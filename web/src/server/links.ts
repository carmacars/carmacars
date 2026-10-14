import 'server-only';
import { env } from '@/lib/env';

// Signed tokens for things that act without a session or must not be forged by the browser:
// an additional driver's signing link (72 hours), an upload ticket (5 minutes, bound to the exact
// storage key the server chose). HMAC-SHA256 over the JSON payload with LINK_SIGNING_KEY.
const enc = new TextEncoder();
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));

export function linkSecret(): string {
  const e = env();
  const k = e.LINK_SIGNING_KEY ?? (e.APP_ENV === 'production' ? undefined : e.LOCAL_AUTH_SECRET ?? 'local-only-link-signing-key-not-for-production');
  if (!k) throw new Error('Missing environment variable LINK_SIGNING_KEY');
  return k;
}

async function mac(data: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(linkSecret()), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64url(new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(data))));
}

export async function signToken(purpose: string, payload: Record<string, unknown>, ttlSeconds: number): Promise<string> {
  const body = b64url(enc.encode(JSON.stringify({ ...payload, p: purpose, exp: Math.floor(Date.now() / 1000) + ttlSeconds })));
  return `${body}.${await mac(body)}`;
}

/** A token valid until a set instant (an additional driver's link: the expiry is kept in the database, so the same
 *  link can be shown again until then). */
export async function signTokenUntil(purpose: string, payload: Record<string, unknown>, expiresAt: Date): Promise<string> {
  const body = b64url(enc.encode(JSON.stringify({ ...payload, p: purpose, exp: Math.floor(expiresAt.getTime() / 1000) })));
  return `${body}.${await mac(body)}`;
}

export async function readToken<T extends Record<string, unknown>>(purpose: string, token: string | null | undefined): Promise<T | null> {
  if (!token || !/^[\w-]+\.[\w-]+$/.test(token)) return null;
  const [body, sig] = token.split('.') as [string, string];
  const want = await mac(body);
  if (want.length !== sig.length) return null;
  let d = 0;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ sig.charCodeAt(i);
  if (d !== 0) return null;
  try {
    const p = JSON.parse(new TextDecoder().decode(unb64url(body))) as T & { p: string; exp: number };
    if (p.p !== purpose || typeof p.exp !== 'number' || p.exp < Math.floor(Date.now() / 1000)) return null;
    return p;
  } catch {
    return null;
  }
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as unknown as ArrayBuffer));
  return Array.from(h, (b) => b.toString(16).padStart(2, '0')).join('');
}
