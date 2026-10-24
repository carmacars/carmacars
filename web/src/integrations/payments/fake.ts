import type { DebitSetup, Intent, IntentCard, PaymentsAdapter, Refund } from './types';
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
  '5105105105105100': { brand: 'mastercard', funding: 'prepaid' },
  '4000000000000002': { brand: 'visa', funding: 'credit', decline: 'Your card was declined.' },
  '4000000000009995': { brand: 'visa', funding: 'credit', decline: 'Your card has insufficient funds.' }
};

interface Ledger { intents: Map<string, Intent>; keys: Map<string, string>; customers: Map<string, string>; auto: Set<string>; seq: number; refunds?: Map<string, Refund>; setups?: Map<string, DebitSetup> }
const g = globalThis as unknown as { __ccFakePayments?: Ledger };
const ledger = (): Ledger => {
  const l = (g.__ccFakePayments ??= { intents: new Map(), keys: new Map(), customers: new Map(), auto: new Set(), seq: 0 });
  l.auto ??= new Set();
  return l;
};

function blank(amountCents: number, metadata: Record<string, string>, customerId: string | null): Intent {
  const l = ledger();
  const id = `pi_fake_${++l.seq}_${Math.random().toString(36).slice(2, 8)}`;
  return { id, status: 'requires_payment_method', amountCents, amountCapturableCents: 0, currency: 'cad', clientSecret: `${id}_secret_fake`,
    metadata, customerId, paymentMethodId: null, chargeId: null, card: null, lastError: null, methodType: null, bank: null, mandateId: null };
}

export interface FakePayments extends PaymentsAdapter {
  /** What Stripe's frame does in the browser: confirms the intent with a card. */
  confirm(id: string, card: { number: string; name: string; expMonth: number; expYear: number }): Promise<Intent>;
  /** What Stripe's bank form does for a pre-authorized debit: the mandate is accepted and the debit is submitted (processing). */
  confirmDebit(id: string, bank: { name: string; institution: string; transit: string; account: string }): Promise<Intent>;
  /** What the bank answers days later. Account numbers ending 0000 are returned (insufficient funds). */
  /** code: what the bank says when it returns the debit (insufficient_funds by default, or account_closed and the like). */
  settleDebit(id: string, ok?: boolean, code?: string): Promise<Intent>;
  /** What Stripe's bank form does for a debit setup: the mandate is accepted and verified (succeeded). */
  confirmDebitSetup(id: string, bank: { name: string; institution: string; transit: string; account: string }): Promise<DebitSetup>;
  intents(): Intent[];
  /** Tests only: an intent made outside this process (the owner-debit Edge Function), so the webhook can read it. */
  register(i: Pick<Intent, 'id' | 'amountCents' | 'metadata'> & Partial<Intent>): Intent;
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
      const id = l.customers.get(r.idempotencyKey) ?? `cus_fake_${(r.renterId ?? r.ownerId ?? 'x').slice(0, 8)}`;
      l.customers.set(r.idempotencyKey, id);
      return { id };
    },
    async createDebitSetup(r) {
      const l = ledger();
      l.setups ??= new Map();
      const hit = l.keys.get(r.idempotencyKey);
      if (hit && l.setups.has(hit)) return { ...l.setups.get(hit)! };
      const id = `seti_fake_${++l.seq}_${Math.random().toString(36).slice(2, 8)}`;
      const x: DebitSetup = { id, status: 'requires_payment_method', clientSecret: `${id}_secret_fake`, customerId: r.customerId, paymentMethodId: null,
        mandateId: null, bank: null, metadata: { owner_id: r.ownerId, purpose: 'owner_debit_setup' }, lastError: null };
      l.setups.set(id, x); l.keys.set(r.idempotencyKey, id);
      return { ...x };
    },
    async retrieveDebitSetup(id) {
      const x = ledger().setups?.get(id);
      if (!x) throw new Error(`No such setup_intent: '${id}'`);
      return { ...x };
    },
    async confirmDebitSetup(id, b) {
      const x = ledger().setups?.get(id);
      if (!x) throw new Error(`No such setup_intent: '${id}'`);
      if (!/^\d{3}$/.test(b.institution) || !/^\d{5}$/.test(b.transit) || !/^\d{7,12}$/.test(b.account)) { x.lastError = 'Check the institution, transit and account numbers.'; return { ...x }; }
      x.bank = { name: 'Test Bank', last4: b.account.slice(-4) };
      x.paymentMethodId = `pm_fake_acss_${id.slice(10)}`;
      x.mandateId = `mandate_fake_${id.slice(10)}`;
      x.status = 'succeeded'; x.lastError = null;
      return { ...x };
    },
    async createBookingIntent(r) {
      return once(r.idempotencyKey, () => blank(r.amountCents,
        { booking_id: r.bookingId, booking_number: r.bookingNumber, offer_version: String(r.offerVersion), purpose: 'booking_total' }, r.customerId));
    },
    async createAddonIntent(r) {
      const i = once(r.idempotencyKey, () => blank(r.amountCents, { booking_id: r.bookingId, booking_number: r.bookingNumber, purpose: 'addon_unpaid' }, r.customerId));
      ledger().auto.add(i.id);
      return i;
    },
    async createInvoiceIntent(r) {
      const i = once(r.idempotencyKey, () => {
        const x = blank(r.amountCents, { owner_invoice_id: r.invoiceId, invoice_number: r.invoiceNumber, owner_id: r.ownerId, purpose: 'owner_invoice',
          recurring: r.method === 'acss_debit' && r.recurring === false ? 'false' : 'true' }, r.customerId);
        x.methodType = r.method;
        return x;
      });
      ledger().auto.add(i.id);
      return i;
    },
    async confirmDebit(id, b) {
      const i = get(id);
      if (i.methodType !== 'acss_debit' || (i.status !== 'requires_payment_method' && i.status !== 'requires_confirmation')) return { ...i };
      if (!/^\d{3}$/.test(b.institution) || !/^\d{5}$/.test(b.transit) || !/^\d{7,12}$/.test(b.account)) { i.lastError = 'Check the institution, transit and account numbers.'; return { ...i }; }
      i.bank = { name: 'Test Bank', last4: b.account.slice(-4) };
      i.paymentMethodId = `pm_fake_acss_${i.id.slice(8)}`;
      i.mandateId = `mandate_fake_${i.id.slice(8)}`;
      i.chargeId = `py_fake_${i.id.slice(8)}`;
      i.lastError = null;
      i.status = 'processing';
      return { ...i };
    },
    async settleDebit(id, ok, code) {
      const i = get(id);
      if (i.status !== 'processing') return { ...i };
      if (ok === false || (ok === undefined && i.bank?.last4 === '0000')) {
        const c = code ?? 'insufficient_funds';
        i.status = 'requires_payment_method'; i.lastErrorCode = c;
        i.lastError = c === 'insufficient_funds' ? 'The debit was returned by the bank: insufficient funds.' : `The debit was returned by the bank: ${c.replace(/_/g, ' ')}.`;
      } else i.status = 'succeeded';
      return { ...i };
    },
    async retrieveIntent(id) { return { ...get(id) }; },
    async confirm(id, c) {
      const i = get(id);
      if (i.status !== 'requires_payment_method' && i.status !== 'requires_confirmation') return { ...i };
      const number = c.number.replace(/\D/g, '');
      const known = FAKE_CARDS[number];
      if (!known) { i.lastError = 'Your card number is incorrect.'; return { ...i }; }
      if (known.decline) { i.lastError = known.decline; i.status = 'requires_payment_method'; return { ...i }; }
      i.card = { brand: known.brand, last4: number.slice(-4), expMonth: c.expMonth, expYear: c.expYear, funding: known.funding, name: c.name || null, fingerprint: `fp_${number.slice(-6)}`, country: 'US' };
      i.paymentMethodId = `pm_fake_${i.id.slice(8)}`;
      i.chargeId = `ch_fake_${i.id.slice(8)}`;
      i.lastError = null;
      i.methodType = 'card';
      if (ledger().auto.has(i.id)) { i.status = 'succeeded'; return { ...i }; }
      i.status = 'requires_capture';
      i.amountCapturableCents = i.amountCents;
      return { ...i };
    },
    async createStaffIntent(r) {
      const i = once(r.idempotencyKey, () => blank(r.amountCents, r.metadata, r.customerId));
      if (r.capture === 'automatic') ledger().auto.add(i.id);
      return i;
    },
    async createCardSetup(r) {
      const i = once(r.idempotencyKey, () => { const x = blank(0, { ...r.metadata, fake_setup: 'true' }, r.customerId); x.id = x.id.replace('pi_', 'seti_'); x.clientSecret = `${x.id}_secret_fake`; return x; });
      ledger().auto.add(i.id);
      return i;
    },
    async retrieveCardSetup(id) { return { ...get(id) }; },
    async captureIntent(id, _key, amountCents) {
      const i = get(id);
      if (i.status === 'requires_capture') { i.status = 'succeeded'; i.amountCapturableCents = 0; if (amountCents !== undefined) i.amountCents = amountCents; }
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
    async refund(r) {
      // a refund of a known intent checks the amount; an intent this process never saw (seeded data) is accepted
      const l = ledger();
      l.refunds ??= new Map();
      const hit = l.refunds.get(r.idempotencyKey);
      if (hit) return { ...hit };
      const i = r.paymentIntentId ? l.intents.get(r.paymentIntentId) : undefined;
      if (i && i.status !== 'succeeded') throw new Error(`This PaymentIntent cannot be refunded because it has a status of ${i.status}.`);
      if (i && r.amountCents > i.amountCents) throw new Error('Refund amount is greater than the charge.');
      const out: Refund = { id: `re_fake_${++l.seq}_${Math.random().toString(36).slice(2, 8)}`, status: 'succeeded', amountCents: r.amountCents, failureReason: null };
      l.refunds.set(r.idempotencyKey, out);
      return { ...out };
    },
    async verifyWebhook(rawBody, header, secret, now) {
      await verifyStripeSignature(rawBody, header, secret, now);
      const e = JSON.parse(rawBody) as { id: string; type: string; created: number; data?: { object?: Record<string, unknown> } };
      return { id: e.id, type: e.type, created: e.created, object: e.data?.object ?? {} };
    },
    intents: () => [...ledger().intents.values()],
    register(x) {
      const l = ledger();
      const i: Intent = { status: 'processing', amountCapturableCents: 0, currency: 'cad', clientSecret: null, customerId: null, paymentMethodId: null,
        chargeId: `py_fake_${x.id.slice(-8)}`, card: null, lastError: null, methodType: 'acss_debit', bank: { name: 'Test Bank', last4: '6789' }, mandateId: null, ...x };
      l.intents.set(i.id, i);
      return { ...i };
    }
  };
}
