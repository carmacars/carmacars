import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isHoldLapse, outcomeOf, settlementOrder, stepFor, type MoneyFacts } from './money-steps.ts';

const base: MoneyFacts = { payment_id: 'p1', action: 'capture_deposit', status: 'pending', amount_cents: 50000, booking_id: 'b1', booking_number: 'CC-1001',
  intent_id: 'pi_1', charge_id: 'ch_1', customer_id: 'cus_1', method_id: 'pm_1', skip_processor: false, idempotency_key: 'money:p1', attempts: 0 };

test('a settlement capture and the capture before a hold lapses capture the hold for the amount, once (the key)', () => {
  for (const action of ['capture_deposit', 'protect_capture'] as const) {
    assert.deepEqual(stepFor({ ...base, action }), { call: 'capture', intentId: 'pi_1', amountCents: 50000, key: 'money:p1' });
  }
  assert.equal(stepFor({ ...base, intent_id: null }).call, 'none');
});

test('a release after a capture of the same hold is not sent to Stripe (the capture ended the hold)', () => {
  assert.deepEqual(stepFor({ ...base, action: 'release_hold', skip_processor: true }), { call: 'skip' });
  assert.deepEqual(stepFor({ ...base, action: 'release_hold' }), { call: 'cancel', intentId: 'pi_1', key: 'money:p1' });
});

test('a deposit refund names its payment, so the refund webhook keeps it on that payment', () => {
  const s = stepFor({ ...base, action: 'refund_deposit', amount_cents: 12000 });
  assert.equal(s.call, 'refund');
  if (s.call === 'refund') { assert.equal(s.amountCents, 12000); assert.equal(s.metadata.refund_id, 'p1'); }
});

test('card charges need the saved card; their description says what it is for', () => {
  const s = stepFor({ ...base, action: 'balance_charge' });
  assert.equal(s.call, 'charge');
  if (s.call === 'charge') assert.match(s.description, /CC-1001: charges after the rental/);
  assert.deepEqual(stepFor({ ...base, action: 'charge_card', method_id: null }), { call: 'none', reason: 'No saved card' });
  assert.deepEqual(stepFor({ ...base, status: 'succeeded' }), { call: 'none', reason: 'Not waiting any more' });
});

test('Stripe\'s answers: done only when the intent succeeded (capture, charge) or is canceled (release)', () => {
  const cap = stepFor(base);
  assert.deepEqual(outcomeOf(cap, { status: 'succeeded', id: 'pi_1', chargeId: 'ch_9' }), { ok: true, intent_id: 'pi_1', charge_id: 'ch_9', intent_status: 'succeeded' });
  assert.equal(outcomeOf(cap, { status: 'canceled' }).intent_status, 'canceled', 'a lapsed hold is reported as canceled');
  assert.equal(outcomeOf(cap, { status: 'requires_capture' }).ok, false);
  assert.equal(outcomeOf(stepFor({ ...base, action: 'release_hold' }), { status: 'canceled' }).ok, true);
  const rf = stepFor({ ...base, action: 'refund_deposit' });
  assert.deepEqual(outcomeOf(rf, { status: 'pending', id: 're_1' }), { ok: true, refund_id: 're_1', refund_status: 'pending', intent_id: 'pi_1' });
  assert.equal(outcomeOf(rf, { status: 'failed', failureReason: 'expired_or_canceled_card' }).error, 'expired_or_canceled_card');
});

test('captures run first', () => {
  assert.deepEqual(settlementOrder([{ action: 'release_hold' }, { action: 'charge_card' }, { action: 'capture_deposit' }]).map((x) => x.action), ['capture_deposit', 'charge_card', 'release_hold']);
});

test('only an automatic cancel of a deposit hold is a lapse', () => {
  const o = { object: 'payment_intent', cancellation_reason: 'automatic', metadata: { purpose: 'staff_request', covers: 'deposit' } };
  assert.equal(isHoldLapse('payment_intent.canceled', o), true);
  assert.equal(isHoldLapse('payment_intent.canceled', { ...o, cancellation_reason: null }), false, 'our own release');
  assert.equal(isHoldLapse('payment_intent.canceled', { ...o, metadata: { purpose: 'staff_request', covers: 'later' } }), false);
  assert.equal(isHoldLapse('payment_intent.succeeded', o), false);
});
