import { sitemapIndex } from '@/features/seo/sitemap';
// The sitemap index files after the first (0097): /sitemap-index/2.xml holds sitemaps 50,001 to 100,000, and so on.
// robots.txt names every one. Read on each request, never at build.
export const dynamic = 'force-dynamic';
type P = { params: Promise<{ file: string }> };
export async function GET(_req: Request, { params }: P) {
  const m = /^([2-9]|[1-9]\d+)\.xml$/.exec((await params).file);
  if (!m) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return sitemapIndex(Number(m[1]));
}
