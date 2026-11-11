// Price limits (1205): dollars typed as cents and the limits in words.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { limitsText, toCents } from './price-limits.ts';

test('dollars typed: empty is no limit, a bad amount is refused', () => {
  assert.equal(toCents(''), null);
  assert.equal(toCents(' '), null);
  assert.equal(toCents('80'), 8000);
  assert.equal(toCents('$1,250.5'), 125050);
  assert.equal(toCents('0'), undefined);
  assert.equal(toCents('-5'), undefined);
  assert.equal(toCents('12.345'), undefined);
  assert.equal(toCents('abc'), undefined);
});

test('the limits in words', () => {
  assert.equal(limitsText({ min_daily_cents: 8000, max_daily_cents: 25000 }), '$80 to $250 a day');
  assert.equal(limitsText({ min_daily_cents: 8000, max_daily_cents: null }), 'at least $80 a day');
  assert.equal(limitsText({ min_daily_cents: null, max_daily_cents: 25000 }), 'at most $250 a day');
  assert.equal(limitsText({ min_daily_cents: null, max_daily_cents: null }), 'no limits');
});
