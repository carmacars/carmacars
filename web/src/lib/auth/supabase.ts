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
    async signUp(email, password, meta) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.signUp({ email, password, options: { data: meta } });
      if (error || !data.user) return { ok: false, message: plain(error?.message ?? 'We could not create the account.') };
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? email } };
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
    async updatePassword(password) {
      const s = await supabaseServer();
      const { data, error } = await s.auth.updateUser({ password });
      if (error || !data.user) return { ok: false, message: error?.message ?? 'The reset link has expired. Ask for a new one.' };
      return { ok: true, user: { id: data.user.id, email: data.user.email ?? '' } };
    }
  };
}
