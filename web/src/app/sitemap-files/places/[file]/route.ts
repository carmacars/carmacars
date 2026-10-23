import { guarded, placeSitemapFile } from '@/features/seo/sitemap';
// The place pages' sitemap files (0095), e.g. /sitemap-places-rental.car-rental.1.xml (0124: at the site's root,
// rewritten here by next.config.ts), read from the database on request (primary key ranges, no page rendered).
export const dynamic = 'force-dynamic';
type P = { params: Promise<{ file: string }> };
export async function GET(_req: Request, { params }: P) {
  const m = /^sitemap-places-(.+)$/.exec((await params).file);
  return guarded(() => placeSitemapFile(m ? m[1]! : ''));
}
