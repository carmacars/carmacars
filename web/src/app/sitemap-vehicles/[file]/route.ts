import { vehicleSitemapFile } from '@/features/seo/sitemap';
// The vehicle sitemaps (migration 0097), e.g. /sitemap-vehicles/toyota-trims.xml: read on each request (the CDN and the
// edge copy keep it for the hour), never during the build.
export const dynamic = 'force-dynamic';
type P = { params: Promise<{ file: string }> };
export async function GET(_req: Request, { params }: P) {
  const m = /^(.+)\.xml$/.exec((await params).file);
  return vehicleSitemapFile(m ? m[1]! : '');
}
