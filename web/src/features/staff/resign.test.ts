import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dayWords, daysBetween, endsNow, lastDayProblem, nextSteps, resignBadge, type ResignFacts } from './resign.ts';

const field: ResignFacts = { staff: true, active: true, portal: 'field', today: '2026-11-25', notice_days: 7, can_today: false, earliest: '2026-11-26', latest: '2027-03-25',
  default_last_day: '2026-12-02', words: { final_pay_text: 'Final pay on the pay date.', return_text: 'Return every key.', pay_timing: 'every two weeks', period_end: '2026-12-05' } };
const onboarding: ResignFacts = { ...field, portal: 'va', can_today: true, in_onboarding: true, earliest: '2026-11-25' };

test('resign (5020): a calendar day in words, never shifted by the time zone', () => {
  assert.equal(dayWords('2026-12-02'), 'Wed, Dec 2, 2026');
  assert.equal(dayWords('2027-01-01'), 'Fri, Jan 1, 2027');
  assert.equal(dayWords(null), '');
  assert.equal(daysBetween('2026-11-25', '2026-12-02'), 7);
});

test('resign (5020): the last day is from tomorrow, today only in onboarding or the trial period, within 120 days', () => {
  assert.equal(lastDayProblem(field, '2026-12-02'), null);
  assert.match(lastDayProblem(field, '2026-11-25') ?? '', /Thu, Nov 26, 2026 at the earliest/);
  assert.equal(lastDayProblem(onboarding, '2026-11-25'), null);
  assert.match(lastDayProblem(field, '2027-06-01') ?? '', /120 days/);
  assert.equal(lastDayProblem(field, ''), 'Choose your last day.');
});

test('resign (5020): the confirm step says what happens next', () => {
  const s = nextSteps(field, '2026-12-02');
  assert.match(s[0] ?? '', /until the end of Wed, Dec 2, 2026/);
  assert.ok(s.some((x) => /shifts and jobs after your last day/.test(x)));
  assert.ok(s.includes('Final pay on the pay date.') && s.includes('Return every key.'));
  assert.match(s[s.length - 1] ?? '', /Withdraw it here any time up to Wed, Dec 2, 2026/);
  assert.ok(nextSteps(field, '2026-11-28').some((x) => /less than the 7 days' notice/.test(x)));
  assert.ok(!nextSteps(field, '2026-12-02').some((x) => /less than/.test(x)));
});

test('resign (5020): today in onboarding ends the access at once, with no withdraw', () => {
  assert.equal(endsNow(onboarding, '2026-11-25'), true);
  const s = nextSteps(onboarding, '2026-11-25');
  assert.match(s[0] ?? '', /access ends as soon as you confirm/);
  assert.ok(!s.some((x) => /Withdraw/.test(x)));
});

test('resign (5020): the Admin badge', () => {
  assert.deepEqual(resignBadge({ status: 'pending', last_day: '2026-12-02', ended_at: null }, true), { label: 'Resigning: last day Wed, Dec 2, 2026', tone: 'amber' });
  assert.deepEqual(resignBadge({ status: 'ended', last_day: '2026-12-02', ended_at: '2026-12-03T05:00:00Z' }, false), { label: 'Resigned: last day Wed, Dec 2, 2026', tone: 'grey' });
  assert.equal(resignBadge({ status: 'ended', last_day: '2026-12-02', ended_at: 'x' }, true), null);
  assert.equal(resignBadge({ status: 'withdrawn', last_day: '2026-12-02', ended_at: null }, true), null);
  assert.equal(resignBadge(null, true), null);
});
