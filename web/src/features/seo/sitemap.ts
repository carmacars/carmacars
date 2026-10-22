import 'server-only';
import { rpc } from '@/lib/db/repo';
import { absUrl } from '@/features/seo/meta';
import { siteUrl } from '@/lib/site';

// The sitemaps (docs/blueprint/14-seo.md section 9, migration 0061): an index, then the fixed pages with the model
// pages, the cars with their photos, the landing pages and the guides. lastmod only where the date is the content's
// own (Google uses it only when it is reliably accurate); no priority or changefreq (Google ignores them).
export const FIXED = ['/', '/cars', '/car-rental', '/guides', '/how-it-works', '/requirements', '/delivery', '/faq', '/contact', '/list-your-car', '/terms', '/privacy', '/cancellation-policy'];
type Row = { path: string; kind: string; lastmod: string | null; images: Array<{ loc: string; title: string | null }> | null };
export const SITEMAPS = ['pages', 'cars', 'landing', 'guides'] as const;
export type SitemapName = (typeof SITEMAPS)[number];

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const iso = (d: string | null) => (d ? new Date(d).toISOString() : null);

async function rows(): Promise<Row[]> {
  return ((await rpc('sitemap_all', {})) ?? []) as unknown as Row[];
}

function entries(name: SitemapName, all: Row[]): Array<{ loc: string; lastmod: string | null; images?: string[] }> {
  const base = siteUrl();
  const url = (p: string) => base + (p === '/' ? '' : p);
  switch (name) {
    // the model pages are in the vehicle sitemaps (0092: /cars/<make>/<model> replaced the model hubs)
    case 'pages': return FIXED.map((p) => ({ loc: url(p), lastmod: null }));
    case 'cars': return all.filter((r) => r.kind === 'car').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod), images: (r.images ?? []).map((i) => absUrl(i.loc)) }));
    case 'landing': return all.filter((r) => r.kind === 'landing').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
    case 'guides': return all.filter((r) => r.kind === 'article').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
  }
}

const XML = { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'public, max-age=0, s-maxage=3600' };

// The vehicle pages (migration 0092): files per tree ("" renting, "buy-" for sale, "t-<term>-" each search term): the
// makes, one per make and level (toyota-years, split in parts of 45,000 when bigger), and the place and colour files
// tiers-1, tiers-2... (ranges of (trim, place) pairs, at most 50,000 addresses each). Only indexed pages. The index is
// split every 50,000 sitemaps: /sitemap.xml, then /sitemap-index/2.xml..., all named in robots.txt. Every list comes from
// the database's own numbering (no page is rendered, no address counted for the index).
export const INDEX_SIZE = 50_000;
const BASE_FILE = /^(makes|tiers-\d+|[a-z0-9]+(-[a-z0-9]+)*-(models|years|trims)(-\d+)?)$/;
type VIndex = { total: number; files: Array<{ file: string; lastmod: string | null }> };
const vIndex = (offset: number, limit: number) => rpc('vehicle_sitemap_index', { p_offset: offset, p_limit: limit }) as unknown as Promise<VIndex>;

/** How many index files there are (robots.txt names each). */
export async function indexCount(): Promise<number> {
  const v = await vIndex(0, 1);
  return Math.max(1, Math.ceil((SITEMAPS.length + (v?.total ?? 0)) / INDEX_SIZE));
}
/** Index file n (1 is /sitemap.xml): the site's sitemaps first, then the vehicle files in the database's order. */
export async function sitemapIndex(n = 1): Promise<Response> {
  const site = n === 1 ? await (async () => { const all = await rows(); return SITEMAPS.map((name) => {
    const e = entries(name, all);
    const last = e.map((x) => x.lastmod).filter(Boolean).sort().pop();
    return `<sitemap><loc>${esc(`${siteUrl()}/sitemap-${name}.xml`)}</loc>${last ? `<lastmod>${last}</lastmod>` : ''}</sitemap>`;
  }); })() : [];
  const offset = n === 1 ? 0 : (n - 1) * INDEX_SIZE - SITEMAPS.length;
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
 *  place and colour file is streamed: its pairs are read 600 at a time (about 8,000 addresses) by keyset (the pair
 *  after the last one read), never by offset. */
export async function vehicleSitemapFile(file: string): Promise<Response> {
  if (!/^[a-z0-9-]{1,120}$/.test(file)) return NOT_FOUND();
  const terms = (((await rpc('vehicle_tiers', {})) as unknown as { terms?: Array<{ slug: string }> } | null)?.terms ?? []).map((t) => t.slug);
  const f = splitFile(file, terms);
  if (!f || !(await rpc('vehicle_sitemap_tree', { p_prefix: f.prefix }))) return NOT_FOUND();
  const base = siteUrl();
  const tier = /^tiers-(\d+)$/.exec(f.base);
  if (tier) {
    const n = Number(tier[1]);
    type T = { g: number; path: string; lastmod: string | null };
    const slice = async (after: number) => ((await rpc('vehicle_tier_sitemap', { p_file: n, p_after: after, p_limit: 600 })) ?? []) as unknown as T[];
    const first = await slice(-1);
    if (!first.length) return NOT_FOUND();
    const enc = new TextEncoder();
    const stream = new ReadableStream<Uint8Array>({
      async start(c) {
        c.enqueue(enc.encode(HEAD));
        let rowsT = first;
        while (rowsT.length) {
          c.enqueue(enc.encode(rowsT.map((r) => url(base, { path: f.to(r.path), lastmod: r.lastmod })).join('')));
          rowsT = await slice(Math.max(...rowsT.map((r) => r.g)));
        }
        c.enqueue(enc.encode('</urlset>\n'));
        c.close();
      }
    });
    return new Response(stream, { headers: XML });
  }
  const rowsV = ((await rpc('vehicle_sitemap', { p_file: f.base })) ?? []) as unknown as Array<{ path: string; lastmod: string | null }>;
  if (!rowsV.length) return NOT_FOUND();
  return new Response(HEAD + rowsV.map((r) => url(base, { path: f.to(r.path), lastmod: r.lastmod })).join('') + '</urlset>\n', { headers: XML });
}
