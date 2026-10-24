import 'server-only';
import { rpc } from '@/lib/db/repo';
import { payments, type Intent } from '@/integrations/payments';
import { enqueuePdfJobs } from '@/server/pdf-jobs';
import { intentOpened } from './intent-log';

// Paying for a booking (02-booking-and-renter.md section 6 and section 2 step 9). The card is
// authorized first (manual capture); public.server_record_booking_payment then locks the car and
// confirms the booking, or refuses; only a confirmation is captured, a refusal is voided at once, so
// the renter who loses a race for the car is never charged. The server action (after the browser
// confirms) and the Stripe webhook both end here; the database makes the second call a replay.
const SR = { role: 'service_role' as const };

export interface PaymentFacts {
  booking_id: string; booking_number: string; status: string; booking_type: string; renter_due_at_booking_cents: number;
  offer_approved_version: number | null; current_offer_version: number | null; renter_id: string; renter_user_id: string;
  legal_name: string; email: string; agreement_signed: boolean; vehicle_free: boolean; customer_id: string | null;
  /** 0130: what of the renter's licence is still missing (empty when nothing, or the switch is off) */
  licence_missing?: string[];
}

export async function paymentFacts(bookingId: string): Promise<PaymentFacts> {
  return (await rpc('server_booking_payment_facts', { p_booking: bookingId }, SR)) as unknown as PaymentFacts;
}

export const PUSH_BACK = 'Someone else confirmed this car for these dates first. Nothing was charged: the hold on your card has been released. We are looking at alternatives and will send you a new offer.';
const REASONS: Record<string, string> = {
  vehicle_taken: PUSH_BACK,
  not_awaiting_payment: PUSH_BACK,
  vehicle_not_bookable: PUSH_BACK,
  offer_changed: 'This offer was updated. Nothing was charged. Review the new version.',
  agreement_not_signed: 'Sign the rental agreement first. Nothing was charged.',
  card_not_credit: 'Please use a credit card. Debit and prepaid cards cannot be used for a rental. Nothing was charged.',
  amount_mismatch: 'The amount changed. Nothing was charged. Reload the page.',
  already_confirmed: 'This booking is already confirmed.',
  name_mismatch: 'The card must be in the renter\'s name. Nothing was charged.'
};
export const reasonMessage = (r: string, fallback?: string) => REASONS[r] ?? fallback ?? 'We could not confirm the booking. Nothing was charged.';

const sameName = (a: string | null | undefined, b: string | null | undefined) => !!a && !!b && a.replace(/\s+/g, '').toLowerCase() === b.replace(/\s+/g, '').toLowerCase();

/** The PaymentIntent for the approved offer: one per offer version (the idempotency key). */
export async function bookingIntent(f: PaymentFacts): Promise<Intent> {
  const p = await payments();
  const customerId = f.customer_id ?? (await p.createCustomer({ email: f.email, name: f.legal_name, renterId: f.renter_id, idempotencyKey: `customer:${f.renter_id}` })).id;
  const i = await p.createBookingIntent({
    bookingId: f.booking_id, bookingNumber: f.booking_number, offerVersion: f.offer_approved_version ?? 0, amountCents: f.renter_due_at_booking_cents,
    customerId, description: `CarmaCars booking ${f.booking_number}`, idempotencyKey: `booking:${f.booking_id}:total:${f.offer_approved_version}`
  });
  // the card form opened, on record before anything is paid (0079)
  await intentOpened({ payment_id: i.id, purpose: 'booking_total', booking_id: f.booking_id, amount_cents: i.amountCents, by: f.renter_user_id });
  return i;
}

export type SettleResult = { ok: true; status: 'confirmed'; bookingNumber: string } | { ok: false; reason: string; message: string; bookingNumber?: string };

export async function settleIntent(intentId: string, by: string | null, eventId: string | null): Promise<SettleResult> {
  const p = await payments();
  const i = await p.retrieveIntent(intentId);
  const bookingId = i.metadata.booking_id;
  if (!bookingId || i.metadata.purpose !== 'booking_total') return { ok: false, reason: 'not_a_booking_payment', message: 'This payment is not for a booking.' };
  const f = await paymentFacts(bookingId);
  if (i.status === 'canceled') return { ok: false, reason: 'canceled', message: 'This payment was cancelled. Nothing was charged.', bookingNumber: f.booking_number };
  if (i.status !== 'requires_capture' && i.status !== 'succeeded') {
    return { ok: false, reason: 'not_authorized', message: i.lastError ?? 'The card was not approved. Nothing was charged.', bookingNumber: f.booking_number };
  }
  const void_ = async (reason: string, message?: string): Promise<SettleResult> => {
    if (i.status === 'requires_capture') await p.cancelIntent(i.id, `void:${i.id}`).catch(() => undefined);
    return { ok: false, reason, message: reasonMessage(reason, message), bookingNumber: f.booking_number };
  };
  // the processor's facts, checked against the database before anything is recorded (13-security.md section 8)
  if (i.currency !== 'cad' || i.amountCents !== f.renter_due_at_booking_cents) return void_('amount_mismatch');
  if (!sameName(i.card?.name ?? null, f.legal_name)) return void_('name_mismatch');
  const offerVersion = Number(i.metadata.offer_version);
  const res = (await rpc('server_record_booking_payment', {
    p_booking: bookingId,
    p_processor: { processor: 'stripe', payment_id: i.id, charge_id: i.chargeId, customer_id: i.customerId, method_id: i.paymentMethodId, fingerprint: i.card?.fingerprint ?? null },
    p_amount_cents: i.amountCents,
    p_offer_version: offerVersion,
    p_card: i.card ? { brand: i.card.brand, last4: i.card.last4, cardholder_name: i.card.name, exp_month: i.card.expMonth, exp_year: i.card.expYear, is_credit: i.card.funding === 'credit', funding: i.card.funding, country: i.card.country ?? null } : null,
    p_event_id: eventId ?? `action:${i.id}`,
    p_by: by ?? f.renter_user_id
  }, SR)) as unknown as { ok: boolean; reason?: string; message?: string; action?: string };
  if (!res.ok) return void_(res.reason ?? 'refused', res.message);
  if (i.status === 'requires_capture') {
    try {
      await p.captureIntent(i.id, `capture:${i.id}`);
    } catch (e) {
      await rpc('server_booking_payment_capture_failed', { p_booking: bookingId, p_processor: { processor: 'stripe', payment_id: i.id }, p_error: e instanceof Error ? e.message : String(e) }, SR).catch(() => undefined);
    }
  }
  // the signed copy: a background job in its own request (0077), so paying never waits for a PDF
  try { await enqueuePdfJobs([{ kind: 'renter_signed_copy', ref: bookingId, user_id: f.renter_user_id }]); } catch (e) { console.error('signed copy job', e); }
  return { ok: true, status: 'confirmed', bookingNumber: f.booking_number };
}
