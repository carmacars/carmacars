// API access (release 28, B3): the tool list, the scopes and the secrets.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ADMIN_TOOLS, CLAIM_TOOLS, CONNECTOR_URL, OPS_TOOLS, PHOTO_TOOLS, SCOPES, STRIPE_TOOLS, TOOLS, WRITABLE, bearer, newSecret, parseScopes, pkceChallenge, secretPrefix, sha256Hex, toolsFor, claimFileKind } from './tools.ts';

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

// release 35 (1156): the Admin's daily operations
const SQL1156 = readFileSync(new URL('../../../../supabase/migrations/1156_r35g_connector_admin_ops.sql', import.meta.url), 'utf8');
test('1156: the operations tools are the database\'s: lists page and hide test records, writes are two-step, money out is prepared only', () => {
  const arr = (fn: string) => /select array\[([^\]]+)\]/.exec(SQL1156.slice(SQL1156.indexOf(`function app.${fn}()`)))![1]!.split(',').map((x) => x.trim().replace(/'/g, ''));
  const lists = arr('api_list_tools');
  const reads = [...lists.filter((n) => !['list_bookings', 'list_requests', 'list_owners', 'list_cars', 'list_applicants', 'list_staff'].includes(n)), ...arr('api_one_reads')].sort();
  assert.deepEqual(OPS_TOOLS.filter((t) => t.readOnly).map((t) => t.name).sort(), reads);
  const writes = [...[...SQL1156.matchAll(/when '([a-z_]+)'\s+then '\{"call"/g)].map((m) => m[1]!), 'prepare_money_action', 'upload_booking_photo'].sort();
  assert.deepEqual(OPS_TOOLS.filter((t) => !t.readOnly).map((t) => t.name).sort(), writes);
  for (const n of lists) {
    const t = TOOLS.find((x) => x.name === n)!;
    const props = (t.inputSchema as { properties: Record<string, { maximum?: number }> }).properties;
    assert.ok(props.cursor && props.include_test && props.limit?.maximum === 200, n);
  }
  for (const t of OPS_TOOLS.filter((x) => !x.readOnly)) {
    const props = (t.inputSchema as { properties: Record<string, unknown> }).properties;
    assert.ok(props.confirm && props.preview_id && t.scope === 'admin:write', t.name);
  }
  assert.match(OPS_TOOLS.find((t) => t.name === 'prepare_money_action')!.description, /no money moves/);
  assert.ok(!OPS_TOOLS.some((t) => /^(refund|release|payout|charge)/.test(t.name)), 'no tool moves money');
});

// the gaps (1873): files on a claim
const SQL1873 = readFileSync(new URL('../../../../supabase/migrations/1873_r35gaps4_connector_claim_files.sql', import.meta.url), 'utf8');
test('1873: the claim file tools are the database\'s, admin:write, two-step, and need the claim', () => {
  assert.deepEqual(CLAIM_TOOLS.map((t) => t.name).sort(), ['attach_claim_estimate', 'attach_claim_photo']);
  for (const t of CLAIM_TOOLS) {
    assert.ok(SQL1873.includes(`'${t.name}'`), t.name);
    assert.equal(t.scope, 'admin:write');
    assert.equal(t.readOnly, false);
    const schema = t.inputSchema as { properties: Record<string, unknown>; required: string[] };
    assert.ok(schema.properties.confirm && schema.properties.preview_id, t.name);
    assert.ok(schema.required.includes('claim'), t.name);
    assert.match(t.description, /Two steps/);
    assert.ok(TOOLS.includes(t));
  }
  assert.deepEqual((CLAIM_TOOLS[0]!.inputSchema as { required: string[] }).required, ['claim', 'file_base64']);
  assert.deepEqual((CLAIM_TOOLS[1]!.inputSchema as { required: string[] }).required, ['claim', 'amount_cents', 'shop_name', 'approved_shop']);
  assert.ok(!toolsFor(['admin:read']).some((t) => t.name.startsWith('attach_claim')), 'a read-only key does not see them');
  assert.ok(toolsFor(['admin:write']).some((t) => t.name === 'attach_claim_photo'));
});

test('1873: the database checks the role, the claim state and the preview before any file is stored', () => {
  assert.match(SQL1873, /app\.is_admin\(\) or app\.va_has\('finance', 'fleet'\)/);
  assert.match(SQL1873, /c\.status in \('closed', 'withdrawn'\)|c\.status in \('closed', 'withdrawn'\) then raise/);
  assert.match(SQL1873, /Preview first: call without confirm/);
  assert.match(SQL1873, /The arguments differ from the preview/);
  assert.match(SQL1873, /Already stored/);
});

test('1873: a claim file is a JPEG, a PNG or a PDF by its bytes, not by its name', () => {
  assert.deepEqual(claimFileKind(new Uint8Array([0xff, 0xd8, 0xff, 0xe0])), { ext: 'jpg', mime: 'image/jpeg' });
  assert.deepEqual(claimFileKind(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d])), { ext: 'png', mime: 'image/png' });
  assert.deepEqual(claimFileKind(new Uint8Array([0x25, 0x50, 0x44, 0x46, 0x2d])), { ext: 'pdf', mime: 'application/pdf' });
  assert.equal(claimFileKind(new Uint8Array([0x4d, 0x5a, 0x90, 0x00])), null);
});

// release 47 (2896): the photo standard, read only
const SQL2896 = readFileSync(new URL('../../../../supabase/migrations/2896_r47b_connector_photo_standard.sql', import.meta.url), 'utf8');
test('2896: photo_standard is a read-only admin:read tool the database answers, logged, never a write', () => {
  const t = PHOTO_TOOLS.find((x) => x.name === 'photo_standard')!;
  assert.ok(t && t.readOnly && t.scope === 'admin:read');
  assert.deepEqual(Object.keys((t.inputSchema as { properties: Record<string, unknown> }).properties).sort(), ['limit', 'vehicle']);
  assert.ok(TOOLS.includes(t));
  assert.ok(toolsFor(['admin:read']).some((x) => x.name === 'photo_standard'));
  assert.ok(!toolsFor(['bookings:read']).some((x) => x.name === 'photo_standard'));
  assert.match(SQL2896, /if p_tool not in \('photo_standard', 'stripe_booking', 'stripe_account', 'stripe_record_paid'\) then return app\.api_call_pre2896/);
  assert.match(SQL2896, /api_key_check\(p_hash, case when v_write then 'admin:write' else 'admin:read' end, p_tool/);
  assert.match(SQL2896, /insert into api_calls/);
});
test('2896: the Stripe tools: two reads, and stripe_record_paid two-step on admin:write', () => {
  const by = (n: string) => STRIPE_TOOLS.find((x) => x.name === n)!;
  assert.ok(by('stripe_booking').readOnly && by('stripe_booking').scope === 'admin:read');
  assert.ok(by('stripe_account').readOnly && by('stripe_account').scope === 'admin:read');
  const w = by('stripe_record_paid');
  assert.ok(!w.readOnly && w.scope === 'admin:write');
  const props = (w.inputSchema as { properties: Record<string, unknown> }).properties;
  assert.ok(props.confirm && props.preview_id && props.payment_intent);
  assert.match(SQL2896, /'run', 'stripe_record_paid'/);
  assert.match(SQL2896, /pv\.args is distinct from v_args/);
});
