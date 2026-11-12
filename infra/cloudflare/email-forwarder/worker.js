// Release 42: inbound email on Cloudflare's FREE plan (docs/hosting/off-cloudflare.md, section 2.5).
// Email Routing (free) hands every message sent to in.carmacars.ca to this Email Worker, which forwards the raw message
// over HTTPS to the website on the company's server (POST /api/inbound/email, web/scripts/vps-server.mjs). The server
// runs what the website Worker's email() ran: the Turo reader and the automatic answers.
//   - signed: x-cc-signature: t=<unix seconds>,v1=<HMAC-SHA256 of "t\nfrom\nto\nraw" with INBOUND_EMAIL_SECRET>
//     (web/src/lib/platform/inbound-email.ts checks it; the secret is derived from the site's signing key by the deploy);
//   - a message above 1 MB is refused; when the server cannot take a message this Worker throws, so the sending mail
//     server tries again later (nothing is lost while the site restarts);
//   - an automatic answer comes back as a finished message and is sent with message.reply (inside Cloudflare, free).
// Free plan limits that apply: 100,000 Worker requests a day for the account and 10 ms of CPU time per message (the
// work here is one HMAC and one request; waiting for the server does not count as CPU time). Email Routing has no
// message quota. Nothing here needs Workers Paid.
import { EmailMessage } from 'cloudflare:email';

const MAX_EMAIL_BYTES = 1_000_000;

async function hmacHex(secret, data) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(data)));
  return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

export default {
  async email(message, env) {
    // not set up yet: a temporary failure (the sender retries), never a bounce
    if (!env.INBOUND_EMAIL_SECRET || !env.INBOUND_URL) throw new Error('inbound email: the forwarder has no secret or address yet');
    if (message.rawSize > MAX_EMAIL_BYTES) { message.setReject('Message too large'); return; }
    const raw = await new Response(message.raw).text();
    const t = Math.floor(Date.now() / 1000);
    const signature = `t=${t},v1=${await hmacHex(env.INBOUND_EMAIL_SECRET, `${t}\n${message.from}\n${message.to}\n${raw}`)}`;
    const r = await fetch(env.INBOUND_URL, {
      method: 'POST', body: raw, signal: AbortSignal.timeout(120_000),
      headers: { 'content-type': 'message/rfc822', 'x-envelope-from': message.from, 'x-envelope-to': message.to, 'x-cc-signature': signature, 'user-agent': 'CarmaCars email forwarder' }
    });
    if (r.status === 413) { message.setReject('Message too large'); return; }
    if (!r.ok) throw new Error(`inbound email: the site answered ${r.status}`);
    const j = await r.json().catch(() => null);
    if (j && typeof j.reply_raw === 'string' && j.reply_raw) {
      try { await message.reply(new EmailMessage(message.to, message.from, j.reply_raw)); }
      catch (e) { console.warn(`inbound email: the automatic answer was not sent (${e instanceof Error ? e.message.slice(0, 120) : 'error'})`); }
    }
  },
  // no web address of its own
  async fetch() { return new Response('Not found', { status: 404 }); }
};
