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

const unb64 = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4)), (c) => c.charCodeAt(0));
/** The clear value of encryptField's output (r35, 0931: Finance and Admin read a staff SIN; every read is logged by the database first). */
export async function decryptField(sealed: string): Promise<string> {
  const m = /^v(\d+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(sealed);
  if (!m || Number(m[1]) !== PAYOUT_KEY_VERSION) throw new Error('This value cannot be read with the current key.');
  const raw = await crypto.subtle.digest('SHA-256', enc.encode(secret()));
  const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['decrypt']);
  const out = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(m[2]!) }, key, unb64(m[3]!));
  return new TextDecoder().decode(out);
}
