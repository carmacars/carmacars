import { guarded, prioritySitemapFile } from '@/features/seo/sitemap';
// The priority sitemap in parts of 10,000 addresses (0124: /sitemap-priority-<n>.xml, rewritten here by next.config.ts),
// first in /sitemap.xml. Read on each request (the CDN and the edge copy keep it), never during the build.
export const dynamic = 'force-dynamic';
type P = { params: Promise<{ file: string }> };
export async function GET(_req: Request, { params }: P) {
  const m = /^sitemap-priority-(\d{1,3})\.xml$/.exec((await params).file);
  if (!m) return new Response('Not found', { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' } });
  return guarded(() => prioritySitemapFile(Number(m[1])));
}
