# Worker CPU and storage growth (October 21, 2026; migration 0074)

The account moved to Workers Paid (30 million CPU ms a month included). Month to date: 94,770 requests, 7.95 million CPU
ms, about 84 ms a request. The verify run of October 21 reported, for the last 24 hours: CPU p50 13 ms, p90 559 ms,
p99 1.3 s, 229 requests stopped with Error 1102 on the free plan's limit. The Supabase project was over its free storage
(deploy-reports 1.1 GB) and the database at 239 MB of 500 MB, 161 MB of it the audit log.

## 1. Where the Worker's CPU went

Measured on a local build (`opennextjs-cloudflare build`, then `wrangler dev` in workerd with the local stack), CPU of
the workerd process per request. A fresh isolate that has to load the Next.js server spends about 1.2 s of CPU before it
renders anything (the sitemap index below); a page answered from the page cache through OpenNext costs 17 to 27 ms warm
and 90 to 100 ms on a fresh isolate. The production tail (p90 559 ms, p99 1.3 s) is the first group: every request that
reaches the Next.js server on a fresh isolate. Those were:

- the sitemaps: `force-dynamic` route handlers, rendered on every request (their `s-maxage` header is not a cache on a
  Worker custom domain: Cloudflare does not cache a Worker's own answers);
- scanners asking for `/wp-login.php`, `/.env` and the like: each a Next.js 404 render;
- the cron tick every five minutes (288 a day): `/api/jobs/listing` and `/api/jobs/seo` through the app, with nothing to
  do almost every time;
- a page cache answer served through OpenNext also re-read the entry from KV and wrote it back to the Cache API on every
  hit (the regional cache's lazy update), and parsed the whole entry (HTML, RSC payload, segments) each time.

## 2. What changed

| Change | Where | Behaviour |
| --- | --- | --- |
| Edge copy of the public pages | `web/src/lib/edge/page-cache.ts`, `web/custom-worker.ts` | The Worker entry keeps what OpenNext answered from its page cache (`x-opennext-cache: HIT`, status 200, no Set-Cookie) in the data centre's Cache API and serves it again without loading the app. Kept only for the time OpenNext itself calls the page fresh (its `s-maxage`, at most a day); then the next request goes to OpenNext, which serves the stale page and queues the rebuild as before. Plain GETs without a query string, and RSC requests by their segment header; never the portals, the API, files or signing links. The nonce and the security headers are added per response as before. Answers carry `x-edge-cache: HIT`. |
| A copy belongs to one deployment | `wrangler.jsonc` (`version_metadata`, binding `CF_VERSION_METADATA`) | The Worker's version id is part of the key, so a page kept before a deploy (naming the previous build's script files) is never served after it. Without the binding no copy is kept or served. |
| Rebuilds on demand still show at once | `web/src/lib/edge/tag-cache-gen.ts`, `web/open-next.config.ts`, `scripts/deploy/open-next/kv.config.ts` | The tag cache is wrapped: a `revalidatePath` or `revalidateTag` touching a public page moves one generation number (KV key `carmacars/edge-gen`, or a D1 table `edge_generation`); a copy kept before it (less a minute, the tag store's own delay) is not served. Portal-only rebuilds leave it alone. |
| Sitemaps | same | Kept for their hour like the pages (the hour their header always promised). |
| Scanners | `isProbe` in `page-cache.ts` | PHP, ASP, WordPress, `.env`, `.git` and similar paths get a plain 404 before the app loads. The site has none of them. |
| Idle cron ticks | `web/src/lib/edge/cron-gate.ts`, `public.server_jobs_due()` (0074) | The tick asks the database first (one PostgREST call with the service key). The listing worker and the search job run only when there is work; any doubt (no key, an error, the function missing) runs both as before. The statements and purge jobs keep their hourly runs. |
| PostgREST right after a deploy | `web/src/lib/db/postgrest.ts` | At run time an error raised before the statement ran (PGRST000 to PGRST003, the schema cache reload right after migrations; no connection, 53300, 08000, 08003, 08006, 57P03) is tried twice more after 300 and 600 ms. The likely cause of the two car pages answering 500 in the verify run right after a deploy: the first render of an hour went to PostgREST while it reloaded its schema, and the error became the page. A timeout, a refusal or a network error is not repeated. |

Not changed, on purpose:

- The edge session refresh still runs on every request with a session cookie. It costs nothing without one or with a
  token that is still good (a cookie parse); skipping it on public pages would leave the browser's Supabase client to
  refresh the token itself, the race that once signed people out after an hour (`web/src/lib/auth/edge-refresh.ts`).
- The regional cache's lazy update stays: without cache purge it is what brings a data centre's copy in line after
  another data centre rebuilt the page. With the edge copy in front, it now runs once per page per hour per data
  centre instead of on every hit.
- Static assets never reach the Worker (Workers Static Assets answers them first); `/robots.txt` answers
  `max-age=0, must-revalidate`, so it is not kept.

## 3. Measurements (local workerd, CPU ms per request)

Warm isolate, average of 30 requests after the entry is cached. Includes the local simulation of KV, D1 and the Cache
API, which runs in the same process, so production is lower; the ratio is what counts.

| Route | Before | After |
| --- | --- | --- |
| `/` | 26.3 | 9.3 |
| `/cars` | 22.7 | 11.0 |
| `/cars/porsche-911` | 21.7 | 10.3 |
| `/cars/ford-f-150` | 21.3 | 10.0 |
| `/cars/porsche-911` (RSC) | 26.3 | 8.3 |
| `/cars/porsche-911` (with cookies) | 21.7 | 10.3 |
| `/rent/porsche-911` | 16.7 | 8.0 |
| `/book/porsche-911` | 19.0 | 7.7 |
| `/car-rental/toronto` | 23.0 | 10.7 |
| `/faq` | 26.7 | 12.0 |
| `/guides` | 20.7 | 8.7 |
| `/sign-in` | 17.0 | 8.7 |
| `/sitemap.xml` | 18.0 | 7.0 |
| `/sitemap-cars.xml` | 16.0 | 6.3 |
| `/sitemap-pages.xml` | 20.0 | 6.7 |
| `/robots.txt` (unchanged path) | 17.7 | 21.3 |
| `/admin` (redirect to sign-in, unchanged path) | 50.7 | 62.3 |
| `/wp-login.php` | a Next.js 404 render | 3.3 |

Fresh isolate, first request (the page already cached in the data centre):

| Route | Before | After |
| --- | --- | --- |
| `/cars/porsche-911` | 90 | 30 |
| `/` | 100 | 40 |
| `/faq` | 100 | 20 |
| `/sitemap.xml` | 1,210 | 20 |
| `/wp-login.php` | about 1,200 (loads the Next.js server for the 404) | 10 |
| An idle cron tick | about 1,200 (loads the Next.js server, two job routes) | one PostgREST call |

A page rendered on a cache miss (the first visitor of the hour in the page cache) is unchanged, including the 1.2 s
server load on a fresh isolate. To measure on production after the deploy: the verify workflow's Worker step (CPU p50, p90,
p99) and its new failures step (below).

## 4. The Worker's failures (verify and cf-logs workflows)

`web/scripts/cf-errors.mjs` queries Workers Observability for `carmacars-prod`: invocations by outcome (ok, exception,
exceededCpu, exceededResources, canceled) for the run's window and the last 24 hours, and the newest 50 failed events
(an exception, a limit, or a 5xx answer) with the route, the message and the stack. Paths lose their query strings;
headers, cookies and bodies are never read; email addresses, tokens and long hex strings are masked. The verify workflow
stores it as `deploy-reports/<run id>/worker-errors.json` with a summary; `cf-logs.yml` does the same on demand
(hours back as input). Without Workers Observability Read on the token, the run warns and names the permission.

## 5. Storage

### deploy-reports (Supabase Storage)

`scripts/backup/prune-reports.sh` keeps verify runs (`<run id>/`) for 3 days by their newest file, only the newest
`guides/<date>/` and the newest 3 `forms/<run id>/`; anything else in the bucket is left alone. It prints every folder
kept and removed with files and size, and deletes only with `PRUNE=1` (the Storage API's bulk delete, 1,000 names a
call). `scripts/backup/prune-reports.test.sh` checks the selection offline. The live list on October 21 (dry run, nothing
deleted): 61 folders, 3,126 files, 764 MB to remove.

The backup workflow runs it every night after the backup and lists what it would remove; it removes when
`PRUNE_REPORTS` in `.github/workflows/backup.yml` is `'1'`, or when run by hand with `prune_now` (mode `prune` lists
only). The guides workflow now uploads its archive as WebP (quality 90, about two thirds of the PNG; the upkeep still
compares the PNGs before the upload).

### The audit log (migration 0074)

Live on October 21, before: 23,258 rows written by the audit trigger with 152 MB of before and after values. 9,026 were
`notification_catalogue` updates (5,975 identical, most of the rest only `updated_at`), 3,300 `seo_pages` updates
(only `snapshot_at` and `updated_at`).

- An UPDATE keeps only the columns that changed, before and after; an UPDATE that changed nothing, or only `updated_at`
  or `snapshot_at`, is not logged.
- A single value over 4 KB is kept as `{"omitted": "larger than 4 KB", "md5": ..., "bytes": ...}` (INSERT and DELETE
  still keep the whole row otherwise).
- `guide_reads` (a count of guide opens per person) and `app_events` (the internal event queue) leave the audit;
  `app.attach_audit()` leaves them out too. Money, bookings, owners, agreements, payouts, users and roles stay audited;
  only the shape of an UPDATE row changed. The redacted tables still log the change without values.
- Admin > Audit log already shows a field diff, so it reads the new rows as before.
- Existing rows are not touched. `docs/sql/2026-10-21-audit-compaction.sql` is an optional one-time compaction (not
  applied; it needs the owner's approval and a kept backup): it would remove the 13,429 no-op rows and bring the 152 MB
  of values to about 9.4 MB.
- pg_cron's run history (`cron.job_run_details`, 46,000 rows, 14 MB) is kept 7 days by a daily job
  (`carmacars-cron-history-purge`, 04:29 UTC); the uptime job's 14-day purge stays as a second line.

## 6. Tests

- Database suite (`scripts/test.sh`): `supabase/tests/52_cpu_and_storage.sql` (diff, no-op, quiet columns, large
  values, insert and delete, redacted tables, money tables, the catalogue refresh, the two tables out, the run history
  purge, `server_jobs_due` and its privileges); `03_flows.sql` lists `guide_reads` with the tables that need no
  audit trigger.
- Unit (`npm run test:unit`): `web/src/lib/edge/page-cache.test.ts` (keys, what is kept and for how long, the
  generation in KV and D1, an unreadable generation, scanners, the cron question), `postgrest.test.ts` (the run-time
  retry).
- Offline: `scripts/backup/prune-reports.test.sh`.

## 7. Follow-up: cars changed in the database alone (deploy run 39668969555)

The SEO audit and the crawl of the deploy run found `/cars/2022-toyota-corolla-grey: HTTP 308` and
`/cars/2023-honda-civic-4d19: HTTP 404`. The CI suite serves the app with `scripts/serve.mjs` (`next start`), so neither
the Worker entry's edge copy nor OpenNext was involved: the links came from Next.js's own page cache of the fleet page
(the audit collects car pages from the sitemap, which is read live, and from the links on `/cars`). End-to-end fixtures
put cars on and off the site with SQL (and 0070 publishes cars by itself in the database); when any app action rebuilt
`/cars` in between, the fleet page kept linking a car that was gone. The same happens on the live site for up to an hour.

Now the fleet's signature (the slug and model page of every car `public.fleet` returns; `src/lib/edge/fleet-sig.ts`)
is watched: the Worker's cron tick reads it through PostgREST every five minutes and, when it differs from the last one
kept in the tag store (`carmacars/fleet-sig`), calls `/api/jobs/public-rebuild`, which rebuilds every page under the
root layout and the sitemaps (on Cloudflare this also retires the edge copies). `scripts/serve.mjs` does the same every
10 seconds (`PUBLIC_REBUILD_TICK_MS`), so the end-to-end suite and the audits see what production sees. A publish,
an unpublish, a deletion or a slug change made by the app still rebuilds the pages at once, as before. No migration.
Tests: `web/src/lib/edge/page-cache.test.ts` (the signature and where it is kept), `web/tests/e2e/fleet-fresh.spec.ts`
(a car published and taken off with SQL alone appears on and leaves the fleet page, home and the cars sitemap).
