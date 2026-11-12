// when(): the same words on the server and in every browser, in Toronto time (r40, React error 418 on bookings).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { when } from './model.ts';

test('when: Toronto date and time in our own words', () => {
  assert.equal(when('2026-11-12T20:05:00Z'), 'Thu, Nov 12, 2026, 3:05 p.m.');
  assert.equal(when('2026-07-01T04:30:00Z'), 'Wed, Jul 1, 2026, 12:30 a.m.');
  assert.equal(when('2026-09-07T17:00:00Z', false), 'Mon, Sep 7, 2026');
  assert.equal(when(null), '');
  assert.equal(when('not a date'), '');
});
