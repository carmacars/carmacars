import { test } from 'node:test';
import assert from 'node:assert/strict';
import { activeCount, hrefWith, mapLegacy, withinRule } from './model.ts';

test('r32: the rule: at most 5 chips, one date range, a sort of at most 3', () => {
  assert.equal(withinRule(5, 1, 3), true);
  assert.equal(withinRule(6, 0, 0), false);
  assert.equal(withinRule(4, 2, 0), false);
  assert.equal(withinRule(4, 0, 4), false);
});

test('r32: old query parameters map to the new ones', () => {
  const r = mapLegacy({ status: 'on_rent', supplier: 'company', q: 'kia', empty: '' }, { status: { on_rent: ['status', 'out'] }, supplier: 'supply' });
  assert.deepEqual(r.sp, { status: 'out', supply: 'company', q: 'kia' });
  assert.equal(r.changed, true);
  assert.equal(mapLegacy({ q: 'x' }, { supplier: 'supply' }).changed, false);
});

test('r32: links keep the other filters; empty removes one; the count leaves the search out', () => {
  assert.equal(hrefWith('/admin/bookings?view=all', { q: 'kia', status: 'out' }, 'status', 'closed'), '/admin/bookings?q=kia&view=all&status=closed');
  assert.equal(hrefWith('/admin/vehicles', { status: 'available' }, 'status', ''), '/admin/vehicles');
  assert.equal(activeCount({ q: 'x', status: 'out', bill: '' }, ['status', 'bill']), 1);
});
