// send-outbox: the email sender (docs/architecture.md section 5, docs/changes/0018_notifications.md).
// Called every minute by pg_cron through pg_net (job `carmacars-send-outbox`, scheduled by the CI deploy
// job) with `Authorization: Bearer <OUTBOX_JOB_TOKEN>`; any other caller gets 403. It claims a batch with
// app.outbox_claim() (daily and monthly caps, priorities), renders each row with emails/src/engine.mjs
// (copied next to this file at deploy time as engine.mjs), sends it through Resend and reports back with
// app.outbox_mark_sent() or app.outbox_mark_failed(). Resend's own limits (HTTP 429: 2 requests a second, and
// the free plan's 100 a day for the whole account, Supabase Auth's emails included) hold the row with
// app.outbox_defer() without spending an attempt (0043): a rate refusal for a minute, a quota refusal for two hours
// (a spread of its own; 2026-11-06), together with the rest of the batch. Sends are spaced to stay under the rate.
//
// Secrets (Edge Function secrets, set by the deploy job): OUTBOX_JOB_TOKEN, RESEND_API_KEY, APP_URL,
// LINK_SIGNING_KEY (the site's key: the 7-day file links are opened by the site at /d/<token>).
// SUPABASE_DB_URL is provided by Supabase. Statement emails carry their PDFs as attachments (app.outbox_attachments).
//
// R23 (0222, docs/changes/2026-11-03-cloudflare-email.md): Cloudflare Email Service first, Resend after. While the
// database says Cloudflare may send (app.cf_email_try: switched on, this month's included sends not used, no
// failure in the last 15 minutes), each email goes to the site's /api/email/send (the Worker's EMAIL binding), signed with
// LINK_SIGNING_KEY like the cron jobs; a refusal is reported (server_cf_email_result) and the email goes through Resend
// as before. The daily and monthly holds of 0018 then apply only when Cloudflare cannot send either.
import postgres from 'npm:postgres@3.4.5';
import { render, renderText } from './engine.mjs';

const TOKEN = Deno.env.get('OUTBOX_JOB_TOKEN') ?? '';
const RESEND = Deno.env.get('RESEND_API_KEY') ?? '';
const APP_URL = (Deno.env.get('APP_URL') ?? 'https://carmacars.ca').replace(/\/$/, '');
const LINK_KEY = Deno.env.get('LINK_SIGNING_KEY') ?? '';
const LINK_TTL = 7 * 24 * 3600;
const BATCH = 20;

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false, idle_timeout: 20, onnotice: () => {} });

interface Row {
  id: string; code: string; category: string; to_address: string; to_name: string | null; from_address: string | null;
  reply_to: string | null; subject: string; payload: Record<string, unknown>; attempts: number; unsubscribe_url: string | null;
  template_html: string | null; template_text: string | null;
}

// The values only a sender can produce (catalogue `sender_supplied`). A document the email promises is a
// signed link valid 7 days (app.outbox_file_refs says which record each link opens; the token has the same
// form as the site's signToken in web/src/server/links.ts, purpose "doc"). Without a record yet, or without
// the key, the link goes to the portal page behind sign-in. Sign-in service links go to the sign-in pages.
// A value already in the payload always wins.
const enc = new TextEncoder();
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
async function signDoc(k: string, key: string): Promise<string> {
  const body = b64url(enc.encode(JSON.stringify({ k, key, p: 'doc', exp: Math.floor(Date.now() / 1000) + LINK_TTL })));
  const hk = await crypto.subtle.importKey('raw', enc.encode(LINK_KEY), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return `${APP_URL}/d/${body}.${b64url(new Uint8Array(await crypto.subtle.sign('HMAC', hk, enc.encode(body))))}`;
}

async function senderValues(r: Row): Promise<Record<string, unknown>> {
  const portal = r.code.startsWith('owner_') ? `${APP_URL}/owner` : r.code.startsWith('investor_') ? `${APP_URL}/investor/statements` : `${APP_URL}/account`;
  const out: Record<string, unknown> = {
    link_expiry: '7 days',
    // never a stand-in for a link that confirms an address (0045): the only confirmation link is Supabase's own email
    sign_in_url: `${APP_URL}/sign-in`, reset_url: `${APP_URL}/reset-password`,
    signed_agreement_url: portal, receipt_url: portal, statement_url: portal, supporting_document_url: portal, invoice_url: `${APP_URL}/contact`,
    security_device: 'Not recorded', security_event: 'Account change', security_event_at: 'Recently', security_place: 'Not recorded'
  };
  if (LINK_KEY) {
    const [{ refs }] = (await sql`select app.outbox_file_refs(${r.id}::uuid) as refs`) as unknown as [{ refs: Record<string, { k: string; key: string }> }];
    for (const [name, ref] of Object.entries(refs ?? {})) out[name] = await signDoc(ref.k, ref.key);
  }
  return out;
}

// The files an email carries as attachments (app.outbox_attachments: the statement PDFs). Each is fetched through
// the site's signed link, as the reader would open it, so the PDF is the stored copy (rendered and stored first
// when it is not yet). A file that cannot be fetched holds the email back for a retry; from the third attempt the
// email goes without it (its 7-day link still opens the file).
const b64 = (u: Uint8Array) => { let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000)); return btoa(s); };
async function attachments(r: Row): Promise<Array<{ filename: string; content: string; content_type: string }>> {
  if (!LINK_KEY) return [];
  const [{ list }] = (await sql`select app.outbox_attachments(${r.id}::uuid) as list`) as unknown as [{ list: Array<{ k: string; key: string; filename: string }> }];
  const out: Array<{ filename: string; content: string; content_type: string }> = [];
  for (const a of list ?? []) {
    try {
      const res = await fetch(await signDoc(a.k, a.key), { headers: { 'user-agent': 'carmacars-send-outbox' } });
      const type = res.headers.get('content-type') ?? '';
      if (!res.ok || !type.includes('pdf')) throw new Error(`the file answered ${res.status} ${type}`);
      out.push({ filename: a.filename, content: b64(new Uint8Array(await res.arrayBuffer())), content_type: 'application/pdf' });
    } catch (e) {
      if (r.attempts < 3) throw new Error(`Attachment ${a.filename}: ${(e as Error).message}`);
    }
  }
  return out;
}

// Live visitors (migration 0060): a renter's links into their own booking pages carry this outbox row's id (?m=), so
// the site can tell "opened the offer email" and who the visitor is (app.visitor_from_email_link). Only links to the
// renter portal's booking pages, in the rendered email; never signed file links, sign-in or unsubscribe links.
const PORTAL_LINK = /(https:\/\/(?:www\.)?carmacars\.ca\/account\/bookings\/[A-Za-z0-9-]+(?:\/[a-z-]+)?)(#[\w-]+)?(?=["'\s<)\]]|$)/g;
function tagLinks(r: { id: string; code: string; category: string }, body: string): string {
  if (/^(staff_|owner_|investor_|insurer_|account_)/.test(r.code) || r.category !== 'transactional') return body;
  return body.replace(PORTAL_LINK, (_m, path: string, hash?: string) => `${path}?m=${r.id}${hash ?? ''}`);
}

const fromHeader = (a: string | null) => {
  const addr = a || 'hello@carmacars.ca';
  return addr.includes('<') ? addr : `CarmaCars <${addr}>`;
};

// the bearer token the site's /api/email/send accepts: HMAC of a fixed label with LINK_SIGNING_KEY (web/src/server/email-send.ts)
async function siteToken(): Promise<string> {
  const hk = await crypto.subtle.importKey('raw', enc.encode(LINK_KEY), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return Array.from(new Uint8Array(await crypto.subtle.sign('HMAC', hk, enc.encode('carmacars-email-send-v1'))), (b) => b.toString(16).padStart(2, '0')).join('');
}
type Mail = { from: string; to: string; reply_to?: string; subject: string; html: string; text: string; headers?: Record<string, string>;
  attachments?: Array<{ filename: string; content: string; content_type: string }> };
// Cloudflare Email Service through the site's Worker: its message id, or the reason it did not send
async function viaCloudflare(m: Mail): Promise<{ id: string } | { error: string }> {
  try {
    const res = await fetch(`${APP_URL}/api/email/send`, { method: 'POST', headers: { authorization: `Bearer ${await siteToken()}`, 'content-type': 'application/json' },
      body: JSON.stringify(m), signal: AbortSignal.timeout(20_000) });
    const j = (await res.json().catch(() => ({}))) as { id?: string; error?: string };
    if (res.ok && j.id) return { id: j.id };
    return { error: `Cloudflare ${res.status}: ${(j.error ?? '').slice(0, 300)}` };
  } catch (e) { return { error: `Cloudflare: ${(e as Error).message}`.slice(0, 300) }; }
}
let cfOn = false;
// 0433: the day's budget per provider (Cloudflare first: 200, Resend after: 100); counts kept here as this batch sends
const budget = { cfLeft: 200, resendLeft: 100, midnight: new Date(Date.now() + 3600_000) };
async function loadBudgets() {
  try {
    const [{ b }] = (await sql`select public.server_email_budgets() as b`) as unknown as [{ b: { cf_budget: number; resend_budget: number; cf_used: number; resend_used: number; midnight: string } }];
    budget.cfLeft = Math.max(0, b.cf_budget - b.cf_used); budget.resendLeft = Math.max(0, b.resend_budget - b.resend_used); budget.midnight = new Date(b.midnight);
  } catch { /* an older database: no budgets, the claim's caps apply */ budget.cfLeft = 1e9; budget.resendLeft = 1e9; }
}

// Resend's 429 body names the limit: rate_limit_exceeded, daily_quota_exceeded or monthly_quota_exceeded.
// 2026-11-06: a quota refusal no longer waits for midnight (the whole backlog then came due at the same minute, spent the
// day's quota in the first batches and was refused again): the rows wait 2 to 2.5 hours, a spread of their own, and the
// pacing of app.outbox_claim (0432) keeps the low priority classes from taking the day's quota first.
class Held extends Error { constructor(public reason: string, public until: 'minute' | 'later', public done = false) { super(reason); } }
function held(status: number, body: string): Held | null {
  if (status !== 429) return null;
  if (/daily_quota|monthly_quota|quota/i.test(body)) return new Held(/monthly/i.test(body) ? 'the email provider\'s monthly limit' : 'the email provider\'s daily limit', 'later');
  return new Held('held by the email provider\'s rate limit', 'minute');
}
async function defer(r: Row, h: Held) {
  const until = h.done ? budget.midnight : h.until === 'minute' ? new Date(Date.now() + 60_000) : new Date(Date.now() + 2 * 3600_000 + Math.floor(Math.random() * 1800_000));
  await sql`select app.outbox_defer(${r.id}::uuid, ${h.reason}, ${until})`;
}
const pause = (ms: number) => new Promise((ok) => setTimeout(ok, ms));

async function sendOne(r: Row): Promise<'sent' | 'failed' | Held> {
  try {
    if (!r.template_html || !r.template_text) throw Object.assign(new Error('The catalogue has no template for ' + r.code), { permanent: true });
    const values = { ...(await senderValues(r)), ...r.payload };
    let html: string, text: string;
    try {
      html = tagLinks(r, render(r.template_html, values));
      text = tagLinks(r, renderText(r.template_text, values));
    } catch (e) {
      throw Object.assign(new Error('Template: ' + (e as Error).message), { permanent: true });
    }
    const headers: Record<string, string> = {};
    if (r.category === 'marketing') {
      if (!r.unsubscribe_url) throw Object.assign(new Error('A marketing email needs its unsubscribe link'), { permanent: true });
      // RFC 8058: the one-click POST goes to the site's /api/unsubscribe with the email's token; the
      // link in the body (unsubscribe_url) opens the page, which asks first.
      const token = new URL(r.unsubscribe_url).searchParams.get('token') ?? '';
      headers['List-Unsubscribe'] = `<${APP_URL}/api/unsubscribe?token=${encodeURIComponent(token)}>`;
      headers['List-Unsubscribe-Post'] = 'List-Unsubscribe=One-Click';
    }
    const files = await attachments(r);
    if (cfOn && budget.cfLeft <= 0) cfOn = false;
    if (!cfOn && budget.resendLeft <= 0) {
      // both budgets are used: the email waits for tomorrow, attempts untouched (oldest, highest priority first when it comes due)
      await sql`select app.outbox_defer(${r.id}::uuid, ${'the day\'s email budget is used'}, ${budget.midnight})`;
      return new Held('the day\'s email budget is used', 'later', true);
    }
    if (cfOn) {
      const cf = await viaCloudflare({ from: fromHeader(r.from_address), to: r.to_address, reply_to: r.reply_to || undefined, subject: r.subject, html, text,
        headers: Object.keys(headers).length ? headers : undefined, attachments: files.length ? files : undefined });
      if ('id' in cf) {
        await sql`select public.server_cf_email_result(${JSON.stringify({ ok: true })}::jsonb)`;
        await sql`select app.outbox_mark_sent(${r.id}::uuid, ${'cf:' + cf.id}, ${text})`;
        budget.cfLeft--;
        return 'sent';
      }
      // not this time: reported (Cloudflare rests 15 minutes), and this email goes through Resend
      cfOn = false;
      await sql`select public.server_cf_email_result(${JSON.stringify({ ok: false, error: cf.error })}::jsonb)`;
    }
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND}`, 'content-type': 'application/json', 'Idempotency-Key': `outbox-${r.id}-${r.attempts}` },
      body: JSON.stringify({ from: fromHeader(r.from_address), to: [r.to_address], reply_to: r.reply_to || undefined, subject: r.subject, html, text,
        headers: Object.keys(headers).length ? headers : undefined, attachments: files.length ? files : undefined })
    });
    if (!res.ok) {
      const body = (await res.text()).slice(0, 500);
      const h = held(res.status, body);
      if (h) {
        // 2026-11-06: Resend refused for its rate or quota: the Cloudflare email binding sends this one instead (the site's
        // Worker), and the rest of the batch goes there too; only when that fails too the row waits, attempts untouched
        if (LINK_KEY) {
          const cf = await viaCloudflare({ from: fromHeader(r.from_address), to: r.to_address, reply_to: r.reply_to || undefined, subject: r.subject, html, text,
            headers: Object.keys(headers).length ? headers : undefined, attachments: files.length ? files : undefined });
          if ('id' in cf) {
            cfOn = true;
            await sql`select app.outbox_mark_sent(${r.id}::uuid, ${'cf:' + cf.id}, ${text})`;
            return 'sent';
          }
        }
        await defer(r, h); return h;
      }
      // 4xx other than rate limiting will not get better on a retry
      throw Object.assign(new Error(`Resend ${res.status}: ${body}`), { permanent: res.status >= 400 && res.status < 500 && res.status !== 429 });
    }
    const { id } = (await res.json()) as { id: string };
    budget.resendLeft--;
    await sql`select app.outbox_mark_sent(${r.id}::uuid, ${id}, ${text})`;
    return 'sent';
  } catch (e) {
    const err = e as Error & { permanent?: boolean };
    await sql`select app.outbox_mark_failed(${r.id}::uuid, ${err.message.slice(0, 1000)}, ${err.permanent === true})`;
    return 'failed';
  }
}

Deno.serve(async (req) => {
  if (!TOKEN || req.headers.get('authorization') !== `Bearer ${TOKEN}`) return new Response('Forbidden', { status: 403 });
  if (!RESEND) return new Response('RESEND_API_KEY is not set', { status: 500 });
  // 0222: Cloudflare first while the database says it may send (an older database without it: Resend only)
  try { cfOn = ((await sql`select app.cf_email_try() as ok`) as unknown as [{ ok: boolean }])[0].ok === true && !!LINK_KEY; } catch { cfOn = false; }
  await loadBudgets();
  const rows = (await sql`select * from app.outbox_claim(${BATCH})`) as unknown as Row[];
  let sent = 0, failed = 0, deferred = 0;
  let stop: Held | null = null;
  for (const r of rows) {
    // after a quota refusal nothing more can go today: the rest of the batch waits too, attempts untouched
    if (stop) { await defer(r, stop); deferred++; continue; }
    const t0 = Date.now();
    const out = await sendOne(r);
    if (out instanceof Held) { deferred++; if (out.until === 'later') stop = out; }
    else if (out === 'sent') sent++; else failed++;
    // Resend allows 2 requests a second per account (Cloudflare's sends need no spacing)
    const wait = (cfOn ? 0 : 550) - (Date.now() - t0);
    if (wait > 0) await pause(wait);
  }
  return Response.json({ claimed: rows.length, sent, failed, deferred });
});
