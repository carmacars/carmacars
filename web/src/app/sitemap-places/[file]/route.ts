import { placeSitemapFile } from '@/features/seo/sitemap';
// The place pages' sitemap files (0095), read from the database on request (primary key ranges, no page rendered).
export const dynamic = 'force-dynamic';
export async function GET(_: Request, { params }: { params: Promise<{ file: string }> }) { return placeSitemapFile((await params).file); }
