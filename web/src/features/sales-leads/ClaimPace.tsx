'use client';
import { useEffect, useState } from 'react';
import { claimPaceWords } from './model';

/** The two limits on claiming (1152): how many leads the person holds of their cap (and the wins to the next slot), and the
 *  next claim in mm:ss. */
export function ClaimPace({ held, max, nextAt, cooldown, paced, winsToNext = null }: { held: number; max: number; nextAt: string | null; cooldown: number; paced: boolean; winsToNext?: number | null }) {
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    if (!nextAt) return;
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const t = setInterval(tick, 1000);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [nextAt]);
  return <span data-testid="lead-pace">{claimPaceWords({ held, max, nextAt, cooldown, paced, winsToNext }, now ?? (nextAt ? Date.parse(nextAt) - cooldown * 60_000 : 0))}</span>;
}
