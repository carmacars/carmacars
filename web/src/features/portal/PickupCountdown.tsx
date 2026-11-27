'use client';
import { useEffect, useState } from 'react';

// r50 hotfix 2: the live countdown to the pickup on the renter's booking page: days, hours, minutes and seconds as four
// tiles in tabular figures, ticking each second while the page is in view. The server renders the first value, so it
// reads right without JavaScript. Once the time has come it says so.
export function parts(ms: number): { d: number; h: number; m: number; s: number } {
  const t = Math.max(0, Math.floor(ms / 1000));
  return { d: Math.floor(t / 86400), h: Math.floor((t % 86400) / 3600), m: Math.floor((t % 3600) / 60), s: t % 60 };
}
const two = (n: number) => String(n).padStart(2, '0');

export function PickupCountdown({ until, initialMs, label = 'Pickup in', place, testId = 'pickup-countdown' }: { until: string; initialMs: number; label?: string; place?: string | null; testId?: string }) {
  const [left, setLeft] = useState(initialMs);
  useEffect(() => {
    const at = new Date(until).getTime();
    let t: ReturnType<typeof setInterval> | null = null;
    const run = () => setLeft(at - Date.now());
    const start = () => { if (!t) { run(); t = setInterval(run, 1000); } };
    const stop = () => { if (t) { clearInterval(t); t = null; } };
    const vis = () => (document.hidden ? stop() : start());
    start();
    document.addEventListener('visibilitychange', vis);
    return () => { stop(); document.removeEventListener('visibilitychange', vis); };
  }, [until]);
  const p = parts(left);
  if (left <= 0) {
    return <section className="cd cd--now" data-testid={testId} aria-label="Pickup"><p className="cd__label">It&apos;s pickup time</p>{place && <p className="cd__place">{place}</p>}</section>;
  }
  const tiles: Array<[string, string]> = [[String(p.d), p.d === 1 ? 'day' : 'days'], [two(p.h), 'hours'], [two(p.m), 'min'], [two(p.s), 'sec']];
  return (
    <section className="cd" data-testid={testId} aria-label={`${label} ${p.d} days ${p.h} hours ${p.m} minutes`}>
      <p className="cd__label">{label}</p>
      <div className="cd__tiles" role="timer" aria-live="off">
        {tiles.map(([v, w]) => <span key={w} className="cd__tile"><b suppressHydrationWarning data-testid={`${testId}-${w === 'day' ? 'days' : w}`}>{v}</b><small>{w}</small></span>)}
      </div>
      {place && <p className="cd__place">{place}</p>}
    </section>
  );
}
