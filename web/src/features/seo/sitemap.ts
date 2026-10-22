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

// The vehicle pages (migration 0092): one sitemap of the makes, then one per make and level (toyota-models,
// toyota-years, toyota-trims), each far under the 50,000 addresses a sitemap may hold. Only indexed pages.
type VFile = { file: string; urls: number; lastmod: string | null };
export const VEHICLE_FILE = /^(makes|[a-z0-9]+(-[a-z0-9]+)*-(models|years|trims))$/;
export const vehicleFiles = async () => ((await rpc('vehicle_sitemap_files', {})) ?? []) as unknown as VFile[];

export async function sitemapIndex(): Promise<Response> {
  const [all, vfiles] = await Promise.all([rows(), vehicleFiles()]);
  const body = SITEMAPS.map((n) => {
    const e = entries(n, all);
    const last = e.map((x) => x.lastmod).filter(Boolean).sort().pop();
    return `<sitemap><loc>${esc(`${siteUrl()}/sitemap-${n}.xml`)}</loc>${last ? `<lastmod>${last}</lastmod>` : ''}</sitemap>`;
  }).join('') + vfiles.map((f) => `<sitemap><loc>${esc(`${siteUrl()}/sitemap-vehicles/${f.file}.xml`)}</loc>${f.lastmod ? `<lastmod>${iso(f.lastmod)}</lastmod>` : ''}</sitemap>`).join('');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${body}</sitemapindex>\n`, { headers: XML });
}

export async function sitemapFile(name: SitemapName): Promise<Response> {
  const e = entries(name, await rows());
  const img = name === 'cars';
  const body = e.map((x) => `<url><loc>${esc(x.loc)}</loc>${x.lastmod ? `<lastmod>${x.lastmod}</lastmod>` : ''}${(x.images ?? []).map((i) => `<image:image><image:loc>${esc(i)}</image:loc></image:image>`).join('')}</url>`).join('\n');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"${img ? ' xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"' : ''}>\n${body}\n</urlset>\n`, { headers: XML });
}

/** One vehicle sitemap (/sitemap-vehicles/<file>.xml); 404 for a file that does not exist. */
export async function vehicleSitemapFile(file: string): Promise<Response> {
  if (!VEHICLE_FILE.test(file)) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  const rowsV = ((await rpc('vehicle_sitemap', { p_file: file })) ?? []) as unknown as Array<{ path: string; lastmod: string | null }>;
  if (!rowsV.length) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=0, s-maxage=600' } });
  const base = siteUrl();
  const body = rowsV.map((r) => `<url><loc>${esc(base + r.path)}</loc>${r.lastmod ? `<lastmod>${iso(r.lastmod)}</lastmod>` : ''}</url>`).join('\n');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${body}\n</urlset>\n`, { headers: XML });
}
