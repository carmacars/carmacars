// The crawl scope (Release 23, docs/changes/2026-11-03-crawl-scope.md). No imports: it runs in the Worker entry
// (custom-worker.ts through bot-shield.ts), in robots.ts, in the sitemaps and in Node for the unit test.
//
// Why: the vehicle and place pages multiply (each trim in each place and colour, each search term, for sale, detailing,
// body shop): Settings > Vehicle pages counted 2.6 trillion addresses in 52 million sitemaps. Search engines and other
// crawlers fetched them one by one, each a fresh render of about 100 ms of Worker CPU that no cache can absorb (every
// address is different): 9.6 million requests and 1.09 billion CPU ms in October against 30 million included.
//
// What crawlers are invited to read now, a bounded set (about 23,000 addresses): the fixed pages, the fleet's cars, the
// landing pages (/car-rental/<slug>, which robots.txt allows one by one), the guides, and the vehicle tree down to the
// trim (/cars/<make>/<model>/<year>/<trim>). Everything deeper or wider stays up for people, but robots.txt keeps
// crawlers out, the sitemaps and IndexNow leave it out, and a crawler that asks anyway is answered 403 at the edge
// before the app loads (one cheap response, kept a day by the CDN).

/** robots.txt Disallow lines for every crawler group (Google and Bing read * as any characters). */
export const OUT_OF_SCOPE = [
  '/t/', '/buy/', '/cars/*/*/*/*/', '/car-rental/', '/detailing/*/', '/body-shop/*/', '/places/'
] as const;

/** The paths out of scope that the edge can tell without the database: the term trees, for sale, a vehicle page below the
 *  trim, a term in a place. The one-segment /car-rental/<slug> is a landing page or a place page: robots.txt allows the
 *  landing pages by name (allowLines), so it is left to robots.txt and never refused here. */
const DEEP = /^\/(t|buy)(\/|$)|^\/cars\/[^/]+\/[^/]+\/[^/]+\/[^/]+\/[^/]+|^\/(car-rental|detailing|body-shop)\/[^/]+\/[^/]+|^\/places\/./;
export function deepOutOfScope(path: string): boolean {
  return DEEP.test(path);
}

/** Whether a public address is in the crawl scope, given the landing page paths (the sitemaps and IndexNow use it). */
export function inCrawlScope(path: string, landing: ReadonlySet<string>): boolean {
  if (deepOutOfScope(path)) return false;
  if (/^\/car-rental\/[^/]+$/.test(path)) return landing.has(path);
  return true;
}

/** robots.txt Allow lines: the landing pages under /car-rental/, exact addresses ($: nothing after). */
export function allowLines(landing: Iterable<string>): string[] {
  return [...[...landing].filter((p) => /^\/car-rental\/[a-z0-9-]+$/.test(p)).sort().map((p) => `${p}$`)];
}
