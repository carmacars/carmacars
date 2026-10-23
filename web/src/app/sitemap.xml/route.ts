import { guarded, sitemapIndex } from '@/features/seo/sitemap';
// The sitemap index (0061): robots.txt names it; each part is its own file.
// Read on each request (the CDN keeps it for the hour, cache-control in sitemap.ts), never during the build: a
// sitemap is fetched by a few crawlers a day, and the build must not depend on the database (deploy run 39310793167).
export const dynamic = 'force-dynamic';
export const GET = () => guarded(() => sitemapIndex());
