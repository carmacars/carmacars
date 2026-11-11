import { money } from '../../lib/format.ts';

// Price limits (1205): a daily minimum and maximum in cents; null is no limit.
export type Limits = { min_daily_cents: number | null; max_daily_cents: number | null };
export type CarLimits = Limits & { min_from: 'car' | 'owner' | null; max_from: 'car' | 'owner' | null };
export type PriceLimitsData = {
  owner: Limits;
  cars: Array<{ vehicle_id: string; name: string; car: Limits; effective: CarLimits }>;
};

/** Dollars typed as cents: empty is null (no limit), anything not a positive amount is undefined. */
export function toCents(s: string): number | null | undefined {
  const t = s.replace(/[$,\s]/g, '');
  if (t === '') return null;
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return undefined;
  const c = Math.round(Number(t) * 100);
  return c > 0 ? c : undefined;
}

/** "$80 to $250 a day", "at least $80 a day", "at most $250 a day", or "no limits". */
export function limitsText(l: Limits): string {
  const a = l.min_daily_cents, b = l.max_daily_cents;
  if (a !== null && b !== null) return `${money(a)} to ${money(b)} a day`;
  if (a !== null) return `at least ${money(a)} a day`;
  if (b !== null) return `at most ${money(b)} a day`;
  return 'no limits';
}
