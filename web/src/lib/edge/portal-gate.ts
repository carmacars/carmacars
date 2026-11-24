// R48 integration: the staff portals' sign-in redirect, answered at the edge as a real 307.
// A segment loading.tsx (release 48 PF added them across the portals) wraps the page in a Suspense boundary, so a
// redirect() or notFound() thrown by the page streams as HTTP 200 (a meta refresh, a soft 404). The pages of /admin and
// /staff all need a signed-in staff member (their own check stays: role, two-step), so a document request with no
// session cookie is sent to sign in here, before the app renders. RSC requests and prefetches keep the app's own
// redirect (the client router follows it). The owner, renter and investor portals have pages opened from emailed links
// without a session (signing, reviews), so they keep the page's check.
import { hasSession } from './page-cache.ts';

export const GATED_PORTALS = ['/admin', '/staff'] as const;

/** The request's path, set by the fronts (Worker, VPS, serve.mjs) on every portal request and never taken from the
 * client, so a portal layout (above the segment loading.tsx) can refuse with a real 307 or 404 (server/portal-access.ts). */
export const PATH_HEADER = 'x-cc-path';
const PORTAL_PATH = /^\/(admin|staff|owner|investor)(\/|$)/;
/** The value of PATH_HEADER: the path and query of a portal page, else null (the header is then removed). */
export function portalPathHeader(pathname: string, search = ''): string | null {
  return PORTAL_PATH.test(pathname) ? pathname + (search.startsWith('?') ? search : search ? `?${search}` : '') : null;
}

// the local stack's session (src/lib/auth/local.ts): CI and local runs sign in with it, not the Supabase cookie
const LOCAL_SESSION = /(?:^|;\s*)cc-local-session=/;

/** The sign-in address for a request that needs one, or null. */
export function portalSignIn(method: string, url: string, headers: { get(name: string): string | null }): string | null {
  if (method !== 'GET' && method !== 'HEAD') return null;
  const u = new URL(url);
  if (!GATED_PORTALS.some((p) => u.pathname === p || u.pathname.startsWith(p + '/'))) return null;
  if (headers.get('rsc') === '1' || headers.get('next-router-prefetch') || headers.get('next-action')) return null;
  const cookie = headers.get('cookie');
  if (hasSession(cookie) || LOCAL_SESSION.test(cookie ?? '')) return null;
  return `/sign-in?next=${encodeURIComponent(u.pathname + u.search)}`;
}
