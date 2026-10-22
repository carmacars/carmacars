# Vehicle pages: every make, model, year and Canadian trim (migration 0092)

The owner, October 21, 2026: "a page for every vehicle, every year, make, model and trim, and below it show the
inventory we have." Then, overriding the first plan's indexing gate: every page is indexed, whether or not we have the
car, self-canonical and in the sitemaps; trims are the real marketed trim names, Canadian where they differ
(`/cars/volkswagen/jetta/2020/sportline`); the gate stays only as an Admin setting whose default is "index everything".

Because every page is indexed, no two pages may share a title, a description or a body. Every sentence on a page is a
fact of that page's own data (its EPA powertrains, its fuel use converted to L/100 km, the cost of 100 km at our price
setting, what changed from the year before, how the trim differs from its sibling trims, similar models of its class
and year, our own cars, the rental questions answered from the program settings). Nothing is written by a model.

## 1. Addresses

| Page | Address | Replaces |
| --- | --- | --- |
| Make | `/cars/<make>` | nothing (a car's address always carries its model, so `/cars/<slug>` is a car first, else a make) |
| Model | `/cars/<make>/<model>` | the model hub `/rent/<make-model>`, which answers 301 (`public.vehicle_hub_path`); `listing_redirects` that pointed at a hub point here |
| Model year | `/cars/<make>/<model>/<year>` | new |
| Trim | `/cars/<make>/<model>/<year>/<trim>` | new |

Slugs are lowercase and stable: `app.slugify` (the same in `web/src/features/vehicles/units.ts`), a trim's "+" read as
"plus" (`ex-plus`, `trendline-plus`). The model's slug is the catalog's (`f150`, the EPA base model; vPIC's "F-150" is
the name shown). Another spelling of a model (`/cars/mercedes-benz/c300`) answers 301 with the catalog's
(`/cars/mercedes-benz/c-class`). Unknown slugs and years are 404. `app.model_hub_path` now returns the model page, so
every car's breadcrumb and "More <model>" link, the fleet signature and the sitemap follow.

## 2. Data sources and the import

| Source | Licence | What it gives | Coverage (catalog workflow dry run 39711271549, October 22) |
| --- | --- | --- | --- |
| US EPA fueleconomy.gov `vehicles.csv.zip` | public domain | year, make, model, base model, engine (displacement, cylinders, turbo), drive, transmission, fuel, EV range, city/highway/combined MPG and kWh/100 mi, CO2, size class | 50,407 rows; 2010 to 2027, 44 makes sold in Canada (exotics left out): 580 models, 4,862 model years (4,746 with ratings), 20,684 powertrains |
| NHTSA vPIC `GetModelsForMake`, `GetModelsForMakeYear` | public domain | the maker's spelling of a model ("F-150", "CR-V"), and model years EPA has not rated yet | 150 calls, none failed, within an 8 minute budget |
| CarmaCars Canadian trim list `web/scripts/catalog/canada-trims.txt` | ours (trim names are facts) | the marketed trims of each model year in Canada, entry trim first (Comfortline, Highline, Sportline, Execline; Komfort, Progressiv, Technik; CE, LE, SE, XSE...) | 113 lines for 79 popular models from 2014 on; about 2,400 trim pages. Admins edit or add lines in Admin > Settings > Vehicle pages |
| CarmaCars popular list `web/scripts/catalog/popular.txt` | ours | 151 models popular in Canada (used only by the rules) | 148 matched |

Trim sources considered: vPIC `GetCanadianVehicleSpecifications` (public domain) carries body-level names only ("JETTA
4DR SEDAN", "JETTA GLI 4DR SEDAN") with dimensions, no marketed trims, so it is not used for trims (dimensions are a
possible later addition). CarQuery's trims are not licence-clean for commercial use. Wikidata (CC0) has trims for very
few models. VIN-decoded trims from vPIC are US trims and need a VIN for every trim. So the trims are the curated list,
mapped to EPA's powertrains by `app.vehicle_trim_variants`: each powertrain's own words in EPA's model name (Hybrid,
GLI, Long Range, C300, "SE/XLE/XSE" as alternatives) score for or against a trim name; a "<X> Line" package never takes
X's engine; Hybrid, Prime and Plug-in keep only those powertrains; AWD, xDrive, 4MATIC, rear-wheel drive and manual keep
those. A trim whose powertrain EPA does not separate (most) shows every powertrain of its year.

The import (`web/scripts/catalog/import.mjs`, pure normaliser `web/src/features/vehicles/normalise.ts`) runs only in
GitHub Actions (`.github/workflows/catalog.yml`): the workspace network blocks both hosts. A push that changes the import
runs a dry run (download, normalise, counts, the fixture subset as annotations); the daily schedule (07:17 UTC) imports
when the last import is older than 30 days (the setting) or an Admin pressed Import now; Run workflow imports at once.
It writes through the deploy's Management API connection in one batch per make (`app.vehicle_catalog_import_begin`,
`_batch`, `_popular`, `_finish`), then rebuilds the public pages. Rows carry a content hash, so `updated_at` (the
sitemaps' lastmod) moves only when the data changed. An import with no make is refused (it would empty the catalog).
Nothing was written to production from this branch.

The committed fixture (`web/scripts/catalog/fixture/`, 176 real EPA rows of 20 models, and vPIC names) is turned into
`supabase/seed/vehicle_catalog_fixture.sql` by the same script; the local and staging seed and the database tests load it.

## 3. The pages

Each level is one database read (`public.vehicle_make_page`, `_model_page`, `_year_page`, `_trim_page`) returning the
page's data, its neighbours, its inventory, whether it is indexed and its canonical.

- Head: H1 "Rent a <year> <make> <model> <trim> in Toronto", a lead from the data, key facts, and the sample cars' studio
  drawing (`/sample-photos/studio/...`, the model's name behind the car), marked "Representative image".
- Specs: engine, drive, transmission, fuel, seats when our car says, city, highway and combined L/100 km (kWh/100 km for
  an EV), electric range, CO2, cost to drive 100 km; one column per powertrain.
- Cost to drive: 100 km, a 300 km weekend and 1,000 km at the gas (regular or premium) or electricity price set in Admin
  (defaults $1.55 a litre, premium 20 cents more, 15 cents a kWh).
- Year page: the Canadian trims with their engines, what changed from the year before (powertrains added or dropped,
  fuel-use changes of 0.2 or more, trims added or dropped), every year of the model, similar models (same EPA class and
  year, same price band first, nearest fuel use).
- Trim page: its position in the lineup, which trims share its powertrain, what the others have that it does not, the
  only trim with a drive, the trim's other years, every year of the model, similar models.
- Inventory, below the facts: our cars of the exact year, make, model and trim first, then the same model in other
  years, then "Similar cars available now" (same body group, same price band, nearest daily rate), never an empty block.
  The fleet's car cards, each with live availability for tomorrow (one `search_available` call per view, in the
  browser). Always "Want this exact car? Request it": the contact form with the car named, a lead in Bookings > Leads.
- Questions answered from the settings: can I rent this one here (our count), what fuel costs for 100 km, minimum age and
  young driver fees, deposit range, coverage and the Protection Plan, delivery.
- JSON-LD: BreadcrumbList, FAQPage, and Product/Car with an AggregateOffer only when real (non-sample) cars of ours match
  exactly. Make pages carry an ItemList of models.
- Titles "Rent a 2020 Volkswagen Jetta Sportline in Toronto | CarmaCars"; descriptions name the page's own fuel use,
  trims and our count. hreflang en-CA and x-default as on every page.

## 4. Indexing

| Setting (program settings, Admin > Settings > Vehicle pages) | Default |
| --- | --- |
| `vpage_index_mode` | `all`: every page indexed, self-canonical, in the sitemaps |
| `vpage_model_min_years` (rules) | 2 |
| `vpage_popular_from_year` (rules) | 2015 |
| `vpage_year_min_cars`, `vpage_trim_min_cars` (rules) | 1, 1 |
| `vpage_gas_cents_per_litre`, `vpage_premium_extra_cents`, `vpage_electricity_cents_per_kwh` | 155, 20, 15 |
| `vpage_import_every_days` | 30 |

With "Only pages that pass the rules", a page that fails is noindex,follow with its canonical at its parent (trim to
year, year to model, model to make) and leaves the sitemap. Our inventory is read live in each page's read, so a page
flips when a car is published or unlisted: the fleet signature's rebuild (`src/lib/edge/fleet-sig.ts`, the Worker's
cron tick, `/api/jobs/public-rebuild`) revalidates every public page, the hourly ISR catches the rest, and an Admin's
setting, trim or popular-list change rebuilds at once.

Expected in production after the first import: 44 make pages, 580 model pages, 4,862 model year pages and about 2,400
trim pages: about 7,900 pages, all indexed by default. Under the rules: 44 makes, about 540 models (539 have 2 or more
years), about 1,500 years (the popular models from 2015) plus the years of our cars, and only the trims of our cars.

Sitemaps: the index (`/sitemap.xml`) lists the site's four sitemaps and the vehicle sitemaps
`/sitemap-vehicles/makes.xml` and `/sitemap-vehicles/<make>-models.xml`, `-years.xml`, `-trims.xml` (about 130 files,
the largest a few hundred addresses, far under 50,000), each address with its lastmod. The model hubs left
`sitemap-pages.xml`. The edge copy keeps the vehicle sitemaps like the others.

## 5. Performance

Rendered on demand with ISR (an hour) and the edge copy, never at build time (`generateStaticParams` returns nothing).
Measured on the local stack (fixture catalog, 20 sample cars): see the change record's tests section and the final
report for the numbers of this run. Indexes: makes and models by key and alias (GIN), years by class and year, trims by
model and slug.

## 6. Admin

Admin > Settings > Vehicle pages (`src/features/vehicles/VehiclePagesAdmin.tsx`, the door's `admin_read
vehicle_pages`, `admin_do vehicle_pages_import`, `vehicle_pages_popular`, `vehicle_pages_trims`): pages and indexed
pages by level, the rules in words, the settings, the popular list (one model per line; a model removed is not added
back by the next import), the Canadian trims of each model (an Admin's lines replace the list's and survive imports;
emptied, the list's come back), the last import with its counts and run, and Import now (picked up by the next daily
check; nothing to set up).

## 7. Tests

- Unit: `web/src/features/vehicles/vehicles.test.ts` (slugs, L/100 km and kWh conversions, cost of 100 km, engine and
  gearbox words, the gate and the canonical parent, EPA special words with alternatives, the fixture building the
  catalog, the trim list's checks, specs merging, year changes, trim differences, unique titles and descriptions).
- Database: `supabase/tests/55_vehicle_pages.sql` (the fixture import, trims to powertrains, car matching, the four
  reads and their 404s and 301, every page indexed by default, the rules flipping with a car published and unlisted,
  sitemaps by make and level, the old hubs, an import of the same data moving no lastmod, the Admin door, who may call
  what). Suites 11 and 22 follow the model page's new address.
- End to end: `web/tests/e2e/vehicle-pages.spec.ts` at 375 and 1440 (each level renders with its H1, specs, inventory and
  request link; indexed and self-canonical by default; noindex with the parent canonical under the rules; a sample car on
  its trim page; the vehicle sitemaps list only indexed pages; the hub 301; unknown slugs 404; axe; no sideways scroll).

## 8. Not done

- Dimensions from vPIC's Canadian specifications (length, width, height, wheelbase, curb weight): available by body,
  not by trim; a later addition to the year page.
- Trims for the models outside the list: their model years are the leaf pages until a line is added in Admin.
- Seats are shown only when one of our cars says (EPA does not carry them).
- A car that leaves the fleet still answers 410 when no other car of its model is live (unchanged); a 301 to its model
  page would keep its links working now that every model has a page.

## Guides

Admin: "Vehicle pages" (chapter Search: car pages, landing pages and guides). VA, customer service: "A request from a
vehicle page". Published by the migration (`supabase/seed/vehicle_pages_gen_guides.mjs`, from `docs/guides/content`,
source `docs/guides/src/guides/admin.py` and `va.py`).
