import type { MetadataRoute } from 'next';
import { env } from '@/lib/env';
import { robotsSitemaps } from '@/features/seo/sitemap';
import { siteUrl } from '@/lib/site';
import { ANSWER_CRAWLERS, PRIVATE_PATHS } from '@/features/seo/crawlers';

// docs/blueprint/14-seo.md section 10. Read on each request (0097): it names every sitemap index file.
export const dynamic = 'force-dynamic';
// Staging is closed to crawlers. Query strings on the public pages are views
// for people (filters, dates); the clean address is the one to index.
// AI answer engines and search crawlers are named in their own group (docs/changes/2026-10-23-ai-search.md): a crawler
// that finds a group with its name ignores the "*" group, so the group repeats the same private paths, and naming them
// says plainly that the owner wants them (several engines treat an unnamed AI crawler as unwelcome on some hosts).
export default async function robots(): Promise<MetadataRoute.Robots> {
  if (env().APP_ENV === 'staging') return { rules: [{ userAgent: '*', disallow: '/' }] };
  return {
    rules: [
      { userAgent: [...ANSWER_CRAWLERS], allow: ['/', '/llms.txt', '/llms-full.txt'], disallow: [...PRIVATE_PATHS] },
      { userAgent: '*', allow: '/', disallow: [...PRIVATE_PATHS] }
    ],
    // 0102: the index files, then each child sitemap of the first (src/features/seo/sitemap.ts robotsSitemaps)
    sitemap: await robotsSitemaps().catch(() => [`${siteUrl()}/sitemap.xml`])
  };
}
