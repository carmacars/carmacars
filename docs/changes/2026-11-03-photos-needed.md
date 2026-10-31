# Real photos for every car: the handover photos as listing photos (0236)

The owner: "we need photos of each car, is the ai photo editor working?"

**What we found.** The studio editor is built and wired (0022, 0073): a listing photo is cut out by Cloudflare Images
(segment=foreground) and placed on the CarmaCars studio backdrop with the model's name, in the listing pipeline's
process_photo step, within the month's 5,000 included transformations. It has never run: no listing photo was ever
uploaded (Cars > Listings: 5 intakes, 0 photos; Settings > Usage: 0 image transformations). So whether Cloudflare
transformations answer on carmacars.ca is untested; the first real photo will tell (a refusal keeps the original and
flags it, reason not_enabled). 75 real cars show sample photos.

- Cars > Listings: **Cars on sample photos**, each real car on sample photos with its newest handover photos (the
  check-out and check-in photos field staff take; app.photos_needed, also readable by fleet and field staff).
- **Use the handover photos**: the newest report's photos of the listing shots (sides, corners, seats, trunk; the
  instrument cluster as the dashboard and the odometer; a front wheel) are copied into the car's listing intake as if taken
  on the capture screen, and the intake is submitted when every required shot is there: the studio editor runs, then the
  listing waits for review (web/src/server/actions/listing.ts listingFromHandover).
- Tests: `supabase/tests/99_release_23.sql` section 10, `web/tests/e2e/release-23.spec.ts`.

## Guides

- `admin/fleet-and-listings`: Cars on sample photos.
