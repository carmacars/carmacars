import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { siteUrl } from '@/lib/site';
import { hostingTarget } from '@/lib/platform/runtime';
import { googleKeys } from '@/server/reviews/google';
import { GSC_SCOPE, GscError, runGscSync, type Begin, type GscSummary } from '@/features/seo/gsc-sync';

// Google Search Console, read by the site itself (release 42, migration 2640). An Admin connects once (Marketing > SEO,
// "Connect Google Search Console"): OAuth with the site's Google client (the reviews client, GOOGLE_REVIEWS_CLIENT_ID and
// SECRET), the webmasters scope (read, and submit the sitemap), offline access; the refresh token goes to the vault.
// Once a day the tick runs /api/jobs/gsc (public.server_jobs_due, "gsc"): src/features/seo/gsc-sync.ts does the work
// with plain fetch, so it runs the same in the Worker and under Node. No token is ever logged.
const SR = { role: 'service_role' as const };
export const gscCallbackUrl = () => `${siteUrl()}/api/google/search-console/callback`;

export function gscConsentUrl(state: string): string | null {
  const k = googleKeys();
  if (!k) return null;
  const q = new URLSearchParams({ client_id: k.id, redirect_uri: gscCallbackUrl(), response_type: 'code', scope: `openid email ${GSC_SCOPE}`,
    access_type: 'offline', prompt: 'consent', include_granted_scopes: 'true', state });
  return `https://accounts.google.com/o/oauth2/v2/auth?${q}`;
}

/** The code from the consent screen: the refresh token and the account's address. */
export async function gscExchange(code: string, f: typeof fetch = fetch): Promise<{ refreshToken: string | null; email: string | null; scopeOk: boolean }> {
  const k = googleKeys();
  if (!k) throw new Error('The Google app keys are not set');
  const r = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ code, client_id: k.id, client_secret: k.secret, redirect_uri: gscCallbackUrl(), grant_type: 'authorization_code' }), signal: AbortSignal.timeout(15_000) });
  const d = (await r.json().catch(() => ({}))) as { refresh_token?: string; id_token?: string; scope?: string; error?: string };
  if (!r.ok) throw new Error(`Google refused the code (${d.error ?? r.status})`);
  let email: string | null = null;
  try { const part = d.id_token?.split('.')[1]; if (part) email = (JSON.parse(atob(part.replace(/-/g, '+').replace(/_/g, '/'))) as { email?: string }).email ?? null; } catch { email = null; }
  // the person may untick Search Console on Google's screen: then the connection could read nothing
  return { refreshToken: d.refresh_token ?? null, email, scopeOk: typeof d.scope !== 'string' || d.scope.split(/\s+/).includes(GSC_SCOPE) };
}

async function accessToken(refresh: string, f: typeof fetch): Promise<string> {
  const k = googleKeys();
  if (!k) throw new GscError('The Google app keys are not set (GOOGLE_REVIEWS_CLIENT_ID, GOOGLE_REVIEWS_CLIENT_SECRET)');
  const r = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: k.id, client_secret: k.secret, refresh_token: refresh, grant_type: 'refresh_token' }), signal: AbortSignal.timeout(15_000) });
  const d = (await r.json().catch(() => ({}))) as { access_token?: string; error?: string };
  if (!r.ok || !d.access_token) {
    if (d.error === 'invalid_grant') throw new GscError('Google no longer accepts the connection: connect Google Search Console again', true);
    throw new GscError(`Google refused the token (${d.error ?? r.status})`);
  }
  return d.access_token;
}

/** The day's sync, when it is due. A Worker has less room for outgoing requests than the server, so it inspects fewer pages a run. */
export async function runGscSyncNow(f: typeof fetch = fetch): Promise<GscSummary> {
  return runGscSync({
    begin: async () => (await rpc('server_gsc_sync_begin', {}, SR)) as unknown as Begin,
    finish: (p) => rpc('server_gsc_sync_finish', { p: p as unknown as Json }, SR),
    token: (refresh) => accessToken(refresh, f),
    fetch: f,
    base: siteUrl(),
    inspectRoom: hostingTarget() === 'node' ? 50 : 30
  });
}
