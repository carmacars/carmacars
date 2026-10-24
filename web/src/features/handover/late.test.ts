import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fmtDuration, lateLabel, lateMinutes } from './late.ts';

const due = '2026-10-24T15:00:00.000Z';

test('a car back on time or early is not late', () => {
  assert.equal(lateMinutes({ status: 'returned', return_at: due, checked_in_at: '2026-10-24T14:30:00.000Z' }), 0);
  assert.equal(lateLabel({ status: 'returned', return_at: due, checked_in_at: '2026-10-24T14:30:00.000Z' }), null);
});

test('the database minutes win once checked in', () => {
  assert.equal(lateMinutes({ status: 'returned', return_at: due, checked_in_at: '2026-10-24T17:10:00.000Z', minutes_late: 130 }), 130);
  assert.equal(lateLabel({ status: 'closed', return_at: due, checked_in_at: '2026-10-24T17:10:00.000Z', minutes_late: 130 }), 'Late by 2 h 10 min');
});

test('a car still out past its time is overdue, counted to now', () => {
  const now = new Date('2026-10-24T15:45:00.000Z');
  assert.equal(lateLabel({ status: 'on_rent', return_at: due }, now), 'Overdue by 45 min');
  assert.equal(lateLabel({ status: 'confirmed', return_at: due }, now), null);
});

test('durations read in minutes, hours and days', () => {
  assert.equal(fmtDuration(0), '0 min');
  assert.equal(fmtDuration(59), '59 min');
  assert.equal(fmtDuration(60), '1 h');
  assert.equal(fmtDuration(1500), '1 d 1 h');
  assert.equal(fmtDuration(2880), '2 d');
});
