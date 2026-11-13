// Owner statement periods (1155).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { partialMonth, partialMonthNotice, periodOf } from './period.ts';

test('a statement is labelled by its period, else its month', () => {
  assert.equal(periodOf({ statement_month: '2026-10-01', period_starts_on: '2026-10-20', period_ends_on: '2026-11-07' }), 'Oct 20 to Nov 7, 2026');
  assert.equal(periodOf({ statement_month: '2026-12-01', period_starts_on: '2026-12-08', period_ends_on: '2027-01-07' }), 'Dec 8, 2026 to Jan 7, 2027');
  assert.equal(periodOf({ statement_month: '2026-10-01', period_ends_on: '2026-11-07' }), 'Through Nov 7, 2026');
  assert.equal(periodOf({ statement_month: '2026-09-01' }), 'September 2026');
});

// r44 (2783): a statement shorter than a full period says so on its page, in the owner portal and on the PDF
test('a partial month is named; a full period and a longer first period are not', () => {
  assert.equal(partialMonthNotice({ statement_month: '2026-10-01', period_starts_on: '2026-10-24', period_ends_on: '2026-11-07' }),
    'This statement covers a partial month (Oct 24 to Nov 7, 2026), not a full month.');
  assert.equal(partialMonth({ period_starts_on: '2026-10-08', period_ends_on: '2026-11-07' }), false, 'Oct 8 to Nov 7 is the full period');
  assert.equal(partialMonth({ period_starts_on: '2026-10-09', period_ends_on: '2026-11-07' }), true);
  assert.equal(partialMonth({ period_starts_on: '2026-09-02', period_ends_on: '2026-11-07' }), false, 'longer, not partial');
  assert.equal(partialMonth({ period_starts_on: '2026-02-20', period_ends_on: '2026-03-07' }), true, 'across February');
  assert.equal(partialMonth({ period_starts_on: '2026-02-08', period_ends_on: '2026-03-07' }), false);
  assert.equal(partialMonth({ period_ends_on: '2026-11-07' }), false, 'no start: not claimed');
  assert.equal(partialMonth({ period_starts_on: '2026-10-08', period_ends_on: '2026-11-07', partial_month: true }), true, 'the database answer wins');
  assert.equal(partialMonthNotice({ statement_month: '2026-10-01', period_starts_on: '2026-10-08', period_ends_on: '2026-11-07' }), null);
  assert.doesNotMatch(partialMonthNotice({ period_starts_on: '2026-10-24', period_ends_on: '2026-11-07' })!, /\u2014|\u2013/);
});
