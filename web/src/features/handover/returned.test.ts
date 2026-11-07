import { test } from 'node:test';
import assert from 'node:assert/strict';
import { showReturned } from './returned.ts';

// 2026-11-07 15:00 UTC is 10:00 in Toronto
const now = new Date('2026-11-07T15:00:00Z');

test('Returned shows on a car on rent that is overdue or due back today', () => {
  assert.equal(showReturned({ status: 'on_rent', return_at: '2026-11-06T15:00:00Z' }, now), true);
  assert.equal(showReturned({ status: 'on_rent', return_at: '2026-11-07T22:00:00Z' }, now), true);
  // 23:30 Toronto tonight is 04:30 UTC tomorrow: still due today
  assert.equal(showReturned({ status: 'on_rent', return_at: '2026-11-08T04:30:00Z' }, now), true);
});

test('Not before the return day, nor once the car is back', () => {
  assert.equal(showReturned({ status: 'on_rent', return_at: '2026-11-08T15:00:00Z' }, now), false);
  assert.equal(showReturned({ status: 'returned', return_at: '2026-11-06T15:00:00Z' }, now), false);
  assert.equal(showReturned({ status: 'confirmed', return_at: '2026-11-06T15:00:00Z' }, now), false);
  assert.equal(showReturned({ status: 'on_rent', return_at: null }, now), false);
});
