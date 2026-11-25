import { test } from 'node:test';
import assert from 'node:assert/strict';
import { instantWhyNot } from './book-choice-rules.ts';

test('r50 (3900): Book instantly is open only to a renter who may book at once, for a car and dates that can be booked at once', () => {
  assert.equal(instantWhyNot({ canBookNow: true, carOk: true }), null);
  assert.match(instantWhyNot({ canBookNow: false, carOk: true }) ?? '', /Gold Rewards/);
  assert.match(instantWhyNot({ canBookNow: true, carOk: false }) ?? '', /send a request/);
  // not eligible wins: the renter is told what opens it
  assert.match(instantWhyNot({ canBookNow: false, carOk: false }) ?? '', /Gold Rewards/);
});
