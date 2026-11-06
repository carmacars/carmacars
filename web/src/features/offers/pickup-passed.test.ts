import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ASK_REOPEN_DONE, PICKUP_PASSED, askPickupError, pickupPassed } from './pickup-passed.ts';

test('0569: a pickup at or before now has passed; a future, empty or unreadable one has not', () => {
  const now = Date.parse('2026-11-06T20:00:00Z');
  assert.equal(pickupPassed('2026-11-06T19:59:00Z', now), true);
  assert.equal(pickupPassed('2026-11-06T20:00:00Z', now), true);
  assert.equal(pickupPassed('2026-11-06T22:00:00Z', now), false);
  assert.equal(pickupPassed('', now), false);
  assert.equal(pickupPassed(null, now), false);
  assert.equal(pickupPassed('not a date', now), false);
  assert.equal(PICKUP_PASSED, 'Pickup time has passed: update it');
});

test('0569: the renter\'s ask: no pickup is fine, a future one is fine, a past or unreadable one is refused', () => {
  const now = Date.parse('2026-11-06T20:00:00Z');
  assert.equal(askPickupError(null, now), null);
  assert.equal(askPickupError('2026-11-08T15:00:00Z', now), null);
  assert.match(askPickupError('2026-11-06T10:00:00Z', now) ?? '', /future/);
  assert.match(askPickupError('soon', now) ?? '', /future/);
  assert.match(ASK_REOPEN_DONE, /asked the team to reopen it/);
});
