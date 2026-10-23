import { sitemapFile } from '@/features/seo/sitemap';
// 0115: the pages to crawl first (the fleet, the landing pages, the makes, the popular models, the place pages nearest
// us), first in /sitemap.xml. Read on each request (the CDN keeps it for the hour), never during the build.
export const dynamic = 'force-dynamic';
export const GET = () => sitemapFile('priority');
