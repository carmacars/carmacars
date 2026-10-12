import type { MetadataRoute } from 'next';
import { rpc } from '@/lib/db/repo';
import { siteUrl } from '@/lib/site';

// XML sitemap: the fixed public pages, plus the canonical car pages and model hubs from
// public.sitemap_rows (0022) with their lastmod (moved only by real content changes).
export const revalidate = 3600;
const PAGES = ['/', '/cars', '/how-it-works', '/requirements', '/delivery', '/faq', '/contact', '/list-your-car', '/terms', '/privacy', '/cancellation-policy'];

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const rows = (await rpc('sitemap_rows', {})) as unknown as { path: string; kind: string; lastmod: string | null }[];
  return [
    ...PAGES.map((p) => ({ url: siteUrl() + (p === '/' ? '' : p) })),
    ...rows.map((r) => ({ url: siteUrl() + r.path, ...(r.lastmod ? { lastModified: new Date(r.lastmod) } : {}) }))
  ];
}
