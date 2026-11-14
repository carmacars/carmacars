// The owner portal's Rental history (r44, migration 2830): every rental on the owner's cars that they may see, read from
// public.owner_portal_rental_history (server only, the service role and the owner's user id). Display only: the earnings
// are what the owner's approved statements carried for each rental; nothing here bills, splits or pays.
import { clockTo, torontoAt } from '../../lib/clock.ts';
import { money } from '../../lib/format.ts';

export type HistoryState = 'upcoming' | 'on_rent' | 'completed' | 'cancelled_kept';
export interface HistoryRow {
  booking_id: string; booking_number: string | null; vehicle_id: string; car: string | null; plate: string | null;
  pickup_at: string; return_at: string; days: number; state: HistoryState;
  /** the rental lines of the owner's approved statements for this rental; null: not yet on a statement */
  earned_cents: number | null;
  /** part of a long rental is on a statement; the rest comes on a later one */
  more_to_come: boolean;
}
export interface HistoryCar { vehicle_id: string; name: string | null; plate: string | null }
export interface RentalHistory {
  count: number; days: number; earned_cents: number; not_on_statement: number;
  upcoming: number; on_rent: number; completed: number; cancelled_kept: number;
  offset: number; limit: number; newest_first: boolean; car: string | null; cars: HistoryCar[]; rows: HistoryRow[];
}

export const HISTORY_PAGE = 50;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface HistoryQuery { car: string | null; newest: boolean; page: number }
/** The list's query from the page address: ?car= (a car id), ?order=newest, ?page= (from 1). Anything else is ignored. */
export function historyQuery(sp: Record<string, string | undefined>): HistoryQuery {
  const car = sp.car && UUID.test(sp.car) ? sp.car.toLowerCase() : null;
  const n = Number.parseInt(sp.page ?? '', 10);
  return { car, newest: sp.order === 'newest', page: Number.isFinite(n) && n > 0 ? Math.min(n, 10_000) : 1 };
}
export const historyOffset = (q: HistoryQuery) => (q.page - 1) * HISTORY_PAGE;

/** The address of the list with some of its query changed (the Bookings tab, anchored at the list). */
export function historyHref(q: HistoryQuery, change: Partial<HistoryQuery> = {}): string {
  const n = { ...q, ...change };
  const p = new URLSearchParams({ tab: 'bookings' });
  if (n.car) p.set('car', n.car);
  if (n.newest) p.set('order', 'newest');
  if (n.page > 1) p.set('page', String(n.page));
  return `/owner/vehicles?${p.toString()}#rental-history`;
}

export const pageCount = (count: number) => Math.max(1, Math.ceil(Math.max(0, count) / HISTORY_PAGE));

const STATE: Record<HistoryState, string> = { upcoming: 'Upcoming', on_rent: 'On rent', completed: 'Completed', cancelled_kept: 'Cancelled, charge kept' };
export const stateLabel = (s: string) => STATE[s as HistoryState] ?? 'Upcoming';

const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** A pickup or return in Toronto time: "Oct 10, 2026, 10:00 a.m." (the time as clockTo writes it). */
export function torontoWhen(iso: string | null | undefined): string {
  if (!iso) return '';
  const p = torontoAt(iso);
  return p ? `${MON[p.month - 1]} ${p.day}, ${p.year}, ${clockTo(iso)}` : '';
}

/** The owner's earnings for a rental as their statements show them. */
export function earnedText(r: Pick<HistoryRow, 'earned_cents' | 'more_to_come'>): string {
  if (r.earned_cents === null || r.earned_cents === undefined) return 'Not yet on a statement';
  return `${money(r.earned_cents, { cents: true })}${r.more_to_come ? ', more on a later statement' : ''}`;
}

/** The car as the list names it: its name and plate. */
export const carText = (r: Pick<HistoryRow, 'car' | 'plate'>) => [r.car ?? 'Car', r.plate].filter(Boolean).join(' · ');

/** The line above the list: how many rentals, how many days and what the statements carried. */
export function summaryText(h: Pick<RentalHistory, 'count' | 'days' | 'earned_cents' | 'not_on_statement'>): string {
  if (!h.count) return 'No rentals yet.';
  const parts = [`${h.count} ${h.count === 1 ? 'rental' : 'rentals'}`, `${h.days} ${h.days === 1 ? 'day' : 'days'}`,
    `${money(h.earned_cents, { cents: true })} on your statements`];
  if (h.not_on_statement) parts.push(`${h.not_on_statement} not yet on a statement`);
  return parts.join(' · ');
}
