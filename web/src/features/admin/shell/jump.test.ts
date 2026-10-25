import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rank, type Item } from './jump.ts';

const items: Item[] = [
  { href: '/admin', label: 'To do', where: 'Today' },
  { href: '/admin/payouts', label: 'Payouts', where: 'Money, Owners' },
  { href: '/admin/payments', label: 'Payments by day', where: 'Money, Renters' },
  { href: '/admin/money', label: 'Payments and refunds', where: 'Money, Renters' },
  { href: '/admin/settings/program', label: 'Program settings', where: 'Settings' },
  { href: '/admin/money/commissions', label: 'Staff commissions', where: 'Money, Company' }
];

test('nothing typed: every page, in the menu order', () => {
  assert.deepEqual(rank(items, '  ').map((i) => i.href), items.map((i) => i.href));
});

test('a name that starts with what was typed comes first', () => {
  assert.deepEqual(rank(items, 'pay').map((i) => i.label), ['Payouts', 'Payments by day', 'Payments and refunds']);
});

test('every word must match, in the name or its place in the menu', () => {
  assert.deepEqual(rank(items, 'program set').map((i) => i.href), ['/admin/settings/program']);
  assert.deepEqual(rank(items, 'money company').map((i) => i.label), ['Staff commissions']);
  assert.deepEqual(rank(items, 'refunds day'), []);
});

test('case and accents do not matter', () => {
  assert.equal(rank(items, 'PAYOÚTS')[0]?.href, '/admin/payouts');
});
