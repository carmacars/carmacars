import 'server-only';
import { randomBytes, randomInt, randomUUID, scrypt as scryptCb, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';
import { cookies } from 'next/headers';
import { SignJWT, jwtVerify } from 'jose';
import { env, required } from '@/lib/env';
import { localSql } from '@/lib/db/local';
import type { AuthAdapter, SessionUser } from './types';
import type { OAuthProvider } from './oauth';
import { checkCode, newSecret, otpauthUri } from './totp';
import { deliverSignInCode } from '@/server/auth-sms';
import { smsCodeText } from '@/features/auth/sms-hook';

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
  const jwt = await new SignJWT({ email: u.email, ...(u.phone ? { phone: u.phone } : {}), role: 'authenticated', aal }).setProtectedHeader({ alg: 'HS256' })
    .setSubject(u.id).setIssuedAt().setExpirationTime('7d').sign(key());
  (await cookies()).set(COOKIE, jwt, { httpOnly: true, sameSite: 'lax', path: '/', secure: false, maxAge: 7 * 86400 });
  // readable by the page (no secret in it): the site's own scripts tell a signed-in visitor apart, as they can with
  // Supabase's session cookie (the discount game never shows to someone signed in)
  (await cookies()).set(HINT, '1', { httpOnly: false, sameSite: 'lax', path: '/', secure: false, maxAge: 7 * 86400 });
}

// Sign-in with a provider, faked (src/app/auth/oauth/fake/route.ts stands in for Google's consent page): the "code" is
// a 2-minute token signed with LOCAL_AUTH_SECRET naming the address the tester typed, whether the provider verified it,
// and the flow's state (so it only works in the browser that started the flow, as PKCE makes Supabase's code). Each
// code works once. The linking rules are Supabase Auth's: a verified address joins the account that has it (an
// unconfirmed account loses its password: its other identities are removed); a new address makes a new account.
const OAUTH_AUD = 'local-oauth';
const usedCodes = new Set<string>();
export async function localOAuthCode(c: { provider: OAuthProvider; email: string; name: string; verified: boolean; state: string }): Promise<string> {
  return new SignJWT({ email: c.email.trim().toLowerCase(), name: c.name, verified: c.verified, provider: c.provider, state: c.state, jti: randomUUID() })
    .setProtectedHeader({ alg: 'HS256' }).setAudience(OAUTH_AUD).setSubject(`${c.provider}:${c.email.trim().toLowerCase()}`).setIssuedAt().setExpirationTime('2m').sign(key());
}

const CODE_MINUTES = 5;
const BAD_CODE = 'That code does not match or has expired. Check the newest text from CarmaCars, or ask for a new code.';

export function localAuth(): AuthAdapter {
  const sql = localSql();
  const codeHash = (phone: string, code: string) => hashToken(`${phone}:${code}`);
  /** A code for the number, "texted" through the site's SMS sender (the fake Quo line here) and kept in the mailbox. */
  async function sendCode(phone: string, kind: 'sms' | 'phone_change', userId: string | null) {
    // one code a minute per number (Supabase's sms_max_frequency)
    const recent = await sql`select 1 from local_auth.otps where phone = ${phone} and created_at > now() - interval '60 seconds'`;
    if (recent.length) return { ok: false as const, code: 'rate_limited' as const, message: 'We texted a code less than a minute ago. Wait a minute before asking for another.' };
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    const owner = kind === 'sms' ? ((await sql`select id from local_auth.users where phone = ${phone} and phone_confirmed_at is not null`)[0]?.id as string | undefined) ?? null : userId;
    const sent = await deliverSignInCode({ phones: [phone], code, userId: owner });
    if (!sent.ok) return { ok: false as const, code: sent.reason === 'send_failed' || sent.reason === 'no_from_number' ? 'send_failed' as const : sent.reason === 'rate_limited' ? 'rate_limited' as const : 'refused' as const, message: sent.message };
    await sql`insert into local_auth.otps (phone, user_id, kind, code_hash, expires_at) values (${phone}, ${userId}, ${kind}, ${codeHash(phone, code)}, now() + make_interval(mins => ${CODE_MINUTES}))`;
    await sql`insert into local_auth.mailbox (to_email, to_phone, subject, body) values (null, ${phone}, 'Text: sign-in code', ${smsCodeText(code)})`;
    return { ok: true as const };
  }
  async function takeCode(phone: string, code: string, kind: 'sms' | 'phone_change', userId: string | null): Promise<boolean> {
    const rows = await sql`select id, code_hash, attempts from local_auth.otps
      where phone = ${phone} and kind = ${kind} and used_at is null and expires_at > now() and (${userId}::uuid is null or user_id = ${userId}::uuid)
      order by created_at desc limit 1`;
    const r = rows[0];
    if (!r) return false;
    if ((r.attempts as number) >= 5) return false;
    if (r.code_hash !== codeHash(phone, code)) { await sql`update local_auth.otps set attempts = attempts + 1 where id = ${r.id as number}`; return false; }
    await sql`update local_auth.otps set used_at = now() where id = ${r.id as number}`;
    return true;
  }
  return {
    async currentUser() {
      const t = (await cookies()).get(COOKIE)?.value;
      if (!t) return null;
      try {
        const { payload } = await jwtVerify(t, key());
        return payload.sub ? { id: payload.sub, email: String(payload.email ?? ''), phone: typeof payload.phone === 'string' ? payload.phone : null } : null;
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
    // ---------------------------------------------------------------- sign-in with a provider (faked)
    async oauthStart(provider, _redirectTo, state) {
      return { ok: true, url: `/auth/oauth/fake?provider=${provider}&state=${encodeURIComponent(state)}` };
    },
    async oauthExchange(code, state) {
      let c: { email?: unknown; name?: unknown; verified?: unknown; state?: unknown; jti?: unknown };
      try { c = (await jwtVerify(code, key(), { audience: OAUTH_AUD })).payload as typeof c; } catch { return { ok: false, message: 'The code was refused.' }; }
      if (c.state !== state || typeof c.jti !== 'string' || usedCodes.has(c.jti) || typeof c.email !== 'string') return { ok: false, message: 'The code was refused.' };
      usedCodes.add(c.jti);
      const e = c.email.trim().toLowerCase();
      const verified = c.verified === true;
      const name = typeof c.name === 'string' && c.name.trim() ? c.name.trim() : null;
      const found = (await sql`select id, email_confirmed_at from local_auth.users where email = ${e}`)[0];
      let id: string; let fresh = false;
      if (found && verified) {
        id = found.id as string;
        // Supabase removes the unconfirmed identities of the account it links to: a password chosen without confirming
        // the address no longer signs in (pre-account takeover)
        if (!found.email_confirmed_at) await sql`update local_auth.users set password_hash = ${'oauth$' + randomBytes(16).toString('hex')}, email_confirmed_at = now() where id = ${id}`;
      } else if (found) {
        return { ok: false, message: 'An account with this email exists; the provider did not verify the address.' };
      } else {
        id = randomUUID(); fresh = true;
        await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${e}, ${'oauth$' + randomBytes(16).toString('hex')}, ${verified ? new Date() : null})`;
      }
      await sql`update local_auth.users set last_sign_in_at = now() where id = ${id}`;
      const user = { id, email: e };
      await setSession(user);
      return { ok: true, user, emailVerified: verified, name, fresh };
    },
    async relinkToRecord(freshId, recordId, email) {
      const e = email.trim().toLowerCase();
      const taken = await sql`select 1 from local_auth.users where id = ${recordId}`;
      if (taken.length) return false;
      const gone = await sql`delete from local_auth.users where id = ${freshId} and password_hash like 'oauth$%' and created_at > now() - interval '10 minutes' returning id`;
      if (!gone.length) return false;
      await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${recordId}, ${e}, ${'oauth$' + randomBytes(16).toString('hex')}, now())`;
      return true;
    },
    // ---------------------------------------------------------------- phone (0091), as Supabase's phone provider
    async sendPhoneCode(phone) {
      return sendCode(phone, 'sms', null);
    },
    async verifyPhoneCode(phone, code) {
      const ok = await takeCode(phone, code, 'sms', null);
      if (!ok) return { ok: false, code: 'credentials', message: BAD_CODE };
      let rows = await sql`select id, email, phone from local_auth.users where phone = ${phone} and phone_confirmed_at is not null`;
      if (!rows[0]) {
        // the first verified code makes the account, as Supabase does with create_user
        const id = randomUUID();
        await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at, phone, phone_confirmed_at) values (${id}, null, ${'phone$' + randomBytes(16).toString('hex')}, null, ${phone}, now())`;
        rows = await sql`select id, email, phone from local_auth.users where id = ${id}`;
      }
      const r = rows[0]!;
      await sql`update local_auth.users set last_sign_in_at = now() where id = ${r.id as string}`;
      const user = { id: r.id as string, email: (r.email as string | null) ?? '', phone };
      await setSession(user);
      return { ok: true, user };
    },
    async startPhoneChange(phone) {
      const u = await this.currentUser();
      if (!u) return { ok: false, code: 'refused', message: 'Sign in first.' };
      const taken = await sql`select id from local_auth.users where phone = ${phone} and phone_confirmed_at is not null`;
      if (taken[0] && taken[0].id === u.id) return { ok: false, code: 'refused', message: 'This number is already on your account.' };
      // another account's number: the same answer, and no text (Supabase refuses it the same way)
      if (taken[0]) return { ok: true };
      return sendCode(phone, 'phone_change', u.id);
    },
    async verifyPhoneChange(phone, code) {
      const u = await this.currentUser();
      if (!u) return { ok: false, message: 'Sign in first.' };
      if (!(await takeCode(phone, code, 'phone_change', u.id))) return { ok: false, code: 'credentials', message: BAD_CODE };
      try {
        await sql`update local_auth.users set phone = ${phone}, phone_confirmed_at = now() where id = ${u.id}`;
      } catch {
        return { ok: false, code: 'credentials', message: BAD_CODE };
      }
      const user = { ...u, phone };
      await setSession(user, (await this.assurance()) ?? 'aal1');
      return { ok: true, user };
    },
    async setEmail(email) {
      const u = await this.currentUser();
      if (!u) return { ok: false, message: 'Sign in first.' };
      const e = email.trim().toLowerCase();
      const other = await sql`select 1 from local_auth.users where email = ${e} and id <> ${u.id}`;
      if (other.length) return { ok: false, code: 'exists', message: 'This email is already used by another account. Sign in with it instead, or use another email.' };
      const done = await sql`update local_auth.users set email = ${e}, email_confirmed_at = null where id = ${u.id} and (email is null or email_confirmed_at is null) returning id`;
      if (!done.length) return { ok: false, message: 'Your account already has a confirmed email.' };
      await this.resendConfirmation(e, '');
      return { ok: true };
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
    async openForCapture(userId, email) {
      const e = email.trim().toLowerCase();
      const found = await sql`select 1 from local_auth.users where id = ${userId} or email = ${e}`;
      if (found.length) return { ok: false, code: 'exists', message: 'An account with this email already exists.' };
      // as on Supabase: no usable password, the address not confirmed, no email sent
      await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${userId}, ${e}, ${'invited$' + randomBytes(16).toString('hex')}, null)`;
      return { ok: true, user: { id: userId, email: e }, needsConfirmation: true };
    },
    async claimForCapture(userId, email, password) {
      const e = email.trim().toLowerCase();
      const rows = await sql`update local_auth.users set password_hash = ${await hashPassword(password)}
                              where id = ${userId} and email = ${e} and email_confirmed_at is null returning id`;
      if (!rows[0]) return { ok: false, code: 'exists', message: 'An account with this email already exists.' };
      await this.resendConfirmation(e, '');
      return { ok: true, user: { id: userId, email: e }, needsConfirmation: true };
    },
    async continueLink(email, next) {
      const e = email.trim().toLowerCase();
      const rows = await sql`select id from local_auth.users where email = ${e}`;
      if (!rows[0]) return { ok: false, message: 'We could not make the sign-in link.' };
      const token = randomBytes(24).toString('base64url');
      await sql`insert into local_auth.reset_tokens (token_hash, user_id, expires_at, kind) values (${hashToken(token)}, ${rows[0].id as string}, now() + interval '1 hour', 'signup')`;
      const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
      return { ok: true, link: `${base}/auth/callback?token_hash=${token}&type=magiclink&next=${encodeURIComponent(next)}` };
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
    async adminSetEmail(userId, email) {
      const e = email.trim().toLowerCase();
      const other = await sql`select 1 from local_auth.users where email = ${e} and id <> ${userId}`;
      if (other.length) return { ok: false, code: 'exists', message: 'Another sign-in already uses this email.' };
      const done = await sql`update local_auth.users set email = ${e} where id = ${userId} returning id`;
      return done.length ? { ok: true } : { ok: true, none: true };
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
