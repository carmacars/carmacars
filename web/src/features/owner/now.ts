import type { OwnerMonthToDate } from './types.ts';

// The owner home's first figures (r27 portals, the owner's ask: "Earned $X this month, 2 cars out, next payout Nov 10"):
// what the owner earned this month and the line on the cars out. Pure: the home renders it, the unit tests check it.

/** What the owner earned this month: the approved statement's payout, else the month so far (net earnings, provisional). */
export function earnedThisMonth(m: OwnerMonthToDate | null): { cents: number | null; final: boolean } {
  if (!m) return { cents: null, final: false };
  if (m.final) return { cents: m.payout_cents ?? null, final: true };
  return { cents: m.totals ? m.totals.net_earnings_cents : null, final: false };
}

/** The line under "Hello": how many cars are out right now (the figures beside it carry the money). */
export function carsOutLine(onRent: number, enrolled: number): string {
  if (!enrolled) return 'Your cars appear here as they join.';
  if (!onRent) return enrolled === 1 ? 'Your car is not out right now.' : `None of your ${enrolled} cars are out right now.`;
  return `${onRent} of ${enrolled} ${enrolled === 1 ? 'car' : 'cars'} out right now.`;
}
