import { test } from 'node:test';
import assert from 'node:assert/strict';
import { heldFunctions, staffHome, staffNav } from './nav.ts';

const hrefs = (fns: string[]) => staffNav(fns).flatMap((g) => g.links.map((l) => l.href));
const groups = (fns: string[]) => staffNav(fns).map((g) => g.label);

test('Sales in person with field work: the Sales pages and the field jobs in one menu', () => {
  const h = hrefs(['sales', 'field']);
  for (const p of ['/staff/requests', '/staff/offers/new', '/staff/quotes/new', '/staff/my-sales', '/staff/field', '/staff/field/report', '/staff/field/hours'])
    assert.ok(h.includes(p), p);
  assert.deepEqual(groups(['sales', 'field']), ['My work', 'Live', 'Sales', 'Rentals', 'Field work']);
  // the office pages cover adding a rental, the sales and the profile
  for (const p of ['/staff/field/rentals/new', '/staff/field/sales', '/staff/field/profile']) assert.ok(!h.includes(p), p);
  // no finance or fleet pages
  for (const p of ['/staff/money', '/staff/fleet', '/staff/messages']) assert.ok(!h.includes(p), p);
});

test('field work only: the field pages, with their own Add a rental, My sales and Profile', () => {
  assert.deepEqual(groups(['field']), ['Field work']);
  assert.ok(hrefs(['field']).includes('/staff/field/rentals/new'));
  assert.ok(!hrefs(['field']).includes('/staff'));
});

test('customer service only', () => {
  assert.deepEqual(groups(['cs']), ['My work', 'Live', 'Customer service', 'Rentals']);
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
