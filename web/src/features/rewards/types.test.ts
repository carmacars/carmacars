import { test } from 'node:test';
import assert from 'node:assert/strict';
import { pointsWorth, redeemSteps } from './types.ts';

test('redeem choices start at the minimum and end at the balance', () => {
  assert.deepEqual(redeemSteps(400, 500), []);
  const s = redeemSteps(1340, 500);
  assert.equal(s[0], 500);
  assert.equal(s[s.length - 1], 1300);
  assert.ok(s.every((p) => p <= 1340 && p % 100 === 0));
});
test('100 points are a dollar by default', () => {
  assert.equal(pointsWorth(1000, 1), 1000);
  assert.equal(pointsWorth(250, 0.5), 125);
});
