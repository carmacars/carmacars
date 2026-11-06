import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heldFunctions, staffHome, staffHubs, staffNav, staffSections } from './nav.ts';
import { STAFF_ACTIONS, placeOf, sectionItems } from '../admin/hubs.ts';

// the menu's own links (one tap), and every page one tap from a link (a section's or a group's other pages, r27)
const hrefs = (fns: string[]) => staffNav(fns).flatMap((g) => g.links.map((l) => l.href));
const reach = (fns: string[]) => staffNav(fns).flatMap((g) => g.links.flatMap((l) => [l.href, ...(l.also ?? [])]));
const groups = (fns: string[]) => staffNav(fns).map((g) => g.label);
const count = (fns: string[]) => staffNav(fns).reduce((a, g) => a + g.links.length, 0);
const actions = (fns: string[]) => STAFF_ACTIONS.filter((a) => !a.fns || a.fns.split(' ').some((f) => fns.includes(f)));

test('Sales in person with field work: the Sales jobs and the field jobs in one menu', () => {
  const h = hrefs(['sales', 'field']);
  for (const p of ['/staff/requests', '/staff/visitors', '/staff/marketing', '/staff/my-sales', '/staff/field', '/staff/field/map', '/staff/field/hours']) assert.ok(h.includes(p), p);
  assert.deepEqual(groups(['sales', 'field']), ['To do', 'Sales', 'Field work', 'Bookings', 'Me']);
  // the office pages cover adding a rental, the sales and the profile
  for (const p of ['/staff/field/rentals/new', '/staff/field/sales', '/staff/field/profile']) assert.ok(!reach(['sales', 'field']).includes(p), p);
  // no finance, fleet or customer service pages
  for (const p of ['/staff/money', '/staff/fleet', '/staff/messages', '/staff/owner-forms']) assert.ok(!reach(['sales', 'field']).includes(p), p);
});

test('field work only: their four jobs and Me (my sales, referrals, profile, academy); adding a rental and reporting are buttons', () => {
  assert.deepEqual(groups(['field']), ['Field work', 'Me']);
  assert.equal(count(['field']), 5);
  for (const p of ['/staff/field', '/staff/field/now', '/staff/field/map', '/staff/field/hours']) assert.ok(hrefs(['field']).includes(p), p);
  for (const p of ['/staff/field/sales', '/staff/field/referrals', '/staff/field/profile', '/staff/academy']) assert.ok(reach(['field']).includes(p), p);
  assert.deepEqual(actions(['field']).map((a) => `${a.on} ${a.href}`), ['/staff/field /staff/field/rentals/new', '/staff/field /staff/field/report']);
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
  assert.ok(!staffNav(['cs', 'sales']).find((g) => g.key === 'sales')!.links.some((l) => l.href === '/staff/requests' || l.href === '/staff/visitors'));
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

// r27 consolidation (the owner on November 2, 2026): at most five links a role, Admin's upgrades in each role's menu
// (Visitors for customer service and Sales, the Marketplace for Sales, the fleet map for Fleet and Field, Owner money for
// Finance), actions as buttons on their page.
const TOP: Record<string, string[]> = {
  cs: ['/staff/requests', '/staff/visitors', '/staff/messages'],
  fleet: ['/staff/fleet', '/staff/fleet/map', '/staff/checks', '/staff/maintenance'],
  finance: ['/staff/money', '/staff/owner-money?tab=invoices', '/staff/tolls', '/staff/turo'],
  sales: ['/staff/requests', '/staff/visitors', '/staff/marketing', '/staff/my-sales'],
  field: ['/staff/field', '/staff/field/now', '/staff/field/map', '/staff/field/hours']
};

test('each role: at most five links in its group, its main jobs one tap away, the rest one tap from "More", Bookings or Me', () => {
  for (const [fn, jobs] of Object.entries(TOP)) {
    const g = staffNav([fn]).find((x) => x.key === fn)!;
    assert.ok(g.links.length <= 5, `${fn}: ${g.links.length}`);
    for (const j of jobs) assert.ok(hrefs([fn]).includes(j), `${fn}: ${j}`);
  }
  // pages that left the menu are still one tap from a link
  for (const p of ['/staff/renters', '/staff/review-requests', '/staff/owner-forms', '/staff/listings', '/staff/chauffeur']) assert.ok(reach(['cs']).includes(p), `cs ${p}`);
  for (const p of ['/staff/field-hours', '/staff/calendar-sync', '/staff/addons', '/staff/owners/add-car', '/staff/renters', '/staff/reviews']) assert.ok(reach(['fleet']).includes(p), `fleet ${p}`);
  for (const p of ['/staff/maintenance', '/staff/renters', '/staff/owner-money']) assert.ok(reach(['finance']).includes(p), `finance ${p}`);
  for (const p of ['/staff/calendar', '/staff/cars', '/staff/card-coverage', '/staff/scorecard', '/staff/today']) assert.ok(reach(['sales']).includes(p), `sales ${p}`);
  // the actions that left the menu: buttons on their page
  for (const a of ['/staff/offers/new', '/staff/quotes/new', '/staff/bookings/new']) {
    assert.ok(!hrefs(['cs', 'sales']).includes(a), a);
    assert.ok(actions(['sales']).some((x) => x.href === a), a);
  }
  // Live visitors and Live chat are one Visitors page
  for (const p of ['/staff/live', '/staff/chat']) assert.ok(!hrefs(['cs', 'sales']).includes(p), p);
});

test('every section a role sees has at most five items', () => {
  for (const fn of ['cs', 'sales', 'fleet', 'finance', 'field']) {
    for (const s of staffSections([fn])) assert.ok(sectionItems(s, staffHubs([fn])).length <= 5, `${fn} ${s.key}`);
  }
});

test('a person sees only the pages of their functions in a section or a group', () => {
  assert.ok(!reach(['fleet']).includes('/staff/owner-forms'));
  assert.ok(!reach(['sales']).includes('/staff/messages'));
  assert.ok(!reach(['cs']).includes('/staff/calendar-sync'));
  assert.ok(reach(['cs', 'fleet']).includes('/staff/calendar-sync'));
  assert.ok(!reach(['finance']).includes('/staff/listings'));
  assert.ok(!reach(['cs']).includes('/staff/marketing'));
  assert.ok(!reach(['cs', 'sales']).includes('/staff/fleet/map'));
});

test('the rows on a page: the section, then the group\'s tabs; Finance\'s money is one page with Admin\'s tabs', () => {
  const at = (fns: string[], path: string, q = '') => placeOf(staffSections(fns), staffHubs(fns), path, q);
  const fin = at(['finance'], '/staff/money', 'tab=day');
  assert.equal(fin.section?.label, 'Finance');
  assert.deepEqual(fin.hub?.hub.tabs.map((t) => t.label), ['To handle', 'By day', 'All payments', 'Refunds', 'Deposits', 'Reconciliation', 'Partner invoices']);
  assert.equal(fin.hub?.tab.label, 'By day');
  assert.deepEqual(at(['finance'], '/staff/owner-money', 'tab=statements').hub?.tab.label, 'Statements');
  const cs = at(['cs'], '/staff/messages');
  assert.equal(cs.section?.label, 'Customer service');
  assert.equal(cs.hub?.tab.label, 'Messages');
  // a fleet person on Find a renter: the Bookings section
  const fl = at(['fleet'], '/staff/renters');
  assert.equal(fl.section?.label, 'Bookings');
  assert.equal(fl.section?.current.label, 'Find a renter');
  assert.equal(at(['cs'], '/staff/requests').section, null);
  assert.equal(at(['fleet'], '/staff/fleet/map').section?.current.label, 'Fleet map');
});
