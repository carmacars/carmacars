import { rpc } from '@/lib/db/repo';
import { siteUrl } from '@/lib/site';
import { MAX_CLAIM_FILE_BYTES, TOOLS, bearer, claimFileKind, normalizeToolArgs, sha256Hex } from '@/features/api-access/tools';
import { oneStepHire } from '@/server/hire';
import { bookNowAgreement } from '@/server/book-now';
import { storage } from '@/integrations/storage';
import { MAX_PHOTO_BYTES } from '@/features/returns/claim';
import { findPayments, inspectAccount, inspectBooking, linkMetadata, stripeReader, tieOf, untiedWillDo, type Known, type PlanAnswer, type Recorded, type StripeGet } from '@/features/api-access/stripe-inspect';
import { helcimOnly, payments, terminal } from '@/integrations/payments';
import { accountView, findHelcimPayments, mountainDay, type HelcimKnown } from '@/features/api-access/helcim-inspect';
import { settleIntentEvent } from '@/server/intent-events';
import { setupEmail } from '@/server/owner-setup-email';
import { settleIntent } from '@/server/portal/payment';
import { env } from '@/lib/env';

// The CarmaCars MCP server (release 28, B3; migration 0562): Claude's connector for Abbas and Mahad. Streamable HTTP
// without a stream: each POST is one JSON-RPC message answered with one JSON response. The bearer is an API key from
// Admin > Settings > API access or an access token from the OAuth flow (/oauth/authorize); without one the answer is a
// 401 pointing at the protected resource metadata, which starts Claude's sign-in. Every tool call goes to the database
// (app.api_call), which checks the key, the scope, the Admin role and the rate limit, runs the tool as that person and
// logs it with the values before and after. Nothing here reads or writes data itself.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

const BOOK_NOW_TOOLS = ['send_offer', 'create_offer', 'book_offer_now'];

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
  return (await rpc('server_api_call', { p_hash: hash, p_tool: name, p_args: (normalizeToolArgs(args) ?? {}) as never, p_client: client }, SR)) as unknown as { ok: boolean; status?: number; result?: unknown; error?: string };
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
        instructions: 'CarmaCars car rental, as its Admin: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, statements, invoices, payouts, claims, tolls, expenses, leads, chats, To do\'s, field jobs, staff, onboarding, hiring and staff bug reports (with their pictures and logs). Every write is two calls: first without confirm, which previews what will change and changes nothing; show the preview to the person, and only when they agree call again with the same arguments plus confirm: true and the preview_id. The database checks each action exactly as the Admin screens do. Lists page with next_cursor (up to 200 a page) and hide test records unless include_test. Money out (refunds, deposit releases, payouts, charges) is only prepared as an Admin To do: never done here. Every call is logged with the values before and after, as the person whose key it is.'
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
      // r50 (3740): add_car reads the VIN's year, make, model and trim from the decode the site records; decoded here first (vPIC)
      if (name === 'add_car') await decodeForConnector((msg.params?.arguments as { vin?: unknown } | undefined)?.vin);
      let r = name === 'whoami' ? who : await callTool(hash, name, msg.params?.arguments ?? {}, client);
      if (r.status === 401) return unauthorized(r.error ?? 'Not valid');
      // a confirmed hire (0732): the database checked the key, the scope, the preview and the arguments; the hire itself runs
      // here as that Admin (the sign-in is made in the web layer), and its outcome is logged
      const run = r.ok ? (r.result as { run?: string; actor?: string; params?: { id?: string } & Record<string, unknown> } | undefined) : undefined;
      if (run?.run === 'hire' && run.actor && run.params?.id) r = await hire(hash, run.actor, run.params as { id: string } & Record<string, unknown>, client);
      // a confirmed booking photo (1156): the database checked the key, the scope, the preview and the booking's condition report;
      // the bytes, held here only, are checked against the fingerprint, stored privately, then recorded on the report
      if (run?.run === 'photo') r = await photo(hash, msg.params?.arguments as Record<string, unknown>, run.params as Record<string, unknown>, client);
      // a confirmed claim photo or estimate file (1873): the same, for a claim's incident
      if (run?.run === 'claim_file') r = await claimFile(hash, name, msg.params?.arguments as Record<string, unknown>, run.params as Record<string, unknown>, client);
      // Book it now (0770, 0810): a confirmed offer booked at once gets the renter's agreement made here, as the screens do
      // (staff-style requests wait for an Admin: bookNowAgreement does nothing until the booking is approved)
      if (r.ok && BOOK_NOW_TOOLS.includes(name)) {
        const done = r.result as { done?: boolean; result?: unknown } | undefined;
        if (done?.done) await bookNowAgreement(done.result);
      }
      // r47 (2896): Stripe, read here with the server's key after the database checked the key, the scope and the preview
      if (r.ok && (run?.run === 'stripe_booking' || run?.run === 'stripe_account' || run?.run === 'stripe_record_preview' || run?.run === 'stripe_record_paid' || run?.run === 'stripe_find')) r = await stripeTool(r.result as Record<string, unknown>);
      // r50 (3710): Helcim, read here with the server's token after the database checked the key, the scope and the preview
      if (r.ok && (run?.run === 'helcim_account' || run?.run === 'helcim_find' || run?.run === 'helcim_record_preview' || run?.run === 'helcim_record_paid')) r = await helcimTool(r.result as Record<string, unknown>);
      // r50 (3740): a car added through the connector: its title, description and features, and the owner's set-up email if approved
      if (r.ok && (r.result as { run?: string } | undefined)?.run === 'car_added') r = await carAdded(r.result as Record<string, unknown>);
      // r50 (3730): an owner's application approved through the connector: the owner's set-up email, as the application page sends it
      if (r.ok && (r.result as { run?: string } | undefined)?.run === 'owner_setup') r = await ownerSetup(r.result as Record<string, unknown>);
      // r48 (2923): the pay link is cancelled in the database; its PaymentIntent is cancelled at Stripe here (never captured)
      if (r.ok && (r.result as { run?: string } | undefined)?.run === 'pay_link_cancel') r = await payLinkCancel(r.result as Record<string, unknown>);
      // a bug report's pictures (2340): private files, given as links that expire in ten minutes
      if (r.ok && name === 'bug_report_get') r = { ...r, result: await signedShots(r.result) };
      const out = r.ok ? withLinks(r.result) : { error: r.error };
      return json(reply(msg.id, { content: [{ type: 'text', text: JSON.stringify(out, null, 1) }], structuredContent: Array.isArray(out) ? { items: out } : out, isError: !r.ok }));
    }
    default:
      if (isNote) return new Response(null, { status: 202 });
      return json(fail(msg.id, -32601, `Method not found: ${msg.method}`));
  }
}

async function photo(hash: string, args: Record<string, unknown> | undefined, p: Record<string, unknown>, client: string): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  const b64 = typeof args?.image_base64 === 'string' ? args.image_base64 : '';
  if (!b64 || (await sha256Hex(b64)) !== p.image_sha256) return { ok: false, status: 400, error: 'The photo differs from the preview: preview again' };
  let bytes: Uint8Array;
  try { bytes = Uint8Array.from(atob(b64.replace(/^data:image\/[a-z]+;base64,/, '')), (c) => c.charCodeAt(0)); } catch { return { ok: false, status: 400, error: 'image_base64 is not base64' }; }
  const jpg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47;
  if (!jpg && !png) return { ok: false, status: 400, error: 'That file is not a photo (JPEG or PNG)' };
  if (bytes.length > MAX_PHOTO_BYTES) return { ok: false, status: 400, error: 'Each photo must be under 8 MB' };
  const path = `bookings/${String(p.booking_id)}/claude/${crypto.randomUUID()}.${png ? 'png' : 'jpg'}`;
  try {
    await (await storage()).put('condition-photos', path, bytes, png ? 'image/png' : 'image/jpeg');
    const out = await rpc('server_api_photo_record' as never, { p_hash: hash, p_preview: String(args?.preview_id ?? ''), p_path: path, p_width: 0, p_height: 0, p_client: client } as never, SR);
    return { ok: true, result: out };
  } catch (e) { return { ok: false, status: 400, error: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The photo was not stored' }; }
}

async function claimFile(hash: string, tool: string, args: Record<string, unknown> | undefined, p: Record<string, unknown>, client: string): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  const b64 = typeof args?.file_base64 === 'string' ? args.file_base64 : '';
  if (!b64 || (await sha256Hex(b64)) !== p.file_sha256) return { ok: false, status: 400, error: 'The file differs from the preview: preview again' };
  let bytes: Uint8Array;
  try { bytes = Uint8Array.from(atob(b64.replace(/^data:[a-z]+\/[a-z]+;base64,/, '')), (c) => c.charCodeAt(0)); } catch { return { ok: false, status: 400, error: 'file_base64 is not base64' }; }
  const kind = claimFileKind(bytes);
  if (!kind || (tool === 'attach_claim_photo' && kind.ext === 'pdf')) return { ok: false, status: 400, error: tool === 'attach_claim_photo' ? 'That file is not a photo (JPEG or PNG)' : 'That file is not a PDF, JPEG or PNG' };
  if (bytes.length > MAX_CLAIM_FILE_BYTES) return { ok: false, status: 400, error: 'Each file must be under 8 MB' };
  const path = `claims/${String(p.claim_id)}/claude/${crypto.randomUUID()}.${kind.ext}`;
  try {
    await (await storage()).put('documents', path, bytes, kind.mime);
    const out = await rpc('server_api_claim_file_record' as never, { p_hash: hash, p_preview: String(args?.preview_id ?? ''), p_path: path, p_mime: kind.mime, p_sha: await sha256Hex(b64), p_client: client } as never, SR);
    return { ok: true, result: out };
  } catch (e) { return { ok: false, status: 400, error: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The file was not stored' }; }
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

/** A bug report with a link for each picture (ten minutes); the storage paths are not shown. */
async function signedShots(v: unknown): Promise<unknown> {
  const o = v as { screenshots?: Array<{ path: string; mime: string; bytes: number; kind: string }> } | undefined;
  if (!o?.screenshots?.length) return v;
  const st = await storage();
  const shots = await Promise.all(o.screenshots.map(async (x, i) => ({ n: i + 1, kind: x.kind, mime: x.mime, bytes: x.bytes,
    url: x.path.startsWith('bug-reports/') ? await st.signedDownloadUrl('documents', x.path, 600, `bug-picture-${i + 1}.${x.path.split('.').pop()}`).catch(() => null) : null,
    expires_in_seconds: 600 })));
  return { ...o, screenshots: shots.map((x) => ({ ...x, url: x.url && x.url.startsWith('/') ? siteUrl() + x.url : x.url })) };
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

/** r48 (2923): cancel_pay_link, confirmed: the link is already cancelled in the database; the PaymentIntent is cancelled at
 *  Stripe (an intent already canceled is fine). Nothing is captured or refunded. */
async function payLinkCancel(res: Record<string, unknown>): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  const { run: _run, ...rest } = res;
  void _run;
  const pi = String(res.payment_intent ?? '');
  let stripe: string;
  try {
    const p = await payments();
    const i = await p.retrieveIntent(pi);
    stripe = i.status === 'canceled' ? 'already canceled' : i.status === 'succeeded' ? 'succeeded at Stripe: not cancelled, check stripe_booking' : (await p.cancelIntent(pi, `void:${pi}`)).status;
  } catch (e) { stripe = `not cancelled at Stripe (${e instanceof Error ? e.message.slice(0, 120) : 'error'}): the link is cancelled, so it cannot be paid`; }
  return { ok: true, result: { ...rest, stripe } };
}

/** r47 (2896): the Stripe tools. Reads only GET (stripe-inspect.ts); stripe_record_paid records an intent Stripe shows
 *  succeeded through settleIntent, the webhook's own path (a succeeded intent is never captured again). */
function stripeGet(): StripeGet | null {
  const e = env();
  return e.PAYMENTS_PROVIDER === 'stripe' && e.STRIPE_SECRET_KEY ? stripeReader(e.STRIPE_SECRET_KEY) : null;
}
async function stripeTool(res: Record<string, unknown>): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  const get = stripeGet();
  try {
    if (res.run === 'stripe_record_paid') {
      const p = res.params as { id: string; booking_number: string; payment_intent: string };
      const i = await (await payments()).retrieveIntent(p.payment_intent);
      const tie = tieOf(i, p.id, p.booking_number);
      if (tie.kind === 'refused') return { ok: false, status: 400, error: tie.why };
      if (tie.kind === 'untied') return await linkUntied(String(res.actor), p);
      const out = await settleIntent(i.id, String(res.actor), `connector:${i.id}`);
      return out.ok ? { ok: true, result: { done: true, booking_number: out.bookingNumber, recorded: i.id, charged: false } } : { ok: false, status: 400, error: out.message };
    }
    if (!get) return { ok: false, status: 400, error: 'Stripe is not connected on this server (the fake payments provider is in use)' };
    if (res.run === 'stripe_account') return { ok: true, result: await inspectAccount(get) };
    if (res.run === 'stripe_find') {
      const known = async (ids: string[]) => (await rpc('server_stripe_known_many' as never, { p_intents: ids } as never, SR)) as unknown as Known;
      const found = await findPayments(get, { since: Number(res.since), until: Number(res.until), amount_cents: typeof res.amount_cents === 'number' ? res.amount_cents : null }, known);
      return { ok: true, result: { from: res.from, to: res.to, amount_cents: res.amount_cents ?? null, ...found } };
    }
    if (res.run === 'stripe_record_preview') {
      const i = await get(`/v1/payment_intents/${String(res.payment_intent)}`, { 'expand[]': 'latest_charge' }).catch(() => null);
      const { run: _run, ...rest } = res;
      void _run;
      if (!i) return { ok: true, result: { ...rest, stripe_status: null, can_confirm: false, warning: 'Stripe has no such PaymentIntent' } };
      const md = (i.metadata ?? {}) as Record<string, string>;
      const tie = tieOf({ status: String(i.status), metadata: md }, String(res.booking_id), String(res.booking_number));
      const base = { ...rest, stripe_status: i.status ?? null, amount_received_cents: i.amount_received ?? null };
      if (tie.kind === 'refused') return { ok: true, result: { ...base, can_confirm: false, warning: tie.why } };
      if (tie.kind === 'tied') return { ok: true, result: { ...base, can_confirm: true } };
      const ch = (i.latest_charge && typeof i.latest_charge === 'object' ? i.latest_charge : {}) as Record<string, unknown>;
      const plan = (await rpc('server_stripe_untied_plan' as never, { p_booking: String(res.booking_id), p_amount: Number(i.amount ?? 0), p_currency: String(i.currency ?? ''),
        p_intent: String(i.id), p_charge: typeof ch.id === 'string' ? ch.id : null } as never, SR)) as unknown as PlanAnswer;
      const amount = Number(i.amount ?? 0);
      return { ok: true, result: { ...base, untied: true, plan, can_confirm: plan.ok,
        ...(plan.ok ? { will_do: untiedWillDo(String(i.id), amount, String(res.booking_number), plan) } : { warning: `Untied payment (no booking in Stripe): ${plan.reason}` }) } };
    }
    return { ok: true, result: await inspectBooking(get, res.recorded as Recorded) };
  } catch (e) {
    return { ok: false, status: 502, error: `Stripe could not be read: ${e instanceof Error ? e.message.slice(0, 200) : 'unknown error'}` };
  }
}

/** r50 (3740): the VIN decoded with the site's decoder (vPIC) and recorded in vin_decodes, as Add a car does in the browser;
 *  a VIN already decoded, or that failed in the last hour, or with a wrong check digit, is not asked again. Never throws. */
async function decodeForConnector(raw: unknown): Promise<void> {
  const vin = typeof raw === 'string' ? raw.toUpperCase().replace(/[\s-]/g, '') : '';
  if (!/^[A-HJ-NPR-Z0-9]{17}$/.test(vin)) return;
  try {
    const f = (await rpc('server_vin_facts', { p_vin: vin }, SR)) as unknown as { decode: unknown; decode_failed_at?: string | null; check_ok?: boolean };
    const recent = f.decode_failed_at && Date.now() - new Date(f.decode_failed_at).getTime() < 3_600_000;
    if (f.decode || recent || f.check_ok === false) return;
    const { decodeVin } = await import('@/integrations/vin');
    const d = await decodeVin(vin).catch(() => null);
    if (d) await rpc('server_record_vin_decode', { p_vin: vin, p_provider: d.provider, p_output: d.result as never }, SR).catch(() => undefined);
  } catch { /* the database says what it could not read */ }
}
async function carAdded(res: Record<string, unknown>): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  const { run: _r, actor, approve, ...rest } = res;
  void _r;
  const { afterCarAdded } = await import('@/server/car-added');
  afterCarAdded();
  const setup = (approve as { setup?: { needed: boolean; owner_id: string; has_account: boolean; email: string | null; name: string } | null } | null)?.setup;
  if (!res.approved || !setup?.needed) return { ok: true, result: rest };
  const note = await setupEmail(String(actor), 'aal2', String(res.application_id), setup).catch((e: unknown) => `The set-up email did not go (${e instanceof Error ? e.message.slice(0, 120) : 'error'}): send it from the application page.`);
  return { ok: true, result: { ...rest, setup_email: note } };
}

/** r50 (3730): after approve_owner_car, the set-up email the application page would send (never twice: the database says). */
async function ownerSetup(res: Record<string, unknown>): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  const { run: _r, actor, ...rest } = res;
  void _r;
  const setup = res.setup as { needed?: boolean; owner_id: string; has_account: boolean; email: string | null; name: string } | null | undefined;
  if (!setup?.needed) return { ok: true, result: rest };
  const note = await setupEmail(String(actor), 'aal2', String(res.application_id), setup).catch((e: unknown) => `Approved. The set-up email did not go (${e instanceof Error ? e.message.slice(0, 120) : 'error'}): send it from the application page.`);
  return { ok: true, result: { ...rest, setup_email: note } };
}

/** r50 (3710): the Helcim tools. Reads only GET (helcim-inspect.ts); helcim_record_paid records a transaction Helcim shows
 *  approved through the webhook's own steps (intent-events.ts), or, taken outside the site, as Link a Stripe payment does. */
async function helcimTool(res: Record<string, unknown>): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  const h = await helcimOnly();
  if (!h) return { ok: false, status: 400, error: 'Helcim is not the card processor on this server (PAYMENTS_PROVIDER is not helcim, or HELCIM_API_TOKEN is not set)' };
  try {
    if (res.run === 'helcim_account') {
      const ok = await h.connectionTest().then(() => ({ ok: true, error: null as string | null })).catch((e: unknown) => ({ ok: false, error: e instanceof Error ? e.message.slice(0, 200) : 'error' }));
      const now = new Date();
      const last = ok.ok ? await h.transactions({ dateFrom: mountainDay(new Date(now.getTime() - 86_400_000)), dateTo: mountainDay(now) }).catch(() => []) : [];
      return { ok: true, result: accountView(ok.ok, ok.error, last, !!env().HELCIM_WEBHOOK_VERIFIER_TOKEN, env().HELCIM_TERMINAL_ID ?? null) };
    }
    if (res.run === 'helcim_find') {
      const known = async (ids: number[]) => (await rpc('server_helcim_known' as never, { p_tx: ids } as never, SR)) as unknown as HelcimKnown;
      const found = await findHelcimPayments((f, t) => h.transactions({ dateFrom: f, dateTo: t }), { from: new Date(String(res.from)), to: new Date(String(res.to)),
        amount_cents: typeof res.amount_cents === 'number' ? res.amount_cents : null }, known);
      return { ok: true, result: { from: res.from, to: res.to, amount_cents: res.amount_cents ?? null, ...found } };
    }
    const p = (res.params ?? res) as { id?: string; booking_id?: string; booking_number: string; transaction_id: string };
    const bookingId = String(p.id ?? p.booking_id ?? '');
    const tx = await h.transaction(Number(p.transaction_id)).catch(() => null);
    const { run: _run, ...rest } = res;
    void _run;
    if (!tx) return res.run === 'helcim_record_preview' ? { ok: true, result: { ...rest, helcim_status: null, can_confirm: false, warning: 'Helcim has no such transaction' } } : { ok: false, status: 400, error: 'Helcim has no such transaction' };
    const approved = String(tx.status).toUpperCase() === 'APPROVED' && ['purchase', 'preauth', 'capture'].includes(tx.type);
    const mine = approved ? await h.reconcile(tx.transactionId) : { intent: null };
    const tiedTo = mine.intent?.metadata.booking_id ?? null;
    const refuse = !approved ? `Helcim shows this ${tx.type} ${String(tx.status).toLowerCase()}, not approved: nothing is recorded`
      : tiedTo && tiedTo !== bookingId ? `This Helcim payment belongs to booking ${mine.intent?.metadata.booking_number ?? tiedTo}, not ${p.booking_number}`
      : !mine.intent && tx.type === 'preauth' ? 'A hold taken outside the site cannot be linked: capture it in Helcim first, then record the capture' : null;
    if (res.run === 'helcim_record_preview') {
      const base = { ...rest, helcim_status: tx.status, helcim_type: tx.type, amount_cents: Math.round(Number(tx.amount) * 100) };
      if (refuse) return { ok: true, result: { ...base, can_confirm: false, warning: refuse } };
      if (mine.intent) return { ok: true, result: { ...base, can_confirm: true, intent: mine.intent.id } };
      const plan = (await rpc('server_stripe_untied_plan' as never, { p_booking: bookingId, p_amount: base.amount_cents, p_currency: 'cad', p_intent: 'hc_preview_untied', p_charge: null } as never, SR)) as unknown as PlanAnswer;
      return { ok: true, result: { ...base, untied: true, plan, can_confirm: plan.ok, ...(plan.ok ? { will_do: untiedWillDo(`Helcim ${tx.transactionId}`, base.amount_cents, String(p.booking_number), plan) } : { warning: `Untied payment (no booking at Helcim): ${plan.reason}` }) } };
    }
    if (refuse) return { ok: false, status: 400, error: refuse };
    if (mine.intent) {
      const i = mine.intent;
      const type = i.status === 'requires_capture' ? 'payment_intent.amount_capturable_updated' : 'payment_intent.succeeded';
      const out = await settleIntentEvent(`connector:${i.id}`, type, { id: i.id, object: 'payment_intent', metadata: i.metadata });
      return { ok: true, result: { done: true, booking_number: p.booking_number, recorded: i.id, transaction_id: tx.transactionId, settled: out, charged: false, captured: false } };
    }
    const i = await h.adoptTransaction(tx, { booking_id: bookingId, booking_number: String(p.booking_number), linked_by: String(res.actor ?? '') });
    const verified = { intent_id: i.id, charge_id: i.chargeId, status: i.status, amount_cents: i.amountCents, capturable_cents: 0, currency: 'cad', last4: i.card?.last4 ?? null,
      brand: i.card?.brand ?? null, fingerprint: i.card?.fingerprint ?? null, capture_before: null };
    const out = (await rpc('server_stripe_link_untied' as never, { p_by: String(res.actor), p_booking: bookingId, p_verified: verified } as never, SR)) as unknown as Record<string, unknown>;
    return { ok: true, result: { done: true, booking_number: p.booking_number, recorded: i.id, transaction_id: tx.transactionId, untied: true, as: out.as, rental_cents: out.rental_cents, deposit_cents: out.deposit_cents, charged: false, captured: false, refunded: false } };
  } catch (e) {
    return { ok: false, status: 502, error: `Helcim could not be read: ${e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'unknown error'}` };
  }
}

/** hotfix 3430: stripe_record_paid, confirmed, for a payment with no booking in Stripe (Tap to Pay in the Dashboard app). Read
 *  at Stripe again, recorded by the database as Link a Stripe payment does (it checks the amount against what is open, that
 *  nothing knows the payment, and audits it), then the booking is written into the PaymentIntent's metadata. Nothing is
 *  charged, captured or refunded: a payment that is not succeeded is refused before anything is recorded. */
async function linkUntied(actor: string, p: { id: string; booking_number: string; payment_intent: string }): Promise<{ ok: boolean; status?: number; result?: unknown; error?: string }> {
  const t = await terminal();
  const i = await t.lookupPayment(p.payment_intent);
  if (i.status !== 'succeeded') return { ok: false, status: 400, error: `Stripe shows this payment ${i.status}, not succeeded: nothing is recorded (and nothing is captured here)` };
  const verified = { intent_id: i.id, charge_id: i.chargeId, status: i.status, amount_cents: i.amountCents, capturable_cents: i.amountCapturableCents, currency: i.currency,
    last4: i.card?.last4 || null, brand: i.card?.brand ?? null, fingerprint: i.card?.fingerprint ?? null, capture_before: i.captureBefore ?? null };
  let out: Record<string, unknown>;
  try {
    out = (await rpc('server_stripe_link_untied' as never, { p_by: actor, p_booking: p.id, p_verified: verified } as never, SR)) as unknown as Record<string, unknown>;
  } catch (e) { return { ok: false, status: 400, error: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The payment was not recorded' }; }
  let stripe_metadata = 'set';
  try { await t.tagIntent(i.id, linkMetadata(i.metadata, p.id, p.booking_number)); } catch (e) {
    stripe_metadata = `not set (${e instanceof Error ? e.message.slice(0, 120) : 'error'}): the payment is recorded; stripe_booking still finds it by its id`;
  }
  return { ok: true, result: { done: true, booking_number: p.booking_number, recorded: i.id, untied: true, as: out.as, rental_cents: out.rental_cents, deposit_cents: out.deposit_cents,
    confirmed: (out as { confirmed?: boolean; rental?: { confirmed?: boolean } }).confirmed ?? (out as { rental?: { confirmed?: boolean } }).rental?.confirmed ?? null,
    stripe_metadata, charged: false, captured: false, refunded: false } };
}
