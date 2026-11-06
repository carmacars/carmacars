// Partner invoices (0547): the builder's arithmetic matches the database's (a percentage of the partner's total, or
// quantity times the unit; 13% HST per line when on).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lineCents, linePayload, totals } from './model.ts';

test('a percentage of the partner\'s claim total, with HST', () => {
  assert.deepEqual(lineCents({ description: 'x', quantity: '1', unit: '', percent: '10', base: '$12,500.00', hst: true }), { amount: 125000, hst: 16250 });
});
test('quantity times the unit, HST off', () => {
  assert.deepEqual(lineCents({ description: 'x', quantity: '3', unit: '150', percent: '', base: '', hst: false }), { amount: 45000, hst: 0 });
});
test('the totals add the lines and their HST', () => {
  const t = totals([{ description: 'a', quantity: '1', unit: '100', percent: '', base: '', hst: true }, { description: 'b', quantity: '1', unit: '', percent: '15', base: '1000', hst: false }]);
  assert.deepEqual(t, { subtotal: 25000, hst: 1300, total: 26300 });
});
test('the payload carries basis points and cents', () => {
  assert.deepEqual(linePayload({ description: 'd', quantity: '', unit: '', percent: '12.5', base: '2000', hst: true }), { description: 'd', quantity: '1', unit_cents: 0, percent_bps: 1250, base_cents: 200000, hst: true });
});
