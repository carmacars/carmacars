export interface SessionUser { id: string; email: string }
export type AuthResult = { ok: true; user: SessionUser } | { ok: false; message: string };

export interface AuthAdapter {
  currentUser(): Promise<SessionUser | null>;
  /** The session's assurance level: aal2 after a second factor (two-step sign-in). */
  assurance(): Promise<'aal1' | 'aal2' | null>;
  signUp(email: string, password: string, meta: { full_name: string }): Promise<AuthResult>;
  signIn(email: string, password: string): Promise<AuthResult>;
  signOut(): Promise<void>;
  /** Sends the reset email. Always resolves, so the response never says whether an account exists. */
  requestPasswordReset(email: string, redirectTo: string): Promise<void>;
  /** With a token from the email (local), or with the session the reset link created (Supabase). */
  updatePassword(password: string, token?: string): Promise<AuthResult>;
}
