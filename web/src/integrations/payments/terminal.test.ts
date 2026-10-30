import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stripeTerminal } from './terminal.ts';

// Stripe Terminal through a mocked fetch (0202): what is sent, and how a card_present payment reads.
function mock(answers: Array<Record<string, unknown>>) {
  const calls: Array<{ url: string; method: string; body: string | undefined; key: string | null }> = [];
  const f = (async (url: string, init: RequestInit) => {
    calls.push({ url, method: String(init.method), body: init.body as string | undefined, key: (init.headers as Record<string, string>)['idempotency-key'] ?? null });
    return new Response(JSON.stringify(answers.shift() ?? {}), { status: 200 });
  }) as unknown as typeof fetch;
  return { f, calls };
}

test('pairing: the location from the address, then the reader by its pairing code', async () => {
  const { f, calls } = mock([{ id: 'tml_1' }, { id: 'tmr_1', label: 'Front desk', device_type: 'stripe_s700', serial_number: 'S7', status: 'online', location: 'tml_1' }]);
  const t = stripeTerminal('sk_test_x', f);
  const l = await t.createLocation({ displayName: 'CarmaCars', address: { line1: '1 Example St', city: 'Toronto', state: 'ON', postal_code: 'M5V 1A1', country: 'CA' }, idempotencyKey: 'k' });
  const r = await t.registerReader({ registrationCode: 'simulated-wpe', label: 'Front desk', location: l.id });
  assert.equal(calls[0]!.url, 'https://api.stripe.com/v1/terminal/locations');
  assert.match(calls[0]!.body!, /address%5Bcity%5D=Toronto/);
  assert.equal(calls[1]!.url, 'https://api.stripe.com/v1/terminal/readers');
  assert.match(calls[1]!.body!, /registration_code=simulated-wpe/);
  assert.deepEqual([r.id, r.deviceType, r.location], ['tmr_1', 'stripe_s700', 'tml_1']);
});

test('a deposit hold on the reader: card_present, manual capture, then handed to the reader', async () => {
  const { f, calls } = mock([{ id: 'pi_1', status: 'requires_payment_method', amount: 50000 }, { id: 'tmr_1', action: { type: 'process_payment_intent', status: 'in_progress' } }]);
  const t = stripeTerminal('sk_test_x', f);
  const i = await t.createReaderIntent({ amountCents: 50000, capture: 'manual', description: 'CarmaCars booking CC-1: deposit hold', metadata: { booking_number: 'CC-1' }, idempotencyKey: 'payreq:1' });
  const r = await t.processOnReader('tmr_1', i.id, 'process:1');
  assert.match(calls[0]!.body!, /payment_method_types%5B%5D=card_present/);
  assert.match(calls[0]!.body!, /capture_method=manual/);
  assert.equal(calls[0]!.key, 'payreq:1');
  assert.equal(calls[1]!.url, 'https://api.stripe.com/v1/terminal/readers/tmr_1/process_payment_intent');
  assert.equal(r.action?.status, 'in_progress');
});

test('a card read on the reader gives its brand, last 4 and fingerprint; a charge id is looked up through its intent', async () => {
  const pi = { id: 'pi_2', status: 'requires_capture', amount: 1000, amount_capturable: 1000, latest_charge: { id: 'ch_2', payment_method_details: { type: 'card_present', card_present: { brand: 'visa', last4: '4242', fingerprint: 'fp_x', funding: 'credit' } } } };
  const { f, calls } = mock([{ id: 'ch_2', payment_intent: 'pi_2' }, pi]);
  const i = await stripeTerminal('sk_test_x', f).lookupPayment('ch_2');
  assert.equal(calls[0]!.url, 'https://api.stripe.com/v1/charges/ch_2');
  assert.deepEqual([i.id, i.status, i.card?.last4, i.card?.fingerprint, i.methodType], ['pi_2', 'requires_capture', '4242', 'fp_x', 'card_present']);
});
