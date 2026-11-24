'use server';
import { cardOffMessage } from '@/server/card-provider';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import { payments } from '@/integrations/payments';
import type { ActionResult } from '@/features/forms/schemas';
import { bookingPath } from '@/features/portal/status';
import { findBooking, requireUser } from '@/server/portal/data';
import { newPayToken, payTokenHash } from '@/server/pay-token';
import type { TipOptions } from '@/features/money/tips';

// r48 part 2 (3053): the renter adds a tip by card, at checkout, on the receipt after the return or from the after-trip
// link. The database checks the booking is theirs and the amount (public.renter_tip_payreq); the tip is paid on Stripe's
// own form (/pay/<token>, captured at once) and split when the payment is recorded (server_payreq_settle).
const SR = { role: 'service_role' as const };
const fail = (message: string): { ok: false; code: string; message: string } => ({ ok: false, code: 'refused', message });

export async function tipOptions(number: string): Promise<ActionResult<TipOptions>> {
  try {
    const user = await requireUser(bookingPath(number));
    const b = await findBooking(user, number);
    if (!b) return fail('Booking not found');
    return { ok: true, data: (await rpc('server_tip_options', { p_booking: b.id }, SR)) as unknown as TipOptions };
  } catch (e) { return fail(e instanceof DbError ? e.message : 'Something went wrong. Please try again.'); }
}

export async function addTip(number: string, amountCents: number, percentBps: number | null, source: 'checkout' | 'receipt' | 'link'): Promise<ActionResult<{ url: string }>> {
  if (!Number.isInteger(amountCents) || amountCents < 100) return fail('A tip is $1 or more.');
  // hotfix 3650: card payments paused
  const off = await cardOffMessage('the tip'); if (off) return fail(off);
  try {
    const user = await requireUser(bookingPath(number));
    const b = await findBooking(user, number);
    if (!b) return fail('Booking not found');
    const token = newPayToken();
    const q = (await rpc('renter_tip_payreq', { p_booking: b.id, p_by: user.id, p_amount: amountCents, p_percent_bps: percentBps ?? 0, p_source: source, p_token_sha256: await payTokenHash(token) }, SR)) as unknown as
      { id: string; amount_cents: number; booking_id: string; booking_number: string; renter: { id: string; legal_name: string; email: string | null; customer_id: string | null } };
    const pay = await payments();
    const customerId = q.renter.customer_id ?? (await pay.createCustomer({ email: q.renter.email ?? '', name: q.renter.legal_name, renterId: q.renter.id, idempotencyKey: `customer:${q.renter.id}` })).id;
    const intent = await pay.createStaffIntent({ amountCents: q.amount_cents, customerId, capture: 'automatic', description: `CarmaCars booking ${q.booking_number}: a tip for the team`,
      metadata: { booking_id: q.booking_id, booking_number: q.booking_number, purpose: 'staff_request', payment_request_id: q.id, covers: 'tip' }, idempotencyKey: `payreq:${q.id}` });
    await rpc('server_payreq_attach', { p_id: q.id, p_intent: intent.id }, SR);
    revalidatePath(bookingPath(number));
    return { ok: true, data: { url: `/pay/${token}?back=${encodeURIComponent(bookingPath(number))}` } };
  } catch (e) { return fail(e instanceof DbError ? e.message : 'Something went wrong. Please try again.'); }
}
