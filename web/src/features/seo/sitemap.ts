import 'server-only';
import { rpc, sharedRead } from '@/lib/db/repo';
import { absUrl } from '@/features/seo/meta';
import { siteUrl } from '@/lib/site';

// The sitemaps read as the server (public paths only), not as a visitor: a file walks thousands of pages, which the
// visitor's 2.5 s limit (0106) cut off (/sitemap.xml and /sitemap-vehicles/makes.xml answered 500, Oct 22).
const SR = { role: 'service_role' as const };

// The sitemaps (docs/blueprint/14-seo.md section 9, migration 0061): an index, then the fixed pages with the model
// pages, the cars with their photos, the landing pages and the guides. lastmod only where the date is the content's
// own (Google uses it only when it is reliably accurate); no priority or changefreq (Google ignores them).
export const FIXED = ['/', '/cars', '/car-rental', '/guides', '/how-it-works', '/requirements', '/delivery', '/chauffeur', '/faq', '/contact', '/list-your-car', '/detailing', '/body-shop', '/place-data', '/terms', '/privacy', '/cancellation-policy'];
type Row = { path: string; kind: string; lastmod: string | null; images: Array<{ loc: string; title: string | null }> | null };
// 0102: 'hubs', the model pages of the cars on the site (/cars/<make>/<model>, sitemap_all's model_hub rows). They were left
// to the vehicle sitemaps of 0097, which list nothing while the vehicle catalog is not loaded (live, Oct 22: none), so the
// 47 model pages were in no sitemap. A page in both files is harmless.
export const SITEMAPS = ['pages', 'cars', 'landing', 'guides', 'hubs'] as const;
export type SitemapName = (typeof SITEMAPS)[number];

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const iso = (d: string | null) => (d ? new Date(d).toISOString() : null);

// The site's own sitemap rows and the place file list are the same for every request: kept per Worker for 5 minutes
// (sharedRead). Google fetched hundreds of index files at once on Oct 23, each reading both again, and the busy
// database made many of them pass Google's time limit ("Couldn't fetch").
async function rows(): Promise<Row[]> {
  return ((await sharedRead('sitemap_all', () => rpc('sitemap_all', {}, SR))) ?? []) as unknown as Row[];
}

function entries(name: SitemapName, all: Row[]): Array<{ loc: string; lastmod: string | null; images?: string[] }> {
  const base = siteUrl();
  const url = (p: string) => base + (p === '/' ? '' : p);
  switch (name) {
    // the model pages are in the vehicle sitemaps (0097: /cars/<make>/<model> replaced the model hubs)
    case 'pages': return FIXED.map((p) => ({ loc: url(p), lastmod: null }));
    case 'cars': return all.filter((r) => r.kind === 'car').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod), images: (r.images ?? []).map((i) => absUrl(i.loc)) }));
    case 'landing': return all.filter((r) => r.kind === 'landing').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
    case 'guides': return all.filter((r) => r.kind === 'article').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
    case 'hubs': return all.filter((r) => r.kind === 'model_hub').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
  }
}

const XML = { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'public, max-age=0, s-maxage=21600' };

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
const shape = () => sharedRead('vehicle_sitemap_shape', () => rpc('vehicle_sitemap_shape', {}, SR)) as Promise<Shape>;
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
  try { return ((await sharedRead('place_sitemap_files', () => rpc('place_sitemap_files', {}, SR))) ?? []) as unknown as PlaceFile[]; } catch { return []; }
}
/** The site's own sitemaps and the place files (at most 49,000), first in the index. */
async function siteEntries(): Promise<string[]> {
  const [all, places] = await Promise.all([rows(), placeFiles()]);
  return [...SITEMAPS.map((name) => {
    const e = entries(name, all);
    const last = e.map((x) => x.lastmod).filter(Boolean).sort().pop();
    return `<sitemap><loc>${esc(`${siteUrl()}/sitemap-${name}.xml`)}</loc>${last ? `<lastmod>${last}</lastmod>` : ''}</sitemap>`;
  }), ...places.slice(0, 49_000).map((f) => `<sitemap><loc>${esc(`${siteUrl()}/sitemap-places/${f.file}.xml`)}</loc>${f.lastmod ? `<lastmod>${iso(f.lastmod)}</lastmod>` : ''}</sitemap>`)];
}

/** robots.txt (0102): every index file, then each child sitemap of the first index (the site's own files and the place
 *  files, at most 1,000 lines), so a crawler reading robots.txt alone finds them too. */
export async function robotsSitemaps(): Promise<string[]> {
  const [site, n] = await Promise.all([siteEntries(), indexCount()]);
  const children = site.map((x) => /<loc>([^<]+)<\/loc>/.exec(x)?.[1]?.replace(/&amp;/g, '&') ?? '').filter(Boolean).slice(0, 1000);
  return [`${siteUrl()}/sitemap.xml`, ...Array.from({ length: n - 1 }, (_, i) => `${siteUrl()}/sitemap-index/${i + 2}.xml`), ...children];
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
  const files = (v?.files ?? []).map((f) => `<sitemap><loc>${esc(`${siteUrl()}/sitemap-vehicles/${f.file}.xml`)}</loc>${f.lastmod ? `<lastmod>${iso(f.lastmod)}</lastmod>` : ''}</sitemap>`);
  if (!site.length && !files.length) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${site.join('')}${files.join('')}</sitemapindex>\n`, { headers: XML });
}

export async function sitemapFile(name: SitemapName): Promise<Response> {
  const e = entries(name, await rows());
  const img = name === 'cars';
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
