import { sitemapFile } from '@/features/seo/sitemap';
// Read on each request (the CDN keeps it for the hour, cache-control in sitemap.ts), never during the build: a
// sitemap is fetched by a few crawlers a day, and the build must not depend on the database (deploy run 39310793167).
export const dynamic = 'force-dynamic';
export const GET = () => sitemapFile('guides');
