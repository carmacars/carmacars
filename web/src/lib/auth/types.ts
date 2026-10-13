export interface SessionUser { id: string; email: string }
export type AuthResult = { ok: true; user: SessionUser; needsConfirmation?: boolean } | { ok: false; message: string };

export interface AuthAdapter {
  currentUser(): Promise<SessionUser | null>;
  /** The session's access token (the JWT the database API checks), or null when signed out. */
  accessToken(): Promise<string | null>;
  /** The session's assurance level: aal2 after a second factor (two-step sign-in). */
  assurance(): Promise<'aal1' | 'aal2' | null>;
  signUp(email: string, password: string, meta: { full_name: string }): Promise<AuthResult>;
  signIn(email: string, password: string): Promise<AuthResult>;
  signOut(): Promise<void>;
  /** Sends the reset email. Always resolves, so the response never says whether an account exists. */
  requestPasswordReset(email: string, redirectTo: string): Promise<void>;
  /** With a token from the email (local), or with the session the reset link created (Supabase). */
  updatePassword(password: string, token?: string): Promise<AuthResult>;
  /** Server only (an Admin inviting staff): creates the account and emails a link to choose a password. */
  invite?(email: string, fullName: string, redirectTo: string): Promise<AuthResult>;
  /** Two-step sign-in (TOTP): the signed-in user's verified authenticator factors. */
  mfaFactors(): Promise<Array<{ id: string; verified: boolean }>>;
  /** Starts enrolment: a new factor with its secret and otpauth link (and a QR code image on Supabase). */
  mfaEnroll(): Promise<{ ok: true; factorId: string; secret: string; uri: string; qr: string | null } | { ok: false; message: string }>;
  /** Checks a code for a factor (enrolment or sign-in); on success the session is aal2. */
  mfaVerify(factorId: string, code: string): Promise<{ ok: true } | { ok: false; message: string }>;
}
