// send-outbox: the email sender (docs/architecture.md section 5, docs/changes/0018_notifications.md).
// Called every minute by pg_cron through pg_net (job `carmacars-send-outbox`, scheduled by the CI deploy
// job) with `Authorization: Bearer <OUTBOX_JOB_TOKEN>`; any other caller gets 403. It claims a batch with
// app.outbox_claim() (daily and monthly caps, priorities), renders each row with emails/src/engine.mjs
// (copied next to this file at deploy time as engine.mjs), sends it through Resend and reports back with
// app.outbox_mark_sent() or app.outbox_mark_failed().
//
// Secrets (Edge Function secrets, set by the deploy job): OUTBOX_JOB_TOKEN, RESEND_API_KEY, APP_URL.
// SUPABASE_DB_URL is provided by Supabase.
import postgres from 'npm:postgres@3.4.5';
import { render, renderText } from './engine.mjs';

const TOKEN = Deno.env.get('OUTBOX_JOB_TOKEN') ?? '';
const RESEND = Deno.env.get('RESEND_API_KEY') ?? '';
const APP_URL = (Deno.env.get('APP_URL') ?? 'https://carmacars.ca').replace(/\/$/, '');
const BATCH = 20;

const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false, idle_timeout: 20, onnotice: () => {} });

interface Row {
  id: string; code: string; category: string; to_address: string; to_name: string | null; from_address: string | null;
  reply_to: string | null; subject: string; payload: Record<string, unknown>; attempts: number; unsubscribe_url: string | null;
  template_html: string | null; template_text: string | null;
}

// The values only a sender can produce (catalogue `sender_supplied`). Signed 7-day file links and
// sign-in service links are not issued here yet: the email links to the portal page that holds the
// file (behind sign-in) or to the sign-in pages instead. A value already in the payload always wins.
function senderValues(r: Row): Record<string, unknown> {
  const portal = r.code.startsWith('owner_') ? `${APP_URL}/owner` : r.code.startsWith('investor_') ? `${APP_URL}/sign-in` : `${APP_URL}/account`;
  return {
    link_expiry: '7 days',
    verify_url: `${APP_URL}/sign-in`, sign_in_url: `${APP_URL}/sign-in`, reset_url: `${APP_URL}/reset-password`,
    signed_agreement_url: portal, receipt_url: portal, statement_url: portal, supporting_document_url: portal,
    security_device: 'Not recorded', security_event: 'Account change', security_event_at: 'Recently', security_place: 'Not recorded'
  };
}

const fromHeader = (a: string | null) => {
  const addr = a || 'hello@carmacars.ca';
  return addr.includes('<') ? addr : `CarmaCars <${addr}>`;
};

async function sendOne(r: Row): Promise<'sent' | 'failed'> {
  try {
    if (!r.template_html || !r.template_text) throw Object.assign(new Error('The catalogue has no template for ' + r.code), { permanent: true });
    const values = { ...senderValues(r), ...r.payload };
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
      headers['List-Unsubscribe'] = `<${r.unsubscribe_url}>`;
      headers['List-Unsubscribe-Post'] = 'List-Unsubscribe=One-Click';
    }
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND}`, 'content-type': 'application/json', 'Idempotency-Key': `outbox-${r.id}-${r.attempts}` },
      body: JSON.stringify({ from: fromHeader(r.from_address), to: [r.to_address], reply_to: r.reply_to || undefined, subject: r.subject, html, text,
        headers: Object.keys(headers).length ? headers : undefined })
    });
    if (!res.ok) {
      const body = (await res.text()).slice(0, 500);
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
  let sent = 0, failed = 0;
  for (const r of rows) (await sendOne(r)) === 'sent' ? sent++ : failed++;
  return Response.json({ claimed: rows.length, sent, failed });
});
