// Quick date ranges (Release 27): Today, 7 days, 30 days, 90 days and Custom, as links whose dates travel in the address.
// Days are YYYY-MM-DD in Toronto, written by the page (it knows today). No imports; unit tested.

export const QUICK_RANGES = [{ key: 'today', label: 'Today', days: 1 }, { key: '7', label: '7 days', days: 7 }, { key: '30', label: '30 days', days: 30 }, { key: '90', label: '90 days', days: 90 }] as const;
export type QuickKey = (typeof QUICK_RANGES)[number]['key'] | 'custom';

const DAY = /^\d{4}-\d{2}-\d{2}$/;
/** A day plus n days (negative for before), as YYYY-MM-DD. */
export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
/** Today in Toronto as YYYY-MM-DD. */
export const torontoToday = (now = Date.now()) => new Date(now).toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });

/** The dates of a range ending today: Today is today to today; 7 days is the last seven days including today. */
export function rangeFor(days: number, today: string): { from: string; to: string } {
  return { from: addDays(today, -(Math.max(1, days) - 1)), to: today };
}
/** Which quick range the dates are: one of the four, "custom" for any other dates set, null when neither date is set. */
export function activeRange(from: string | null | undefined, to: string | null | undefined, today: string): QuickKey | null {
  const f = from && DAY.test(from) ? from : null, t = to && DAY.test(to) ? to : null;
  if (!f && !t) return null;
  for (const r of QUICK_RANGES) { const x = rangeFor(r.days, today); if (f === x.from && (t ?? today) === x.to) return r.key; }
  return 'custom';
}
/** The address of a range: `base` with the other parameters kept, the dates set, the cursor dropped. */
export function rangeHref(base: string, keep: Record<string, string | undefined>, range: { from: string; to: string }, keys: { from: string; to: string } = { from: 'from', to: 'to' }): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(keep)) if (v && k !== keys.from && k !== keys.to && k !== 'cursor') q.set(k, v);
  q.set(keys.from, range.from); q.set(keys.to, range.to);
  return `${base}?${q}`;
}
