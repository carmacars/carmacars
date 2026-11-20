// Unfinished rentals (0148; r48 ops): where a draft opens, its words, and how many show before "Show older". Pure.
export interface Draft { id: string; kind: 'rental' | 'offer'; title: string | null; quick: boolean; updated_at: string; by: string | null; mine: boolean; vehicle: string | null; held_until: string | null; missing: string[] }
export type DraftBase = '/admin' | '/staff' | '/staff/field';

export const draftHref = (r: Pick<Draft, 'id' | 'kind'>, base: DraftBase) =>
  r.kind === 'offer' ? `${base === '/staff/field' ? '/staff' : base}/offers/new?draft=${r.id}` : `${base === '/staff/field' ? '/staff/field/rentals' : `${base}/bookings`}/new?draft=${r.id}`;

const when = (iso: string) => new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
/** "You · Nov 20, 3:40 p.m. · 2024 Kia Forte": who saved it last, when, and the car when the title is the renter. */
export const draftLine = (r: Pick<Draft, 'mine' | 'by' | 'updated_at' | 'title' | 'vehicle'>) =>
  [r.mine ? 'You' : r.by ?? 'Someone', when(r.updated_at), r.title && r.vehicle && r.vehicle !== r.title ? r.vehicle : null].filter(Boolean).join(' · ');

/** At most `max` of what is missing as chips, the rest as a count (a draft just started misses a dozen things). */
export function draftMissing(r: Pick<Draft, 'missing'>, max = 5): { shown: string[]; more: number } {
  return { shown: r.missing.slice(0, max), more: Math.max(0, r.missing.length - max) };
}
/** The newest `max` up front, the rest behind "Show older" (Miller's law: a short list first). */
export function split<T>(rows: T[], max = 4): { first: T[]; rest: T[] } {
  return rows.length <= max + 1 ? { first: rows, rest: [] } : { first: rows.slice(0, max), rest: rows.slice(max) };
}
/** Who gets the section: an Admin, and Sales (Today and Bookings). Everyone else sees only their own drafts on the forms. */
export const seesUnfinished = (viewer: { role: 'admin' } | { role: 'staff'; fn: string | null }) => viewer.role === 'admin' || viewer.fn === 'sales';
