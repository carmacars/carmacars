import { test } from 'node:test';
import assert from 'node:assert/strict';
import { draftHref, draftLine, draftMissing, seesUnfinished, split, type Draft } from './unfinished.ts';

// r48 ops: Unfinished rentals only where it belongs (Admin and Sales, Today and Bookings), each draft opening its own form.
const d = (o: Partial<Draft> = {}): Draft => ({ id: 'd1', kind: 'rental', title: 'Quinn Quick', quick: false, updated_at: '2026-11-20T20:40:00Z', by: 'Sam Sales', mine: false, vehicle: '2024 Kia Forte', held_until: null, missing: [], ...o });

test('the section is for an Admin and for Sales, nobody else', () => {
  assert.equal(seesUnfinished({ role: 'admin' }), true);
  assert.equal(seesUnfinished({ role: 'staff', fn: 'sales' }), true);
  for (const fn of ['cs', 'fleet', 'finance', null]) assert.equal(seesUnfinished({ role: 'staff', fn }), false, String(fn));
});

test('a draft opens the form it was typed in, per portal', () => {
  assert.equal(draftHref(d(), '/admin'), '/admin/bookings/new?draft=d1');
  assert.equal(draftHref(d(), '/staff'), '/staff/bookings/new?draft=d1');
  assert.equal(draftHref(d(), '/staff/field'), '/staff/field/rentals/new?draft=d1');
  assert.equal(draftHref(d({ kind: 'offer' }), '/admin'), '/admin/offers/new?draft=d1');
  assert.equal(draftHref(d({ kind: 'offer' }), '/staff/field'), '/staff/offers/new?draft=d1');
});

test('the line says who saved it, when (Toronto) and the car', () => {
  assert.match(draftLine(d()), /^Sam Sales · Nov\.? 20, 3:40 p\.m\. · 2024 Kia Forte$/);
  assert.match(draftLine(d({ mine: true, title: null })), /^You · /);
  assert.ok(!draftLine(d({ title: '2024 Kia Forte' })).includes('Kia'), 'the car is not said twice');
  assert.match(draftLine(d({ by: null })), /^Someone/);
});

test('a long list of what is missing is cut to five chips and a count; a long list of drafts shows four first', () => {
  const many = Array.from({ length: 12 }, (_, i) => `thing ${i}`);
  assert.deepEqual(draftMissing(d({ missing: many })), { shown: many.slice(0, 5), more: 7 });
  assert.deepEqual(draftMissing(d({ missing: ['email'] })), { shown: ['email'], more: 0 });
  assert.deepEqual(split([1, 2, 3, 4, 5]), { first: [1, 2, 3, 4, 5], rest: [] });
  assert.deepEqual(split([1, 2, 3, 4, 5, 6, 7]), { first: [1, 2, 3, 4], rest: [5, 6, 7] });
});
