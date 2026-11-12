// Release 42: inbound email without Workers Paid (docs/hosting/off-cloudflare.md, section 2.5). Cloudflare Email Routing
// (free) hands each message sent to in.carmacars.ca to a small Email Worker on the free plan
// (infra/cloudflare/email-forwarder), which POSTs the raw message to /api/inbound/email on the company's server, signed
// with a shared secret. The Node entry (scripts/vps-server.mjs) checks the signature here and then does exactly what the
// Worker entry's email() does (custom-worker.ts): an inbox with automatic answers goes to /api/inbound/ask first, and
// anything else, or an address that is not such an inbox, to the Turo reader /api/inbound/turo.
// The secret is derived from LINK_SIGNING_KEY with a fixed label, so the forwarder never holds the key itself and the
// owner has no new secret to create. No imports: this runs in the Node entry, in the app and in the unit test.

export const INBOUND_PATH = '/api/inbound/email';
export const SIGNATURE_HEADER = 'x-cc-signature';
export const INBOUND_LABEL = 'carmacars-inbound-email-v1';
export const MAX_INBOUND_BYTES = 1_000_000;
/** A signature older or newer than this is refused (a captured request cannot be sent again later). */
export const MAX_SKEW_S = 300;

async function hmacHex(secret: string, data: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(data)));
  return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** The forwarder's secret: HMAC of a fixed label with LINK_SIGNING_KEY (the deploy gives the Worker this value only). */
export function inboundSecret(linkSigningKey: string): Promise<string> {
  return hmacHex(linkSigningKey, INBOUND_LABEL);
}

/** What is signed: the time, the envelope and the whole message, so none of them can be changed on the way. */
const signed = (t: number, from: string, to: string, raw: string) => `${t}\n${from}\n${to}\n${raw}`;

/** The header the forwarder sends: `t=<unix seconds>,v1=<hex HMAC-SHA256>`. */
export async function signInbound(secret: string, t: number, from: string, to: string, raw: string): Promise<string> {
  return `t=${t},v1=${await hmacHex(secret, signed(t, from, to, raw))}`;
}

/** True when the header was made with the secret for exactly this message, within MAX_SKEW_S of now. Constant time. */
export async function verifyInbound(secret: string, header: string | null | undefined, from: string, to: string, raw: string, nowS: number): Promise<boolean> {
  const m = /^t=(\d{9,11}),v1=([0-9a-f]{64})$/.exec((header ?? '').trim());
  if (!secret || !m) return false;
  const t = Number(m[1]);
  if (Math.abs(nowS - t) > MAX_SKEW_S) return false;
  const want = await hmacHex(secret, signed(t, from, to, raw));
  const got = m[2]!;
  let d = 0;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ got.charCodeAt(i);
  return d === 0;
}

export interface InboundMessage { from: string; to: string; raw: string }
export interface InboundReply { subject: string; text: string; in_reply_to: string | null }
/** Posts the raw message to one of the app's inbound routes (with the jobs' token) and gives its status and JSON. */
export type InboundPost = (path: '/api/inbound/ask' | '/api/inbound/turo', m: InboundMessage) => Promise<{ status: number; json: unknown }>;
/** 200: taken (with the automatic answer to send back, when there is one). 413: too large, refuse it. 502: the app could
 *  not take it, so the forwarder fails and the sender tries again. */
export interface InboundResult { status: 200 | 413 | 502; reply: InboundReply | null }

/** The Worker entry's email() as a function: the same two routes in the same order with the same outcomes. */
export async function routeInbound(m: InboundMessage, post: InboundPost): Promise<InboundResult> {
  if (m.raw.length > MAX_INBOUND_BYTES) return { status: 413, reply: null };
  if (!/^trips@/i.test(m.to)) {
    const a = await post('/api/inbound/ask', m);
    if (a.status !== 404) {
      const r = (a.json as { reply?: InboundReply } | null)?.reply;
      return { status: 200, reply: r && typeof r.subject === 'string' && typeof r.text === 'string' ? { subject: r.subject, text: r.text, in_reply_to: r.in_reply_to ?? null } : null };
    }
  }
  const r = await post('/api/inbound/turo', m);
  if (r.status === 413) return { status: 413, reply: null };
  return { status: r.status >= 200 && r.status < 300 ? 200 : 502, reply: null };
}
