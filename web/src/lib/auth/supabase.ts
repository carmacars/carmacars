import 'server-only';
import { cache } from 'react';
import { cookies } from 'next/headers';
import { required } from '@/lib/env';
import { readSession } from './session-cookie';
import { verifyAccessToken } from './jwt-verify';
import type { AuthAdapter, AuthResult, PhoneCodeResult, SessionUser } from './types';
import { OAUTH_PROVIDERS } from './oauth';

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

// Supabase Auth's answers to a code request in plain words (the hook's own refusal arrives as its message).
const BAD_CODE = 'That code does not match or has expired. Check the newest text from CarmaCars, or ask for a new code.';
function codeFailure(e: { message?: string; code?: string; status?: number } | null | undefined): PhoneCodeResult & { ok: false } {
  const code = e?.code ?? '';
  const m = e?.message ?? '';
  if (code === 'over_sms_send_rate_limit' || code === 'over_request_rate_limit' || e?.status === 429 || /rate limit|seconds|too many/i.test(m)) {
    return { ok: false, code: 'rate_limited', message: 'We texted a code a moment ago. Wait a minute before asking for another.' };
  }
  if (code === 'sms_send_failed' || code === 'hook_timeout' || code === 'hook_payload_invalid_content_type' || /hook|sms|provider|send/i.test(m)) {
    return { ok: false, code: 'send_failed', message: 'We could not text a code right now. Try again in a minute, or sign in with your email.' };
  }
  if (code === 'phone_provider_disabled' || code === 'sms_provider_disabled') return { ok: false, code: 'refused', message: 'Sign-in by phone is not available right now. Sign in with your email.' };
  return { ok: false, code: 'refused', message: 'We could not text a code to this number. Check it, or sign in with your email.' };
}
const plusPhone = (p: string | null | undefined) => (p ? (p.startsWith('+') ? p : `+${p}`) : null);

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
    async openForCapture(userId, email, fullName) {
      // no password, email_confirm false, and Supabase sends nothing for an account made this way
      const r = await gotrue('/admin/users', { id: userId, email: email.trim().toLowerCase(), email_confirm: false, user_metadata: { full_name: fullName } }, { service: true });
      if (!r.ok) return failure(r.err, 'We could not create the sign-in.');
      return { ok: true, user: { id: userId, email }, needsConfirmation: true };
    },
    async claimForCapture(userId, email, password) {
      const e = email.trim().toLowerCase();
      const got = await gotrue(`/admin/users/${encodeURIComponent(userId)}`, undefined, { service: true, method: 'GET' });
      const u = got.data as { email?: string; email_confirmed_at?: string | null };
      if (!got.ok || (u.email ?? '').toLowerCase() !== e || u.email_confirmed_at) return { ok: false, code: 'exists', message: 'An account with this email already exists.' };
      const r = await gotrue(`/admin/users/${encodeURIComponent(userId)}`, { password }, { service: true, method: 'PUT' });
      if (!r.ok) return failure(r.err, 'We could not set the password.');
      const { env } = await import('@/lib/env');
      await gotrue('/resend', { type: 'signup', email: e }, { query: { redirect_to: `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/auth/callback` } }).catch(() => undefined);
      return { ok: true, user: { id: userId, email: e }, needsConfirmation: true };
    },
    async continueLink(email, next) {
      const { env } = await import('@/lib/env');
      const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
      // a magic link of an existing account: verifying it signs in and confirms the address (as a recovery link does)
      const r = await gotrue('/admin/generate_link', { type: 'magiclink', email: email.trim().toLowerCase() }, { service: true });
      const d = r.data as { hashed_token?: string; properties?: { hashed_token?: string } };
      const token = d.hashed_token ?? d.properties?.hashed_token;
      if (!r.ok || !token) return { ok: false, message: 'We could not make the sign-in link.' };
      return { ok: true, link: `${base}/auth/callback?token_hash=${encodeURIComponent(token)}&type=magiclink&next=${encodeURIComponent(next)}` };
    },
    async accountLink(email, fullName, next, userId) {
      const e = email.trim().toLowerCase();
      const { env } = await import('@/lib/env');
      const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
      let type: 'invite' | 'recovery' = 'invite';
      if (userId) {
        // a record already on file: its sign-in is made with the same id (no email), then a link to choose a password
        const made = await gotrue('/admin/users', { id: userId, email: e, email_confirm: true, user_metadata: { full_name: fullName } }, { service: true });
        if (!made.ok && made.status !== 422) return failure(made.err, 'We could not create the sign-in.');
        if (!made.ok) return { ok: false, code: 'exists', message: 'This address already signs in.' };
        type = 'recovery';
      }
      const r = await gotrue('/admin/generate_link', { type, email: e, data: { full_name: fullName } }, { service: true });
      if (!r.ok) return r.status === 422 ? { ok: false, code: 'exists', message: 'This address already signs in.' } : failure(r.err, 'We could not make the sign-in link.');
      const d = r.data as { id?: string; hashed_token?: string; properties?: { hashed_token?: string }; user?: { id?: string } };
      const token = d.hashed_token ?? d.properties?.hashed_token;
      const id = userId ?? d.id ?? d.user?.id;
      if (!token || !id) return { ok: false, message: 'We could not make the sign-in link.' };
      return { ok: true, user: { id, email: e }, link: `${base}/auth/callback?token_hash=${encodeURIComponent(token)}&type=${type}&next=${encodeURIComponent(next)}` };
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
    async sendPhoneCode(phone) {
      const r = await gotrue('/otp', { phone, create_user: true, channel: 'sms' }).catch(() => null);
      if (!r) return { ok: false, code: 'send_failed', message: 'We could not text a code right now. Try again in a minute, or sign in with your email.' };
      return r.ok ? { ok: true } : codeFailure(r.err);
    },
    async verifyPhoneCode(phone, code) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.verifyOtp({ phone, token: code, type: 'sms' });
      if (error || !data.user) {
        if (error && (error.status === 429 || /rate limit|too many/i.test(error.message))) return { ok: false, code: 'rate_limited', message: 'Too many tries. Wait a few minutes, then ask for a new code.' };
        return { ok: false, code: 'credentials', message: BAD_CODE };
      }
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? '', phone: plusPhone(data.user.phone) } };
    },
    async startPhoneChange(phone) {
      const s = await supabaseServer();
      const { error } = await s.auth.updateUser({ phone });
      if (!error) return { ok: true };
      // another account's number: the same answer as a code sent (nobody learns the number has an account)
      if (error.code === 'phone_exists' || (error.status === 422 && /already|exists|registered/i.test(error.message))) return { ok: true };
      return codeFailure(error);
    },
    async verifyPhoneChange(phone, code) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.verifyOtp({ phone, token: code, type: 'phone_change' });
      if (error || !data.user) return { ok: false, code: 'credentials', message: BAD_CODE };
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? '', phone: plusPhone(data.user.phone) ?? phone } };
    },
    async setEmail(email) {
      const s = await supabaseServer();
      const { env } = await import('@/lib/env');
      const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
      const { error } = await s.auth.updateUser({ email: email.trim().toLowerCase() }, { emailRedirectTo: `${base}/auth/callback?next=/account` });
      if (!error) return { ok: true };
      const f = failure(error, 'We could not save this email.');
      return f.code === 'exists' ? { ok: false, code: 'exists', message: 'This email is already used by another account. Sign in with it instead, or use another email.' } : { ok: false, code: f.code, message: f.message };
    },
    async oauthStart(provider, redirectTo) {
      const s = await supabaseServer();
      // PKCE: supabase-js writes the code verifier to its cookie on this browser; the code comes back to redirectTo
      const { data, error } = await s.auth.signInWithOAuth({
        provider: OAUTH_PROVIDERS[provider].supabase,
        options: { redirectTo, skipBrowserRedirect: true, ...(provider === 'google' ? { queryParams: { prompt: 'select_account' } } : {}) }
      });
      if (error || !data.url) return { ok: false, message: error?.message ?? 'The sign-in service did not answer.' };
      return { ok: true, url: data.url };
    },
    async oauthExchange(code) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.exchangeCodeForSession(code);
      if (error || !data.user) return { ok: false, message: error?.message ?? 'The code was refused.' };
      const u = data.user;
      const meta = (u.user_metadata ?? {}) as Record<string, unknown>;
      const name = [meta.full_name, meta.name].find((v) => typeof v === 'string' && v.trim()) as string | undefined;
      const ids = u.identities ?? [];
      // made by this sign-in: the provider's identity only, created moments ago
      const fresh = ids.length === 1 && ids[0]!.provider !== 'email' && ids[0]!.provider !== 'phone' && Date.now() - Date.parse(u.created_at) < 10 * 60_000;
      return { ok: true, user: { id: u.id, email: u.email ?? '' }, emailVerified: !!u.email_confirmed_at, name: name ?? null, fresh };
    },
    async relinkToRecord(freshId, recordId, email, fullName) {
      const got = await gotrue(`/admin/users/${encodeURIComponent(freshId)}`, undefined, { service: true, method: 'GET' });
      const u = got.data as { identities?: Array<{ provider?: string }>; created_at?: string };
      // never removes an account that holds anything: only the one this sign-in just made
      if (!got.ok || (u.identities ?? []).length > 1 || Date.now() - Date.parse(u.created_at ?? '') > 10 * 60_000) return false;
      // the record already has a sign-in (another address): staff link those by hand
      const taken = await gotrue(`/admin/users/${encodeURIComponent(recordId)}`, undefined, { service: true, method: 'GET' });
      if (taken.ok) return false;
      const del = await gotrue(`/admin/users/${encodeURIComponent(freshId)}`, undefined, { service: true, method: 'DELETE' });
      if (!del.ok) return false;
      const made = await gotrue('/admin/users', { id: recordId, email: email.trim().toLowerCase(), email_confirm: true, user_metadata: { full_name: fullName } }, { service: true });
      return made.ok;
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
