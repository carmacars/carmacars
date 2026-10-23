import { moved, sitemapUrl } from '@/features/seo/sitemap';
// The old address of the place sitemaps (0095), moved for good to the site's root (0124: /sitemap-places-<file>.xml).
export const dynamic = 'force-dynamic';
export async function GET(_: Request, { params }: { params: Promise<{ file: string }> }) {
  const m = /^((?:rental|sale|detailing|bodyshop)\.[a-z0-9-]+\.\d{1,6})\.xml$/.exec((await params).file);
  if (!m) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return moved(sitemapUrl.places(m[1]!));
}
