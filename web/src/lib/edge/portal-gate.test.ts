import { test } from 'node:test';
import assert from 'node:assert/strict';
import { portalSignIn } from './portal-gate.ts';

const h = (o: Record<string, string> = {}) => ({ get: (n: string) => o[n.toLowerCase()] ?? null });

test('a staff portal page with no session is sent to sign in at the edge (a real 307, not a streamed redirect)', () => {
  assert.equal(portalSignIn('GET', 'https://carmacars.ca/admin/bookings?tab=all', h()), '/sign-in?next=%2Fadmin%2Fbookings%3Ftab%3Dall');
  assert.equal(portalSignIn('HEAD', 'https://carmacars.ca/staff', h()), '/sign-in?next=%2Fstaff');
});

test('a session, a client navigation, a write or another path keeps the app', () => {
  assert.equal(portalSignIn('GET', 'https://carmacars.ca/admin', h({ cookie: 'sb-abc123-auth-token=x' })), null);
  assert.equal(portalSignIn('GET', 'https://carmacars.ca/admin', h({ rsc: '1' })), null);
  assert.equal(portalSignIn('POST', 'https://carmacars.ca/admin', h()), null);
  assert.equal(portalSignIn('GET', 'https://carmacars.ca/staff-restore', h()), null);
  assert.equal(portalSignIn('GET', 'https://carmacars.ca/owner/sign?key=1', h()), null);
  assert.equal(portalSignIn('GET', 'https://carmacars.ca/cars/x', h()), null);
});
