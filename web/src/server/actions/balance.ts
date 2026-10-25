'use server';
import { redirect } from 'next/navigation';
import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { payments } from '@/integrations/payments';
import { newPayToken, payTokenHash } from '@/server/pay-token';

// The renter pays the balance of their booking from its page (migration 0132): a pay link for exactly what is open,
// opened at once on their own device (Stripe's form on /pay/<token>; the card number never reaches the site).
const SR = { role: 'service_role' as const };
interface Req { id: string; amount_cents: number; covers: string; booking_id: string; booking_number: string; renter: { id: string; legal_name: string; email: string | null; customer_id: string | null } }

export async function renterPayBalance(form: FormData): Promise<void> {
  const user = await currentUser();
  if (!user) redirect('/sign-in');
  const bookingId = String(form.get('booking') ?? '');
  const token = newPayToken();
  const q = (await rpc('renter_balance_payreq', { p_booking: bookingId, p_by: user.id, p_token_sha256: await payTokenHash(token) }, SR)) as unknown as Req;
  const pay = await payments();
  const customerId = q.renter.customer_id ?? (await pay.createCustomer({ email: q.renter.email ?? '', name: q.renter.legal_name, renterId: q.renter.id, idempotencyKey: `customer:${q.renter.id}` })).id;
  const intent = await pay.createStaffIntent({ amountCents: q.amount_cents, customerId, capture: 'automatic', description: `CarmaCars booking ${q.booking_number}: the balance`,
    metadata: { booking_id: q.booking_id, booking_number: q.booking_number, purpose: 'staff_request', payment_request_id: q.id, covers: 'balance' }, idempotencyKey: `payreq:${q.id}` });
  await rpc('server_payreq_attach', { p_id: q.id, p_intent: intent.id }, SR);
  redirect(`/pay/${token}?back=${encodeURIComponent(`/account/bookings/${q.booking_number}`)}`);
}
