import { test } from 'node:test';
import assert from 'node:assert/strict';
import { depositChoices, moneyLine, pastDue, type EndedMoney } from './ended.ts';

test('1063: the deposit of an ended trip in words, and the choices', () => {
  const m: EndedMoney = { deposit_cents: 50000, deposit_status: 'held', hold_expired: false, deposit_waived: false, deposit_due: false, owed_cents: 18300, late_fee_cents: 18300, statement: true };
  assert.equal(moneyLine(m), '$500.00 held, $183.00 owed (late $183.00)');
  assert.match(moneyLine({ ...m, hold_expired: true }), /expired: settled by expiry/);
  assert.equal(moneyLine({ ...m, deposit_cents: 0, deposit_due: true }), 'No deposit taken');
  assert.deepEqual(depositChoices().map(([v]) => v), ['balance', 'late_fee', 'full', '']);
  assert.equal(pastDue(30), '1 d');
});
