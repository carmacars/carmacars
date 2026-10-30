# Website requests and Worker CPU: crawlers answered early, fewer heartbeats (no migration)

Website requests were at 70% of the 10 million a month and Worker CPU about ten times the allowance.

## What drives it (from the code)

- Every page view, every photo under `/media/` (the public photo bucket through the Worker) and every Live visitors
  heartbeat (`/api/t`, every 45 seconds per open tab) is a Worker request. Static files (`/_next/static`, `public/`)
  are served by Workers Assets without running the Worker (`wrangler.jsonc` has no `run_worker_first`): no change.
- CPU: a page the edge copy does not have is a full render (about a second of CPU on a fresh isolate). The millions of
  programmatic car pages (`/cars/<make>/<model>/...`, `/buy/...`, `/t/...`) are rendered on demand, so every crawler
  reading them pays a render per page; a query-string view (`/cars?...`, campaign tags) is never kept, so it is always
  a render; a portal page (`/admin`, `/book`, ...) opened by a crawler that ignores robots.txt is a render too.
- Not a driver: the cron (every 5 minutes, 8,640 a month, idle ticks load nothing), staff screen polling (already
  paused while the tab is hidden; the chat and phone inboxes call the database directly, not the Worker).

## Changes

- `web/src/lib/edge/bot-shield.ts` (unit tests in `bot-shield.test.ts`), run first in `custom-worker.ts`, before the
  session refresh and the app:
  - SEO tools and scrapers (AhrefsBot, SemrushBot, MJ12bot, DotBot, PetalBot, Bytespider, DataForSeoBot, BLEXBot and
    others): 403 on every page, cached a day; robots.txt and the API stay open to them.
  - A crawler (its user agent says bot, crawler or spider) on a portal or sign-in page: 403 with `noindex`.
  - A crawler on a query-string view robots.txt already keeps out (`/cars?`, `/cars/...?`, `/car-rental/...?`,
    `/guides/...?`, `/rent/`, `/buy/`, `/detailing/`, `/body-shop/`): 301 to the clean address, which the edge copy
    answers without loading the app. People, headless browsers (the end-to-end tests) and scripts are never touched.
- robots.txt (`web/src/app/robots.ts`, `web/src/features/seo/crawlers.ts`): the training crawlers (GPTBot, ClaudeBot,
  CCBot, Meta-ExternalAgent, Meta-WebIndexer, FacebookBot, Amazonbot, GoogleOther, cohere-ai) keep every public page
  with `Crawl-delay: 10`; the search and answer crawlers keep no delay; the SEO tools above get `Disallow: /`.
- Photos (`/media/`): served from the data centre's cache (a day) before reading R2.
- Live visitors heartbeat (`web/src/features/live/heartbeat.ts`): a visible tab nobody touches for 15 minutes stops
  beating; a touch, key or scroll starts it again. A screen left open on a desk was 80 requests an hour.
- HTML keeps `no-cache` for browsers (pages kept from an old deploy lost their styles, October 21): the per-request
  nonce means Cloudflare's cache cannot hold the HTML in front of the Worker, so the saving is CPU, not requests.

## Expected effect

Fewer renders for crawlers (the scrapers' and the query-string views' renders go away entirely, and training crawlers
slow to one page every 10 seconds each), so most of the CPU over the allowance should go. Requests drop by the
scrapers' share and by the idle heartbeats; photos still count as requests until they move to their own address
(below). Check Workers > carmacars-prod > Metrics (CPU time, requests) a week after the deploy.

## Cloudflare dashboard settings for the owner (not changed by this work)

1. Security > Bots: turn on **Bot Fight Mode** (free), or on Pro **Super Bot Fight Mode**: "Definitely automated" =
   Block, "Verified bots" = Allow, "Static resource protection" off.
2. Security > Settings (or Bots): **Block AI bots** off (the owner wants the AI answer engines), **AI Labyrinth** on.
3. Security > WAF > Rate limiting rules (one free rule): requests to `/cars/` from one IP above 60 in 10 seconds:
   Block for 10 seconds (people never browse that fast).
4. Caching > Configuration: **Browser Cache TTL** = Respect existing headers; **Tiered Cache** (Smart Tiered Cache) on.
5. Photos without the Worker: R2 > `carmacars-prod-vehicle-public` > Settings > Custom Domains: connect
   `media.carmacars.ca`, add a Cache Rule (hostname `media.carmacars.ca`: eligible for cache, edge TTL 1 day), then set
   the build variable `NEXT_PUBLIC_VEHICLE_PHOTOS_URL=https://media.carmacars.ca` and deploy. Every photo request then
   stops counting against the Worker.
6. Workers > carmacars-prod > Settings: keep **Workers Logs** sampling at 10% or less if logs are on (observability
   is on in `wrangler.jsonc`).

## Guides
No guide change: no screen changed.
