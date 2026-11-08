import { rpc } from '@/lib/db/repo';
import { siteUrl } from '@/lib/site';
import { TOOLS, bearer, sha256Hex } from '@/features/api-access/tools';
import { oneStepHire } from '@/server/hire';

// The CarmaCars MCP server (release 28, B3; migration 0562): Claude's connector for Abbas and Mahad. Streamable HTTP
// without a stream: each POST is one JSON-RPC message answered with one JSON response. The bearer is an API key from
// Admin > Settings > API access or an access token from the OAuth flow (/oauth/authorize); without one the answer is a
// 401 pointing at the protected resource metadata, which starts Claude's sign-in. Every tool call goes to the database
// (app.api_call), which checks the key, the scope, the Admin role and the rate limit, runs the tool as that person and
// logs it with the values before and after. Nothing here reads or writes data itself.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

type Rpc = { jsonrpc: '2.0'; id?: string | number | null; method?: string; params?: Record<string, unknown> };
const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(body === null ? null : JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...extra } });
const reply = (id: Rpc['id'], result: unknown) => ({ jsonrpc: '2.0', id: id ?? null, result });
const fail = (id: Rpc['id'], code: number, message: string) => ({ jsonrpc: '2.0', id: id ?? null, error: { code, message } });

function unauthorized(message: string): Response {
  const meta = `${siteUrl()}/.well-known/oauth-protected-resource/api/mcp`;
  return json({ error: 'invalid_token', error_description: message }, 401, { 'www-authenticate': `Bearer resource_metadata="${meta}", error="invalid_token"` });
}

async function callTool(hash: string, name: string, args: unknown, client: string): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  return (await rpc('server_api_call', { p_hash: hash, p_tool: name, p_args: (args ?? {}) as never, p_client: client }, SR)) as unknown as { ok: boolean; status?: number; result?: unknown; error?: string };
}

export async function GET() {
  // no server-sent stream: every answer comes with its POST
  return new Response(null, { status: 405, headers: { allow: 'POST' } });
}

export async function POST(req: Request) {
  const secret = bearer(req.headers.get('authorization'));
  if (!secret) return unauthorized('Sign in to CarmaCars to connect, or send an API key as a Bearer token.');
  const hash = await sha256Hex(secret);
  const client = (req.headers.get('user-agent') ?? '').slice(0, 64);
  let msg: Rpc;
  try { msg = (await req.json()) as Rpc; } catch { return json(fail(null, -32700, 'Parse error'), 400); }
  if (Array.isArray(msg)) return json(fail(null, -32600, 'Send one message per request'), 400);
  if (!msg || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') return json(fail(msg?.id, -32600, 'Invalid request'), 400);
  // check the key on every message (whoami is free of scope): a revoked key or a lapsed Admin role stops at once
  const who = await callTool(hash, 'whoami', {}, client);
  if (!who.ok) return who.status === 401 ? unauthorized(who.error ?? 'Not valid') : json(fail(msg.id, -32001, who.error ?? 'Not permitted'), who.status === 429 ? 429 : 403);
  const scopes = ((who.result as { scopes?: string[] } | undefined)?.scopes) ?? [];
  const isNote = msg.id === undefined || msg.id === null;

  switch (msg.method) {
    case 'initialize': {
      const asked = String(msg.params?.protocolVersion ?? '');
      return json(reply(msg.id, {
        protocolVersion: VERSIONS.includes(asked) ? asked : VERSIONS[1],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'carmacars', title: 'CarmaCars', version: '1.0.0' },
        instructions: 'CarmaCars car rental, as its Admin: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, invoices, staff and hiring. Every write is two calls: first without confirm, which previews what will change and changes nothing; show the preview to the person, and only when they agree call again with the same arguments plus confirm: true and the preview_id. The database checks each action exactly as the Admin screens do. Every call is logged with the values before and after.'
      }));
    }
    case 'notifications/initialized': case 'notifications/cancelled':
      return new Response(null, { status: 202 });
    case 'ping':
      return json(reply(msg.id, {}));
    case 'tools/list':
      return json(reply(msg.id, { tools: TOOLS.filter((t) => t.scope === 'any' || scopes.includes(t.scope)).map((t) => ({
        name: t.name, title: t.title, description: t.description, inputSchema: t.inputSchema,
        annotations: { title: t.title, readOnlyHint: t.readOnly, destructiveHint: t.destructive ?? false, idempotentHint: t.readOnly, openWorldHint: false }
      })) }));
    case 'tools/call': {
      const name = String(msg.params?.name ?? '');
      if (!TOOLS.some((t) => t.name === name)) return json(fail(msg.id, -32602, `Unknown tool: ${name}`));
      let r = name === 'whoami' ? who : await callTool(hash, name, msg.params?.arguments ?? {}, client);
      if (r.status === 401) return unauthorized(r.error ?? 'Not valid');
      // a confirmed hire (0732): the database checked the key, the scope, the preview and the arguments; the hire itself runs
      // here as that Admin (the sign-in is made in the web layer), and its outcome is logged
      const run = r.ok ? (r.result as { run?: string; actor?: string; params?: { id?: string } & Record<string, unknown> } | undefined) : undefined;
      if (run?.run === 'hire' && run.actor && run.params?.id) r = await hire(hash, run.actor, run.params as { id: string } & Record<string, unknown>, client);
      const out = r.ok ? withLinks(r.result) : { error: r.error };
      return json(reply(msg.id, { content: [{ type: 'text', text: JSON.stringify(out, null, 1) }], structuredContent: Array.isArray(out) ? { items: out } : out, isError: !r.ok }));
    }
    default:
      if (isNote) return new Response(null, { status: 202 });
      return json(fail(msg.id, -32601, `Method not found: ${msg.method}`));
  }
}

async function hire(hash: string, actor: string, p: { id: string } & Record<string, unknown>, client: string): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  let out: Awaited<ReturnType<typeof oneStepHire>>;
  try {
    out = await oneStepHire(actor, 'aal2', { id: p.id, function: (p.function as string) ?? null, start_on: (p.start_on as string) ?? null,
      pay_cents: typeof p.pay_cents === 'number' ? p.pay_cents : null, pay_currency: (p.pay_currency as string) ?? null });
  } catch (e) { out = { ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The hire failed' }; }
  await rpc('server_api_hire_result', { p_hash: hash, p_application: p.id, p_ok: out.ok, p_error: out.ok ? '' : out.message, p_client: client }, SR).catch(() => null);
  return out.ok ? { ok: true, result: { done: true, tool: 'hire_applicant', onboarding: out.status, admin_path: `/admin/hiring/${p.id}` } } : { ok: false, status: 400, error: out.message };
}

/** The portal links in full (the database gives paths). */
function withLinks(v: unknown): unknown {
  const site = siteUrl();
  const fix = (o: unknown): unknown => {
    if (Array.isArray(o)) return o.map(fix);
    if (o && typeof o === 'object') {
      const r: Record<string, unknown> = {};
      for (const [k, x] of Object.entries(o)) {
        if (k === 'admin_path' && typeof x === 'string') r.admin_url = site + x; else r[k] = fix(x);
      }
      return r;
    }
    return o;
  };
  return fix(v);
}
