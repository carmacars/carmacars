// What the Worker entry (custom-worker.ts) answers a crawler before the app loads (2026-10-30: website requests at 70%
// of the 10 million a month, Worker CPU ten times its allowance). No imports but crawl-scope.ts: it runs in the Worker entry and in Node
// for the unit test. Keep BLOCKED_BOT in step with src/features/seo/crawlers.ts BLOCKED_CRAWLERS.
//
// - SEO tools and scrapers (no visitor comes from them, and some ignore robots.txt): 403, a day in the browser's and
//   Cloudflare's cache. robots.txt itself stays readable, so a polite one learns it is not welcome.
// - A crawler (a user agent naming itself bot, crawler or spider) on a portal or sign-in page: 403. robots.txt already
//   keeps them out; those that ignore it no longer cost a render. Never a person, never the API (webhooks, monitors).
// - A crawler on a public page's query-string view (filters, dates, campaign tags) that robots.txt keeps out: 301 to the
//   clean address, which the edge copy answers without loading the app. People keep their query strings.
// - R23, when the search scope is Core (Settings > Vehicle pages; the Worker keeps the flag): a crawler on a page outside
//   the crawl scope (crawl-scope.ts: the term trees, for sale, below the trim, a term in a place) that robots.txt keeps
//   out: 403, kept a day. In Full (the default) every public page is open to crawlers. People always see every page.

import { deepOutOfScope } from './crawl-scope.ts';

export const BLOCKED_BOT = /AhrefsBot|SemrushBot|MJ12bot|DotBot|PetalBot|Bytespider|DataForSeoBot|BLEXBot|serpstatbot|MegaIndex|SeekportBot|Barkrowler|ImagesiftBot|Timpibot|ZoominfoBot|AwarioBot|magpie-crawler|SiteAuditBot|trendictionbot|Sogou web spider/i;
/** A user agent that says it is a crawler. Not a headless browser or a script (the e2e tests and uptime checks are never
 *  refused here). A chat app's link preview that calls itself a bot (Slackbot, TelegramBot) gets no preview of a portal
 *  page, which shows nothing to a stranger anyway. */
export const CRAWLER = /bot\b|bot\/|crawler|spider|slurp/i;

/** Portal and sign-in pages, by first path segment (robots.txt PRIVATE_PATHS, the pages a crawler has no use for). */
const PORTAL = new Set(['book', 'account', 'owner', 'investor', 'admin', 'staff', 'va', 'field', 'sign-in', 'create-account', 'reset-password', 'update-password',
  'two-step', 'choose-portal', 'read-only']);
/** The public trees whose query-string views robots.txt keeps out (crawlers.ts: /cars?, /cars/*?, /car-rental/*?, ...). */
const QUERY_VIEW = /^\/(cars(\/.*)?|(car-rental|guides|rent|buy|detailing|body-shop)\/.+)$/;

export type Shield = { kind: 'pass' } | { kind: 'refuse'; reason: 'blocked' | 'portal' | 'scope' } | { kind: 'redirect'; location: string };

/** 0320: the search and answer crawlers that bring visitors (features/seo/crawlers.ts FULL_SCOPE_CRAWLERS): they read every
 *  public page the search scope allows. Any other crawler reads the crawl scope only (crawl-scope.ts), whatever the scope. */
export const SEARCH_CRAWLER = /Googlebot|Google-InspectionTool|Storebot-Google|AdsBot-Google|Mediapartners-Google|Google-CloudVertexBot|Gemini-Deep-Research|bingbot|BingPreview|msnbot|DuckDuckBot|DuckAssistBot|Applebot(?!-Extended)|OAI-SearchBot|ChatGPT-User|Claude-SearchBot|Claude-User|PerplexityBot|Perplexity-User|Meta-ExternalFetcher|Amzn-SearchBot|Amzn-User|MistralAI-User/i;
export const isSearchCrawler = (ua: string | null | undefined): boolean => !!ua && SEARCH_CRAWLER.test(ua);

/** Whether a user agent says it is a crawler (custom-worker.ts reads the search scope flag only for one). */
export const isCrawler = (ua: string | null | undefined): boolean => !!ua && CRAWLER.test(ua);

/** Whether this crawler is kept to the crawl scope on a deep page: any crawler when the search scope is Core (`coreFlag`);
 *  0324 (the owner's decision: every crawler reaches every page, about US$20 to 25 a month): a crawler that is not a
 *  search or answer crawler only while the month's crawler guard is on (`guardFlag`, Program settings crawler_guard_usd,
 *  US$40 of projected CPU above the allowance). Search and answer crawlers are never limited by the guard. Each flag is
 *  read from the tag store only when it matters. */
export async function keptToScope(ua: string | null | undefined, path: string, coreFlag: () => Promise<boolean>, guardFlag: () => Promise<boolean> = async () => false): Promise<boolean> {
  if (!isCrawler(ua) || !deepOutOfScope(path)) return false;
  if (!isSearchCrawler(ua) && (await guardFlag())) return true;
  return coreFlag();
}

export function shield(method: string, url: string, ua: string | null | undefined, core = false): Shield {
  if (!ua || (method !== 'GET' && method !== 'HEAD')) return { kind: 'pass' };
  const u = new URL(url);
  const path = u.pathname;
  if (path === '/robots.txt' || path.startsWith('/api/') || path.startsWith('/_next/')) return { kind: 'pass' };
  if (BLOCKED_BOT.test(ua)) return { kind: 'refuse', reason: 'blocked' };
  if (!CRAWLER.test(ua)) return { kind: 'pass' };
  if (PORTAL.has(path.split('/')[1] ?? '')) return { kind: 'refuse', reason: 'portal' };
  if (core && deepOutOfScope(path)) return { kind: 'refuse', reason: 'scope' };
  if (u.search && QUERY_VIEW.test(path)) {
    // Next.js's own RSC fetches carry _rsc; a crawler never sends it, but leave them alone
    if ([...u.searchParams.keys()].every((k) => k === '_rsc')) return { kind: 'pass' };
    return { kind: 'redirect', location: `${u.origin}${path}` };
  }
  return { kind: 'pass' };
}

/** The response for a shield answer other than pass. */
export function shieldResponse(s: Exclude<Shield, { kind: 'pass' }>, headers: Record<string, string>): Response {
  if (s.kind === 'redirect') return new Response(null, { status: 301, headers: { location: s.location, 'cache-control': 'public, max-age=86400', ...headers } });
  return new Response('Not available to crawlers. See /robots.txt.', { status: 403, headers: {
    'content-type': 'text/plain; charset=utf-8', 'x-robots-tag': 'noindex', 'cache-control': `public, max-age=${s.reason === 'portal' ? 3600 : 86400}`, ...headers } });
}

// 0324: R23's 503 for every crawler on the catalog from 70% of the included CPU time is retired (the owner's decision: search
// and answer crawlers are never limited); the month's crawler guard (keptToScope) replaces it.
