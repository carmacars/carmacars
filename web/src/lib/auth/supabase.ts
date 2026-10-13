import 'server-only';
import { supabaseServer } from '@/lib/supabase/server';
import type { AuthAdapter } from './types';

const plain = (m: string) => (/invalid login/i.test(m) ? 'That email and password do not match an account.' : m);

export function supabaseAuth(): AuthAdapter {
  return {
    async currentUser() {
      const s = await supabaseServer();
      const { data } = await s.auth.getUser();
      return data.user ? { id: data.user.id, email: data.user.email ?? '' } : null;
    },
    async accessToken() {
      const s = await supabaseServer();
      const { data } = await s.auth.getSession();
      return data.session?.access_token ?? null;
    },
    async assurance() {
      const s = await supabaseServer();
      const { data } = await s.auth.mfa.getAuthenticatorAssuranceLevel();
      return data?.currentLevel === 'aal2' ? 'aal2' : data?.currentLevel === 'aal1' ? 'aal1' : null;
    },
    async signUp(email, password, meta) {
      const s = await supabaseServer();
      const { env } = await import('@/lib/env');
      const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
      const { data, error } = await s.auth.signUp({ email, password, options: { data: meta, emailRedirectTo: `${base}/auth/callback?next=/account` } });
      if (error || !data.user) return { ok: false, message: plain(error?.message ?? 'We could not create the account.') };
      // Supabase answers an existing address with a user that has no identities (it never says so outright).
      if (Array.isArray(data.user.identities) && data.user.identities.length === 0) {
        return { ok: false, message: 'An account with this email already exists. Sign in, or use "Forgot password" to set a new password.' };
      }
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? email }, needsConfirmation: !data.session };
    },
    async signIn(email, password) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.signInWithPassword({ email, password });
      if (error || !data.user) return { ok: false, message: plain(error?.message ?? 'We could not sign you in.') };
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? email } };
    },
    async signOut() {
      const s = await supabaseServer();
      await s.auth.signOut();
    },
    async requestPasswordReset(email, redirectTo) {
      const s = await supabaseServer();
      await s.auth.resetPasswordForEmail(email, { redirectTo });
    },
    async invite(email, fullName, redirectTo) {
      const { createClient } = await import('@supabase/supabase-js');
      const { required } = await import('@/lib/env');
      const admin = createClient(required('NEXT_PUBLIC_SUPABASE_URL'), required('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false, autoRefreshToken: false } });
      const { data, error } = await admin.auth.admin.inviteUserByEmail(email, { redirectTo, data: { full_name: fullName } });
      if (error || !data.user) return { ok: false, message: error?.message ?? 'We could not invite this person.' };
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? email } };
    },
    async updatePassword(password) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.updateUser({ password });
      if (error || !data.user) return { ok: false, message: error?.message ?? 'The reset link has expired. Ask for a new one.' };
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
