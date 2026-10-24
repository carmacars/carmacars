# Address autofill everywhere (2026-10-24)

The owner: "not every single address field has the autofill working." Release 0130 put the address lookup (Google Places
Autocomplete, then Place Details for the parts) into most forms. This change closes the gaps, makes the admin forms fill
the parts beside an address, lets a staff member abroad find their home address, and makes a failed Google call say why
in the Worker's log. No migration.

## What changed

- **Admin forms fill the parts** (`Act`, `SaveForm`, `TollEntry`; `siblingFill` in `features/forms/address-parts.ts`).
  A suggestion chosen in an address field now fills the same form's matching fields by name: beside
  `<prefix>street|address|street_address|address_line1`, the `<prefix>city`, `<prefix>province|region`,
  `<prefix>postal_code`, `<prefix>address_line2|unit`, `<prefix>country`, `<prefix>latitude` and `<prefix>longitude`.
  With a city field next to it, the address field keeps the street only; without one, the whole address on one line.
  Before, Site settings > Business name, address and phone put the whole one-line address into the street field and left
  the city, province, postal code and coordinates as they were; the delivery origin's coordinates were typed by hand.
- **Fields that were plain text now look addresses up**: Admin > Partners (add and edit a partner: street, city,
  postal code), Admin > Tolls and tickets > Place, Maintenance > Tires (where a removed set is stored).
- **Coordinates**: `/api/address/place` also returns the place's `lat` and `lng`; `AddressInput`'s `onParts` passes them
  as a third argument (Site settings business latitude and longitude, the delivery origin's company latitude and longitude).
- **Home addresses abroad**: suggestions were limited to Canada, so a VA's home address in the Philippines never got any.
  The staff home address (the VA and field portals' Home address, Admin > Staff > Sales > Home address) asks for every
  country (`AddressInput anywhere`, `/api/address?w=1`; Google without `includedRegionCodes`). The daily cap is the same.
- **Why a lookup did not work is logged** (Workers Observability, `console.warn`, never the key):
  - `maps: Google /v1/places:autocomplete answered 403 (PERMISSION_DENIED: ...)`: Google's own reason (the key does not
    allow Places API (New), a referrer or IP restriction, billing off), or `failed: TimeoutError ...`.
  - `maps: autocomplete not sent to Google: the daily cap is reached`: once a SKU a day per isolate; or `the daily cap
    could not be read (...)` when the database did not answer (treated as over the cap, as before).
  - `maps: the fake adapter is in use (...)`: production without `GOOGLE_MAPS_API_KEY` (sample landmarks only).
  - `/api/address` answers `via: "google" | "fake"` beside `items` and `limited`, so the browser's network panel shows
    which adapter answered.

## Field inventory (origin/main before this change)

Uses the lookup and fills the parts already (0130): booking request delivery and return address (`RequestWizard`),
renter profile and booking details (`ProfileForm`, `DetailsForm`, `AddressFields`), owner profile (`OwnerForms`), owner
application (`ApplyWizard`), list your car (`OwnerForm`), Add an owner's car (`AddOwnerCar`), owner review
(`OwnerReview`), chauffeur pickup and drop-off (`ChauffeurForm`), staff home address and postal code (`HomeAddressForm`),
field vehicle moves (`FieldButton`), VA fleet and booking places (`Act` type address), Site settings mailing address and
street address, insurers' billing address, the delivery origin address.

Fixed here: Site settings business address (parts and coordinates were not filled), delivery origin coordinates, Admin >
Partners street, city and postal code (plain text), Admin > Staff > Sales home address postal code (not filled),
Tolls and tickets place (plain text), tire storage place (plain text), every staff home address outside Canada (no
suggestions).

Not touched (another change converts them): the quick rental form (`ManualRentalForm`), the offer composer, the booking
edit (`BookingReview`) and Edit renter screens.

Not addresses: Visitor history's city filter, damage location on the car, a car's home area.

## Tests

- `tests/e2e/address-autofill.spec.ts`: one row per address field (17), typed a key at a time in the production build
  with the local maps stand-in; each row checks the suggestion appears, the choice fills the field and its parts, at most
  3 suggestion requests for the whole word, no overflow; both widths. A second test checks the API (`via`, `lat`, `lng`).
- `src/features/forms/address-parts.test.ts`: `siblingFill` for the business address, a partner, a staff home address,
  the delivery origin and a field alone.

## Guides

No guide change: the guides already say to start typing an address and choose the suggestion; the steps are the same,
only more fields fill themselves.
