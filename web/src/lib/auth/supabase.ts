import 'server-only';
import { cache } from 'react';
import { cookies } from 'next/headers';
import { required } from '@/lib/env';
import { readSession } from './session-cookie';
import { verifyAccessToken } from './jwt-verify';
import type { AuthAdapter, AuthResult, SessionUser } from './types';

// Who is signed in, per server render, from the session cookie: the access token is verified with the project's
// public signing key (jwt-verify.ts), so a portal page neither builds a Supabase client nor waits for Supabase Auth.
// The Worker entry refreshes the session before the page runs (edge-refresh.ts), so the token is fresh. A token
// that cannot be verified that way (an older token, the key set not reachable, an expired token on a server
// without the Worker entry) falls back to asking Supabase Auth, as before. React's cache() keeps the answer for
// the render; in a server action or a route handler every call asks again.
// Loaded only when needed (sign-in, sign-out, two-step, an older token): a portal page never evaluates supabase-js.
const supabaseServer = cache(async () => (await import('@/lib/supabase/server')).supabaseServer());

interface Who { user: SessionUser; token: string | null; aal: 'aal1' | 'aal2' | null }
const who = cache(async (): Promise<Who | null> => {
  let token: string | null = null;
  try {
    const jar = await cookies();
    token = readSession(new Map(jar.getAll().map((c) => [c.name, c.value])))?.session.access_token ?? null;
  } catch { token = null; }
  if (!token) return null;
  const claims = await verifyAccessToken(token, required('NEXT_PUBLIC_SUPABASE_URL'));
  if (claims) return { user: { id: claims.sub, email: claims.email ?? '' }, token, aal: claims.aal === 'aal2' ? 'aal2' : 'aal1' };
  const s = await supabaseServer();
  const { data } = await s.auth.getUser();
  if (!data.user) return null;
  const { data: sd } = await s.auth.getSession();
  const { data: a } = await s.auth.mfa.getAuthenticatorAssuranceLevel();
  return { user: { id: data.user.id, email: data.user.email ?? '' }, token: sd.session?.access_token ?? null,
    aal: a?.currentLevel === 'aal2' ? 'aal2' : a?.currentLevel === 'aal1' ? 'aal1' : null };
});

// Supabase Auth's answers in plain words. An unknown address and a wrong password read the same.
function failure(e: { message?: string; code?: string; status?: number } | null | undefined, fallback: string): AuthResult & { ok: false } {
  const code = e?.code ?? '';
  const m = e?.message ?? fallback;
  if (code === 'invalid_credentials' || /invalid login/i.test(m)) return { ok: false, code: 'credentials', message: 'That email and password do not match an account.' };
  if (code === 'email_not_confirmed' || /email not confirmed/i.test(m)) return { ok: false, code: 'unconfirmed', message: 'Confirm your email first. We emailed you a link when the account was made (subject "Confirm your CarmaCars account"); it works for 24 hours. Press "Send a new confirmation link" below to get a new one.' };
  if (code === 'over_request_rate_limit' || code === 'over_email_send_rate_limit' || e?.status === 429 || /rate limit|too many/i.test(m)) return { ok: false, code: 'rate_limited', message: 'Too many tries. Wait a minute, then try again.' };
  if (code === 'user_banned') return { ok: false, code: 'inactive', message: 'This account is not active. Contact us if you think it should be.' };
  if (code === 'email_exists' || code === 'user_already_exists' || /already (been )?registered|already exists/i.test(m)) return { ok: false, code: 'exists', message: 'An account with this email already exists.' };
  return { ok: false, message: m };
}

// Supabase Auth over plain HTTP, for the calls that need no session (no client, no cookies written).
async function gotrue(path: string, body: unknown, opts: { service?: boolean; query?: Record<string, string>; method?: string } = {}) {
  const url = new URL(`${required('NEXT_PUBLIC_SUPABASE_URL').replace(/\/$/, '')}/auth/v1${path}`);
  for (const [k, v] of Object.entries(opts.query ?? {})) url.searchParams.set(k, v);
  const key = opts.service ? required('SUPABASE_SERVICE_ROLE_KEY') : required('NEXT_PUBLIC_SUPABASE_ANON_KEY');
  const r = await fetch(url, { method: opts.method ?? 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  let data: Record<string, unknown> = {};
  try { data = text ? (JSON.parse(text) as Record<string, unknown>) : {}; } catch { data = { msg: text.slice(0, 200) }; }
  const err = r.ok ? null : { status: r.status, code: (data.error_code ?? data.code) as string | undefined, message: String(data.msg ?? data.message ?? data.error_description ?? data.error ?? `Supabase Auth ${r.status}`) };
  return { ok: r.ok, status: r.status, data, err };
}

export function supabaseAuth(): AuthAdapter {
  return {
    async currentUser() { return (await who())?.user ?? null; },
    async accessToken() { return (await who())?.token ?? null; },
    async assurance() { return (await who())?.aal ?? null; },
    async signUp(email, password, meta) {
      const s = await supabaseServer();
      const { env } = await import('@/lib/env');
      const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
      const { data, error } = await s.auth.signUp({ email, password, options: { data: meta, emailRedirectTo: `${base}/auth/callback` } });
      if (error || !data.user) return failure(error, 'We could not create the account.');
      // Supabase answers an existing address with a user that has no identities (it never says so outright).
      if (Array.isArray(data.user.identities) && data.user.identities.length === 0) {
        return { ok: false, code: 'exists', message: 'An account with this email already exists. Sign in, or use "Forgot password" to set a new password.' };
      }
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? email }, needsConfirmation: !data.session };
    },
    async signIn(email, password) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.signInWithPassword({ email, password });
      if (error || !data.user) return failure(error, 'We could not sign you in.');
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? email } };
    },
    async signOut() {
      const s = await supabaseServer();
      await s.auth.signOut({ scope: 'local' });
    },
    async requestPasswordReset(email, redirectTo) {
      await gotrue('/recover', { email: email.trim().toLowerCase() }, { query: { redirect_to: redirectTo } }).catch(() => undefined);
    },
    async resendConfirmation(email, redirectTo) {
      const r = await gotrue('/resend', { type: 'signup', email: email.trim().toLowerCase() }, { query: { redirect_to: redirectTo } }).catch(() => null);
      // Supabase sends one confirmation per address a minute; saying "sent" then would be wrong
      if (r && !r.ok && (r.status === 429 || /rate limit|seconds/i.test(r.err?.message ?? ''))) return 'rate_limited';
    },
    async invite(email, fullName, redirectTo) {
      const r = await gotrue('/invite', { email: email.trim().toLowerCase(), data: { full_name: fullName } }, { service: true, query: { redirect_to: redirectTo } });
      if (!r.ok) return failure(r.err, 'We could not invite this person.');
      const u = r.data as { id?: string; email?: string };
      return u.id ? { ok: true, user: { id: u.id, email: u.email ?? email } } : { ok: false, message: 'We could not invite this person.' };
    },
    async createForRecord(userId, email, fullName, redirectTo) {
      const r = await gotrue('/admin/users', { id: userId, email: email.trim().toLowerCase(), email_confirm: false, user_metadata: { full_name: fullName } }, { service: true });
      if (!r.ok) return failure(r.err, 'We could not create the sign-in.');
      await gotrue('/recover', { email: email.trim().toLowerCase() }, { query: { redirect_to: redirectTo } }).catch(() => undefined);
      return { ok: true, user: { id: userId, email }, needsConfirmation: true };
    },
    async deleteAccount(userId) {
      await gotrue(`/admin/users/${encodeURIComponent(userId)}`, undefined, { service: true, method: 'DELETE' }).catch(() => undefined);
    },
    async updatePassword(password) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.updateUser({ password });
      if (error || !data.user) {
        if (/same.*password|different from the old/i.test(error?.message ?? '')) return { ok: false, message: 'Choose a password different from the one you had.' };
        if (/weak|at least|characters/i.test(error?.message ?? '')) return { ok: false, message: error!.message };
        return { ok: false, message: 'This link has expired or was already used. Ask for a new one below.' };
      }
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? '' } };
    },
    async mfaFactors() {
      const s = await supabaseServer();
      const { data } = await s.auth.mfa.listFactors();
      return (data?.all ?? []).filter((f) => f.factor_type === 'totp').map((f) => ({ id: f.id, verified: f.status === 'verified' }));
    },
    async mfaEnroll() {
      const s = await supabaseServer();
      // an enrolment started and never finished is removed first (Supabase refuses a second one by name)
      const { data: list } = await s.auth.mfa.listFactors();
      for (const f of list?.all ?? []) if (f.factor_type === 'totp' && f.status !== 'verified') await s.auth.mfa.unenroll({ factorId: f.id });
      const { data, error } = await s.auth.mfa.enroll({ factorType: 'totp', friendlyName: `Authenticator ${new Date().toISOString().slice(0, 10)}` });
      if (error || !data) return { ok: false as const, message: error?.message ?? 'We could not start two-step sign-in.' };
      return { ok: true as const, factorId: data.id, secret: data.totp.secret, uri: data.totp.uri, qr: data.totp.qr_code ?? null };
    },
    async mfaVerify(factorId, code) {
      const s = await supabaseServer();
      const { error } = await s.auth.mfa.challengeAndVerify({ factorId, code: code.replace(/\s/g, '') });
      return error ? { ok: false as const, message: /invalid|expired/i.test(error.message) ? 'That code did not match. Enter the newest code from the app.' : error.message } : { ok: true as const };
    }
  };
}
