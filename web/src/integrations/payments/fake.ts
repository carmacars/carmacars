import type { Intent, IntentCard, PaymentsAdapter } from './types';
import { verifyStripeSignature } from './signature';

// For local work and tests: a PaymentIntent ledger that behaves like Stripe's for the paths the app
// uses (manual capture, cancel, off-session charges, idempotency keys). It lives on globalThis so the
// server actions and the webhook route of one server process see the same intents.
// Stripe's test card numbers decide the outcome when the browser "confirms" in the fake card form.
export const FAKE_CARDS: Record<string, { brand: string; funding: IntentCard['funding']; decline?: string }> = {
  '4242424242424242': { brand: 'visa', funding: 'credit' },
  '5555555555554444': { brand: 'mastercard', funding: 'credit' },
  '378282246310005': { brand: 'amex', funding: 'credit' },
  '4000056655665556': { brand: 'visa', funding: 'debit' },
  '4000000000000002': { brand: 'visa', funding: 'credit', decline: 'Your card was declined.' },
  '4000000000009995': { brand: 'visa', funding: 'credit', decline: 'Your card has insufficient funds.' }
};

interface Ledger { intents: Map<string, Intent>; keys: Map<string, string>; customers: Map<string, string>; seq: number }
const g = globalThis as unknown as { __ccFakePayments?: Ledger };
const ledger = (): Ledger => (g.__ccFakePayments ??= { intents: new Map(), keys: new Map(), customers: new Map(), seq: 0 });

function blank(amountCents: number, metadata: Record<string, string>, customerId: string | null): Intent {
  const l = ledger();
  const id = `pi_fake_${++l.seq}_${Math.random().toString(36).slice(2, 8)}`;
  return { id, status: 'requires_payment_method', amountCents, amountCapturableCents: 0, currency: 'cad', clientSecret: `${id}_secret_fake`,
    metadata, customerId, paymentMethodId: null, chargeId: null, card: null, lastError: null };
}

export interface FakePayments extends PaymentsAdapter {
  /** What Stripe's frame does in the browser: confirms the intent with a card. */
  confirm(id: string, card: { number: string; name: string; expMonth: number; expYear: number }): Promise<Intent>;
  intents(): Intent[];
}

export function fakePayments(): FakePayments {
  const once = (key: string, make: () => Intent): Intent => {
    const l = ledger();
    const hit = l.keys.get(key);
    if (hit) return { ...l.intents.get(hit)! };
    const i = make();
    l.intents.set(i.id, i);
    l.keys.set(key, i.id);
    return { ...i };
  };
  const get = (id: string) => {
    const i = ledger().intents.get(id);
    if (!i) throw new Error(`No such payment_intent: '${id}'`);
    return i;
  };
  return {
    name: 'fake',
    async createCustomer(r) {
      const l = ledger();
      const id = l.customers.get(r.idempotencyKey) ?? `cus_fake_${r.renterId.slice(0, 8)}`;
      l.customers.set(r.idempotencyKey, id);
      return { id };
    },
    async createBookingIntent(r) {
      return once(r.idempotencyKey, () => blank(r.amountCents,
        { booking_id: r.bookingId, booking_number: r.bookingNumber, offer_version: String(r.offerVersion), purpose: 'booking_total' }, r.customerId));
    },
    async retrieveIntent(id) { return { ...get(id) }; },
    async confirm(id, c) {
      const i = get(id);
      if (i.status !== 'requires_payment_method' && i.status !== 'requires_confirmation') return { ...i };
      const number = c.number.replace(/\D/g, '');
      const known = FAKE_CARDS[number];
      if (!known) { i.lastError = 'Your card number is incorrect.'; return { ...i }; }
      if (known.decline) { i.lastError = known.decline; i.status = 'requires_payment_method'; return { ...i }; }
      i.card = { brand: known.brand, last4: number.slice(-4), expMonth: c.expMonth, expYear: c.expYear, funding: known.funding, name: c.name || null, fingerprint: `fp_${number.slice(-6)}` };
      i.paymentMethodId = `pm_fake_${i.id.slice(8)}`;
      i.chargeId = `ch_fake_${i.id.slice(8)}`;
      i.lastError = null;
      i.status = 'requires_capture';
      i.amountCapturableCents = i.amountCents;
      return { ...i };
    },
    async captureIntent(id) {
      const i = get(id);
      if (i.status === 'requires_capture') { i.status = 'succeeded'; i.amountCapturableCents = 0; }
      else if (i.status !== 'succeeded') throw new Error(`This PaymentIntent could not be captured because it has a status of ${i.status}.`);
      return { ...i };
    },
    async cancelIntent(id) {
      const i = get(id);
      if (i.status === 'succeeded') throw new Error('You cannot cancel this PaymentIntent because it has a status of succeeded.');
      i.status = 'canceled'; i.amountCapturableCents = 0;
      return { ...i };
    },
    async chargeOffSession(r) {
      return once(r.idempotencyKey, () => {
        const i = blank(r.amountCents, r.metadata, r.customerId);
        i.paymentMethodId = r.paymentMethodId; i.chargeId = `ch_fake_${i.id.slice(8)}`; i.status = 'succeeded';
        return i;
      });
    },
    async verifyWebhook(rawBody, header, secret, now) {
      await verifyStripeSignature(rawBody, header, secret, now);
      const e = JSON.parse(rawBody) as { id: string; type: string; created: number; data?: { object?: Record<string, unknown> } };
      return { id: e.id, type: e.type, created: e.created, object: e.data?.object ?? {} };
    },
    intents: () => [...ledger().intents.values()]
  };
}
