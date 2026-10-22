import type { BookingStatus, BookingSummary, MyBooking } from './types';
import { when } from '@/features/agreement/model';
import { money } from '@/lib/format';

// What each status means to the renter and what to do next (02-booking-and-renter.md sections 2 and 7.1).
export const STATUS: Record<BookingStatus, { label: string; badge: string; blurb: string }> = {
  requested: { label: 'Requested', badge: 'badge--outline', blurb: 'We are checking the car and dates and will send you an offer.' },
  offered: { label: 'Offer ready', badge: 'badge--red', blurb: 'Your offer is ready. It does not hold the car until you approve, sign and pay.' },
  pending_payment: { label: 'Sign and pay', badge: 'badge--red', blurb: 'You approved the offer. Sign the agreement and pay to confirm the booking.' },
  confirmed: { label: 'Confirmed', badge: '', blurb: 'Your booking is confirmed and the car is reserved for you.' },
  on_rent: { label: 'On rent', badge: '', blurb: 'You have the car. Drive safely.' },
  returned: { label: 'Returned', badge: 'badge--grey', blurb: 'The car is back. Your final statement follows within a few days.' },
  closed: { label: 'Closed', badge: 'badge--grey', blurb: 'This rental is complete.' },
  cancelled: { label: 'Cancelled', badge: 'badge--grey', blurb: 'This booking was cancelled.' },
  expired: { label: 'Offer expired', badge: 'badge--grey', blurb: 'The offer expired before it was approved. Ask us to send it again.' },
  declined: { label: 'Declined', badge: 'badge--grey', blurb: 'This request was declined or withdrawn.' }
};

/** A rental added by hand by staff, confirmed but not signed yet (0051): the car is not released until it is. */
export const AWAITING_SIGNATURE = { label: 'Awaiting signature', blurb: 'Your rental is booked. Sign the rental agreement before pickup: the car is released only once it is signed.' };
export const awaitingSignature = (b: MyBooking | BookingSummary) => b.status === 'confirmed' && (b as { readiness?: { awaiting_signature?: boolean } | null }).readiness?.awaiting_signature === true;

export interface NextStep { title: string; note: string; href?: string; cta?: string; urgent?: boolean }

// with its car code (0079) when known, so the renter can quote it to staff
export const carName = (b: Pick<BookingSummary, 'vehicle_year' | 'vehicle_make' | 'vehicle_model'> & { car_code?: string | null }) =>
  `${b.vehicle_year} ${b.vehicle_make} ${b.vehicle_model}${b.car_code ? ` (car code ${b.car_code})` : ''}`;
export const bookingPath = (n: string, sub = '') => `/account/bookings/${encodeURIComponent(n)}${sub ? `/${sub}` : ''}`;

export function nextStep(b: BookingSummary | MyBooking, now = Date.now()): NextStep {
  const full = 'offers' in b ? b : null;
  const path = (s = '') => bookingPath(b.booking_number, s);
  switch (b.status) {
    case 'requested': {
      const q = full?.info_requests.find((x) => x.status === 'open');
      if (q) return { title: 'Answer our question', note: 'We need a little more information before we can send your offer.', href: `${path()}#questions`, cta: 'Answer now', urgent: true };
      return { title: 'Offer on its way', note: 'We are checking the car and dates. Your offer arrives by email and here.', href: path(), cta: 'View request' };
    }
    case 'offered': return { title: 'Approve your offer', note: b.offer_expires_at ? `Offer open until ${when(b.offer_expires_at)}.` : 'Review the price and terms.', href: path('offer'), cta: 'Review offer', urgent: true };
    case 'pending_payment': {
      const signed = full?.agreement?.status === 'signed' || full?.agreement?.status === 'completed';
      return signed
        ? { title: 'Pay to confirm', note: 'Your agreement is signed. Pay to confirm the booking.', href: path('pay'), cta: 'Pay now', urgent: true }
        : { title: 'Sign and pay', note: 'Sign the rental agreement, then pay to confirm.', href: path('sign'), cta: 'Sign agreement', urgent: true };
    }
    case 'confirmed': {
      // a rental staff added by hand (0046): confirmed before the agreement is signed
      if (full && (full as { added_by_staff?: boolean }).added_by_staff && full.agreement?.status !== 'completed' && full.agreement?.status !== 'signed') {
        return { title: 'Sign your rental agreement', note: 'Your rental is booked. Read and sign the agreement before pickup.', href: path('sign'), cta: 'Sign agreement', urgent: true };
      }
      const missing = full?.readiness?.missing ?? [];
      if (full && (missing.includes('identity') || missing.includes('coverage'))) return { title: 'Upload your licence', note: 'Licence photos, a selfie and proof of coverage are needed before pickup.', href: path('verify'), cta: 'Upload documents', urgent: true };
      const soon = new Date(b.pickup_at).getTime() - now < 36 * 3600e3;
      return { title: soon ? `Pickup ${when(b.pickup_at)}` : 'You are all set', note: soon ? 'Bring your original licence and the card you paid with.' : `Pickup ${when(b.pickup_at)}.`, href: path(), cta: 'Pickup details' };
    }
    case 'on_rent':
      // a rental staff added while already underway (0074): sign it, then pay online with a payment link
      if (full?.added_live && full.agreement?.status !== 'completed' && full.agreement?.status !== 'signed') {
        return { title: 'Sign your rental agreement', note: 'Your rental has started. Read and sign the agreement now.', href: path('sign'), cta: 'Sign agreement', urgent: true };
      }
      if (full?.link_due) return { title: 'Pay for your rental', note: 'Your agreement is signed. Pay the amount due online.', href: path('pay'), cta: 'Pay now', urgent: true };
      return { title: `Return by ${when(b.return_at)}`, note: 'Need longer? Ask for an extension before the return time.', href: path(), cta: 'Return details' };
    case 'returned': return { title: 'Car returned', note: 'Your final statement is on its way.', href: path(), cta: 'View booking' };
    case 'closed': return { title: 'Rental complete', note: 'Your statements and receipts are in your documents.', href: '/account/documents', cta: 'Documents' };
    case 'expired': return { title: 'Offer expired', note: 'Call or message us and we will send it again.', href: path(), cta: 'View booking' };
    default: return { title: STATUS[b.status].label, note: STATUS[b.status].blurb, href: path(), cta: 'View booking' };
  }
}

export function group(list: BookingSummary[], now = Date.now()) {
  const active = (b: BookingSummary) => ['requested', 'offered', 'pending_payment', 'confirmed'].includes(b.status);
  const current = list.filter((b) => b.status === 'on_rent');
  const upcoming = list.filter((b) => active(b)).sort((a, b) => a.pickup_at.localeCompare(b.pickup_at));
  const past = list.filter((b) => !active(b) && b.status !== 'on_rent');
  const nearest = current[0] ?? upcoming.find((b) => new Date(b.return_at).getTime() > now) ?? upcoming[0] ?? null;
  return { current, upcoming, past, nearest };
}

export interface Progress { label: string; done: boolean; href?: string }
export function progress(b: MyBooking): Progress[] {
  const after = (s: BookingStatus[]) => s.includes(b.status);
  const live: BookingStatus[] = ['confirmed', 'on_rent', 'returned', 'closed'];
  const path = (s = '') => bookingPath(b.booking_number, s);
  const renterSigned = !!b.agreement?.signers.find((s) => s.role === 'renter')?.signed_at;
  const paid = b.payments.some((p) => p.purpose === 'booking_total' && p.status === 'succeeded');
  const missing = b.readiness?.missing ?? ['identity', 'coverage'];
  return [
    { label: 'Request sent', done: true },
    { label: 'Offer approved', done: b.offer_approved_version !== null && after(['pending_payment', ...live]), href: b.status === 'offered' ? path('offer') : undefined },
    { label: 'Agreement signed', done: renterSigned || (after(live) && !awaitingSignature(b)), href: b.status === 'pending_payment' && !renterSigned ? path('sign') : undefined },
    { label: 'Paid', done: paid || after(live), href: b.status === 'pending_payment' && renterSigned ? path('pay') : undefined },
    { label: 'Drivers verified', done: after(live) && !missing.includes('identity'), href: b.status === 'confirmed' ? path('verify') : undefined },
    { label: 'Coverage confirmed', done: !!b.coverage_confirmed_at, href: b.status === 'confirmed' ? path('verify') : undefined },
    { label: 'Pickup', done: !!b.handed_over_at },
    { label: 'Return', done: !!b.checked_in_at },
    { label: 'Statement', done: b.status === 'closed' }
  ];
}

/** Changes from the request (or the previous offer version) to the current offer, as before and after. */
export function offerChanges(b: MyBooking): Array<{ label: string; before: string; after: string }> {
  const cur = b.offers.find((o) => o.version === b.current_offer_version) ?? b.offers[b.offers.length - 1];
  if (!cur) return [];
  const prev = b.offers.filter((o) => o.version < cur.version && o.status !== 'sent').pop();
  const req = b.request;
  const out: Array<{ label: string; before: string; after: string }> = [];
  const add = (label: string, before: string | null | undefined, after: string | null | undefined) => {
    if ((before ?? '') !== (after ?? '') && before) out.push({ label, before: before ?? '', after: after ?? '' });
  };
  const car = (v: { year: number; make: string; model: string } | null | undefined) => (v ? `${v.year} ${v.make} ${v.model}` : '');
  if (prev) {
    add('Car', car(prev.vehicle), car(cur.vehicle));
    add('Pickup', when(prev.pickup_at), when(cur.pickup_at));
    add('Return', when(prev.return_at), when(cur.return_at));
    add('Total', money(prev.total_cents), money(cur.total_cents));
    add('Deposit at pickup', money(prev.deposit_cents), money(cur.deposit_cents));
  } else {
    add('Car', car(req.vehicle), car(cur.vehicle));
    add('Pickup', req.pickup_at ? when(String(req.pickup_at)) : '', when(cur.pickup_at));
    add('Return', req.return_at ? when(String(req.return_at)) : '', when(cur.return_at));
    add('Pickup place', (req.pickup_place as string | null) ?? 'Our location', b.pickup_place ?? 'Our location');
    add('Return place', (req.return_place as string | null) ?? 'Our location', b.return_place ?? 'Our location');
  }
  return out;
}

