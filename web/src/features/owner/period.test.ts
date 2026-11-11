// Owner statement periods (1155).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { periodOf } from './period.ts';

test('a statement is labelled by its period, else its month', () => {
  assert.equal(periodOf({ statement_month: '2026-10-01', period_starts_on: '2026-10-20', period_ends_on: '2026-11-07' }), 'Oct 20 to Nov 7, 2026');
  assert.equal(periodOf({ statement_month: '2026-12-01', period_starts_on: '2026-12-08', period_ends_on: '2027-01-07' }), 'Dec 8, 2026 to Jan 7, 2027');
  assert.equal(periodOf({ statement_month: '2026-10-01', period_ends_on: '2026-11-07' }), 'Through Nov 7, 2026');
  assert.equal(periodOf({ statement_month: '2026-09-01' }), 'September 2026');
});
