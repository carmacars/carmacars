'use client';
import { useEffect, useState } from 'react';
import { waitWords } from '@/lib/wait-words';

// How long something has waited, counting up live, against a target (the first reply target: 5 minutes by default).
// Under the target it is calm, in the last minute it warns, past it it turns red and says "late" in words (colour is
// never the only signal). The server renders the figure as of the request; the browser keeps it ticking every second
// (text only, no movement, so reduced motion does not stop it). Styles in queue.css.
export function waitClock(sec: number): string {
  return waitWords(Math.max(0, sec) / 60);
}

export function WaitTimer({ since, targetMin, now, bar = false, testId, label = 'Waiting' }: {
  /** when the wait began (ISO) */ since: string; /** the target in minutes; none: just the time */ targetMin?: number;
  /** the server's clock at render (ms), so the first paint matches */ now: number; bar?: boolean; testId?: string; label?: string;
}) {
  const start = Date.parse(since);
  const [t, setT] = useState(now);
  useEffect(() => {
    const i = setInterval(() => setT(Date.now()), 15_000);
    return () => clearInterval(i);
  }, []);
  const sec = Math.max(0, (t - start) / 1000);
  const target = targetMin ? targetMin * 60 : null;
  const state = target === null ? 'calm' : sec > target ? 'late' : sec > target - 60 ? 'soon' : 'calm';
  const words = `${label} ${waitWords(sec / 60)}${target !== null ? (state === 'late' ? `, past the ${targetMin}-minute target` : `, target ${targetMin} minutes`) : ''}`;
  return (
    <span className={`pu-timer pu-timer--${state}`} data-testid={testId} data-state={state}>
      <span className="vh">{words}</span>
      <span className="pu-timer__clock" aria-hidden="true" suppressHydrationWarning>{waitClock(sec)}</span>
      {state === 'late' && <span className="pu-timer__tag" aria-hidden="true">late</span>}
      {bar && target !== null && <span className="pu-timer__bar" aria-hidden="true"><span style={{ transform: `scaleX(${Math.min(1, sec / target)})` }} /></span>}
    </span>
  );
}
