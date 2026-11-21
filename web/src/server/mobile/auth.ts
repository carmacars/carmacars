import 'server-only';
import { env, required } from '@/lib/env';
import { verifyAccessToken } from '@/lib/auth/jwt-verify';
import { jwtClaims } from '@/lib/auth/session-cookie';
import type { MobileSession } from '@/features/mobile-api/contract';
import { LiveTokens, revocationKeys } from '@/features/mobile-api/revoke';
import { rpc } from '@/lib/db/repo';

// The native app's sessions (release 48). The same accounts as the website: on Supabase the tokens come from Supabase
// Auth over plain HTTP (no cookie, no client); on the local stack from the stand-in (src/lib/auth/local.ts). The app
// keeps the pair in the phone's keychain and sends the access token with each call (src/server/mobile/context.ts).
export type Issued = { ok: true; session: MobileSession } | { ok: false; code: string; message: string };
const local = () => env().DATA_BACKEND === 'local';
const BAD_CODE = 'That code does not match or has expired. Check the newest text from CarmaCars, or ask for a new code.';

interface GoTrueSession { access_token?: string; refresh_token?: string; expires_at?: number; expires_in?: number; user?: { id?: string; email?: string; phone?: string } }
async function gotrue(path: string, body: unknown, o: { bearer?: string; service?: boolean; method?: string } = {}): Promise<{ ok: boolean; status: number; data: Record<string, unknown> }> {
  const key = o.service ? required('SUPABASE_SERVICE_ROLE_KEY') : required('NEXT_PUBLIC_SUPABASE_ANON_KEY');
  const r = await fetch(`${required('NEXT_PUBLIC_SUPABASE_URL').replace(/\/$/, '')}/auth/v1${path}`, {
    method: o.method ?? 'POST', headers: { apikey: key, authorization: `Bearer ${o.bearer ?? key}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const text = await r.text();
  let data: Record<string, unknown> = {};
  try { data = text ? (JSON.parse(text) as Record<string, unknown>) : {}; } catch { data = {}; }
  return { ok: r.ok, status: r.status, data };
}
function session(d: GoTrueSession): Issued {
  if (!d.access_token || !d.refresh_token || !d.user?.id) return { ok: false, code: 'auth', message: 'The sign-in service did not answer. Try again.' };
  const exp = d.expires_at ?? Math.floor(Date.now() / 1000) + (d.expires_in ?? 3600);
  return { ok: true, session: { access_token: d.access_token, refresh_token: d.refresh_token, expires_at: exp,
    user: { id: d.user.id, email: d.user.email ?? '', phone: d.user.phone ? (d.user.phone.startsWith('+') ? d.user.phone : `+${d.user.phone}`) : null } } };
}
function failure(status: number, d: Record<string, unknown>, fallback: string): Issued & { ok: false } {
  const code = String(d.error_code ?? d.code ?? '');
  const m = String(d.msg ?? d.message ?? d.error_description ?? '');
  if (code === 'invalid_credentials' || /invalid login/i.test(m)) return { ok: false, code: 'credentials', message: 'That email and password do not match an account.' };
  if (code === 'email_not_confirmed' || /email not confirmed/i.test(m)) return { ok: false, code: 'unconfirmed', message: 'Confirm your email first. We emailed you a link when the account was made (subject "Confirm your CarmaCars account"); it works for 24 hours.' };
  if (status === 429 || /rate limit|too many/i.test(m)) return { ok: false, code: 'rate_limited', message: 'Too many tries. Wait a minute, then try again.' };
  if (code === 'user_banned') return { ok: false, code: 'inactive', message: 'This account is not active. Contact us if you think it should be.' };
  return { ok: false, code: 'auth', message: fallback };
}

async function localIssue(u: { id: string; email: string; phone?: string | null }, aal: 'aal1' | 'aal2' = 'aal1'): Promise<Issued> {
  const l = await import('@/lib/auth/local');
  return { ok: true, session: { access_token: await l.localAccessToken(u, aal, '1h'), refresh_token: await l.localRefreshToken(u, aal), expires_at: Math.floor(Date.now() / 1000) + 3600,
    user: { id: u.id, email: u.email, phone: u.phone ?? null } } };
}

/** Email and password. The caller has run the sign-in pause and records the sign-in event (as the website does). */
export async function passwordSession(email: string, password: string): Promise<Issued> {
  if (local()) {
    const r = await (await (await import('@/lib/auth')).auth()).signIn(email, password);
    return r.ok ? localIssue(r.user) : { ok: false, code: r.code ?? 'auth', message: r.message };
  }
  const r = await gotrue('/token?grant_type=password', { email: email.trim().toLowerCase(), password });
  return r.ok ? session(r.data as GoTrueSession) : failure(r.status, r.data, 'We could not sign you in.');
}

/** A new access token from the refresh token (the app asks a minute before the old one ends). */
export async function refreshSession(refreshToken: string): Promise<Issued> {
  if (local()) {
    const l = await import('@/lib/auth/local');
    const who = await l.localReadRefresh(refreshToken);
    return who ? localIssue(who.user, who.aal) : { ok: false, code: 'expired', message: 'Sign in again.' };
  }
  const r = await gotrue('/token?grant_type=refresh_token', { refresh_token: refreshToken });
  // a refresh token that was used, revoked or has ended: the app signs the person out. Anything else (the service is busy) is tried again
  if (!r.ok) return r.status >= 500 || r.status === 429 ? { ok: false, code: 'busy', message: 'The sign-in service did not answer. Try again.' } : { ok: false, code: 'expired', message: 'Sign in again.' };
  return session(r.data as GoTrueSession);
}

/** The texted code (the code was asked for with the website's own action, so its limits and wording are the same). */
export async function phoneSession(phone: string, code: string): Promise<Issued> {
  if (local()) {
    const r = await (await (await import('@/lib/auth')).auth()).verifyPhoneCode(phone, code);
    return r.ok ? localIssue(r.user) : { ok: false, code: r.code ?? 'credentials', message: r.message };
  }
  const r = await gotrue('/verify', { type: 'sms', phone, token: code });
  if (!r.ok) return r.status === 429 ? { ok: false, code: 'rate_limited', message: 'Too many tries. Wait a few minutes, then ask for a new code.' } : { ok: false, code: 'credentials', message: BAD_CODE };
  return session(r.data as GoTrueSession);
}

/** Two-step sign-in (staff): the code of the authenticator app; the session that comes back is aal2. */
export async function twoStepSession(token: string, code: string): Promise<Issued> {
  const clean = code.replace(/\s/g, '');
  if (!/^\d{6}$/.test(clean)) return { ok: false, code: 'invalid', message: 'Enter the 6-digit code from your authenticator app.' };
  if (local()) {
    const a = await (await import('@/lib/auth')).auth();
    const [user, factors] = [await a.currentUser(), await a.mfaFactors()];
    const f = factors.find((x) => x.verified);
    if (!user || !f) return { ok: false, code: 'no_factor', message: 'Two-step sign-in is not set up for this account yet. Set it up on carmacars.ca first.' };
    const r = await a.mfaVerify(f.id, clean);
    return r.ok ? localIssue(user, 'aal2') : { ok: false, code: 'credentials', message: r.message };
  }
  const u = await gotrue('/user', undefined, { bearer: token, method: 'GET' });
  const factor = ((u.data.factors as Array<{ id: string; factor_type?: string; status?: string }> | undefined) ?? []).find((f) => f.factor_type === 'totp' && f.status === 'verified');
  if (!u.ok || !factor) return { ok: false, code: 'no_factor', message: 'Two-step sign-in is not set up for this account yet. Set it up on carmacars.ca first.' };
  const ch = await gotrue(`/factors/${factor.id}/challenge`, {}, { bearer: token });
  if (!ch.ok || typeof ch.data.id !== 'string') return failure(ch.status, ch.data, 'We could not check the code. Try again.');
  const v = await gotrue(`/factors/${factor.id}/verify`, { challenge_id: ch.data.id, code: clean }, { bearer: token });
  if (!v.ok) return v.status === 429 ? failure(429, v.data, '') : { ok: false, code: 'credentials', message: 'That code did not match. Enter the newest code from the app.' };
  return session(v.data as GoTrueSession);
}

/** A session for an account that just proved itself another way (a passkey): a one-time link made and used here, never sent. */
export async function sessionForUser(userId: string): Promise<Issued> {
  if (local()) {
    const { localSql } = await import('@/lib/db/local');
    const rows = await localSql()`select id, email, phone from local_auth.users where id = ${userId}`;
    return rows[0] ? localIssue({ id: rows[0].id as string, email: (rows[0].email as string | null) ?? '', phone: (rows[0].phone as string | null) ?? null })
      : { ok: false, code: 'auth', message: 'This account has no sign-in.' };
  }
  const u = await gotrue(`/admin/users/${encodeURIComponent(userId)}`, undefined, { service: true, method: 'GET' });
  const email = typeof u.data.email === 'string' ? u.data.email : '';
  if (!u.ok || !email) return { ok: false, code: 'email_needed', message: 'Add an email to your account before using a passkey.' };
  const link = await gotrue('/admin/generate_link', { type: 'magiclink', email }, { service: true });
  const d = link.data as { hashed_token?: string; properties?: { hashed_token?: string } };
  const hash = d.hashed_token ?? d.properties?.hashed_token;
  if (!link.ok || !hash) return { ok: false, code: 'auth', message: 'We could not sign you in. Try again.' };
  const v = await gotrue('/verify', { type: 'magiclink', token_hash: hash });
  return v.ok ? session(v.data as GoTrueSession) : failure(v.status, v.data, 'We could not sign you in. Try again.');
}

const SR = { role: 'service_role' as const };
const live = new LiveTokens();

/** Ends this phone's session only: the sign-in service ends its refresh token, and the access token (checked here with
 *  the public keys, so it would stay good until it expires) is refused from now on (migration 3400). */
export async function endSession(token: string): Promise<void> {
  if (!token) return;
  const c = jwtClaims(token);
  const keys = await revocationKeys(token, c);
  live.drop(keys[0]!);
  const exp = typeof c?.exp === 'number' ? c.exp * 1000 : Date.now() + 3600_000;
  await rpc('server_bearer_revoke', { p_keys: keys, p_until: new Date(exp + 300_000).toISOString() }, SR)
    .catch((e) => console.error('mobile sign-out: revoke', e instanceof Error ? e.name : 'error'));
  if (local()) return;
  await gotrue('/logout?scope=local', {}, { bearer: token }).catch(() => undefined);
}

/** False once the token was signed out (its hash or its sign-in session is stored). A database that does not answer
 *  does not sign anyone out: every other call needs it too, and fails on its own. */
async function stillLive(token: string, claims: Record<string, unknown> | null): Promise<boolean> {
  const keys = await revocationKeys(token, claims);
  if (live.has(keys[0]!)) return true;
  try {
    if (await rpc('server_bearer_revoked', { p_keys: keys }, SR)) return false;
  } catch (e) {
    console.error('mobile token: revocation check', e instanceof Error ? e.name : 'error');
    return true;
  }
  live.add(keys[0]!);
  return true;
}

/** Whose token this is, checked: the project's public keys first, Supabase Auth for an older token; the stand-in locally.
 *  A token that was signed out (endSession) is nobody's. */
export async function tokenUser(token: string): Promise<{ id: string; email: string; aal: 'aal1' | 'aal2' } | null> {
  const who = await tokenOwner(token);
  return who && (await stillLive(token, jwtClaims(token))) ? who : null;
}

async function tokenOwner(token: string): Promise<{ id: string; email: string; aal: 'aal1' | 'aal2' } | null> {
  if (!token || token.length > 6000) return null;
  if (local()) {
    const { asMobileCall } = await import('./context');
    return asMobileCall(token, async () => {
      const a = await (await import('@/lib/auth')).auth();
      const [u, aal] = [await a.currentUser(), await a.assurance()];
      return u ? { id: u.id, email: u.email, aal: aal === 'aal2' ? 'aal2' : 'aal1' } : null;
    });
  }
  const claims = await verifyAccessToken(token, required('NEXT_PUBLIC_SUPABASE_URL'));
  if (claims) return { id: claims.sub, email: claims.email ?? '', aal: claims.aal === 'aal2' ? 'aal2' : 'aal1' };
  // an expired token never asks Supabase Auth (the app refreshes and tries once more)
  const c = jwtClaims(token);
  if (!c || typeof c.exp !== 'number' || c.exp * 1000 <= Date.now()) return null;
  const u = await gotrue('/user', undefined, { bearer: token, method: 'GET' }).catch(() => null);
  return u?.ok && typeof u.data.id === 'string' ? { id: u.data.id, email: String(u.data.email ?? ''), aal: c.aal === 'aal2' ? 'aal2' : 'aal1' } : null;
}
