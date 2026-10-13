'use server';
import { redirect } from 'next/navigation';
import { auth } from '@/lib/auth';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { verifyTurnstile } from '@/integrations/turnstile';
import { fieldErrors, newPasswordSchema, resetSchema, signInSchema, signUpSchema, type ActionResult } from '@/features/forms/schemas';
import { requestMeta } from '@/server/request';
import { homeFor, rolesOf } from '@/server/door';

// Sign-in is Supabase Auth (email and password, reset by email). A new account also gets its users
// row and the renter role (public.register_account, 0027) with the same id as the sign-in account.
const safeNext = (n: FormDataEntryValue | null | undefined) => (typeof n === 'string' && /^\/(?!\/)[\w\-/?=&.]*$/.test(n) ? n : null);

/** After the password: the second step when the person enrolled one (or must, as staff with the switch on),
 *  then the page asked for, or the home of their role (admin, assistant, field, investor, owner, renter). */
async function afterPassword(userId: string, next: string | null): Promise<string> {
  const a = await auth();
  const roles = await rolesOf(userId);
  const home = next ?? homeFor(roles);
  const factors = (await a.mfaFactors().catch(() => [])).filter((f) => f.verified);
  if (factors.length) return `/two-step?next=${encodeURIComponent(home)}`;
  if (roles.staff && roles.two_step_required) return `/two-step/setup?next=${encodeURIComponent(home)}`;
  return home;
}

export async function signIn(_: unknown, fd: FormData): Promise<ActionResult> {
  const p = signInSchema.safeParse(Object.fromEntries(fd));
  if (!p.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(p.error) };
  const r = await (await auth()).signIn(p.data.email, p.data.password);
  if (!r.ok) return { ok: false, code: 'auth', message: r.message };
  redirect(await afterPassword(r.user.id, safeNext(fd.get('next'))));
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
  redirect(safeNext(next) ?? homeFor(await rolesOf(user.id)));
}

export async function signUp(_: unknown, fd: FormData): Promise<ActionResult> {
  const p = signUpSchema.safeParse({ ...Object.fromEntries(fd), agree: fd.get('agree') === 'on' });
  if (!p.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(p.error) };
  const meta = await requestMeta();
  if (!(await verifyTurnstile(fd.get('cf-turnstile-response') as string | null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  const a = await auth();
  const r = await a.signUp(p.data.email, p.data.password, { full_name: p.data.name });
  if (!r.ok) return { ok: false, code: 'auth', message: r.message };
  const reg = (await rpc('register_account', { p_user: r.user.id, p_email: p.data.email, p_full_name: p.data.name }, { role: 'service_role', requestId: meta.requestId })) as unknown as { ok: boolean; message?: string };
  if (!reg.ok) return { ok: false, code: 'email_on_record', message: reg.message ?? 'We could not finish creating the account. Contact us.' };
  if (r.needsConfirmation) return { ok: true, data: { confirm: true, email: p.data.email } };
  redirect('/account?welcome=1');
}

export async function signOut(): Promise<void> {
  await (await auth()).signOut();
  redirect('/');
}

export async function requestReset(_: unknown, fd: FormData): Promise<ActionResult> {
  const p = resetSchema.safeParse(Object.fromEntries(fd));
  if (!p.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(p.error) };
  const meta = await requestMeta();
  if (!(await verifyTurnstile(fd.get('cf-turnstile-response') as string | null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
  const redirectTo = env().DATA_BACKEND === 'local' ? `${base}/update-password` : `${base}/auth/callback?next=/update-password`;
  await (await auth()).requestPasswordReset(p.data.email, redirectTo);
  return { ok: true, data: null };
}

export async function updatePassword(_: unknown, fd: FormData): Promise<ActionResult> {
  const p = newPasswordSchema.safeParse({ password: fd.get('password'), token: fd.get('token') || undefined });
  if (!p.success) return { ok: false, code: 'invalid', message: 'Check the highlighted fields.', fieldErrors: fieldErrors(p.error) };
  const r = await (await auth()).updatePassword(p.data.password, p.data.token);
  if (!r.ok) return { ok: false, code: 'auth', message: r.message };
  redirect('/account?password=1');
}
