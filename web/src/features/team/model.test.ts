import { test } from 'node:test';
import assert from 'node:assert/strict';
import { academyWords, actionWords, hoursWords, owedCents } from './model.ts';

test('team words: hours, academy, pay owed, actions', () => {
  assert.equal(hoursWords(750), '12 h 30 min');
  assert.equal(hoursWords(120), '2 h');
  assert.equal(hoursWords(0), '0 min');
  assert.equal(academyWords({ core_passed: 3, core_total: 9, passed: 10, total: 33 }), '3 of 9 basics, 10 of 33 in all');
  assert.equal(academyWords({ core_passed: 9, core_total: 9, passed: 33, total: 33 }), 'All passed');
  assert.equal(owedCents({ pay_lines_cents: 12000, commission_cents: 3450, held: false }), 15450);
  assert.equal(actionWords('UPDATE', 'field_jobs'), 'field jobs update');
});
