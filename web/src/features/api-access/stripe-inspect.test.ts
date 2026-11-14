// r47 (2896): the connector's Stripe reads, with a faked Stripe.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inspectAccount, inspectBooking, recordable, stripeReader, verdict, type Recorded, type StripeGet } from './stripe-inspect.ts';

const BID = '11111111-1111-4111-8111-111111111111';
const rec = (o: Partial<Recorded> = {}): Recorded => ({ booking_id: BID, booking_number: 'CC-1', status: 'confirmed', payments: [], holds: [], pay_links: [], intents: [], ...o });
function fake(objects: Record<string, Record<string, unknown>>, calls: string[] = []): StripeGet {
  return async (path, params = {}) => {
    calls.push(path);
    if (path === '/v1/payment_intents/search') return { data: Object.values(objects).filter((x) => String(x.id).startsWith('pi_') && JSON.stringify(x.metadata ?? {}).includes(BID)) };
    if (path === '/v1/charges') return { data: objects[`ch:${params.payment_intent}`] ? [objects[`ch:${params.payment_intent}`]] : [] };
    if (path === '/v1/disputes') return { data: [] };
    const id = path.split('/').pop()!;
    if (objects[id]) return objects[id];
    if (objects[path]) return objects[path];
    throw new Error('No such object');
  };
}
const PI = { id: 'pi_paid123', status: 'succeeded', amount: 50000, amount_received: 50000, amount_capturable: 0, currency: 'cad', capture_method: 'manual', created: 1794600000,
  metadata: { booking_id: BID, purpose: 'booking_total' }, payment_method: { card: { brand: 'visa', last4: '4242', fingerprint: 'x', exp_month: 1 } } };
const CH = { id: 'ch_1', status: 'succeeded', captured: true, amount_captured: 50000, amount_refunded: 0, disputed: false, refunds: { data: [] }, payment_method_details: { card: { brand: 'visa', last4: '4242' } } };

test('paid at Stripe, found by its metadata, not recorded: the verdict names the PaymentIntent', async () => {
  const r = await inspectBooking(fake({ pi_paid123: PI, 'ch:pi_paid123': CH }), rec());
  assert.equal(r.stripe.length, 1);
  assert.equal(r.stripe[0]!.card, 'visa 4242');
  assert.match(r.verdict, /^paid at Stripe but not recorded \(pi_paid123, \$500\.00\)/);
  assert.ok(!JSON.stringify(r).includes('fingerprint') && !JSON.stringify(r).includes('client_secret'));
});
test('paid and recorded; a hold; not paid', async () => {
  const paid = await inspectBooking(fake({ pi_paid123: PI, 'ch:pi_paid123': CH }), rec({ intents: ['pi_paid123'], payments: [{ purpose: 'booking_total', kind: 'charge', status: 'succeeded', amount_cents: 50000, intent: 'pi_paid123' }] }));
  assert.equal(paid.verdict, 'paid and recorded (pi_paid123)');
  const hold = { ...PI, id: 'pi_hold123', status: 'requires_capture', amount_received: 0, amount_capturable: 30000 };
  const ch = { ...CH, captured: false, payment_method_details: { card: { brand: 'visa', last4: '4242', capture_before: 1795000000 } } };
  const h = await inspectBooking(fake({ pi_hold123: hold, 'ch:pi_hold123': ch }), rec());
  assert.match(h.verdict, /^hold authorized until \d{4}-\d{2}-\d{2} \(pi_hold123, \$300\.00\)/);
  assert.equal(verdict(rec(), []), 'not paid');
});
test('the reads only GET', async () => {
  const methods: string[] = [];
  const f = (async (_u: string, init: RequestInit) => { methods.push(String(init.method)); return new Response(JSON.stringify({ available: [], pending: [] }), { status: 200 }); }) as unknown as typeof fetch;
  await stripeReader('sk_test_x', f)('/v1/balance');
  assert.deepEqual(methods, ['GET']);
});
test('the account: balance, payouts and the open requirements', async () => {
  const a = await inspectAccount(fake({
    '/v1/balance': { available: [{ currency: 'cad', amount: 1200 }], pending: [{ currency: 'cad', amount: 300 }] },
    '/v1/account': { charges_enabled: true, payouts_enabled: false, requirements: { currently_due: ['person_x.verification.document'], past_due: [], eventually_due: [], current_deadline: 1795000000, disabled_reason: 'requirements.past_due' } },
    '/v1/payouts': { data: [{ id: 'po_1', status: 'in_transit', amount: 900, currency: 'cad', arrival_date: 1794700000 }] }
  }));
  assert.equal(a.payouts_enabled, false);
  assert.deepEqual(a.requirements.currently_due, ['person_x.verification.document']);
  assert.equal(a.requirements.disabled_reason, 'requirements.past_due');
  assert.equal(a.next_payout?.id, 'po_1');
  assert.deepEqual(a.balance.available, [{ currency: 'cad', amount_cents: 1200 }]);
});
test('record: only a succeeded intent of this booking\'s total', () => {
  assert.equal(recordable({ status: 'succeeded', metadata: { booking_id: BID, purpose: 'booking_total' } }, BID), null);
  assert.match(recordable({ status: 'requires_capture', metadata: { booking_id: BID, purpose: 'booking_total' } }, BID)!, /not succeeded/);
  assert.match(recordable({ status: 'succeeded', metadata: { booking_id: 'other', purpose: 'booking_total' } }, BID)!, /not for this booking/);
});
