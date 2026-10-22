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
const PRIVATE = new Set(['admin', 'account', 'owner', 'va', 'field', 'investor', 'api', 'auth', 'two-step', 'choose-portal', 'sign', 'sign-document',
  'd', 'files', 'r', 'guide-pdf', 'unsubscribe', 'link-expired', 'read-only', 'update-password', 'media', '_next', 'cdn-cgi']);
/** The programmatic vehicle pages (0097): the /cars tree below a make, /buy and the term trees /t/<term>. They are
 *  rendered on demand with no ISR entry (no KV write per page: millions of pages), so their only copy is this one, kept
 *  for PROGRAMMATIC_TTL_S whatever Next.js says (force-dynamic answers "private, no-store"), and sent to browsers and
 *  crawlers with PROGRAMMATIC_CC. */
export const PROGRAMMATIC = /^\/(cars\/[^/]+\/[^/]+(\/[^/]+){0,5}|buy(\/[^/]+){1,7}|t\/[^/]+(\/[^/]+){1,7})$/;
export const PROGRAMMATIC_TTL_S = 21_600;
export const PROGRAMMATIC_CC = 'public, max-age=600, s-maxage=21600, stale-while-revalidate=86400';
const SITEMAP = /^\/(sitemap(-[a-z]+)?\.xml|robots\.txt|sitemap-vehicles\/[a-z0-9-]+\.xml|sitemap-index\/\d+\.xml|sitemap-places\/[a-z0-9.-]+\.xml)$/;

export interface EdgeRequestLike { method: string; url: string; headers: { get(name: string): string | null } }

/** The cache key for a request that may be answered from (or kept in) the edge copy, else null. */
export function edgeKey(req: EdgeRequestLike, version: string): string | null {
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
  return `https://edge.cache/${encodeURIComponent(version)}/${u.host}${path}${rsc ? `?rsc=1&seg=${encodeURIComponent(segment)}` : ''}`;
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

// ------------------------------------------------------------------ requests nobody should render
/** Paths the site never has, asked for by scanners (PHP, WordPress, dot files): a plain 404 before the app loads. */
const PROBE = /\.(php\d?|aspx?|jsp|cgi|env|ini|sql|bak|old|swp|git)(\/|$)|^\/(wp-|wordpress|xmlrpc|cgi-bin|\.git|\.env|\.aws|\.ssh|phpmyadmin|vendor\/phpunit)/i;
export const isProbe = (pathname: string) => PROBE.test(pathname);
