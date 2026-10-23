import { moved, sitemapUrl } from '@/features/seo/sitemap';
// The old address of the index files after the first (0097). 0124: a sitemap index may only list files in its own
// directory or below, and /sitemap-index/<n>.xml listed /sitemap-vehicles/... files: moved for good to /sitemap-index-<n>.xml.
export const dynamic = 'force-dynamic';
type P = { params: Promise<{ file: string }> };
export async function GET(_req: Request, { params }: P) {
  const m = /^([2-9]|[1-9]\d+)\.xml$/.exec((await params).file);
  if (!m) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return moved(sitemapUrl.index(Number(m[1])));
}
