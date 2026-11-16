# Real cars cut out in the decorative sections, and the owner's occupancy forecast (Release 48, part O: 3080, 3081, 3089)

Migrations `3080_r48o_site_cutouts.sql`, `3081_r48o_occupancy_forecast.sql`, `3089_r48o_guides.sql`.

## 1. Real cars cut out in the decorative sections and the home hero (3080)

The owner: the decorative sections and the home hero (not the listings or the car cards) show a real fleet car, background removed, at the exact angle, size and place of the sample car of the section photo, over the section's own background (no dealership background), with a black gradient behind the text; the hero rotates through real cars.

- **Where.** The home hero (in turn, 6 seconds a car), Delivered to your door and Good cars come back around on the home page, the Delivery page's top, List your car's top, and the band of the Cars page. Not the car cards or the listings.
- **Exactly where the sample car stood.** `prototype/tools/make-standins.mjs` now also draws each section photo without its sample car (the plate, `web/public/site-plates/`) and the sample car alone; `web/scripts/slot-plates.mjs` measures each car's box into `web/src/lib/slot-cars-data.ts` (`--check` keeps both in step). A real car stands as long as the sample car, its wheels on the sample's ground line, centred on it, with a soft shadow; a car facing the other way is mirrored (the delivery scenes). One frame cropped like the photo it replaces (`components/SlotCars.tsx`, container query units), so the car keeps its place at every width; the section's own `::after` gradient stays over it, behind the text. The scroll effects move the whole frame.
- **Which photo.** `app.site_cutout_source`: the R48 studio side view (3030, on the site), then a listing side photo (either side), then a check-in or check-out side photo (a side view only: no plate shows), then the model's stock photo when its licence asks for no credit line (CC0 or public domain). None: the sample photo stays.
- **Made once, kept in Storage.** `web/src/server/site-cutouts.ts`, run by the listing worker's door a couple of cars a run: rembg's server (`REMBG_URL`, a `carmacars-rembg` container in `infra/vps/web/docker-compose.yml`, only the site reaches it), then sharp crops to the car and writes a WebP with transparency (at most 1600 px wide) to `vehicle-public/site/cutouts/<car>/<shot>-<hash>.webp`. No Cloudflare image transformation. A new source photo makes it again; the old cutout stays on the site until the new one is saved; a failure waits 1, 2, 4 ... hours, at most 6 tries a photo. `REMBG_URL` unset: nothing is made and every section keeps its photo.
- **Read.** `public.site_cutouts(shot, limit)` (anon): published real cars, most viewed first. Read once when a page is built.
- **Only on the stand-in photos.** A section photo replaced in Site content keeps its photo: the place of its car is not known.
- The hero's older studio slides (0563, 3040's studio covers with the dealership background) are gone from the hero; the car cards keep 3040's studio covers.

## 2. The owner's monthly occupancy forecast (3081)

- **The GTA seasonal curve.** Program settings `occupancy_season` (jan .. dec, the factor of each month against an average month: 0.80, 0.80, 0.95, 0.90, 1.00, 1.10, 1.25, 1.25, 1.00, 1.00, 0.90, 1.05) and `occupancy_base_pct` (60). A month's curve = base x factor. Editable in Settings > Program settings; a curve without its 12 months, or a factor outside 0.1 to 2.5, is refused.
- **A car's actuals** (`app.car_month_occupancy_bps`): the share of the month covered by its confirmed, on-rent, returned or closed bookings the owner sees (`app.booking_visible_to_owner`); hidden bookings, tests, placeholders and the owner's own trips are left out.
- **The blend** (`app.car_occupancy_forecast`): history = the car's full months on the program before the forecast (at most 24). Under 3: the curve alone. From 3: the car's own level (actual / factor, averaged) x the month's factor, weighted n / (n + 3) against the curve (3: 1/2, 6: 2/3, 12: 4/5, 24: 8/9).
- **Projected owner revenue** = occupancy x days x the car's owner revenue per booked day (its own statements of the last 12 months, else its daily rate less the Revenue Share). Before fees; an estimate.
- **Where.** The owner portal's Home: **Forecast**, the next 12 months per car (`features/owner/Forecast.tsx`). The Admin's owner Overview: the same (`ops_read owner_forecast`, the owner themself or an Admin). Every statement (the owner's page, the Admin's, the PDF): a **Forecast** line, next month against the statement's month, higher or lower, by how many points and about how much owner revenue, and why (the season) (`app.owner_statement_forecast`).
- Staff portals: not added; owner money and terms stay with an Admin (as the staff owner page says).

## Tests

- `supabase/tests/99_r48o_cutouts_forecast.sql`: the cutout source chain, the worker's list, a saved cutout and a failure, a remake keeping the old cutout, the public read and its grants; the hidden booking left out, the curve alone under 3 months, the blend and its weights, revenue, the curve's check, the statement line, who reads the forecast.
- `web/src/lib/slot-cars.test.ts`, `web/src/features/owner/forecast.test.ts`, `web/src/features/home/cutout.test.ts`.

## Guides

- `owner/fees-payments-and-payouts`: Your forecast (release 48).
- `admin/owner-money`: The owner forecast (release 48).
