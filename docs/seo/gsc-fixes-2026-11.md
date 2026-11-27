# Search Console issues and fixes, November 2026

Release 50 hotfix 2. Every Search Console issue the data shows for carmacars.ca, its cause and the fix at the source.
Data: `search_console_issues` (connector, Nov 27), the gsc workflow run 45924183998 (Nov 27 01:43 UTC), `heal_status`,
`site_health`, and the live pages. What no stored data covers is said plainly.

## Does the auto-correct fix Search Console errors?

Not as it was. Evidence:

- `gsc_rewrite_on` (2640) rewrites the copy of landing pages and guides ranking 8 to 20 or clicked under 1%: it improves
  ranking, it fixes no error.
- `gsc_inspect` and the coverage sample (0564, 1860) inspect addresses from our own sitemaps, which exist, so they never
  met a 404: the self-healing gsc playbooks (4800: redirect a missing car page, restart on 5xx) show 0 successes and 0
  failures. Search Console's Pages report (the real error list) has no API.
- Fixed: the workflow now checks the pages Google shows in search (its Search Analytics pages, top 400 by impressions) on
  the live site and stores a 404, 410 or 5xx as an error, which the self-healing matches (`web/scripts/gsc-coverage.mjs`,
  `web/src/features/seo/coverage.ts`).

## Issues

| Area | What the data shows | Cause | Fix |
|---|---|---|---|
| Sitemaps: `/sitemap-families.xml` error, 0 addresses (read Nov 26) | Live file: a valid empty `urlset` | A failed database read answered an empty file instead of an error | A failed read answers 503 with Retry-After (Google retries); the tracker pages moved to `/sitemap-pages.xml`, which needs no slow read (`sitemap.ts`, `sitemap-paths.ts`) |
| Sitemaps: errors on files the property no longer holds (`sitemap-places-bodyshop.hail-damage-repair.14.xml`, `.16.xml`) | Shown with errors in Admin; the run of Nov 27 holds 500 files with 2 errors | `app.gsc_sitemap_latest` kept the last row of every file ever stored (873 for a property of 500) | The view holds the last run only (5160) |
| Sitemaps: `sitemap-vehicles-tiers-95.xml` error (49,491 addresses) | One error, last read Nov 25 | A slow read (the file streams pairs from the database) | The workflow resubmits errored files each run (existing); the database speed is the busy-database fix (another helper). Not changed here |
| Not found (404), soft 404 | 0 in the 150 inspected | The sample cannot meet them (above) | The known-pages check (above); a missing car page then gets its 301 by itself (4800) |
| Server errors (5xx) | 0 inspected; `site_health` car page check failing with 403 since Nov 6 | The uptime check is refused by the site (403), not a Google error | Reported for the owner of the uptime check; the known-pages check stores real 5xx Google would see |
| Crawled, currently not indexed | 60 stored (3 in the last sample) | Thin long-tail pages among 10.1 million submitted addresses | Every SEO page now links the money pages (the eight offers, the OPCF 27 and software pages); the 2640 rewrite queue keeps improving landing pages |
| Discovered, currently not indexed | 2,125 stored; 43 of 46 known in the last sample | Crawl demand, not errors: Google discovers more than it crawls | IndexNow unstuck (below); money pages linked from every page; the search scope (Core) exists if the owner wants fewer long-tail addresses (his decision of Nov 12 keeps every page open) |
| Unknown to Google | 6,165 stored; 104 of 150 in the sample | Long-tail files never read yet | As above |
| Duplicates and canonicals | No duplicate state in the stored data | Synonym pages name their group's page as canonical (2402, 0115); query-string views answer crawlers 301 to the clean address (`bot-shield.ts`) | No change needed |
| Redirects | No redirect error stored | www answers 301 to the canonical host; http answers 301 to https | No change needed |
| HTTPS | No issue stored | HSTS with preload, https redirect at the edge | No change needed |
| Core Web Vitals | Not in any stored data (no CrUX read) | Unknown | Not claimed. Next step: read the CrUX API in the gsc workflow |
| Mobile usability | Google retired the report and its API in December 2023 | n/a | None |
| Structured data | Not in any stored data (the Rich results report has no API) | Unknown | Pages emit BreadcrumbList, FAQPage, Service, Product, ItemList; the new pages add Service and FAQPage. Not verified against Google's report |
| IndexNow | Key file answers; 8,580 changed pages waiting, 0 sent in a day; the sweep waits "changed pages first" | Only the site's search job sends changed pages, and it had stopped reaching them, so nothing moved | The gsc workflow sends the changed pages itself (5165 `server_indexnow_changed_claim`, every 3 hours); changed pages outside the search scope no longer hold the sweep |

## Crawl rate

- **Sitemaps**: segmented already (priority parts, pages, cars, landing pages, guides, hubs, families, languages, places,
  vehicles). The tracker and software pages are now in the pages file. lastmod is the later of the page's own date and
  the content epoch (1100), so it moves only when the content does.
- **IndexNow on change**: unstuck (above).
- **Internal links to money pages**: every SEO page family carries the tracker, owner program, chauffeur, rental,
  long-term, insurance replacement, body shop and detailing offers, each linking to its form (`catalog.ts` `LEAD_KEYS`,
  tested by `families-offers.test.ts`); place pages list the chauffeur, owner and tracker pages too.
- **Fast answers for Googlebot**: Googlebot and Bingbot pass the scraper guard (they name themselves; Cloudflare verifies
  them on the Worker) and are never paced (`scraper-guard.ts`, `bot-shield.ts`). The busy-database answers are the other
  helper's work; this branch changes nothing there.
- **Crawl traps**: query-string views are disallowed in robots.txt and answered 301 for crawlers; portal pages 403.
  The long-tail trees stay open by the owner's decision; Settings > Vehicle pages > Core closes them if he chooses.
- **Request indexing by API**: Google's Indexing API is allowed only for job postings and livestreams. The open roles
  (`/careers/<role>`, JobPosting) qualify; it needs the `indexing` scope on the Search Console connection, which takes
  the owner's consent click. Not built here.
