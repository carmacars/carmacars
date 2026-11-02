// Data health on Admin > To do (migration 0441): the card's order and words.
//   node --test --experimental-strip-types src/features/admin/data-health/model.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkedWords, fixedWords, splitChecks, type DataHealthCheck, staffLink } from './model.ts';

const check = (key: string, count: number): DataHealthCheck => ({ key, title: key, line: key, href: null, count, items: [] });

test('lists the checks with records in the database order, and counts the clear ones', () => {
  const { open, clear } = splitChecks([check('a', 1), check('b', 0), check('c', 4)]);
  assert.deepEqual(open.map((c) => c.key), ['a', 'c']);
  assert.deepEqual(clear.map((c) => c.key), ['b']);
});

test('says what the auto-fix did, adding up the test account kinds', () => {
  assert.equal(fixedWords({ test_tasks: 2, test_leads: 1, duplicate_tasks: 1 }), '3 test accounts taken off real work, 1 duplicate task closed');
  assert.equal(fixedWords({ resolved_tasks: 4 }), '4 finished tasks closed');
  assert.equal(fixedWords({}), '');
  assert.equal(fixedWords(null), '');
});

test('says when it last checked, in Toronto time', () => {
  const now = new Date('2026-11-07T15:00:00Z');
  assert.match(checkedWords('2026-11-07T08:23:00Z', now), /^Checked 3:23\sa\s?m$/);
  assert.match(checkedWords('2026-11-06T08:23:00Z', now), /^Checked yesterday, 3:23\sa\s?m$/);
  assert.match(checkedWords('2026-10-31T08:23:00Z', now), /^Checked Oct 31, 4:23\sa\s?m$/);
});

// r27 consolidation: each staff role's Data health lines link to the staff pages (Admin-only pages get no link)
test('Data health links in the staff portal', () => {
  assert.equal(staffLink('/admin/bookings/CC-1042'), '/staff/bookings/CC-1042');
  assert.equal(staffLink('/admin/vehicles/abc?tab=records'), '/staff/vehicles/abc?tab=records');
  assert.equal(staffLink('/admin/payments'), '/staff/money?tab=payments');
  assert.equal(staffLink('/admin/reconciliation'), '/staff/money?tab=reconciliation');
  assert.equal(staffLink('/admin/leads?q=x'), '/staff/leads?q=x');
  assert.equal(staffLink('/admin/owners/abc'), null);
  assert.equal(staffLink('/admin/settings/usage'), null);
  assert.equal(staffLink(null), null);
});
