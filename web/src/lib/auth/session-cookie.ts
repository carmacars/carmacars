// The Supabase session cookie, read and written the way @supabase/ssr does (cookie name sb-<ref>-auth-token,
// value "base64-" + base64url(JSON), split into .0, .1, ... chunks above 3,180 characters), so the Worker entry
// (custom-worker.ts) can refresh a session before the app sees the request, and the server can read the signed-in
// user from the cookie without building a Supabase client. No imports: it runs in the Worker entry and in Node.

export interface StoredSession {
  access_token: string;
  refresh_token: string;
  expires_at?: number;
  expires_in?: number;
  token_type?: string;
  user?: { id: string; email?: string } & Record<string, unknown>;
  [k: string]: unknown;
}

const CHUNK = 3180;
const PREFIX = 'base64-';
export const isAuthCookie = (name: string) => /^sb-[a-z0-9]+-auth-token(\.\d+)?$/.test(name);
const baseName = (name: string) => name.replace(/\.\d+$/, '');

export function parseCookieHeader(header: string | null | undefined): Map<string, string> {
  const out = new Map<string, string>();
  for (const part of (header ?? '').split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    if (k && !out.has(k)) out.set(k, part.slice(i + 1).trim());
  }
  return out;
}

function b64urlToText(s: string): string {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
}
function textToB64url(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** The auth cookie's base name and every cookie name that belongs to it (the value or its chunks). */
export function authCookieNames(cookies: Map<string, string>): { base: string; names: string[] } | null {
  const names = [...cookies.keys()].filter(isAuthCookie).filter((n) => !n.endsWith('-code-verifier'));
  if (!names.length) return null;
  return { base: baseName(names[0]!), names: names.filter((n) => baseName(n) === baseName(names[0]!)) };
}

/** The stored session, or null when there is none or it cannot be read. */
export function readSession(cookies: Map<string, string>): { base: string; names: string[]; session: StoredSession } | null {
  const found = authCookieNames(cookies);
  if (!found) return null;
  let raw = cookies.get(found.base) ?? null;
  if (!raw) {
    const parts: string[] = [];
    for (let i = 0; cookies.has(`${found.base}.${i}`); i++) parts.push(cookies.get(`${found.base}.${i}`)!);
    raw = parts.length ? parts.join('') : null;
  }
  if (!raw) return null;
  try {
    const text = raw.startsWith(PREFIX) ? b64urlToText(raw.slice(PREFIX.length)) : decodeURIComponent(raw);
    const s = JSON.parse(text) as StoredSession;
    if (!s || typeof s.access_token !== 'string' || typeof s.refresh_token !== 'string') return null;
    return { ...found, session: s };
  } catch {
    return null;
  }
}

/** The cookies that store a session, as @supabase/ssr writes them. */
export function sessionCookies(base: string, session: StoredSession): Array<{ name: string; value: string }> {
  const value = PREFIX + textToB64url(JSON.stringify(session));
  if (value.length <= CHUNK) return [{ name: base, value }];
  const out: Array<{ name: string; value: string }> = [];
  for (let i = 0; i * CHUNK < value.length; i++) out.push({ name: `${base}.${i}`, value: value.slice(i * CHUNK, (i + 1) * CHUNK) });
  return out;
}

/** Seconds since the epoch at which the access token expires (from the stored value, or from the token). */
export function expiresAt(s: StoredSession): number | null {
  if (typeof s.expires_at === 'number') return s.expires_at;
  const claims = jwtClaims(s.access_token);
  return typeof claims?.exp === 'number' ? claims.exp : null;
}

export function jwtClaims(token: string): Record<string, unknown> | null {
  const p = token.split('.');
  if (p.length !== 3) return null;
  try { return JSON.parse(b64urlToText(p[1]!)) as Record<string, unknown>; } catch { return null; }
}
export function jwtHeader(token: string): Record<string, unknown> | null {
  const p = token.split('.');
  if (p.length !== 3) return null;
  try { return JSON.parse(b64urlToText(p[0]!)) as Record<string, unknown>; } catch { return null; }
}

export const cookieHeader = (cookies: Map<string, string>) => [...cookies].map(([k, v]) => `${k}=${v}`).join('; ');
export function setCookie(name: string, value: string, secure: boolean, maxAge = 400 * 86400): string {
  return `${name}=${value}; Path=/; Max-Age=${maxAge}; SameSite=Lax${secure ? '; Secure' : ''}`;
}
