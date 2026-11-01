import { test } from 'node:test';
import assert from 'node:assert/strict';
import { IDLE_AFTER_MS, pollDue } from './poll.ts';

test('in use: the screen\'s own pace', () => {
  const t0 = 1_000_000;
  assert.equal(pollDue(t0 + 5_000, t0, t0, 5_000), true);
  assert.equal(pollDue(t0 + 3_000, t0, t0, 5_000), false);
});
test('untouched for two minutes: once a minute at most; a touch brings the pace back', () => {
  const t0 = 1_000_000, active = t0 - IDLE_AFTER_MS;
  assert.equal(pollDue(t0 + 5_000, t0, active, 5_000), false);
  assert.equal(pollDue(t0 + 60_000, t0, active, 5_000), true);
  assert.equal(pollDue(t0 + 5_000, t0, t0 + 4_000, 5_000), true);
  assert.equal(pollDue(t0 + 60_000, t0, active, 300_000), false, 'a slower screen keeps its own pace');
});
