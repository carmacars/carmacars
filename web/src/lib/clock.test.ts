import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clockSecondsTo, clockTo, dayClockTo, torontoAt, weekdayClockTo, weekdayDateTo } from './clock.ts';

// r35: Toronto times written with our own words, so the server's page and the browser's first draw match (React 418).
test('a time of day in Toronto, the same words whatever the ICU', () => {
  // 20:05:09 UTC on Nov 8, 2026 is 3:05:09 p.m. in Toronto (EST, UTC-5)
  assert.equal(clockTo('2026-11-08T20:05:09Z'), '3:05 p.m.');
  assert.equal(clockSecondsTo('2026-11-08T20:05:09Z'), '3:05:09 p.m.');
  assert.equal(dayClockTo('2026-11-08T20:05:09Z'), 'Nov 8, 3:05 p.m.');
  assert.equal(weekdayClockTo('2026-11-08T20:05:09Z'), 'Sun 3:05 p.m.');
  assert.equal(weekdayDateTo('2026-11-08T20:05:09Z'), 'Sun Nov 8');
  // midnight and noon; summer time (EDT, UTC-4)
  assert.equal(clockTo('2026-11-09T05:00:00Z'), '12:00 a.m.');
  assert.equal(clockTo('2026-07-01T16:30:00Z'), '12:30 p.m.');
  assert.equal(clockTo(Date.UTC(2026, 6, 1, 4, 7)), '12:07 a.m.');
  assert.equal(torontoAt('2026-07-01T03:59:00Z')?.day, 30);
  assert.equal(clockTo('not a date'), '');
});
