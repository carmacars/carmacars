// The deposit review and the Finance countdowns (release 35 part RR, 1010).
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { levelOf, pairPhotos, stageWords, sweepDays, timeLeft, type ReviewState } from './model.ts';

const st = (x: Partial<ReviewState>): ReviewState => ({ items: 7, fleet_signed: 0, finance_signed: 0, issues: 0, places: 17, places_checked: 0, tickets_found: 0,
  fleet_done_at: null, finance_done_at: null, stage: 'fleet', ...x });

test('where a review stands, in words', () => {
  assert.equal(stageWords(null), 'No review');
  assert.equal(stageWords(st({ fleet_signed: 3 })), 'Fleet to check: 3 of 7 items');
  assert.equal(stageWords(st({ stage: 'finance', finance_signed: 2, places_checked: 5 })), 'Finance to double-check: 2 of 7 items, 5 of 17 ticket places');
  assert.equal(stageWords(st({ stage: 'done', issues: 1 })), 'Checked by Fleet and Finance: 1 issue to bill');
  assert.equal(stageWords(st({ stage: 'done' })), 'Checked by Fleet and Finance: nothing to bill');
});

test('the sweep days in words', () => {
  assert.equal(sweepDays('mon,wed,fri'), 'Monday, Wednesday and Friday');
  assert.equal(sweepDays('tue'), 'Tuesday');
});

test('pickup and return photos paired angle by angle', () => {
  const p = (seq: number, shot: string, angle: string | null = null, damage_label: string | null = null) => ({ seq, shot, angle, damage_label });
  const rows = pairPhotos([p(1, 'front'), p(2, 'rear'), p(3, 'other', 'dashboard')], [p(1, 'front'), p(2, 'other', 'dashboard'), p(3, 'rear'), p(4, 'damage_closeup', null, 'D1')]);
  assert.deepEqual(rows.map((r) => [r.key, r.out?.seq ?? null, r.in?.seq ?? null]), [['front', 1, 1], ['rear', 2, 3], ['dashboard', 3, 2], ['damage:D1', null, 4]]);
  const twice = pairPhotos([p(1, 'front')], [p(1, 'front'), p(2, 'front')]);
  assert.deepEqual(twice.map((r) => r.key), ['front', 'front#2']);
});

test('countdown levels and time left', () => {
  const now = Date.parse('2026-11-08T12:00:00Z');
  assert.equal(levelOf('2026-11-09T06:00:00Z', now), 'red');
  assert.equal(levelOf('2026-11-10T06:00:00Z', now), 'amber');
  assert.equal(levelOf('2026-11-12T06:00:00Z', now), 'ok');
  assert.equal(levelOf('2026-11-07T06:00:00Z', now), 'red');
  assert.equal(levelOf(null, now), null);
  assert.equal(timeLeft('2026-11-10T16:00:00Z', now), 'in 2 days 4 h');
  assert.equal(timeLeft('2026-11-08T17:30:00Z', now), 'in 5 h 30 min');
  assert.equal(timeLeft('2026-11-08T09:00:00Z', now), '3 h ago');
  assert.equal(timeLeft('2026-11-08T12:20:00Z', now), 'in 20 min');
});
