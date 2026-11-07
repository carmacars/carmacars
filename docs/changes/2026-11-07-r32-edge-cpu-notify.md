# Release 32, part A: place pages from a global copy, instant notifications, the coverage panel

Migration 0670 (SCHEMA_MARKER 0670). Branch `r32-a`.

## 1. Worker CPU: the place pages from one global copy

**Measured on November 7 (Cloudflare):** about 1,000,000 Worker requests a day at about 100 ms of CPU each; the month at
785 million CPU ms against 30 million included. Security Analytics: cache status None for 2.15M of 2.19M requests, mostly
bots walking the place pages (`/car-rental/<place>`, `/car-rental/<term>/<place>`, `/detailing/...`, `/body-shop/...`,
`/buy/...`) from the US and Mexico, and Applebot at about 441,000 a day. The owner keeps every page (no 404, no region
switch) and a stale copy is fine.

**Why they rendered:** those routes are `force-dynamic` and their only copies were the data centre's (Cache API, per
data centre): the fresh copy belongs to one deployment and lives a day, the last good copy a week (served to crawlers 3
days). A bot asking from another data centre, or after any deploy (several a day), got a fresh render.

**What changed** (`web/src/lib/edge/global-store.ts`, `page-cache.ts serveEdge`, `custom-worker.ts`):

- One copy of each place page for the whole network in R2 (the OpenNext cache bucket `NEXT_INC_CACHE_R2_BUCKET`, keys
  under `edge-pages/v1/`), gzipped, kept 30 days whatever the deploys and the rebuilds on demand. A request looks in the
  data centre's mirror first (Cache API, free: `x-edge-cache: GLOBAL-DC`), then R2 (one read: `GLOBAL`), and gets only the
  nonce rewrite. A crawler asking "changed since?" gets 304.
- A miss renders as before and the render is kept in R2 and in the mirror (in the background, after the answer).
- Only a plain GET of the HTML page without a query string, an RSC header or a server action, and never with a session
  (a signed-in visitor or an Admin viewing as someone always reaches the app). Only a real 200 render without Set-Cookie
  is kept.
- A page names its build's script files, which stay 8 days after they leave a deploy (`scripts/deploy/keep-assets.mjs`):
  a person gets a copy up to 7 days old; crawlers up to 30 days. A person past 7 days gets a render, which replaces the
  copy.
- The nonce stays per response (added after this, as before). The sitemaps and `bot-shield.ts` are unchanged.
- Cheaper miss path: with the global copy on, a place page skips the data centre's fresh copy and the crawler copy (each
  a tag store read in D1 before the render; the mirror holds the same render), and the crawler flags (search scope,
  crawler guard) are read at most every 30 seconds per isolate instead of a D1 read for each crawler request.

**Cost per request** (Workers Paid: US$0.02 per million CPU ms; R2: US$4.50 per million writes, US$0.36 per million
reads, US$0.015 per GB-month; 1M writes, 10M reads and 10 GB included a month):

| | CPU | R2 | US$ per million |
|---|---|---|---|
| a render (today) | about 100 ms (Cloudflare, measured) | none | 2.00 |
| a render kept (r32) | about 100 ms + about 1.6 ms (tee and gzip, Node estimate) | one read (the miss) + one write | 2.00 + 0.03 + 0.36 + 4.50 = 6.89 |
| a hit from R2 (another data centre) | about 2 ms (gunzip and mirror fill, Node estimate; native streams on Workers are cheaper) | one read | 0.04 + 0.36 = 0.40 |
| a hit from the mirror | under 1 ms (Node estimate: 0.4 ms) | none | 0.02 |

Each request also pays the Worker entry's fixed work (the shield, the session check, the nonce rewrite: about 1 ms,
estimate). A hit is therefore 30 to 100 times cheaper in CPU than a render. A stored page pays for its write after about
3 requests in its 30 days (4.89 / (2.00 - 0.40)). For the month: with 30 million place-page requests and N different
pages asked, the CPU per request falls by 30M / N roughly (N = 3M: about 12 ms a request, 8x; N = 1M: about 5 ms, 19x)
and the bill moves from about US$60 (CPU) to N x 6.89 + (30M - N) x 0.40 per million (N = 3M: about US$31; N = 1M:
about US$19). Storage: about 5 to 25 KB a page gzipped, so 2 million pages are 10 to 50 GB (US$0 to 0.60 a month).
Read the result after the deploy from the `x-edge-cache` values (GLOBAL, GLOBAL-DC against none) in the cf-logs workflow.

## 2. Instant notifications

- `public.server_notify_kick(p_kinds)` (0670): turns the waiting events into notices now (`app.process_events`, skip
  locked like the minute job) and answers what is due: a push (for the kinds the Worker can send), a text, an urgent email.
  When an urgent email waits it runs the email sender's own pg_cron call (`carmacars-send-outbox`) at once, at most every
  20 seconds.
- The Worker asks it after every POST that reached the app (a server action, a form, a webhook), under `waitUntil` after
  the answer, debounced per isolate (at once, then once more 2 seconds after a burst), and runs `/api/jobs/push` and
  `/api/jobs/phone` when due (`web/src/lib/edge/notify-kick.ts`).
- The cron runs every minute (`wrangler.jsonc`). The jobs keep their five-minute turn (minutes 0, 5, 10 ...; the hourly
  ones on the same minutes as before); the minutes between only ask `server_notify_kick` (one small call; the app loads
  only when a push or a text is due).
- A phone push is due when its notice is written, never at its email's due time. Customers' quiet hours and each staff
  member's own quiet hours still hold the pushes that are not urgent.
- Urgent emails skip the hour's pace: a staff alert marked urgent (0583, still at most 3 an hour per person) and a
  first-class customer email written in the last 15 minutes are claimed first and on top of the hour's pace. The day's
  cap (the providers' budgets together) still applies. Digests and the other emails keep the pace and the quiet hours.

**Added CPU (estimate):** 1,152 more cron ticks a day at about 1 to 2 ms (one database call) = about 2,000 CPU ms a day;
one database call per POST at about 0.5 ms; the push and text jobs run as before, sooner and in smaller batches. Under
0.1 million CPU ms a month, against the 30 million included.

## 3. Search Console coverage

Admin > Settings > Search already shows the stored counts (card "Index coverage (Search Console sample)", from
`public.server_gsc_coverage_trend`, migration 0564), so no new panel. What the code itself keeps out of the index: a
place page is `noindex` while its place is not indexable (`h.indexable`), a synonym term names its main term's page as
canonical, and while the search scope is Core or the month's crawler guard is on, robots.txt disallows the term and place
trees for the crawlers it covers (`crawl-scope.ts OUT_OF_SCOPE`) and the sitemaps and IndexNow leave them out. robots.txt
and the pages are unchanged.

## Guides

No guide change: the guides already say alerts arrive at once; the edge copy and the cron changes no screen.
