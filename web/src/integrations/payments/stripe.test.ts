// Unit tests for the Stripe adapter against a mocked fetch (no network, no key).
//   node --test --experimental-strip-types src/integrations/payments/stripe.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formEncode, stripeAdapter, StripeError, toIntent } from './stripe.ts';
import { signStripePayload, verifyStripeSignature } from './signature.ts';

type Call = { url: string; init: RequestInit };
function mock(responses: Array<{ status?: number; body: unknown }>) {
  const calls: Call[] = [];
  const f = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    const r = responses.shift() ?? { status: 500, body: { error: { message: 'no more responses' } } };
    return new Response(JSON.stringify(r.body), { status: r.status ?? 200, headers: { 'content-type': 'application/json' } });
  }) as typeof fetch;
  return { f, calls };
}

const pi = (over: Record<string, unknown> = {}) => ({
  id: 'pi_123', object: 'payment_intent', status: 'requires_capture', amount: 71190, amount_capturable: 71190, currency: 'cad',
  client_secret: 'pi_123_secret_x', customer: 'cus_1', metadata: { booking_id: 'b1', offer_version: '1' },
  payment_method: { id: 'pm_1', card: { brand: 'visa', last4: '4242', exp_month: 12, exp_year: 2031, funding: 'credit', fingerprint: 'fp1' }, billing_details: { name: 'Gus Green' } },
  latest_charge: { id: 'ch_1' }, last_payment_error: null, ...over
});

test('form encoding nests objects and lists the way Stripe reads them', () => {
  assert.equal(decodeURIComponent(formEncode({ amount: 100, metadata: { booking_id: 'b1' }, expand: ['payment_method', 'latest_charge'], skip: undefined })),
    'amount=100&metadata[booking_id]=b1&expand[]=payment_method&expand[]=latest_charge');
});

test('a booking intent is card only, manual capture, saves the card, carries the booking and the idempotency key', async () => {
  const { f, calls } = mock([{ body: pi({ status: 'requires_payment_method', payment_method: null, latest_charge: null }) }]);
  const s = stripeAdapter('sk_test_abc', f);
  const i = await s.createBookingIntent({ bookingId: 'b1', bookingNumber: 'CC-1', offerVersion: 2, amountCents: 71190, customerId: 'cus_1', description: 'Booking CC-1', idempotencyKey: 'booking:b1:total:2' });
  assert.equal(calls.length, 1);
  const c = calls[0]!;
  assert.equal(c.url, 'https://api.stripe.com/v1/payment_intents');
  assert.equal(c.init.method, 'POST');
  const h = c.init.headers as Record<string, string>;
  assert.equal(h.authorization, 'Bearer sk_test_abc');
  assert.equal(h['idempotency-key'], 'booking:b1:total:2');
  const body = new URLSearchParams(String(c.init.body));
  assert.equal(body.get('capture_method'), 'manual');
  assert.equal(body.get('setup_future_usage'), 'off_session');
  assert.equal(body.get('currency'), 'cad');
  assert.equal(body.get('amount'), '71190');
  assert.deepEqual(body.getAll('payment_method_types[]'), ['card']);
  assert.equal(body.get('metadata[booking_id]'), 'b1');
  assert.equal(body.get('metadata[offer_version]'), '2');
  assert.equal(i.clientSecret, 'pi_123_secret_x');
  assert.equal(i.card, null);
});

test('retrieve reads the card funding, the cardholder and the charge from the expanded objects', async () => {
  const { f, calls } = mock([{ body: pi() }]);
  const i = await stripeAdapter('sk_test_abc', f).retrieveIntent('pi_123');
  assert.match(calls[0]!.url, /\/payment_intents\/pi_123\?expand%5B%5D=payment_method&expand%5B%5D=latest_charge$/);
  assert.equal(calls[0]!.init.method, 'GET');
  assert.deepEqual(i.card, { brand: 'visa', last4: '4242', expMonth: 12, expYear: 2031, funding: 'credit', name: 'Gus Green', fingerprint: 'fp1' });
  assert.equal(i.status, 'requires_capture');
  assert.equal(i.paymentMethodId, 'pm_1');
  assert.equal(i.chargeId, 'ch_1');
  assert.equal(i.amountCapturableCents, 71190);
});

test('capture and cancel post to their endpoints with their own idempotency keys', async () => {
  const { f, calls } = mock([{ body: pi({ status: 'succeeded', amount_capturable: 0 }) }, { body: pi({ status: 'canceled' }) }]);
  const s = stripeAdapter('sk_test_abc', f);
  assert.equal((await s.captureIntent('pi_123', 'capture:pi_123')).status, 'succeeded');
  assert.equal((await s.cancelIntent('pi_123', 'void:pi_123')).status, 'canceled');
  assert.equal(calls[0]!.url, 'https://api.stripe.com/v1/payment_intents/pi_123/capture');
  assert.equal((calls[0]!.init.headers as Record<string, string>)['idempotency-key'], 'capture:pi_123');
  assert.equal(calls[1]!.url, 'https://api.stripe.com/v1/payment_intents/pi_123/cancel');
  assert.equal((calls[1]!.init.headers as Record<string, string>)['idempotency-key'], 'void:pi_123');
});

test('an off-session charge confirms at once on the saved card', async () => {
  const { f, calls } = mock([{ body: pi({ status: 'succeeded' }) }]);
  await stripeAdapter('sk_test_abc', f).chargeOffSession({ customerId: 'cus_1', paymentMethodId: 'pm_1', amountCents: 5000, description: 'Extension', metadata: { extension_id: 'e1' }, idempotencyKey: 'ext:e1' });
  const body = new URLSearchParams(String(calls[0]!.init.body));
  assert.equal(body.get('off_session'), 'true');
  assert.equal(body.get('confirm'), 'true');
  assert.equal(body.get('payment_method'), 'pm_1');
  assert.equal(body.get('metadata[extension_id]'), 'e1');
});

test('a Stripe error becomes a StripeError with the decline code; a 500 is retried', async () => {
  const { f, calls } = mock([
    { status: 500, body: { error: { message: 'temporary' } } },
    { status: 402, body: { error: { message: 'Your card was declined.', code: 'card_declined', decline_code: 'generic_decline' } } }
  ]);
  await assert.rejects(stripeAdapter('sk_test_abc', f).captureIntent('pi_123', 'k'), (e: unknown) => {
    assert.ok(e instanceof StripeError);
    assert.equal(e.message, 'Your card was declined.');
    assert.equal(e.declineCode, 'generic_decline');
    assert.equal(e.status, 402);
    return true;
  });
  assert.equal(calls.length, 2);
});

test('webhook signatures: a good one passes; a forged, stale or missing one is refused', async () => {
  const body = JSON.stringify({ id: 'evt_1', type: 'payment_intent.amount_capturable_updated', created: 1, data: { object: pi() } });
  const now = 1_800_000_000;
  const header = await signStripePayload(body, 'whsec_test', now);
  const s = stripeAdapter('sk_test_abc', mock([]).f);
  const e = await s.verifyWebhook(body, header, 'whsec_test', now + 10);
  assert.equal(e.id, 'evt_1');
  assert.equal(toIntent(e.object).id, 'pi_123');
  await assert.rejects(verifyStripeSignature(body, header, 'whsec_other', now), /does not match/);
  await assert.rejects(verifyStripeSignature(body.replace('evt_1', 'evt_2'), header, 'whsec_test', now), /does not match/);
  await assert.rejects(verifyStripeSignature(body, header, 'whsec_test', now + 301), /tolerance/);
  await assert.rejects(verifyStripeSignature(body, null, 'whsec_test', now), /Missing/);
});

test('an owner invoice by pre-authorized debit: acss_debit only, automatic capture, a mandate on a schedule, saved for later', async () => {
  const { f, calls } = mock([{ body: pi({ status: 'requires_payment_method', capture_method: 'automatic', payment_method: null, latest_charge: null, metadata: { owner_invoice_id: 'i1', purpose: 'owner_invoice' } }) }]);
  const s = stripeAdapter('sk_test_abc', f);
  await s.createInvoiceIntent({ invoiceId: 'i1', invoiceNumber: 'INV-1001', ownerId: 'o1', amountCents: 101700, customerId: 'cus_1', method: 'acss_debit', transactionType: 'personal', description: 'Invoice INV-1001', idempotencyKey: 'owner-invoice:i1:acss_debit:101700:0' });
  const body = decodeURIComponent(String(calls[0]!.init.body));
  assert.match(body, /payment_method_types\[\]=acss_debit/);
  assert.match(body, /setup_future_usage=off_session/);
  assert.doesNotMatch(body, /capture_method=manual/);
  assert.match(body, /payment_method_options\[acss_debit\]\[mandate_options\]\[payment_schedule\]=interval/);
  assert.match(body, /payment_method_options\[acss_debit\]\[mandate_options\]\[transaction_type\]=personal/);
  assert.match(body, /metadata\[purpose\]=owner_invoice/);
  assert.equal((calls[0]!.init.headers as Record<string, string>)['idempotency-key'], 'owner-invoice:i1:acss_debit:101700:0');
});

test('the invoice page with the recurring box unticked (0053): a one-time debit, a sporadic mandate, nothing saved', async () => {
  const { f, calls } = mock([{ body: pi({ status: 'requires_payment_method', capture_method: 'automatic', payment_method: null, latest_charge: null, metadata: { owner_invoice_id: 'i1', purpose: 'owner_invoice', recurring: 'false' } }) }]);
  const s = stripeAdapter('sk_test_abc', f);
  await s.createInvoiceIntent({ invoiceId: 'i1', invoiceNumber: 'INV-1001', ownerId: 'o1', amountCents: 101700, customerId: 'cus_1', method: 'acss_debit', transactionType: 'business', recurring: false, description: 'Invoice INV-1001', idempotencyKey: 'owner-invoice:i1:acss_debit:101700:0:once' });
  const body = decodeURIComponent(String(calls[0]!.init.body));
  assert.doesNotMatch(body, /setup_future_usage/);
  assert.match(body, /payment_method_options\[acss_debit\]\[mandate_options\]\[payment_schedule\]=sporadic/);
  assert.doesNotMatch(body, /interval_description/);
  assert.match(body, /metadata\[recurring\]=false/);
});

test('a settled debit reads the bank and the mandate from the charge', () => {
  const i = toIntent(pi({ status: 'succeeded', payment_method: { id: 'pm_a', type: 'acss_debit', acss_debit: { bank_name: 'TD', last4: '6789' } }, latest_charge: { id: 'py_1', payment_method_details: { type: 'acss_debit', acss_debit: { bank_name: 'TD', last4: '6789', mandate: 'mandate_1' } } } }));
  assert.equal(i.methodType, 'acss_debit');
  assert.deepEqual(i.bank, { name: 'TD', last4: '6789' });
  assert.equal(i.mandateId, 'mandate_1');
  assert.equal(i.card, null);
});

test('a refund goes to /v1/refunds against the PaymentIntent, with the refund\'s own idempotency key', async () => {
  const { f, calls } = mock([{ body: { id: 're_1', object: 'refund', status: 'succeeded', amount: 2500, failure_reason: null } }]);
  const s = stripeAdapter('sk_test_abc', f);
  const r = await s.refund({ paymentIntentId: 'pi_123', chargeId: 'ch_1', amountCents: 2500, idempotencyKey: 'refund:r1', metadata: { refund_id: 'r1' } });
  assert.deepEqual(r, { id: 're_1', status: 'succeeded', amountCents: 2500, failureReason: null });
  const c = calls[0]!;
  assert.equal(c.url, 'https://api.stripe.com/v1/refunds');
  const body = decodeURIComponent(String(c.init.body));
  assert.match(body, /payment_intent=pi_123/);
  assert.doesNotMatch(body, /charge=/);
  assert.match(body, /amount=2500/);
  assert.match(body, /metadata\[refund_id\]=r1/);
  assert.equal((c.init.headers as Record<string, string>)['idempotency-key'], 'refund:r1');
});

test('a refund of a charge without an intent uses the charge; a refusal is a StripeError with the message', async () => {
  const { f, calls } = mock([{ body: { id: 're_2', status: 'pending', amount: 100 } }, { status: 400, body: { error: { message: 'Charge ch_9 has been charged back.', code: 'charge_disputed' } } }]);
  const s = stripeAdapter('sk_test_abc', f);
  const r = await s.refund({ paymentIntentId: null, chargeId: 'ch_2', amountCents: 100, idempotencyKey: 'refund:r2', metadata: {} });
  assert.equal(r.status, 'pending');
  assert.match(decodeURIComponent(String(calls[0]!.init.body)), /charge=ch_2/);
  await assert.rejects(s.refund({ paymentIntentId: null, chargeId: 'ch_9', amountCents: 100, idempotencyKey: 'refund:r3', metadata: {} }),
    (e: unknown) => e instanceof StripeError && e.code === 'charge_disputed' && /charged back/.test(e.message));
});

test('a pre-authorized debit set up without a payment: a SetupIntent with the mandate schedule from settings', async () => {
  const { f, calls } = mock([{ body: { id: 'seti_1', status: 'requires_payment_method', client_secret: 'seti_1_secret', customer: 'cus_1', payment_method: null, mandate: null, metadata: { owner_id: 'o1', purpose: 'owner_debit_setup' } } }]);
  const s = stripeAdapter('sk_test_abc', f);
  const r = await s.createDebitSetup({ ownerId: 'o1', customerId: 'cus_1', transactionType: 'business', intervalDescription: 'On the 20th of each month', idempotencyKey: 'owner-debit-setup:o1:x' });
  const body = decodeURIComponent(String(calls[0]!.init.body));
  assert.equal(calls[0]!.url, 'https://api.stripe.com/v1/setup_intents');
  assert.match(body, /usage=off_session/);
  assert.match(body, /payment_method_types\[\]=acss_debit/);
  assert.match(body.replace(/\+/g, ' '), /interval_description\]=On the 20th of each month/);
  assert.match(body, /payment_method_options\[acss_debit\]\[mandate_options\]\[transaction_type\]=business/);
  assert.match(body, /metadata\[purpose\]=owner_debit_setup/);
  assert.equal(r.clientSecret, 'seti_1_secret');
});

test('a verified debit setup reads the method, the mandate and the bank', async () => {
  const { f } = mock([{ body: { id: 'seti_1', status: 'succeeded', customer: 'cus_1', mandate: 'mandate_1', metadata: { owner_id: 'o1' },
    payment_method: { id: 'pm_1', acss_debit: { bank_name: 'TD', last4: '6789' } } } }]);
  const r = await stripeAdapter('sk_test_abc', f).retrieveDebitSetup('seti_1');
  assert.deepEqual([r.status, r.paymentMethodId, r.mandateId, r.bank?.last4, r.metadata.owner_id], ['succeeded', 'pm_1', 'mandate_1', '6789', 'o1']);
});

test('the invoice mandate uses the schedule in words from settings', async () => {
  const { f, calls } = mock([{ body: pi({ status: 'requires_payment_method', payment_method: null, latest_charge: null }) }]);
  await stripeAdapter('sk_test_abc', f).createInvoiceIntent({ invoiceId: 'i1', invoiceNumber: 'INV-1', ownerId: 'o1', amountCents: 100, customerId: 'cus_1', method: 'acss_debit',
    transactionType: 'personal', intervalDescription: 'On the 15th of each month, notice 10 days before', description: 'x', idempotencyKey: 'k' });
  assert.match(decodeURIComponent(String(calls[0]!.init.body)).replace(/\+/g, ' '), /interval_description\]=On the 15th of each month, notice 10 days before/);
});
