import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clockLine, hoursWords, type ClockState } from './model.ts';

test('1061: the clock line', () => {
  assert.equal(hoursWords(125), '2 h 5 min');
  assert.equal(hoursWords(45), '45 min');
  assert.equal(hoursWords(120), '2 h');
  const base: ClockState = { open: null, start_today: '2026-11-09T14:00:00Z', today_minutes: 0, week_minutes: 300, entries: [] };
  assert.match(clockLine(base, Date.parse('2026-11-09T15:00:00Z')), /^Your day started at 9:00.*clock in now\.$/);
  assert.match(clockLine(base, Date.parse('2026-11-09T12:00:00Z')), /^Your day starts at 9:00/);
  assert.match(clockLine({ ...base, open: { id: 'e', started_at: '2026-11-09T14:05:00Z', minutes: 65 }, today_minutes: 65 }), /^Clocked in since 9:05.*\(1 h 5 min\)/);
});
