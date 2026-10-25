// What the renter portal's trip pages show, worked out from what the loaders already read (no new rule, no money computed:
// every amount is one the database stored). Pure, so src/features/portal/trip-model.test.ts covers it.
import { span } from '../../components/portal-ui/time.ts';

type Status = 'requested' | 'offered' | 'pending_payment' | 'confirmed' | 'on_rent' | 'returned' | 'closed' | 'cancelled' | 'expired' | 'declined';
const TZ = 'America/Toronto';

/** "Sun 7 PM", "Sun 7:30 PM"; with the date when it is more than six days away or in the past ("Sun, Nov 2, 7 PM"). */
export function shortWhen(iso: string, now = Date.now()): string {
  const d = new Date(iso);
  const far = d.getTime() - now > 6 * 86400e3 || d.getTime() < now - 86400e3;
  const day = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, weekday: 'short', ...(far ? { month: 'short', day: 'numeric' } : {}) }).format(d).replace(/\./g, '');
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hour12: true }).formatToParts(d);
  const h = parts.find((p) => p.type === 'hour')?.value ?? '';
  const m = parts.find((p) => p.type === 'minute')?.value ?? '00';
  const ap = (parts.find((p) => p.type === 'dayPeriod')?.value ?? '').toUpperCase();
  return `${day}${far ? ',' : ''} ${h}${m === '00' ? '' : `:${m}`} ${ap}`.replace(/\s+/g, ' ').trim();
}

export interface Clock { label: string; before: string; after: string; until: string; initial: string; late: boolean }
/** The trip's clock: "Pickup in 2 days 4 h" before pickup, "Return in 1 day 3 h" on rent (with "Return by Sun 7 PM"). */
export function tripClock(b: { status: Status; pickup_at: string; return_at: string; handed_over_at?: string | null }, now = Date.now()): Clock | null {
  const live = ['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status) && !b.handed_over_at;
  if (live) {
    const left = new Date(b.pickup_at).getTime() - now;
    return { label: `Pickup ${shortWhen(b.pickup_at, now)}`, before: 'Pickup in', after: 'Pickup was {t} ago', until: b.pickup_at,
      initial: left > 0 ? `Pickup in ${span(left)}` : `Pickup was ${span(left)} ago`, late: false };
  }
  if (b.status === 'on_rent') {
    const left = new Date(b.return_at).getTime() - now;
    return { label: `Return by ${shortWhen(b.return_at, now)}`, before: 'Return in', after: 'Return was due {t} ago', until: b.return_at,
      initial: left > 0 ? `Return in ${span(left)}` : `Return was due ${span(left)} ago`, late: left <= 0 };
  }
  return null;
}

/** A Google Maps search link for a place in words (an address or a named place); none for an empty place. */
export function mapLink(place: string | null | undefined): string | null {
  const q = (place ?? '').trim();
  return q ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(q)}` : null;
}

interface Pay { purpose: string; kind: string; status: string; amount_cents: number; card_last4: string | null; processed_at: string | null; created_at: string }
interface Refund { id: string; amount_cents: number; status: string; created_at: string }
interface Ext { id: string; status: string; total_cents: number | null; paid_at: string | null; new_return_at: string }
interface Addon { after_booking: boolean; paid: boolean; status: string; amount_cents: number | null; hst_cents: number | null }
interface Change { status: string; total_difference_cents: number | null }
export interface MoneyInput {
  status: Status; renter_due_at_booking_cents: number; deposit_cents: number; link_due?: boolean; signed: boolean;
  payments: Pay[]; refunds: Refund[]; extensions: Ext[]; addons: Addon[]; changes: Change[];
}
export interface Part { key: string; label: string; cents: number; state: 'paid' | 'owing' | 'held' | 'refunded' | 'info'; note?: string; sub?: string; cta?: string }

const PURPOSE: Record<string, string> = { booking_total: 'Rental', extension: 'Extension', addon: 'Add-ons', post_rental: 'Charges after the trip', toll_ticket: 'Tolls and tickets',
  damage: 'Damage', deductible: 'Deductible', other: 'Other', deposit: 'Deposit' };
export const purposeLabel = (p: string) => PURPOSE[p] ?? p.replace(/_/g, ' ');

/** Paid and owing, by part, from the booking's payments, refunds, extensions, add-ons and changes as stored. */
export function moneyParts(m: MoneyInput): { parts: Part[]; paidCents: number; owingCents: number } {
  const parts: Part[] = [];
  const paidBy = new Map<string, { cents: number; last4: string | null }>();
  for (const p of m.payments) {
    if (p.purpose === 'deposit') continue;
    if (p.status !== 'succeeded' || !['charge', 'capture'].includes(p.kind)) continue;
    const cur = paidBy.get(p.purpose) ?? { cents: 0, last4: null };
    paidBy.set(p.purpose, { cents: cur.cents + p.amount_cents, last4: p.card_last4 ?? cur.last4 });
  }
  for (const [purpose, v] of paidBy) parts.push({ key: `paid-${purpose}`, label: purposeLabel(purpose), cents: v.cents, state: 'paid', note: v.last4 ? `card ending ${v.last4}` : undefined });
  const dep = m.payments.find((p) => p.purpose === 'deposit' && ['authorized', 'succeeded'].includes(p.status) && p.kind !== 'release' && p.kind !== 'refund');
  if (dep) parts.push({ key: 'deposit', label: 'Deposit', cents: dep.amount_cents, state: 'held', note: 'refundable, released after the return' });
  const refunded = m.refunds.filter((r) => r.status === 'paid').reduce((s, r) => s + r.amount_cents, 0);
  if (refunded > 0) parts.push({ key: 'refunds', label: 'Refunded to you', cents: refunded, state: 'refunded' });

  // what is open: only what the renter can act on, each with where to do it
  if (m.status === 'pending_payment' || m.link_due) parts.push({ key: 'owe-booking', label: 'Rental', cents: m.renter_due_at_booking_cents, state: 'owing', sub: m.signed ? 'pay' : 'sign', cta: m.signed ? 'Pay now' : 'Sign, then pay' });
  for (const e of m.extensions) if (e.status === 'approved' && !e.paid_at && (e.total_cents ?? 0) > 0) parts.push({ key: `owe-ext-${e.id}`, label: 'Extension', cents: e.total_cents ?? 0, state: 'owing', sub: 'extend', cta: 'Pay for the extension' });
  const addonOpen = m.addons.filter((a) => a.after_booking && !a.paid && a.status === 'confirmed').reduce((s, a) => s + (a.amount_cents ?? 0) + (a.hst_cents ?? 0), 0);
  if (addonOpen > 0) parts.push({ key: 'owe-addons', label: 'Add-ons', cents: addonOpen, state: 'owing', sub: 'addons/pay', cta: 'Pay for your add-ons' });
  const chg = m.changes.find((c) => c.status === 'approved' && (c.total_difference_cents ?? 0) > 0);
  if (chg) parts.push({ key: 'owe-change', label: 'Date change', cents: chg.total_difference_cents ?? 0, state: 'owing', sub: 'change', cta: 'Review and sign' });
  if (m.status === 'offered') parts.push({ key: 'due-offer', label: 'Due when you confirm', cents: m.renter_due_at_booking_cents, state: 'info', note: 'after you approve and sign', sub: 'offer', cta: 'Review offer' });

  const paidCents = parts.filter((p) => p.state === 'paid').reduce((s, p) => s + p.cents, 0);
  const owingCents = parts.filter((p) => p.state === 'owing').reduce((s, p) => s + p.cents, 0);
  return { parts, paidCents, owingCents };
}
