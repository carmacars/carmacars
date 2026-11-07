// The global copy of the place pages (r32, docs/changes/2026-11-07-r32-edge-cpu-notify.md). No imports: it runs in the
// Worker entry (custom-worker.ts, through page-cache.ts serveEdge) before the app is loaded, and in Node for the unit test.
//
// Why: on November 7 the Worker took about a million requests a day at about 100 ms of CPU each (785 million CPU ms in
// the month against 30 million included), nearly all of them bots walking the place pages (/car-rental/<place>,
// /car-rental/<term>/<place>, /detailing/..., /body-shop/..., /buy/<term>/<place>). Those pages are rendered on demand
// and their only copies were the data centre's (page-cache.ts: the fresh copy belongs to one deployment and lives a day,
// the last good copy a week), so a bot asking from another data centre, or after a deploy, got a fresh render.
//
// What this adds: one copy of each place page for the whole network, in R2 (the OpenNext cache bucket, under
// GLOBAL_PREFIX), gzipped, kept GLOBAL_TTL_S (30 days) whatever the deploys and the rebuilds on demand (the owner: a
// stale copy is fine, a price changed does not rebuild it). A request finds it first in the data centre's Cache API
// (free, GLOBAL-DC), then in R2 (one read, GLOBAL), and is answered with only the nonce rewrite of custom-worker.ts.
// A miss renders as before and keeps the render in both.
//
// What keeps it right:
// - only a plain GET of the HTML page (no query string, no RSC request, no server action), never with a session
//   (hasSession: a signed-in visitor or an Admin viewing as someone always reaches the app);
// - only a real 200 render without Set-Cookie (never a copy served from a cache, a stale answer or the busy page);
// - a page names its build's script files, kept 8 days after they leave a deploy (scripts/deploy/keep-assets.mjs): a copy
//   older than PEOPLE_MAX_S (7 days) is served to crawlers only; a person gets a fresh render, which replaces the copy;
// - a crawler asking "changed since?" gets 304 when the copy is no newer;
// - the nonce is added per response after this (custom-worker.ts), never stored.

export const GLOBAL_PREFIX = 'edge-pages/v1/';
export const GLOBAL_TTL_S = 30 * 86_400;
/** a person gets a copy only while its build files are still served (keep-assets.mjs keeps them 8 days) */
export const PEOPLE_MAX_S = 7 * 86_400;
/** the data centre's mirror of the global copy (Cache API, free) */
const MIRROR = 'https://edge.global/';
const STORED = 'x-edge-stored';
export const GLOBAL_EDGE_HEADER = 'x-edge-cache';
/** the response headers a stored page keeps (everything else is the Worker's own or per response) */
const KEEP_HEADERS = ['content-type', 'content-language', 'vary', 'link', 'x-robots-tag'];
/** pages larger than this are not stored (none is near it; a guard against an endless stream) */
export const MAX_BYTES = 4_000_000;
export const BROWSER_CC = 'public, max-age=300';

// the place pages: the same addresses as page-cache.ts PLACE_PAGE (kept here so this file has no imports)
const PLACE = /^\/(car-rental\/[a-z0-9-]+(\/[a-z0-9-]+)?|(buy|detailing|body-shop)\/[a-z0-9-]+\/[a-z0-9-]+)$/;

export interface GlobalRequestLike { method: string; url: string; headers: { get(name: string): string | null } }

function sessionCookie(cookie: string | null): boolean {
  for (const part of (cookie ?? '').split(';')) {
    const name = part.slice(0, Math.max(0, part.indexOf('='))).trim();
    if (/^sb-[a-z0-9]+-auth-token(\.\d+)?$/.test(name) || name === 'cc-view-as' || name === '__prerender_bypass') return true;
  }
  return false;
}

/** The global copy's key for this request (host and path), or null when it is never served from or kept in it. */
export function globalKey(req: GlobalRequestLike): string | null {
  if (req.method !== 'GET') return null;
  const h = req.headers;
  if (h.get('rsc') === '1' || h.get('next-action') || h.get('x-prerender-revalidate')) return null;
  if (sessionCookie(h.get('cookie'))) return null;
  const u = new URL(req.url);
  if (u.search) return null;
  const path = u.pathname.length > 1 ? u.pathname.replace(/\/$/, '') : u.pathname;
  if (!PLACE.test(path)) return null;
  return `${u.host.toLowerCase()}${path}`;
}

interface R2ObjectLike { body: ReadableStream; customMetadata?: Record<string, string> }
export interface R2Like {
  get(key: string): Promise<R2ObjectLike | null>;
  put(key: string, value: ArrayBuffer, o?: { httpMetadata?: { contentType?: string }; customMetadata?: Record<string, string> }): Promise<unknown>;
}
interface CacheLike { match(key: string): Promise<Response | undefined>; put(key: string, r: Response): Promise<void> }
export interface GlobalDeps {
  bucket: R2Like;
  cache: () => Promise<CacheLike>;
  waitUntil(p: Promise<unknown>): void;
  /** a crawler (bot-shield.ts isCrawler): copies up to GLOBAL_TTL_S; anyone else up to PEOPLE_MAX_S */
  crawler: boolean;
  ifModifiedSince?: string | null;
  now?: () => number;
}

function headersOf(json: string | undefined): Headers {
  const out = new Headers();
  try {
    const o = JSON.parse(json ?? '{}') as Record<string, unknown>;
    for (const k of KEEP_HEADERS) if (typeof o[k] === 'string') out.set(k, o[k] as string);
  } catch { /* the content type alone */ }
  if (!out.has('content-type')) out.set('content-type', 'text/html; charset=utf-8');
  return out;
}

function answer(body: ReadableStream | null, headers: Headers, stored: number, how: string, d: GlobalDeps): Response {
  const lastModified = new Date(Math.floor(stored / 1000) * 1000).toUTCString();
  const since = d.ifModifiedSince ? Date.parse(d.ifModifiedSince) : NaN;
  if (Number.isFinite(since) && stored <= since + 999) {
    if (body) void body.cancel().catch(() => undefined);
    return new Response(null, { status: 304, headers: { 'last-modified': lastModified, [GLOBAL_EDGE_HEADER]: `${how}-304` } });
  }
  const out = new Headers(headers);
  out.set('cache-control', BROWSER_CC);
  out.set('last-modified', lastModified);
  out.set(GLOBAL_EDGE_HEADER, how);
  out.delete(STORED);
  return new Response(body, { status: 200, headers: out });
}

/** The page's global copy (the data centre's mirror first, then R2), a 304, or null (render as usual). */
export async function globalMatch(key: string, d: GlobalDeps): Promise<Response | null> {
  const now = d.now?.() ?? Date.now();
  const maxAge = (d.crawler ? GLOBAL_TTL_S : PEOPLE_MAX_S) * 1000;
  try {
    const cache = await d.cache();
    const m = await cache.match(MIRROR + key);
    if (m) {
      const stored = Number(m.headers.get(STORED) ?? 0);
      if (stored && now - stored <= maxAge) return answer(m.body, m.headers, stored, 'GLOBAL-DC', d);
      void m.body?.cancel().catch(() => undefined);
      // a mirror too old for a person may still be in R2 newer (another data centre rendered it since)
    }
    const o = await d.bucket.get(GLOBAL_PREFIX + key);
    if (!o) return null;
    const stored = Number(o.customMetadata?.s ?? 0);
    if (!stored || now - stored > maxAge) { void o.body.cancel().catch(() => undefined); return null; }
    const headers = headersOf(o.customMetadata?.h);
    const plain = o.body.pipeThrough(new DecompressionStream('gzip'));
    const left = GLOBAL_TTL_S - Math.floor((now - stored) / 1000);
    if (left < 60) return answer(plain, headers, stored, 'GLOBAL', d);
    const [a, b] = plain.tee();
    const mh = new Headers(headers);
    mh.set('cache-control', `public, max-age=${left}`);
    mh.set(STORED, String(stored));
    d.waitUntil(cache.put(MIRROR + key, new Response(b, { status: 200, headers: mh })).catch(() => undefined));
    return answer(a, headers, stored, 'GLOBAL', d);
  } catch {
    return null;
  }
}

/** A render worth keeping: 200, HTML, no Set-Cookie, not itself a copy from a cache or the busy page. */
export function globalWorthy(status: number, headers: { get(name: string): string | null }): boolean {
  if (status !== 200 || headers.get('set-cookie') || headers.get('x-edge-stale') || headers.get(GLOBAL_EDGE_HEADER)) return false;
  return /text\/html/.test(headers.get('content-type') ?? '');
}

async function gzip(s: ReadableStream): Promise<ArrayBuffer> {
  return new Response(s.pipeThrough(new CompressionStream('gzip'))).arrayBuffer();
}

/** Keeps a render as the page's global copy (R2, gzipped) and the data centre's mirror; returns the response to send on. */
export function globalKeep(key: string, res: Response, d: Omit<GlobalDeps, 'crawler'>): Response {
  if (!res.body || !globalWorthy(res.status, res.headers)) return res;
  const len = Number(res.headers.get('content-length') ?? 0);
  if (len > MAX_BYTES) return res;
  const [a, b] = res.body.tee();
  const [toR2, toMirror] = b.tee();
  const stored = d.now?.() ?? Date.now();
  const kept: Record<string, string> = {};
  for (const k of KEEP_HEADERS) { const v = res.headers.get(k); if (v) kept[k] = v; }
  let h = JSON.stringify(kept);
  // R2 custom metadata is at most 2 KB in all
  if (h.length > 1500) h = JSON.stringify({ 'content-type': kept['content-type'] ?? 'text/html; charset=utf-8' });
  const mh = new Headers(kept);
  mh.set('cache-control', `public, max-age=${GLOBAL_TTL_S}`);
  mh.set(STORED, String(stored));
  d.waitUntil((async () => {
    const buf = await gzip(toR2);
    if (buf.byteLength > MAX_BYTES) return;
    await d.bucket.put(GLOBAL_PREFIX + key, buf, { httpMetadata: { contentType: kept['content-type'] ?? 'text/html; charset=utf-8' }, customMetadata: { s: String(stored), h } });
  })().catch(() => undefined));
  d.waitUntil(d.cache().then((c) => c.put(MIRROR + key, new Response(toMirror, { status: 200, headers: mh }))).catch(() => undefined));
  return new Response(a, { status: res.status, statusText: res.statusText, headers: res.headers });
}
