import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ADMIN_HUBS, STAFF_HUBS, hubLink, hubOf, movedTo, tabOf } from './hubs.ts';

const at = (path: string, q = '') => { const x = hubOf(ADMIN_HUBS, path, q); return x ? `${x.hub.key}:${x.tab.label}` : null; };

test('a merged page shows its tab from ?tab=, and its first tab without one (or with a tab it does not have)', () => {
  assert.equal(at('/admin/owner-money', 'tab=debits'), 'owner-money:Debits');
  assert.equal(at('/admin/owner-money', ''), 'owner-money:Invoices');
  assert.equal(at('/admin/owner-money', 'tab=nope&status=paid'), 'owner-money:Invoices');
  assert.equal(at('/admin/money', 'tab=reconciliation&month=2026-10-01'), 'payments:Reconciliation');
  assert.equal(at('/admin/money'), 'payments:By day');
  assert.equal(at('/admin/logs', 'tab=access&q=x'), 'logs:Data access');
});

test('a grouped page is its own tab; a tab with a query wins when the page has it', () => {
  assert.equal(at('/admin/expenses'), 'company:Expenses');
  assert.equal(at('/admin/owners', 'view=checklist'), 'owners:Paid and signed');
  assert.equal(at('/admin/owners'), 'owners:Owners');
  assert.equal(at('/admin/money/field-pay', 'tab=hours'), 'staff-pay:Field pay');
});

test('detail pages and pages outside a group show no tab row', () => {
  for (const p of ['/admin/invoices/INV-1', '/admin/statements/abc', '/admin/bookings', '/admin', '/admin/settings/site', '/admin/insurers/x']) assert.equal(at(p), null, p);
});

test('every tab is in one group only, and every group has at least two tabs', () => {
  for (const hubs of [ADMIN_HUBS, STAFF_HUBS]) {
    const all = hubs.flatMap((h) => h.tabs.map((t) => t.href));
    assert.equal(all.length, new Set(all).size);
    for (const h of hubs) assert.ok(h.tabs.length >= 2, h.key);
  }
  assert.equal(hubOf(STAFF_HUBS, '/staff/payments', 'from=2026-10-01')?.tab.label, 'By day');
});

test('a group\'s menu link goes to its first tab and is current on each of its addresses', () => {
  assert.deepEqual(hubLink(ADMIN_HUBS, 'owner-money'), { href: '/admin/owner-money?tab=invoices', label: 'Owner money', also: ['/admin/owner-money'] });
  assert.deepEqual(hubLink(ADMIN_HUBS, 'team').also, ['/admin/settings/staff', '/admin/academy', '/admin/hiring', '/admin/portals']);
  assert.throws(() => hubLink(ADMIN_HUBS, 'nope'));
});

test('an old address goes to its tab with its query kept, an old tab value mapped', () => {
  assert.equal(movedTo('/admin/owner-money', 'invoices', { status: 'paid', q: 'Smith' }), '/admin/owner-money?tab=invoices&status=paid&q=Smith');
  assert.equal(movedTo('/admin/damages', 'incidents', { tab: 'claims' }, { claims: 'claims' }), '/admin/damages?tab=claims');
  assert.equal(movedTo('/admin/damages', 'incidents', { tab: 'incidents' }, { claims: 'claims' }), '/admin/damages?tab=incidents');
  assert.equal(movedTo('/admin/logs', 'emails', { tab: 'suppressions' }, { suppressions: 'blocked' }), '/admin/logs?tab=blocked');
  assert.equal(movedTo('/admin/money', 'day', { method: ['card', 'cash'], from: '2026-10-01' }), '/admin/money?tab=day&method=card&method=cash&from=2026-10-01');
});

test('tabOf: a known tab, else the first', () => {
  const k = ['a', 'b'] as const;
  assert.equal(tabOf(k, 'b'), 'b');
  assert.equal(tabOf(k, 'z'), 'a');
  assert.equal(tabOf(k, undefined), 'a');
  assert.equal(tabOf(k, ['b', 'a']), 'b');
});
