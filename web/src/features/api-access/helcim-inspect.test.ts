// r50: the connector's Helcim reads (helcim_find_payments, helcim_account) against faked Helcim transactions.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { accountView, findHelcimPayments, mountainDay } from './helcim-inspect.ts';

const tx = (id: number, over: Record<string, unknown> = {}) => ({ transactionId: id, dateCreated: '2026-11-24 09:00:00', status: 'APPROVED', type: 'purchase', amount: 120.5,
  currency: 'CAD', cardNumber: '424242******4242', cardType: 'VI', cardToken: 'secret-token', customerCode: 'CC1', ...over });

test('helcim_find_payments: approved payments of the window, recorded or untied, never a token', async () => {
  const list = async () => [tx(1), tx(2, { status: 'DECLINED' }), tx(3, { type: 'refund' }), tx(4, { type: 'preauth', amount: 500 }), tx(5, { amount: 99 })];
  const out = await findHelcimPayments(list, { from: new Date('2026-11-23T12:00:00Z'), to: new Date('2026-11-24T20:00:00Z'), amount_cents: null },
    async (ids) => { assert.deepEqual(ids.sort(), [1, 4, 5]); return { 1: { intent: 'hc_a', status: 'succeeded', booking_number: 'CC-10482', recorded: true } }; });
  assert.deepEqual(out.payments.map((p) => p.transaction_id), [5, 4, 1]);
  assert.equal(out.untied, 2);
  assert.equal(out.payments.find((p) => p.transaction_id === 1)?.booking_number, 'CC-10482');
  assert.equal(out.payments[0]!.card, 'visa 4242');
  assert.ok(!JSON.stringify(out).includes('secret-token'));
  const one = await findHelcimPayments(list, { from: new Date('2026-11-23T12:00:00Z'), to: new Date('2026-11-24T20:00:00Z'), amount_cents: 50000 }, async () => ({}));
  assert.deepEqual(one.payments.map((p) => p.transaction_id), [4]);
});

test('helcim_account: connected, the webhook, and the last day in cents', () => {
  const v = accountView(true, null, [tx(1), tx(2, { type: 'preauth', amount: 500 }), tx(3, { status: 'DECLINED' })] as never, true, null);
  assert.equal(v.connected, true);
  assert.deepEqual(v.last_24_hours, { approved: 2, declined: 1, charged_cents: 12050, held_cents: 50000, refunded_cents: 0 });
  assert.equal(mountainDay(new Date('2026-11-25T03:00:00Z')), '2026-11-24');
});
