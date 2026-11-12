// r41 (migration 2570, docs/changes/2026-11-12-r41-ses.md): Amazon SES as the first email provider of the send-outbox
// Edge Function. Pure and dependency free (Web Crypto only, no AWS SDK): the Edge Function imports this file (copied
// next to it at deploy time as ses.ts, scripts/deploy/supabase.sh) and the unit tests read it.
//   - sigV4: AWS Signature Version 4, written by hand (checked against AWS's published test vectors)
//   - mimeMessage: the raw MIME email (HTML and text, Reply-To, List-Unsubscribe and List-Unsubscribe-Post, attachments);
//     SES v2's Simple content cannot carry every header we need, so the email goes as Raw content
//   - sesSend: SES v2 SendEmail (POST /v2/email/outbound-emails), its message id or a classified error
//   - emailProviderOrder: which provider the sender tries first
// SES is paid per use (about USD 0.10 per 1,000 emails): the owner approved it as the main sender (2026-11-12), the one
// exception to "never a paid send", held at the Program setting email_ses_daily_max a day.

const enc = new TextEncoder();
type Bytes = Uint8Array<ArrayBuffer>;
const hex = (b: ArrayBuffer | Uint8Array) => Array.from(b instanceof Uint8Array ? b : new Uint8Array(b), (x) => x.toString(16).padStart(2, '0')).join('');
export async function sha256Hex(data: string | Bytes): Promise<string> {
  return hex(await crypto.subtle.digest('SHA-256', typeof data === 'string' ? enc.encode(data) : data));
}
async function hmac(key: Bytes, data: string): Promise<Bytes> {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(data)));
}
// the signing key of a day, region and service (AWS docs, "Derive a signing key")
export async function signingKey(secret: string, date: string, region: string, service: string): Promise<Bytes> {
  const kDate = await hmac(enc.encode('AWS4' + secret), date);
  const kRegion = await hmac(kDate, region);
  const kService = await hmac(kRegion, service);
  return hmac(kService, 'aws4_request');
}
export const signingKeyHex = async (secret: string, date: string, region: string, service: string) => hex(await signingKey(secret, date, region, service));

// RFC 3986 encoding as SigV4 wants it (every character but A-Z a-z 0-9 - _ . ~)
const uriEncode = (s: string) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());

export interface SignInput {
  method: string; url: string; region: string; service: string; accessKeyId: string; secretAccessKey: string;
  sessionToken?: string; headers?: Record<string, string>; body?: string; amzDate?: string;
}
// The request's headers with x-amz-date and Authorization added (and x-amz-security-token with temporary keys).
// amzDate (YYYYMMDDTHHMMSSZ) is for the tests; it is now by default.
export async function sigV4(i: SignInput): Promise<Record<string, string>> {
  const u = new URL(i.url);
  const amzDate = i.amzDate ?? new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  const date = amzDate.slice(0, 8);
  const headers: Record<string, string> = {};
  for (const [k, v] of Object.entries(i.headers ?? {})) headers[k.toLowerCase()] = v;
  headers.host = u.host;
  headers['x-amz-date'] = amzDate;
  if (i.sessionToken) headers['x-amz-security-token'] = i.sessionToken;
  const names = Object.keys(headers).sort();
  const canonHeaders = names.map((n) => `${n}:${(headers[n] ?? '').trim().replace(/\s+/g, ' ')}\n`).join('');
  const signed = names.join(';');
  const path = u.pathname.split('/').map((s) => uriEncode(decodeURIComponent(s))).join('/') || '/';
  const query = [...u.searchParams.entries()].map(([k, v]): [string, string] => [uriEncode(k), uriEncode(v)]).sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : 1) : a[0] < b[0] ? -1 : 1))
    .map(([k, v]) => `${k}=${v}`).join('&');
  const canonical = [i.method.toUpperCase(), path, query, canonHeaders, signed, await sha256Hex(i.body ?? '')].join('\n');
  const scope = `${date}/${i.region}/${i.service}/aws4_request`;
  const toSign = ['AWS4-HMAC-SHA256', amzDate, scope, await sha256Hex(canonical)].join('\n');
  const signature = hex(await hmac(await signingKey(i.secretAccessKey, date, i.region, i.service), toSign));
  const out: Record<string, string> = { ...(i.headers ?? {}), 'x-amz-date': amzDate };
  if (i.sessionToken) out['x-amz-security-token'] = i.sessionToken;
  out.authorization = `AWS4-HMAC-SHA256 Credential=${i.accessKeyId}/${scope}, SignedHeaders=${signed}, Signature=${signature}`;
  return out;
}

// ---------------------------------------------------------------- the raw MIME email
export interface SesMail {
  from: string; to: string; reply_to?: string; subject: string; html: string; text: string; headers?: Record<string, string>;
  attachments?: Array<{ filename: string; content: string; content_type: string }>;
}
const b64utf8 = (s: string) => { const b = enc.encode(s); let o = ''; for (let i = 0; i < b.length; i += 0x8000) o += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(o); };
const wrap76 = (s: string) => s.replace(/.{1,76}/g, '$&\r\n');
// RFC 2047 for a header with characters outside ASCII
const word = (s: string) => (/^[\x20-\x7e]*$/.test(s) ? s : `=?UTF-8?B?${b64utf8(s)}?=`);
// "Name <a@b>": the name encoded when it needs it, the address as is
const addr = (s: string) => { const m = /^\s*"?([^"<]*?)"?\s*<([^>]+)>\s*$/.exec(s); return m ? (m[1] ? `${/^[\w .-]*$/.test(m[1]) ? m[1] : word(m[1])} <${m[2]}>` : `<${m[2]}>`) : s.trim(); };
const noBreak = (s: string) => s.replace(/[\r\n]+/g, ' ');

export function mimeMessage(m: SesMail, opts: { boundary?: string; date?: Date } = {}): string {
  const bnd = opts.boundary ?? `cc${crypto.randomUUID().replace(/-/g, '')}`;
  const head = [
    `From: ${addr(noBreak(m.from))}`, `To: ${addr(noBreak(m.to))}`,
    ...(m.reply_to ? [`Reply-To: ${addr(noBreak(m.reply_to))}`] : []),
    `Subject: ${word(noBreak(m.subject))}`, `Date: ${(opts.date ?? new Date()).toUTCString()}`, 'MIME-Version: 1.0',
    ...Object.entries(m.headers ?? {}).filter(([k]) => /^[A-Za-z0-9-]+$/.test(k)).map(([k, v]) => `${k}: ${noBreak(v)}`)
  ];
  const part = (type: string, body: string) => `Content-Type: ${type}; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n${wrap76(b64utf8(body))}`;
  const alt = `--${bnd}a\r\n${part('text/plain', m.text)}--${bnd}a\r\n${part('text/html', m.html)}--${bnd}a--\r\n`;
  const files = m.attachments ?? [];
  if (!files.length) return `${head.join('\r\n')}\r\nContent-Type: multipart/alternative; boundary="${bnd}a"\r\n\r\n${alt}`;
  const att = files.map((f) => {
    const name = word(noBreak(f.filename).replace(/"/g, ''));
    return `--${bnd}m\r\nContent-Type: ${f.content_type}; name="${name}"\r\nContent-Disposition: attachment; filename="${name}"\r\nContent-Transfer-Encoding: base64\r\n\r\n${wrap76(f.content.replace(/\s+/g, ''))}`;
  }).join('');
  return `${head.join('\r\n')}\r\nContent-Type: multipart/mixed; boundary="${bnd}m"\r\n\r\n--${bnd}m\r\nContent-Type: multipart/alternative; boundary="${bnd}a"\r\n\r\n${alt}${att}--${bnd}m--\r\n`;
}

// ---------------------------------------------------------------- SES v2 SendEmail
export interface SesConfig { accessKeyId: string; secretAccessKey: string; region: string; configurationSet?: string }
export function sesConfig(env: (k: string) => string | undefined): SesConfig | null {
  const accessKeyId = (env('AWS_SES_ACCESS_KEY_ID') ?? '').trim(), secretAccessKey = (env('AWS_SES_SECRET_ACCESS_KEY') ?? '').trim();
  if (!accessKeyId || !secretAccessKey) return null;
  return { accessKeyId, secretAccessKey, region: (env('AWS_SES_REGION') ?? '').trim() || 'ca-central-1', configurationSet: (env('AWS_SES_CONFIGURATION_SET') ?? '').trim() || undefined };
}

// What an SES refusal means for this email:
//   throttle  SES's sending rate: the email waits a minute and goes again (attempts untouched)
//   email     this email only (MessageRejected, e.g. a recipient the sandbox has not verified): the next provider sends it
//   account   SES cannot send now (bad keys, sending paused, the account's daily quota, the sender's domain not verified,
//             an outage): the next provider sends it, and SES rests 15 minutes (the database records it)
export type SesKind = 'throttle' | 'email' | 'account';
export function classifySesError(status: number, type: string, message: string): SesKind {
  const t = `${type} ${message}`;
  if (status === 429 || /TooManyRequests|Throttl|Maximum sending rate/i.test(t)) return 'throttle';
  if (/MessageRejected/i.test(type) && !/AccountSuspend|SendingPaused/i.test(t)) return 'email';
  return 'account';
}

export type SesResult = { id: string } | { error: string; kind: SesKind };
export async function sesSend(c: SesConfig, m: SesMail, fetcher: typeof fetch = fetch): Promise<SesResult> {
  const url = `https://email.${c.region}.amazonaws.com/v2/email/outbound-emails`;
  const body = JSON.stringify({
    Content: { Raw: { Data: b64utf8(mimeMessage(m)) } },
    // the envelope: the To and From of the MIME message (Reply-To is in it too)
    FromEmailAddress: m.from, Destination: { ToAddresses: [m.to] },
    ...(c.configurationSet ? { ConfigurationSetName: c.configurationSet } : {})
  });
  try {
    const headers = await sigV4({ method: 'POST', url, region: c.region, service: 'ses', accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey,
      headers: { 'content-type': 'application/json' }, body });
    const res = await fetcher(url, { method: 'POST', headers, body, signal: AbortSignal.timeout(20_000) });
    const j = (await res.json().catch(() => ({}))) as { MessageId?: string; message?: string; Message?: string; __type?: string };
    if (res.ok && j.MessageId) return { id: j.MessageId };
    const type = ((res.headers.get('x-amzn-errortype') ?? j.__type ?? '').split(':')[0] ?? '').split('#').pop() ?? '';
    const msg = (j.message ?? j.Message ?? '').slice(0, 250);
    return { error: `SES ${res.status} ${type}: ${msg}`.slice(0, 300), kind: classifySesError(res.status, type, msg) };
  } catch (e) {
    return { error: `SES: ${(e as Error).message}`.slice(0, 300), kind: 'account' };
  }
}

// ---------------------------------------------------------------- which emails SES may send
// SES production access is requested for transactional email, and AWS's terms want recipients who asked for the email:
// marketing (category 'marketing', the campaigns of 2520 included) never goes through SES unless the Program setting
// email_ses_marketing is on (off by default). Booking, payment, sign-in, staff and owner email may.
export const sesMaySend = (category: string, sesMarketing: boolean) => category !== 'marketing' || sesMarketing;

// ---------------------------------------------------------------- which provider first
// 2600 (the owner, 2026-11-12): booking and system email (every category but marketing) goes through SES first when its
// keys are set, the Program setting email_ses_enabled is on, today's SES count is under email_ses_daily_max and it is not
// resting after an account-level refusal; when SES cannot or refuses, Resend's free plan sends it. Cloudflare only when the
// Program setting email_cloudflare_enabled is on (cfOn/cfLeft are 0 otherwise) and never for marketing. Marketing: Resend's
// free plan only (SES only with email_ses_marketing). An empty list: nothing may send now (the email is held as before).
export type Provider = 'ses' | 'cf' | 'resend';
// With a category, SES only for the emails it may send (sesMaySend).
export function emailProviderOrder(s: { sesConfigured: boolean; sesEnabled: boolean; sesLeft: number; sesResting?: boolean; cfOn: boolean; cfLeft: number; resendLeft: number;
  category?: string; sesMarketing?: boolean }): Provider[] {
  const out: Provider[] = [];
  if (s.sesConfigured && s.sesEnabled && s.sesLeft > 0 && !s.sesResting && (s.category === undefined || sesMaySend(s.category, s.sesMarketing === true))) out.push('ses');
  if (s.cfOn && s.cfLeft > 0 && s.category !== 'marketing') out.push('cf');
  if (s.resendLeft > 0) out.push('resend');
  return out;
}
