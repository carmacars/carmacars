import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { STRIPE_EVENTS, stripeEventCalls } from './stripe-events.ts';

// 0132: the Stripe events the site did not listen to, mapped to their database calls; the deploy subscribes to them all.
test('a refund settling, with the site refund it belongs to', () => {
  const c = stripeEventCalls('refund.updated', { object: 'refund', id: 're_1', status: 'succeeded', amount: 5000, payment_intent: 'pi_1', charge: 'ch_1', metadata: { refund_id: 'r-uuid' } });
  assert.deepEqual(c, [{ fn: 'server_stripe_refund_event', p: { refund_id: 're_1', status: 'succeeded', amount_cents: 5000, intent_id: 'pi_1', charge_id: 'ch_1', site_refund_id: 'r-uuid', failure_reason: null } }]);
});
test('a refund made in the dashboard: each refund of the charge, or the amount when the list is left out', () => {
  assert.equal(stripeEventCalls('charge.refunded', { object: 'charge', id: 'ch_2', payment_intent: 'pi_2', refunds: { data: [{ id: 're_a', status: 'succeeded', amount: 100 }, { id: 're_b', status: 'pending', amount: 50 }] } }).length, 2);
  const c = stripeEventCalls('charge.refunded', { object: 'charge', id: 'ch_3', payment_intent: { id: 'pi_3' }, amount_refunded: 700 });
  assert.equal(c[0]!.p.refund_id, 'ch_3:700');
  assert.equal(c[0]!.p.intent_id, 'pi_3');
});
test('a dispute with its evidence date', () => {
  const c = stripeEventCalls('charge.dispute.created', { object: 'dispute', id: 'dp_1', status: 'needs_response', amount: 9000, reason: 'fraudulent', charge: 'ch_9', payment_intent: 'pi_9', evidence_details: { due_by: 1800000000 } });
  assert.equal(c[0]!.fn, 'server_stripe_dispute_event');
  assert.equal(c[0]!.p.evidence_due_at, new Date(1800000000 * 1000).toISOString());
});
test('a charge the bank wants confirmed; other events make no call', () => {
  assert.equal(stripeEventCalls('payment_intent.requires_action', { object: 'payment_intent', id: 'pi_4', metadata: { payment_id: 'p1', purpose: 'staff_charge' } })[0]!.fn, 'server_stripe_requires_action');
  assert.deepEqual(stripeEventCalls('payment_intent.requires_action', { object: 'payment_intent', id: 'pi_6', metadata: { purpose: 'booking_total' } }), []);
  assert.deepEqual(stripeEventCalls('payment_intent.succeeded', { object: 'payment_intent', id: 'pi_5' }), []);
});
test('the deploy subscribes the endpoint to every event the route handles', () => {
  const sh = readFileSync(new URL('../../../scripts/deploy/supabase.sh', import.meta.url), 'utf8');
  const m = sh.match(/local events=\(([^)]*)\)/);
  assert.ok(m, 'the events list in supabase.sh');
  assert.deepEqual(m![1]!.split(/\s+/).filter(Boolean).sort(), [...STRIPE_EVENTS].sort());
});
