'use client';
import './games.css';
import Link from 'next/link';
import { lazy, Suspense, useEffect, useId, useRef, useState, type ComponentType } from 'react';
import { browserRpc } from '@/lib/browser-rpc';
import { sessionId, visitorId } from '@/features/live/beacon';
import { claimProblems, type GameKind, type PrizeWord, type Visit } from './rules';
import { remember } from './GameGate';

// Discount games (migration 0069): the game itself. A slide-in card on a computer and a bottom sheet on a phone, never
// a full-screen block, always closable (the close button and Esc). The database has already drawn the prize; the game
// only shows it. Then the visitor enters a first name, an email and (optional) a mobile number to get the code, which
// is also emailed. Each game is its own small file, loaded here.
export interface GamePopupProps { trigger: 'pages' | 'time' | 'exit'; path: string; onDone: () => void }
export interface Play { ok: boolean; reason?: string; token: string; game: GameKind; prize: PrizeWord & { min_days: number | null }; prizes: PrizeWord[]; terms: string; consent: string; revealed?: boolean }
export interface GameProps { prize: Play['prize']; prizes: PrizeWord[]; reduced: boolean; onReveal: () => void }
type Claimed = { code: string; prize_label: string; applies_to: string; expires: string; email: string };

const GAMES: Record<GameKind, { title: string; pitch: string; C: ComponentType<GameProps> }> = {
  wheel: { title: 'Spin to win', pitch: 'Every spin wins a discount on your rental.', C: lazy(() => import('./games/Wheel')) },
  scratch: { title: 'Scratch to win', pitch: 'Scratch the card. Every card wins a discount.', C: lazy(() => import('./games/Scratch')) },
  blackjack: { title: 'Beat the dealer', pitch: 'One quick hand of blackjack. Win or lose, you get a discount.', C: lazy(() => import('./games/Blackjack')) },
  cups: { title: 'Find the ball', pitch: 'Watch the cups, then pick one. Every cup hides a discount.', C: lazy(() => import('./games/Cups')) },
  plinko: { title: 'Drop to win', pitch: 'Drop the disc. Every slot is a discount.', C: lazy(() => import('./games/Plinko')) }
};
const device = () => (matchMedia('(max-width: 599px)').matches ? 'phone' : matchMedia('(max-width: 1024px)').matches ? 'tablet' : 'desktop');

export function GamePopup({ trigger, path, onDone }: GamePopupProps) {
  const [play, setPlay] = useState<Play | null>(null);
  const [stage, setStage] = useState<'ready' | 'playing' | 'won' | 'claimed'>('ready');
  const [form, setForm] = useState({ first: '', email: '', phone: '', marketing: false });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [failure, setFailure] = useState('');
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
    const start = () => browserRpc<Play>('game_start', { p: { vid: visitorId(), sid: sessionId(), device: device(), path, trigger } });
    // one more try after a moment if the network dropped the first
    start().catch(() => new Promise<Play>((ok, ko) => setTimeout(() => start().then(ok, ko), 3000)))
      .then((r) => {
        if (!live) return;
        if (!r?.ok) { if (r?.reason && ['claimed', 'known', 'signed_in'].includes(r.reason)) remember({ never: r.reason }); onDone(); return; }
        setPlay(r);
        if (r.revealed) setStage('won');
      })
      .catch(() => { if (live) onDone(); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  // focus moves to the card when it opens (it does not trap focus: the page stays usable behind it)
  useEffect(() => { if (play) head.current?.focus(); }, [play]);
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
    addEventListener('keydown', k);
    return () => removeEventListener('keydown', k);
  });

  function close() {
    if (stage !== 'claimed') remember({ dismissedAt: Date.now() });
    if (back.current instanceof HTMLElement) back.current.focus();
    onDone();
  }
  function revealed() {
    setStage('won');
    if (play) void browserRpc('game_reveal', { p_token: play.token }).catch(() => undefined);
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
        token: play.token, first_name: form.first.trim(), email: form.email.trim(), phone: form.phone.trim(), marketing: form.marketing, sid: sessionId(),
        cars_viewed: visit?.cars.length ?? 0, pages_viewed: visit?.pages ?? 0, seconds: visit ? Math.round((Date.now() - visit.start) / 1000) : 0 }) });
      const j = (await r.json()) as ({ ok: true } & Claimed) | { ok: false; error?: string; message?: string };
      if (!j.ok) {
        if (j.error && ['first_name', 'email', 'phone'].includes(j.error)) setErrors({ [j.error === 'first_name' ? 'first' : j.error]: j.message ?? 'Check this field.' });
        else setFailure(j.message ?? 'We could not send the code. Please try again.');
        if (j.error === 'email_used' || j.error === 'device_used' || j.error === 'claimed') remember({ claimed: true });
        return;
      }
      setClaimed(j); setStage('claimed');
      remember({ claimed: true, code: j.code, codeUntil: j.expires });
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
  return (
    <section className="ccg" role="dialog" aria-modal="false" aria-labelledby={`${id}-h`} aria-describedby={`${id}-d`} data-testid="game" data-game={play.game}>
      <header className="ccg-head">
        <div>
          <p className="ccg-kicker">CarmaCars giveaway</p>
          <h2 className="ccg-title" id={`${id}-h`} ref={head} tabIndex={-1}>
            {stage === 'claimed' ? 'Your code is ready' : stage === 'won' ? `You won ${play.prize.label}` : g.title}
          </h2>
        </div>
        <button type="button" className="ccg-x" onClick={close} aria-label="Close the game" data-testid="game-close">×</button>
      </header>
      <div className="ccg-body">
        {stage === 'ready' && <>
          <p className="ccg-pitch" id={`${id}-d`}>{g.pitch}</p>
          <button type="button" className="btn btn--primary ccg-play" onClick={() => setStage('playing')} data-testid="game-play">Play now</button>
          <p className="ccg-fine">{play.terms} <Link className="link" href="/terms#s14">Terms</Link></p>
        </>}
        {stage === 'playing' && <>
          <p className="vh" id={`${id}-d`}>{g.pitch}</p>
          <Suspense fallback={<div className="ccg-stage" aria-busy="true" />}><g.C prize={play.prize} prizes={play.prizes} reduced={reduced} onReveal={revealed} /></Suspense>
        </>}
        {stage === 'won' && <form onSubmit={claim} noValidate className="ccg-form" data-testid="game-claim">
          <p className="ccg-prize" id={`${id}-d`} role="status"><strong>{play.prize.label}</strong> your rental{play.prize.min_days ? ` of ${play.prize.min_days} days or more` : ''}. Tell us where to send your code.</p>
          <label className="ccg-field" htmlFor={`${id}-first`}><span>First name</span>
            <input className="input" id={`${id}-first`} name="first" autoComplete="given-name" value={form.first} onChange={(e) => setForm({ ...form, first: e.target.value })}
              aria-invalid={err('first') ? true : undefined} aria-describedby={err('first') ? `${id}-first-e` : undefined} /></label>
          {err('first') && <p className="ccg-err" id={`${id}-first-e`}>{err('first')}</p>}
          <label className="ccg-field" htmlFor={`${id}-email`}><span>Email</span>
            <input className="input" id={`${id}-email`} name="email" type="email" inputMode="email" autoComplete="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })}
              aria-invalid={err('email') ? true : undefined} aria-describedby={err('email') ? `${id}-email-e` : undefined} /></label>
          {err('email') && <p className="ccg-err" id={`${id}-email-e`}>{err('email')}</p>}
          <label className="ccg-field" htmlFor={`${id}-phone`}><span>Mobile <em>(optional, for a faster booking)</em></span>
            <input className="input" id={`${id}-phone`} name="phone" type="tel" inputMode="tel" autoComplete="tel" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })}
              aria-invalid={err('phone') ? true : undefined} aria-describedby={err('phone') ? `${id}-phone-e` : undefined} /></label>
          {err('phone') && <p className="ccg-err" id={`${id}-phone-e`}>{err('phone')}</p>}
          {play.consent && <label className="check ccg-check"><input type="checkbox" name="marketing" checked={form.marketing} onChange={(e) => setForm({ ...form, marketing: e.target.checked })} />
            <span>{play.consent}</span></label>}
          <button type="submit" className="btn btn--primary ccg-play" disabled={busy} data-testid="game-get-code">{busy ? 'Sending...' : 'Get my code'}</button>
          {failure && <p className="ccg-err" role="alert">{failure}</p>}
          <p className="ccg-fine">We email the code either way. {play.terms} <Link className="link" href="/terms#s14">Terms</Link> and <Link className="link" href="/privacy">Privacy</Link>.</p>
        </form>}
        {stage === 'claimed' && claimed && <div className="ccg-done" data-testid="game-done">
          <p className="ccg-codebox"><span className="vh">Your code: </span><strong data-testid="game-code">{claimed.code}</strong></p>
          <p className="ccg-pitch">{claimed.prize_label} {claimed.applies_to}. Good until {claimed.expires}. We sent it to {claimed.email} too.</p>
          <div className="ccg-row">
            <button type="button" className="btn btn--ghost" onClick={copy}>{copied ? 'Copied' : 'Copy the code'}</button>
            <Link className="btn btn--primary" href="/cars" onClick={() => onDone()}>Choose a car</Link>
          </div>
          <p className="ccg-fine" role="status">{copied ? 'The code is copied.' : 'Enter it in the promo code box when you send your booking request. We fill it in for you on this device.'}</p>
        </div>}
      </div>
    </section>
  );
}
