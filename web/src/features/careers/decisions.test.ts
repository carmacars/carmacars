import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DECISIONS, nextTorontoMorning } from './model.ts';

// Release 23 (0226): the rubric's decisions and the time "Send all decision emails" can be scheduled for.
test('decisions: Good fit for Sales instead is one of the rubric choices', () => {
  assert.deepEqual(DECISIONS.map(([k]) => k), ['hire', 'maybe', 'no', 'sales', 'no_show']);
});

test('next Monday 9:00 am Toronto, across the daylight saving change', () => {
  // Saturday October 31, 2026 (EDT): Monday November 2 is EST (-5): 14:00 UTC
  assert.equal(nextTorontoMorning(1, 9, new Date('2026-10-31T16:00:00Z')).iso, '2026-11-02T14:00:00.000Z');
  // a Monday morning asks for the next Monday, never today
  assert.equal(nextTorontoMorning(1, 9, new Date('2026-11-02T13:00:00Z')).iso, '2026-11-09T14:00:00.000Z');
  // tomorrow in summer (EDT, -4)
  assert.equal(nextTorontoMorning(null, 9, new Date('2026-07-01T16:00:00Z')).iso, '2026-07-02T13:00:00.000Z');
});
