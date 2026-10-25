'use client';
import { useEffect, useState } from 'react';

// the same words as ago() in ../ui (kept here so this client file pulls in nothing else)
const ago = (min: number) => (min < 60 ? `${min} min` : min < 1440 ? `${Math.floor(min / 60)} h ${min % 60} min` : `${Math.floor(min / 1440)} d ${Math.floor((min % 1440) / 60)} h`);

/**
 * How long something has waited, kept current while the page is open (admin portal design, October 25, 2026): the
 * server's figure first, then one more minute each minute. Past the target it turns red and says so in words.
 */
export function LiveWait({ minutes, target, testId, prefix = '' }: { minutes: number; target?: number; testId?: string; prefix?: string }) {
  const [m, setM] = useState(Math.max(0, Math.round(minutes)));
  useEffect(() => {
    const t0 = Date.now();
    const base = Math.max(0, Math.round(minutes));
    const id = setInterval(() => setM(base + Math.floor((Date.now() - t0) / 60_000)), 15_000);
    return () => clearInterval(id);
  }, [minutes]);
  const over = target !== undefined && m > target;
  return (
    <span className={`ad-wait${over ? ' is-over' : ''}`} data-testid={testId}>
      <span className="ad-wait__dot" aria-hidden="true" />
      {prefix}{ago(m)}{over ? <span className="vh">, past the reply target</span> : null}
    </span>
  );
}
