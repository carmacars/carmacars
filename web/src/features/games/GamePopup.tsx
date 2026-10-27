'use client';
import './games.css';
import Link from 'next/link';
import { lazy, Suspense, useEffect, useId, useRef, useState, type ComponentType } from 'react';
import { browserRpc } from '@/lib/browser-rpc';
import { sessionId, visitorId } from '@/features/live/beacon';
import { claimProblems, isReplay, keptWords, mayPlayAgain, waitingWords, wonWords, type GameKind, type PrizeWord, type Trigger, type Visit } from './rules';
import { forgetSaved, memory, remember, rememberAgain, rememberClaim, rememberSeen, rememberWon } from './GameGate';
import { SavedAsYouType, useCapture } from '@/features/capture/useCapture';

// Discount games (migrations 0069 and 0081): the game itself. A slide-in card on a computer and a bottom sheet on a
// phone, never a full-screen block, always closable (the close button and Esc). On the first page of a phone visit
// from a search engine it starts as a small slide-in that opens into the card when tapped. The database has already
// drawn the prize; the game only shows it. Then the visitor enters a first name, an email and (optional) a mobile
// number to get the code, which is also emailed. In the request-to-book form (context "booking") the same card opens
// from the inline offer, the fields come filled from the form (a signed-in renter's code goes to their account's
// email), and the code goes on that booking request. Each game is its own small file, fetched in idle time. 0171: a
// prize won earlier and not claimed opens this card again by itself ("Your 5% off is still waiting"); the replay prize
// ("another go") has no claim form but a "Play again" button: the server starts a second play (another game, a prize
// without the replay), which always ends in a code. 0176: the prize popping up again by itself is the small slide-in
// ("Your 5% off is still waiting") with Get my code (the full card with its claim form) and Play again: a new game
// (game_start with again_of, once a visit and once a day); the visitor keeps the better of the two prizes (the server
// decides and closes the other), so there are never two open prizes.
export type Claimed = { code: string; prize_label: string; applies_to: string; expires: string; email: string; min_days?: number | null; again_after?: string | null };
export interface GamePopupProps {
  trigger: Trigger | 'booking' | 'saved'; path: string; seen: GameKind[]; onDone: (how: 'closed' | 'claimed' | 'failed') => void; slim?: boolean;
  /** 0176: the prize popping up again by itself (the small slide-in with Get my code and Play again) */
  repop?: boolean;
  /** 0176: opened by the badge's Play again: start the new game at once */
  start?: 'again';
  context?: 'site' | 'booking'; prefill?: { first: string; email: string; phone: string }; onClaimed?: (c: Claimed) => void; applied?: string;
}
export interface Play { ok: boolean; reason?: string; /** 0172: with reason claimed, when this person may play again */ again_after?: string; token: string; game: GameKind; prize: PrizeWord & { min_days: number | null; rare?: boolean }; prizes: PrizeWord[]; terms: string; consent: string; revealed?: boolean;
  /** 0171: the second game of a replay prize */
  second?: boolean;
  /** 0100: this visitor already won this prize (an earlier game was played to the end) and has not claimed it */
  saved?: boolean; context?: 'site' | 'booking'; account?: { first: string | null; email: string };
  /** 0176: with a saved prize: whether Play again may start a new game now (once a day, game_saved_again_days) */
  again?: { ok: boolean; again_after?: string };
  /** 0176: a game started by Play again on a saved prize: the prize the visitor keeps (the better of the two) */
  keep?: { from: 'new' | 'saved'; token: string; prize: Play['prize']; other: string } }
export interface GameProps { prize: Play['prize']; prizes: PrizeWord[]; reduced: boolean; onReveal: () => void }

const LOAD: Record<GameKind, () => Promise<{ default: ComponentType<GameProps> }>> = {
  wheel: () => import('./games/Wheel'), scratch: () => import('./games/Scratch'), blackjack: () => import('./games/Blackjack'),
  cups: () => import('./games/Cups'), plinko: () => import('./games/Plinko'), pack: () => import('./games/Pack'),
  coin: () => import('./games/Coin'), dice: () => import('./games/Dice'), slots: () => import('./games/Slots'), drop: () => import('./games/Drop'),
  mystery: () => import('./games/Mystery')
};
/** The games' code, fetched ahead (idle time) so a game opens at once. */
export function preloadGames() { for (const f of Object.values(LOAD)) void f().catch(() => undefined); }
const GAMES: Record<GameKind, { title: string; pitch: string; C: ComponentType<GameProps> }> = {
  wheel: { title: 'Spin to win', pitch: 'Every spin wins a discount on your rental.', C: lazy(LOAD.wheel) },
  scratch: { title: 'Scratch to win', pitch: 'Scratch the card. Every card wins a discount.', C: lazy(LOAD.scratch) },
  blackjack: { title: 'Beat the dealer', pitch: 'One quick hand of blackjack. Win or lose, you get a discount.', C: lazy(LOAD.blackjack) },
  cups: { title: 'Find the ball', pitch: 'Watch the cups, then pick one. Every cup hides a discount.', C: lazy(LOAD.cups) },
  plinko: { title: 'Drop to win', pitch: 'Drop the disc. Every slot is a discount.', C: lazy(LOAD.plinko) },
  pack: { title: 'Rip the pack', pitch: 'Tear open the CarmaCars pack. The last card is your discount.', C: lazy(LOAD.pack) },
  coin: { title: 'Flip to win', pitch: 'Call heads or tails. Every flip wins a discount.', C: lazy(LOAD.coin) },
  dice: { title: 'Roll to win', pitch: 'Roll the dice. Every roll wins a discount.', C: lazy(LOAD.dice) },
  slots: { title: 'Pull to win', pitch: 'Pull the lever on the CarmaCars slot machine. Every spin wins a discount.', C: lazy(LOAD.slots) },
  drop: { title: 'Prize drop', pitch: 'Turn the handle for a prize capsule. Every capsule holds a discount.', C: lazy(LOAD.drop) },
  mystery: { title: 'Pick a box', pitch: 'Pick one of three mystery boxes. Every box holds a discount.', C: lazy(LOAD.mystery) }
};
const COLOURS = ['#D0111B', '#000000', '#ffffff', '#ff6a70', '#ffd23f', '#6ec6ff'];
/** A rare prize: a burst of confetti over the card (never with reduced motion). */
function Confetti() {
  return (
    <span className="ccg-confetti" aria-hidden="true">
      {Array.from({ length: 36 }, (_, i) => <i key={i} style={{ ['--x' as string]: `${(i * 37) % 100}%`, ['--c' as string]: COLOURS[i % COLOURS.length],
        ['--d' as string]: `${(i % 9) * 70}ms`, ['--rot' as string]: `${(i % 2 ? 1 : -1) * (180 + (i * 53) % 360)}deg` }} />)}
    </span>
  );
}
const device = () => (matchMedia('(max-width: 599px)').matches ? 'phone' : matchMedia('(max-width: 1024px)').matches ? 'tablet' : 'desktop');

async function startPlay(p: Record<string, unknown>, booking: boolean): Promise<Play> {
  if (!booking) return browserRpc<Play>('game_start', { p });
  // the request-to-book form's play goes through the site's server, which knows who is signed in
  const r = await fetch('/api/games', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin', body: JSON.stringify({ action: 'start', p }) });
  if (!r.ok && r.status >= 500) throw new Error('unavailable');
  return (await r.json()) as Play;
}

export function GamePopup({ trigger, path, seen, onDone, slim: slimAtFirst = false, repop = false, start, context = 'site', prefill, onClaimed, applied }: GamePopupProps) {
  const booking = context === 'booking';
  const [play, setPlay] = useState<Play | null>(null);
  // 0176: the prize popping up again by itself starts small; the full card opens from Get my code or Play again
  const [slim, setSlim] = useState(slimAtFirst || repop);
  const [stage, setStage] = useState<'ready' | 'playing' | 'won' | 'claimed'>('ready');
  // 0100: a prize won in an earlier game and not claimed: "Your 5% off is saved", never "You won" again
  const [saved, setSaved] = useState(false);
  const [form, setForm] = useState({ first: prefill?.first ?? '', email: prefill?.email ?? '', phone: prefill?.phone ?? '', marketing: false });
  // contact capture (0090): what is typed to claim the code is saved as each field becomes valid
  const cap = useCapture('game');
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [failure, setFailure] = useState('');
  // 0171: what this card was opened as: by the saved badge or the booking form ("is saved"), or by itself ("is still waiting")
  const how: 'saved' | 'waiting' = trigger === 'saved' || booking ? 'saved' : 'waiting';
  const [busy, setBusy] = useState(false);
  const [claimed, setClaimed] = useState<Claimed | null>(null);
  const [copied, setCopied] = useState(false);
  const [reduced] = useState(() => matchMedia('(prefers-reduced-motion: reduce)').matches);
  const head = useRef<HTMLHeadingElement>(null);
  const back = useRef<Element | null>(null);
  const id = useId();

  useEffect(() => {
    let live = true;
    back.current = document.activeElement;
    const p = { vid: visitorId(), sid: sessionId(), device: device(), path, trigger: booking ? 'booking' : trigger, seen, ...(booking ? { context: 'booking' } : {}) };
    // one more try after a moment if the network dropped the first
    startPlay(p, booking).catch(() => new Promise<Play>((ok, ko) => setTimeout(() => startPlay(p, booking).then(ok, ko), 3000)))
      .then((r) => {
        if (!live) return;
        if (!r?.ok) {
          // 0172: claimed: not until again_after (the server's wait after a claim); known or signed in: not on the site
          if (r?.reason === 'claimed') rememberClaim(r.again_after);
          else if (r?.reason && !booking && ['known', 'signed_in'].includes(r.reason)) remember({ never: r.reason });
          // 0170: the saved badge's prize is gone on the server (claimed, expired, games off): no badge that does nothing
          if (trigger === 'saved' && r?.reason !== 'limited') forgetSaved();
          onDone('failed'); return;
        }
        // a game this page does not know yet (a newer database than this website): no game rather than a broken one
        if (!GAMES[r.game]) { onDone('failed'); return; }
        if (r.account) setForm((f) => ({ ...f, first: f.first || r.account?.first || '', email: r.account?.email ?? f.email }));
        setPlay(r);
        // 0100: the prize shows only as the outcome of a game played now. A play already revealed (an earlier game,
        // the same page again) is a saved prize: its claim form opens under "Your ... is saved", never as a new win.
        // 0170: the badge asked for a saved prize the server no longer holds (it lapsed): a new game instead
        if ((trigger === 'saved' || repop) && !r.saved && !r.revealed) forgetSaved();
        if (r.saved || r.revealed) {
          rememberWon(r.prize);
          // 0171: the claim form under "Your ... is saved" (the badge, the request-to-book form's card) or, when the card
          // popped up again by itself, "Your ... is still waiting"; a replay prize not used yet offers Play again.
          // 0176: popped up by itself, it is the small slide-in (Get my code, Play again), never the full card
          setSaved(true); setStage('won');
          if (!booking && trigger !== 'saved') setSlim(true);
          if (start === 'again' && !isReplay(r.prize)) void playAgain(r);
          return;
        }
        rememberSeen(r.game);
      })
      .catch(() => { if (live) onDone('failed'); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  // focus moves to the card when it opens (it does not trap focus: the page stays usable behind it); the small
  // slide-in does not take the focus
  useEffect(() => { if (play && !slim) head.current?.focus(); }, [play, slim]);
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
    addEventListener('keydown', k);
    return () => removeEventListener('keydown', k);
  });

  function close() {
    if (back.current instanceof HTMLElement && document.contains(back.current)) back.current.focus();
    onDone(stage === 'claimed' ? 'claimed' : 'closed');
  }
  function revealed() {
    setStage('won');
    // 0176: after Play again on a saved prize the browser keeps the prize the server kept
    if (play) rememberWon(play.keep ? play.keep.prize : play.prize);
    if (play) void browserRpc('game_reveal', { p_token: play.token }).catch(() => undefined);
  }
  // 0171: the replay prize: the server starts the second game (another game, a prize that is a discount)
  async function again() {
    if (!play || busy) return;
    setBusy(true); setFailure('');
    const p = { vid: visitorId(), sid: sessionId(), device: device(), path, trigger: booking ? 'booking' : trigger, seen: memory().seen ?? [], replay_of: play.token, ...(booking ? { context: 'booking' } : {}) };
    try {
      const r = await startPlay(p, booking);
      if (!r?.ok || !GAMES[r.game]) { setFailure('We could not start your next game. Please try again.'); return; }
      setPlay(r); setSaved(false); setStage('playing');
      rememberSeen(r.game);
      setTimeout(() => head.current?.focus(), 0);
    } catch { setFailure('We could not start your next game. Check your connection and try again.'); }
    finally { setBusy(false); }
  }
  // 0176: Play again on a saved prize: a new game (another kind, a new draw); the better of the two prizes is kept
  async function playAgain(from: Play) {
    if (busy) return;
    setBusy(true); setFailure('');
    const p = { vid: visitorId(), sid: sessionId(), device: device(), path, trigger, seen: memory().seen ?? [], again_of: from.token };
    try {
      const r = await startPlay(p, false);
      if (r?.ok && GAMES[r.game]) {
        rememberAgain();
        setPlay(r); setSaved(false); setSlim(false); setStage('playing');
        rememberSeen(r.game);
        setTimeout(() => head.current?.focus(), 0);
        return;
      }
      if (r?.reason === 'again_limited') rememberAgain();
      // the saved prize stays: its claim form, with why there is no new game
      setSlim(false);
      setFailure(r?.reason === 'again_limited' ? `Play again is once a day. Your ${from.prize.label} is still yours: get the code below.` : 'We could not start a new game. Your prize is still yours: get the code below.');
    } catch { setSlim(false); setFailure('We could not start a new game. Check your connection and try again.'); }
    finally { setBusy(false); }
  }
  async function claim(e: React.FormEvent) {
    e.preventDefault();
    if (!play || busy) return;
    const p = claimProblems(form);
    setErrors(p); setFailure('');
    if (Object.keys(p).length) { document.getElementById(`${id}-${Object.keys(p)[0]}`)?.focus(); return; }
    setBusy(true);
    let visit: Visit | null = null;
    try { visit = JSON.parse(sessionStorage.getItem('cc_game_visit') ?? 'null') as Visit | null; } catch { /* private mode */ }
    try {
      const r = await fetch('/api/games', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin', body: JSON.stringify({
        token: play.keep?.token ?? play.token, first_name: form.first.trim(), email: form.email.trim(), phone: form.phone.trim(), marketing: form.marketing, sid: sessionId(),
        cars_viewed: visit?.cars.length ?? 0, pages_viewed: visit?.pages ?? 0, seconds: visit ? Math.round((Date.now() - visit.start) / 1000) : 0 }) });
      const j = (await r.json()) as ({ ok: true } & Claimed) | { ok: false; error?: string; message?: string; again_after?: string };
      if (!j.ok) {
        if (j.error && ['first_name', 'email', 'phone'].includes(j.error)) setErrors({ [j.error === 'first_name' ? 'first' : j.error]: j.message ?? 'Check this field.' });
        else setFailure(j.message ?? 'We could not send the code. Please try again.');
        if (j.error === 'email_used' || j.error === 'device_used' || j.error === 'claimed') rememberClaim(j.again_after);
        return;
      }
      setClaimed(j); setStage('claimed');
      rememberClaim(j.again_after, { code: j.code, codeUntil: j.expires });
      forgetSaved();
      onClaimed?.(j);
      setTimeout(() => head.current?.focus(), 0);
    } catch { setFailure('We could not send the code. Check your connection and try again.'); }
    finally { setBusy(false); }
  }
  async function copy() {
    if (!claimed) return;
    try { await navigator.clipboard.writeText(claimed.code); setCopied(true); } catch { setCopied(false); }
  }

  if (!play) return null;
  const g = GAMES[play.game];
  const err = (k: string) => errors[k];
  const account = booking && play.account;
  const replay = isReplay(play.prize);
  // 0176: the prize shown in the claim form: the one kept after Play again on a saved prize
  const kept = play.keep?.from === 'saved';
  const prize = kept ? play.keep!.prize : play.prize;
  let visitNow: Visit | null = null;
  try { visitNow = JSON.parse(sessionStorage.getItem('cc_game_visit') ?? 'null') as Visit | null; } catch { /* private mode */ }
  const againOk = !booking && play.again?.ok !== false && mayPlayAgain(memory(), visitNow, Date.now());
  if (slim && saved) return (
    <section className="ccg ccg--two" role="region" aria-label="CarmaCars giveaway" data-testid="game" data-game={play.game} data-slim="true" data-repop="true" data-saved="true">
      <p className="ccg-two__text">{replay ? 'You still have another go' : waitingWords(play.prize)}
        <span>{replay ? 'One more game, on us.' : againOk ? 'Get your code, or play again: you keep the better prize.' : 'Get your code before it ends.'}</span></p>
      <button type="button" className="ccg-x ccg-x--dark" onClick={close} aria-label="Close the game" data-testid="game-close">×</button>
      <div className="ccg-two__acts">
        {!replay && <button type="button" className="btn btn--primary btn--sm" onClick={() => { setSlim(false); setTimeout(() => head.current?.focus(), 0); }} data-testid="game-open-code">Get my code</button>}
        {(replay || againOk) && <button type="button" className={`btn btn--sm ${replay ? 'btn--primary' : 'btn--ghost'}`} disabled={busy} data-testid="game-again"
          onClick={() => { if (replay) { setSlim(false); void again(); } else void playAgain(play); }}>{busy ? 'Starting...' : 'Play again'}</button>}
      </div>
    </section>
  );
  if (slim) return (
    <section className="ccg ccg--slim" role="region" aria-label="CarmaCars giveaway" data-testid="game" data-game={play.game} data-slim="true">
      <p className="ccg-slim__text"><strong>Play for a discount</strong> <span>on your rental</span></p>
      <button type="button" className="btn btn--primary btn--sm ccg-slim__go" onClick={() => setSlim(false)} data-testid="game-open">Play</button>
      <button type="button" className="ccg-x ccg-x--dark" onClick={close} aria-label="Close the game" data-testid="game-close">×</button>
    </section>
  );
  return (
    <section className={`ccg${booking ? ' ccg--booking' : ''}`} role="dialog" aria-modal="false" aria-labelledby={`${id}-h`} aria-describedby={`${id}-d`} data-testid="game" data-game={play.game} data-context={context} data-saved={saved ? 'true' : undefined}>
      <header className="ccg-head">
        <div>
          <p className="ccg-kicker">{booking ? 'A discount on this booking' : 'CarmaCars giveaway'}</p>
          <h2 className="ccg-title" id={`${id}-h`} ref={head} tabIndex={-1}>
            {stage === 'claimed' ? (booking ? 'Your discount is on' : 'Your code is ready') : stage === 'won' ? (kept ? keptWords(prize) : wonWords(play.prize, saved ? how : 'new')) : play.second ? `Your second go: ${g.title}` : g.title}
          </h2>
        </div>
        <button type="button" className="ccg-x" onClick={close} aria-label={booking ? 'Close the game and go on with the booking' : 'Close the game'} data-testid="game-close">×</button>
      </header>
      {stage === 'won' && !saved && !kept && play.prize.rare && !reduced && <Confetti />}
      <div className="ccg-body">
        {stage === 'ready' && <>
          <p className="ccg-pitch" id={`${id}-d`}>{g.pitch}</p>
          <button type="button" className="btn btn--primary ccg-play" onClick={() => setStage('playing')} data-testid="game-play">Play now</button>
          <p className="ccg-fine">{play.terms} <Link className="link" href="/terms#s14" target={booking ? '_blank' : undefined}>Terms</Link></p>
        </>}
        {stage === 'playing' && <>
          <p className="vh" id={`${id}-d`}>{g.pitch}</p>
          <Suspense fallback={<div className="ccg-stage" aria-busy="true" />}><g.C prize={play.prize} prizes={play.prizes} reduced={reduced} onReveal={revealed} /></Suspense>
        </>}
        {stage === 'won' && replay && <div className="ccg-done" data-testid="game-replay-offer">
          <p className="ccg-pitch" id={`${id}-d`} role="status">{saved ? 'Your free replay is still here.' : 'One more game, on us.'} Your next game always ends in a discount on {booking ? 'this booking' : 'your rental'}.</p>
          <button type="button" className="btn btn--primary ccg-play" onClick={again} disabled={busy} data-testid="game-replay">{busy ? 'Starting...' : 'Play again'}</button>
          {failure && <p className="ccg-err" role="alert">{failure}</p>}
          <p className="ccg-fine">{play.terms} <Link className="link" href="/terms#s14" target={booking ? '_blank' : undefined}>Terms</Link></p>
        </div>}
        {stage === 'won' && !replay && <form onSubmit={claim} noValidate className="ccg-form" data-testid="game-claim" onBlur={() => cap.capture({ name: form.first, email: form.email, phone: form.phone })}>
          {play.prize.rare && !saved && !kept && <p className="ccg-rare" data-testid="game-rare">A rare prize</p>}
          {play.keep && <p className="ccg-pitch" data-testid="game-kept" data-kept={play.keep.from}>{kept ? `This game gave ${play.keep.other}, so you keep your ${prize.label}.` : `Better than your ${play.keep.other}: this prize replaces it.`}</p>}
          <p className={`ccg-prize${prize.rare ? ' ccg-holo' : ''}`} id={`${id}-d`} role="status"><strong>{prize.label}</strong> {/free day/.test(prize.label) ? 'on ' : ''}{booking ? 'this booking' : 'your rental'}{prize.min_days ? ` of ${prize.min_days} days or more` : ''}. {booking ? (account ? `We put the code on this booking and send it to ${account.email}.` : 'Where should we send your code? It goes on this booking at once.') : 'Tell us where to send your code.'}</p>
          <label className="ccg-field" htmlFor={`${id}-first`}><span>First name</span>
            <input className="input" id={`${id}-first`} name="first" autoComplete="given-name" value={form.first} onChange={(e) => setForm({ ...form, first: e.target.value })}
              aria-invalid={err('first') ? true : undefined} aria-describedby={err('first') ? `${id}-first-e` : undefined} /></label>
          {err('first') && <p className="ccg-err" id={`${id}-first-e`}>{err('first')}</p>}
          {!account && <>
            <label className="ccg-field" htmlFor={`${id}-email`}><span>Email</span>
              <input className="input" id={`${id}-email`} name="email" type="email" inputMode="email" autoComplete="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })}
                aria-invalid={err('email') ? true : undefined} aria-describedby={err('email') ? `${id}-email-e` : undefined} /></label>
            {err('email') && <p className="ccg-err" id={`${id}-email-e`}>{err('email')}</p>}
            <label className="ccg-field" htmlFor={`${id}-phone`}><span>Mobile <em>(optional, for a faster booking)</em></span>
              <input className="input" id={`${id}-phone`} name="phone" type="tel" inputMode="tel" autoComplete="tel" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })}
                aria-invalid={err('phone') ? true : undefined} aria-describedby={err('phone') ? `${id}-phone-e` : undefined} /></label>
            {err('phone') && <p className="ccg-err" id={`${id}-phone-e`}>{err('phone')}</p>}
          </>}
          {play.consent && <label className="check ccg-check"><input type="checkbox" name="marketing" checked={form.marketing} onChange={(e) => setForm({ ...form, marketing: e.target.checked })} />
            <span>{play.consent}</span></label>}
          <button type="submit" className="btn btn--primary ccg-play" disabled={busy} data-testid="game-get-code">{busy ? 'Sending...' : booking ? 'Apply my discount' : 'Get my code'}</button>
          {failure && <p className="ccg-err" role="alert">{failure}</p>}
          <SavedAsYouType className="ccg-fine" newTab={!!booking} />
          <p className="ccg-fine">We email the code either way. {play.terms} <Link className="link" href="/terms#s14" target={booking ? '_blank' : undefined}>Terms</Link> and <Link className="link" href="/privacy" target={booking ? '_blank' : undefined}>Privacy</Link>.</p>
        </form>}
        {stage === 'claimed' && claimed && <div className="ccg-done" data-testid="game-done">
          <p className="ccg-codebox"><span className="vh">Your code: </span><strong data-testid="game-code">{claimed.code}</strong></p>
          <p className="ccg-pitch">{claimed.prize_label} {claimed.applies_to}. Good until {claimed.expires}. We sent it to {claimed.email} too.</p>
          {booking ? <>
            <p className="ccg-pitch" role="status" data-testid="game-applied">{applied ?? 'The code is on this booking request. The price beside the form shows it.'}</p>
            <button type="button" className="btn btn--primary ccg-play" onClick={close} data-testid="game-continue">Back to my booking</button>
          </> : <>
            <div className="ccg-row">
              <button type="button" className="btn btn--ghost" onClick={copy}>{copied ? 'Copied' : 'Copy the code'}</button>
              <Link className="btn btn--primary" href="/cars" onClick={() => onDone('claimed')}>Choose a car</Link>
            </div>
            <p className="ccg-fine" role="status">{copied ? 'The code is copied.' : 'Enter it in the promo code box when you send your booking request. We fill it in for you on this device.'}</p>
          </>}
        </div>}
      </div>
    </section>
  );
}
