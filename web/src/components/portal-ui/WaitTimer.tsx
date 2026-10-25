'use client';
import { useEffect, useState } from 'react';

// How long something has waited, counting up live, against a target (the first reply target: 5 minutes by default).
// Under the target it is calm, in the last minute it warns, past it it turns red and says "late" in words (colour is
// never the only signal). The server renders the figure as of the request; the browser keeps it ticking every second
// (text only, no movement, so reduced motion does not stop it). Styles in queue.css.
export function waitClock(sec: number): string {
  const s = Math.max(0, Math.floor(sec));
  if (s >= 86_400) return `${Math.floor(s / 86_400)}d ${Math.floor((s % 86_400) / 3600)}h`;
  if (s >= 3600) return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}m`;
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

export function WaitTimer({ since, targetMin, now, bar = false, testId, label = 'Waiting' }: {
  /** when the wait began (ISO) */ since: string; /** the target in minutes; none: just the time */ targetMin?: number;
  /** the server's clock at render (ms), so the first paint matches */ now: number; bar?: boolean; testId?: string; label?: string;
}) {
  const start = Date.parse(since);
  const [t, setT] = useState(now);
  useEffect(() => {
    const i = setInterval(() => setT(Date.now()), 1000);
    return () => clearInterval(i);
  }, []);
  const sec = Math.max(0, (t - start) / 1000);
  const target = targetMin ? targetMin * 60 : null;
  const state = target === null ? 'calm' : sec > target ? 'late' : sec > target - 60 ? 'soon' : 'calm';
  const mins = Math.floor(sec / 60);
  const words = `${label} ${mins < 1 ? 'under a minute' : mins === 1 ? '1 minute' : `${mins} minutes`}${target !== null ? (state === 'late' ? `, past the ${targetMin}-minute target` : `, target ${targetMin} minutes`) : ''}`;
  return (
    <span className={`pu-timer pu-timer--${state}`} data-testid={testId} data-state={state}>
      <span className="vh">{words}</span>
      <span className="pu-timer__clock" aria-hidden="true" suppressHydrationWarning>{waitClock(sec)}</span>
      {state === 'late' && <span className="pu-timer__tag" aria-hidden="true">late</span>}
      {bar && target !== null && <span className="pu-timer__bar" aria-hidden="true"><span style={{ transform: `scaleX(${Math.min(1, sec / target)})` }} /></span>}
    </span>
  );
}
