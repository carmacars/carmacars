import 'server-only';
import { rpc, sharedRead } from '@/lib/db/repo';
import { absUrl } from '@/features/seo/meta';
import { siteUrl } from '@/lib/site';
import { env } from '@/lib/env';

// The sitemaps read as the server (public paths only), not as a visitor: a file walks thousands of pages, which the
// visitor's 2.5 s limit (0106) cut off (/sitemap.xml and /sitemap-vehicles/makes.xml answered 500, Oct 22).
const SR = { role: 'service_role' as const };

// The sitemaps (docs/blueprint/14-seo.md section 9, migration 0061): an index, then the fixed pages with the model
// pages, the cars with their photos, the landing pages and the guides. lastmod only where the date is the content's
// own (Google uses it only when it is reliably accurate); no priority or changefreq (Google ignores them).
export const FIXED = ['/', '/cars', '/car-rental', '/guides', '/how-it-works', '/requirements', '/credit-card-rental-coverage', '/delivery', '/chauffeur', '/faq', '/contact', '/about', '/list-your-car', '/detailing', '/body-shop', '/place-data', '/places', '/makes', '/terms', '/privacy', '/cancellation-policy'];
type Row = { path: string; kind: string; lastmod: string | null; images: Array<{ loc: string; title: string | null }> | null };
// 0102: 'hubs', the model pages of the cars on the site (/cars/<make>/<model>, sitemap_all's model_hub rows). They were left
// to the vehicle sitemaps of 0097, which list nothing while the vehicle catalog is not loaded (live, Oct 22: none), so the
// 47 model pages were in no sitemap. 0128: without the model pages the vehicle sitemaps list, and with the fleet's make pages.
// 0115: 'priority', first in the index: the pages most worth crawling first (the fleet's cars, the landing pages, the
// make pages, the popular models from the newest years, the place pages nearest us for the first terms), at most 50,000.
// 0128: without the cars and landing pages, which are in their own files (each address in one sitemap file).
export const SITEMAPS = ['priority', 'pages', 'cars', 'landing', 'guides', 'hubs'] as const;
export type SitemapName = (typeof SITEMAPS)[number];

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const iso = (d: string | null) => (d ? new Date(d).toISOString() : null);

// The site's own sitemap rows and the place file list are the same for every request: kept per Worker for 5 minutes
// (sharedRead). Google fetched hundreds of index files at once on Oct 23, each reading both again, and the busy
// database made many of them pass Google's time limit ("Couldn't fetch").
// The local stack (DATA_BACKEND=local: next dev and the end-to-end tests) reads them every time, as the anon shared
// reads already do (src/lib/db/repo.ts), so an Admin switch shows in the sitemaps at once; the database's own stored
// lists follow a switch at once too (0119).
const memo = (key: string, load: () => Promise<unknown>) => (env().DATA_BACKEND === 'local' ? load() : sharedRead(key, load));
async function rows(): Promise<Row[]> {
  return ((await memo('sitemap_all', () => rpc('sitemap_all', {}, SR))) ?? []) as unknown as Row[];
}

type Prio = Array<{ path: string; lastmod: string | null }>;
async function priorityRows(): Promise<Prio> {
  try { return ((await memo('sitemap_priority', () => rpc('sitemap_priority', {}, SR))) ?? []) as unknown as Prio; } catch { return []; }
}
// 0128: the hubs file is the model pages of the fleet's cars the vehicle sitemaps do not list, and the make pages of the
// fleet's makes the catalog does not cover (/cars/bmw); before 0128 is applied, the model pages as sitemap_all lists them
async function hubRows(all: Row[]): Promise<Prio> {
  try { return ((await memo('sitemap_hubs', () => rpc('sitemap_hubs', {}, SR))) ?? []) as unknown as Prio; }
  catch { return all.filter((r) => r.kind === 'model_hub'); }
}

function entries(name: SitemapName, all: Row[], prio: Prio = [], hubs: Prio = []): Array<{ loc: string; lastmod: string | null; images?: string[] }> {
  const base = siteUrl();
  const url = (p: string) => base + (p === '/' ? '' : p);
  switch (name) {
    // the model pages are in the vehicle sitemaps (0097: /cars/<make>/<model> replaced the model hubs)
    case 'pages': return FIXED.map((p) => ({ loc: url(p), lastmod: null }));
    // 0128: each address in one sitemap file. The priority list leaves out the addresses of the site's own files (the
    // fleet's cars, the landing pages, the fixed pages, the guides and the hubs: listed right after it, at the top of
    // the index); it keeps its own selection (the makes, the popular models, the place pages nearest us).
    case 'priority': {
      const seen = new Set<string>([...FIXED, ...all.filter((r) => r.kind !== 'model_hub').map((r) => r.path), ...hubs.map((r) => r.path)]);
      return prio.filter((r) => !seen.has(r.path) && !!seen.add(r.path)).slice(0, 50_000).map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
    }
    case 'cars': return all.filter((r) => r.kind === 'car').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod), images: (r.images ?? []).map((i) => absUrl(i.loc)) }));
    case 'landing': return all.filter((r) => r.kind === 'landing').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
    case 'guides': return all.filter((r) => r.kind === 'article').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
    case 'hubs': return hubs.map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
  }
}

// 0124: kept by the CDN and the edge copy for 6 hours and served stale for a day while it is read again, so a crawler's
// burst of sitemap fetches is answered at the edge (Googlebot fetches faster from a site that answers fast).
const XML = { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'public, max-age=0, s-maxage=21600, stale-while-revalidate=86400' };

// 0124: every sitemap file at the site's root. Google reads a sitemap index only for files "in the same directory as the
// sitemap index file, or lower" (developers.google.com/search/docs/crawling-indexing/sitemaps/large-sitemaps), and a
// sitemap not submitted in Search Console "affects only descendants of the parent directory" (the sitemaps.org location
// rule Bing follows too). /sitemap-index/2.xml listed /sitemap-vehicles/*.xml, which is outside /sitemap-index/: Search
// Console showed 0 discovered pages for all 480 of them. The public names are now /sitemap-index-<n>.xml,
// /sitemap-priority-<n>.xml, /sitemap-vehicles-<file>.xml and /sitemap-places-<file>.xml (next.config.ts rewrites them
// to the handlers under /sitemap-files/); the old addresses answer 301 to the new ones.
export const sitemapUrl = {
  index: (n: number) => `${siteUrl()}${n <= 1 ? '/sitemap.xml' : `/sitemap-index-${n}.xml`}`,
  priority: (n: number) => `${siteUrl()}/sitemap-priority-${n}.xml`,
  vehicles: (file: string) => `${siteUrl()}/sitemap-vehicles-${file}.xml`,
  places: (file: string) => `${siteUrl()}/sitemap-places-${file}.xml`
};
/** 0124: the priority sitemap in files of 10,000 addresses (fetched and reported one by one in Search Console). */
export const PRIORITY_CHUNK = 10_000;

/** A sitemap that cannot be read now (the database busy): 503 with Retry-After, never a 500 (a crawler slows down and
 *  comes back; a 500 counts against the site's crawl rate and is reported as an error). */
export function busyXml(retryAfter = 120): Response {
  return new Response('Busy, try again shortly', { status: 503, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', 'retry-after': String(retryAfter) } });
}
export async function guarded(make: () => Promise<Response>): Promise<Response> {
  try { return await make(); } catch { return busyXml(); }
}
/** An old sitemap address (before 0124), moved for good to its root name. */
export const moved = (to: string) => new Response(null, { status: 301, headers: { location: to, 'cache-control': 'public, max-age=86400' } });

// The vehicle pages (migration 0097): files per tree ("" renting, "buy-" for sale, "t-<term>-" each search term): the
// makes, one per make and level (toyota-years, split in parts of 45,000 when bigger), and the place and colour files
// tiers-1, tiers-2... (ranges of (trim, place) pairs, at most 50,000 addresses each). Only indexed pages. The index is
// split every 50,000 sitemaps: /sitemap.xml, then /sitemap-index/2.xml..., all named in robots.txt. Every list comes from
// the database's own numbering (no page is rendered, no address counted for the index).
export const INDEX_SIZE = 50_000;
const BASE_FILE = /^(makes|tiers-\d+|[a-z0-9]+(-[a-z0-9]+)*-(models|years|trims)(-\d+)?)$/;
type VIndex = { total: number; files: Array<{ file: string; lastmod: string | null }> };
// 0110: the numbering of app.vpage_index_page, done here from the stored shape (the level files, the place and colour
// files per tree, the trees) instead of 50,000 rows built in SQL on every request (7 to 12 s, past the 8 s limit).
type Shape = { base: Array<{ file: string; lastmod: string | null }>; tiers: number; trees: string[] };
const shape = () => memo('vehicle_sitemap_shape', () => rpc('vehicle_sitemap_shape', {}, SR)) as Promise<Shape>;
export function numberFiles(sh: Shape, offset: number, limit: number): VIndex {
  const nb = sh.base.length;
  const per = nb + (sh.tiers ?? 0);
  const total = per * sh.trees.length;
  const files: VIndex['files'] = [];
  for (let n = offset + 1; n <= Math.min(offset + Math.max(limit, 0), total); n++) {
    const r = (n - 1) % per;
    const tree = sh.trees[Math.floor((n - 1) / per)]!;
    files.push(r < nb ? { file: tree + sh.base[r]!.file, lastmod: sh.base[r]!.lastmod } : { file: `${tree}tiers-${r - nb + 1}`, lastmod: null });
  }
  return { total, files };
}
const vIndex = async (offset: number, limit: number): Promise<VIndex> => numberFiles(await shape(), offset, Math.min(limit, INDEX_SIZE));

// the place pages (0095): one file per term and range of places, listed by the database without reading the pages
type PlaceFile = { file: string; vertical: string; term: string; page: number; lastmod: string | null };
async function placeFiles(): Promise<PlaceFile[]> {
  try { return ((await memo('place_sitemap_files', () => rpc('place_sitemap_files', {}, SR))) ?? []) as unknown as PlaceFile[]; } catch { return []; }
}
const lastOf = (e: Array<{ lastmod: string | null }>) => e.map((x) => x.lastmod).filter(Boolean).sort().pop();
const sm = (loc: string, last: string | null | undefined) => `<sitemap><loc>${esc(loc)}</loc>${last ? `<lastmod>${last}</lastmod>` : ''}</sitemap>`;
/** The site's own sitemaps (the priority list in files of PRIORITY_CHUNK) and the place files (at most 49,000), first in
 *  the index. */
async function siteEntries(): Promise<string[]> {
  const [all, places, prio] = await Promise.all([rows(), placeFiles(), priorityRows()]);
  const hubs = await hubRows(all);
  return [...SITEMAPS.flatMap((name) => {
    const e = entries(name, all, prio, hubs);
    if (name === 'priority') return chunk(e, PRIORITY_CHUNK).map((c, i) => sm(sitemapUrl.priority(i + 1), lastOf(c)));
    return [sm(`${siteUrl()}/sitemap-${name}.xml`, lastOf(e))];
  }), ...places.slice(0, 49_000).map((f) => sm(sitemapUrl.places(f.file), iso(f.lastmod)))];
}
/** The list in parts of n (at least one part, so an empty priority list is still one valid, empty file). */
export function chunk<T>(list: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < list.length; i += n) out.push(list.slice(i, i + n));
  return out.length ? out : [[]];
}

/** robots.txt (0102): every index file, then each child sitemap of the first index (the site's own files and the place
 *  files, at most 1,000 lines), so a crawler reading robots.txt alone finds them too. */
export async function robotsSitemaps(): Promise<string[]> {
  const [site, n] = await Promise.all([siteEntries(), indexCount()]);
  const children = site.map((x) => /<loc>([^<]+)<\/loc>/.exec(x)?.[1]?.replace(/&amp;/g, '&') ?? '').filter(Boolean).slice(0, 1000);
  return [sitemapUrl.index(1), ...Array.from({ length: n - 1 }, (_, i) => sitemapUrl.index(i + 2)), ...children];
}

/** How many index files there are (robots.txt names each). */
export async function indexCount(): Promise<number> {
  const [site, v] = await Promise.all([siteEntries(), vIndex(0, 1)]);
  return Math.max(1, Math.ceil((site.length + (v?.total ?? 0)) / INDEX_SIZE));
}
/** Index file n (1 is /sitemap.xml): the site's sitemaps and the place files first, then the vehicle files in the
 *  database's order. */
export async function sitemapIndex(n = 1): Promise<Response> {
  const all = await siteEntries();
  const site = n === 1 ? all : [];
  const offset = n === 1 ? 0 : (n - 1) * INDEX_SIZE - all.length;
  const v = await vIndex(offset, INDEX_SIZE - site.length);
  const files = (v?.files ?? []).map((f) => sm(sitemapUrl.vehicles(f.file), iso(f.lastmod)));
  if (!site.length && !files.length) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${site.join('')}${files.join('')}</sitemapindex>\n`, { headers: XML });
}

export async function sitemapFile(name: Exclude<SitemapName, 'priority'>): Promise<Response> {
  const all = await rows();
  return urlset(entries(name, all, [], name === 'hubs' ? await hubRows(all) : []), name === 'cars');
}
/** Part n of the priority sitemap (/sitemap-priority-<n>.xml, 0124); 404 past the last part. */
export async function prioritySitemapFile(n: number): Promise<Response> {
  const [all, prio] = await Promise.all([rows(), priorityRows()]);
  const parts = chunk(entries('priority', all, prio, await hubRows(all)), PRIORITY_CHUNK);
  if (!Number.isInteger(n) || n < 1 || n > parts.length) return NOT_FOUND();
  return urlset(parts[n - 1]!, false);
}
function urlset(e: Array<{ loc: string; lastmod: string | null; images?: string[] }>, img: boolean): Response {
  const body = e.map((x) => `<url><loc>${esc(x.loc)}</loc>${x.lastmod ? `<lastmod>${x.lastmod}</lastmod>` : ''}${(x.images ?? []).map((i) => `<image:image><image:loc>${esc(i)}</image:loc></image:image>`).join('')}</url>`).join('\n');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"${img ? ' xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"' : ''}>\n${body}\n</urlset>\n`, { headers: XML });
}

const NOT_FOUND = () => new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=0, s-maxage=600' } });
const HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n';
const url = (base: string, r: { path: string; lastmod: string | null }) => `<url><loc>${esc(base + r.path)}</loc>${r.lastmod ? `<lastmod>${iso(r.lastmod)}</lastmod>` : ''}</url>\n`;

/** A file name's tree and its base file: "t-car-hire-toyota-years" is the car-hire tree's "toyota-years". */
export function splitFile(file: string, terms: string[]): { prefix: string; base: string; to: (p: string) => string } | null {
  const tries: Array<[string, (p: string) => string]> = [['', (p) => p], ['buy-', (p) => `/buy${p.slice(5)}`], ...terms.map((t) => [`t-${t}-`, (p: string) => `/t/${t}${p.slice(5)}`] as [string, (p: string) => string])];
  for (const [prefix, to] of tries.sort((a, b) => b[0].length - a[0].length)) {
    if (file.startsWith(prefix) && BASE_FILE.test(file.slice(prefix.length))) return { prefix, base: file.slice(prefix.length), to };
  }
  return null;
}

/** One vehicle sitemap (/sitemap-vehicles/<file>.xml); 404 for a file that does not exist or a tree switched off. A
 *  place and colour file is streamed: its pairs are read up to 600 at a time within one trim (about 8,000
 *  addresses) by keyset (the pair after the last one read), never by offset. */
export async function vehicleSitemapFile(file: string): Promise<Response> {
  if (!/^[a-z0-9-]{1,120}$/.test(file)) return NOT_FOUND();
  const terms = (((await rpc('vehicle_tiers', {}, SR)) as unknown as { terms?: Array<{ slug: string }> } | null)?.terms ?? []).map((t) => t.slug);
  const f = splitFile(file, terms);
  if (!f || !(await rpc('vehicle_sitemap_tree', { p_prefix: f.prefix }, SR))) return NOT_FOUND();
  const base = siteUrl();
  const tier = /^tiers-(\d+)$/.exec(f.base);
  if (tier) {
    const n = Number(tier[1]);
    type T = { g: number; path: string | null; lastmod: string | null };
    const slice = async (after: number) => ((await rpc('vehicle_tier_sitemap', { p_file: n, p_after: after, p_limit: 600 }, SR)) ?? []) as unknown as T[];
    // a file past the last is a 404; a file whose places have no pages (a region switched off) is an empty list
    if (n < 1 || n > Number(await rpc('vehicle_tier_files_count', {}, SR))) return NOT_FOUND();
    const first = await slice(-1);
    const enc = new TextEncoder();
    const stream = new ReadableStream<Uint8Array>({
      async start(c) {
        c.enqueue(enc.encode(HEAD));
        let rowsT = first;
        while (rowsT.length) {
          c.enqueue(enc.encode(rowsT.flatMap((r) => (r.path ? [url(base, { path: f.to(r.path), lastmod: r.lastmod })] : [])).join('')));
          rowsT = await slice(Math.max(...rowsT.map((r) => r.g)));
        }
        c.enqueue(enc.encode('</urlset>\n'));
        c.close();
      }
    });
    return new Response(stream, { headers: XML });
  }
  const rowsV = ((await rpc('vehicle_sitemap', { p_file: f.base }, SR)) ?? []) as unknown as Array<{ path: string; lastmod: string | null }>;
  if (!rowsV.length) return NOT_FOUND();
  return new Response(HEAD + rowsV.map((r) => url(base, { path: f.to(r.path), lastmod: r.lastmod })).join('') + '</urlset>\n', { headers: XML });
}

/** One file of place pages: /sitemap-places/<vertical>.<term>.<page>.xml (a primary key range of places, 0095). */
export async function placeSitemapFile(file: string): Promise<Response> {
  const m = /^(rental|sale|detailing|bodyshop)\.([a-z0-9-]+)\.(\d{1,6})\.xml$/.exec(file);
  if (!m) return new Response('Not found', { status: 404 });
  const rowsP = ((await rpc('place_sitemap', { p_vertical: m[1]!, p_term: m[2]!, p_page: Number(m[3]) }, SR)) ?? []) as unknown as Array<{ path: string; lastmod: string | null }>;
  const base = siteUrl();
  const body = rowsP.map((x) => `<url><loc>${esc(base + x.path)}</loc>${x.lastmod ? `<lastmod>${x.lastmod.slice(0, 10)}</lastmod>` : ''}</url>`).join('\n');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${body}\n</urlset>\n`, { headers: XML });
}
