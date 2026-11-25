// r50 (4701): the server's own errors are kept beside the browser's (client_errors, kind 'server'), so an Admin (and the
// connector's site_errors) sees which page failed on the server, for whom, and how often. Before, a server error page was
// only known when the browser reported the digest. Never throws: a failed write is only logged.
type Req = { path: string; method: string; headers: Record<string, string | string[] | undefined> };
type Ctx = { routerKind?: string; routePath?: string; routeType?: string };

const TOKEN_PATH = /^\/api\/(shift-feed|ical|booking-ics|feeds)\/[^/]+/;
const CONTROL = /^NEXT_(NOT_FOUND|REDIRECT|HTTP_ERROR_FALLBACK)|^DYNAMIC_SERVER_USAGE|^BAILOUT_TO_CLIENT_SIDE_RENDERING/;

export async function onRequestError(err: unknown, request: Req, context: Ctx): Promise<void> {
  try {
    const e = err as { message?: string; stack?: string; digest?: string } | null;
    if (e?.digest && CONTROL.test(e.digest)) return;
    if (process.env.NEXT_PHASE === 'phase-production-build') return;
    const { rpc } = await import('@/lib/db/repo');
    // the secret in a token address (a calendar feed, a channel feed, a booking's calendar file) is never kept
    const path = String(request.path ?? '/').split('?')[0]!.replace(TOKEN_PATH, '/api/$1/[token]').slice(0, 300);
    const ua = request.headers['user-agent'];
    await rpc('server_error_log', { p: {
      path, digest: e?.digest?.slice(0, 100),
      message: `${request.method} ${context.routeType ?? ''} ${context.routePath ?? ''}: ${String(e?.message ?? err)}`.replace(/\s+/g, ' ').slice(0, 500),
      stack: e?.stack?.slice(0, 4000), ua: (Array.isArray(ua) ? ua[0] : ua)?.slice(0, 300)
    } }, { role: 'service_role', skipViewAs: true });
  } catch (x) {
    console.error('server-error-log', x instanceof Error ? x.message.slice(0, 200) : x);
  }
}
