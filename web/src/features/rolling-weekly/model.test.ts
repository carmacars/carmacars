import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rollingWords, type RollingState } from './model.ts';

const base: RollingState = { on: true, since: '2026-11-01T15:00:00Z', by_name: 'Staff', end_at: null, return_at: '2026-11-20T15:00:00Z', next_return_at: '2026-11-27T15:00:00Z',
  lead_hours: 48, reminded_for: null, may_turn_on: true, weeks_paid: 2, next: null };

test('the words of a long-term weekly booking', () => {
  assert.match(rollingWords(base).line, /^Paid to .*\(2 weeks added\)\. The car stays out until the renter gives notice\. 48 hours before/);
  assert.match(rollingWords({ ...base, weeks_paid: 1 }).line, /\(1 week added\)/);
  assert.match(rollingWords({ ...base, end_at: '2026-11-25T15:00:00Z' }).line, /gave notice: the rental ends/);
  assert.doesNotMatch(rollingWords({ ...base, next_return_at: null }).line, /pay link/);
  assert.match(rollingWords({ ...base, on: false }).line, /^Off\. Turn it on/);
  assert.equal(rollingWords({ ...base, on: false, may_turn_on: false }).line, 'Off.');
  for (const x of [base, { ...base, on: false }]) assert.doesNotMatch(rollingWords(x).line, /—|–/, 'no long dashes');
});
