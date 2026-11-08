// API access (release 28, B3): the tool list, the scopes and the secrets.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ADMIN_TOOLS, CONNECTOR_URL, SCOPES, TOOLS, WRITABLE, bearer, newSecret, parseScopes, pkceChallenge, secretPrefix, sha256Hex, toolsFor } from './tools.ts';

test('every tool names a known scope, and only the update tools write', () => {
  for (const t of TOOLS) assert.ok(t.scope === 'any' || (SCOPES as readonly string[]).includes(t.scope), t.name);
  assert.deepEqual(TOOLS.filter((t) => !t.readOnly && t.scope !== 'admin:write').map((t) => t.name).sort(), ['update_booking', 'update_owner', 'update_request']);
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

// release 33 (0732): the Admin's actions
const SQL = readFileSync(new URL('../../../../supabase/migrations/0732_connector_admin_actions.sql', import.meta.url), 'utf8')
  + readFileSync(new URL('../../../../supabase/migrations/0810_r34o_book_now_connector.sql', import.meta.url), 'utf8');

test('every Admin write is two-step: confirm and preview_id in its input, and the database knows it', () => {
  const inDb = [...SQL.matchAll(/when '([a-z_]+)'\s+then '\{"call"/g)].map((m) => m[1]).sort();
  const writes = ADMIN_TOOLS.filter((t) => !t.readOnly);
  assert.deepEqual(writes.map((t) => t.name).sort(), inDb);
  for (const t of writes) {
    const props = (t.inputSchema as { properties: Record<string, unknown> }).properties;
    assert.ok(props.confirm && props.preview_id, t.name);
    assert.equal(t.scope, 'admin:write', t.name);
    assert.match(t.description, /preview/, t.name);
  }
});

test('the Admin reads are the database\'s, read only, admin:read', () => {
  const m = /api_admin_reads\(\) returns text\[\]\s+language sql immutable as \$\$ select array\[([^\]]+)\]/.exec(SQL);
  assert.ok(m);
  const inDb = m![1]!.split(',').map((x) => x.trim().replace(/'/g, '')).sort();
  assert.deepEqual(ADMIN_TOOLS.filter((t) => t.readOnly).map((t) => t.name).sort(), inDb);
  for (const t of ADMIN_TOOLS.filter((x) => x.readOnly)) assert.equal(t.scope, 'admin:read');
});

test('a key with the Admin scopes sees the Admin tools; names are unique', () => {
  const names = TOOLS.map((t) => t.name);
  assert.equal(new Set(names).size, names.length);
  assert.ok(toolsFor(['admin:write']).some((t) => t.name === 'hire_applicant'));
  assert.ok(!toolsFor(['admin:read']).some((t) => t.name === 'cancel_booking'));
  assert.equal(CONNECTOR_URL, 'https://carmacars.ca/api/mcp');
});

// release 34 (0810): Book it now from the connector
test('Book it now: send_offer and create_offer take book_now, book_offer_now books an offer that is out, each two-step', () => {
  for (const n of ['send_offer', 'create_offer']) {
    const t = ADMIN_TOOLS.find((x) => x.name === n)!;
    const props = (t.inputSchema as { properties: Record<string, { type?: string }> }).properties;
    assert.equal(props.book_now?.type, 'boolean', n);
    assert.ok(props.book_now_reason, n);
  }
  const t = ADMIN_TOOLS.find((x) => x.name === 'book_offer_now')!;
  assert.equal(t.scope, 'admin:write');
  assert.deepEqual((t.inputSchema as { required: string[] }).required, ['booking']);
  assert.match(t.description, /Two steps/);
  assert.match(t.description, /without the renter's approval/);
});
