import type { PaymentsAdapter, PaymentRef } from './types';

// For local work and tests: remembers what was asked, keyed on the idempotency key like Stripe.
export function fakePayments(): PaymentsAdapter & { ledger: Map<string, PaymentRef & { kind: string; amountCents: number }> } {
  const ledger = new Map<string, PaymentRef & { kind: string; amountCents: number }>();
  const once = (key: string, kind: string, amountCents: number, status: string, url?: string) => {
    const hit = ledger.get(key);
    if (hit) return hit;
    const ref = { id: `fake_${kind}_${ledger.size + 1}`, status, url, kind, amountCents };
    ledger.set(key, ref);
    return ref;
  };
  return {
    name: 'fake', ledger,
    async createCheckout(r) { return once(r.idempotencyKey, 'checkout', r.amountCents, 'open', `${r.successUrl}${r.successUrl.includes('?') ? '&' : '?'}fake_checkout=1`); },
    async placeHold(r) { return once(r.idempotencyKey, 'hold', r.amountCents, 'requires_capture'); },
    async captureHold(id, amount, key) { return once(key, 'capture', amount, 'succeeded'); },
    async releaseHold(id, key) { return once(key, 'release', 0, 'canceled'); },
    async refund(id, amount, key) { return once(key, 'refund', amount, 'succeeded'); }
  };
}
