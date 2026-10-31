'use server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { env } from '@/lib/env';
import { phoneLine } from '@/integrations/phone';
import { ipKey } from '@/lib/track/shared';
import type { ActionResult } from '@/features/forms/schemas';
import { cleanCode, formatPhone } from '@/features/auth/phone';
import { DEALS_TEXT, gateNumber, type GateKind } from '@/features/phone-gate/rules';
import { requestMeta } from '@/server/request';
import { visitorCookie } from '@/server/capture';
import { realUser } from '@/server/portal/data';
import { sha256Hex } from '@/server/links';

// The phone number box (migration 0280). Called only when a visitor taps something the box guards, never for a page
// view: whether a signed-in renter has a verified mobile (then no box), a code by text (only with the code setting on;
// the database counts the texts per number, network address and site a day), and the number given.
const SR = { role: 'service_role' as const };
type R<T = null> = ActionResult<T>;
const KINDS: readonly GateKind[] = ['gallery', 'dates', 'request'];
const kindOf = (k: unknown): GateKind => (KINDS as readonly unknown[]).includes(k) ? (k as GateKind) : 'dates';
const salt = () => (env().SUPABASE_SERVICE_ROLE_KEY ?? 'local').slice(-24);
const codeHash = (phone: string, vid: string, code: string) => sha256Hex(new TextEncoder().encode(`phone-gate:${phone}:${vid}:${code}`));
const fakeLocal = () => env().DATA_BACKEND === 'local' && env().QUO_PROVIDER === 'fake' && env().APP_ENV !== 'production';

const REASON: Record<string, string> = {
  rate_limited: 'Too many tries for now. Wait a while and try again.',
  no_us_texts: 'We cannot text US numbers yet. Continue without the code.',
  no_from_number: 'Texts are not set up right now. Try again later.',
  code: 'That code does not match or has expired. Check the newest text, or ask for a new code.',
  code_needed: 'Enter the code we texted you.',
  off: 'Codes are not used right now. Continue.',
  visitor: 'Reload the page and try again.'
};

/** Signed in with a verified mobile: no box. */
export async function phoneGateStatus(): Promise<R<{ pass: boolean; phone: string | null }>> {
  const user = await realUser().catch(() => null);
  if (!user) return { ok: true, data: { pass: false, phone: null } };
  const si = (await rpc('server_my_sign_in', { p_user: user.id }, SR).catch(() => null)) as unknown as { phone: string | null; phone_verified?: boolean } | null;
  return { ok: true, data: { pass: !!si?.phone_verified && !!si.phone, phone: si?.phone ?? null } };
}

/** Texts a 6-digit code (the code setting on). */
export async function phoneGateSendCode(input: { phone: string; gate: GateKind }): Promise<R<{ phone: string; display: string; noTexts?: boolean }>> {
  const n = gateNumber(input.phone);
  if (!n.ok) return { ok: false, code: 'invalid', message: n.message, fieldErrors: { phone: n.message } };
  const vid = await visitorCookie();
  if (!vid) return { ok: false, code: 'visitor', message: REASON.visitor! };
  const code = String(crypto.getRandomValues(new Uint32Array(1))[0]! % 1_000_000).padStart(6, '0');
  const meta = await requestMeta();
  const r = (await rpc('server_phone_gate_code', { p: { phone: n.phone, visitor_id: vid, gate: kindOf(input.gate), ip_key: await ipKey(meta.ip, salt()).catch(() => null), code_hash: await codeHash(n.phone, vid, code) } as unknown as Json }, SR)) as unknown as
    { ok: boolean; reason?: string; phone?: string; from?: string; log_id?: string };
  if (!r.ok) {
    if (r.reason === 'no_us_texts') return { ok: true, data: { phone: n.phone, display: formatPhone(n.phone), noTexts: true } };
    if (r.reason === 'invalid' || r.reason === 'country') { const m = 'Enter a Canadian or US mobile number.'; return { ok: false, code: 'invalid', message: m, fieldErrors: { phone: m } }; }
    return { ok: false, code: r.reason ?? 'refused', message: REASON[r.reason ?? ''] ?? 'We could not text a code. Try again later.' };
  }
  const body = `CarmaCars code: ${code}. It expires in 10 minutes. Don't share it.`;
  const res = await phoneLine().sendText({ from: r.from!, to: r.phone!, body });
  await rpc('server_auth_sms_result', { p: { log_id: r.log_id, ok: res.ok, quo_id: res.id, error: res.error ?? null } as unknown as Json }, SR).catch(() => undefined);
  if (!res.ok) return { ok: false, code: 'send_failed', message: 'The text could not be sent. Try again in a moment.' };
  if (fakeLocal()) {
    // locally (the fake text line) the text is kept in the stand-in's mailbox, where the tests read it like the sign-in codes
    const { localSql } = await import('@/lib/db/local');
    await localSql()`insert into local_auth.mailbox (to_email, to_phone, subject, body) values (null, ${r.phone!}, 'Text: phone number box code', ${body})`.catch(() => undefined);
  }
  return { ok: true, data: { phone: n.phone, display: formatPhone(n.phone) } };
}

/** The number given (with the code, when the code setting is on). */
export async function phoneGateSave(input: { phone: string; gate: GateKind; page?: string | null; marketing?: boolean; code?: string | null; unverified?: boolean }): Promise<R<{ phone: string; verified: boolean }>> {
  const n = gateNumber(input.phone);
  if (!n.ok) return { ok: false, code: 'invalid', message: n.message, fieldErrors: { phone: n.message } };
  const vid = await visitorCookie();
  if (!vid) return { ok: false, code: 'visitor', message: REASON.visitor! };
  const code = input.code ? cleanCode(input.code) : null;
  if (input.code && !code) return { ok: false, code: 'code', message: 'Enter the 6 digits from the text.', fieldErrors: { code: 'Enter the 6 digits.' } };
  const meta = await requestMeta();
  const user = await realUser().catch(() => null);
  const r = (await rpc('server_phone_gate_save', { p: {
    visitor_id: vid, phone: n.phone, gate: kindOf(input.gate), page: typeof input.page === 'string' ? input.page.slice(0, 300) : null,
    ip_key: await ipKey(meta.ip, salt()).catch(() => null), marketing: input.marketing === true, marketing_text: input.marketing === true ? DEALS_TEXT : null,
    code_hash: code ? await codeHash(n.phone, vid, code) : null, unverified: input.unverified === true, signed_in: user?.id ?? null
  } as unknown as Json }, SR)) as unknown as { ok: boolean; reason?: string; phone?: string; verified?: boolean };
  if (!r.ok) {
    const m = REASON[r.reason ?? ''] ?? (r.reason === 'invalid' || r.reason === 'country' ? 'Enter a Canadian or US mobile number.' : 'We could not save the number. Try again.');
    const field: Record<string, string> | undefined = r.reason === 'code' || r.reason === 'code_needed' ? { code: m } : r.reason === 'invalid' || r.reason === 'country' ? { phone: m } : undefined;
    return { ok: false, code: r.reason ?? 'refused', message: m, fieldErrors: field };
  }
  return { ok: true, data: { phone: r.phone ?? n.phone, verified: !!r.verified } };
}
