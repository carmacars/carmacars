'use client';
import { FdIcon } from '@/features/field/icons';
import type { Card } from './model';
import { AddonTicks, CleanCheck } from './Steps';

// On a pickup or return screen (r35 part X): the clean check (before the pickup, after the return) and the add-ons ticked as in the
// car, the same steps as the card on Today. The pickup is refused until every add-on is ticked or an Admin overrides (0930).
export function JobCardSteps({ c }: { c: Card }) {
  const clean = c.clean;
  const showClean = clean && !clean.done && (c.leg === 'pickup' || c.status === 'done' || c.status === 'in_progress');
  return (
    <>
      {clean?.done && <p className="fp-done" data-testid="clean-done"><FdIcon name="check" />Clean check done</p>}
      {showClean && <CleanCheck c={c} />}
      {c.leg === 'pickup' && (c.addons?.length ?? 0) > 0 && c.status !== 'done' && <AddonTicks addons={c.addons ?? []} />}
    </>
  );
}
