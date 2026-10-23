import { moved, sitemapUrl } from '@/features/seo/sitemap';
// 0115's single priority sitemap. 0124: it is /sitemap-priority-1.xml, -2.xml... (10,000 addresses each, every address in
// one part), listed first in /sitemap.xml; this address moved for good to the first part.
export const dynamic = 'force-dynamic';
export const GET = () => moved(sitemapUrl.priority(1));
