import 'server-only';
import { rpc } from '@/lib/db/repo';
import { payments, type Intent } from '@/integrations/payments';

// Gift cards bought on /gift-cards (migration 3600). One card PaymentIntent per order, captured at once (the card is not
// saved), no HST (it is charged on the rental the card later pays for). The server action (after the browser confirms)
// and the Stripe webhook both settle here; the database checks the intent's id, amount, currency and status against the
// order and makes the second call a replay. An intent the database refuses is refunded at once.
const SR = { role: 'service_role' as const };

export interface GiftOrder { id: string; amount_cents: number; kind: string; rental_text: string | null; buyer_email: string; buyer_name: string; stripe_intent_id: string | null }

/** The PaymentIntent of an order (one per order and amount: the idempotency key carries both). */
export async function giftIntent(o: GiftOrder, userId: string): Promise<Intent> {
  const p = await payments();
  const customerId = (await p.createCustomer({ email: o.buyer_email, name: o.buyer_name, idempotencyKey: `gift-buyer:${userId}` })).id;
  const i = await p.createGiftIntent({ giftCardId: o.id, amountCents: o.amount_cents, customerId, description: 'CarmaCars gift card', idempotencyKey: `gift:${o.id}:${o.amount_cents}` });
  await rpc('server_gift_order_intent', { p_id: o.id, p_intent: i.id }, SR);
  return i;
}

export type GiftSettle = { ok: true; id: string; view_token?: string; already?: boolean } | { ok: false; reason: string; message: string };

export async function settleGiftIntent(intentId: string): Promise<GiftSettle> {
  const p = await payments();
  const i = await p.retrieveIntent(intentId);
  const id = i.metadata.gift_card_id;
  if (!id || i.metadata.purpose !== 'gift_card') return { ok: false, reason: 'not_gift', message: 'This payment is not for a gift card.' };
  if (i.status !== 'succeeded') return { ok: false, reason: 'not_paid', message: i.lastError ?? 'The card was not approved. Nothing was charged.' };
  const card = i.card ? `${i.card.brand.charAt(0).toUpperCase()}${i.card.brand.slice(1)} ending ${i.card.last4}` : null;
  const r = (await rpc('server_gift_order_paid', { p_id: id, p: { id: i.id, amount_cents: i.amountCents, currency: i.currency, status: i.status, card_text: card } }, SR)) as unknown as
    { ok: boolean; reason?: string; message?: string; view_token?: string; already?: boolean };
  if (!r.ok) {
    // paid but refused (the amount changed, another order): the money goes back at once
    if (r.reason === 'amount_mismatch' || r.reason === 'other_payment' || r.reason === 'not_pending') {
      await p.refund({ paymentIntentId: i.id, chargeId: i.chargeId, amountCents: i.amountCents, idempotencyKey: `refund:${i.id}`, metadata: { gift_card_id: id, purpose: 'gift_card_refused' } }).catch(() => undefined);
    }
    return { ok: false, reason: r.reason ?? 'refused', message: r.message ?? 'The payment could not be recorded. It was refunded.' };
  }
  return { ok: true, id, view_token: r.view_token, already: r.already };
}
