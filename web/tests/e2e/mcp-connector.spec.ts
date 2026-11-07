import { test, expect } from '@playwright/test';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { db } from './helpers';

// The Claude connector end to end (release 33, migration 0732): the MCP handshake against /api/mcp with a test key, as
// Claude sends it: initialize, the initialized notification, tools/list, a read, then a write previewed (nothing changes)
// and confirmed with the same arguments and the preview_id (done once, logged with before and after).
test.describe.configure({ mode: 'serial' });
const sha = (s: string) => createHash('sha256').update(s).digest('hex');

test('MCP handshake: initialize, tools/list, a read, a preview then a confirmed write', async ({ request }, info) => {
  test.skip(info.project.name !== 'desktop-1440', 'one width is enough for an API');
  const sql = db();
  const tag = `${Date.now()}${Math.floor(Math.random() * 1000)}`;
  const admin = randomUUID(); const staff = randomUUID();
  const key = `cc_live_${randomBytes(32).toString('base64url')}`;
  try {
    await sql`insert into users (id, email, full_name) values (${admin}, ${`mcp.admin.${tag}@example.test`}, 'Mona Admin')`;
    await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
    await sql`insert into users (id, email, full_name) values (${staff}, ${`mcp.staff.${tag}@example.test`}, 'Sam Staff')`;
    await sql`insert into user_roles (user_id, role) values (${staff}, 'va')`;
    await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code) values (${staff}, 'va', 'cs', '1 Test Lane, Testville', 'X9X 9X9')`;
    await sql`insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
              values (${admin}, 'key', 'e2e', ${key.slice(0, 12)}, ${sha(key)}, ${['bookings:read', 'admin:read', 'admin:write']}, ${admin})`;
    const auth = { authorization: `Bearer ${key}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' };
    let n = 0;
    const rpc = async (method: string, params: Record<string, unknown> = {}, note = false) => {
      const r = await request.post('/api/mcp', { headers: auth, data: { jsonrpc: '2.0', method, params, ...(note ? {} : { id: ++n }) } });
      return { status: r.status(), body: note ? null : await r.json() };
    };

    // no key: 401 pointing at the protected resource metadata (where Claude's sign-in starts)
    const anon = await request.post('/api/mcp', { data: { jsonrpc: '2.0', id: 0, method: 'initialize', params: {} } });
    expect(anon.status()).toBe(401);
    expect(anon.headers()['www-authenticate']).toContain('resource_metadata=');

    const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'e2e', version: '1' } });
    expect(init.status).toBe(200);
    expect(init.body.result.protocolVersion).toBe('2025-06-18');
    expect(init.body.result.serverInfo.name).toBe('carmacars');
    expect(init.body.result.instructions).toContain('confirm');
    expect((await rpc('notifications/initialized', {}, true)).status).toBe(202);

    const list = await rpc('tools/list');
    const names = (list.body.result.tools as Array<{ name: string }>).map((t) => t.name);
    for (const t of ['whoami', 'list_bookings', 'list_cars', 'list_staff', 'hire_applicant', 'cancel_booking', 'end_staff_access']) expect(names).toContain(t);
    expect(names).not.toContain('update_owner'); // owners:write not granted

    const read = await rpc('tools/call', { name: 'list_staff', arguments: { query: `mcp.staff.${tag}` } });
    expect(read.body.result.isError).toBe(false);
    expect(JSON.stringify(read.body.result.structuredContent)).toContain('Sam Staff');

    // the preview: nothing changes
    const args = { user: staff };
    const pv = await rpc('tools/call', { name: 'end_staff_access', arguments: args });
    expect(pv.body.result.isError).toBe(false);
    const preview = pv.body.result.structuredContent as { preview: boolean; preview_id: string; will_change: Record<string, { before: unknown; after: unknown }> };
    expect(preview.preview).toBe(true);
    expect(preview.will_change.status).toEqual({ before: 'active', after: 'suspended' });
    expect((await sql`select status from users where id = ${staff}`)[0]!.status).toBe('active');

    // a confirm without the preview, or with other arguments: refused
    const bare = await rpc('tools/call', { name: 'end_staff_access', arguments: { ...args, confirm: true } });
    expect(bare.body.result.isError).toBe(true);
    // the confirm: done once
    const done = await rpc('tools/call', { name: 'end_staff_access', arguments: { ...args, confirm: true, preview_id: preview.preview_id } });
    expect(done.body.result.isError).toBe(false);
    expect((done.body.result.structuredContent as { done: boolean }).done).toBe(true);
    expect((await sql`select status from users where id = ${staff}`)[0]!.status).toBe('suspended');
    const again = await rpc('tools/call', { name: 'end_staff_access', arguments: { ...args, confirm: true, preview_id: preview.preview_id } });
    expect(again.body.result.isError).toBe(true);

    const log = await sql`select tool, ok from api_calls where key_id = (select id from api_keys where key_hash = ${sha(key)}) and tool like 'end_staff_access%' order by id`;
    expect(log.map((r) => `${r.tool}:${r.ok}`)).toEqual(['end_staff_access:preview:true', 'end_staff_access:false', 'end_staff_access:true', 'end_staff_access:false']);
  } finally {
    await sql`update api_keys set revoked_at = now() where key_hash = ${sha(key)}`;
    await sql.end();
  }
});
