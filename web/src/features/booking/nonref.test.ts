import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nonRefAllowed } from './nonref.ts';

test('the non-refundable discount needs the pickup at least the set days ahead (0241)', () => {
  assert.equal(nonRefAllowed('2026-11-07', '2026-10-31', 7), true);
  assert.equal(nonRefAllowed('2026-11-06', '2026-10-31', 7), false);
  assert.equal(nonRefAllowed('2026-11-01', '2026-10-31', 0), true);
  assert.equal(nonRefAllowed('', '2026-10-31', 7), true);
});
