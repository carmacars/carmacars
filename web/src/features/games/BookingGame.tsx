'use client';
import './offer.css';
import { useCallback, useEffect, useState, type ComponentType, type ReactNode } from 'react';
import { usePathname } from 'next/navigation';
import { visitorId } from '@/features/live/beacon';
import { bookingIneligible, claimWait, savedWords } from './rules';
import { automated, gameSettings, loadPopup, memory, rememberClaim } from './GameGate';
import type { Claimed, GamePopupProps } from './GamePopup';

// Discount games in the request-to-book form (migration 0081). The one place a signed-in renter sees a game: anyone who
// has not claimed a prize (0172: in the last day, the wait after a claim) is offered "Play for a discount on this booking" on the add-ons and review steps (never on
// the pay or sign pages, never to staff: the server says who may). The offer is decided in idle time when the form
// opens and drawn only with a step that starts after that, so nothing on the page moves. It never blocks the booking:
// the card opens the game over the page, a won code goes in the promo code box (the quote then applies it with its own
// rules: a minimum length, the $75 cap) and the price beside the form changes; closing it goes on with the booking.
const CLOSED = 'cc_game_book_closed';
const wasClosed = () => { try { return sessionStorage.getItem(CLOSED) === '1'; } catch { return false; } };
const idle = (f: () => void) => ('requestIdleCallback' in window ? requestIdleCallback(f, { timeout: 3000 }) : setTimeout(f, 800));

export interface BookingGameArgs {
  step: number; steps: number[]; first: string; email: string; phone: string; promoApplied: boolean;
  /** what the quote says about the code now (applied with its amount, or why not) */
  applied: string;
  onCode: (code: string) => void;
}

export function useBookingGame(a: BookingGameArgs): { card: (step: number) => ReactNode; popup: ReactNode } {
  const path = usePathname() ?? '/book';
  const [ready, setReady] = useState(false);
  const [state, setState] = useState<'offer' | 'closed' | 'won'>('offer');
  const [code, setCode] = useState('');
  // 0100: a prize this visitor already won and has not claimed: offered as saved, not as a game to play
  const [saved, setSaved] = useState<string | null>(null);
  const [Popup, setPopup] = useState<ComponentType<GamePopupProps> | null>(null);
  const [open, setOpen] = useState(false);
  // the steps that started while the offer was ready (derived during render, so the card comes with its step)
  const [lastStep, setLastStep] = useState(a.step);
  const [shownOn, setShownOn] = useState<number[]>([]);
  if (a.step !== lastStep) {
    setLastStep(a.step);
    if (ready && a.steps.includes(a.step) && !shownOn.includes(a.step)) setShownOn([...shownOn, a.step]);
  }

  // in idle time: may this visitor play here? (the settings, this device, then the server: signed in, staff, claimed)
  useEffect(() => {
    let live = true;
    idle(() => {
      void (async () => {
        if (automated() || wasClosed()) return;
        const cfg = await gameSettings();
        if (!live || bookingIneligible({ cfg, mem: memory(), path, now: Date.now() })) return;
        const r = await fetch('/api/games', { method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin',
          body: JSON.stringify({ action: 'start', p: { vid: visitorId(), context: 'booking', dry: true } }) }).then((x) => x.json() as Promise<{ ok: boolean; reason?: string; saved?: string | null; again_after?: string }>).catch(() => null);
        if (!live || !r) return;
        if (!r.ok) { if (r.reason === 'claimed') rememberClaim(r.again_after); return; }
        setSaved(r.saved ?? null);
        setReady(true);
        // the game's code in idle time, so it opens at once
        idle(() => { void loadPopup().catch(() => undefined); });
      })();
    });
    return () => { live = false; };
  }, [path]);

  const play = useCallback(() => {
    void loadPopup().then((m) => { setPopup(() => m.GamePopup); setOpen(true); }).catch(() => undefined);
  }, []);
  const done = useCallback((how: 'closed' | 'claimed' | 'failed') => {
    setOpen(false);
    if (how === 'claimed') return;
    setState((s) => (s === 'won' ? s : 'closed'));
    try { sessionStorage.setItem(CLOSED, '1'); } catch { /* private mode */ }
  }, []);
  const claimed = useCallback((c: Claimed) => { setCode(c.code); setState('won'); a.onCode(c.code); }, [a]);

  const offerOn = (step: number) => ready && shownOn.includes(step) && (state === 'won' || (state === 'offer' && !a.promoApplied && claimWait(memory(), Date.now()) === null));
  const card = (step: number): ReactNode => {
    if (!offerOn(step)) return null;
    if (state === 'won') return (
      <div className="ccg-offer" data-testid="booking-game-won">
        <p className="ccg-offer__text" role="status"><strong>Your game code {code} is on this booking</strong><span>{a.applied}</span></p>
      </div>
    );
    if (saved) return (
      <div className="ccg-offer" data-testid="booking-game" data-saved="true">
        <p className="ccg-offer__text"><strong>{savedWords({ label: saved })}</strong><span>Put it on this booking: the discount comes off the rental charge.</span></p>
        <button type="button" className="btn btn--primary btn--sm ccg-offer__go" onClick={play} data-testid="booking-game-play">Use it</button>
        <button type="button" className="btn btn--quiet btn--sm ccg-offer__no" onClick={() => done('closed')} data-testid="booking-game-no">No thanks</button>
      </div>
    );
    return (
      <div className="ccg-offer" data-testid="booking-game">
        <p className="ccg-offer__text"><strong>Play for a discount on this booking</strong><span>One quick game. Every play wins a discount off the rental charge. Skip it and nothing changes.</span></p>
        <button type="button" className="btn btn--primary btn--sm ccg-offer__go" onClick={play} data-testid="booking-game-play">Play</button>
        <button type="button" className="btn btn--quiet btn--sm ccg-offer__no" onClick={() => done('closed')} data-testid="booking-game-no">No thanks</button>
      </div>
    );
  };
  const popup = open && Popup ? (
    <Popup trigger="booking" context="booking" path={path} seen={memory().seen ?? []} onDone={done} onClaimed={claimed} applied={code ? a.applied : undefined}
      prefill={{ first: a.first, email: a.email, phone: a.phone }} />
  ) : null;
  return { card, popup };
}
