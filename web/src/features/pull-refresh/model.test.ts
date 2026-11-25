import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PULL, pullDistance } from './model.ts';

test('r50 pull to refresh: follows the finger, stiffens, reaches the trigger, never past the max', () => {
  assert.equal(pullDistance(0), 0);
  assert.equal(pullDistance(-30), 0);
  assert.equal(pullDistance(20), 12);
  assert.ok(pullDistance(80) < PULL.trigger, 'a short pull does not refresh');
  assert.ok(pullDistance(170) >= PULL.trigger, 'a deliberate pull does');
  assert.equal(pullDistance(2000), PULL.max);
  assert.ok(pullDistance(100) > pullDistance(90));
});
