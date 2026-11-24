// The owner's Bookings page (r48 ops, docs/changes/2026-11-20-r48-ops-screens.md): every booking in one of three places
// (on a trip now, coming up, past), filtered by car, with the money of each said plainly and a timeline of the weeks
// around today. Display only: what an owner may see of a booking is decided by the database (0156, owner_view) and read
// through viewOf; nothing here shows an amount the database left out. Pure, for the unit tests.
import type { OwnerBooking } from './types.ts';
import { viewOf } from './insights.ts';
import { money } from '../../lib/format.ts';

export type Bucket = 'trip' | 'upcoming' | 'past';
export const BUCKETS: Array<[Bucket, string]> = [['trip', 'On a trip'], ['upcoming', 'Upcoming'], ['past', 'Past']];
const ENDED = new Set(['returned', 'closed', 'cancelled', 'no_show', 'declined', 'expired']);
const DAY = 86_400_000;

/** Where a booking belongs now: out with a renter, still to come, or over (returned, closed, cancelled, or its dates passed). */
export function bucketOf(b: Pick<OwnerBooking, 'status' | 'pickup_at' | 'return_at' | 'presumed_out'>, now: number): Bucket {
  if (ENDED.has(b.status)) return 'past';
  const s = Date.parse(b.pickup_at), e = Date.parse(b.return_at);
  if (b.status === 'on_rent' || b.presumed_out) return 'trip';   // r50: pickup not recorded, the car presumed out
  if (e <= now) return 'past';
  if (b.status === 'confirmed' && s <= now) return 'trip';
  return 'upcoming';
}
export interface Sorted { trip: OwnerBooking[]; upcoming: OwnerBooking[]; past: OwnerBooking[] }
/** The three lists: trips by the return that comes first, upcoming by the pickup that comes first, past newest first. */
export function sortBookings(list: OwnerBooking[], now: number, car?: string | null): Sorted {
  const out: Sorted = { trip: [], upcoming: [], past: [] };
  for (const b of list) if (!car || b.vehicle_id === car) out[bucketOf(b, now)].push(b);
  out.trip.sort((a, b) => a.return_at.localeCompare(b.return_at));
  out.upcoming.sort((a, b) => a.pickup_at.localeCompare(b.pickup_at));
  out.past.sort((a, b) => b.return_at.localeCompare(a.return_at));
  return out;
}
/** The list to open on: a trip under way first, else what is coming, else the past. */
export const firstBucket = (s: Sorted): Bucket => (s.trip.length ? 'trip' : s.upcoming.length ? 'upcoming' : 'past');
export const bucketParam = (v: string | undefined): Bucket | null => (v === 'trip' || v === 'upcoming' || v === 'past' ? v : null);
/** The page's address with a list and a car chosen (the rental history keeps its own ?car= and page). */
export function bookingsHref(o: { when?: Bucket | null; car?: string | null }): string {
  const p = new URLSearchParams({ tab: 'bookings' });
  if (o.when) p.set('when', o.when);
  if (o.car) p.set('car', o.car);
  return `/owner/vehicles?${p.toString()}`;
}

export type MoneyKind = 'amount' | 'statement' | 'own' | 'none';
export interface BookingMoney { kind: MoneyKind; cents: number | null; label: string; note: string }
/** What the page says about a booking's money, by what the owner may see (0156):
 *  full: the rental charge (before tax); booked: no amount yet, it comes with the approved statement; unavailable: nothing,
 *  the dates are not part of the owner's revenue; the owner's own booking: no charge. */
export function bookingMoney(b: Pick<OwnerBooking, 'owner_view' | 'rental_charge_cents' | 'booking_type' | 'status' | 'on_statement_cents' | 'on_statement_days' | 'rental_days'>): BookingMoney {
  const v = viewOf(b);
  if (v === 'unavailable') return { kind: 'none', cents: null, label: 'Unavailable', note: 'Not part of your revenue' };
  if (b.booking_type === 'owner') return { kind: 'own', cents: null, label: 'Your booking', note: 'Your own use: no charge' };
  if (v === 'booked' || b.rental_charge_cents === null) return { kind: 'statement', cents: null, label: 'Booked', note: 'The amount comes with your approved statement' };
  if (['cancelled', 'no_show', 'declined', 'expired'].includes(b.status)) return { kind: 'amount', cents: b.rental_charge_cents, label: 'Rental charge', note: 'Before tax; cancelled, so your statement says what you keep' };
  return { kind: 'amount', cents: b.rental_charge_cents, label: 'Rental charge', note: statementSplit(b) };
}
/** r50 (3810): the agreed charge is for the whole rental; a long rental reaches the statements a part at a time. Stored
 *  values only, so the words are the same at every view. */
export function statementSplit(b: Pick<OwnerBooking, 'on_statement_cents' | 'on_statement_days' | 'rental_days'>): string {
  const on = b.on_statement_cents ?? 0, days = b.rental_days ?? 0, onDays = b.on_statement_days ?? 0;
  if (!on) return days > 0 ? `Before tax, for all ${days} day${days === 1 ? '' : 's'}; your share is on your statement` : 'Before tax; your share is on your statement';
  if (onDays && days && onDays < days) return `Before tax, for all ${days} days. On your statements so far: ${money(on, { cents: true })} for ${onDays} of ${days} days; the rest on later statements`;
  return `Before tax, for all ${days} days. On your statements: ${money(on, { cents: true })}`;
}
/** The money of a list added up: only the amounts the owner may see, and how many are still to come with a statement. */
export function bucketTotals(list: OwnerBooking[]): { bookings: number; days: number; cents: number; shown: number; onStatement: number } {
  let days = 0, cents = 0, shown = 0, onStatement = 0, bookings = 0;
  for (const b of list) {
    const m = bookingMoney(b);
    if (m.kind === 'none' || ['cancelled', 'no_show', 'declined', 'expired'].includes(b.status)) continue;
    bookings += 1; days += nights(b);
    if (m.kind === 'amount') { cents += m.cents ?? 0; shown += 1; } else if (m.kind === 'statement') onStatement += 1;
  }
  return { bookings, days, cents, shown, onStatement };
}
export const nights = (b: Pick<OwnerBooking, 'pickup_at' | 'return_at'>) => Math.max(1, Math.round((Date.parse(b.return_at) - Date.parse(b.pickup_at)) / DAY));

const STATUS: Record<string, string> = { on_rent: 'On rent now', confirmed: 'Confirmed', pending_payment: 'Booked, payment due', requested: 'Requested', offered: 'Offer sent', tentative: 'Tentative',
  returned: 'Returned', closed: 'Completed', cancelled: 'Cancelled', no_show: 'No show', declined: 'Declined', expired: 'Expired' };
export type Tone = 'live' | 'ready' | 'muted' | 'accent';
/** The status in the owner's words and its pill. */
export function statusOf(b: Pick<OwnerBooking, 'status' | 'owner_view' | 'rental_charge_cents' | 'presumed_out'>): { label: string; tone: Tone } {
  if (viewOf(b) === 'unavailable') return { label: 'Unavailable', tone: 'muted' };
  if (b.presumed_out) return { label: 'Pickup not recorded, car presumed out', tone: 'live' };
  const label = STATUS[b.status] ?? b.status.replace(/_/g, ' ');
  return { label, tone: b.status === 'on_rent' ? 'live' : ['confirmed', 'returned', 'closed'].includes(b.status) ? 'ready' : ['cancelled', 'no_show', 'declined', 'expired'].includes(b.status) ? 'muted' : 'accent' };
}

// ---------------------------------------------------------------- the timeline
export interface TlBar { id: string; left: number; width: number; kind: 'trip' | 'upcoming' | 'past' | 'own' | 'unavailable'; title: string; clippedStart: boolean; clippedEnd: boolean }
export interface TlRow { vehicle_id: string; name: string; bars: TlBar[] }
export interface Tl { from: number; days: number; today: number | null; weeks: Array<{ left: number; label: string }>; rows: TlRow[] }
const TZ = 'America/Toronto';
const dayLabel = (ms: number) => new Intl.DateTimeFormat('en-CA', { timeZone: TZ, month: 'short', day: 'numeric' }).format(new Date(ms)).replace('.', '');
/**
 * The cars as rows over `days` days from `from`: each booking a bar by percent of the width (a booking that starts before
 * or ends after is cut at the edge and says so), today as a line. Cancelled bookings are left out; a car with nothing in
 * the window still gets its (empty) row, so a free car is seen as free.
 */
export function timeline(list: OwnerBooking[], cars: Array<{ vehicle_id: string; name: string }>, from: number, days: number, now: number): Tl {
  const end = from + days * DAY, span = end - from;
  const pct = (ms: number) => Math.round(((ms - from) / span) * 10000) / 100;
  const rows = cars.map((c) => ({ vehicle_id: c.vehicle_id, name: c.name, bars: list
    .filter((b) => b.vehicle_id === c.vehicle_id && !['cancelled', 'no_show', 'declined', 'expired'].includes(b.status) && Date.parse(b.pickup_at) < end && Date.parse(b.return_at) > from)
    .sort((a, b) => a.pickup_at.localeCompare(b.pickup_at))
    .map((b): TlBar => {
      const s = Date.parse(b.pickup_at), e = Date.parse(b.return_at);
      const left = pct(Math.max(s, from)), right = pct(Math.min(e, end));
      const v = viewOf(b);
      return { id: b.booking_id, left, width: Math.max(1.2, Math.round((right - left) * 100) / 100), clippedStart: s < from, clippedEnd: e > end,
        kind: v === 'unavailable' ? 'unavailable' : b.booking_type === 'owner' ? 'own' : bucketOf(b, now),
        title: `${v === 'unavailable' ? 'Unavailable' : b.booking_number ?? 'Booking'}: ${dayLabel(s)} to ${dayLabel(e)}` };
    }) }));
  const weeks = Array.from({ length: Math.ceil(days / 7) }, (_, i) => ({ left: pct(from + i * 7 * DAY), label: dayLabel(from + i * 7 * DAY) }));
  return { from, days, today: now >= from && now < end ? pct(now) : null, weeks, rows };
}
/** The window a list is drawn over: the six weeks from the start of today (on a trip, upcoming) or the six weeks before. */
export function windowFor(bucket: Bucket, todayStart: number, days = 42): { from: number; days: number } {
  return bucket === 'past' ? { from: todayStart - (days - 1) * DAY, days } : { from: todayStart - 2 * DAY, days };
}
