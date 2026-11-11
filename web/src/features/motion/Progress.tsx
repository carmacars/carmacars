'use client';
import { useEffect, useRef } from 'react';
import { playMoment } from './moment';

// Release 36: the booking and renter portal polish (on the motion layer of 2026-10-21 and r35's moments; every movement is in
// styles/motion.css under prefers-reduced-motion: no-preference, transform and opacity only).

/** A checklist's progress: "2 of 4 done" and a bar that fills to it when it shows (the fill is a transform, so nothing
 *  moves the layout). Server or client page alike. */
export function ChecklistProgress({ done, total, label, testId }: { done: number; total: number; label: string; testId?: string }) {
  if (total <= 0) return null;
  const p = Math.max(0, Math.min(1, done / total));
  return (
    <div className="ck-progress" data-testid={testId} data-complete={done >= total || undefined}>
      <div className="ck-progress__bar" role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={total} aria-valuenow={done} aria-valuetext={`${done} of ${total} done`}>
        <span className="ck-progress__fill" style={{ ['--p' as string]: String(p) }} />
      </div>
      <p className="ck-progress__text small">{done >= total ? 'All done' : `${done} of ${total} done`}</p>
    </div>
  );
}

/** The confirmed moment once per booking on this device: the first time the renter sees the booking confirmed (staff
 *  confirmed it, or it was paid elsewhere), not on every visit. Stored per device; a browser that keeps nothing simply
 *  plays it on that one visit. */
/** silent: only noted as seen (the pay page's own moment just played). */
export function ConfirmedOnce({ booking, silent }: { booking: string; silent?: boolean }) {
  const done = useRef(false);
  useEffect(() => {
    if (done.current) return;
    done.current = true;
    const key = `cc-confirmed-${booking}`;
    try { if (localStorage.getItem(key)) return; localStorage.setItem(key, '1'); } catch { return; }
    if (!silent) playMoment('confirmed');
  }, [booking, silent]);
  return null;
}
