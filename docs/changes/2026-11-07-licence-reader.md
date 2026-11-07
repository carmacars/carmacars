# The licence reader and the main driver's Ontario licence (release 31, D2; migration 0602)

Branch `r31-lic`, merged into release 31 (`docs/releases/r31.md`, "Licence reader"). SCHEMA_MARKER 0602.

## What changed

- **Every licence photo is read on the server once it is stored** (`web/src/server/licence-read.ts`): the renter's
  verify page and booking request (`confirmUpload`), an additional driver's own link (`driverLicenceUpload`), staff at
  the counter, on the booking and in the field (`staffLicenceUpload`). The back's PDF417 barcode first, in pure
  JavaScript (`features/licence/barcode.ts`: jpeg-js and fast-png decode the photo, the ZXing PDF417 reader reads it at
  two sizes and both ways up; the Worker cannot compile WebAssembly from bytes), parsed as AAMVA
  (`features/licence/aamva.ts`: name, date of birth, number, class, issue and expiry dates, province or state, country,
  address; Canadian and US date orders; the older DAA name). Otherwise the vision model, like the VIN reader, within the
  day's AI allowance (purpose `licence_read`, tier live; a small JPEG; the call recorded with its neurons). Nothing read
  is logged; an error is logged by its name only.
- **What was read** goes to `licence_reads` (staff only: the Admin policy and the service key; audited with the values
  redacted; deleted when the licence image is purged, so it keeps the image's retention). The driver's empty licence
  fields (`drivers`, `booking_drivers`: number, class, issuer, expiry) are filled from a sharp read; the renter confirms
  them on the verify page (**These are right**, or **Change them**; a change by the renter counts as confirmed).
- **The checks** (`app.licence_checks`), one Pass or Flag line each on the document review, customer service's and
  Sales' verify page and the field licence review: photos sharp and whole; valid to the return (expired, or expires
  before the return); class in `accepted_licence_classes`; the minimum age at pickup; name and date of birth match the
  booking's driver; the Ontario number (a letter and 14 digits, the family name's letter, the date of birth in the last
  six digits, month + 50 too); front and back the same licence; the main driver's Ontario licence.
- **A photo that cannot be used** (blurry, cut off, not a licence): the person who took it is told at once, in one
  plain sentence, to take it again (renter, additional driver and staff alike).
- **Staff still approve.** Settings > Program, Driver's licence reader: **Approve automatically when every check
  passes** (off). When on, a driver whose front and back both read sharp with every check passing is approved through
  the same review, in the name of the Admin who turned it on; anything flagged waits.
- **The main driver needs an Ontario licence** (**Primary driver must hold an Ontario licence**, on): when the reader
  finds a licence from elsewhere on the main driver of a booking being arranged (requested to confirmed), that person
  becomes an additional driver with their upload and checks (still reviewed by staff); `booking_primary_swaps` records it;
  the booking needs "Primary driver: Ontario licence needed" (`booking_readiness.primary_ontario_needed`, missing
  `primary_driver_ontario_licence`) and the car cannot go out (`a0_primary_ontario_guard` on `on_rent`). The renter sees
  one screen: "The main driver needs an Ontario licence. Add a driver with an Ontario licence as the main driver. You'll
  stay on the booking as an extra driver." with **Add main driver** (name, email, mobile, date of birth; their licence
  photos next, read the same way), or uploads their own Ontario licence instead. The new main driver gets the usual
  driver link to accept and sign; the agreement names them "Primary driver" and the account holder keeps signing as the
  renter (never twice). The swap is settled when the new main driver's (or the first one's) Ontario licence is read.
  Staff see it on the document review and the verify pages; an Admin can **Undo the swap** or **Let it go** with a
  reason. Staff-created bookings and staff verify pages go through the same reader when staff upload the photos.

## Guides

- `renter/find-a-car-and-send-a-request` (the read, the retake, confirming the details; The main driver needs an Ontario licence)
- `va/customer-service` (the reader's lines; the main driver swap)
- `va/sales` (the reader's lines)
- `field/my-jobs` (the reader's lines; the retake)
- `admin/requests-offers-and-bookings` (The licence reader: the settings, the swap, undo and let it go)

## Tests

- `web/src/features/licence/aamva.test.ts`: AAMVA text of sample licences (Ontario, New York, an older card; invented
  people and numbers), the Ontario number check, the vision model's answer, the retake message.
- `web/src/features/licence/barcode.test.ts`: the PDF417 read from a photo of a made-up card (`fixtures/back-fake.jpg`).
- `supabase/tests/99_licence_reader.sql`: every check and flag, the fields filled, automatic approval (off by default,
  Admin only), the swap to additional driver, the pickup blocked, a new main driver, the agreement's signers, the
  renter's confirmation, an Admin's undo and override, staff only, the read deleted with its image, no number in the
  audit log.
- `web/tests/e2e/r31-licence-reader.spec.ts`: the renter's flow (a licence from Quebec read from the back's barcode,
  the screen, Add main driver).
