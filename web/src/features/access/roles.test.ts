import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ROLE_NAV, currentRole, landingRole, mergedNav, rolesFor, type RoleInfo } from './roles.ts';

// r48 ops: one portal with a role switcher and merged navigation, for a person with more than one role.
const R = (o: Partial<RoleInfo> = {}): RoleInfo => ({ admin: false, va: null, field: false, owner: false, renter: false, investor: false, ...o });

test('every role once, in one order; an Admin never gets the renter role; a single role stays single', () => {
  assert.deepEqual(rolesFor(R({ va: 'sales', va_functions: ['sales'], field: true, functions: ['sales', 'field'] })).map((r) => r.key), ['sales', 'field']);
  assert.deepEqual(rolesFor(R({ va: 'finance', va_functions: ['finance', 'fleet'], owner: true, renter: true })).map((r) => r.key), ['fleet', 'finance', 'owner', 'account']);
  assert.deepEqual(rolesFor(R({ admin: true, owner: true, renter: true })).map((r) => r.key), ['admin', 'owner']);
  assert.deepEqual(rolesFor(R({ owner: true })).map((r) => r.key), ['owner']);
  assert.deepEqual(rolesFor(R()).length, 0);
  // an office function is switched to by the staff portal (its link carries the function), field work and the rest are plain links
  const s = rolesFor(R({ va: 'sales', va_functions: ['sales'], field: true }));
  assert.deepEqual(s.map((r) => [r.href, r.fn ?? null]), [['/staff/switch?fn=sales', 'sales'], ['/staff/field', null]]);
});

test('the role a page is in: by its address, inside the staff portal by the function worked in; field pages are field work', () => {
  const roles = rolesFor(R({ va: 'sales', va_functions: ['sales', 'cs'], field: true, owner: true }));
  assert.equal(currentRole('/staff', 'sales', roles), 'sales');
  assert.equal(currentRole('/staff/requests', 'cs', roles), 'cs');
  assert.equal(currentRole('/staff/field/shifts', 'sales', roles), 'field');
  assert.equal(currentRole('/owner/money', 'sales', roles), 'owner');
  assert.equal(currentRole('/staff', 'finance', roles), 'cs', 'a function not held: the first staff role');
  assert.equal(currentRole('/admin', null, roles), null, 'a role the person does not have is never marked');
  assert.equal(currentRole('/cars', null, roles), null);
});

test('merged navigation: the pages of every other role; an office function\'s pages open in that function', () => {
  const roles = rolesFor(R({ va: 'sales', va_functions: ['sales'], field: true, owner: true }));
  const nav = mergedNav(roles, 'sales');
  assert.deepEqual(nav.map((g) => g.role.key), ['field', 'owner']);
  assert.deepEqual(nav[1]!.links.map((l) => l.href), ['/owner', '/owner/vehicles', '/owner/vehicles?tab=bookings', '/owner/money']);
  const fromOwner = mergedNav(roles, 'owner');
  assert.equal(fromOwner[0]!.links[1]!.href, '/staff/switch?fn=sales&to=%2Fstaff%2Frequests');
  assert.equal(fromOwner[1]!.links[0]!.href, '/staff/field');
  // nothing a role cannot open: every link is under the role's own portal
  for (const [k, links] of Object.entries(ROLE_NAV)) for (const l of links) {
    const root = k === 'admin' ? '/admin' : k === 'field' ? '/staff/field' : k === 'owner' ? '/owner' : k === 'investor' ? '/investor' : k === 'account' ? '/account' : '/staff';
    assert.ok(l.href === root || l.href.startsWith(`${root}/`) || l.href.startsWith(`${root}?`), `${k}: ${l.href}`);
    assert.ok(links.length <= 5, `${k}: a short list`);
  }
});

test('sign-in opens the role used last, never a chooser; with none remembered the first role', () => {
  const two = rolesFor(R({ va: 'finance', va_functions: ['finance'], owner: true }));
  assert.equal(landingRole(two, null), '/staff');
  assert.equal(landingRole(two, 'owner'), '/owner');
  assert.equal(landingRole(two, 'va'), '/staff', 'the cookie of the old chooser (a portal) still works');
  assert.equal(landingRole(two, 'finance'), '/staff/switch?fn=finance');
  assert.equal(landingRole(two, 'admin'), '/staff', 'a role no longer held is ignored');
  assert.equal(landingRole(rolesFor(R({ field: true, owner: true })), null), '/staff/field');
  assert.equal(landingRole(rolesFor(R({ owner: true, renter: true })), 'account'), '/owner', 'renting counts only when there is nothing else');
  assert.equal(landingRole(rolesFor(R({ renter: true })), null), '/account');
  assert.equal(landingRole([], null), '/account');
});
