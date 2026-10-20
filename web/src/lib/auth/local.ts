import 'server-only';
import { randomBytes, randomUUID, scrypt as scryptCb, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';
import { cookies } from 'next/headers';
import { SignJWT, jwtVerify } from 'jose';
import { env, required } from '@/lib/env';
import { localSql } from '@/lib/db/local';
import type { AuthAdapter, SessionUser } from './types';
import { checkCode, newSecret, otpauthUri } from './totp';

// LOCAL ONLY. A stand-in for Supabase Auth on the local stack (local/local_auth.sql):
// scrypt password hashes, an HS256 session cookie with the same claims Supabase issues
// (sub, email, role "authenticated"), and reset links written to local_auth.mailbox. A sign-up waits for its
// confirmation link (written to the mailbox, as Supabase would email it) before it can sign in; links last 24 hours,
// as mailer_otp_exp does on Supabase (scripts/deploy/auth-templates.mjs).
const LINK_HOURS = 24;
const UNCONFIRMED = 'Confirm your email first. We emailed you a link when the account was made (subject "Confirm your CarmaCars account"); it works for 24 hours. Press "Send a new confirmation link" below to get a new one.';
const scrypt = promisify(scryptCb) as (p: string, s: Buffer, n: number) => Promise<Buffer>;
const COOKIE = 'cc-local-session';
const HINT = 'cc-local-in';
const key = () => new TextEncoder().encode(required('LOCAL_AUTH_SECRET'));
const hashToken = (t: string) => createHash('sha256').update(t).digest('hex');

async function hashPassword(pw: string) {
  const salt = randomBytes(16);
  return `scrypt$${salt.toString('base64')}$${(await scrypt(pw, salt, 64)).toString('base64')}`;
}
async function checkPassword(pw: string, stored: string) {
  const [, salt, hash] = stored.split('$');
  if (!salt || !hash) return false;
  const got = await scrypt(pw, Buffer.from(salt, 'base64'), 64);
  const want = Buffer.from(hash, 'base64');
  return got.length === want.length && timingSafeEqual(got, want);
}
async function setSession(u: SessionUser, aal: 'aal1' | 'aal2' = 'aal1') {
  const jwt = await new SignJWT({ email: u.email, role: 'authenticated', aal }).setProtectedHeader({ alg: 'HS256' })
    .setSubject(u.id).setIssuedAt().setExpirationTime('7d').sign(key());
  (await cookies()).set(COOKIE, jwt, { httpOnly: true, sameSite: 'lax', path: '/', secure: false, maxAge: 7 * 86400 });
  // readable by the page (no secret in it): the site's own scripts tell a signed-in visitor apart, as they can with
  // Supabase's session cookie (the discount game never shows to someone signed in)
  (await cookies()).set(HINT, '1', { httpOnly: false, sameSite: 'lax', path: '/', secure: false, maxAge: 7 * 86400 });
}

export function localAuth(): AuthAdapter {
  const sql = localSql();
  return {
    async currentUser() {
      const t = (await cookies()).get(COOKIE)?.value;
      if (!t) return null;
      try {
        const { payload } = await jwtVerify(t, key());
        return payload.sub ? { id: payload.sub, email: String(payload.email ?? '') } : null;
      } catch {
        return null;
      }
    },
    async accessToken() {
      return (await cookies()).get(COOKIE)?.value ?? null;
    },
    async assurance() {
      const t = (await cookies()).get(COOKIE)?.value;
      if (!t) return null;
      try { const { payload } = await jwtVerify(t, key()); return payload.aal === 'aal2' ? 'aal2' : 'aal1'; } catch { return null; }
    },
    async mfaFactors() {
      const u = await this.currentUser(); if (!u) return [];
      const rows = await sql`select id, verified_at from local_auth.factors where user_id = ${u.id}`;
      return rows.map((r) => ({ id: r.id as string, verified: r.verified_at !== null }));
    },
    async mfaEnroll() {
      const u = await this.currentUser(); if (!u) return { ok: false as const, message: 'Sign in first.' };
      await sql`delete from local_auth.factors where user_id = ${u.id} and verified_at is null`;
      const id = randomUUID(); const secret = newSecret();
      await sql`insert into local_auth.factors (id, user_id, secret) values (${id}, ${u.id}, ${secret})`;
      return { ok: true as const, factorId: id, secret, uri: otpauthUri(secret, u.email), qr: null };
    },
    async mfaVerify(factorId, code) {
      const u = await this.currentUser(); if (!u) return { ok: false as const, message: 'Sign in first.' };
      const rows = await sql`select secret from local_auth.factors where id = ${factorId} and user_id = ${u.id}`;
      if (!rows[0] || !checkCode(rows[0].secret as string, code)) return { ok: false as const, message: 'That code did not match. Enter the newest code from the app.' };
      await sql`update local_auth.factors set verified_at = coalesce(verified_at, now()) where id = ${factorId}`;
      await setSession(u, 'aal2');
      return { ok: true as const };
    },
    async signUp(email, password) {
      const e = email.trim().toLowerCase();
      const exists = await sql`select 1 from local_auth.users where email = ${e}`;
      if (exists.length) return { ok: false, code: 'exists', message: 'An account with this email already exists. Sign in, or use "Forgot password" to set a new password.' };
      const id = randomUUID();
      await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${e}, ${await hashPassword(password)}, null)`;
      await this.resendConfirmation(e, '');
      // as on Supabase with confirmations on: no session until the link is opened
      return { ok: true, user: { id, email: e }, needsConfirmation: true };
    },
    async confirmEmail(tokenHash) {
      const rows = await sql`
        update local_auth.reset_tokens t set used_at = now() from local_auth.users u
         where t.token_hash = ${hashToken(tokenHash)} and t.kind = 'signup' and t.used_at is null and t.expires_at > now() and u.id = t.user_id
         returning u.id, u.email`;
      const r = rows[0];
      if (!r) return { ok: false, message: 'This link has expired or was already used.' };
      await sql`update local_auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = ${r.id as string}`;
      const user = { id: r.id as string, email: r.email as string };
      await setSession(user);
      return { ok: true, user };
    },
    async signIn(email, password) {
      const e = email.trim().toLowerCase();
      const rows = await sql`select id, email, password_hash, email_confirmed_at from local_auth.users where email = ${e}`;
      const r = rows[0];
      if (!r || !(await checkPassword(password, r.password_hash as string))) return { ok: false, code: 'credentials', message: 'That email and password do not match an account.' };
      if (!r.email_confirmed_at) return { ok: false, code: 'unconfirmed', message: UNCONFIRMED };
      await sql`update local_auth.users set last_sign_in_at = now() where id = ${r.id as string}`;
      const user = { id: r.id as string, email: r.email as string };
      await setSession(user);
      return { ok: true, user };
    },
    async signOut() {
      (await cookies()).delete(COOKIE);
      (await cookies()).delete(HINT);
    },
    async requestPasswordReset(email, redirectTo) {
      const e = email.trim().toLowerCase();
      const rows = await sql`select id from local_auth.users where email = ${e}`;
      if (!rows[0]) return;
      const token = randomBytes(24).toString('base64url');
      await sql`insert into local_auth.reset_tokens (token_hash, user_id, expires_at) values (${hashToken(token)}, ${rows[0].id as string}, now() + make_interval(hours => ${LINK_HOURS}))`;
      const link = `${redirectTo}${redirectTo.includes('?') ? '&' : '?'}token=${token}`;
      await sql`insert into local_auth.mailbox (to_email, subject, body, link) values (${e}, 'Reset your CarmaCars password', ${'Open this link to choose a new password: ' + link}, ${link})`;
    },
    async invite(email, _fullName, redirectTo) {
      const e = email.trim().toLowerCase();
      const found = await sql`select id, password_hash from local_auth.users where email = ${e}`;
      // an address that already signs in is not invited again (Supabase refuses it the same way)
      if (found[0] && !String(found[0].password_hash).startsWith('invited$')) return { ok: false, code: 'exists', message: 'An account with this email already exists.' };
      const id = (found[0]?.id as string | undefined) ?? randomUUID();
      // an unusable password until the invited person chooses one through the emailed link
      if (!found[0]) await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${e}, ${'invited$' + randomBytes(16).toString('hex')})`;
      await this.requestPasswordReset(e, redirectTo);
      return { ok: true, user: { id, email: e } };
    },
    async createForRecord(userId, email, _fullName, redirectTo) {
      const e = email.trim().toLowerCase();
      const found = await sql`select 1 from local_auth.users where id = ${userId} or email = ${e}`;
      if (found.length) return { ok: false, code: 'exists', message: 'An account with this email already exists.' };
      await sql`insert into local_auth.users (id, email, password_hash) values (${userId}, ${e}, ${'invited$' + randomBytes(16).toString('hex')})`;
      await this.requestPasswordReset(e, redirectTo);
      return { ok: true, user: { id: userId, email: e }, needsConfirmation: true };
    },
    async accountLink(email, _fullName, next, userId) {
      const e = email.trim().toLowerCase();
      const found = await sql`select id, password_hash from local_auth.users where email = ${e}`;
      if (found[0] && !String(found[0].password_hash).startsWith('invited$')) return { ok: false, code: 'exists', message: 'An account with this email already exists.' };
      const id = (found[0]?.id as string | undefined) ?? userId ?? randomUUID();
      if (!found[0]) await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${e}, ${'invited$' + randomBytes(16).toString('hex')})`;
      const token = randomBytes(24).toString('base64url');
      await sql`insert into local_auth.reset_tokens (token_hash, user_id, expires_at) values (${hashToken(token)}, ${id}, now() + make_interval(hours => ${LINK_HOURS}))`;
      const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
      return { ok: true, user: { id, email: e }, link: `${base}/update-password?token=${token}&next=${encodeURIComponent(next)}` };
    },
    async deleteAccount(userId) {
      await sql`delete from local_auth.users where id = ${userId}`;
    },
    async resendConfirmation(email) {
      // a new link for an account still waiting for its confirmation (nothing for any other address, as on Supabase)
      const e = email.trim().toLowerCase();
      const rows = await sql`select id from local_auth.users where email = ${e} and email_confirmed_at is null`;
      if (!rows[0]) return;
      const token = randomBytes(24).toString('base64url');
      await sql`insert into local_auth.reset_tokens (token_hash, user_id, expires_at, kind) values (${hashToken(token)}, ${rows[0].id as string}, now() + make_interval(hours => ${LINK_HOURS}), 'signup')`;
      // the link of the Supabase template (scripts/deploy/auth-templates.mjs): no next, the person lands in their portal
      const link = `${env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '')}/auth/callback?token_hash=${token}&type=signup`;
      await sql`insert into local_auth.mailbox (to_email, subject, body, link) values (${e}, 'Confirm your CarmaCars account', ${'Open this link to confirm your email: ' + link}, ${link})`;
    },
    async updatePassword(password, token) {
      if (!token) return { ok: false, message: 'This link has expired or was already used. Ask for a new one below.' };
      const rows = await sql`
        update local_auth.reset_tokens t set used_at = now() from local_auth.users u
         where t.token_hash = ${hashToken(token)} and t.kind = 'recovery' and t.used_at is null and t.expires_at > now() and u.id = t.user_id
         returning u.id, u.email`;
      const r = rows[0];
      if (!r) return { ok: false, message: 'This link has expired or was already used. Ask for a new one below.' };
      // the emailed link proved the address, as Supabase's recovery and invitation links do
      await sql`update local_auth.users set password_hash = ${await hashPassword(password)}, email_confirmed_at = coalesce(email_confirmed_at, now()) where id = ${r.id as string}`;
      const user = { id: r.id as string, email: r.email as string };
      await setSession(user);
      return { ok: true, user };
    }
  };
}
