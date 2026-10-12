import 'server-only';
import { randomBytes, randomUUID, scrypt as scryptCb, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';
import { cookies } from 'next/headers';
import { SignJWT, jwtVerify } from 'jose';
import { required } from '@/lib/env';
import { localSql } from '@/lib/db/local';
import type { AuthAdapter, SessionUser } from './types';

// LOCAL ONLY. A stand-in for Supabase Auth on the local stack (local/local_auth.sql):
// scrypt password hashes, an HS256 session cookie with the same claims Supabase issues
// (sub, email, role "authenticated"), and reset links written to local_auth.mailbox.
const scrypt = promisify(scryptCb) as (p: string, s: Buffer, n: number) => Promise<Buffer>;
const COOKIE = 'cc-local-session';
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
async function setSession(u: SessionUser) {
  const jwt = await new SignJWT({ email: u.email, role: 'authenticated' }).setProtectedHeader({ alg: 'HS256' })
    .setSubject(u.id).setIssuedAt().setExpirationTime('7d').sign(key());
  (await cookies()).set(COOKIE, jwt, { httpOnly: true, sameSite: 'lax', path: '/', secure: false, maxAge: 7 * 86400 });
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
    async signUp(email, password) {
      const e = email.trim().toLowerCase();
      const exists = await sql`select 1 from local_auth.users where email = ${e}`;
      if (exists.length) return { ok: false, message: 'An account with this email already exists. Sign in instead.' };
      const id = randomUUID();
      await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${e}, ${await hashPassword(password)})`;
      const user = { id, email: e };
      await setSession(user);
      return { ok: true, user };
    },
    async signIn(email, password) {
      const e = email.trim().toLowerCase();
      const rows = await sql`select id, email, password_hash from local_auth.users where email = ${e}`;
      const r = rows[0];
      if (!r || !(await checkPassword(password, r.password_hash as string))) return { ok: false, message: 'That email and password do not match an account.' };
      await sql`update local_auth.users set last_sign_in_at = now() where id = ${r.id as string}`;
      const user = { id: r.id as string, email: r.email as string };
      await setSession(user);
      return { ok: true, user };
    },
    async signOut() {
      (await cookies()).delete(COOKIE);
    },
    async requestPasswordReset(email, redirectTo) {
      const e = email.trim().toLowerCase();
      const rows = await sql`select id from local_auth.users where email = ${e}`;
      if (!rows[0]) return;
      const token = randomBytes(24).toString('base64url');
      await sql`insert into local_auth.reset_tokens (token_hash, user_id, expires_at) values (${hashToken(token)}, ${rows[0].id as string}, now() + interval '1 hour')`;
      const link = `${redirectTo}${redirectTo.includes('?') ? '&' : '?'}token=${token}`;
      await sql`insert into local_auth.mailbox (to_email, subject, body, link) values (${e}, 'Reset your CarmaCars password', ${'Open this link to choose a new password: ' + link}, ${link})`;
    },
    async updatePassword(password, token) {
      if (!token) return { ok: false, message: 'The reset link has expired. Ask for a new one.' };
      const rows = await sql`
        update local_auth.reset_tokens t set used_at = now() from local_auth.users u
         where t.token_hash = ${hashToken(token)} and t.used_at is null and t.expires_at > now() and u.id = t.user_id
         returning u.id, u.email`;
      const r = rows[0];
      if (!r) return { ok: false, message: 'The reset link has expired. Ask for a new one.' };
      await sql`update local_auth.users set password_hash = ${await hashPassword(password)} where id = ${r.id as string}`;
      const user = { id: r.id as string, email: r.email as string };
      await setSession(user);
      return { ok: true, user };
    }
  };
}
