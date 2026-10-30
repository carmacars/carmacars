// The edge copy of the public pages (docs/changes/2026-10-21-cpu-and-storage.md). No imports: it runs in the Worker
// entry (custom-worker.ts) before the app is loaded, and in Node for the unit test.
//
// Why: every request that reaches OpenNext pays for its routing, the page cache read (a JSON document with the page,
// its RSC payload and segments), the tag checks and, on a fresh isolate, for loading the Next.js server (about a
// second of CPU). The public pages are the same for everyone and are already answered from the page cache; here the
// Worker entry keeps the answer OpenNext gave from its page cache (x-opennext-cache: HIT) in the data centre's Cache
// API and serves it again without loading the app.
//
// What keeps it right:
// - only a page OpenNext served from its page cache (HIT) is kept, never a render, a STALE answer, an error, a
//   redirect, or anything carrying Set-Cookie; the sitemaps (route handlers, public for an hour) too;
// - only for the time OpenNext itself would still call it fresh (its s-maxage), at most a day: when the hour runs out,
//   the next request goes to OpenNext, which serves the stale page and queues the rebuild as before;
// - a page rebuilt on demand (revalidatePath, revalidateTag) bumps one generation number (the tag cache wrapper,
//   src/lib/edge/tag-cache-gen.ts); a copy kept before it, less a minute for the tag store's own delay, is not served;
// - only plain GETs without a query string (the RSC requests by their rsc and segment headers, the _rsc query
//   ignored as OpenNext ignores it), outside the portals and the API;
// - a copy belongs to one deployment (the Worker's version id is in the key): a page kept before a deploy names the
//   previous build's script files, so it is never served by the next one.

export const EDGE_CACHE_NAME = 'carmacars-pages-v1';
export const EDGE_GEN_KEY = 'carmacars/edge-gen';
export const EDGE_HEADER = 'x-edge-cache';
const STORED = 'x-edge-stored';
const ORIGINAL_CC = 'x-edge-cc';
const ORIGINAL_VARY = 'x-edge-vary';
/** a copy counts as kept this much earlier than it was: the tag store (KV) can take up to a minute to show a write */
export const STORE_MARGIN_MS = 60_000;
const MAX_TTL_S = 86_400;
const MIN_TTL_S = 10;

/** First path segments that are never kept: signed-in portals, the API, files and the signing links. */
const PRIVATE = new Set(['admin', 'account', 'owner', 'va', 'field', 'staff', 'investor', 'api', 'auth', 'two-step', 'choose-portal', 'sign', 'sign-document',
  'd', 'files', 'r', 'guide-pdf', 'unsubscribe', 'review', 'link-expired', 'read-only', 'update-password', 'media', '_next', 'cdn-cgi']);
/** The programmatic vehicle pages (0097): the /cars tree below a make, /buy and the term trees /t/<term>. They are
 *  rendered on demand with no ISR entry (no KV write per page: millions of pages), so their only copy is this one, kept
 *  for PROGRAMMATIC_TTL_S whatever Next.js says (force-dynamic answers "private, no-store"), and sent to browsers and
 *  crawlers with PROGRAMMATIC_CC. */
// 0124: the directories that lead to them (/makes, /places and its pages) too: rendered on demand, crawled often
export const PROGRAMMATIC = /^\/(cars\/[^/]+\/[^/]+(\/[^/]+){0,5}|buy(\/[^/]+){1,7}|t\/[^/]+(\/[^/]+){1,7}|makes|places(\/\d{1,6})?)$/;
export const PROGRAMMATIC_TTL_S = 21_600;
export const PROGRAMMATIC_CC = 'public, max-age=600, s-maxage=21600, stale-while-revalidate=86400';
// 0124: the sitemaps at the site's root (/sitemap-index-<n>.xml, /sitemap-priority-<n>.xml, /sitemap-vehicles-<file>.xml,
// /sitemap-places-<file>.xml); the old addresses only redirect now
export const SITEMAP = /^\/(sitemap(-[a-z]+)?\.xml|robots\.txt|sitemap-(index|priority)-\d+\.xml|sitemap-vehicles-[a-z0-9-]+\.xml|sitemap-places-[a-z0-9.-]+\.xml)$/;

export interface EdgeRequestLike { method: string; url: string; headers: { get(name: string): string | null } }

/** The cache key for a request that may be answered from (or kept in) the edge copy, else null. */
export function edgeKey(req: EdgeRequestLike, version: string): string | null {
  const s = edgeSuffix(req);
  return s === null ? null : `https://edge.cache/${encodeURIComponent(version)}/${s}`;
}

/** host, path and the RSC part of the key, or null when the request is never kept */
function edgeSuffix(req: EdgeRequestLike): string | null {
  if (req.method !== 'GET') return null;
  const u = new URL(req.url);
  const seg = u.pathname.split('/')[1] ?? '';
  if (PRIVATE.has(seg)) return null;
  const h = req.headers;
  if (h.get('next-action') || h.get('x-prerender-revalidate')) return null;
  if ((h.get('cookie') ?? '').includes('__prerender_bypass')) return null;
  // the query string: none, or only Next.js's _rsc cache buster on an RSC request
  for (const k of u.searchParams.keys()) if (k !== '_rsc') return null;
  const rsc = h.get('rsc') === '1';
  if (!rsc && u.searchParams.has('_rsc')) return null;
  // OpenNext answers a cached RSC request by its segment header alone (or the whole payload without one); the router's
  // state tree, Next-Url and the prefetch flag do not change a cached answer
  const segment = rsc ? h.get('next-router-segment-prefetch') ?? '' : '';
  const path = u.pathname.length > 1 ? u.pathname.replace(/\/$/, '') : '/';
  return `${u.host}${path}${rsc ? `?rsc=1&seg=${encodeURIComponent(segment)}` : ''}`;
}

// The place pages (migration 0095) and the landing pages they share a route with: rendered on demand (dynamic, never in
// OpenNext's page cache, so no cache write per page), and kept here only, for PLACE_TTL_S. Browsers get a short public
// cache time. A rebuild on demand (an Admin's edit) retires the copies through the generation number as for any page.
export const PLACE_PAGE = /^\/(car-rental\/[a-z0-9-]+(\/[a-z0-9-]+)?|(buy|detailing|body-shop)\/[a-z0-9-]+\/[a-z0-9-]+)$/;
export const PLACE_TTL_S = 21_600;
export const PLACE_BROWSER_CC = 'public, max-age=300';
export const isPlacePage = (pathname: string) => PLACE_PAGE.test(pathname.length > 1 ? pathname.replace(/\/$/, '') : pathname);

/** Seconds to keep this answer, or 0 for not at all. */
export function edgeTtl(pathname: string, status: number, headers: { get(name: string): string | null }): number {
  if (status !== 200 || headers.get('set-cookie')) return 0;
  if (isPlacePage(pathname) && /text\/html|text\/x-component/.test(headers.get('content-type') ?? '')) return PLACE_TTL_S;
  if (PROGRAMMATIC.test(pathname)) return PROGRAMMATIC_TTL_S;
  const cc = headers.get('cache-control') ?? '';
  if (/no-store|private/.test(cc)) return 0;
  const sharedAge = Number(/s-maxage=(\d+)/.exec(cc)?.[1] ?? NaN);
  if (!Number.isFinite(sharedAge)) return 0;
  const hit = headers.get('x-opennext-cache');
  if (hit === 'HIT' || (SITEMAP.test(pathname) && hit !== 'STALE')) {
    const ttl = Math.min(sharedAge, MAX_TTL_S);
    return ttl >= MIN_TTL_S ? ttl : 0;
  }
  return 0;
}

/** True when a tag rebuilt on demand can change a public page (portal and API pages only change themselves). */
export function tagsTouchPublic(tags: ReadonlyArray<string | { tag: string }>): boolean {
  return tags.some((t) => {
    const s = typeof t === 'string' ? t : t.tag;
    const m = /^_N_T_\/([^/]*)/.exec(s);
    if (!m) return true;
    return !PRIVATE.has(m[1]!);
  });
}

/** The deployment the copies belong to: the Worker's version id (wrangler.jsonc version_metadata); null without it,
 *  and then no copy is kept or served. */
export function deploymentOf(env: Record<string, unknown>): string | null {
  const v = env.CF_VERSION_METADATA as { id?: string } | undefined;
  return v && typeof v.id === 'string' && v.id ? v.id : null;
}

// ------------------------------------------------------------------ the generation number (KV, else D1)
interface KvLike { get(key: string, o?: { cacheTtl?: number }): Promise<string | null>; put(key: string, value: string): Promise<void> }
interface D1Like { prepare(q: string): { bind(...v: unknown[]): { first<T>(): Promise<T | null>; run(): Promise<unknown> }; first<T>(): Promise<T | null>; run(): Promise<unknown> } }
type EnvLike = Record<string, unknown>;

function store(env: EnvLike): { kv?: KvLike; d1?: D1Like } {
  const kv = (env.NEXT_TAG_CACHE_KV ?? env.NEXT_INC_CACHE_KV) as KvLike | undefined;
  if (kv && typeof kv.get === 'function') return { kv };
  const d1 = env.NEXT_TAG_CACHE_D1 as D1Like | undefined;
  if (d1 && typeof d1.prepare === 'function') return { d1 };
  return {};
}

/** A number kept in the tag store (KV, else D1): 0 when none is kept, null when it cannot be read. */
export async function readNumber(env: EnvLike, key: string): Promise<number | null> {
  const s = store(env);
  try {
    if (s.kv) return Number((await s.kv.get(key, { cacheTtl: 30 })) ?? 0) || 0;
    if (s.d1) {
      const row = await s.d1.prepare('SELECT v FROM edge_generation WHERE k = ?').bind(key).first<{ v: number }>();
      return Number(row?.v ?? 0) || 0;
    }
    return 0; // no tag store: the pages are served as built and never rebuilt on demand
  } catch (e) {
    // D1 before the first write has no table yet
    if (s.d1 && /no such table/i.test(String(e))) return 0;
    return null;
  }
}

export async function writeNumber(env: EnvLike, key: string, v: number): Promise<void> {
  const s = store(env);
  if (s.kv) { await s.kv.put(key, String(v)); return; }
  if (s.d1) {
    await s.d1.prepare('CREATE TABLE IF NOT EXISTS edge_generation (k TEXT PRIMARY KEY, v INTEGER NOT NULL)').run();
    await s.d1.prepare('INSERT INTO edge_generation (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v').bind(key, v).run();
  }
}

/** The last on-demand rebuild of a public page (ms), 0 when none is known, null when it cannot be read. */
export const readGeneration = (env: EnvLike) => readNumber(env, EDGE_GEN_KEY);
export const bumpGeneration = (env: EnvLike, now = Date.now()) => writeNumber(env, EDGE_GEN_KEY, now);

// ------------------------------------------------------------------ read and keep
interface CacheLike { match(key: string): Promise<Response | undefined>; put(key: string, r: Response): Promise<void> }
export interface EdgeDeps { cache: () => Promise<CacheLike>; env: EnvLike; now?: () => number }

/** The kept answer for this request (headers as OpenNext sent them, plus x-edge-cache: HIT), or null. */
export async function edgeMatch(key: string, d: EdgeDeps): Promise<Response | null> {
  try {
    const cache = await d.cache();
    const [hit, gen] = await Promise.all([cache.match(key), readGeneration(d.env)]);
    if (!hit) return null;
    const stored = Number(hit.headers.get(STORED) ?? 0);
    if (gen === null || gen > stored) { void hit.body?.cancel().catch(() => undefined); return null; }
    const headers = new Headers(hit.headers);
    const cc = headers.get(ORIGINAL_CC);
    if (cc) headers.set('cache-control', cc); else headers.delete('cache-control');
    const vary = headers.get(ORIGINAL_VARY);
    if (vary) headers.set('vary', vary);
    headers.delete(ORIGINAL_CC); headers.delete(ORIGINAL_VARY); headers.delete(STORED); headers.delete('age'); headers.delete('cf-cache-status');
    headers.set(EDGE_HEADER, 'HIT');
    return new Response(hit.body, { status: 200, headers });
  } catch {
    return null;
  }
}

/** Keeps a copy of OpenNext's answer when it may be kept; returns the response to send on (the body is shared). */
export function edgeKeep(key: string, pathname: string, res: Response, d: EdgeDeps & { waitUntil(p: Promise<unknown>): void }): Response {
  const ttl = edgeTtl(pathname, res.status, res.headers);
  if (!ttl || !res.body) return res;
  const [a, b] = res.body.tee();
  const headers = new Headers(res.headers);
  const place = isPlacePage(pathname);
  const programmatic = !place && PROGRAMMATIC.test(pathname);
  const cc = place ? PLACE_BROWSER_CC : programmatic ? PROGRAMMATIC_CC : headers.get('cache-control');
  if (cc) headers.set(ORIGINAL_CC, cc);
  // the copy is found by its key alone (the RSC headers are in the key); the browser still gets OpenNext's Vary
  const vary = headers.get('vary');
  if (vary) { headers.set(ORIGINAL_VARY, vary); headers.delete('vary'); }
  headers.set('cache-control', `public, max-age=${ttl}`);
  headers.set(STORED, String((d.now?.() ?? Date.now()) - STORE_MARGIN_MS));
  headers.delete('set-cookie');
  d.waitUntil(d.cache().then((c) => c.put(key, new Response(b, { status: 200, headers }))).catch(() => undefined));
  const out = new Headers(res.headers);
  if (place) out.set('cache-control', PLACE_BROWSER_CC);
  else if (programmatic) out.set('cache-control', PROGRAMMATIC_CC);
  return new Response(a, { status: res.status, statusText: res.statusText, headers: out });
}

// ------------------------------------------------------------------ the last good copy (0106)
// When the database is slow (a bulk import, a load spike on the Micro compute), OpenNext answers 500 or takes 5 to 40
// seconds. The last good answer of each public page is kept beside the fresh copy, under a key without the deployment
// and for a week, whatever its freshness; when OpenNext answers 5xx or has not answered within ORIGIN_WAIT_MS, the
// visitor gets that copy (x-edge-stale says why) and the page is asked for again in the background. With no copy yet,
// the visitor waits, and a 5xx (or no answer within GIVE_UP_MS) becomes the "Busy for a moment" page, which tries
// again by itself. Only for the requests edgeKey covers, and only without a session (a signed-in visitor or an Admin
// viewing as someone always reaches the app): never a portal, the API or a write.

export const STALE_TTL_S = 7 * 86_400;
export const STALE_HEADER = 'x-edge-stale';
const STALE_VERSION = 'x-edge-version';
/** OpenNext's answer is waited for this long when a last good copy exists */
export const ORIGIN_WAIT_MS = 4_000;
/** with no copy, the first visitor waits at most this long before the busy page */
export const GIVE_UP_MS = 25_000;
/** after a 5xx answered from the copy, the page is asked for again this much later, at most once a minute */
export const REFRESH_AFTER_MS = 5_000;
export const REFRESH_EVERY_MS = 60_000;

/** A sign-in session (Supabase's cookie) or an Admin viewing as someone: such a request never gets a kept copy. */
export function hasSession(cookieHeader: string | null | undefined): boolean {
  for (const part of (cookieHeader ?? '').split(';')) {
    const name = part.slice(0, Math.max(0, part.indexOf('='))).trim();
    if (/^sb-[a-z0-9]+-auth-token(\.\d+)?$/.test(name) || name === 'cc-view-as') return true;
  }
  return false;
}

/** The key of the last good copy (no deployment in it: it outlives a deploy), or null. */
export function staleKey(req: EdgeRequestLike): string | null {
  const s = edgeSuffix(req);
  if (s === null || hasSession(req.headers.get('cookie'))) return null;
  return `https://edge.stale/${s}`;
}

/** A good answer worth keeping as the last good copy: 200, no Set-Cookie, a page, its RSC payload, a sitemap or robots. */
export function staleWorthy(status: number, headers: { get(name: string): string | null }): boolean {
  if (status !== 200 || headers.get('set-cookie') || headers.get(STALE_HEADER)) return false;
  return /text\/html|text\/x-component|xml|text\/plain/.test(headers.get('content-type') ?? '');
}

/** Keeps the answer as the page's last good copy when it is one; returns the response to send on (the body is shared). */
export function staleKeep(key: string, res: Response, d: EdgeDeps & { version: string; waitUntil(p: Promise<unknown>): void }): Response {
  if (!res.body || !staleWorthy(res.status, res.headers)) return res;
  const [a, b] = res.body.tee();
  const headers = new Headers(res.headers);
  const cc = headers.get('cache-control');
  if (cc) headers.set(ORIGINAL_CC, cc);
  const vary = headers.get('vary');
  if (vary) { headers.set(ORIGINAL_VARY, vary); headers.delete('vary'); }
  headers.set('cache-control', `public, max-age=${STALE_TTL_S}`);
  headers.set(STORED, String(d.now?.() ?? Date.now()));
  headers.set(STALE_VERSION, d.version);
  d.waitUntil(d.cache().then((c) => c.put(key, new Response(b, { status: 200, headers }))).catch(() => undefined));
  return new Response(a, { status: res.status, statusText: res.statusText, headers: res.headers });
}

/** The last good copy, marked with why it is served; null when none is kept. An RSC payload is served only to the
 *  deployment that made it (another build's router cannot use it); a page is served whatever deployment kept it. */
export async function staleMatch(key: string, d: EdgeDeps & { version: string }, why: string, rsc: boolean): Promise<Response | null> {
  try {
    const hit = await (await d.cache()).match(key);
    if (!hit) return null;
    const version = hit.headers.get(STALE_VERSION);
    if (rsc && version !== d.version) { void hit.body?.cancel().catch(() => undefined); return null; }
    const headers = new Headers(hit.headers);
    const vary = headers.get(ORIGINAL_VARY);
    if (vary) headers.set('vary', vary);
    const age = Math.max(0, Math.round(((d.now?.() ?? Date.now()) - Number(headers.get(STORED) ?? 0)) / 1000));
    for (const h of [ORIGINAL_CC, ORIGINAL_VARY, STORED, STALE_VERSION, 'age', 'cf-cache-status', 'etag']) headers.delete(h);
    // never kept by a browser or a shared cache: the next visit asks again
    headers.set('cache-control', 'no-cache');
    headers.set(EDGE_HEADER, 'STALE');
    headers.set(STALE_HEADER, `${why}; age=${age}${version === d.version ? '' : '; deploy=previous'}`);
    return new Response(hit.body, { status: 200, headers });
  } catch {
    return null;
  }
}

/** The page a first visitor gets when the site cannot answer and no copy is kept: it tries again by itself. */
export function busyPage(status = 503): Response {
  const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<meta name="robots" content="noindex"><title>CarmaCars: busy for a moment</title>'
    + '<noscript><meta http-equiv="refresh" content="8"></noscript>'
    + '<style>body{margin:0;font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f7f7f5;color:#1b1b1b;display:grid;place-items:center;min-height:100vh}'
    + 'main{max-width:28rem;padding:2rem 1rem;text-align:center}h1{font-size:1.5rem;margin:0 0 .5rem}p{margin:.5rem 0;color:#4a4a4a}a{color:#0b57d0}'
    + '@media (prefers-color-scheme:dark){body{background:#151515;color:#eee}p{color:#bbb}a{color:#8ab4f8}}</style></head>'
    + '<body><main><h1>Busy for a moment, retrying</h1><p>CarmaCars is very busy right now. This page tries again by itself in a few seconds.</p>'
    + '<p id="cc-busy-next" aria-live="polite"></p><p><a href="">Try now</a></p></main>'
    + '<script>(function(){var k="cc-busy",n=0,t=Date.now();try{var o=JSON.parse(sessionStorage.getItem(k)||"null");if(o&&t-o.t<120000)n=o.n+1;sessionStorage.setItem(k,JSON.stringify({n:n,t:t}))}catch(e){}'
    + 'var ms=Math.min(30000,Math.round(3000*Math.pow(1.6,n)));var el=document.getElementById("cc-busy-next");if(el)el.textContent="Trying again in "+Math.round(ms/1000)+" seconds.";'
    + 'setTimeout(function(){location.reload()},ms)})()</script></body></html>';
  return new Response(html, { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'retry-after': '5', [STALE_HEADER]: 'busy' } });
}

const refreshed = new Map<string, number>();
/** May the page be asked for again now (at most once a REFRESH_EVERY_MS per page and isolate)? */
export function refreshDue(key: string, now: number): boolean {
  const last = refreshed.get(key);
  if (last !== undefined && now - last < REFRESH_EVERY_MS) return false;
  if (refreshed.size > 500) refreshed.clear();
  refreshed.set(key, now);
  return true;
}

export interface ServeDeps extends EdgeDeps {
  version: string;
  waitUntil(p: Promise<unknown>): void;
  /** OpenNext's answer for this request (called again for a background refresh) */
  origin(): Promise<Response>;
  waitMs?: number; giveUpMs?: number; refreshAfterMs?: number;
  /** a timer that can be cancelled (tests pass their own) */
  timer?: (ms: number) => { done: Promise<void>; cancel(): void };
}

const realTimer = (ms: number) => {
  let id: ReturnType<typeof setTimeout> | undefined;
  const done = new Promise<void>((r) => { id = setTimeout(r, ms); });
  return { done, cancel: () => { if (id !== undefined) clearTimeout(id); } };
};
const drain = (r: Response | null | undefined) => { if (r?.body) void r.body.cancel().catch(() => undefined); };
const consume = (r: Response) => r.arrayBuffer().then(() => undefined, () => undefined);
const failed = (status: number) => new Response(null, { status });

/**
 * One public request: the fresh edge copy (edgeMatch) when it holds, else OpenNext, keeping its answer (edgeKeep) and
 * its last good copy (staleKeep); with a stale key, a 5xx or a slow answer is replaced by the last good copy, and with
 * none by the busy page (HTML) or the error itself (RSC, sitemaps).
 */
export async function serveEdge(req: EdgeRequestLike, key: string | null, sKey: string | null, pathname: string, d: ServeDeps): Promise<Response> {
  if (key) { const hit = await edgeMatch(key, d); if (hit) return hit; }
  const keep = (r: Response) => { let out = key ? edgeKeep(key, pathname, r, d) : r; if (sKey) out = staleKeep(sKey, out, d); return out; };
  if (!sKey) return keep(await d.origin());
  const timer = d.timer ?? realTimer;
  const rsc = req.headers.get('rsc') === '1';
  const html = !rsc && !/\.(xml|txt)$/.test(pathname);
  const origin: Promise<Response> = d.origin().then(keep, () => failed(502));
  const slow = timer(d.waitMs ?? ORIGIN_WAIT_MS);
  const first = await Promise.race([origin, slow.done.then(() => null)]);
  slow.cancel();
  if (first && first.status < 500) return first;
  const why = first ? `error ${first.status}` : 'slow';
  const old = await staleMatch(sKey, d, why, rsc);
  if (old) {
    if (first) {
      drain(first);
      // the page asked for again a little later, so the copy is replaced once the site answers
      if (refreshDue(sKey, d.now?.() ?? Date.now())) {
        const later = timer(d.refreshAfterMs ?? REFRESH_AFTER_MS);
        d.waitUntil(later.done.then(() => d.origin()).then(keep).then(consume).catch(() => undefined));
      }
    } else {
      // the answer still on its way is the refresh: it is kept when it comes
      d.waitUntil(origin.then(consume));
    }
    return old;
  }
  // no copy kept yet: the first visitor waits (up to GIVE_UP_MS in all), then gets the busy page
  let last = first;
  if (!last) {
    const rest = timer(Math.max(0, (d.giveUpMs ?? GIVE_UP_MS) - (d.waitMs ?? ORIGIN_WAIT_MS)));
    last = await Promise.race([origin, rest.done.then(() => null)]);
    rest.cancel();
    if (last && last.status < 500) return last;
    if (!last) d.waitUntil(origin.then(consume));
  }
  if (html) { drain(last); return busyPage(); }
  // 0124: a sitemap, robots.txt or an RSC payload the site cannot give now is a 503 with Retry-After, never a 500 or 504:
  // a crawler reads it as "come back later" and keeps its crawl rate (a 5xx other than 503 lowers it)
  drain(last);
  return busyAnswer();
}

/** The answer to a crawler or the router when the site cannot answer now (not a page): 503, Retry-After 120. */
export function busyAnswer(retryAfter = 120): Response {
  return new Response('Busy, try again shortly', { status: 503, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', 'retry-after': String(retryAfter), [STALE_HEADER]: 'busy' } });
}

// ------------------------------------------------------------------ requests nobody should render
/** Paths the site never has, asked for by scanners (PHP, WordPress, dot files): a plain 404 before the app loads. */
const PROBE = /\.(php\d?|aspx?|jsp|cgi|env|ini|sql|bak|old|swp|git)(\/|$)|^\/(wp-|wordpress|xmlrpc|cgi-bin|\.git|\.env|\.aws|\.ssh|phpmyadmin|vendor\/phpunit)/i;
export const isProbe = (pathname: string) => PROBE.test(pathname);
