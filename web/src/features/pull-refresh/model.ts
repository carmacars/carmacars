// r50 pull to refresh (PullToRefresh.tsx): the numbers, kept pure for the unit test.
export const PULL = { trigger: 72, max: 110, rest: 56, size: 40 } as const;

/** How far the indicator follows a finger dragged `dy` px down: one to one at first, then stiffer, never past max. */
export function pullDistance(dy: number): number {
  if (!(dy > 0)) return 0;
  const eased = dy <= 40 ? dy * 0.6 : 24 + (dy - 40) * 0.4;
  return Math.min(PULL.max, Math.round(eased));
}
