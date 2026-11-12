import 'server-only';
import { rpc } from '@/lib/db/repo';
import { payments, type Intent } from '@/integrations/payments';
import { isPayToken, payTokenHash } from '@/server/pay-token';
import { CARD_NOT_CREDIT, holdAmountMessage, holdAmountStep, payCardStep } from '@/server/pay-card';

// A card request staff started (0129): its facts by the link's token, and what Stripe reports for it, read again from
// Stripe (the pay page's action and the webhook both end here; the database makes the second call a repeat).
const SR = { role: 'service_role' as const };

export interface PayLinkFacts { id: string; kind: 'charge' | 'hold' | 'setup'; covers: string; amount_cents: number; reason: string | null; status: string; expires_at: string;
  intent_id: string | null; booking_id: string; booking_number: string; vehicle_name: string; pickup_at: string; return_at: string; renter_name: string; hold_days: number }

export async function payLinkFacts(token: string): Promise<PayLinkFacts | null> {
  if (!isPayToken(token)) return null;
  return (await rpc('server_payreq_facts', { p_token_sha256: await payTokenHash(token) }, SR)) as unknown as PayLinkFacts | null;
}

/** 0213: the first opening of the link (the Money tab and the ready check say the renter opened it). */
export async function markPayLinkOpened(token: string): Promise<void> {
  if (!isPayToken(token)) return;
  await rpc('server_payreq_opened', { p_token_sha256: await payTokenHash(token) }, SR).catch(() => undefined);
}

/** r42: Program settings, Extended deposit holds: a deposit hold asks Stripe for up to about 30 days, if available. */
export async function extendedHolds(): Promise<boolean> {
  return Boolean(await rpc('server_deposit_extended_holds' as never, {} as never, SR).catch(() => false));
}

export async function settlePayreq(id: string, intentId: string, kind: PayLinkFacts['kind'], placed?: Intent | null): Promise<{ ok: boolean; reason?: string; message?: string }> {
  const p = await payments();
  let i: Intent = kind === 'setup' ? await p.retrieveCardSetup(intentId) : await p.retrieveIntent(intentId);
  // an older authorization (refused for its card and replaced), or the new one not used yet after a refusal (0213)
  if (kind !== 'setup' && (i.status === 'canceled' || i.status === 'requires_payment_method')) {
    if (await rpc('server_payreq_card_refused', { p_id: id }, SR).catch(() => false)) return { ok: false, reason: 'card_not_credit', message: CARD_NOT_CREDIT };
    if (i.status === 'canceled') return { ok: false, reason: 'canceled', message: 'This payment was cancelled. Nothing was charged.' };
  }
  // the same cards as the booking's pay page (0213): a debit or prepaid card is refused before anything is charged
  if (kind !== 'setup' && i.card && (i.status === 'requires_capture' || i.status === 'succeeded')) {
    const cardOk = (await rpc('server_payreq_card_ok', { p_id: id, p_card: { is_credit: i.card.funding === 'credit', funding: i.card.funding, brand: i.card.brand, last4: i.card.last4, country: i.card.country ?? null } as never }, SR)) as unknown as boolean;
    const step = payCardStep(kind, i.status, cardOk !== false);
    if (step === 'refuse') {
      if (i.status === 'requires_capture') await p.cancelIntent(i.id, `void:${i.id}`).catch(() => undefined);
      else await p.refund({ paymentIntentId: i.id, chargeId: i.chargeId, amountCents: i.amountCents, idempotencyKey: `not-credit-refund:${i.id}`, metadata: { payment_request_id: id, reason: 'card_not_credit' } }).catch(() => undefined);
      // a new authorization on the same link, for another card
      const fresh = await p.createStaffIntent({ amountCents: i.amountCents, customerId: i.customerId ?? '', capture: 'manual', extendedHold: kind === 'hold' && await extendedHolds(), description: `CarmaCars booking ${i.metadata.booking_number ?? ''}: ${kind === 'hold' ? 'deposit hold' : 'payment'}`.trim(),
        metadata: { ...i.metadata }, idempotencyKey: `payreq:${id}:after:${i.id}` });
      await rpc('server_payreq_attach', { p_id: id, p_intent: fresh.id }, SR);
      return { ok: false, reason: 'card_not_credit', message: CARD_NOT_CREDIT };
    }
    if (step === 'capture') i = await p.captureIntent(i.id, `capture:${i.id}`);
  }
  // 0262: a deposit hold is higher on a debit or prepaid card; a hold placed for the other kind of card's amount is voided
  // and the same link asks again for the right amount (never two holds)
  if (kind === 'hold' && i.card && i.status === 'requires_capture') {
    const need = (await rpc('server_payreq_hold_required', { p_id: id, p_card: { funding: i.card.funding } as never }, SR).catch(() => null)) as unknown as number | null;
    const step = holdAmountStep(i.amountCents, need);
    if (step.reask) {
      await p.cancelIntent(i.id, `void:${i.id}`).catch(() => undefined);
      const fresh = await p.createStaffIntent({ amountCents: step.amountCents, customerId: i.customerId ?? '', capture: 'manual', extendedHold: await extendedHolds(), description: `CarmaCars booking ${i.metadata.booking_number ?? ''}: deposit hold`.trim(),
        metadata: { ...i.metadata }, idempotencyKey: `payreq:${id}:amount:${i.id}` });
      await rpc('server_payreq_hold_reset', { p_id: id, p_intent: fresh.id, p_amount: step.amountCents }, SR);
      return { ok: false, reason: 'hold_amount', message: holdAmountMessage(i.card.funding, step.amountCents) };
    }
  }
  // a hold that cannot be recorded (the deposit was already taken another way, 0261): the authorization is voided, so
  // the renter never has two holds
  const settle = (args: { p_id: string; p_intent: never }) => rpc('server_payreq_settle', args, SR).catch(async (e: unknown) => {
    if (kind === 'hold' && i.status === 'requires_capture' && /already been taken/.test(e instanceof Error ? e.message : String(e))) await p.cancelIntent(i.id, `void:${i.id}`).catch(() => undefined);
    throw e;
  });
  const res = (await settle({ p_id: id, p_intent: {
    id: i.id, status: i.status, amount: i.amountCents, amount_capturable: i.amountCapturableCents, charge_id: i.chargeId, customer_id: i.customerId, method_id: i.paymentMethodId,
    error: i.lastError, card: i.card ? { brand: i.card.brand, last4: i.card.last4, exp_month: i.card.expMonth, exp_year: i.card.expYear, funding: i.card.funding, name: i.card.name, fingerprint: i.card.fingerprint, country: i.card.country ?? null } : null
  } } as never)) as unknown as { ok: boolean; reason?: string; refund?: boolean };
  // another card on a card-coverage rental (0203): refused, and the money it took is given back at once
  if (res.refund && kind === 'charge' && i.status === 'succeeded') {
    await p.refund({ paymentIntentId: i.id, chargeId: i.chargeId, amountCents: i.amountCents, idempotencyKey: `same-card-refund:${id}`, metadata: { payment_request_id: id, reason: 'card_coverage_other_card' } }).catch(() => undefined);
  }
  // 0541: the hold's real expiry is Stripe's capture_before (an extended authorization: up to about 30 days)
  if (res.ok && kind === 'hold' && i.status === 'requires_capture') {
    const before = i.captureBefore ?? placed?.captureBefore ?? null;
    if (before) await rpc('server_deposit_hold_expiry', { p_intent: i.id, p_capture_before: before, p_extended: Boolean(i.extendedAuth ?? placed?.extendedAuth) } as never, SR).catch(() => undefined);
  }
  return { ok: res.ok, reason: res.reason };
}

