// Traction on the investor deck and the portal (r50 hotfix 2, migration 5162): each measure of the business (CarmaCars:
// monthly active users of the website and of the app, days rented) as its last full month, the change on the month
// before and a 12-month trend. The same model for every Almash business (merch: items customized; phones: phones
// purchased): the labels and units come from the database. Pure.
//   node --test --experimental-strip-types src/features/deck/traction.test.ts
import { compact } from './search.ts';

export interface TractionMetric { code: string; label: string; unit: string; note: string | null; months: Array<{ month: string; value: number | string }> }
export interface DeckTraction { business: string; metrics: TractionMetric[] }

/** The month a figure is about, in words (2026-10-01: October 2026). */
export const monthWords = (m: string) => new Date(`${m.slice(0, 10)}T12:00:00Z`).toLocaleDateString('en-CA', { timeZone: 'UTC', month: 'long', year: 'numeric' });

/** The headline of a measure: the last full month (the month before `today`'s), its value, the change on the month before
 *  it, and the month in progress so far. Null when nothing is stored. */
export function headline(m: TractionMetric, today: string): { month: string; value: number; changePct: number | null; current: number | null } | null {
  const thisMonth = `${today.slice(0, 7)}-01`;
  const rows = m.months.map((x) => ({ month: x.month.slice(0, 10), value: Number(x.value) })).filter((x) => Number.isFinite(x.value)).sort((a, b) => a.month.localeCompare(b.month));
  const full = rows.filter((x) => x.month < thisMonth);
  const cur = rows.find((x) => x.month === thisMonth)?.value ?? null;
  const last = full.at(-1);
  if (!last) return cur === null ? null : { month: thisMonth, value: cur, changePct: null, current: null };
  const prev = full.at(-2);
  return { month: last.month, value: last.value, changePct: prev && prev.value > 0 ? Math.round((100 * (last.value - prev.value)) / prev.value) : null, current: cur };
}

/** The value as the deck writes it: people and items as whole numbers, days to one decimal under 100. */
export const figure = (v: number, unit: string) => (unit === 'days' && v < 100 && !Number.isInteger(v) ? v.toFixed(1) : compact(Math.round(v)));
export const change = (p: number | null) => (p === null ? '' : `${p >= 0 ? '+' : ''}${p}% on the month before`);
/** The bar heights (0 to 100) of the months. */
export const bars = (m: TractionMetric) => { const v = m.months.map((x) => Number(x.value) || 0); const max = Math.max(0, ...v); return v.map((x) => (max > 0 ? Math.round((100 * x) / max) : 0)); };
