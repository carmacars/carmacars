import type { Totals } from './types.ts';

/** "12 imported, 3 skipped, 1 failed": only what happened. */
export function summaryLines(t: Totals | null | undefined): string[] {
  const x = t ?? {};
  return ([[x.imported, 'imported'], [x.skipped, 'skipped'], [x.failed, 'failed'], [x.pending, 'to do']] as Array<[number | undefined, string]>)
    .filter(([n]) => (n ?? 0) > 0).map(([n, w]) => `${n} ${w}`);
}
