// What the owner portal's charts and figures show, worked out from the owner's own reads (owner_portal_home and
// owner_portal_bookings): their cars, their bookings, their invoices and their statements. Display only: nothing here
// bills, splits or pays; the statement stays the record of what is paid. No fleet-wide figure is read or shown.
import type { OwnerBooking, OwnerHome, OwnerVehicle, OwnerView } from './types.ts';

const TZ = 'America/Toronto';
const ymdFmt = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' });
/** The Toronto calendar date of an instant, YYYY-MM-DD. */
export const torontoDay = (iso: string | Date) => ymdFmt.format(typeof iso === 'string' ? new Date(iso) : iso);
const dayNum = (ymd: string) => Date.UTC(Number(ymd.slice(0, 4)), Number(ymd.slice(5, 7)) - 1, Number(ymd.slice(8, 10))) / 86_400_000;
const monthKey = (ymd: string) => ymd.slice(0, 7);
const addMonth = (key: string, n: number) => { const i = Number(key.slice(0, 4)) * 12 + Number(key.slice(5, 7)) - 1 + n; return `${Math.floor(i / 12)}-${String((i % 12) + 1).padStart(2, '0')}`; };
const daysIn = (key: string) => new Date(Date.UTC(Number(key.slice(0, 4)), Number(key.slice(5, 7)), 0)).getUTCDate();
export const monthLabel = (key: string, style: 'long' | 'short' = 'long') => new Intl.DateTimeFormat('en-CA', { month: style, ...(style === 'long' ? { year: 'numeric' } : {}), timeZone: 'UTC' }).format(new Date(`${key}-15T12:00:00Z`)).replace('.', '');

/** Bookings that are, or were, a rental of the car (not a request, an offer, a cancellation or a no-show). */
const RENTED = new Set(['confirmed', 'on_rent', 'returned', 'closed']);
const UPCOMING = new Set(['confirmed', 'on_rent', 'pending_payment']);

/** What the owner may see of a booking (0156; the database decides and leaves the amount out): full, booked (dates and
 *  status, the amount comes with the approved statement) or unavailable (the car is busy, nothing more). */
export const viewOf = (b: Pick<OwnerBooking, 'owner_view' | 'rental_charge_cents'>): OwnerView => b.owner_view ?? (b.rental_charge_cents === null ? 'booked' : 'full');
/** The amount cell of a booking: the owner's own booking, a hidden one ("Booked"), one not shown ("Unavailable"), or the money. */
export function amountText(b: Pick<OwnerBooking, 'owner_view' | 'rental_charge_cents' | 'booking_type'>, fmt: (cents: number) => string): string {
  const v = viewOf(b);
  if (v === 'unavailable') return 'Unavailable';
  if (b.booking_type === 'owner') return 'Your booking';
  if (v === 'booked' || b.rental_charge_cents === null) return 'Booked';
  return fmt(b.rental_charge_cents);
}

export type LiveKey = 'on_rent' | 'available' | 'service' | 'onboarding' | 'leaving' | 'off' | 'unavailable';
export interface Live { key: LiveKey; label: string; tone: 'live' | 'ready' | 'service' | 'accent' | 'muted' }

/** A car's status right now, in the owner's words: on rent, available or in service (and the states around them). */
export function liveStatus(v: OwnerVehicle, bookings: OwnerBooking[], now = new Date()): Live {
  if (v.onboarding_status && v.onboarding_status !== 'enrolled' || v.status === 'onboarding') return { key: 'onboarding', label: 'Onboarding', tone: 'accent' };
  const t = now.getTime();
  // a booking not shown to the owner that covers now: the car is unavailable (nothing more is said)
  const blockedNow = bookings.some((b) => b.vehicle_id === v.vehicle_id && viewOf(b) === 'unavailable' && !['cancelled', 'no_show', 'returned', 'closed'].includes(b.status)
    && new Date(b.pickup_at).getTime() <= t && new Date(b.return_at).getTime() > t);
  if (blockedNow) return { key: 'unavailable', label: 'Unavailable', tone: 'muted' };
  const onNow = bookings.some((b) => b.vehicle_id === v.vehicle_id && viewOf(b) !== 'unavailable' && (b.status === 'on_rent' || (RENTED.has(b.status) && b.status !== 'closed' && b.status !== 'returned' && new Date(b.pickup_at).getTime() <= t && new Date(b.return_at).getTime() > t)));
  if (v.status === 'on_rent' || onNow) return { key: 'on_rent', label: 'On rent', tone: 'live' };
  if (v.status === 'available' || v.status === 'ready_to_list') return { key: 'available', label: 'Available', tone: 'ready' };
  if (v.status === 'cleaning' || v.status === 'out_of_service') return { key: 'service', label: 'In service', tone: 'service' };
  if (v.status === 'exit_notice') return { key: 'leaving', label: 'Exit notice', tone: 'accent' };
  return { key: 'off', label: v.status === 'exited' ? 'Left the program' : v.status === 'total_loss' ? 'Total loss' : v.status.replace(/_/g, ' '), tone: 'muted' };
}

export interface MonthCar { vehicle_id: string; name: string; bookings: number; days: number; rental_cents: number; fees_cents: number }
export interface MonthStat {
  key: string; label: string; short: string; current: boolean;
  /** Rental charges before tax on the owner's cars, counted by rental day (a rental over two months counts in each). */
  rental_cents: number; days: number; bookings: number; fees_cents: number;
  /** Rentals of the month whose figures are not shown yet (0156): they come with the approved statement. */
  held: number;
  /** The payout of the month's approved statement, if there is one. */
  payout_cents: number | null; statement_id: string | null; statement_number: string | null;
  cars: MonthCar[];
}

/**
 * The last `count` months up to this one, per month and per car: bookings, days rented, rental charges (before tax, after
 * discounts, as owner_portal_bookings gives them), fees billed (the month's invoices) and the statement's payout.
 */
export function monthStats(home: Pick<OwnerHome, 'vehicles' | 'invoices' | 'statements'>, bookings: OwnerBooking[], today = torontoDay(new Date()), count = 6): MonthStat[] {
  const thisMonth = monthKey(today);
  const keys = Array.from({ length: count }, (_, i) => addMonth(thisMonth, i - count + 1));
  const cars = home.vehicles.filter((v) => !['declined'].includes(v.status));
  const out = keys.map((key) => ({ key, label: monthLabel(key), short: monthLabel(key, 'short'), current: key === thisMonth, rental_cents: 0, days: 0, bookings: 0, fees_cents: 0, held: 0,
    payout_cents: null as number | null, statement_id: null as string | null, statement_number: null as string | null,
    cars: cars.map((v) => ({ vehicle_id: v.vehicle_id, name: v.name, bookings: 0, days: 0, rental_cents: 0, fees_cents: 0 })) }));
  const at = new Map(out.map((m) => [m.key, m]));
  for (const b of bookings) {
    if (!RENTED.has(b.status) || b.booking_type === 'owner') continue;
    const view = viewOf(b);
    if (view === 'unavailable') continue;
    const a = torontoDay(b.pickup_at), z = torontoDay(b.return_at);
    const nights = Math.max(1, dayNum(z) - dayNum(a));
    for (const m of out) {
      const first = dayNum(`${m.key}-01`), last = first + daysIn(m.key); // [first, last)
      const s = Math.max(dayNum(a), first), e = Math.min(Math.max(dayNum(z), dayNum(a) + 1), last);
      if (e <= s) continue;
      // a hidden booking counts nowhere in the figures (not its days either): only that one is still to come
      if (view !== 'full' || b.rental_charge_cents === null) { m.held += 1; continue; }
      const d = e - s;
      const cents = Math.round((b.rental_charge_cents * d) / nights);
      const c = m.cars.find((x) => x.vehicle_id === b.vehicle_id);
      m.days += d; m.rental_cents += cents; m.bookings += 1;
      if (c) { c.days += d; c.rental_cents += cents; c.bookings += 1; }
    }
  }
  for (const i of home.invoices) {
    if (!i.period_month || ['void', 'draft'].includes(i.status) || i.kind === 'credit_note') continue;
    const m = at.get(i.period_month.slice(0, 7));
    if (!m) continue;
    m.fees_cents += i.fees_cents;
    const c = m.cars.find((x) => x.vehicle_id === i.vehicle_id);
    if (c) c.fees_cents += i.fees_cents;
  }
  for (const s of home.statements) {
    const m = at.get(s.statement_month.slice(0, 7));
    if (m) { m.payout_cents = (m.payout_cents ?? 0) + s.payout_cents; m.statement_id = s.id; m.statement_number = s.statement_number; }
  }
  return out;
}

/** The next payout: the approved statement not paid yet (its amount and date), else the next payout date alone. */
export function nextPayout(home: Pick<OwnerHome, 'statements' | 'next_payout_date'>, today = torontoDay(new Date())): { date: string; cents: number | null; statement_id: string | null } {
  const due = home.statements.filter((s) => s.status === 'approved' && s.payout_date >= today).sort((a, b) => a.payout_date.localeCompare(b.payout_date))[0];
  return due ? { date: due.payout_date, cents: due.payout_cents, statement_id: due.id } : { date: home.next_payout_date, cents: null, statement_id: null };
}

/** The bookings still to come or under way, soonest first. */
export function upcoming(bookings: OwnerBooking[], now = new Date(), limit = 6): OwnerBooking[] {
  const t = now.getTime();
  return bookings.filter((b) => UPCOMING.has(b.status) && new Date(b.return_at).getTime() > t).sort((a, b) => a.pickup_at.localeCompare(b.pickup_at)).slice(0, limit);
}

/** Days rented, bookings and rental charges of one car this month, for its card. */
export function carThisMonth(months: MonthStat[], vehicleId: string): MonthCar | null {
  return months.find((m) => m.current)?.cars.find((c) => c.vehicle_id === vehicleId) ?? null;
}
