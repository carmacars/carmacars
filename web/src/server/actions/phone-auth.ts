'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { auth } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import { verifyTurnstile } from '@/integrations/turnstile';
import type { ActionResult } from '@/features/forms/schemas';
import { checkSignInPhone, cleanCode, formatPhone, toE164 } from '@/features/auth/phone';
import { requestMeta } from '@/server/request';
import { safeNext } from '@/server/portals';
import { afterSignIn, clearSessionCookies, rememberSignIn } from '@/server/after-sign-in';

// Sign-in by phone (migration 0091): a 6-digit code texted from the CarmaCars number (Supabase Auth's phone provider
// and its Send SMS hook; the local stand-in locally). Every answer reads the same whether or not the number has an
// account: the account of a number is made at its first verified code, and earlier records with the number are
// attached only then (app.account_phone_verified).
const SR = { role: 'service_role' as const };
type R<T = null> = ActionResult<T>;
export type PhonePurpose = 'sign_in' | 'add';
export interface PhoneRules { enabled: boolean; us_allowed: boolean; code_length: number; code_minutes: number }

async function rules(): Promise<PhoneRules> {
  return ((await rpc('signin_phone_rules', {} as never, { role: 'anon' }).catch(() => null)) as unknown as PhoneRules | null)
    ?? { enabled: false, us_allowed: false, code_length: 6, code_minutes: 5 };
}
const REASON: Record<string, string> = {
  rate_limited: 'Too many codes asked for. Wait a while, then try again, or sign in with your email.',
  off: 'Sign-in by phone is not available right now. Sign in with your email.'
};
const PROFILE_PATHS = ['/account/profile', '/owner/profile', '/va/profile', '/field/profile'];

/** Texts a code: to sign in (or sign up), or, signed in, to add a number to the account. */
export async function requestPhoneCode(input: { phone: string; purpose: PhonePurpose; turnstile?: string | null }): Promise<R<{ phone: string; display: string }>> {
  const r = await rules();
  if (!r.enabled) return { ok: false, code: 'off', message: REASON.off! };
  const c = checkSignInPhone(input.phone, r.us_allowed);
  if (!c.ok) return { ok: false, code: 'invalid', message: c.message, fieldErrors: { phone: c.message } };
  const a = await auth();
  const meta = await requestMeta();
  const user = input.purpose === 'add' ? await a.currentUser() : null;
  if (input.purpose === 'add' && !user) return { ok: false, code: 'auth', message: 'Sign in first.' };
  if (input.purpose === 'sign_in' && !(await verifyTurnstile(input.turnstile ?? null, meta.ip))) {
    return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  }
  const chk = (await rpc('server_signin_phone_request', { p: { phone: c.phone, ip: meta.ip, kind: 'code', purpose: input.purpose === 'add' ? 'phone_change' : 'sign_in', user_id: user?.id ?? null } }, SR)) as unknown as { ok: boolean; reason?: string; phone?: string };
  if (!chk.ok) {
    if (chk.reason === 'country' || chk.reason === 'invalid') { const m = checkSignInPhone(input.phone, false); const msg = m.ok ? 'Check the number.' : m.message; return { ok: false, code: 'invalid', message: msg, fieldErrors: { phone: msg } }; }
    return { ok: false, code: chk.reason ?? 'refused', message: REASON[chk.reason ?? ''] ?? 'We could not text a code. Try again later.' };
  }
  const sent = input.purpose === 'add' ? await a.startPhoneChange(c.phone) : await a.sendPhoneCode(c.phone);
  if (!sent.ok) return { ok: false, code: sent.code, message: sent.message };
  return { ok: true, data: { phone: c.phone, display: formatPhone(c.phone) } };
}

/** Checks the texted code. Signing in: the session is the number's account, then the page asked for (or the name, for
 *  a new account without one). Adding: the number is now the signed-in account's. */
export async function verifyPhoneCode(input: { phone: string; code: string; purpose: PhonePurpose; next?: string | null; name?: string | null; channel?: 'email' | 'text' | 'both' | null }): Promise<R<{ needsName?: boolean; phone?: string }>> {
  const phone = toE164(input.phone);
  const code = cleanCode(input.code);
  if (!phone) return { ok: false, code: 'invalid', message: 'Ask for a code again.' };
  if (!code) return { ok: false, code: 'invalid', message: 'Enter the 6-digit code from the text.', fieldErrors: { code: 'Enter the 6 digits.' } };
  const meta = await requestMeta();
  const lim = (await rpc('server_signin_phone_request', { p: { phone, ip: meta.ip, kind: 'verify' } }, SR)) as unknown as { ok: boolean; reason?: string };
  if (!lim.ok && lim.reason === 'rate_limited') return { ok: false, code: 'rate_limited', message: 'Too many tries. Wait a while, then ask for a new code.' };
  const a = await auth();
  if (input.purpose === 'add') {
    const user = await a.currentUser();
    if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
    const r = await a.verifyPhoneChange(phone, code);
    if (!r.ok) return { ok: false, code: r.code ?? 'credentials', message: r.message, fieldErrors: { code: r.message } };
    await rpc('server_phone_signed_in', { p_user: user.id, p_phone: r.user.phone ?? phone }, SR);
    for (const p of PROFILE_PATHS) revalidatePath(p);
    return { ok: true, data: { phone: formatPhone(r.user.phone ?? phone) } };
  }
  const r = await a.verifyPhoneCode(phone, code);
  if (!r.ok) return { ok: false, code: r.code ?? 'credentials', message: r.message, fieldErrors: { code: r.message } };
  await clearSessionCookies(false);
  await rememberSignIn('phone');
  let needsName = false;
  try {
    // the number the sign-in service verified (never what was typed): the account's row, then what the number links to
    const done = (await rpc('server_phone_signed_in', { p_user: r.user.id, p_phone: r.user.phone ?? phone, p_name: (input.name ?? '').trim() || undefined }, { ...SR, requestId: meta.requestId })) as unknown as { needs_name?: boolean };
    needsName = !!done.needs_name;
    // 0096: the channel chosen on the phone sign-up (Text by default for an account without an email)
    if (input.channel && ['email', 'text', 'both'].includes(input.channel)) await rpc('server_set_notify_channel', { p_user: r.user.id, p_channel: input.channel }, SR).catch(() => undefined);
  } catch (e) {
    if (!(e instanceof DbError)) throw e;
    return { ok: false, code: 'refused', message: e.message };
  }
  if (needsName) return { ok: true, data: { needsName: true } };
  redirect(await afterSignIn(r.user.id, safeNext(input.next ?? null)));
}

/** The name of an account just made by phone, then on to the page asked for. */
export async function savePhoneName(name: string, next: string | null): Promise<R> {
  const n = String(name ?? '').trim();
  if (n.length < 2 || n.length > 120) return { ok: false, code: 'invalid', message: 'Enter your full name.', fieldErrors: { name: 'Enter your full name.' } };
  const user = await (await auth()).currentUser();
  if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
  try { await rpc('server_account_set_name', { p_user: user.id, p_name: n }, SR); } catch (e) { return { ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'Try again.' }; }
  redirect(await afterSignIn(user.id, safeNext(next)));
}

/** Phone or email: the sign-in this person uses (the sign-in page opens on it on their devices). */
export async function setSignInMethod(method: 'phone' | 'email'): Promise<R<{ preferred: string }>> {
  const user = await (await auth()).currentUser();
  if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
  try {
    await rpc('server_account_set_sign_in', { p_user: user.id, p_method: method }, SR);
  } catch (e) { return { ok: false, code: 'refused', message: e instanceof DbError ? e.message : 'Try again.' }; }
  await rememberSignIn(method);
  for (const p of PROFILE_PATHS) revalidatePath(p);
  return { ok: true, data: { preferred: method } };
}

/** An account made by phone gives its email (the pay page asks before the first payment: receipts go there). */
export async function saveAccountEmail(email: string, path?: string | null): Promise<R<{ email: string }>> {
  const e = String(email ?? '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e) || e.length > 200) return { ok: false, code: 'invalid', message: 'Enter an email address like name@example.com.', fieldErrors: { email: 'Enter an email address like name@example.com.' } };
  const a = await auth();
  const user = await a.currentUser();
  if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
  let r: { ok: boolean; error?: string; message?: string };
  try { r = (await rpc('server_account_set_email', { p_user: user.id, p_email: e }, SR)) as unknown as typeof r; } catch (x) { return { ok: false, code: 'refused', message: x instanceof DbError ? x.message : 'Try again.' }; }
  if (!r.ok) return { ok: false, code: r.error ?? 'refused', message: r.error === 'email_taken' ? 'This email is already on file with us. Use another email, or contact us and we will link it to your account.' : r.message ?? 'Try again.', fieldErrors: { email: 'Use another email.' } };
  // the sign-in service emails a link to confirm the address (then it also signs in by email)
  const s = await a.setEmail(e);
  if (!s.ok && s.code === 'exists') return { ok: false, code: 'email_taken', message: s.message, fieldErrors: { email: 'Use another email.' } };
  if (path && path.startsWith('/')) revalidatePath(path);
  for (const p of PROFILE_PATHS) revalidatePath(p);
  return { ok: true, data: { email: e } };
}
