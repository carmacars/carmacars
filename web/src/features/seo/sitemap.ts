import 'server-only';
import { rpc } from '@/lib/db/repo';
import { absUrl } from '@/features/seo/meta';
import { siteUrl } from '@/lib/site';

// The sitemaps (docs/blueprint/14-seo.md section 9, migration 0061): an index, then the fixed pages with the model
// pages, the cars with their photos, the landing pages and the guides. lastmod only where the date is the content's
// own (Google uses it only when it is reliably accurate); no priority or changefreq (Google ignores them).
export const FIXED = ['/', '/cars', '/car-rental', '/guides', '/how-it-works', '/requirements', '/delivery', '/chauffeur', '/faq', '/contact', '/list-your-car', '/terms', '/privacy', '/cancellation-policy'];
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
    case 'pages': return [...FIXED.map((p) => ({ loc: url(p), lastmod: null })), ...all.filter((r) => r.kind === 'model_hub').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }))];
    case 'cars': return all.filter((r) => r.kind === 'car').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod), images: (r.images ?? []).map((i) => absUrl(i.loc)) }));
    case 'landing': return all.filter((r) => r.kind === 'landing').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
    case 'guides': return all.filter((r) => r.kind === 'article').map((r) => ({ loc: url(r.path), lastmod: iso(r.lastmod) }));
  }
}

const XML = { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'public, max-age=0, s-maxage=3600' };

export async function sitemapIndex(): Promise<Response> {
  const all = await rows();
  const body = SITEMAPS.map((n) => {
    const e = entries(n, all);
    const last = e.map((x) => x.lastmod).filter(Boolean).sort().pop();
    return `<sitemap><loc>${esc(`${siteUrl()}/sitemap-${n}.xml`)}</loc>${last ? `<lastmod>${last}</lastmod>` : ''}</sitemap>`;
  }).join('');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${body}</sitemapindex>\n`, { headers: XML });
}

export async function sitemapFile(name: SitemapName): Promise<Response> {
  const e = entries(name, await rows());
  const img = name === 'cars';
  const body = e.map((x) => `<url><loc>${esc(x.loc)}</loc>${x.lastmod ? `<lastmod>${x.lastmod}</lastmod>` : ''}${(x.images ?? []).map((i) => `<image:image><image:loc>${esc(i)}</image:loc></image:image>`).join('')}</url>`).join('\n');
  return new Response(`<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"${img ? ' xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"' : ''}>\n${body}\n</urlset>\n`, { headers: XML });
}
