// r47 (2896): the connector's Stripe reads, with a faked Stripe.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { findPayments, inspectAccount, inspectBooking, linkMetadata, LINKED_PURPOSE, payerKeys, payerOf, recordable, stripeReader, tieOf, untiedWillDo, verdict, withMatches, type Recorded, type StripeGet } from './stripe-inspect.ts';

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
  // r50 (3871): the card's fingerprint is given on purpose, as payer.card_fingerprint only
  assert.ok(!JSON.stringify(r).replace(/"card_fingerprint":(null|"[^"]*")/g, '').includes('fingerprint') && !JSON.stringify(r).includes('client_secret'));
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

// hotfix 3430: a card taken in the Stripe Dashboard app (Tap to Pay) has no booking in Stripe
test('3430: tieOf: made for the booking, untied, another booking, not succeeded', () => {
  assert.deepEqual(tieOf({ status: 'succeeded', metadata: { booking_id: BID, purpose: 'booking_total' } }, BID, 'CC-1'), { kind: 'tied' });
  assert.deepEqual(tieOf({ status: 'succeeded', metadata: {} }, BID, 'CC-1'), { kind: 'untied' });
  assert.deepEqual(tieOf({ status: 'succeeded', metadata: { booking_id: BID, purpose: LINKED_PURPOSE } }, BID, 'CC-1'), { kind: 'untied' });
  const other = tieOf({ status: 'succeeded', metadata: { booking_id: '22222222-2222-4222-8222-222222222222' } }, BID, 'CC-1');
  assert.equal(other.kind, 'refused');
  assert.equal(tieOf({ status: 'succeeded', metadata: { booking_number: 'cc-9' } }, BID, 'CC-1').kind, 'refused');
  const held = tieOf({ status: 'requires_capture', metadata: {} }, BID, 'CC-1');
  assert.ok(held.kind === 'refused' && /not succeeded/.test(held.why) && /nothing is captured/.test(held.why));
  // this booking's staff pay link: the webhook's own path, not linked a second way
  assert.equal(tieOf({ status: 'succeeded', metadata: { booking_id: BID, purpose: 'staff_request' } }, BID, 'CC-1').kind, 'refused');
});
test('3430: the metadata set at Stripe names the booking and never a purpose the webhook settles', () => {
  const m = linkMetadata({}, BID, 'CC-1');
  assert.deepEqual(m, { booking_id: BID, booking_number: 'CC-1', linked_by: 'connector', purpose: LINKED_PURPOSE });
  assert.notEqual(m.purpose, 'booking_total');
  assert.equal(linkMetadata({ purpose: 'something' }, BID, 'CC-1').purpose, undefined);
  assert.match(untiedWillDo('pi_x123456', 500000, 'CC-1', { ok: true, as: 'rental_deposit', rental_cents: 400000, deposit_cents: 100000 }),
    /\$5000\.00.*untied.*CC-1.*\$4000\.00.*\$1000\.00.*Nothing is charged, captured or refunded/);
});
test('3430: findPayments lists succeeded and holding intents in the window, flags the untied ones, GET only', async () => {
  const calls: Array<{ path: string; params: Record<string, string> }> = [];
  const tap = { id: 'pi_tap123456', status: 'succeeded', amount: 500000, amount_received: 500000, currency: 'cad', created: 1795000000, metadata: {}, payment_method_types: ['card_present'],
    latest_charge: { id: 'ch_tap', payment_method_details: { type: 'card_present', card_present: { brand: 'visa', last4: '1111', wallet: { type: 'apple_pay' } } } } };
  const site = { ...tap, id: 'pi_site123456', amount: 20000, metadata: { booking_number: 'CC-1', booking_id: BID }, latest_charge: { payment_method_details: { type: 'card', card: { brand: 'mastercard', last4: '4444' } } } };
  const failed = { ...tap, id: 'pi_fail123456', status: 'requires_payment_method' };
  const get: StripeGet = async (path, params = {}) => {
    calls.push({ path, params });
    if (!params.starting_after) return { data: [tap, failed], has_more: true };
    return { data: [site], has_more: false };
  };
  const r = await findPayments(get, { since: 1794900000, until: 1795100000 }, async (ids) => {
    assert.deepEqual(ids, ['pi_tap123456', 'pi_site123456']);
    return { pi_site123456: { booking_number: 'CC-1', where: 'payment' } };
  });
  assert.equal(calls.length, 2);
  assert.ok(calls.every((c) => c.path === '/v1/payment_intents' && c.params['created[gte]'] === '1794900000' && c.params['created[lte]'] === '1795100000'));
  assert.equal(calls[1]!.params.starting_after, 'pi_fail123456');
  assert.equal(r.count, 2);
  assert.equal(r.untied_not_recorded, 1);
  const t = r.payments[0]!;
  assert.deepEqual([t.card, t.method_type, t.wallet, t.no_booking, t.recorded], ['visa 1111', 'card_present', 'apple_pay', true, false]);
  assert.match(t.flag!, /no booking in Stripe/);
  assert.deepEqual([r.payments[1]!.recorded, r.payments[1]!.recorded_on, r.payments[1]!.booking_metadata, r.payments[1]!.flag], [true, 'CC-1', 'CC-1', null]);
  const only = await findPayments(async () => ({ data: [tap, site] }), { since: 1, until: 2, amount_cents: 500000 }, async () => ({}));
  assert.deepEqual(only.payments.map((p) => p.id), ['pi_tap123456']);
  assert.ok(!JSON.stringify(r).replace(/"card_fingerprint":(null|"[^"]*")/g, '').includes('fingerprint'));
});

test('r50 (3871): the payer from the charge and the Customer, the fingerprint but never the number', () => {
  const p = payerOf({ receipt_email: null, customer: { email: 'Cust@Example.test', name: 'Cust Name' } },
    { receipt_email: 'r@example.test', billing_details: { name: 'Bill Name', email: 'b@example.test', phone: '+16475550123' },
      payment_method_details: { type: 'card', card: { brand: 'visa', last4: '4242', fingerprint: 'fpAbc123', number: '4242424242424242' } } }, null);
  assert.deepEqual(p, { receipt_email: 'r@example.test', billing_name: 'Bill Name', billing_email: 'b@example.test', billing_phone: '+16475550123',
    customer_email: 'Cust@Example.test', customer_name: 'Cust Name', card_fingerprint: 'fpAbc123' });
  assert.ok(!JSON.stringify(p).includes('4242424242424242'));
  assert.deepEqual(payerKeys('pi_1', null, p).emails, ['r@example.test', 'b@example.test', 'cust@example.test']);
  assert.equal(payerOf({ customer: { deleted: true, email: 'x@y.z' } }, null, null).customer_email, null);
});

test('r50 (3871): matched_renter comes from one database call, only for payers with something to match', async () => {
  const none = payerOf(null, null, null);
  const calls: unknown[] = [];
  const rows = await withMatches([{ id: 'pi_a', created: null, payer: { ...none, billing_email: 'a@example.test' } }, { id: 'pi_b', created: null, payer: none }],
    async (keys) => { calls.push(keys); return { pi_a: { matched: true, renters: [{ renter_id: 'r' }], bookings: [] } }; });
  assert.equal(calls.length, 1);
  assert.equal((calls[0] as unknown[]).length, 1);
  assert.equal(rows[0]!.matched_renter?.matched, true);
  assert.equal(rows[1]!.matched_renter, null);
});

test('r50 (3871): the PaymentIntents list expands only the charge and the Customer', async () => {
  const seen: Array<Record<string, string>> = [];
  await findPayments(async (_p, params = {}) => { seen.push(params); return { data: [], has_more: false }; }, { since: 1, until: 2 }, async () => ({}));
  assert.deepEqual(Object.entries(seen[0]!).filter(([k]) => k.startsWith('expand')).map(([, v]) => v), ['data.latest_charge', 'data.customer']);
});
