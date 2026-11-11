import { test } from 'node:test';
import assert from 'node:assert/strict';
import { beatDue, breaksWords, clockLine, hoursWords, nudgeDue, type ClockState } from './model.ts';

test('1061: the clock line', () => {
  assert.equal(hoursWords(125), '2 h 5 min');
  assert.equal(hoursWords(45), '45 min');
  assert.equal(hoursWords(120), '2 h');
  const base: ClockState = { open: null, start_today: '2026-11-09T14:00:00Z', today_minutes: 0, week_minutes: 300, entries: [] };
  assert.match(clockLine(base, Date.parse('2026-11-09T15:00:00Z')), /^Your day started at 9:00.*clock in now\.$/);
  assert.match(clockLine(base, Date.parse('2026-11-09T12:00:00Z')), /^Your day starts at 9:00/);
  assert.match(clockLine({ ...base, open: { id: 'e', started_at: '2026-11-09T14:05:00Z', minutes: 65 }, today_minutes: 65 }), /^Clocked in since 9:05.*\(1 h 5 min\)/);
});

test('1800: breaks in words, the beat at most once a minute, the nudge', () => {
  assert.equal(breaksWords({ count: 0, minutes: 0, longest: 0 }), 'No breaks');
  assert.equal(breaksWords({ count: 2, minutes: 25, longest: 15 }), '2 breaks, 25 min, longest 15 min');
  assert.equal(beatDue(0, 59_000, true), false);
  assert.equal(beatDue(0, 60_000, true), true);
  assert.equal(beatDue(0, 60_000, false), false);
  assert.equal(beatDue(0, 300_000, false), true);
  assert.equal(nudgeDue(0, 8 * 60_000, 8, true, true), true);
  assert.equal(nudgeDue(0, 7 * 60_000, 8, true, true), false);
  assert.equal(nudgeDue(0, 9 * 60_000, 8, false, true), false);
  assert.equal(nudgeDue(0, 9 * 60_000, 8, true, false), false);
});
