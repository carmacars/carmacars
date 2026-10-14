// Keeps a Supabase session alive before the app sees the request (custom-worker.ts on Cloudflare).
//
// Why here: a page is a server component, and a server component cannot set cookies. When the access token (one
// hour) has expired, Supabase's client refreshes it during the render, the new tokens are thrown away, and the
// refresh token it used is now spent. The next page, more than 10 seconds later, presents the spent token;
// Supabase treats that as a stolen token and ends the session: the person is signed out about an hour after
// signing in. Refreshing here, where the response can carry Set-Cookie, keeps the session, and the app then always
// sees a fresh token (and can verify it without a round trip to Supabase Auth).
import { cookieHeader, expiresAt, parseCookieHeader, readSession, sessionCookies, setCookie, type StoredSession } from './session-cookie.ts';

export interface RefreshConfig { url: string; anonKey: string; fetch?: typeof fetch; now?: () => number }
export interface RefreshResult { request: Request; setCookies: string[]; outcome: 'refreshed' | 'signed_out' }

const MARGIN_S = 120;
const inflight = new Map<string, Promise<{ ok: true; session: StoredSession } | { ok: false; fatal: boolean }>>();

async function refreshToken(cfg: RefreshConfig, token: string) {
  const hit = inflight.get(token);
  if (hit) return hit;
  const p = (async () => {
    try {
      const r = await (cfg.fetch ?? fetch)(`${cfg.url.replace(/\/$/, '')}/auth/v1/token?grant_type=refresh_token`, {
        method: 'POST', headers: { apikey: cfg.anonKey, authorization: `Bearer ${cfg.anonKey}`, 'content-type': 'application/json' },
        body: JSON.stringify({ refresh_token: token })
      });
      if (r.ok) {
        const s = (await r.json()) as StoredSession;
        if (typeof s.access_token !== 'string' || typeof s.refresh_token !== 'string') return { ok: false as const, fatal: false };
        if (typeof s.expires_at !== 'number' && typeof s.expires_in === 'number') s.expires_at = Math.floor((cfg.now?.() ?? Date.now()) / 1000) + s.expires_in;
        return { ok: true as const, session: s };
      }
      // 400 or 401: the refresh token is spent, revoked or unknown: the session is over (sign in again)
      return { ok: false as const, fatal: r.status === 400 || r.status === 401 };
    } catch {
      return { ok: false as const, fatal: false };
    }
  })();
  inflight.set(token, p);
  // kept 10 seconds, so the pages a browser asks for at once share one refresh (Supabase allows a spent token for 10 seconds too)
  void p.finally(() => { const t = setTimeout(() => inflight.delete(token), 10_000) as unknown as { unref?: () => void }; t.unref?.(); });
  return p;
}

/** null: nothing to do (no session, or the token is still good, or Supabase could not be reached). */
export async function refreshSession(request: Request, cfg: RefreshConfig): Promise<RefreshResult | null> {
  const header = request.headers.get('cookie');
  if (!header || !header.includes('-auth-token')) return null;
  const cookies = parseCookieHeader(header);
  const found = readSession(cookies);
  if (!found) return null;
  const exp = expiresAt(found.session);
  const now = Math.floor((cfg.now?.() ?? Date.now()) / 1000);
  if (exp !== null && exp - now > MARGIN_S) return null;
  const secure = new URL(request.url).protocol === 'https:';
  const r = await refreshToken(cfg, found.session.refresh_token);
  if (!r.ok && !r.fatal) return null;
  for (const n of found.names) cookies.delete(n);
  const setCookies: string[] = [];
  let keep = new Set<string>();
  if (r.ok) {
    const fresh = sessionCookies(found.base, r.session);
    keep = new Set(fresh.map((c) => c.name));
    for (const c of fresh) { cookies.set(c.name, c.value); setCookies.push(setCookie(c.name, c.value, secure)); }
  }
  for (const n of found.names) if (!keep.has(n)) setCookies.push(setCookie(n, '', secure, 0));
  const headers = new Headers(request.headers);
  if (cookies.size) headers.set('cookie', cookieHeader(cookies)); else headers.delete('cookie');
  return { request: new Request(request, { headers }), setCookies, outcome: r.ok ? 'refreshed' : 'signed_out' };
}
