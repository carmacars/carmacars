// send-outbox: the email sender (docs/architecture.md section 5, docs/changes/0018_notifications.md).
// Called every minute by pg_cron through pg_net (job `carmacars-send-outbox`, scheduled by the CI deploy
// job) with `Authorization: Bearer <OUTBOX_JOB_TOKEN>`; any other caller gets 403. It claims a batch with
// app.outbox_claim() (daily and monthly caps, priorities), renders each row with emails/src/engine.mjs
// (copied next to this file at deploy time as engine.mjs), sends it through Resend and reports back with
// app.outbox_mark_sent() or app.outbox_mark_failed(). Resend's own limits (HTTP 429: 2 requests a second, and
// the free plan's 100 a day for the whole account, Supabase Auth's emails included) hold the row with
// app.outbox_defer() without spending an attempt (0043): a rate refusal for a minute, a quota refusal until the
// next Toronto midnight, together with the rest of the batch. Sends are spaced to stay under the rate.
//
// Secrets (Edge Function secrets, set by the deploy job): OUTBOX_JOB_TOKEN, RESEND_API_KEY, APP_URL,
// LINK_SIGNING_KEY (the site's key: the 7-day file links are opened by the site at /d/<token>).
// SUPABASE_DB_URL is provided by Supabase. Statement emails carry their PDFs as attachments (app.outbox_attachments).
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
    verify_url: `${APP_URL}/sign-in`, sign_in_url: `${APP_URL}/sign-in`, reset_url: `${APP_URL}/reset-password`,
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

const fromHeader = (a: string | null) => {
  const addr = a || 'hello@carmacars.ca';
  return addr.includes('<') ? addr : `CarmaCars <${addr}>`;
};

// Resend's 429 body names the limit: rate_limit_exceeded, daily_quota_exceeded or monthly_quota_exceeded.
class Held extends Error { constructor(public reason: string, public until: 'minute' | 'midnight') { super(reason); } }
function held(status: number, body: string): Held | null {
  if (status !== 429) return null;
  if (/daily_quota|monthly_quota|quota/i.test(body)) return new Held(/monthly/i.test(body) ? 'the email provider\'s monthly limit' : 'the email provider\'s daily limit', 'midnight');
  return new Held('held by the email provider\'s rate limit', 'minute');
}
const nextMidnight = async () => ((await sql`select app.local_midnight(app.local_date(now()) + 1) as t`) as unknown as [{ t: Date }])[0].t;
async function defer(r: Row, h: Held) {
  const until = h.until === 'minute' ? new Date(Date.now() + 60_000) : await nextMidnight();
  await sql`select app.outbox_defer(${r.id}::uuid, ${h.reason}, ${until})`;
}
const pause = (ms: number) => new Promise((ok) => setTimeout(ok, ms));

async function sendOne(r: Row): Promise<'sent' | 'failed' | Held> {
  try {
    if (!r.template_html || !r.template_text) throw Object.assign(new Error('The catalogue has no template for ' + r.code), { permanent: true });
    const values = { ...(await senderValues(r)), ...r.payload };
    let html: string, text: string;
    try {
      html = render(r.template_html, values);
      text = renderText(r.template_text, values);
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
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND}`, 'content-type': 'application/json', 'Idempotency-Key': `outbox-${r.id}-${r.attempts}` },
      body: JSON.stringify({ from: fromHeader(r.from_address), to: [r.to_address], reply_to: r.reply_to || undefined, subject: r.subject, html, text,
        headers: Object.keys(headers).length ? headers : undefined, attachments: files.length ? files : undefined })
    });
    if (!res.ok) {
      const body = (await res.text()).slice(0, 500);
      const h = held(res.status, body);
      if (h) { await defer(r, h); return h; }
      // 4xx other than rate limiting will not get better on a retry
      throw Object.assign(new Error(`Resend ${res.status}: ${body}`), { permanent: res.status >= 400 && res.status < 500 && res.status !== 429 });
    }
    const { id } = (await res.json()) as { id: string };
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
  const rows = (await sql`select * from app.outbox_claim(${BATCH})`) as unknown as Row[];
  let sent = 0, failed = 0, deferred = 0;
  let stop: Held | null = null;
  for (const r of rows) {
    // after a quota refusal nothing more can go today: the rest of the batch waits too, attempts untouched
    if (stop) { await defer(r, stop); deferred++; continue; }
    const t0 = Date.now();
    const out = await sendOne(r);
    if (out instanceof Held) { deferred++; if (out.until === 'midnight') stop = out; }
    else if (out === 'sent') sent++; else failed++;
    // Resend allows 2 requests a second per account
    const wait = 550 - (Date.now() - t0);
    if (wait > 0) await pause(wait);
  }
  return Response.json({ claimed: rows.length, sent, failed, deferred });
});
