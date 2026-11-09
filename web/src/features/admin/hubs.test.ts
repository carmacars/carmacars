import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ADMIN_HUBS, ADMIN_SECTIONS, STAFF_HUBS, hubLink, hubOf, movedTo, placeOf, sectionLink, tabOf } from './hubs.ts';

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
  assert.equal(at('/admin/money/field-pay', 'tab=hours'), 'company:Field pay');
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
  assert.equal(hubOf(STAFF_HUBS, '/staff/money', 'tab=day&from=2026-10-01')?.tab.label, 'By day');
  assert.equal(hubOf(STAFF_HUBS, '/staff/money', '')?.tab.label, 'To handle');
});

test('a group\'s menu link goes to its first tab and is current on each of its addresses', () => {
  assert.deepEqual(hubLink(ADMIN_HUBS, 'owner-money'), { href: '/admin/owner-money?tab=invoices', label: 'Owner money', also: ['/admin/owner-money'] });
  assert.deepEqual(hubLink(ADMIN_HUBS, 'team').also, ['/admin/settings/staff', '/admin/academy', '/admin/hiring', '/admin/portals', '/admin/timesheet', '/admin/townhall']);
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

test('admin sections: one link each, opening on the page used most, current on every page in it', () => {
  const l = (k: string) => sectionLink(ADMIN_SECTIONS, ADMIN_HUBS, k)!;
  assert.equal(l('cars').href, '/admin/vehicles');
  assert.equal(l('people').href, '/admin/applications');
  assert.equal(l('money').href, '/admin/money?tab=day');
  assert.equal(l('settings').href, '/admin/settings');
  for (const p of ['/admin/maintenance', '/admin/similar-cars', '/admin/calendar-sync']) assert.ok(l('cars').also.includes(p), p);
  for (const p of ['/admin/applications', '/admin/referral-partners', '/admin/hiring', '/admin/investors', '/admin/settings/staff']) assert.ok(l('people').also.includes(p), p);
  for (const p of ['/admin/owner-money', '/admin/tolls', '/admin/expenses', '/admin/money/field-pay', '/admin/insurers']) assert.ok(l('money').also.includes(p), p);
  assert.ok(l('settings').also.includes('/admin/logs'));
  // every page group but Damage and claims is in a section
  const inSec = new Set(ADMIN_SECTIONS.flatMap((x) => x.items.filter((i): i is string => typeof i === 'string')));
  assert.deepEqual(ADMIN_HUBS.map((h) => h.key).filter((k) => !inSec.has(k)), ['problems']);
});

test('admin rows: the section with its current page, then the group\'s tabs', () => {
  const p = placeOf(ADMIN_SECTIONS, ADMIN_HUBS, '/admin/owner-money', 'tab=debits');
  assert.equal(p.section?.label, 'Money');
  assert.equal(p.section?.current.label, 'Owner money');
  assert.equal(p.hub?.tab.label, 'Debits');
  const m = placeOf(ADMIN_SECTIONS, ADMIN_HUBS, '/admin/maintenance', '');
  assert.equal(m.section?.current.label, 'Maintenance');
  assert.equal(m.hub, null);
  const s = placeOf(ADMIN_SECTIONS, ADMIN_HUBS, '/admin/settings/staff', '');
  assert.equal(s.section?.label, 'People');
  assert.equal(s.hub?.tab.label, 'Staff and roles');
  const d = placeOf(ADMIN_SECTIONS, ADMIN_HUBS, '/admin/damages', 'tab=claims');
  assert.equal(d.section, null);
  assert.equal(d.hub?.tab.label, 'Claims');
  assert.equal(placeOf(ADMIN_SECTIONS, ADMIN_HUBS, '/admin/bookings', '').section, null);
});

// r27 consolidation (the owner on November 2, 2026: "Target each area <= 5 sub-pages"; actions are buttons, not menu items)
test('every admin area lists at most five pages, and its actions are buttons that still belong to it', () => {
  for (const sec of ADMIN_SECTIONS) assert.ok(sec.items.length <= 5, `${sec.key}: ${sec.items.length}`);
  const people = sectionLink(ADMIN_SECTIONS, ADMIN_HUBS, 'people')!;
  for (const p of ['/admin/applications', '/admin/owners', '/admin/owner-forms', '/admin/owners/add-car', '/admin/partners', '/admin/referral-partners', '/admin/renters',
    '/admin/settings/staff', '/admin/academy', '/admin/hiring', '/admin/portals', '/admin/investors']) assert.ok(people.also.includes(p), p);
  const cars = sectionLink(ADMIN_SECTIONS, ADMIN_HUBS, 'cars')!;
  for (const p of ['/admin/vehicles/new', '/admin/vehicles/bulk-rates', '/admin/vehicles/samples', '/admin/vehicles/tracking', '/admin/vehicles/import-photos']) assert.ok(cars.also.includes(p), p);
  const mk = sectionLink(ADMIN_SECTIONS, ADMIN_HUBS, 'marketing')!;
  assert.equal(mk.href, '/admin/marketing/marketplace');
  for (const p of ['/admin/marketing/listings', '/admin/marketing/ads', '/admin/marketing/social', '/admin/marketing/channels', '/admin/marketing/report', '/admin/marketing/recruit', '/admin/marketing/owner-pipeline']) assert.ok(mk.also.includes(p), p);
  // actions are never tabs
  for (const h of [...ADMIN_HUBS, ...STAFF_HUBS]) for (const a of h.actions ?? []) assert.ok(!h.tabs.some((t) => t.href === a.href), a.href);
  assert.deepEqual(hubOf(ADMIN_HUBS, '/admin/applications', '')?.tab.label, 'Applications');
  const add = placeOf(ADMIN_SECTIONS, ADMIN_HUBS, '/admin/owners/add-car', '');
  assert.equal(add.section?.current.label, 'Owners');
});
