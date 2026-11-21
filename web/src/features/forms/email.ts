// The one form of an account's email (r48 security audit, docs/security/audit-2026-11-r48.md): NFKC (a full-width or
// compatibility letter becomes the plain one), trimmed, lower case. Used at sign-in, sign-up and reset, on the website
// and in the native app's sign-in, so two ways of writing one address are never two accounts.
export const normalEmail = (v: string): string => v.normalize('NFKC').trim().toLowerCase();
/** A new account's address in printable ASCII only, so no address is made to look like another (a Cyrillic "а"). */
export const plainEmail = (v: string): boolean => /^[\x21-\x7e]+$/.test(v);
