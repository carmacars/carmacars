// The WebAuthn requests the phone's passkey sheet takes, built from what the server gives (a one-time challenge, the
// site's domain as the relying party). Face ID, fingerprint or the screen lock is always asked. No native imports here.
import type { PasskeyOptions } from '../shared.ts';

const PARAMS = [{ type: 'public-key' as const, alg: -7 }, { type: 'public-key' as const, alg: -257 }];
const b64u = (s: string) => {
  const bytes = Array.from(new TextEncoder().encode(s));
  const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const [a, b, c] = [bytes[i]!, bytes[i + 1], bytes[i + 2]];
    out += abc[a >> 2]! + abc[((a & 3) << 4) | ((b ?? 0) >> 4)]! + (b === undefined ? '' : abc[((b & 15) << 2) | ((c ?? 0) >> 6)]!) + (c === undefined ? '' : abc[c & 63]!);
  }
  return out;
};

export function createRequest(o: PasskeyOptions) {
  if (!o.user) throw new Error('Sign in first.');
  return {
    challenge: o.challenge, rp: { id: o.rp_id, name: o.rp_name },
    user: { id: b64u(o.user.id), name: o.user.name, displayName: o.user.display_name },
    pubKeyCredParams: PARAMS, timeout: 120_000, attestation: 'none' as const,
    excludeCredentials: (o.exclude ?? []).map((id) => ({ type: 'public-key' as const, id })),
    authenticatorSelection: { authenticatorAttachment: 'platform' as const, residentKey: 'required' as const, requireResidentKey: true, userVerification: 'required' as const }
  };
}
export function getRequest(o: PasskeyOptions) {
  return { challenge: o.challenge, rpId: o.rp_id, timeout: 120_000, userVerification: 'required' as const };
}
/** The person closed the sheet (not an error to show). */
export const cancelled = (e: unknown) => /cancel|abort|NotAllowed|UserCancelled|dismiss/i.test(String((e as { error?: string; message?: string } | null)?.error ?? (e as Error | null)?.message ?? e));
/** No passkey on this phone for the site: the sheet had nothing to offer. */
export const none = (e: unknown) => /NoCredentials|no credential|not found/i.test(String((e as { error?: string; message?: string } | null)?.error ?? (e as Error | null)?.message ?? e));
