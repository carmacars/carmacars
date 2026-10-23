# Crawl speed: sitemaps Google can read, IndexNow that runs, crawlers answered fast (October 23, 2026)

Migration 0124. The owner wants Google and Bing to find and index the search pages (every year, make, model and trim,
every place and service) much faster. Search Console showed 0 discovered pages for each of the 480
`/sitemap-index/<n>.xml` files submitted; Bing's IndexNow page showed no submission from carmacars.ca; Cloudflare's
crawler report showed Googlebot 1.9k requests allowed and 342 unsuccessful in 7 days.

## 1. What was wrong: the index files listed files outside their directory

Our structure had no nested index (`/sitemap.xml` and each `/sitemap-index/<n>.xml` listed only URL-set files), so it
was not an index of indexes. It broke another rule. Google reads a sitemap index only for files "in the same directory
as the sitemap index file, or lower in the site hierarchy" (Search Central, "Manage your sitemaps with a sitemap index
file"). `/sitemap-index/2.xml` sits in `/sitemap-index/` and listed `/sitemap-vehicles/...` files, so Google read none
of them: 0 discovered, for all 480. `/sitemap.xml` at the root was legal, which is why it alone worked. Also, a sitemap
that is not submitted in Search Console "affects only descendants of the parent directory" (the sitemaps.org location
rule, which Bing follows), so `/sitemap-vehicles/x.xml` and `/sitemap-places/x.xml` could only cover addresses under
their own folders when found through robots.txt.

Every sitemap is now at the site's root:

| Before | Now |
|---|---|
| `/sitemap-index/<n>.xml` | `/sitemap-index-<n>.xml` |
| `/sitemap-priority.xml` (up to 49,500 addresses) | `/sitemap-priority-1.xml`, `-2.xml`... (10,000 each; every address in one part) |
| `/sitemap-vehicles/<file>.xml` | `/sitemap-vehicles-<file>.xml` |
| `/sitemap-places/<file>.xml` | `/sitemap-places-<file>.xml` |

- `next.config.ts` rewrites the root names to the handlers under `/sitemap-files/` (disallowed in robots.txt); the old
  addresses answer 301 to the new ones, so an old submission or link still leads somewhere.
- The site's own files (`/sitemap-pages.xml`, cars, landing, guides, hubs) and `/sitemap.xml` keep their names.
- The vehicle place-and-colour files stay at up to 50,000 addresses: five times as many files would need five times as
  many index files, past Search Console's 500. The priority list is the one split (smaller, reported per part).
- `lastmod` is unchanged: the content's own date where there is one, none otherwise.

## 2. Search Console: the files themselves, priority first (.github/workflows/gsc.yml)

`web/scripts/gsc.mjs` with the plan in `web/src/features/seo/gsc-plan.ts`, every three hours and after each production deploy:

- The property holds up to 500 sitemaps (Search Console's limit): `/sitemap.xml`, the priority parts and the site's own
  files, then the place and vehicle files that have addresses (each one fetched to check, which also leaves it at the
  edge) in the index's order, keeping those already held so their figures build up.
- The index files `/sitemap-index-<n>.xml` are not submitted: robots.txt names every one, and Google reads them from there.
- Ours that are no longer planned are removed (the 480 old index files, the old priority file).
- A scheduled run submits only what is missing and the errored ones again (a few seconds apart); a run by hand or after a
  deploy submits all of them again.
- Each sitemap's figures (discovered addresses, errors, pending, last read) are logged in the run summary and kept in
  `app.gsc_sitemap_log` (90 days; `select * from app.gsc_sitemap_latest order by submitted desc`).
- The Search Console secrets are read from the server's vault, else the hosted project's (the database moved to the
  server; the workflow used the hosted project only).
- Google's Indexing API is not used (it is only for job postings and livestreams).

## 3. IndexNow: priority first, and runs that cannot get stuck

- The sweep (0097) walked the vehicle files only, from a claim with no clock: 5,000 steps of place-and-colour pairs could
  pass the database API's statement limit, and a claim that failed sent nothing and was tried again, the same way,
  every five minutes, with no trace (the error was swallowed). Its cursor also moved only when a batch was sent, so an
  empty stretch longer than one claim was never passed.
- Now one cursor walks, in order: the site's own pages (the fleet's cars, the landing pages, the guides, the model pages),
  the priority sitemap, every place sitemap file, then the vehicle files as before; then the next round starts with
  the priority list. A claim stops after 4 seconds; a stretch without addresses moves the cursor at once; a failed claim
  is recorded (`last_error` "claim: ...", a 10 minute wait). Batches of up to 10,000 (the protocol's limit), within the
  daily ceiling (`indexnow_daily_max`, 2,000,000), a 429's Retry-After obeyed.
- The site's job starts the sweep first and runs it beside the copy job (it used to wait up to 25 seconds behind the text
  model); the five-minute tick runs the job while the sweep has priority or place addresses.
- The gsc workflow checks that IndexNow is on, that `/<key>.txt` answers with the key, and where the sweep is, then sends
  up to ten batches itself from the runner on the same cursor and quota (100,000 addresses every three hours), so the
  sweep keeps going even if the site's job cannot. Changed pages still go first through the queue (up to 500 a run).

## 4. Crawlers answered fast, and never with a 500

- The sitemaps: `s-maxage` 6 hours plus `stale-while-revalidate` a day, kept at the edge (the root names are added to the
  edge copy); a sitemap that cannot be read now is a 503 with `Retry-After: 120`, never a 500.
- The edge copy: a sitemap, robots.txt or RSC payload the site cannot give (no last good copy) is a 503 with Retry-After
  instead of the origin's 500 or a 504. Pages already got the 503 "busy" page.
- `/makes` and `/places` (the directories crawlers use to reach every model and place) are kept at the edge like the
  vehicle pages.
- After each deploy: the Worker's warm-up adds the site's own pages and hubs (`/faq` answered a cold crawler in 7.7 s),
  and the gsc workflow fetches the first 3,000 priority addresses once (status counts and timings in the run summary).

## 5. Internal links

Every page's footer lists, under Browse, the popular hubs of the priority list: Cities (the nearest places), Services
(the first terms at the nearest place), Popular makes and Popular models, twelve each (`public.seo_hub_links`, kept 5
minutes per Worker). With the directories (`/places`, `/makes`) any search page is a few clicks from any page, so
discovery does not depend on the sitemaps alone.

## Checks

Text check, typecheck, lint, unit tests (498: the plan, the sweep loop, the edge answers, the warm-up list),
`scripts/test.sh` (6,419 passed, suite 81 new), the change guides check, the generated types; end to end on a production
build (`next build`, `scripts/serve.mjs`), desktop, one worker: seo-coverage, local-seo, sitemap-index and vehicle-pages
(39 passed).

## After the deploy

1. Nothing by hand: the deploy starts the gsc workflow (warm-up, submissions, IndexNow).
2. Watch the next runs' summaries: discovered addresses per sitemap rise as Google reads the files (days, not hours).
3. Bing Webmaster Tools: submit `https://carmacars.ca/sitemap.xml` (done October 23); the IndexNow page fills as batches arrive.
4. Cloudflare's Bot Fight Mode (on, free plan) does not challenge verified bots such as Googlebot and Bingbot; leave it unless the crawler report shows them challenged.

## Guides

No guide change: no screen or step changes. The Admin guide's notes stay true (changed pages go to IndexNow by
themselves; `carmacars.ca/sitemap.xml` is the one sitemap to submit by hand, and the gsc workflow now does it too).
