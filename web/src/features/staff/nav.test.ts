import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heldFunctions, staffHome, staffHubs, staffNav, staffSections } from './nav.ts';
import { placeOf } from '../admin/hubs.ts';

// the menu's own links (one tap), and every page one tap from a link (a section's or a group's other pages, r27)
const hrefs = (fns: string[]) => staffNav(fns).flatMap((g) => g.links.map((l) => l.href));
const reach = (fns: string[]) => staffNav(fns).flatMap((g) => g.links.flatMap((l) => [l.href, ...(l.also ?? [])]));
const groups = (fns: string[]) => staffNav(fns).map((g) => g.label);
const count = (fns: string[]) => staffNav(fns).reduce((a, g) => a + g.links.length, 0);

test('Sales in person with field work: the Sales jobs and the field jobs in one menu', () => {
  const h = hrefs(['sales', 'field']);
  for (const p of ['/staff/requests', '/staff/offers/new', '/staff/quotes/new', '/staff/my-sales', '/staff/field', '/staff/field/report', '/staff/field/hours']) assert.ok(h.includes(p), p);
  assert.deepEqual(groups(['sales', 'field']), ['To do', 'Sales', 'Field work', 'Bookings', 'Me']);
  // the office pages cover adding a rental, the sales and the profile
  for (const p of ['/staff/field/rentals/new', '/staff/field/sales', '/staff/field/profile']) assert.ok(!reach(['sales', 'field']).includes(p), p);
  // no finance, fleet or customer service pages
  for (const p of ['/staff/money', '/staff/fleet', '/staff/messages', '/staff/owner-forms']) assert.ok(!reach(['sales', 'field']).includes(p), p);
});

test('field work only: their five jobs and Me (referrals, profile, academy)', () => {
  assert.deepEqual(groups(['field']), ['Field work', 'Me']);
  assert.equal(count(['field']), 6);
  for (const p of ['/staff/field/rentals/new', '/staff/field/sales', '/staff/field/hours']) assert.ok(hrefs(['field']).includes(p), p);
  for (const p of ['/staff/field/referrals', '/staff/field/profile', '/staff/academy']) assert.ok(reach(['field']).includes(p), p);
  assert.ok(!reach(['field']).includes('/staff'));
});

test('every office role: To do, its group, Bookings and Me', () => {
  assert.deepEqual(groups(['cs']), ['To do', 'Customer service', 'Bookings', 'Me']);
  assert.deepEqual(groups(['finance']), ['To do', 'Finance', 'Bookings', 'Me']);
  assert.ok(!reach(['cs']).some((p) => p.startsWith('/staff/field')));
});

test('a page two functions share is listed once', () => {
  const h = hrefs(['cs', 'sales', 'fleet', 'finance', 'field']);
  assert.equal(h.length, new Set(h).size);
  const cs = staffNav(['cs', 'sales']).find((g) => g.key === 'cs')!;
  assert.ok(cs.links.some((l) => l.href === '/staff/requests' && l.label === 'Requests'));
  assert.ok(!staffNav(['cs', 'sales']).find((g) => g.key === 'sales')!.links.some((l) => l.href === '/staff/requests'));
});

test('every link is under /staff', () => {
  for (const p of reach(['cs', 'sales', 'fleet', 'finance', 'field'])) assert.match(p, /^\/staff(\/|$)/);
});

test('held functions and the home page', () => {
  assert.deepEqual(heldFunctions(['field', 'sales', 'va', 'sales']), ['sales', 'field']);
  assert.deepEqual(heldFunctions(null), []);
  assert.equal(staffHome(['field']), '/staff/field');
  assert.equal(staffHome(['field', 'fleet']), '/staff');
  assert.deepEqual(staffNav([]), []);
});

test('the academy is one tap from the menu of every staff member (Release 21b): under Me', () => {
  for (const fns of [['cs'], ['field'], ['sales', 'field'], ['cs', 'sales', 'fleet', 'finance', 'field']]) assert.ok(reach(fns).includes('/staff/academy'), fns.join());
});

// The r27 audit, second cut: about 9 links for an office role, each role's five most frequent jobs one tap from the menu.
const TOP5: Record<string, string[]> = {
  cs: ['/staff/requests', '/staff/chat', '/staff/messages', '/staff/offers/new', '/staff/live'],
  fleet: ['/staff/fleet', '/staff/checks', '/staff/reviews', '/staff/maintenance', '/staff/listings'],
  finance: ['/staff/money', '/staff/payments', '/staff/tolls', '/staff/reconciliation', '/staff/turo'],
  sales: ['/staff/requests', '/staff/offers/new', '/staff/quotes/new', '/staff/chat', '/staff/my-sales'],
  field: ['/staff/field', '/staff/field/hours', '/staff/field/report', '/staff/field/rentals/new', '/staff/field/sales']
};
const SIZE: Record<string, number> = { cs: 9, fleet: 9, finance: 9, sales: 9, field: 6 };

test('each role: 9 links (field 6), its top five jobs one tap away, everything else one tap from "More" or Bookings or Me', () => {
  for (const [fn, jobs] of Object.entries(TOP5)) {
    assert.equal(count([fn]), SIZE[fn], fn);
    for (const j of jobs) assert.ok(hrefs([fn]).includes(j), `${fn}: ${j}`);
  }
  // pages that left the menu are still one tap from a link
  for (const p of ['/staff/renters', '/staff/review-requests', '/staff/owner-forms', '/staff/listings', '/staff/chauffeur']) assert.ok(reach(['cs']).includes(p), `cs ${p}`);
  for (const p of ['/staff/field-hours', '/staff/calendar-sync', '/staff/addons', '/staff/owners/add-car', '/staff/renters']) assert.ok(reach(['fleet']).includes(p), `fleet ${p}`);
  for (const p of ['/staff/maintenance', '/staff/renters']) assert.ok(reach(['finance']).includes(p), `finance ${p}`);
  for (const p of ['/staff/calendar', '/staff/cars', '/staff/bookings/new', '/staff/card-coverage', '/staff/scorecard', '/staff/today']) assert.ok(reach(['sales']).includes(p), `sales ${p}`);
});

test('a person sees only the pages of their functions in a section or a group', () => {
  assert.ok(!reach(['fleet']).includes('/staff/owner-forms'));
  assert.ok(!reach(['sales']).includes('/staff/messages'));
  assert.ok(!reach(['cs']).includes('/staff/calendar-sync'));
  assert.ok(reach(['cs', 'fleet']).includes('/staff/calendar-sync'));
  assert.ok(!reach(['finance']).includes('/staff/listings'));
});

test('the rows on a page: the section, then the group\'s tabs; Finance\'s money pages are one group', () => {
  const at = (fns: string[], path: string) => placeOf(staffSections(fns), staffHubs(fns), path, '');
  const fin = at(['finance'], '/staff/payments');
  assert.equal(fin.section?.label, 'Finance');
  assert.deepEqual(fin.hub?.hub.tabs.map((t) => t.label), ['To handle', 'By day', 'Reconciliation']);
  const cs = at(['cs'], '/staff/renters');
  assert.equal(cs.section?.label, 'Customer service');
  assert.equal(cs.hub?.tab.label, 'Find a renter');
  // a fleet person on Find a renter: the Fleet section, no tab row (one page of the group is theirs)
  const fl = at(['fleet'], '/staff/renters');
  assert.equal(fl.section?.label, 'Fleet');
  assert.equal(fl.section?.current.label, 'Find a renter');
  assert.equal(at(['cs'], '/staff/requests').section, null);
});
