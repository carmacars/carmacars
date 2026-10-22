'use server';
import { redirect } from 'next/navigation';
import { auth } from '@/lib/auth';
import { rpc } from '@/lib/db/repo';
import { verifyTurnstile } from '@/integrations/turnstile';
import { fieldErrors, newPasswordSchema, resetSchema, signInSchema, signUpSchema, type ActionResult } from '@/features/forms/schemas';
import { requestMeta } from '@/server/request';
import { rolesOf } from '@/server/door';
import { landingFor, safeNext } from '@/server/portals';
import { afterSignIn, clearSessionCookies, rememberSignIn } from '@/server/after-sign-in';
import { passwordLinkTarget, rememberEmail, siteBase } from '@/server/auth-links';

// Sign-in is Supabase Auth (email and password, reset by email). A new account also gets its users
// row and the renter role (public.register_account, 0027) with the same id as the sign-in account.

const base = siteBase;

const afterPassword = afterSignIn;

export async function signIn(_: unknown, fd: FormData): Promise<ActionResult> {
  const p = signInSchema.safeParse(Object.fromEntries(fd));
  if (!p.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(p.error) };
  const r = await (await auth()).signIn(p.data.email, p.data.password);
  if (!r.ok) return { ok: false, code: r.code ?? 'auth', message: r.message };
  // a view-as left from an earlier session never carries over to a new sign-in
  await clearSessionCookies(false);
  await rememberSignIn('email');
  // the sign-in service lets only confirmed addresses sign in: earlier requests with it are attached (migration 0040)
  await rpc('server_account_email_verified', { p_user: r.user.id, p_email: r.user.email }, { role: 'service_role' }).catch(() => undefined);
  redirect(await afterPassword(r.user.id, safeNext(fd.get('next'))));
}

/** The "confirm your email" link again (from the sign-in form). Says the same whether or not the account exists. */
export async function resendConfirmation(email: string): Promise<ActionResult> {
  const e = String(email ?? '').trim();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) return { ok: false, code: 'invalid', message: 'Enter your email address first.' };
  const r = await (await auth()).resendConfirmation(e, `${base()}/auth/callback`);
  await rememberEmail(e);
  if (r === 'rate_limited') return { ok: false, code: 'rate_limited', message: 'We sent a link to this address less than a minute ago. Check your inbox and spam, or wait a minute and press again.' };
  return { ok: true, data: null };
}

/** Starts enrolling an authenticator app (two-step sign-in). */
export async function startTwoStep(): Promise<ActionResult<{ factorId: string; secret: string; uri: string; qr: string | null }>> {
  const a = await auth();
  if (!(await a.currentUser())) return { ok: false, code: 'auth', message: 'Sign in first.' };
  const r = await a.mfaEnroll();
  return r.ok ? { ok: true, data: { factorId: r.factorId, secret: r.secret, uri: r.uri, qr: r.qr } } : { ok: false, code: 'refused', message: r.message };
}

/** Checks a code (enrolment or the second step at sign-in) and goes on to the page asked for. */
export async function verifyTwoStep(factorId: string | null, code: string, next: string | null): Promise<ActionResult> {
  const a = await auth();
  const user = await a.currentUser();
  if (!user) return { ok: false, code: 'auth', message: 'Sign in first.' };
  if (!/^\s*\d{3}\s?\d{3}\s*$/.test(code)) return { ok: false, code: 'invalid', message: 'Enter the 6-digit code from your authenticator app.' };
  const id = factorId ?? (await a.mfaFactors()).find((f) => f.verified)?.id;
  if (!id) return { ok: false, code: 'refused', message: 'Set up two-step sign-in first.' };
  const r = await a.mfaVerify(id, code);
  if (!r.ok) return { ok: false, code: 'refused', message: r.message };
  redirect(safeNext(next) ?? landingFor(await rolesOf(user.id)));
}

export async function signUp(_: unknown, fd: FormData): Promise<ActionResult> {
  const p = signUpSchema.safeParse({ ...Object.fromEntries(fd), agree: fd.get('agree') === 'on' });
  if (!p.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(p.error) };
  const meta = await requestMeta();
  if (!(await verifyTurnstile(fd.get('cf-turnstile-response') as string | null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  const a = await auth();
  // An address already on file (a booking request, an owner or investor record) gets a sign-in for that record and one
  // email, the link to choose the password. Asked before the sign-up so Supabase never also sends a confirmation for a
  // sign-in that would be removed again (two emails, one dead link).
  const onFile = (await rpc('server_user_by_email', { p_email: p.data.email }, { role: 'service_role' }).catch(() => null)) as unknown as string | null;
  if (onFile && a.createForRecord) {
    const made = await a.createForRecord(onFile, p.data.email, p.data.name, passwordLinkTarget());
    if (!made.ok) return { ok: false, code: made.code === 'exists' ? 'exists' : 'email_on_record', message: made.code === 'exists'
      ? 'An account with this email already exists. Sign in, or use "Forgot password" to set a new password.'
      : 'We already have a booking request with this email. Contact us and we will link it to your account.' };
    await rememberEmail(p.data.email);
    return { ok: true, data: { confirm: true, onRecord: true, email: p.data.email } };
  }
  const r = await a.signUp(p.data.email, p.data.password, { full_name: p.data.name });
  if (!r.ok) return { ok: false, code: 'auth', message: r.message };
  const reg = (await rpc('register_account', { p_user: r.user.id, p_email: p.data.email, p_full_name: p.data.name }, { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; error?: string; message?: string };
  if (!reg.ok && reg.error === 'email_on_record' && a.createForRecord && a.deleteAccount) {
    // The address is already on file from a booking request, without a sign-in. The sign-in just made is removed and
    // one is made for that record instead, with a link to the address to choose the password: whoever opens it
    // owns the address, so the bookings it holds are theirs to see.
    await a.signOut().catch(() => undefined);
    await a.deleteAccount(r.user.id);
    const id = (await rpc('server_user_by_email', { p_email: p.data.email }, { role: 'service_role' })) as unknown as string | null;
    const made = id ? await a.createForRecord(id, p.data.email, p.data.name, passwordLinkTarget()) : null;
    if (!made?.ok) return { ok: false, code: 'email_on_record', message: 'We already have a booking request with this email. Contact us and we will link it to your account.' };
    await rememberEmail(p.data.email);
    return { ok: true, data: { confirm: true, onRecord: true, email: p.data.email } };
  }
  if (!reg.ok) return { ok: false, code: 'email_on_record', message: reg.message ?? 'We could not finish creating the account. Contact us.' };
  if (r.needsConfirmation) { await rememberEmail(p.data.email); return { ok: true, data: { confirm: true, email: p.data.email } }; }
  redirect('/account?welcome=1');
}

export async function signOut(): Promise<void> {
  await clearSessionCookies(true);
  await (await auth()).signOut();
  redirect('/');
}

export async function requestReset(_: unknown, fd: FormData): Promise<ActionResult> {
  const p = resetSchema.safeParse(Object.fromEntries(fd));
  if (!p.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(p.error) };
  const meta = await requestMeta();
  if (!(await verifyTurnstile(fd.get('cf-turnstile-response') as string | null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  await (await auth()).requestPasswordReset(p.data.email, passwordLinkTarget());
  await rememberEmail(p.data.email);
  return { ok: true, data: null };
}

export async function updatePassword(_: unknown, fd: FormData): Promise<ActionResult> {
  const p = newPasswordSchema.safeParse({ password: fd.get('password'), token: fd.get('token') || undefined });
  if (!p.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(p.error) };
  const r = await (await auth()).updatePassword(p.data.password, p.data.token);
  if (!r.ok) return { ok: false, code: 'expired', message: r.message };
  // the link that let them choose a password proved the address (migration 0040)
  await rpc('server_account_email_verified', { p_user: r.user.id, p_email: r.user.email }, { role: 'service_role' }).catch(() => undefined);
  // invited staff, owners and investors go to their portal (or choose one), renters to their trips
  const to = await afterPassword(r.user.id, null);
  redirect(to === '/account' ? '/account?password=1' : to.includes('?') ? to : `${to}?password=1`);
}
