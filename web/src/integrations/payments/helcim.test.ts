// Unit tests for the Helcim adapter against a faked Helcim (helcim-fake.ts) and a memory store: no network, no token.
//   node --test --experimental-strip-types src/integrations/payments/helcim.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardOf, helcimAdapter, memoryHelcimStore, toIntent } from './helcim.ts';
import { compactJson, dollars, helcimKey, rawMember, sha256Hex, signHelcimWebhook, verifyCheckoutHash, verifyHelcimWebhook } from './helcim-api.ts';
import { fakeHelcim, fakeHelcimState } from './helcim-fake.ts';
import { cardProvider, holdWindowDays } from './provider.ts';

function setup(plan: 'hold' | 'charge' = 'hold') {
  const state = fakeHelcimState(true);
  const fake = fakeHelcim(state);
  const store = memoryHelcimStore(() => plan);
  let now = Date.parse('2026-11-24T15:00:00Z');
  const h = helcimAdapter('test-token', store, { now: () => now }, fake.fetch);
  return { h, fake, store, state, tick: (ms: number) => { now += ms; } };
}
const VISA = { number: '4242424242424242', name: 'Maya Okafor' };

test('provider seam: helcim without a token is off; the fake never in production', () => {
  assert.equal(cardProvider({ PAYMENTS_PROVIDER: 'helcim', HELCIM_API_TOKEN: 'x' }), 'helcim');
  assert.equal(cardProvider({ PAYMENTS_PROVIDER: 'helcim' }), 'off');
  assert.equal(cardProvider({ PAYMENTS_PROVIDER: 'stripe' }), 'off');
  assert.equal(cardProvider({ PAYMENTS_PROVIDER: 'stripe', STRIPE_SECRET_KEY: 'sk' }), 'stripe');
  assert.equal(cardProvider({ PAYMENTS_PROVIDER: 'off', HELCIM_API_TOKEN: 'x' }), 'off');
  assert.equal(cardProvider({}), 'fake');
  assert.equal(cardProvider({ APP_ENV: 'production' }), 'off');
  assert.equal(holdWindowDays('helcim'), 7);
  assert.equal(holdWindowDays('stripe', true), 30);
});

test('idempotency keys are 32 hex characters (Helcim: 25 to 36), the same for the same call', async () => {
  const a = await helcimKey('capture:hc_abc');
  assert.match(a, /^[0-9a-f]{32}$/);
  assert.equal(a, await helcimKey('capture:hc_abc'));
  assert.notEqual(a, await helcimKey('capture:hc_abd'));
  assert.equal(dollars(71190), 711.9);
});

test('booking payment: a preauth checkout, confirmed by its hash, then captured', async () => {
  const { h, fake, state } = setup();
  const cust = await h.createCustomer({ email: 'maya@example.com', name: 'Maya Okafor', renterId: '6f1c2d3e-0000-4000-8000-000000000001', idempotencyKey: 'cust:1' });
  assert.match(cust.id, /^CC6F1C2D3E/);
  const i = await h.createBookingIntent({ bookingId: 'b1', bookingNumber: 'CC-10482', offerVersion: 2, amountCents: 71190, customerId: cust.id, description: 'Booking', idempotencyKey: 'booking:b1:v2' });
  assert.equal(i.status, 'requires_payment_method');
  assert.match(i.id, /^hc_/);
  assert.ok(i.clientSecret?.startsWith('ct_'));
  assert.equal([...state.sessions.values()].at(-1)!.paymentType, 'preauth');
  // the same key returns the same payment and session
  const again = await h.createBookingIntent({ bookingId: 'b1', bookingNumber: 'CC-10482', offerVersion: 2, amountCents: 71190, customerId: cust.id, description: 'Booking', idempotencyKey: 'booking:b1:v2' });
  assert.equal(again.id, i.id);
  assert.equal(again.clientSecret, i.clientSecret);
  const modal = await fake.pay(i.clientSecret!, VISA);
  assert.equal(modal.eventStatus, 'SUCCESS');
  assert.equal(await h.idForCheckout(i.clientSecret!), i.id);
  const held = await h.confirmCheckout(i.id, modal.eventMessage);
  assert.equal(held.status, 'requires_capture');
  assert.equal(held.amountCapturableCents, 71190);
  assert.equal(held.card?.brand, 'visa');
  assert.equal(held.card?.last4, '4242');
  assert.ok(held.paymentMethodId?.startsWith('tok_'));
  assert.ok(held.captureBefore && held.captureBefore * 1000 > Date.parse('2026-11-30T15:00:00Z'), 'a preauth must be captured within 7 days');
  // a second confirm is a repeat
  assert.equal((await h.confirmCheckout(i.id, modal.eventMessage)).status, 'requires_capture');
  const cap = await h.captureIntent(i.id, `capture:${i.id}`);
  assert.equal(cap.status, 'succeeded');
  assert.equal((await h.captureIntent(i.id, `capture:${i.id}`)).status, 'succeeded');
  assert.equal(state.calls.filter((c) => c.path === '/payment/capture').length, 1, 'captured once');
});

test('a forged or replayed answer is refused; the browser\'s amount is never trusted', async () => {
  const { h, fake } = setup();
  const a = await h.createAddonIntent({ bookingId: 'b1', bookingNumber: 'CC-1', amountCents: 5000, customerId: '', description: 'Add-ons', idempotencyKey: 'addon:1' });
  const b = await h.createAddonIntent({ bookingId: 'b2', bookingNumber: 'CC-2', amountCents: 5000, customerId: '', description: 'Add-ons', idempotencyKey: 'addon:2' });
  const paid = await fake.pay(a.clientSecret!, VISA);
  // the answer of another session (another secret token) does not count for b
  await assert.rejects(h.confirmCheckout(b.id, paid.eventMessage), /did not come from Helcim/);
  const m = JSON.parse(paid.eventMessage) as { data: Record<string, string>; hash: string };
  await assert.rejects(h.confirmCheckout(a.id, JSON.stringify({ data: { ...m.data, amount: '1.00' }, hash: m.hash })), /did not come from Helcim/);
  assert.equal((await h.confirmCheckout(a.id, paid.eventMessage)).status, 'succeeded');
});

test('a declined card keeps the payment open and a new session is made for the next try', async () => {
  const { h, fake } = setup();
  const i = await h.createGiftIntent({ giftCardId: 'g1', amountCents: 10000, customerId: '', description: 'Gift', idempotencyKey: 'gift:1' });
  const no = await fake.pay(i.clientSecret!, { number: '4000000000000002' });
  assert.equal(no.eventStatus, 'ABORTED');
  const renewed = await h.renewCheckout(i.id);
  assert.notEqual(renewed.clientSecret, i.clientSecret);
  const ok = await fake.pay(renewed.clientSecret!, VISA);
  assert.equal((await h.confirmCheckout(i.id, ok.eventMessage)).status, 'succeeded');
});

test('a checkout session older than 55 minutes is renewed when read', async () => {
  const { h, tick } = setup();
  const i = await h.createCardSetup({ customerId: '', description: 'Save the card', metadata: { purpose: 'staff_request' }, idempotencyKey: 'setup:1' });
  tick(56 * 60_000);
  const r = await h.retrieveCardSetup(i.id);
  assert.notEqual(r.clientSecret, i.clientSecret);
});

test('deposit hold released: the preauth is reversed; a hold not reversed is still never captured', async () => {
  const { h, fake, state } = setup();
  const i = await h.createStaffIntent({ amountCents: 50000, customerId: '', capture: 'manual', description: 'Deposit hold', metadata: { booking_id: 'b1', covers: 'deposit', purpose: 'staff_request', payment_request_id: 'q1' }, idempotencyKey: 'payreq:q1' });
  await h.confirmCheckout(i.id, (await fake.pay(i.clientSecret!, VISA)).eventMessage);
  const c = await h.cancelIntent(i.id, `void:${i.id}`);
  assert.equal(c.status, 'canceled');
  assert.equal(state.calls.filter((x) => x.path === '/payment/reverse').length, 1);
  await assert.rejects(h.captureIntent(i.id, 'capture:x'), /status of canceled/);
});

test('rental longer than the hold window: the deposit is charged, a partial capture refunds the rest, release refunds it all', async () => {
  const { h, fake, state } = setup('charge');
  const i = await h.createStaffIntent({ amountCents: 50000, customerId: '', capture: 'manual', description: 'Deposit', metadata: { booking_id: 'b9', covers: 'deposit', purpose: 'staff_request', payment_request_id: 'q9' }, idempotencyKey: 'payreq:q9' });
  assert.equal(i.metadata.held_as_charge, 'true');
  assert.equal([...state.sessions.values()].at(-1)!.paymentType, 'purchase');
  const held = await h.confirmCheckout(i.id, (await fake.pay(i.clientSecret!, VISA)).eventMessage);
  assert.equal(held.status, 'requires_capture', 'the site still sees a deposit it can capture or release');
  assert.equal(held.captureBefore, null, 'a charged deposit never lapses');
  const kept = await h.captureIntent(i.id, `capture:${i.id}`, 12000);
  assert.equal(kept.status, 'succeeded');
  assert.equal(kept.amountCents, 12000);
  const refunds = state.calls.filter((x) => x.path === '/payment/refund');
  assert.equal(refunds.length, 1);
  assert.equal((refunds[0]!.body as { amount: number }).amount, 380);

  const j = await h.createStaffIntent({ amountCents: 30000, customerId: '', capture: 'manual', description: 'Deposit', metadata: { booking_id: 'b9', covers: 'deposit' }, idempotencyKey: 'payreq:q10' });
  await h.confirmCheckout(j.id, (await fake.pay(j.clientSecret!, VISA)).eventMessage);
  assert.equal((await h.cancelIntent(j.id, `void:${j.id}`)).status, 'canceled');
  assert.equal(state.calls.filter((x) => x.path === '/payment/refund').length, 2);
});

test('card on file: an off-session charge and hold on the saved token; a declined token is reported, not thrown', async () => {
  const { h, fake } = setup();
  const s = await h.createCardSetup({ customerId: '', description: 'Save', metadata: {}, idempotencyKey: 'setup:2' });
  const saved = await h.confirmCheckout(s.id, (await fake.pay(s.clientSecret!, VISA)).eventMessage);
  assert.equal(saved.status, 'succeeded');
  const toll = await h.chargeOffSession({ customerId: '', paymentMethodId: saved.paymentMethodId!, amountCents: 1825, description: 'Toll', metadata: { booking_id: 'b1' }, idempotencyKey: 'toll:1' });
  assert.equal(toll.status, 'succeeded');
  assert.equal((await h.chargeOffSession({ customerId: '', paymentMethodId: saved.paymentMethodId!, amountCents: 1825, description: 'Toll', metadata: {}, idempotencyKey: 'toll:1' })).id, toll.id);
  const hold = await h.chargeOffSession({ customerId: '', paymentMethodId: saved.paymentMethodId!, amountCents: 50000, capture: 'manual', description: 'Deposit', metadata: { booking_id: 'b1', covers: 'deposit' }, idempotencyKey: 'dep:1' });
  assert.equal(hold.status, 'requires_capture');
  const bad = await h.chargeOffSession({ customerId: '', paymentMethodId: 'tok_unknown', amountCents: 100, description: 'x', metadata: {}, idempotencyKey: 'bad:1' });
  assert.equal(bad.status, 'requires_payment_method');
  assert.ok(bad.lastError);
});

test('refunds: once per key, never more than was charged; a Stripe payment is refused with where to refund it', async () => {
  const { h, fake, state } = setup();
  const i = await h.createAddonIntent({ bookingId: 'b1', bookingNumber: 'CC-1', amountCents: 20000, customerId: '', description: 'x', idempotencyKey: 'addon:9' });
  await h.confirmCheckout(i.id, (await fake.pay(i.clientSecret!, VISA)).eventMessage);
  const r = await h.refund({ paymentIntentId: i.id, chargeId: null, amountCents: 5000, idempotencyKey: 'ref:1', metadata: {} });
  assert.equal(r.status, 'succeeded');
  assert.match(r.id, /^hcr_\d+$/);
  assert.deepEqual(await h.refund({ paymentIntentId: i.id, chargeId: null, amountCents: 5000, idempotencyKey: 'ref:1', metadata: {} }), r);
  assert.equal(state.calls.filter((x) => x.path === '/payment/refund').length, 1);
  await assert.rejects(h.refund({ paymentIntentId: i.id, chargeId: null, amountCents: 16000, idempotencyKey: 'ref:2', metadata: {} }), /greater than the charge/);
  await assert.rejects(h.refund({ paymentIntentId: 'pi_3Abc', chargeId: null, amountCents: 100, idempotencyKey: 'ref:3', metadata: {} }), /Stripe payment/);
});

test('a refund Helcim refuses in an open batch is a reverse instead (full amount only)', async () => {
  const { h, fake, state } = setup();
  const i = await h.createAddonIntent({ bookingId: 'b1', bookingNumber: 'CC-1', amountCents: 20000, customerId: '', description: 'x', idempotencyKey: 'addon:10' });
  await h.confirmCheckout(i.id, (await fake.pay(i.clientSecret!, VISA)).eventMessage);
  state.failNext.push({ path: /^\/payment\/refund$/, status: 400, errors: ['Transaction is in an open batch: reverse it'] });
  assert.equal((await h.refund({ paymentIntentId: i.id, chargeId: null, amountCents: 20000, idempotencyKey: 'ref:full', metadata: {} })).status, 'succeeded');
  assert.equal(state.calls.filter((x) => x.path === '/payment/reverse').length, 1);
});

test('webhook reconciliation: a paid modal the browser never confirmed is tied to its one open session', async () => {
  const { h, fake } = setup();
  const i = await h.createBookingIntent({ bookingId: 'b1', bookingNumber: 'CC-1', offerVersion: 1, amountCents: 33300, customerId: '', description: 'x', idempotencyKey: 'bk:1' });
  const paid = await fake.pay(i.clientSecret!, VISA);
  const tx = Number((JSON.parse(paid.eventMessage) as { data: { transactionId: string } }).data.transactionId);
  const r = await h.reconcile(tx);
  assert.equal(r.intent?.id, i.id);
  assert.equal(r.intent?.status, 'requires_capture');
  assert.equal((await h.reconcile(tx)).intent?.id, i.id, 'a retry finds the same payment');
  assert.equal((await h.confirmCheckout(i.id, paid.eventMessage)).status, 'requires_capture');
});

test('owner bank debits are not available on Helcim', async () => {
  const { h } = setup();
  await assert.rejects(h.createInvoiceIntent({ invoiceId: 'i', invoiceNumber: 'OI-1', ownerId: 'o', amountCents: 100, customerId: '', method: 'acss_debit', transactionType: 'personal', description: 'x', idempotencyKey: 'k' }), /not available with Helcim/);
  await assert.rejects(h.createDebitSetup({ ownerId: 'o', customerId: '', transactionType: 'personal', intervalDescription: 'x', idempotencyKey: 'k' }), /not available with Helcim/);
});

test('HelcimPay.js hash: raw data text, compact JSON, escaped unicode and slashes all verify; a wrong secret does not', async () => {
  const data = { transactionId: '1', amount: '100.00', cardHolderName: 'Zoë Côté', warning: 'a/b' };
  const secret = 'st_secret';
  const pretty = `{ "data": { "transactionId": "1", "amount": "100.00", "cardHolderName": "Zoë Côté", "warning": "a/b" }, "hash": "${await sha256Hex(compactJson('{ "transactionId": "1", "amount": "100.00", "cardHolderName": "Zoë Côté", "warning": "a/b" }') + secret)}" }`;
  assert.ok(await verifyCheckoutHash(pretty, secret));
  const php = JSON.stringify(data).replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`).replace(/\//g, '\\/');
  assert.ok(await verifyCheckoutHash({ data, hash: await sha256Hex(php + secret) }, secret));
  assert.equal(await verifyCheckoutHash({ data, hash: await sha256Hex(php + secret) }, 'other'), null);
  assert.equal(rawMember('{"hash":"x","data":{"a":[1,{"b":"}"}]}}', 'data'), '{"a":[1,{"b":"}"}]}');
});

test('webhook signature: v1 HMAC of id.timestamp.body with the base64 verifier; stale or wrong refused', async () => {
  const token = btoa('a-verifier-token-of-32-bytes-long!!');
  const body = '{"id":"25764674","type":"cardTransaction"}';
  const hdr = await signHelcimWebhook(body, token, 'msg_1', 1_800_000_000);
  await verifyHelcimWebhook(body, hdr, token, 1_800_000_010);
  await verifyHelcimWebhook(body, { ...hdr, signature: `v2,zzz ${hdr.signature}` }, token, 1_800_000_010);
  await assert.rejects(verifyHelcimWebhook(body + ' ', hdr, token, 1_800_000_010), /does not match/);
  await assert.rejects(verifyHelcimWebhook(body, hdr, token, 1_800_001_000), /tolerance/);
  await assert.rejects(verifyHelcimWebhook(body, { ...hdr, id: null }, token), /Missing/);
  await assert.rejects(verifyHelcimWebhook(body, hdr, ''), /No webhook verifier/);
});

test('cards: brand and last four only; Helcim\'s debit and Interac types count as debit', () => {
  assert.deepEqual([cardOf({ cardNumber: '424242******4242', cardType: 'VI' })?.brand, cardOf({ cardNumber: '424242******4242', cardType: 'VI' })?.funding], ['visa', 'credit']);
  assert.equal(cardOf({ cardNumber: '4506******1234', cardType: 'DB' })?.funding, 'debit');
  assert.equal(cardOf({ cardNumber: '' }), null);
  const row = { id: 'hc_x', status: 'requires_payment_method', checkoutToken: 'ct_1' } as Parameters<typeof toIntent>[0];
  assert.equal(toIntent({ ...row, metadata: {}, amountCents: 1, capturableCents: 0 } as never).clientSecret, 'ct_1');
});
