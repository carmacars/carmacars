// Password sign-in pauses for an address after repeated wrong passwords (migration 2770, public.server_sign_in_allowed).
// No imports. The database answers true or false; anything else (the function missing on an older database, the database
// unreachable) lets the sign-in through: the pause never locks everybody out because it could not be read.
export const SIGN_IN_PAUSED = 'Too many wrong passwords for this email. Wait 15 minutes and try again, or reset your password. You can also sign in with your phone number.';

/** True only when the database said this address is paused. */
export function signInPaused(answer: unknown): boolean {
  return answer === false;
}
