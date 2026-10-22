import 'server-only';
import { rpc } from '@/lib/db/repo';
import { payments, type Intent } from '@/integrations/payments';
import { intentOpened } from '@/server/portal/intent-log';

// Add-ons bought after booking with no card on file (migration 0079): the renter pays them by card on the booking's
// add-on pay page. One PaymentIntent for everything due, captured at once (not saved as the Card on File). The server
// action (after the browser confirms) and the Stripe webhook both settle here; the database makes the second a replay.
// A payment the database refuses (the amount changed, nothing due any more) is refunded at once.
const SR = { role: 'service_role' as const };

export interface UnpaidAddons {
  booking_id: string; booking_number: string; renter_id: string; legal_name: string; email: string; customer_id: string | null;
  total_cents: number; items: Array<{ booking_addon_id: string; name: string; amount_cents: number; hst_cents: number; total_cents: number }>;
}

export async function unpaidAddons(bookingId: string, by: string): Promise<UnpaidAddons> {
  return (await rpc('server_my_unpaid_addons', { p_booking: bookingId, p_by: by }, SR)) as unknown as UnpaidAddons;
}

/** The PaymentIntent for what is due now; a new amount gets a new intent (the idempotency key carries it). */
export async function addonIntent(u: UnpaidAddons, by: string): Promise<Intent> {
  const p = await payments();
  const customerId = u.customer_id ?? (await p.createCustomer({ email: u.email, name: u.legal_name, renterId: u.renter_id, idempotencyKey: `customer:${u.renter_id}` })).id;
  const keyOf = u.items.map((i) => i.booking_addon_id).sort().join('.');
  const i = await p.createAddonIntent({ bookingId: u.booking_id, bookingNumber: u.booking_number, amountCents: u.total_cents, customerId,
    description: `CarmaCars add-ons for ${u.booking_number}`, idempotencyKey: `addons:${u.booking_id}:${u.total_cents}:${keyOf}` });
  await intentOpened({ payment_id: i.id, purpose: 'addon_unpaid', booking_id: u.booking_id, amount_cents: i.amountCents, by });
  return i;
}

export type AddonSettle = { ok: true; bookingNumber: string | null } | { ok: false; reason: string; message: string };

export async function settleAddonIntent(intentId: string, by: string | null): Promise<AddonSettle> {
  const p = await payments();
  const i = await p.retrieveIntent(intentId);
  const bookingId = i.metadata.booking_id;
  if (!bookingId || i.metadata.purpose !== 'addon_unpaid') return { ok: false, reason: 'not_addons', message: 'This payment is not for add-ons.' };
  if (i.status !== 'succeeded') return { ok: false, reason: 'not_paid', message: i.lastError ?? 'The card was not approved. Nothing was charged.' };
  if (i.currency !== 'cad') return { ok: false, reason: 'currency', message: 'This payment is not in Canadian dollars.' };
  const r = (await rpc('server_addons_paid_online', { p_booking: bookingId, p_by: by as never,
    p_processor: { processor: 'stripe', payment_id: i.id, charge_id: i.chargeId }, p_amount_cents: i.amountCents }, SR)) as unknown as { ok: boolean; reason?: string; message?: string; action?: string };
  if (!r.ok) {
    if (r.action === 'refund_payment') {
      await p.refund({ paymentIntentId: i.id, chargeId: i.chargeId, amountCents: i.amountCents, idempotencyKey: `refund:${i.id}`, metadata: { booking_id: bookingId, purpose: 'addon_unpaid_refused' } }).catch(() => undefined);
    }
    return { ok: false, reason: r.reason ?? 'refused', message: r.message ?? 'The payment could not be recorded. It was refunded.' };
  }
  return { ok: true, bookingNumber: i.metadata.booking_number ?? null };
}
