# The public site stays up when the database is busy (0106)

During the vehicle catalog import and the places import (and any load spike on the Micro compute), car pages took 5 to
40 s and answered 500: visitors saw "Internal server error" or a gateway timeout. Bigger compute is not an option, so
the site now serves its last good copy, fails fast, and the imports go gently.

## 1. The last good copy of each public page

`web/src/lib/edge/page-cache.ts` (`serveEdge`, `staleKey`, `staleKeep`, `staleMatch`, `busyPage`), used by the Worker
entry `web/custom-worker.ts`:

- Every good answer (200, no Set-Cookie, a page, its RSC payload, a sitemap or robots) of a public request is also kept
  in the Cache API under `https://edge.stale/<host><path>`, for 7 days, whatever its freshness. The key has no
  deployment in it, so a copy outlives a deploy.
- When OpenNext answers 5xx (or throws), or has not answered within 4 s, the visitor gets that copy, with
  `x-edge-stale: error 500; age=...` or `slow; age=...` (and `deploy=previous` when an earlier deploy kept it),
  `x-edge-cache: STALE` and `cache-control: no-cache`. After a 5xx the page is asked for again 5 s later (at most once a
  minute per page and isolate); after a slow answer, the answer still on its way is kept when it comes.
- With no copy yet, the visitor waits (up to 25 s in all); a 5xx then becomes the "Busy for a moment, retrying" page
  (503, `Retry-After: 5`, `no-store`, never kept), which reloads by itself after 3 s, then longer. An RSC payload or a
  sitemap keeps its error.
- Only the requests `edgeKey` covers (plain public GETs, never the portals, the API or a write) and only without a
  session: a Supabase sign-in cookie or an Admin's view-as cookie always reaches the app. The site's own cookies
  (`cc_geo`, consent) do not count as a session.
- An RSC payload is served from the copy only to the deployment that kept it; a page is served whatever deployment
  kept it.

`web/scripts/serve.mjs` (the local server of the e2e tests) runs the same `serveEdge` for public pages (wait 15 s
there), and outside production takes `POST /__test/fault {path, status}` from the machine itself to make a path answer
5xx.

## 2. Fail fast

- Migration 0106: `alter role anon set statement_timeout = '2500ms'`. PostgREST applies the role's setting to every anon
  request, which is every public page's read. (A function's own `SET statement_timeout` does not limit the statement
  that calls it; checked locally.)
- `web/src/lib/db/postgrest.ts`, `supabase.ts`: a visitor's anonymous call (not during the build) has one 3 s deadline
  for the call and its quick retries (`ANON_DEADLINE_MS`), reported as `57014` and not tried again. A busy database
  fails the page in about 3 s, inside the Worker's 4 s, so the copy is served instead of holding the Worker 30 s.

## 3. Gentle imports

Migration 0106 and `web/src/lib/import-pace.ts`:

- The catalog is staged in `app.vehicle_catalog_staging` (unlogged), with COPY over the pooler when the workflow has
  the database password (`SUPABASE_DB_PASSWORD`), else through the Management API (`app.vehicle_catalog_import_stage`).
  Then `app.vehicle_catalog_import_merge(2000)` merges 2,000 rows a transaction with the same ON CONFLICT upserts as
  0097, then the trims are built a make a transaction (`app.vehicle_catalog_import_trims`), then `finish`.
- The catalog-wide refreshes are deferred while an import writes (the transaction-local setting
  `carmacars.bulk_import`, `app.bulk_import()`): the listing row cache's refresh of every car (0102's triggers on
  `vehicle_catalog_models` and `vehicle_catalog_trims`, which ran on every batch) and the trims' numbering with every
  car's catalog match (`vehicle_catalog_car_match`). They run once in `vehicle_catalog_import_finish` (and in `fail`).
- Places: a region goes in 2,000 places a transaction (`public.server_places_import_apply_chunk`: rows, then parents,
  then `server_places_import_region_done`). `server_places_import_apply` still does a region in one call with the same
  result.
- Before every transaction both imports pause (500 ms) and ask `app.db_busy()` (client sessions running a statement,
  lock waits, the longest statement) and time the question; while 6 or more sessions are running, 3 wait on a lock, a
  statement has run over 10 s or the question took over 1.5 s (4 s through the Management API), they wait 2, 4, 8, then
  15 s, at most 10 minutes before one transaction.
- The one-call `app.vehicle_catalog_import_batch` (the SQL fixture) now stages and merges at once.

Flags (`import.mjs --write`, `load.mjs`): `--chunk 2000`, `--pause-ms 500`, `--max-active 6`.

## 4. Warm pages after an import

`POST /api/jobs/warm-up` (the Worker entry, the listing worker's token): the progress of this deploy's warm-up (0102)
goes back to the start, the first share runs at once, the cron ticks do the rest. The catalog workflow calls it 75 s
after its rebuild; the places workflow after a production load. The pages it renders become their fresh and last good
copies.

## 5. Tests

- `web/src/lib/edge/page-cache-stale.test.ts`: keys, what is kept, a 500 and a slow answer served from the copy, the
  refresh, the busy page, sessions and portals, a previous deploy's copy.
- `web/src/lib/db/postgrest.test.ts`: the deadline. `web/src/lib/import-pace.test.ts`: the pace.
- `supabase/tests/74_gentle_imports.sql`: the anon timeout, the busy check, staging and chunked merge, the deferred
  refreshes, a failure, the fixture again, places in chunks with the same slugs and parents, grants.
- `web/tests/e2e/stale-on-error.spec.ts`: a car page served once still served when the app answers 500; the busy page
  for a page never served.

## 6. Guides

No guide change: the site's behaviour for visitors and the Admin screens are unchanged; this is how the Worker and the
import workflows behave under load.
