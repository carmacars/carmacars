# Vehicle pages: every make, model, year and trim, by place, colour and search term (migration 0092)

The owner, October 21 and 22, 2026, in order:

1. "A page for every vehicle, every year, make, model and trim, and below it show the inventory we have."
2. Every page indexed, whether or not we have the car, self-canonical and in the sitemaps; trims are the real marketed
   trim names, Canadian where they differ (`/cars/volkswagen/jetta/2020/sportline`); the gate stays only as an Admin
   setting whose default is "index everything".
3. Every year the sources have and every make, exotics included.
4. Each trim multiplied by places and colours; every page with a for-sale twin under `/buy`.
5. Every figure people look up, from licence-clean sources only, never invented.
6. Places: every city, town and neighbourhood (the local SEO release's place table, North America), with GTA and
   country levels; search terms: renting, sale, detailing and body shop synonyms, each its own twin of every page.
7. Every page crawled as fast as the engines allow (IndexNow, sitemaps, links).
8. Cost guardrails: no KV page cache for these pages, low CPU, a database size cap, a budget alarm.

He was told the risk of large numbers of near-identical pages (Google's spam policies on scaled content and doorway
pages can demote a whole site) and chose to go ahead. What this release does about it: every sentence on a page is a
fact of that page's own data, every title, description and H1 is unique (tested), no page claims what is not true (a
car for sale, a loan, a lease), and every tier has its own switch to take it out of search at once.

## 1. Addresses

| Page | Address |
| --- | --- |
| Make | `/cars/<make>` (a car's address always carries its model, so `/cars/<slug>` is a car first, else a make) |
| Model, year, trim | `/cars/<make>/<model>`, `/<year>`, `/<trim>` (the model page replaces the model hub `/rent/<make-model>`, which answers 301) |
| Place | `/cars/<make>/<model>/<year>/<trim>/<place>` |
| Place and colour | `/cars/<make>/<model>/<year>/<trim>/<place>/<colour>` |
| Colour | `/cars/<make>/<model>/<year>/<trim>/colour/<colour>` (a place is never called `colour`) |
| For sale | `/buy/...`: the same tree (`/buy/volkswagen/jetta/2020/sportline/mississauga/black`), and `/buy` listing the makes |
| A search term | `/t/<term>/...`: the same tree for each active term (`/t/car-hire/volkswagen/jetta/2020/sportline/port-credit`, `/t/financing/...`, `/t/ceramic-coating/...`, `/t/bumper-repair/...`), and `/t/<term>` listing the makes |

The term is a path prefix, not a segment inside the car's address: every combination has its own address, nothing
collides with the existing routes (`/car-rental/<area>` landing pages, `/cars/<car>`), and the canonical tree under
`/cars` is unchanged. Slugs are lowercase and stable (`app.slugify`, a trim's "+" read as "plus"); another spelling of a
model answers 301 in every tree; unknown slugs, years, places, colours and terms are 404.

## 2. Data sources and the import

| Source | Licence | What it gives |
| --- | --- | --- |
| US EPA fueleconomy.gov `vehicles.csv.zip` | public domain | year, make, model, base model, engine (displacement, cylinders, turbo), drive, transmission, fuel, EV range, MPG (city, highway, combined; MPGe for an EV), kWh/100 mi, CO2, size class, annual fuel cost, charge time at 240 V, luggage volume, battery size where EPA names it |
| NHTSA vPIC `GetModelsForMake`, `GetModelsForMakeYear` (car, MPV, truck) | public domain | the maker's spelling of a model ("F-150", "CR-V"); models EPA does not rate (heavy-duty pickups and vans above EPA's weight limit); model years 1981 to 1983 and the next model year |
| NHTSA vPIC `GetCanadianVehicleSpecifications` | public domain | length, width, height, wheelbase and curb weight of each Canadian body of a model year ("JETTA GLI 4DR SEDAN") |
| NHTSA recalls flat file (`FLAT_RCL`) and complaints flat file (`FLAT_CMPL`) | public domain | each model year's recall campaigns (number, date, component, summary) and owner complaint counts by component |
| CarmaCars Canadian trim list `web/scripts/catalog/canada-trims.txt` | ours (trim names are facts) | the marketed trims of each model year in Canada, entry trim first (Comfortline, Highline, Sportline, Execline; Komfort, Progressiv, Technik; CE, LE, SE, XSE...) |
| CarmaCars popular list `web/scripts/catalog/popular.txt` | ours | 151 models popular in Canada: the rules, and the order of the sitemaps and IndexNow |

Not used: CarQuery (its terms could not be confirmed to allow storing and republishing the data; the page was not
reachable from here, so it is left out as the owner asked), Wikidata (power and dimensions exist for whole models, not
trims: putting a model's figure on a trim would be a guess). So power, torque, 0 to 100 km/h, top speed, fuel tank and
towing have no licence-clean source and are never shown; the page says so in its Sources note.

Trims: no free source has Canadian marketed trims for every model (vPIC's Canadian specifications name bodies, not
trims; vPIC VIN decoding gives US trims and needs a VIN per trim). The trims are the curated list, mapped to EPA's
powertrains by `app.vehicle_trim_variants`; a model year without a trim line is the leaf page. Admins add lines in
Admin > Settings > Vehicle pages.

Coverage (catalog workflow dry run COVERAGE_RUN, October 22):

COVERAGE_TABLE

The import (`web/scripts/catalog/import.mjs`, pure normaliser `web/src/features/vehicles/normalise.ts`) runs only in
GitHub Actions (`.github/workflows/catalog.yml`): the workspace network blocks these hosts. A push that changes the
import runs a dry run (download, normalise, counts, coverage and the fixture subset as annotations); the daily schedule
(07:17 UTC) imports when the last import is older than 30 days or an Admin pressed Import now. vPIC is asked four calls
at a time, backing off on 403, 429 and 5xx, within a time budget; what did not answer is counted
(`stats.vpic_errors`) and the catalog is built from what did. A make is sent in batches of at most about 900 KB. Rows
carry a content hash, so `updated_at` (the sitemaps' lastmod) moves only when the data changed. An import with no make
is refused, and so is one that would bring the database over the Admin's cap (section 8). Nothing was written to
production from this branch.

The committed fixture (`web/scripts/catalog/fixture/`) is turned into `supabase/seed/vehicle_catalog_fixture.sql` by the
same script; the local and staging seed and the database tests load it.

## 3. The pages

Each page is one database read (`public.vehicle_make_page`, `_model_page`, `_year_page`, `_trim_page`,
`vehicle_tier_page` for a place or colour; a /buy or body shop page adds `vehicle_buy_extras`).

- Rental pages (`/cars`): specs; every figure (section 4); the cost to drive 100 km, a 300 km weekend and 1,000 km at
  the gas or electricity price set in Admin; what changed from the year before; how the trim differs from its sibling
  trims; similar models; our cars (the exact match first, then the same model in other years, then similar cars, never
  an empty block) with live availability and "Request it" into the enquiry flow; the rental questions answered from the
  program settings.
- Place pages: the place and its parent ("Port Credit, Mississauga"), the straight-line distance from our location, the
  delivery price from our real cars' rate cards and the per-kilometre setting (or the rule, when no real car is listed),
  the landing page's local notes (areas, transit, highways, airport terminals, parking), the nearby places (those the
  landing page names first, then the nearest), the place's own questions. A region, province or country lists the places
  within it instead of a distance.
- Colour pages: the studio stand-in drawn in that colour (twelve colours; gold added to the studio's paints), our cars of
  that colour first in each block of the inventory. The makers' factory colour names have no licence-clean source.
- For sale (`/buy`, and the sale terms "used", "financing", "leasing", "lease takeover"): the same figures; what to check
  when buying that model year (NHTSA recall campaigns with their summaries, complaint counts by component; on a model
  page, recalls and complaints by year); the fuel cost of a year (EPA's and ours); "Rent it for a week before you buy";
  "Find me this car" (a buyer lead). A financing or leasing page shows the Admin's disclaimer ("CarmaCars is not a
  lender, dealer or lessor...") and its form is a finance lead.
- Renting terms ("car rental", "car hire", "cars for hire", "vehicle rental", "insurance replacement rental"): the rental
  page's content under the term's title and H1.
- Detailing (car, interior, exterior, mobile detailing, paint correction, ceramic coating, window tint, PPF, vinyl wrap)
  and body shop (collision repair, auto body, dent, bumper and scratch repair, car painting): first "Rent a car while
  yours is detailed" or "An insurance replacement rental while it is repaired" (to the insurance replacement twin), the
  car's facts that matter (EPA body class, the Canadian bodies' dimensions and weight, the colour), the request form (a
  detailing or body shop lead), the cars to rent while it is in.
- JSON-LD: BreadcrumbList; FAQPage; Product and Car with the sourced figures (fuelConsumption, fuelEfficiency,
  vehicleEngine with engineDisplacement, vehicleTransmission, driveWheelConfiguration, cargoVolume, emissionsCO2,
  weight, depth, width, height, wheelbase, seatingCapacity when our car says, color on a colour page). A rental Offer
  (AggregateOffer) only when real cars of ours match exactly; a sale Offer (price, CAD, UsedCondition) only when an
  Admin flagged a matching fleet car for sale (Cars > the car > For sale, with its asking price). Never on a sample car.
- Titles, descriptions and H1s: unique for every page (unit test over a sample of 3 trims x 14 places x 12 colours x
  every tree; the SEO audit across the sampled pages); every shorter fallback keeps the place, the colour and the term
  ("Pearson (YYZ)" for "Toronto Pearson Airport (YYZ)"); the home city's place page says "delivery and pickup" so it never
  takes the trim page's title.
- Links: every page links to its parent (breadcrumbs), its children (models, years, trims), its siblings (other trims,
  nearby places, the other colours) and its twins (for sale, every search term).

## 4. Every figure, and its source on the page

Rows appear only when a source gives the figure; a conversion says it is one (Imperial MPG from US MPG; litres from
cubic feet; inches and pounds from centimetres and kilograms). The "Sources" note under the table names EPA and vPIC
and says which figures no free source publishes.

| Figure | Source | Share of trim pages with it (dry run) |
| --- | --- | --- |
COVERAGE_ROWS

## 5. Places, terms, tiers and the switches

`places (id, slug, name, kind: province|region|city|neighbourhood|airport|country, parent_id, lat, lng)` is created
`if not exists` with the definition the local SEO release (branch seolocal) uses; whichever migration runs first creates
it. Until that release fills it (its GitHub Actions gazetteer import, GeoNames or StatCan with attribution), the places
are the active location landing pages. The places are numbered with the GTA first (a place under the region slugged
`gta` or `greater-toronto-area`), so the sitemaps and IndexNow reach the GTA first. `search_terms (id, slug, name, kind:
rental|sale|detailing|bodyshop, sort_order, is_active)` is created the same way, with the defaults above; the seolocal
branch owns both tables (their Admin editing and the gazetteer) and must keep these columns. Coordinate at merge: if its
definitions differ, keep one.

| Switch (Admin > Settings > Vehicle pages, all on) | Off |
| --- | --- |
| Index every page / only pages that pass the rules (`vpage_index_mode`) | the rules (makes; models with 2 years of data; years with our car or of a popular model from 2015; trims with our car) |
| Index the place pages (`vpage_place_index`) | place and place-and-colour pages noindex, canonical at the trim, out of the sitemaps |
| Index the colour pages (`vpage_colour_index`) | colour and place-and-colour pages likewise |
| Index the search term pages (`vpage_term_index`) | every renting and sale term's tree |
| Index the /buy pages (`vpage_buy_index`) | /buy and the sale terms' trees |
| Index the detailing pages (`vpage_detailing_index`) | the detailing terms' trees |
| Index the body shop pages (`vpage_bodyshop_index`) | the body shop terms' trees |
| Financing disclaimer (`vpage_finance_disclaimer`) | the text on financing and leasing pages and forms |

## 6. Counts

A tree (renting, for sale, or one term) has the level pages and, for each trim, its place pages, place-and-colour pages
and colour pages: `B + T x P x 13 + T x 12` (B level pages, T trims, P places, 12 colours). There are `2 + R + S + D + Y`
trees (renting, /buy, and the active terms: 5 renting, 4 sale, 9 detailing, 6 body shop by default, 26 trees).

COUNTS_TABLE

## 7. Sitemaps and IndexNow

- Files per tree: "" (renting), `buy-`, `t-<term>-`; then `makes`, `<make>-models|years|trims` (parts of 45,000 when
  bigger) and `tiers-<n>`: a range of (trim, place) pairs, a pair at most 13 addresses (the place page and its 12
  colours; the last pair of a trim is its 12 colour pages), so `floor(50,000 / 13)` pairs a file never pass 50,000
  addresses. Pair g is trim `g / Q + 1` and place `g % Q + 1` (Q the pairs of a trim): a file, and each slice of it
  (600 pairs, about 8,000 addresses, streamed), is read by keyset on g, never by offset; the list of files is arithmetic,
  so the index never counts addresses. Every address has its lastmod (the trim's data or our car of it, the place's
  landing page).
- The index: `/sitemap.xml` (the site's four sitemaps and the first vehicle files), then `/sitemap-index/2.xml`... every
  50,000 sitemaps; robots.txt names every index file (it is read on each request).
- Trims are numbered with the popular models and the newest years first (`app.vehicle_catalog_number_trims`, after every
  build of the trims and every change of the popular list).
- IndexNow: one queue and one quota for the whole site. `indexnow_queue` (0061) keeps the addresses whose content
  changed (sent first by the search job, at most 500 a run); `indexnow_sweep` walks every address of the vehicle
  sitemaps in their order with a cursor, one request of up to 10,000 addresses (IndexNow's most) each run of the search
  job (the Worker's cron, every 5 minutes), within a daily ceiling (`indexnow_daily_max`, 2,000,000, every sender
  counts). A 429 backs off from 15 minutes, doubling, at most a day; a 403 or 422 (the key refused) waits until the next
  day; anything else 10 minutes; the cursor stays put and the sweep resumes where it stopped. When the list is done it
  starts again (rounds). The local SEO release must send its addresses through `app.indexnow_queue_path` and count
  through `app.server_indexnow_report`, so there is one quota.
- Nothing about a sitemap or IndexNow renders a page: both are database reads on the trims' and places' numbers.

At a few billion addresses, IndexNow's daily limits are the bottleneck (2,000,000 a day would take years for the
whole list); the order (popular models, newest years, GTA first) decides what is sent first.

## 8. Cost guardrails

- No KV page cache: every programmatic route (`/cars/<make>/<model>/...`, `/buy/...`, `/t/...`) is `force-dynamic`
  (the build lists them as `ƒ`, no ISR entry, so no incremental cache write per page). Their only copy is the Worker's
  edge copy (the Cache API, free): `src/lib/edge/page-cache.ts` keeps them 6 hours whatever Next.js answers
  (`PROGRAMMATIC`), invalidated by the existing on-demand rebuild, and sends `public, max-age=600, s-maxage=21600,
  stale-while-revalidate=86400` to browsers and crawlers. The make pages share the car route and keep its hourly ISR
  (144 entries).
- CPU: one database read per page (two for /buy and body shop); measured below.
- Database size: nothing is stored per page. The import projects the catalog's size (its JSON at 0.75, measured 0.45
  for jsonb with TOAST compression, plus about 300 bytes a trim) and `app.vehicle_catalog_import_begin` refuses to start
  when the database would pass `vpage_import_db_cap_mb` (Admin > Settings > Vehicle pages; 6,144 MB by default on
  Supabase Pro's 8 GB). The panel shows the database size and each catalog table's.
- The budget alarm lives in the usage guard of release 2 (migration 0080, not on this branch): see Integration.

DB_SIZE

## 9. Performance

PERF

## 10. Admin

Admin > Settings > Vehicle pages: pages and indexed pages per level and per tier, with the total; the switches and
settings above; the database size against the cap; IndexNow (sent today, the sweep's place, the back-off); the popular
list; the Canadian trims; the last import and Import now. Cars > a car > For sale: the flag and the asking price.
Assistants: Leads > Buyer leads (buyer, finance, detailing and body shop leads, each with a To do line for Sales:
"A buyer asked us to find a car", "Someone asked about financing or leasing a car", "A detailing request", "A body
shop request"). The forms use the existing marketing consent wording (`legal.marketing_opt_in`), recorded only when
ticked.

## 11. Tests

- Unit: `web/src/features/vehicles/vehicles.test.ts` (every make and year, vPIC models and sizes, batches by size,
  titles and descriptions unique across places, colours and trees, every figure only from a source, bodies by trim);
  `web/src/lib/edge/page-cache.test.ts` (the programmatic pages kept at the edge whatever Next.js says).
- Database: `supabase/tests/55_vehicle_pages.sql` (the place list and the place table, place, colour and region pages,
  the sitemap slices by keyset and their 50,000 limit, the index of every tree, every switch, IndexNow batches, cursor
  and back-off, for sale only when flagged, recalls unknown versus none, buyer, finance, detailing and body shop leads,
  who may call what).
- End to end: `web/tests/e2e/vehicle-pages.spec.ts` at 375 and 1440 (every level, place, colour, /buy and term page
  renders with its H1, canonical, figures and its own block; axe; no sideways scroll; unique titles, descriptions and
  H1s; the sitemaps; the switches; the buyer lead).
- CI: the SEO audit reads every sitemap of the renting and /buy trees and of each term tree its makes and first place
  file (every file name is checked against its renting twin), and audits a sample of every kind of page; the link check
  and the role crawl sample the place, colour and twin pages by shape.

## 12. Not done

- Trims beyond the curated list (no licence-clean source); power, torque, acceleration, top speed, fuel tank and towing
  (no licence-clean source); the makers' colour names; drive times (no maps key, so straight-line distances).
- The gazetteer of every North American place: the seolocal release imports it into `places`.

## Integration (for release 2)

1. The budget alarm: release 2's usage guard (0080) already reads the Worker's requests and CPU every hour
   (`.github/workflows/usage.yml`, `web/scripts/cf-usage.mjs`) and alerts on Admin > To do and by email. The owner wants
   the alert at 70% of the included 10 million requests and 30 million CPU-ms a month:

   ```sql
   update usage_services set warn_bps = 7000 where service in ('workers_requests', 'workers_cpu');
   ```

2. The investor deck (0083): a feature in `web/src/features/deck/features.ts`, group "For the business" (or a new group),
   with the screenshot committed here as `web/public/deck/vehicle-pages.jpg`:

   ```ts
   { id: 'search-reach', title: 'Search reach: a page for every car',
     what: 'Every make, model, year and trim since 1981, for rent and for sale, in every place we serve and in twelve colours, and again for what people search: car hire, financing, ceramic coating, bumper repair. Each page carries the car\'s real figures (EPA fuel use and costs, Canadian dimensions, NHTSA recalls) and our live inventory below them, and asks for the booking, the purchase or the repair.',
     why: 'Search is the cheapest renter there is. Every page is built from data on demand, costs nothing to keep, is listed in the sitemaps and sent to search engines, and turns a search into a rental: each one leads to our cars, a request, or an insurance replacement rental.',
     points: ['A page for every car, place, colour and search', 'Real figures only, unique on every page', 'Our cars and a request on every page'],
     shots: [d('vehicle-pages.jpg', 'A vehicle page: a 2020 Volkswagen Jetta Sportline in Mississauga, in black')] }
   ```

   No count of pages or cars is on the slide (the deck shows no fleet figures); `app.vpage_tier_counts` has the counts if
   a later version wants them.

## Guides

Admin: "Vehicle pages" and "A car for sale" (chapter Search: car pages, landing pages and guides). Assistants (Sales and
customer service): "A request from a vehicle page" and "A buyer lead from a /buy page". Published by the migration
(`supabase/seed/vehicle_pages_gen_guides.mjs`, from `docs/guides/content`, source `docs/guides/src/guides/admin.py` and
`va.py`).
