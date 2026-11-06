// API access (release 28, B3): the tool list, the scopes and the secrets.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SCOPES, TOOLS, WRITABLE, bearer, newSecret, parseScopes, pkceChallenge, secretPrefix, sha256Hex, toolsFor } from './tools.ts';

test('every tool names a known scope, and only the update tools write', () => {
  for (const t of TOOLS) assert.ok(t.scope === 'any' || (SCOPES as readonly string[]).includes(t.scope), t.name);
  assert.deepEqual(TOOLS.filter((t) => !t.readOnly).map((t) => t.name).sort(), ['update_booking', 'update_owner', 'update_request']);
  for (const t of TOOLS.filter((x) => !x.readOnly)) assert.ok(t.scope.endsWith(':write'), t.name);
});

test('the writable fields never include money, status or identity numbers', () => {
  const all = Object.values(WRITABLE).flat() as string[];
  for (const bad of ['status', 'total_due_at_booking_cents', 'deposit_cents', 'balance_carried_forward_cents', 'payout_method', 'corporation_number', 'registrant_identification_number', 'vehicle_id', 'renter_id'])
    assert.ok(!all.includes(bad), bad);
});

test('a key with read scopes sees only the read tools', () => {
  assert.deepEqual(toolsFor(['bookings:read']).map((t) => t.name), ['whoami', 'list_bookings', 'get_booking']);
});

test('scopes asked by Claude: the known ones; none asked: all', () => {
  assert.deepEqual(parseScopes('bookings:read owners:write payments:write'), ['bookings:read', 'owners:write']);
  assert.deepEqual(parseScopes(''), [...SCOPES]);
});

test('secrets: random, prefixed, hashed; PKCE S256 as RFC 7636 computes it', async () => {
  const a = newSecret('cc_live_'), b = newSecret('cc_live_');
  assert.notEqual(a, b);
  assert.match(a, /^cc_live_[A-Za-z0-9_-]{43}$/);
  assert.equal(secretPrefix(a), a.slice(0, 12));
  assert.match(await sha256Hex(a), /^[0-9a-f]{64}$/);
  // the example of RFC 7636, appendix B
  assert.equal(await pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
});

test('the bearer of an Authorization header', () => {
  assert.equal(bearer('Bearer cc_live_abcdefghijklmnopqrstuvwxyz'), 'cc_live_abcdefghijklmnopqrstuvwxyz');
  assert.equal(bearer('Basic abc'), null);
  assert.equal(bearer(null), null);
  assert.equal(bearer('Bearer short'), null);
});
