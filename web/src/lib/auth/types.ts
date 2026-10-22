export interface SessionUser { id: string; email: string; phone?: string | null }
export type AuthResult = { ok: true; user: SessionUser; needsConfirmation?: boolean } | { ok: false; message: string; code?: AuthFailure };
/** Why a sign-in or an invitation failed, where the page says more than the message (never "no such account"). */
export type AuthFailure = 'credentials' | 'unconfirmed' | 'rate_limited' | 'exists' | 'inactive';

/** Asking for a texted code (0091). Never says whether the number has an account. */
export type PhoneCodeResult = { ok: true } | { ok: false; code: 'rate_limited' | 'send_failed' | 'refused'; message: string };

export interface AuthAdapter {
  currentUser(): Promise<SessionUser | null>;
  /** The session's access token (the JWT the database API checks), or null when signed out. */
  accessToken(): Promise<string | null>;
  /** The session's assurance level: aal2 after a second factor (two-step sign-in). */
  assurance(): Promise<'aal1' | 'aal2' | null>;
  signUp(email: string, password: string, meta: { full_name: string }): Promise<AuthResult>;
  signIn(email: string, password: string): Promise<AuthResult>;
  /** Ends this device's session only (other devices stay signed in). */
  signOut(): Promise<void>;
  /** Sends the reset email. Always resolves, so the response never says whether an account exists. */
  requestPasswordReset(email: string, redirectTo: string): Promise<void>;
  /** Sends the "confirm your email" link again (an account created and not yet confirmed). Always resolves. */
  resendConfirmation(email: string, redirectTo: string): Promise<void | 'rate_limited'>;
  /** With a token from the email (local), or with the session the reset link created (Supabase). */
  updatePassword(password: string, token?: string): Promise<AuthResult>;
  /** Server only (an Admin inviting someone): creates the account and emails a link to choose a password.
   *  code 'exists' when the address already has a sign-in. */
  invite?(email: string, fullName: string, redirectTo: string): Promise<AuthResult>;
  /** Server only: a sign-in for a record that is already on file (its id), then a link to choose a password. */
  createForRecord?(userId: string, email: string, fullName: string, redirectTo: string): Promise<AuthResult>;
  /** Server only (staff set up an owner's car, 0067): a sign-in for the address (the record's id when one is on file)
   *  and a one-time link to choose a password, returned instead of emailed, so it goes in CarmaCars' own email. */
  accountLink?(email: string, fullName: string, next: string, userId?: string | null): Promise<{ ok: true; user: SessionUser; link: string } | { ok: false; message: string; code?: AuthFailure }>;
  /** Local stand-in only: checks a sign-up confirmation link (Supabase checks its own in the callback). */
  confirmEmail?(tokenHash: string): Promise<AuthResult>;
  /** Server only: removes a sign-in account (one this request created and could not finish). */
  deleteAccount?(userId: string): Promise<void>;
  /** Sign-in by phone (0091): the sign-in service texts a 6-digit code (through our SMS hook). The account of that
   *  number is made at its first verified code, so the answer is the same whether or not it exists. */
  sendPhoneCode(phone: string): Promise<PhoneCodeResult>;
  /** Checks the code; on success the session is the number's account (new when the number had none). */
  verifyPhoneCode(phone: string, code: string): Promise<AuthResult>;
  /** Signed in: texts a code to a number to add to this account. A number of another account gets no text and the
   *  same answer (the code then never matches). */
  startPhoneChange(phone: string): Promise<PhoneCodeResult>;
  /** Signed in: checks that code; the number is then this account's (it can sign in with it). */
  verifyPhoneChange(phone: string, code: string): Promise<AuthResult>;
  /** Signed in, an account made by phone: its email (for receipts and email sign-in); a link to confirm it is emailed. */
  setEmail(email: string): Promise<{ ok: true } | { ok: false; code?: AuthFailure; message: string }>;
  /** Two-step sign-in (TOTP): the signed-in user's verified authenticator factors. */
  mfaFactors(): Promise<Array<{ id: string; verified: boolean }>>;
  /** Starts enrolment: a new factor with its secret and otpauth link (and a QR code image on Supabase). */
  mfaEnroll(): Promise<{ ok: true; factorId: string; secret: string; uri: string; qr: string | null } | { ok: false; message: string }>;
  /** Checks a code for a factor (enrolment or sign-in); on success the session is aal2. */
  mfaVerify(factorId: string, code: string): Promise<{ ok: true } | { ok: false; message: string }>;
}
