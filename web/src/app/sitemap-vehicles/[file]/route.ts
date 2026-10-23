import { moved, sitemapUrl } from '@/features/seo/sitemap';
// The old address of the vehicle sitemaps (0097), moved for good to the site's root (0124: /sitemap-vehicles-<file>.xml).
export const dynamic = 'force-dynamic';
type P = { params: Promise<{ file: string }> };
export async function GET(_req: Request, { params }: P) {
  const m = /^([a-z0-9-]{1,120})\.xml$/.exec((await params).file);
  if (!m) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return moved(sitemapUrl.vehicles(m[1]!));
}
