# Car page speed, the /book car list, and a real car for sample car requests (0102)

The owner reported, with screenshots: car pages are very slow; `/book/<car>?from=...` sat a long time with a grey block
under "Your request"; the car list of the request form named cars without their year ("Volkswagen Jetta, from $60 a
day" three times). Two more fixes in the same flow: the review step's Edit links broke one letter a line beside the
summary, and a request on a sample car (2023 Kia Forte EX) told the renter we were looking for a similar car while a
real 2021 Kia Forte was free.

## 1. Cause

- The public listing row of each car was computed on every request. `public.fleet` (read by every public page: the
  site's tokens, similar cars, the /book list) built all 92 rows; the 72 cars without an approved photo each built 8
  studio images to keep the first. Live (Oct 22, `explain analyze` in a read-only transaction): fleet 300 ms in the
  database, car_page 65 to 85 ms. Through the API: fleet 0.5 to 1 s and one 500 at the 3 s statement timeout, car_page
  0.25 to 3 s (the database busy with fleets), quote_booking 0.5 to 1.4 s.
- `/book/<car>`: `wizardProps` read the whole fleet, then `handover_places` once per program car (10 calls), and the form
  was rendered in the browser only (`useSearchParams` under Suspense with an empty fallback). In the browser the dates
  waited for the draft lookup (a server action), then 300 ms, then the quote: the skeleton block.
- The list label was `{make} {model}, from {daily}`.
- The review table cells have `overflow-wrap: anywhere` and the action column `width: 1%`.
- After each deploy every car page was a cold render for its first visitor (the page cache is per build and the edge
  copy per version).

## 2. Change

Database, migration 0102 (schema marker 0102):

- `app.listing_row_cache`: each car's row exactly as `app.public_listing_row_live` (the old function, renamed) returns
  it, with `valid_until` (the next start or end of one of the car's rate cards, the only time-dependent input).
  `app.public_listing_row` reads it and computes live when a row is missing or past its time, so a read is never wrong.
  Statement triggers (with the changed rows) refresh the cars touched by vehicles, vehicle_listings (and the cars whose
  canonical car it is), rate_cards, vehicle_photos, vehicle_class_links, partner_rates, partners (the partner's cars),
  vin_decodes (the cars with that VIN); vehicle_classes, sample_photos, listing_shot_types and the vehicle catalog
  refresh every row. Rows are locked first and built in a later statement, so a change committed meanwhile by another
  transaction is included. Job `carmacars-listing-cache` (pg_cron, every 10 minutes): rows past their time, and every
  row once an hour. Indexes: `vehicle_listings (canonical_vehicle_id)`, `vin_decodes (upper(vin), decoded_at desc)`.
- `public.booking_cars()`: id, slug, label, from price, year confirmed, sample. Label
  `{year} {make} {model} {trim}, {colour}, from $X a day` (no year when it is not confirmed; the form then says "Year
  confirmed when you book"), the car code in brackets only when two labels are still the same, sorted by price then
  name. `public.booking_car(slug)`: the one car of the form, with its handover places.
- `public.sample_car_match(vehicle, pickup, return)`: the best real car free for those dates, the same make and model
  first (closest price, newest), else the same class and body within 40% of the price. `app.sample_car_enquiry` keeps
  it on the enquiry (`payload.suggested`) and adds it to the customer service task ("... Free: 2021 Kia Forte, black,
  from $55 a day"). `public.enquiry_has_match(reference)` for the received page (a yes or no only).

Website:

- `/book` and `/book/<car>`: one `booking_cars` call and one `booking_car` call (no fleet rows, no per-car calls). The
  form renders on the server with its car and its rates in the summary; the link's dates apply at once (the draft
  lookup no longer holds them) and the first quote is asked without the 300 ms pause. Choosing another car reads it
  with `booking_car` from the browser.
- A sample car with dates, on the car page and in the form: "Good news: we have a {car} free for your dates" with one
  button (Switch to the {car} in the form, Book the {car} instead on the car page). With none free, the example car note
  stays. The enquiry received page says "We have a similar car for your dates; we'll confirm it within 2 hours" when the
  enquiry has a match.
- Review step: the action column does not wrap (`white-space: nowrap`).
- Worker cron (`custom-worker.ts`, `src/lib/edge/warm.ts`): after the post-deploy rebuild, the next ticks request home,
  `/cars` and each car page once through the Worker's service binding (each its own invocation and CPU limit), 4 at a
  time with a 150 ms pause per lane, 15 s per tick, at most 400 pages; progress is kept in the tag store
  (`carmacars/warm`) and resumes on the next tick. The tick's own CPU work is unchanged (it only waits).

Sitemaps (Search Console found 57 pages from `/sitemap.xml`):

- `/sitemap.xml` was already a `<sitemapindex>` naming the site's files, the 128 place files (0095) and the vehicle
  files (0097). Live, the vehicle index is empty (the vehicle catalog is not loaded), and the 47 model pages
  (`/cars/<make>/<model>`, indexable, self-canonical) were left to those vehicle files, so they were in no sitemap. A new
  child `/sitemap-hubs.xml` lists them (sitemap_all's model_hub rows). Every child stays under 50,000 addresses and is
  read from the database without rendering pages.
- robots.txt names the index files and now also each child of the first index (at most 1,000 lines).

## 3. Timings

| | Live before (API, from here) | Live before (database) | Local after (database, 82 published cars, 62 partner) |
| --- | --- | --- | --- |
| fleet | 0.5 to 1.0 s, one 500 at 3 s | 300 to 343 ms | 1.3 to 6 ms (was 190 ms locally) |
| car_page | 0.25 to 3.0 s | 65 to 85 ms | 7 to 16 ms (was 18 to 40 ms) |
| /book list | the fleet (141 KB) plus 10 handover_places | as fleet | booking_cars 3 ms (17 KB) |
| quote_booking | 0.55 to 1.45 s | | 7 ms warm |

## 4. Checks

- DB suite 69: every car's cached row equals the live row and the fleet equals the live fleet; rows follow a rate, the
  car, the listing, a class, the classes table, unpublishing and publishing again; a later rate card sets
  `valid_until`, an expired row is never served and the job refreshes it; labels, the car code only between identical
  labels, no year when unconfirmed, the order, anon access; the sample match (same model first, busy car skipped,
  similar class and body, none), the enquiry's payload and task, the received page's answer.
- Unit: `warm.test.ts` (paths, progress per deploy, concurrency, budget, resume, a failing page), `wizard-car.test.ts`.
- E2E `booking-list-perf.spec.ts` at 375 and 1440: the list labels (as the database gives them, all different, by
  price), the form and summary in the server's HTML, Edit one line high at 375, 768, 1024 and 1440, the sample match on
  the car page and the form, switching, and an enquiry that keeps the match.

- E2E `sitemap-index.spec.ts`: the index names every child (the site's files with hubs, a place file, a vehicle file),
  each site file is a urlset under 50,000, and it follows down to a model page, a place page and a vehicle page (200);
  robots.txt names them.

## Guides

- `va/customer-service`: the task names the free real car; check it and quote it.
- `admin/partners-company-cars-and-rentals-added-by-hand`: a real car is offered for a sample car's dates.
Both edited in `docs/guides/src/guides/*.py` and `docs/guides/content/*.json` and published by 0102
(`supabase/seed/0102_gen_guides.mjs`).
