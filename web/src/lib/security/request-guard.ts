// Release 35 (security audit): two checks run on every request before the app (custom-worker.ts on Cloudflare,
// scripts/serve.mjs locally). No imports.
//
// 1. A write from another site is refused. Every POST, PUT, PATCH and DELETE (server actions included: they are POSTs)
//    must come from a page of this site: the browser's Origin header (sent on every cross-origin write, and on same-origin
//    ones by current browsers) must name this host, and Sec-Fetch-Site must not say cross-site. The session cookies are
//    SameSite=Lax already; this is the second lock, the same for every route instead of a check per route. Senders that
//    are not browsers and prove themselves with a signature or a bearer token (webhooks, the jobs, the tracker, the
//    connector's OAuth and MCP endpoints, one-click unsubscribe from mail apps) are outside it: they send no Origin, and
//    their own check is stronger than this one.
// 2. Paths the app does not use and that carry known framework advisories answer 404 (the image optimizer: images come
//    pre-sized, next.config.ts images.unoptimized; GHSA-2464-fhr4-w9xw).

const WRITE = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

/** Routes that authenticate the sender themselves (signature or bearer token), so a missing or foreign Origin is fine. */
export const SIGNED_SENDER_PREFIXES = [
  '/api/webhooks/', '/api/inbound/', '/api/tracker/ingest', '/api/jobs/', '/api/oauth/', '/api/mcp', '/api/email/send', '/api/unsubscribe'
] as const;

const bare = (host: string) => host.toLowerCase().replace(/^www\./, '');

/** True when a write must be refused because it came from another site. */
export function crossSiteWriteRefused(method: string, url: string, origin: string | null | undefined, secFetchSite: string | null | undefined): boolean {
  if (!WRITE.has(method.toUpperCase())) return false;
  const u = new URL(url);
  if (SIGNED_SENDER_PREFIXES.some((p) => (p.endsWith('/') ? u.pathname.startsWith(p) : u.pathname === p || u.pathname.startsWith(`${p}/`)))) return false;
  if ((secFetchSite ?? '').toLowerCase() === 'cross-site') return true;
  if (!origin) return false;
  if (origin === 'null') return (secFetchSite ?? '').toLowerCase() !== 'same-origin';
  let o: URL;
  try { o = new URL(origin); } catch { return true; }
  return bare(o.host) !== bare(u.host);
}

/** Framework endpoints this site never uses: answered 404 before the app. */
export function unusedFrameworkPath(pathname: string): boolean {
  return pathname === '/_next/image' || pathname.startsWith('/_next/image/') || pathname.startsWith('/_next/image?');
}

export const CROSS_SITE_REFUSAL = 'This form was sent from another website, so it was not accepted. Open carmacars.ca and try again.';

export function crossSiteRefusal(headers: Record<string, string>): Response {
  return new Response(CROSS_SITE_REFUSAL, { status: 403, headers: { ...headers, 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } });
}
