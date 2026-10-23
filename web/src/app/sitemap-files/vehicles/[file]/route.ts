import { guarded, vehicleSitemapFile } from '@/features/seo/sitemap';
// The vehicle sitemaps (0097), e.g. /sitemap-vehicles-toyota-trims.xml (0124: at the site's root, rewritten here by
// next.config.ts): read on each request (the CDN and the edge copy keep it), never during the build.
export const dynamic = 'force-dynamic';
type P = { params: Promise<{ file: string }> };
export async function GET(_req: Request, { params }: P) {
  const m = /^sitemap-vehicles-(.+)\.xml$/.exec((await params).file);
  return guarded(() => vehicleSitemapFile(m ? m[1]! : ''));
}
