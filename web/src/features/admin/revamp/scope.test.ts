import { test } from 'node:test';
import assert from 'node:assert/strict';
import { REVAMP_ADMIN, REVAMP_STAFF, revamped } from './scope.ts';

test('the revamped pages and the pages under them; never the pages other branches own', () => {
  for (const p of ['/admin/owner-money', '/admin/invoices/INV-1', '/admin/settings/site', '/admin/money/field-pay', '/admin/reviews']) assert.ok(revamped(REVAMP_ADMIN, p), p);
  for (const p of ['/admin', '/admin/bookings', '/admin/requests', '/admin/calendar', '/admin/live', '/admin/live-map', '/admin/chat', '/admin/overview', '/admin/tasks', '/admin/moneyx']) assert.ok(!revamped(REVAMP_ADMIN, p), p);
  for (const p of ['/staff/money', '/staff/field/hours', '/staff/tolls/x']) assert.ok(revamped(REVAMP_STAFF, p), p);
  for (const p of ['/staff', '/staff/requests', '/staff/bookings/CC-1', '/staff/calendar', '/staff/chat', '/staff/live', '/staff/my-sales', '/staff/today']) assert.ok(!revamped(REVAMP_STAFF, p), p);
});

test('every revamped staff page has an admin counterpart area in the list or is staff-only work', () => {
  assert.equal(new Set(REVAMP_ADMIN).size, REVAMP_ADMIN.length);
  assert.equal(new Set(REVAMP_STAFF).size, REVAMP_STAFF.length);
});
