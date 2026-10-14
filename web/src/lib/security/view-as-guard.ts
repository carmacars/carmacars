// "View as" (an Admin opening another person's portal) is read only. This is the hard stop, run on every request
// before the app (custom-worker.ts on Cloudflare; scripts/serve.mjs has the same rule locally): while the view-as
// cookie is present, anything but a read is refused, except in the Admin portal itself (where the Admin acts as
// themselves) and the view-as start and exit. Server actions are POST requests, so every one of them is covered,
// whatever the page. The app checks again where it reads as the other person (src/server/view-as.ts). No imports.

export const VIEW_AS_COOKIE = 'cc-view-as';
/** Not httpOnly: the banner reads the name from it. It carries no authority; the signed cookie above does. */
export const VIEW_AS_UI_COOKIE = 'cc-view-as-ui';

const READ = new Set(['GET', 'HEAD', 'OPTIONS']);
/** Set by the Worker entry (and serve.mjs) on requests for the Admin portal, where view-as does not apply: the Admin is
 *  themselves there. Any copy the browser sends is removed first. It can only take view-as away, never give it. */
export const ADMIN_AREA_HEADER = 'x-cc-admin-area';
export const isAdminArea = (pathname: string) => /^\/admin(\/|$)/.test(pathname);

export function hasViewAsCookie(cookieHeader: string | null | undefined): boolean {
  return !!cookieHeader && cookieHeader.split(';').some((p) => p.trim().startsWith(`${VIEW_AS_COOKIE}=`) && p.trim().length > VIEW_AS_COOKIE.length + 1);
}

/** True when the request must be refused: a write while viewing as someone else, outside the Admin portal. */
export function viewAsWriteRefused(method: string, pathname: string, cookieHeader: string | null | undefined): boolean {
  if (READ.has(method.toUpperCase())) return false;
  if (!hasViewAsCookie(cookieHeader)) return false;
  if (isAdminArea(pathname) || pathname.startsWith('/api/view-as/') || pathname.startsWith('/api/webhooks/')) return false;
  return true;
}

export const VIEW_AS_REFUSAL = 'Read only. You are viewing CarmaCars as another person, so nothing can be changed. Use Exit on the red banner to go back to your own account.';

/** The answer to a refused write. A server action (the Next-Action header) is sent to the read-only page, the way the
 *  app itself redirects from an action; anything else gets a plain 403. */
export function viewAsRefusal(isServerAction: boolean, headers: Record<string, string>): Response {
  if (isServerAction) return new Response('', { status: 200, headers: { ...headers, 'content-type': 'text/plain', 'cache-control': 'no-store', 'x-action-redirect': '/read-only;push' } });
  return new Response(VIEW_AS_REFUSAL, { status: 403, headers: { ...headers, 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } });
}
