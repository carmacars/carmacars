import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clockWords, daysWords, dutyWords, scheduleWords } from './model.ts';

test('schedule words: the three role defaults read as the owner said them', () => {
  assert.equal(scheduleWords({ id: 'a', function: 'cs', user_id: null, weekdays: [1, 3, 4, 5, 6, 7], month_days: [], start: '08:00', end: '18:00', extra_days_per_week: 0, starts_on: null, note: null }),
    '6 days a week (Tuesday off), 8:00 am to 6:00 pm Toronto');
  assert.equal(scheduleWords({ id: 'b', function: 'finance', user_id: null, weekdays: [1, 3, 5], month_days: [10, 15], start: '10:00', end: '19:00', extra_days_per_week: 1, starts_on: '2026-11-11', note: null }),
    'Monday, Wednesday and Friday, plus the 10th and the 15th of each month, 10:00 am to 7:00 pm Toronto; up to 1 extra day a week with overflow work');
  assert.equal(daysWords({ weekdays: [1, 2, 3, 4, 5, 6], month_days: [] }), '6 days a week (Sunday off)');
  assert.equal(clockWords('12:30'), '12:30 pm');
  assert.equal(daysWords({ weekdays: [], month_days: [1, 22] }), 'the 1st and the 22nd of each month');
});

test('duty words: late, absent, working, extra day', () => {
  const base = { user_id: 'u', name: 'A', functions: ['cs'], on_shift: true };
  assert.equal(dutyWords({ ...base, clocked_in: true, today: { scheduled: true, late: true, late_minutes: 25 } }), 'Working, started 25 min late');
  assert.equal(dutyWords({ ...base, clocked_in: false, today: { scheduled: true, late: true, late_minutes: 40 } }), 'Late 40 min, not clocked in');
  assert.equal(dutyWords({ ...base, clocked_in: false, today: { scheduled: true, absent: true } }), 'Absent');
  assert.equal(dutyWords({ ...base, clocked_in: true, today: { scheduled: false } }), 'Clocked in (extra day)');
});
