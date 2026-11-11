import { test } from 'node:test';
import assert from 'node:assert/strict';
import { needHref, needProgress, needsAction, orderNeeds, showNeeds, stillNeededOf, type NeedItem } from './still-needed.ts';

const item = (key: string, status: NeedItem['status'], path: string | null = 'verify'): NeedItem => ({ key, label: key, status, reason: status === 'rejected' ? 'Blurry' : null, action: path ? { label: 'Go', path } : null });

test('the list as the database sent it; none when empty or missing', () => {
  assert.equal(stillNeededOf(null), null);
  assert.equal(stillNeededOf({ still_needed: { items: [] } }), null);
  const s = stillNeededOf({ still_needed: { items: [item('dob', 'done', null), item('coverage', 'missing'), { key: 'x', label: 'x', status: 'odd' } as never] } })!;
  assert.deepEqual([s.total, s.done, s.complete], [2, 1, false]);
});

test('rejected first, then needed, then under review, then done (stable within each)', () => {
  const o = orderNeeds([item('a', 'done'), item('b', 'review'), item('c', 'missing'), item('d', 'rejected'), item('e', 'missing')]);
  assert.deepEqual(o.map((i) => i.key), ['d', 'c', 'e', 'b', 'a']);
});

test('progress: done counts whole, under review half; what is left to do', () => {
  const s = stillNeededOf({ still_needed: { items: [item('a', 'done'), item('b', 'review'), item('c', 'missing'), item('d', 'rejected')] } })!;
  assert.equal(needProgress(s), 38);
  assert.equal(needsAction(s), 2);
  assert.equal(showNeeds(s), true);
  const all = stillNeededOf({ still_needed: { items: [item('a', 'done')] } })!;
  assert.equal(needProgress(all), 100);
  assert.equal(showNeeds(all), false);
});

test('where an action goes', () => {
  assert.equal(needHref('CC-10003', 'verify'), '/account/bookings/CC-10003/verify');
  assert.equal(needHref('CC-10003', '#questions'), '/account/bookings/CC-10003#questions');
  assert.equal(needHref('CC-10003', '/account/profile'), '/account/profile');
});
