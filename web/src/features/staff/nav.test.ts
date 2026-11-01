import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heldFunctions, staffHome, staffNav } from './nav.ts';

const hrefs = (fns: string[]) => staffNav(fns).flatMap((g) => g.links.map((l) => l.href));
// every page one tap from the menu: the links and the other pages of their groups (r27)
const reach = (fns: string[]) => staffNav(fns).flatMap((g) => g.links.flatMap((l) => [l.href, ...(l.also ?? [])]));
const groups = (fns: string[]) => staffNav(fns).map((g) => g.label);

test('Sales in person with field work: the Sales pages and the field jobs in one menu', () => {
  const h = reach(['sales', 'field']);
  for (const p of ['/staff/requests', '/staff/offers/new', '/staff/quotes/new', '/staff/my-sales', '/staff/field', '/staff/field/report', '/staff/field/hours'])
    assert.ok(h.includes(p), p);
  assert.deepEqual(groups(['sales', 'field']), ['Today', 'Sales', 'Rentals', 'Me', 'Field work']);
  // the office pages cover adding a rental, the sales and the profile
  for (const p of ['/staff/field/rentals/new', '/staff/field/sales', '/staff/field/profile']) assert.ok(!h.includes(p), p);
  // no finance or fleet pages
  for (const p of ['/staff/money', '/staff/fleet', '/staff/messages', '/staff/owner-forms']) assert.ok(!h.includes(p), p);
});

test('field work only: the field pages, with their own Add a rental, My sales and Profile', () => {
  assert.deepEqual(groups(['field']), ['Field work']);
  assert.ok(hrefs(['field']).includes('/staff/field/rentals/new'));
  assert.ok(!hrefs(['field']).includes('/staff'));
});

test('customer service only', () => {
  assert.deepEqual(groups(['cs']), ['Today', 'Customer service', 'Rentals', 'Me']);
  assert.ok(!hrefs(['cs']).some((p) => p.startsWith('/staff/field')));
});

test('a page two functions share is listed once', () => {
  const h = hrefs(['cs', 'sales', 'fleet', 'finance', 'field']);
  assert.equal(h.length, new Set(h).size);
  // the first group keeps it: Requests under customer service
  const cs = staffNav(['cs', 'sales']).find((g) => g.key === 'cs')!;
  assert.ok(cs.links.some((l) => l.href === '/staff/requests' && l.label === 'Requests'));
  assert.ok(!staffNav(['cs', 'sales']).find((g) => g.key === 'sales')!.links.some((l) => l.href === '/staff/requests'));
});

test('every link is under /staff', () => {
  for (const p of hrefs(['cs', 'sales', 'fleet', 'finance', 'field'])) assert.match(p, /^\/staff(\/|$)/);
});

test('held functions and the home page', () => {
  assert.deepEqual(heldFunctions(['field', 'sales', 'va', 'sales']), ['sales', 'field']);
  assert.deepEqual(heldFunctions(null), []);
  assert.equal(staffHome(['field']), '/staff/field');
  assert.equal(staffHome(['field', 'fleet']), '/staff');
  assert.deepEqual(staffNav([]), []);
});

test('the academy is in the menu of every staff member, once (Release 21b)', () => {
  for (const fns of [['cs'], ['field'], ['sales', 'field'], ['cs', 'sales', 'fleet', 'finance', 'field']]) assert.equal(hrefs(fns).filter((p) => p === '/staff/academy').length, 1, fns.join());
});

test('Finance: the three money pages are one Money link, current on each of them (r27)', () => {
  const fin = staffNav(['finance']).find((g) => g.key === 'finance')!;
  const money = fin.links.find((l) => l.label === 'Money')!;
  assert.equal(money.href, '/staff/money');
  assert.deepEqual(money.also, ['/staff/money', '/staff/payments', '/staff/reconciliation']);
  for (const p of ['/staff/payments', '/staff/reconciliation']) assert.ok(!fin.links.some((l) => l.href === p), p);
});

// The r27 audit: each role's menu is short, its own group first, and its five most frequent jobs are one tap from the
// menu (a link, or a tab of a link's page group).
const TOP5: Record<string, string[]> = {
  cs: ['/staff/requests', '/staff/chat', '/staff/offers/new', '/staff/renters', '/staff/messages'],
  fleet: ['/staff/fleet', '/staff/checks', '/staff/reviews', '/staff/maintenance', '/staff/listings'],
  finance: ['/staff/money', '/staff/payments', '/staff/tolls', '/staff/reconciliation', '/staff/turo'],
  sales: ['/staff/requests', '/staff/offers/new', '/staff/quotes/new', '/staff/chat', '/staff/my-sales'],
  field: ['/staff/field', '/staff/field/hours', '/staff/field/report', '/staff/field/rentals/new', '/staff/field/sales']
};
const SIZE: Record<string, number> = { cs: 18, fleet: 17, finance: 15, sales: 17, field: 6 };

test('each role: a short menu, its own group first after Today, its top five jobs one tap away (r27 audit)', () => {
  for (const [fn, jobs] of Object.entries(TOP5)) {
    const n = staffNav([fn]);
    assert.equal(n.reduce((a, g) => a + g.links.length, 0), SIZE[fn], fn);
    assert.equal(n[fn === 'field' ? 0 : 1]!.key, fn, fn);
    for (const j of jobs) assert.ok(reach([fn]).includes(j), `${fn}: ${j}`);
  }
});

test('a page group shows a person only the pages of their functions', () => {
  const fleet = staffNav(['fleet']).flatMap((g) => g.links);
  assert.ok(fleet.some((l) => l.href === '/staff/owners/add-car' && l.label === 'Add a car for an owner' && !l.also));
  assert.ok(!reach(['fleet']).includes('/staff/owner-forms'));
  assert.ok(!reach(['sales']).includes('/staff/messages'));
  assert.ok(!reach(['cs']).includes('/staff/calendar-sync'));
  assert.ok(reach(['cs', 'fleet']).includes('/staff/calendar-sync'));
});
