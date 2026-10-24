import 'server-only';
import { rpc } from '@/lib/db/repo';
import { payments } from '@/integrations/payments';

// The saved card of a rental staff added, charged when the renter signs (0053), whether they sign in their portal or on
// a staff member's device (0130). Not a server action: called by the signing actions only.
const SR = { role: 'service_role' as const };

interface AddedRentalCharge { booking_id: string; booking_number: string; amount_cents: number; customer_id: string | null; method_id: string | null; brand: string | null; last4: string | null }

/** The saved card of a rental staff added, charged when the renter signs (0053). Returns the decline message, or null. */
export async function chargeAddedRental(bookingId: string, number: string, userId: string): Promise<string | null> {
  const c = (await rpc('server_manual_rental_sign_charge', { p_booking: bookingId, p_by: userId }, SR)) as unknown as AddedRentalCharge | null;
  if (!c || !c.method_id || !c.customer_id || c.amount_cents <= 0) return null;
  try {
    const i = await (await payments()).chargeOffSession({ customerId: c.customer_id, paymentMethodId: c.method_id, amountCents: c.amount_cents,
      description: `Rental ${number}`, metadata: { booking_id: bookingId, purpose: 'booking_total', manual_rental: 'true', charged_on_signing: 'true' },
      idempotencyKey: `manual-rental:${bookingId}` });
    const ok = i.status === 'succeeded';
    await rpc('server_manual_rental_sign_charged', { p_booking: bookingId, p_by: userId, p: { ok, amount_cents: i.amountCents || c.amount_cents,
      error: ok ? null : i.lastError ?? 'The card was declined.', processor: { payment_id: i.id, charge_id: i.chargeId } } }, SR);
    return ok ? null : (i.lastError ?? 'The card was declined.');
  } catch (e) {
    const message = e instanceof Error ? e.message : 'The card could not be charged.';
    await rpc('server_manual_rental_sign_charged', { p_booking: bookingId, p_by: userId, p: { ok: false, amount_cents: c.amount_cents, error: message } }, SR).catch(() => undefined);
    return message;
  }
}

