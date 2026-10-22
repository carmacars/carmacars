// Supabase Auth's Send SMS hook (migration 0091): the signature check and the payload reader. No imports, so it runs
// in the Worker, in Node and in the unit tests (sms-hook.test.ts).
//
// Supabase signs each hook call the Standard Webhooks way: headers webhook-id, webhook-timestamp (Unix seconds) and
// webhook-signature ("v1,<base64>" entries, space separated); HMAC-SHA256 over "<id>.<timestamp>.<raw body>" with the
// secret, which the project holds as "v1,whsec_<base64>" (the part after "whsec_" is base64-decoded into the key).
// It fails closed: no secret, no header, a timestamp more than 5 minutes off or no matching signature is refused.
//
// Body: { user: { id, phone, ... }, sms: { otp: "123456" } }. Answer: 200 with {} when the text was sent; otherwise a
// non-2xx status with { error: { http_code, message } }, which Supabase reports to the sign-in request.

export const HOOK_TOLERANCE_SECONDS = 300;
/** The text, as the project's sms_template says it (scripts/deploy/supabase.sh phoneauth). */
export const SMS_TEMPLATE = "CarmaCars code: {{ .Code }}. It expires in 5 minutes. Don't share it.";
export const smsCodeText = (code: string) => SMS_TEMPLATE.replace('{{ .Code }}', code);

const enc = new TextEncoder();
function b64ToBytes(b64: string): Uint8Array {
  const s = atob(b64.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, ''));
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}
function bytesToB64(b: Uint8Array): string {
  let s = '';
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s);
}
function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function hmac(key: Uint8Array, data: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', key as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return bytesToB64(new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(data))));
}
/** "v1,whsec_abc=", "whsec_abc=" or "abc=" to the key bytes. */
export function hookKey(secret: string): Uint8Array | null {
  const s = secret.trim().replace(/^v1,/, '').replace(/^whsec_/, '');
  if (!s) return null;
  try { const b = b64ToBytes(s); return b.length ? b : null; } catch { return null; }
}

export type HeaderGet = (name: string) => string | null | undefined;
export interface HookVerified { ok: boolean; id?: string; reason?: string }

/** Checks a hook call against one or more secrets ("v1,whsec_a v1,whsec_b": a new secret beside the old one). */
export async function verifyHookSignature(raw: string, header: HeaderGet, secrets: string | Array<string | null | undefined> | null | undefined,
  nowSeconds = Math.floor(Date.now() / 1000)): Promise<HookVerified> {
  const list = (Array.isArray(secrets) ? secrets : String(secrets ?? '').split(/[\s|]+/)).filter((s): s is string => !!s && !!s.trim());
  const keys = list.map(hookKey).filter((k): k is Uint8Array => !!k);
  if (!keys.length) return { ok: false, reason: 'no secret' };
  const id = header('webhook-id'), ts = header('webhook-timestamp'), sig = header('webhook-signature');
  if (!id || !ts || !sig) return { ok: false, reason: 'no signature header' };
  const t = Number(ts);
  if (!Number.isFinite(t) || Math.abs(nowSeconds - t) > HOOK_TOLERANCE_SECONDS) return { ok: false, reason: 'timestamp' };
  const given = sig.split(' ').map((e) => e.split(',')).filter(([v, s]) => v === 'v1' && !!s).map(([, s]) => s!);
  for (const k of keys) {
    const want = await hmac(k, `${id}.${ts}.${raw}`);
    if (given.some((g) => sameText(g, want))) return { ok: true, id };
  }
  return { ok: false, reason: 'signature' };
}

/** Signs a body the way Supabase does (the unit tests and the local stand-in). */
export async function signHook(raw: string, secret: string, id: string, ts = Math.floor(Date.now() / 1000)): Promise<Record<string, string>> {
  const k = hookKey(secret);
  if (!k) throw new Error('bad secret');
  return { 'webhook-id': id, 'webhook-timestamp': String(ts), 'webhook-signature': `v1,${await hmac(k, `${id}.${ts}.${raw}`)}` };
}

export interface SmsHookCall { userId: string | null; phones: string[]; otp: string; type: string | null }
const plus = (p: string) => (p.startsWith('+') ? p : `+${p}`);
/** The fields we use, or null when the body is not a Send SMS hook call. phones: the numbers the code may be for, most
 *  likely first: a phone change texts the new number (user.new_phone), a sign-in the account's number (user.phone).
 *  The database picks the one our site asked a code for in the last minutes (app.server_auth_sms). */
export function parseSmsHook(body: unknown): SmsHookCall | null {
  if (!body || typeof body !== 'object') return null;
  const b = body as { user?: { id?: unknown; phone?: unknown; new_phone?: unknown }; sms?: { otp?: unknown; phone?: unknown; sms_type?: unknown; type?: unknown } };
  const otp = typeof b.sms?.otp === 'string' ? b.sms.otp : null;
  const type = typeof b.sms?.sms_type === 'string' ? b.sms.sms_type : typeof b.sms?.type === 'string' ? b.sms.type : null;
  const ok = (p: unknown): p is string => typeof p === 'string' && p.replace(/\D/g, '').length >= 8;
  const order = type === 'phone_change' ? [b.sms?.phone, b.user?.new_phone, b.user?.phone] : type ? [b.sms?.phone, b.user?.phone, b.user?.new_phone] : [b.sms?.phone, b.user?.new_phone, b.user?.phone];
  const phones = [...new Set(order.filter(ok).map(plus))];
  if (!otp || !/^\d{4,10}$/.test(otp) || !phones.length) return null;
  return { userId: typeof b.user?.id === 'string' ? b.user.id : null, phones, otp, type };
}

export const hookError = (status: number, message: string) => ({ status, body: { error: { http_code: status, message } } });
