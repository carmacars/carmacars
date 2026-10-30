import type { Intent } from './types';
import { StripeError } from './stripe';
import type { Reader, TerminalAdapter } from './terminal';
import { fakePayments } from './fake';

// ---------------------------------------------------------------- the fake (local work, unit and end-to-end tests)
// The reader is simulated: processing presents the card at once. The card is a Visa credit ending 4242 unless a test sets
// another (globalThis.__ccFakeReaderCard), so a different card can be shown on a card-coverage rental.
interface FakeReaders { readers: Map<string, Reader>; seq: number }
const g = globalThis as unknown as { __ccFakeReaders?: FakeReaders; __ccFakeReaderCard?: { last4: string; brand: string; funding: 'credit' | 'debit' } };
const readers = (): FakeReaders => (g.__ccFakeReaders ??= { readers: new Map(), seq: 0 });
/** Tests only: the card the simulated reader reads next. */
export function setFakeReaderCard(c: { last4: string; brand: string; funding: 'credit' | 'debit' } | null) { g.__ccFakeReaderCard = c ?? undefined; }

export function fakeTerminal(): TerminalAdapter {
  const pay = fakePayments();
  return {
    name: 'fake',
    async createLocation() { return { id: `tml_fake_${++readers().seq}` }; },
    async registerReader(r) {
      if (!/^[a-z]+-[a-z]+-[a-z]+$/i.test(r.registrationCode)) throw new StripeError('The pairing code is not valid: type the three words the reader shows', 400, 'invalid_registration_code', null);
      const x: Reader = { id: `tmr_fake_${++readers().seq}`, label: r.label, deviceType: 'stripe_s700', serialNumber: `S700-FAKE-${readers().seq}`, status: 'online', location: r.location, action: null };
      readers().readers.set(x.id, x);
      return { ...x };
    },
    async retrieveReader(id) {
      const x = readers().readers.get(id) ?? { id, label: 'Front desk', deviceType: 'stripe_s700', serialNumber: null, status: 'online', location: null, action: null };
      return { ...x };
    },
    async createReaderIntent(r) {
      const i = pay.register({ id: `pi_fake_rdr_${++readers().seq}_${Math.random().toString(36).slice(2, 8)}`, amountCents: r.amountCents, metadata: r.metadata,
        status: 'requires_payment_method', chargeId: null, methodType: null, bank: null });
      return i;
    },
    async processOnReader(readerId, intentId) {
      const i = await pay.retrieveIntent(intentId);
      const c = g.__ccFakeReaderCard ?? { last4: '4242', brand: 'visa', funding: 'credit' as const };
      // the reader's intents are made with manual capture (0202): the card is read, then captured or cancelled
      pay.register({ ...i, status: 'requires_capture', amountCapturableCents: i.amountCents, chargeId: `ch_fake_${intentId.slice(8)}`,
        paymentMethodId: `pm_fake_cp_${intentId.slice(-6)}`, methodType: 'card_present', bank: null,
        card: { brand: c.brand, last4: c.last4, expMonth: 12, expYear: 2030, funding: c.funding, name: null, fingerprint: `fp_00${c.last4}`, country: 'CA' } });
      const x = { ...(await this.retrieveReader(readerId)), action: { type: 'process_payment_intent', status: 'succeeded', failureMessage: null } };
      readers().readers.set(readerId, x);
      return x;
    },
    async cancelReaderAction(readerId) {
      const x = { ...(await this.retrieveReader(readerId)), action: null };
      readers().readers.set(readerId, x);
      return x;
    },
    async lookupPayment(id) {
      const hit = pay.intents().find((i) => i.id === id || i.chargeId === id);
      if (hit) return { ...hit };
      // a payment made in the Dashboard that this process never saw: a test can name its outcome in the id
      // (pi_test_<amount>_<last4>_<succeeded|hold>), as Stripe's test mode would answer
      const m = /^(?:pi|ch)_test_(\d+)_(\d{4})_(succeeded|hold)(?:_[a-z0-9]+)?$/.exec(id);
      if (!m) throw new StripeError(`No such payment: '${id}'`, 404, 'resource_missing', null);
      const cents = Number(m[1]);
      return { id: id.replace(/^ch_/, 'pi_'), status: (m[3] === 'hold' ? 'requires_capture' : 'succeeded') as Intent['status'], amountCents: cents, amountCapturableCents: m[3] === 'hold' ? cents : 0,
        currency: 'cad', clientSecret: null, metadata: {}, customerId: null, paymentMethodId: null, chargeId: id.replace(/^pi_/, 'ch_'),
        card: { brand: 'visa', last4: m[2]!, expMonth: 12, expYear: 2030, funding: 'credit', name: null, fingerprint: `fp_00${m[2]!}`, country: 'CA' },
        lastError: null, methodType: 'card', bank: null, mandateId: null, captureBefore: null };
    }
  };
}
