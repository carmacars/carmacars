import 'server-only';
import { rpc } from '@/lib/db/repo';
import { payments, type Intent } from '@/integrations/payments';
import { isPayToken, payTokenHash } from '@/server/pay-token';

// A card request staff started (0129): its facts by the link's token, and what Stripe reports for it, read again from
// Stripe (the pay page's action and the webhook both end here; the database makes the second call a repeat).
const SR = { role: 'service_role' as const };

export interface PayLinkFacts { id: string; kind: 'charge' | 'hold' | 'setup'; covers: string; amount_cents: number; reason: string | null; status: string; expires_at: string;
  intent_id: string | null; booking_id: string; booking_number: string; vehicle_name: string; pickup_at: string; return_at: string; renter_name: string; hold_days: number }

export async function payLinkFacts(token: string): Promise<PayLinkFacts | null> {
  if (!isPayToken(token)) return null;
  return (await rpc('server_payreq_facts', { p_token_sha256: await payTokenHash(token) }, SR)) as unknown as PayLinkFacts | null;
}

export async function settlePayreq(id: string, intentId: string, kind: PayLinkFacts['kind']): Promise<{ ok: boolean; reason?: string }> {
  const p = await payments();
  const i: Intent = kind === 'setup' ? await p.retrieveCardSetup(intentId) : await p.retrieveIntent(intentId);
  const res = (await rpc('server_payreq_settle', { p_id: id, p_intent: {
    id: i.id, status: i.status, amount: i.amountCents, amount_capturable: i.amountCapturableCents, charge_id: i.chargeId, customer_id: i.customerId, method_id: i.paymentMethodId,
    error: i.lastError, card: i.card ? { brand: i.card.brand, last4: i.card.last4, exp_month: i.card.expMonth, exp_year: i.card.expYear, funding: i.card.funding, name: i.card.name, fingerprint: i.card.fingerprint, country: i.card.country ?? null } : null
  } }, SR)) as unknown as { ok: boolean; reason?: string; refund?: boolean };
  // another card on a card-coverage rental (0203): refused, and the money it took is given back at once
  if (res.refund && kind === 'charge' && i.status === 'succeeded') {
    await p.refund({ paymentIntentId: i.id, chargeId: i.chargeId, amountCents: i.amountCents, idempotencyKey: `same-card-refund:${id}`, metadata: { payment_request_id: id, reason: 'card_coverage_other_card' } }).catch(() => undefined);
  }
  return { ok: res.ok, reason: res.reason };
}

