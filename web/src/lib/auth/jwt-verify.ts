// Verifies a Supabase access token on the server without a round trip to Supabase Auth: the project signs tokens
// with an asymmetric key (ES256, or RS256), whose public half is published at /auth/v1/.well-known/jwks.json. The
// keys are fetched once per Worker isolate and kept for ten minutes; the check is one WebCrypto verify. A token the
// keys cannot check (an older HS256 token, or the key set not reachable) returns null, and the caller asks Supabase
// Auth instead. No imports, so the unit test runs it in Node.

export interface AccessClaims { sub: string; email?: string; aal?: string; role?: string; exp: number; [k: string]: unknown }

type Jwk = JsonWebKey & { kid?: string; alg?: string };
let jwks: { url: string; at: number; keys: Jwk[] } | null = null;
const imported = new Map<string, Promise<CryptoKey | null>>();
const TTL_MS = 10 * 60 * 1000;

const b64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));

async function keys(url: string, f: typeof fetch, now: number): Promise<Jwk[]> {
  if (jwks && jwks.url === url && now - jwks.at < TTL_MS) return jwks.keys;
  const r = await f(`${url.replace(/\/$/, '')}/auth/v1/.well-known/jwks.json`);
  if (!r.ok) throw new Error(`jwks ${r.status}`);
  const body = (await r.json()) as { keys?: Jwk[] };
  jwks = { url, at: now, keys: Array.isArray(body.keys) ? body.keys : [] };
  imported.clear();
  return jwks.keys;
}

function importKey(k: Jwk): Promise<CryptoKey | null> {
  const id = `${k.kid ?? ''}:${k.alg ?? ''}`;
  let p = imported.get(id);
  if (!p) {
    const algo = k.kty === 'EC' ? { name: 'ECDSA', namedCurve: k.crv ?? 'P-256' } : k.kty === 'RSA' ? { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' } : null;
    const jwk: JsonWebKey = Object.fromEntries(Object.entries({ kty: k.kty, crv: k.crv, x: k.x, y: k.y, n: k.n, e: k.e }).filter(([, v]) => v !== undefined));
    p = algo ? crypto.subtle.importKey('jwk', jwk, algo, false, ['verify']).catch(() => null) : Promise.resolve(null);
    imported.set(id, p);
  }
  return p;
}

/** The token's claims when its signature, issuer, audience and expiry check out; otherwise null. */
export async function verifyAccessToken(token: string, supabaseUrl: string, opts: { fetch?: typeof fetch; now?: number } = {}): Promise<AccessClaims | null> {
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  try {
    const header = JSON.parse(new TextDecoder().decode(b64u(parts[0]!))) as { alg?: string; kid?: string };
    if (header.alg !== 'ES256' && header.alg !== 'RS256') return null;
    const now = opts.now ?? Date.now();
    const list = await keys(supabaseUrl, opts.fetch ?? fetch, now);
    const jwk = list.find((k) => k.kid === header.kid && (!k.alg || k.alg === header.alg));
    if (!jwk) return null;
    const key = await importKey(jwk);
    if (!key) return null;
    const algo = header.alg === 'ES256' ? { name: 'ECDSA', hash: 'SHA-256' } : { name: 'RSASSA-PKCS1-v1_5' };
    const ok = await crypto.subtle.verify(algo, key, b64u(parts[2]!), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    if (!ok) return null;
    const c = JSON.parse(new TextDecoder().decode(b64u(parts[1]!))) as AccessClaims & { aud?: string | string[]; iss?: string };
    const aud = Array.isArray(c.aud) ? c.aud : [c.aud];
    if (typeof c.exp !== 'number' || c.exp * 1000 <= now) return null;
    if (!aud.includes('authenticated') || c.role !== 'authenticated') return null;
    if (c.iss && c.iss !== `${supabaseUrl.replace(/\/$/, '')}/auth/v1`) return null;
    if (typeof c.sub !== 'string' || !/^[0-9a-f-]{36}$/i.test(c.sub)) return null;
    return c;
  } catch {
    return null;
  }
}

/** Tests only. */
export function resetJwksCache() { jwks = null; imported.clear(); }
