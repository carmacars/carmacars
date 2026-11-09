import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chargeRows, unlinkedSince, type ChargeIn } from './stripe-unlinked.ts';

const ch = (id: string, x: Partial<ChargeIn> = {}): ChargeIn => ({ id, intentId: `pi_${id.slice(3)}`, amountCents: 5000, refundedCents: 0, currency: 'CAD', created: 1_800_000_000,
  status: 'succeeded', captured: true, email: ' Pat@Example.test ', name: ' Pat Example ', last4: '4242', brand: 'visa', description: null, metadata: {}, ...x });

test('r35: the nightly check sends the paid, captured charges once, with what finds their booking', () => {
  const rows = chargeRows([ch('ch_a', { metadata: { booking_number: 'cc-1042' } }), ch('ch_a'), ch('ch_b', { status: 'failed' }), ch('ch_c', { captured: false }),
    ch('ch_d', { amountCents: 0 }), ch('ch_e', { last4: '42', email: null })]);
  assert.deepEqual(rows.map((r) => r.id), ['ch_a', 'ch_e']);
  assert.deepEqual([rows[0]!.email, rows[0]!.name, rows[0]!.currency, rows[0]!.booking_number, rows[0]!.intent_id], ['pat@example.test', 'Pat Example', 'cad', 'CC-1042', 'pi_a']);
  assert.deepEqual([rows[1]!.last4, rows[1]!.email], [null, null]);
});

test('r35: the check reads 60 days back', () => {
  assert.equal(unlinkedSince(Date.UTC(2026, 10, 8)), Math.floor(Date.UTC(2026, 8, 9) / 1000));
});
