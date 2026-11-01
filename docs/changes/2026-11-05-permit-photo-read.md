# The ownership permit read from a photo (0290)

The owner, October 31, 2026, sent photos of Ontario vehicle permits for each car to be added, and their details were
typed into the car forms by hand: plate, VIN, year, make and model code, colour, body, permit number and the plate
sticker expiry (printed as YYMMDD). Now the form fills itself from the photo, and staff (or the owner) check each field
before saving. On by default.

- **Where:** Add a car for an owner (Admin and the staff portal), Admin > Vehicles > Add a car, a car's Registration
  card, and the owner's own application (signed in). "Fill this from the ownership permit": **Take a photo** (the phone's
  camera) or **Choose a photo**. The photo is made a standard JPEG in the browser (HEIC from iPhones too, location data
  dropped) and read.
- **What fills in:** the VIN (then decoded as when typed), the plate, the colour as a swatch (the permit's code, for
  example GRY, read as Grey), the permit number and the sticker expiry; the year (from the VIN when the permit year is
  not read), make, model code and body are shown to check. On the Registration card only the empty fields are filled; a
  value that differs from the saved one is named, not overwritten.
- **The checks, before anyone sees it:** the VIN's 17 characters and its check digit (I and O read as 1 and 0 are put
  right first), the plate's Ontario format (four letters and three digits, or the older three and three; anything else
  is "Check this", for example a personalized plate), the sticker expiry as a real date (an expired sticker is flagged),
  and the permit year against the VIN's year code. Each detail shows **Checked**, **Check this** or **Type it**, with the
  reason in words. Nothing is made up: a value not read stays empty.
- **The photo** is attached as the car's ownership permit document (Add a car for an owner, Add a car), or waits on the
  Registration card's upload. Choosing another file replaces it.
- **The model:** Cloudflare Workers AI, the vision model of Settings > Vision model (the toll reader's), through the
  Worker's AI binding. No new key or secret. It counts in the readers' share of the free daily allowance (Usage:
  "Ownership permit reader").
- **Who:** Admins, fleet and customer service; a signed-in owner or applicant, 10 reads a day
  (`ai_vision_permit_daily_per_person`). Off: `ai_vision_permit_enabled` (Settings > Vision model).
- **What is kept:** `permit_reads` (who, when, whether it answered and how many of the nine fields were read; never the
  values) and the call's neurons in `provider_calls`. The permit number and sticker expiry entered with a car added for an
  owner (or in the owner's application) are saved on the car (`vehicles.permit_number`, `sticker_expires_on`, 0237), so the
  sticker task 30 and 7 days before applies at once.

Files: `supabase/migrations/0290_permit_read.sql`, `web/src/features/vehicles/permit-read.ts` (the prompt and the checks),
`web/src/features/vehicles/PermitScan.tsx`, `web/src/app/api/permit/read/route.ts`. Tests: `supabase/tests/99_permit_read_walkthrough.sql`,
`web/src/features/vehicles/permit-read.test.ts`, `web/tests/e2e/r25b-permit-walkthrough.spec.ts`.

## Guides

- `admin/owners-and-onboarding`: Add a car for an owner, the permit photo.
- `owner/apply-and-get-your-car-listed`: the permit photo when signed in.
