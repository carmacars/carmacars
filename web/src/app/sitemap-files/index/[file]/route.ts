import { guarded, sitemapIndex } from '@/features/seo/sitemap';
// The sitemap index files after the first (0124: /sitemap-index-<n>.xml at the site's root, rewritten here by
// next.config.ts; a sitemap index may only list files in its own directory or below). Read on each request, never at build.
export const dynamic = 'force-dynamic';
type P = { params: Promise<{ file: string }> };
export async function GET(_req: Request, { params }: P) {
  const m = /^sitemap-index-([2-9]|[1-9]\d+)\.xml$/.exec((await params).file);
  if (!m) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return guarded(() => sitemapIndex(Number(m[1])));
}
