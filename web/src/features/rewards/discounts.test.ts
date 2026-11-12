import { test } from 'node:test';
import assert from 'node:assert/strict';
import { discountRow, discountRows, usableDiscounts, type SavedDiscount } from './discounts.ts';

// r40 (2423): the renter's saved discounts in words: status, end, countdown under 30 days, what can be used now
const d = (o: Partial<SavedDiscount>): SavedDiscount => ({ code: 'PTS1', kind: 'points', what: '$5.00 off', applies_to: 'the rental charge only', percent_bps: null, amount_cents: 500,
  free_days: null, valid_until: '2026-12-01T05:00:00Z', ends: 'Nov 30', days_left: 18, status: 'open', booking_number: null, ...o });

test('an unused code: its source, the end with days left, a countdown under 30 days, copyable', () => {
  const r = discountRow(d({}));
  assert.equal(r.source, 'From your points');
  assert.equal(r.state, 'Unused');
  assert.equal(r.until, 'Ends Nov 30 (18 days left)');
  assert.equal(r.countdown, true);
  assert.equal(r.copyable, true);
  assert.equal(discountRow(d({ days_left: 45 })).countdown, false);
  assert.equal(discountRow(d({ valid_until: null, ends: null, days_left: null })).until, 'No end date');
});

test('used, on a request and expired: the booking number, no copy', () => {
  assert.equal(discountRow(d({ status: 'used', booking_number: 'R-1234', kind: 'free_day' })).state, 'Used on booking R-1234');
  assert.equal(discountRow(d({ status: 'used', kind: 'free_day' })).source, 'Your free day (Black)');
  assert.equal(discountRow(d({ status: 'on_request', booking_number: 'R-9' })).state, 'On request R-9');
  const e = discountRow(d({ status: 'expired', days_left: null }));
  assert.equal(e.state, 'Expired');
  assert.equal(e.until, 'Ended Nov 30');
  assert.equal(e.copyable, false);
  assert.equal(e.countdown, false);
});

test('the picker: only unused codes, the soonest to end first; bad rows dropped', () => {
  const list = [d({ code: 'A', days_left: 40 }), d({ code: 'B', status: 'used' }), d({ code: 'C', days_left: 3 }), d({ code: 'D', valid_until: null, ends: null, days_left: null })];
  assert.deepEqual(usableDiscounts(list).map((x) => x.code), ['C', 'A', 'D']);
  assert.deepEqual(discountRows(null), []);
  assert.equal(discountRows([null as unknown as SavedDiscount, d({})]).length, 1);
});
