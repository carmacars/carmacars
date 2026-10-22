import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { env } from '@/lib/env';
import { phoneLine } from '@/integrations/phone';
import { hookError, parseSmsHook, smsCodeText, verifyHookSignature } from '@/features/auth/sms-hook';

// Sign-in codes by text (migration 0091). Supabase Auth makes the code and calls our Send SMS hook
// (/api/webhooks/auth-sms); the local stand-in (src/lib/auth/local.ts) calls deliverSignInCode directly. Either way the
// database decides whether the number may get a code (Canada; the US only when an Admin allows it; our site asked for
// it in the last minutes; the per-number limit) and keeps a log without the code, and the text goes out through the
// Quo line from the CarmaCars number (the fake line locally and in tests).
const SR = { role: 'service_role' as const };

/** The local stand-in's hook secret (the unit and end-to-end tests sign with it). Never used in production. */
export const LOCAL_SMS_HOOK_SECRET = 'v1,whsec_' + 'Y2FybWFjYXJzLWxvY2FsLXNtcy1ob29rLXNlY3JldA==';
export function smsHookSecrets(): string[] {
  const e = env();
  if (e.AUTH_SMS_HOOK_SECRET) return e.AUTH_SMS_HOOK_SECRET.split(/[\s|]+/).filter(Boolean);
  return e.APP_ENV !== 'production' && e.QUO_PROVIDER === 'fake' ? [LOCAL_SMS_HOOK_SECRET] : [];
}

const REFUSED: Record<string, string> = {
  country: 'Sign-in codes are texted to Canadian mobile numbers only.',
  invalid: 'Not a mobile number.',
  off: 'Sign-in by phone is switched off.',
  rate_limited: 'Too many codes for this number. Wait an hour.',
  no_request: 'No sign-in code was asked for this number on the site.',
  no_from_number: 'The CarmaCars number is not set (Site settings, Phone).'
};

export type Delivered = { ok: true; phone: string } | { ok: false; reason: string; message: string };

/** Texts a sign-in code. phones: the numbers it may be for (the hook's candidates), most likely first. */
export async function deliverSignInCode(p: { phones: string[]; code: string; userId: string | null }): Promise<Delivered> {
  const chk = (await rpc('server_auth_sms', { p: { phones: p.phones, user_id: p.userId } as unknown as Json }, SR)) as unknown as
    { ok: boolean; reason?: string; phone?: string; log_id?: string; from?: string };
  if (!chk.ok || !chk.phone || !chk.log_id || !chk.from) {
    const reason = chk.reason ?? 'refused';
    return { ok: false, reason, message: REFUSED[reason] ?? 'The code was not sent.' };
  }
  const res = await phoneLine().sendText({ from: chk.from, to: chk.phone, body: smsCodeText(p.code) });
  await rpc('server_auth_sms_result', { p: { log_id: chk.log_id, ok: res.ok, quo_id: res.id, error: res.error ?? null } as unknown as Json }, SR);
  return res.ok ? { ok: true, phone: chk.phone } : { ok: false, reason: 'send_failed', message: `The text could not be sent: ${res.error ?? 'Quo refused it'}` };
}

export interface HookResult { status: number; body: Record<string, unknown> }

/** One call of Supabase's Send SMS hook: verified on the raw body, then texted. A failure is answered with the hook's
 *  error shape, so Supabase reports it to the person asking (and sends nothing itself). */
export async function handleSmsHook(raw: string, header: (n: string) => string | null): Promise<HookResult> {
  const v = await verifyHookSignature(raw, header, smsHookSecrets());
  if (!v.ok) return hookError(401, 'invalid signature');
  let body: unknown;
  try { body = JSON.parse(raw); } catch { return hookError(400, 'not JSON'); }
  const call = parseSmsHook(body);
  if (!call) return hookError(400, 'not a Send SMS hook call');
  const r = await deliverSignInCode({ phones: call.phones, code: call.otp, userId: call.userId });
  if (r.ok) return { status: 200, body: {} };
  // refused by our rules: 4xx (Supabase shows it as a client error); Quo failing: 502
  return hookError(r.reason === 'send_failed' || r.reason === 'no_from_number' ? 502 : r.reason === 'rate_limited' ? 429 : 403, r.message);
}
