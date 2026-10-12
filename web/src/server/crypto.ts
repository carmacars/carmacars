import 'server-only';
import { env } from '@/lib/env';

// Field encryption for values that must never sit in the database in clear: an owner's payout
// account number (owner_payout_accounts.account_no, 0022: "application-layer encrypted").
// AES-256-GCM with WebCrypto (runs in the Worker); the key is SHA-256 of PAYOUT_ENCRYPTION_KEY.
// Stored as v1.<iv>.<ciphertext>, base64url; key_version 1 goes with it.
const enc = new TextEncoder();
const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
export const PAYOUT_KEY_VERSION = 1;

function secret(): string {
  const e = env();
  const k = e.PAYOUT_ENCRYPTION_KEY ?? (e.APP_ENV === 'production' ? undefined : 'local-only-payout-encryption-key-not-for-production');
  if (!k) throw new Error('Missing environment variable PAYOUT_ENCRYPTION_KEY');
  return k;
}

export async function encryptField(plain: string): Promise<string> {
  const raw = await crypto.subtle.digest('SHA-256', enc.encode(secret()));
  const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(plain)));
  return `v${PAYOUT_KEY_VERSION}.${b64(iv)}.${b64(ct)}`;
}
