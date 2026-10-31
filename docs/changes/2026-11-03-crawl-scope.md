# The crawl scope: Worker CPU within its allowance (no migration of its own; 0220 for IndexNow)

The owner's request (Release 23, first): Settings > Usage showed the Worker's CPU time at 1.09 billion ms for October
against 30 million included (about US$21 above it and climbing) and website requests at 96% of 10 million.

**The cause, in plain words.** The vehicle and place pages multiply (each trim in each place and colour, each search term,
for sale, detailing and body shop): Settings > Vehicle pages counted 2.6 trillion addresses in 52 million sitemaps, and
the IndexNow sweep pushed millions of them to Bing. Search engines and other crawlers then fetched them one by one. Every
address is different, so no cache helps: each is a fresh render of about 100 ms of CPU (1.09 billion ms over about 9.6
million requests). The cron jobs and people's visits are a small part.

What changed (web/src/lib/edge/crawl-scope.ts, one list used everywhere):

- Crawlers are invited to a bounded set of about 23,000 addresses: the fixed pages, the fleet's cars, the landing pages,
  the guides and the vehicle tree down to the trim (144 makes, 2,089 models, 17,835 model years, 2,490 trims).
- robots.txt disallows `/t/`, `/buy/`, `/cars/*/*/*/*/` (below the trim: places and colours), `/car-rental/` (allowing each
  landing page by its exact address), `/detailing/*/`, `/body-shop/*/` and `/places/` for every crawler group.
- The sitemaps list only the scope: no place files, no tiers files, no for-sale or term trees (they answer 404, so Search
  Console drops them).
- IndexNow's sweep sends the priority list only, inside the scope, once a week (0220).
- The Worker entry answers a crawler on an out-of-scope deep page 403 before the app loads (bot-shield.ts, kept a day by
  the CDN). People see every page as before.
- Hard guard (the owner's choice: from 70% of the month's included CPU time): the five-minute tick asks the database
  (server_jobs_due cpu_guard) and keeps a flag in the Worker's KV; while it is up a crawler asking for a catalog page
  (/cars/<make>/..., /car-rental/..., /makes, /places, /guides/...) gets 503 with Retry-After a day, never a render.

**Expected CPU.** Well-behaved crawlers read robots.txt about daily and stop fetching the disallowed trees at once. The
scope is about 23,000 pages: even crawled five times a month at about 100 ms that is about 12 million ms, and the edge
copies answer repeat visits. With people's visits and the cron jobs, about 15 to 20 million CPU ms a month, under the 30
million included; the 70% guard caps a bad month.

Also in this change:

- /delivery: "Delivery costs from" is never below the delivery minimum of Program settings (it said $0 for a car with no
  fee of its own; app.delivery_fee already prices it so), and the page names the Delivery area text of Site settings
  ("All of Ontario") instead of the service area. The car page's delivery line too (web/src/lib/delivery.ts).
- Settings > Usage, R2 storage: the usage workflow now prints each bucket's size (`r2 buckets` notice), so the bucket
  filling the 10 GB is named. The photo shrinking of 2026-10-30 is in the code (new uploads only); the WAL changes of
  2026-10-30 need the manual steps on the server written there (nothing was run). See the release report.

## Guides

- `admin/search-car-pages-landing-pages-and-guides`: What search engines may read.
