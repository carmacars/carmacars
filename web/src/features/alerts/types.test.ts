import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ago, callNumber, clock, filterOf, HALF_HOURS } from './types.ts';

// The staff Alerts feed and settings (migration 0466): the small helpers the list and the settings use.
test('a filter from the address, all when unknown', () => {
  assert.equal(filterOf('unread'), 'unread');
  assert.equal(filterOf('urgent'), 'urgent');
  assert.equal(filterOf('everything'), 'all');
  assert.equal(filterOf(undefined), 'all');
});

test('minutes of the day as a clock, and the half hours of the pickers', () => {
  assert.equal(clock(1260), '21:00');
  assert.equal(clock(480), '08:00');
  assert.equal(clock(0), '00:00');
  assert.equal(clock(1439), '23:59');
  assert.equal(HALF_HOURS.length, 48);
  assert.equal(HALF_HOURS[47], 1410);
});

test('how long ago, then the date in Toronto', () => {
  const now = Date.parse('2026-11-07T15:00:00Z');
  assert.equal(ago('2026-11-07T14:59:40Z', now), 'just now');
  assert.equal(ago('2026-11-07T14:55:00Z', now), '5 min ago');
  assert.equal(ago('2026-11-07T12:00:00Z', now), '3 h ago');
  assert.equal(ago('2026-11-02T15:00:00Z', now), 'Nov 2');
});

test('the Call button takes a phone number only', () => {
  assert.equal(callNumber('+16475550199'), '+16475550199');
  assert.equal(callNumber('4165550177'), '4165550177');
  assert.equal(callNumber('javascript:alert(1)'), null);
  assert.equal(callNumber('123'), null);
  assert.equal(callNumber(undefined), null);
});
