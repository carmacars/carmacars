import { test } from 'node:test';
import assert from 'node:assert/strict';
import { depositChoiceText, depositDue, depositStateLine, type DepositState } from './deposit-state.ts';

const s: DepositState = { card_cents: 30000, offline_cents: 60000, debit_cents: 60000, offline_on: true, multiplier: 2, set_by_staff: false, method: 'e_transfer',
  required_cents: 60000, taken_cents: 20000, owed_cents: 40000, over_cents: 0 };
const fmt = (c: number) => `$${(c / 100).toFixed(2)}`;

test('the deposit by each way of paying, and what is left to take', () => {
  assert.equal(depositDue(s, 0)('e_transfer'), 40000);
  assert.equal(depositDue(s, 0)('card'), 10000);
  assert.equal(depositDue(null, 30000)('cash'), 30000);
  assert.equal(depositStateLine(s, fmt), 'Credit card hold $300.00; e-Transfer or cash $600.00 (2x)');
  assert.equal(depositStateLine({ ...s, offline_cents: 30000 }, fmt), null);
  assert.match(depositChoiceText(s, fmt) ?? '', /\$600\.00 paid by e-Transfer, cash or debit \(2x\)/);
});
