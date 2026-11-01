import type { MetadataRoute } from 'next';
import { env } from '@/lib/env';
import { coreScope, crawlerGuard, landingPaths, robotsSitemaps } from '@/features/seo/sitemap';
import { OUT_OF_SCOPE, allowLines } from '@/lib/edge/crawl-scope';
import { siteUrl } from '@/lib/site';
import { ANSWER_CRAWLERS, BLOCKED_CRAWLERS, CRAWL_DELAY_S, FULL_SCOPE_CRAWLERS, PRIVATE_PATHS, SLOW_CRAWLERS } from '@/features/seo/crawlers';

// docs/blueprint/14-seo.md section 10. Read on each request (0097): it names every sitemap index file.
export const dynamic = 'force-dynamic';
// Staging is closed to crawlers. Query strings on the public pages are views
// for people (filters, dates); the clean address is the one to index.
// AI answer engines and search crawlers are named in their own group (docs/changes/2026-10-23-ai-search.md): a crawler
// that finds a group with its name ignores the "*" group, so the group repeats the same private paths, and naming them
// says plainly that the owner wants them (several engines treat an unnamed AI crawler as unwelcome on some hosts).
export default async function robots(): Promise<MetadataRoute.Robots> {
  if (env().APP_ENV === 'staging') return { rules: [{ userAgent: '*', disallow: '/' }] };
  // R23, the search scope (Settings > Vehicle pages): Full, every public page as before; Core (src/lib/edge/crawl-scope.ts),
  // the multiplying trees are out of every crawler's reach and the landing pages under /car-rental/ are allowed by name (a
  // longer rule wins over the Disallow)
  const [core, guard] = await Promise.all([coreScope(), crawlerGuard()]);
  const landing = allowLines(await landingPaths().catch(() => []));
  // the search scope (Settings > Vehicle pages) for every crawler; Core keeps them to the crawl scope
  const allow = ['/', '/llms.txt', '/llms-full.txt', ...(core ? landing : [])];
  const disallow = [...PRIVATE_PATHS, ...(core ? OUT_OF_SCOPE : [])];
  // 0324 (the owner's decision): every crawler reaches every page again; while the month's crawler guard is on, the crawlers
  // that are not search or answer crawlers keep to the crawl scope until the month ends (search and answer crawlers never)
  const scoped = guard ? { allow: ['/', '/llms.txt', '/llms-full.txt', ...landing], disallow: [...PRIVATE_PATHS, ...OUT_OF_SCOPE] } : { allow, disallow };
  const full = new Set<string>(FULL_SCOPE_CRAWLERS);
  const slow = new Set<string>(SLOW_CRAWLERS);
  return {
    rules: [
      { userAgent: ANSWER_CRAWLERS.filter((b) => full.has(b)), allow, disallow },
      { userAgent: ANSWER_CRAWLERS.filter((b) => !full.has(b) && !slow.has(b)), ...scoped },
      // 2026-10-30: the training crawlers, one page every 10 seconds; the SEO tools and scrapers, nothing
      { userAgent: [...SLOW_CRAWLERS], ...scoped, crawlDelay: CRAWL_DELAY_S },
      { userAgent: [...BLOCKED_CRAWLERS], disallow: ['/', ...PRIVATE_PATHS] },
      { userAgent: '*', allow: scoped.allow.filter((a) => a !== '/llms.txt' && a !== '/llms-full.txt'), disallow: scoped.disallow }
    ],
    // 0102: the index files, then each child sitemap of the first (src/features/seo/sitemap.ts robotsSitemaps)
    sitemap: await robotsSitemaps().catch(() => [`${siteUrl()}/sitemap.xml`])
  };
}
