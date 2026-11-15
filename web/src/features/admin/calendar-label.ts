// The fleet calendar's bar words and day widths (r48, docs/changes/2026-11-14-r48-fleet-calendar.md). Node-tested.
import { OWNER_TRIP } from '../request-history/model.ts';

/** r48: day widths that leave room for a renter and a booking number on a two-day bar (month: a date and its weekday). */
export const VIEWS: Record<string, { days: number; dw: number; label: string }> = { week: { days: 7, dw: 132, label: 'Week' }, two: { days: 14, dw: 80, label: '2 weeks' }, month: { days: 31, dw: 44, label: 'Month' } };

export interface LabelEntry { type: string; booking_type: string | null; booking_number: string | null; renter: string | null; status: string | null; reason: string | null; note: string | null;
  placeholder?: boolean; blocks: boolean | null; insurer: string | null }
/** r48: a bar's words in two parts, who (or what) first and the booking number or note after, so a short bar still
 * shows the part that matters. The full words stay in the bar's title and label. */
export function barLabel(e: LabelEntry): { main: string; sub: string } {
  if (e.type === 'block') { const r = (e.reason ?? 'block').replace(/_/g, ' '); return { main: r.charAt(0).toUpperCase() + r.slice(1), sub: e.note ?? '' }; }
  if (e.type !== 'booking') return { main: '', sub: '' };
  if (e.booking_type === 'owner') return { main: OWNER_TRIP, sub: e.booking_number ?? '' };
  const state = e.status === 'requested' ? 'Request' : e.status === 'offered' ? 'Offer' : e.status === 'pending_payment' ? 'Payment due' : '';
  const flags = [state, e.placeholder ? 'placeholder' : e.blocks === false ? 'not blocking' : '', e.insurer ? 'insurer' : ''].filter(Boolean).join(', ');
  return { main: e.renter?.trim() || e.booking_number || state || 'Booking', sub: [e.renter?.trim() ? e.booking_number : '', flags].filter(Boolean).join(' · ') };
}

// ---------------------------------------------------------------- r48 follow-up: is the car free?
const DAY = 86_400_000;
/** Vehicle statuses that cannot be booked at all: the whole row is greyed out. */
export const OFF_STATUSES = ['onboarding', 'ready_to_list', 'out_of_service', 'exited', 'total_loss', 'declined'];
export interface Span { type: string; status: string | null; blocks: boolean | null; placeholder?: boolean; reason: string | null; starts_at: string; ends_at: string | null;
  renter: string | null; booking_number: string | null; booking_type: string | null;
  /** r48 (2961): an open offer's expiry, or the end of an accepted unpaid booking's hold */
  hold_until?: string | null }
/** What takes the car (the days it cannot be booked): a blocking booking, a block, a Turo trip. Requests, offers,
 * placeholders and non-blocking bookings do not. */
export const takes = (e: Span) => e.type === 'block' || e.type === 'turo_trip'
  || (e.type === 'booking' && !e.placeholder && e.blocks !== false && ['confirmed', 'on_rent', 'returned', 'closed'].includes(e.status ?? ''));
/** r48 (2961): when a soft hold ends (an open offer at its expiry, an accepted booking not paid yet at the end of its
 * hold), or null when the bar is not a soft hold. */
export const holdEnds = (e: Pick<Span, 'type' | 'status' | 'placeholder' | 'blocks'> & { hold_until?: string | null }): number | null =>
  e.type === 'booking' && !e.placeholder && e.blocks !== false && ['offered', 'pending_payment'].includes(e.status ?? '') && e.hold_until
    ? Date.parse(e.hold_until) : null;
/** A soft hold still running: drawn as a light hatched hold until it ends. Once it ends it never holds the car. */
export const holding = (e: Parameters<typeof holdEnds>[0], now: number) => { const t = holdEnds(e); return t !== null && t > now; };
/** An accepted booking waiting for payment blocks the car while its hold runs (an offer never does: the first to pay gets it). */
const heldNow = (e: Span, now: number) => e.status === 'pending_payment' && holding(e, now);
const clock = (ms: number) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
  .format(new Date(ms)).replace(/\./g, '').replace(/\s?a\s?m\b/i, ' am').replace(/\s?p\s?m\b/i, ' pm');
/** The words for a soft hold: "Held until Nov 15, 3:40 pm" while it runs, "Hold ended" after. */
export function holdWords(e: Parameters<typeof holdEnds>[0], now: number): string {
  const t = holdEnds(e);
  if (t === null) return '';
  if (t <= now) return e.status === 'offered' ? 'Offer expired' : 'Hold ended, not paid';
  return `${e.status === 'offered' ? 'Offer open until' : 'Held until'} ${clock(t)}`;
}

/** The tint behind a taken stretch. */
export const busyKind = (e: Span): 'out' | 'booked' | 'maint' | 'block' | 'turo' => e.type === 'turo_trip' ? 'turo'
  : e.type === 'block' ? (['service', 'repair', 'cleaning'].includes(e.reason ?? '') ? 'maint' : 'block') : e.status === 'on_rent' ? 'out' : 'booked';

const until = (iso: string | null) => iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' }).format(new Date(iso)).replace('.', '') : null;
export interface Avail { kind: 'free' | 'out' | 'busy' | 'off'; now: string; window: string; freeToday: boolean; freeAll: boolean; freeDays: number; days: number }
/**
 * A car's availability: right now (the badge), and over the days shown from today on (free days). `days` are the
 * calendar's [start, end) days; `todayStart` is today's midnight in Toronto.
 */
export function availability(v: { status: string; entries: Span[] }, now: number, days: Array<[number, number]>, todayStart: number): Avail {
  const ahead = days.filter(([, e]) => e > todayStart);
  if (OFF_STATUSES.includes(v.status)) return { kind: 'off', now: v.status === 'out_of_service' ? 'In shop' : 'Not bookable', window: '', freeToday: false, freeAll: false, freeDays: 0, days: ahead.length };
  // r48 (2961): an accepted booking not paid yet takes the car while its hold runs, then frees it
  const spans = v.entries.filter((e) => takes(e) || heldNow(e, now)).map((e) => ({ e, s: Date.parse(e.starts_at), f: e.ends_at ? Date.parse(e.ends_at) : Infinity }));
  const free = ([a, b]: [number, number]) => !spans.some((x) => x.s < b && x.f > a);
  const freeDays = ahead.filter(free).length;
  const freeToday = free([todayStart, todayStart + DAY]);
  const cur = spans.filter((x) => x.s <= now && x.f > now).sort((a, b) => b.f - a.f)[0]?.e;
  const window = !ahead.length ? '' : freeDays === ahead.length ? 'Free every day shown' : freeDays === 0 ? 'No free day shown' : `Free ${freeDays} of ${ahead.length} days`;
  const base = { window, freeToday, freeAll: ahead.length > 0 && freeDays === ahead.length, freeDays, days: ahead.length };
  if (!cur) return { kind: 'free', now: 'Available now', ...base };
  const to = until(cur.ends_at); const till = to ? ` until ${to}` : ' until further notice';
  if (cur.type === 'booking') {
    const who = cur.booking_type === 'owner' ? 'owner' : cur.renter?.trim() || cur.booking_number || 'a renter';
    if (cur.status === 'pending_payment') return { kind: 'busy', now: `${holdWords(cur, now)}: ${who}, not paid yet`, ...base };
    return { kind: 'out', now: `${cur.status === 'on_rent' ? 'Out now' : 'Booked now'}: ${who}${till}`, ...base };
  }
  if (cur.type === 'turo_trip') return { kind: 'busy', now: `On Turo${till}`, ...base };
  const r = (cur.reason ?? 'blocked').replace(/_/g, ' ');
  return { kind: 'busy', now: ['service', 'repair'].includes(cur.reason ?? '') ? `In shop${till}` : `${r.charAt(0).toUpperCase()}${r.slice(1)}${till}`, ...base };
}
