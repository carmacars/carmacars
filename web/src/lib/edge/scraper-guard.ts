// The scrapers of November 6, 2026 (hotfix r27b, docs/changes/2026-11-06-r27b-load-texts-emails.md). Workers
// Observability, two hours: 165,000 invocations, 138,000 of them from no verified bot, led by "browsers" (Windows Chrome
// 150 to 154) from RapidSeedbox Ltd (21,000 invocations, 6,300 s of CPU, about a third of the Worker's time) and a
// residential proxy pool in 40 countries, each asking for the same long-tail place pages about 12 times an hour, over
// http:// and https:// alike. Their renders kept the database's 20 connections busy: the staff's Text button and the
// Admin pages timed out (504, React error 441). Search and AI engines are never touched here: a verified bot
// (Cloudflare's verifiedBotCategory) always passes, and so does every person on a residential or mobile network.
// No imports but page-cache.ts: it runs in the Worker entry and in Node for the unit test.

import { PLACE_PAGE, PROGRAMMATIC } from './page-cache.ts';

/** Hosting and proxy networks (Cloudflare's asOrganization) that no visitor browses from. Not the clouds the site's own
 *  checks and the search engines use (Google, Microsoft, Amazon, Apple), and not OVH (the database server is there). */
export const HOSTING_NETWORK = /RapidSeedbox|M247|Datacamp|Zenlayer|HostRoyale|Psychz|ColoCrossing|GTHost|Clouvider|Contabo|Hetzner|Choopa|Vultr|Leaseweb|Hostinger|Alibaba|Tencent|Huawei Cloud|DigitalOcean|Akamai Connected Cloud|Linode|Scaleway|Aeza|Stark Industries|FranTech|PacketHub|Tzulo|xTom|Kamatera|IPXO|HostPapa|Serverion|WorldStream|Hydra Communications|Cloud Innovation|Byteplus|Oracle Cloud/i;

export interface CfLike { asOrganization?: unknown; verifiedBotCategory?: unknown; botManagement?: { verifiedBot?: unknown } }

/** A crawler Cloudflare verified (Googlebot, Bingbot, GPTBot, ClaudeBot, Applebot and the others): never limited here. */
export function verifiedBot(cf: CfLike | undefined): boolean {
  return (typeof cf?.verifiedBotCategory === 'string' && cf.verifiedBotCategory !== '') || cf?.botManagement?.verifiedBot === true;
}

/** A public page that multiplies (place and term pages, the vehicle tree, for sale, the term trees). */
export function longTail(pathname: string): boolean {
  const p = pathname.length > 1 ? pathname.replace(/\/$/, '') : pathname;
  return PLACE_PAGE.test(p) || PROGRAMMATIC.test(p);
}

/** The cookie a browser gets from the check page (and the site's own cookies, which only a browser that keeps cookies sends). */
export const CHECK_COOKIE = 'cc_h';
const SELF_AGENT = /bot\b|bot\/|crawler|spider|slurp|compatible;|-User\b|Fetcher|externalhit|WhatsApp|Slack|Discord|Telegram|LinkedIn|Google|Bing|Yahoo|Yandex|Baidu|Applebot|Mediapartners|CarmaCars|HeadlessChrome|Playwright|curl|wget|python|node|Go-http|okhttp|axios|undici/i;
/** True when the request carries a cookie of ours: the check page's, the geo notice's (every HTML page sets it) or a session. */
export function knownBrowser(cookie: string | null | undefined): boolean {
  return /(^|;\s*)(cc_h|cc_geo|cc-view-as)=|(^|;\s*)sb-[a-z0-9]+-auth-token/.test(cookie ?? '');
}

export type Guard = 'pass' | 'copy-only' | 'check';
/** 'copy-only': a page from a hosting network that is not a verified bot gets the page's kept copy (up to a week old) or
 *  429, never a render. */
/** 'check': an agent that says it is a browser, on a long-tail page, with none of our cookies: its kept copy, else a tiny
 *  page that sets a cookie and reloads (a person sees it for a moment, once), never a render. Scrapers that pose as
 *  browsers and keep no cookies (the residential proxy pool of November 6) stop there. Crawlers that name themselves,
 *  verified bots, scripts and the site's own checks are never asked. */
export function scraperGuard(method: string, pathname: string, cf: CfLike | undefined, ua?: string | null, cookie?: string | null, rsc = false): Guard {
  if (method !== 'GET' && method !== 'HEAD') return 'pass';
  if (!longTail(pathname) || verifiedBot(cf)) return 'pass';
  const org = typeof cf?.asOrganization === 'string' ? cf.asOrganization : '';
  if (org && HOSTING_NETWORK.test(org)) return 'copy-only';
  if (!ua || SELF_AGENT.test(ua) || !/Mozilla\//.test(ua) || rsc || knownBrowser(cookie)) return 'pass';
  return 'check';
}

/** The check page: sets the cookie for a day and reloads; without JavaScript a link does the same after the cookie. */
export function checkPage(headers: Record<string, string> = {}): Response {
  const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>CarmaCars</title><style>body{margin:0;font:16px/1.5 system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;background:#f7f7f5;color:#1b1b1b}</style></head>'
    + '<body><main><p>One moment, loading the page.</p><noscript><p>Turn on JavaScript, or <a href="">open the page</a>.</p></noscript></main>'
    + `<script>document.cookie="${CHECK_COOKIE}=1; Path=/; Max-Age=86400; SameSite=Lax; Secure";if(document.cookie.indexOf("${CHECK_COOKIE}=")>-1)location.reload();else document.querySelector("main p").textContent="Allow cookies for carmacars.ca to open this page."</script></body></html>`;
  return new Response(html, { status: 200, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'x-robots-tag': 'noindex', ...headers } });
}

/** http:// on the site's own hosts: the https address (301), before anything renders; null otherwise. */
export function httpsRedirect(url: string): string | null {
  const u = new URL(url);
  if (u.protocol !== 'http:' || !/(^|\.)carmacars\.ca$/i.test(u.hostname)) return null;
  u.protocol = 'https:';
  return u.toString();
}

/** The answer when a page cannot be rendered for this requester now. */
export function tooMany(retryAfterS: number, headers: Record<string, string> = {}): Response {
  return new Response('Too many requests. Try again later.', { status: 429, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', 'retry-after': String(retryAfterS), ...headers } });
}

// ------------------------------------------------------------------ cached-only mode (r27b, the owner: "this can't happen again")
// When the site cannot render (the database busy: answers 5xx or slower than 4 s), every Worker switches the long-tail
// pages to their kept copies for BUSY_MS: no render, no database query, until the server has room again. A Worker trips
// it after BUSY_TRIP failures within BUSY_WINDOW_MS (its own count); the flag is a time in the tag store, so it ends by
// itself. People and crawlers get the kept copy, or the busy page (503 with Retry-After, which search engines read as
// "come back later"); signed-in staff and the portals are never affected.
export const BUSY_KEY = 'carmacars/busy-until';
export const BUSY_MS = 10 * 60_000;
/** 1860: cached-only serving by usage. The tag store holds 1 while the month's Worker requests or CPU time are at the Program
 *  setting usage_cached_pct (70) of the allowance (the five-minute tick writes it from the database's answer, cron-gate.ts
 *  cached_only); the vehicle and SEO pages then come from the kept copy only. A page with no copy yet is rendered once (its
 *  copy then serves the rest), where busy mode answers 503: a search engine is never told to go away because of the bill. */
export const USAGE_CACHED_KEY = 'carmacars/usage-cached';
export type TailServing = 'render' | 'copy-or-busy' | 'copy-or-render';
/** How a long-tail page of a visitor without a session is served: busy mode (the database failing) wins over the usage line. */
export function tailServing(busy: boolean, usageCached: boolean, searchEngine = false): TailServing {
  // 2350: a verified search engine crawler (Googlebot, Bingbot) is never told to go away from a normal page: in busy mode
  // it gets the kept copy or a render, never the 503 busy page (Search Console listed hundreds of place pages as 5xx)
  return busy ? (searchEngine ? 'copy-or-render' : 'copy-or-busy') : usageCached ? 'copy-or-render' : 'render';
}

/** 2350: a crawler Cloudflare verified as a search engine (its verifiedBotCategory), not an AI or other bot. */
export function verifiedSearchEngine(cf: CfLike | undefined): boolean {
  return cf?.verifiedBotCategory === 'Search Engine Crawler';
}

// ------------------------------------------------------------------ the market (2350)
// The place pages keep to our market: the regions of the United States and Mexico are off (place_regions.is_enabled,
// migration 2350). A place slug ends with its region's code (gazetteer.ts: kingston-on, toddsville-ny, ...-cam), and no
// code of a US state or a Mexican state is a Canadian one, so while every region outside Canada is off (the tick's
// place_foreign flag) the Worker answers a term-and-place address of a US or Mexican place 404 before the app loads.
// The one-segment /car-rental/<slug> is left to the database (a landing page slug such as ...-near-me could end like one).
const US_CODES = 'ny|mi|oh|pa|vt|nh|me|ma|ct|ri|nj|de|md|dc|va|wv|nc|sc|ga|fl|al|ms|tn|ky|in|il|wi|mn|ia|mo|ar|la|tx|ok|ks|ne|sd|nd|mt|wy|co|nm|az|ut|id|nv|ca|or|wa|ak|hi|pr|vi|gu|as|mp';
const MX_CODES = 'agu|bcn|bcs|cam|chp|chh|coa|col|cmx|dur|gua|gro|hid|jal|mex|mic|mor|nay|nle|oax|pue|que|roo|slp|sin|son|tab|tam|tla|ver|yuc|zac';
const FOREIGN_PLACE = new RegExp(`^(?:/[a-z]{2,3})?/(?:car-rental|detailing|body-shop|buy)/([a-z0-9-]+)/[a-z0-9-]+-(?:${US_CODES}|${MX_CODES})/?$`);
/** The buying help terms (/buy/<term>/<place>); any other /buy/<a>/<b> is the vehicle tree (a make and a model). */
const SALE_TERM = /(sale|loan|financ|lease|leasing|credit|dealer|trade|sell|buy)/;
export const PLACE_FOREIGN_KEY = 'carmacars/place-foreign';
export function foreignPlacePage(pathname: string): boolean {
  const m = FOREIGN_PLACE.exec(pathname);
  if (!m) return false;
  return !/\/buy\//.test(pathname) || SALE_TERM.test(m[1]!);
}
/** The answer to a place page outside our market: a plain 404 kept a day by every cache. */
export function outOfMarket(headers: Record<string, string> = {}): Response {
  return new Response('Not found: CarmaCars serves Toronto and the Greater Toronto Area.', { status: 404, headers: {
    'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=86400', 'x-robots-tag': 'noindex', ...headers } });
}
export const BUSY_TRIP = 5;
export const BUSY_WINDOW_MS = 60_000;

/** One isolate's count of failed renders; true when this failure should switch cached-only mode on. */
export class BusyMeter {
  private fails: number[] = [];
  private tripped = 0;
  failed(now: number): boolean {
    this.fails = this.fails.filter((t) => now - t < BUSY_WINDOW_MS);
    this.fails.push(now);
    if (this.fails.length < BUSY_TRIP || now - this.tripped < BUSY_WINDOW_MS) return false;
    this.tripped = now;
    return true;
  }
}
/** Whether an answer counts as a failed render: a 5xx, or the kept copy or busy page served because the site was slow or failing. */
export function renderFailed(status: number, staleHeader: string | null): boolean {
  return status >= 500 || /^(busy|slow|error)/.test(staleHeader ?? '');
}
