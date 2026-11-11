// r35 UX (1110): what a renter may do with their name and date of birth. Pure; identity.test.ts.
export type IdentityMode = 'edit' | 'request' | 'pending';
export function identityMode(d: { identity_locked: boolean; pending: unknown | null }): IdentityMode {
  if (d.pending) return 'pending';
  return d.identity_locked ? 'request' : 'edit';
}
