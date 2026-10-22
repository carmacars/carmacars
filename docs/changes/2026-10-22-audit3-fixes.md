# Audit 3 fixes (migration 0104)

The live audit of October 22, 2026 (17:40 to 18:50 UTC) found the bugs below. Migration 0104 (schema marker 0104) and
the code changes fix them. 0102 (perf) and 0103 (livefix) come before it in the combined deploy; nothing here touches
their areas (car_page, fleet, the /book list, sitemap.xml, the /api/t beacon, live visitors) or the text alerts.

## 1. Site health (B1)

`carmacars-uptime` failed every minute from 17:36 UTC: pg_net answered "Failure when receiving data from the peer" with
no HTTP status, `app.uptime_page_result` passed a null "ok", the insert failed, the whole job rolled back and the 4
probes stayed stuck.

- `app.uptime_page_result`: no status is a failed check, with pg_net's reason ("No answer: ...").
- `app.uptime_record` (wrapped): a null "ok" is a failure.
- `app.job_uptime` (replaced): each probe is recorded in its own block (a bad row is recorded as a failure and never
  stops the others); any probe older than 15 minutes is dropped.
- The migration deletes the stuck probes.

## 2. IndexNow (B3)

All 128 queued addresses got 429; 100 had used their 5 attempts.

- `app.server_indexnow_sent`: a 429 spends no attempt.
- `app.server_indexnow_report`: a 429 pauses the whole queue (the changed addresses and the sweep) until the
  Retry-After time when the engine gives one, else until 00:05 tomorrow, Toronto time.
- `app.server_seo_claim` (wrapped): no address while the queue waits; at most `indexnow_batch` (and 500) addresses,
  within the day's room (`indexnow_daily_max`).
- `app.server_jobs_due` (wrapped): the five-minute tick runs the search job when IndexNow may send now: changed
  addresses, or the vehicle page sweep once the catalog has makes. While the queue waits, IndexNow alone never loads
  the app. `/api/jobs/seo` runs the sweep even when the copy job fails.
- `web/src/server/seo-job.ts`: sends to `https://www.bing.com/indexnow` (every IndexNow engine shares what one gets;
  api.indexnow.org refused the Worker's shared addresses), at most 10,000 addresses a request, and passes Retry-After on.
- The migration resets `attempts` on every unsent address and clears the back-off.

## 3. Partner cars: one title and heading each (B6, N20)

- `app.listing_seo_mark`: a partner car's twins are the cars of the same model and trim (a missing year matches a
  missing year). The mark is the colour when no twin has it, then the car code, then a short word ("car 7CED").
- `app.car_copy_touch_0104`, run by `app.car_copy_apply` (wrapped) for every copy put live and once for every car on
  the site: a partner car's search title and heading name the trim, never an unconfirmed year, and a twin's carry its
  mark ("Rent a Mercedes-Benz C-Class C43 AMG in Toronto (grey)"). Locked fields are kept. The copy's status and any
  AI rewrite due are untouched.
- The car page (`app/cars/[slug]/page.tsx`): the title and description use the mark (colour or car code), and the
  heading shows a partner car's trim and the mark.

## 4. Sample cars listed first (B7)

- Trigger `vehicle_listings_sample_not_featured`: a sample car is never featured; the 7 featured samples are cleared.
- `FleetBrowser`: real cars always come before sample cars, whatever the sort. (The `fleet` function is perf's area and
  is not changed.)

## 5. Text and case (B8, B9, N40)

- `app.gearbox_case`: "automatic (cvt)" becomes "Automatic (CVT)", "automatic (dual-clutch)" becomes
  "Automatic (dual-clutch)", in every copy put live and in the 15 descriptions on file. The car page's description
  keeps the gearbox as stored.
- Trigger `vehicles_a0_colour_case` (like 0087's name case): a colour in capitals is stored in proper case on insert and
  update. The 6 real cars in capitals are fixed and their copy made again (`app.car_copy_again`).

## 6. Cars waiting for a trim (N33)

The 3 real cars with a trim list keep year-make-model as their address (for example `2019-volkswagen-beetle`, the
site's address format) with a 301 from the old one (`listing_redirects`). `app.vehicle_pick_trim` (wrapped) moves the
address again when the trim is picked, leaving a 301.

## 7. Workers AI usage guard (B12)

`web/src/integrations/ai/guard.ts`: every Workers AI call goes through the usage guard (0080's `server_usage_gate`),
read at most every 30 seconds. While Workers AI is paused, nothing is asked and the call answers "quota". It sits in
the two adapters (`textGenerator`, `visionModel`), so the guide rewrite, the car copy writer, the landing pages and
guides, live chat, the phone line, the Turo email reader, the toll notice reader, the plate check, the colour reader
and the assistant all obey it. The guide rewrite stops at once when paused (`paused: true`), and
`scripts/guide-upkeep.mjs` leaves the rest of its sections for the next run.

## 8. Budget alarm

`usage_services.warn_bps = 7000` for `workers_requests` and `workers_cpu` (0097's Integration 1).

## 9. Admin To do (B16)

`web/src/features/admin/todo/group.ts`: 3 or more lines of one kind of work are one line, "Add real photos (72 cars)",
"Record the last service (10 cars)", whose button opens the list with each car's own button. Decisions about one
person, booking or owner (chats, requests, documents, applications, the insurer, invoices, signatures, owner terms)
stay lines of their own. Titles use the body font. The e2e specs open a group when there is one.

## 10. Stale duplicate flags (B13)

`app.check_listing_similarity` (wrapped) removes the open flags of the kinds it compared that it did not find again
(logged as `similarity_gone`), and closes the car's duplicate task when no blocking flag is left. The migration runs
the check, quietly, for every car with an open flag.

## 11. Import size caps (B4, N11)

Postgres cannot read the Supabase plan, so it is an Admin setting: `program_settings.db_plan` (`pro` by default; the
owner upgraded), `db_cap_pro_mb` (6,144) and `db_cap_free_mb` (450), under Settings > Vehicle pages. A trigger keeps
`vpage_import_db_cap_mb` and `place_db_cap_mb` at the plan's cap (set to it when the plan or its cap changes, never
above it), and the usage guard's database allowance follows the plan (8 GB on Pro, 500 MB on Free).

## Checks

- Database suite: new suite 69 (site health with no status and stuck probes, IndexNow back-off, Retry-After, batch and
  daily limits, partner titles and headings, marks, gearbox case, colour case, samples never featured, the trim
  address and its redirects, the budget alarm, stale flags, the plan caps). Suites 40, 52, 55 and 60 updated for the
  new rules (a 429 spends no attempt; the car code as a mark; colours in proper case; the Free allowance set in the test).
- Unit tests: `integrations/ai/guard.test.ts`, `features/admin/todo/group.test.ts`.
- Lint, typecheck; `src/lib/db/types.ts` regenerated.

## Guides

- `admin/getting-around-admin`: To do groups repeating work into one line that opens the list.
- `admin/search-car-pages-landing-pages-and-guides`: the database cap follows the Database plan (Pro, 6,144 MB by
  default; Free, 450 MB).
