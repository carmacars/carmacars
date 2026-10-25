# The renter portal, redesigned (October 24, 2026)

Migration 0152 (read only). The owner, October 24, 2026: "When a renter signs in and is looking at their active rentals,
it should look nice. Maybe there should be a picture of the car they are renting." Then: the portals must be "the most
appealing and interactive and look expensive". The renter portal is rebuilt on a shared component layer the owner and
investor portals reuse. No booking, pricing or payment rule changed: every page reads the same loaders and calls the
same server actions as before; amounts are shown as the database stored them.

## What renters see

- **Trips (`/account`)**: the nearest trip as a hero card: a large photo of the car booked (its own cover photo; else
  its first approved photo; else the listing's cover or the sample photo of its body style; else a clean branded
  placeholder, never a broken image), the car, year and colour on a glass panel over the photo, the status chip and the
  booking number, a live clock ("Pickup in 2 days 4 h", or "Return by Sun 7 PM" and "Return in 1 day 3 h" on rent),
  pickup and return (when, where, a Maps link for the place), kilometres included, the fuel rule (same as pickup, or
  prepaid with the full tank add-on), the deposit, the length, and the one next step with its button (only what is
  actually pending: approve the offer, sign, pay, upload the licence; otherwise "You are all set"). Then the other
  current and upcoming trips as photo cards, past trips as compact cards with a thumbnail, dates, the total paid and
  "Book again" (the car's page), and a polished empty state ("No trips yet", Find a car). "Book a car" in the header.
- **A booking (`/account/bookings/<n>`)**: the same hero (title h1) with the status line; the next step box on the
  right (on a phone, below). Then:
  - **Manage your trip**: tiles for Licence and coverage, Extend (or Pay for the extension), Ask to change dates,
    Message us, Call us, Add a driver (opens the message box with "I would like to add a driver"), Report a problem
    while on rent (calls the roadside number from the site settings, or opens a message), Photo report, Documents,
    Review your rental, Cancel booking, Book again. Withdraw stays below the tiles for a request.
  - **Progress**: a ring with the steps done and the next one; "Every step" opens the timeline (Request sent to Statement).
  - Add-ons, Drivers (with their signing links), Changes and extensions, Messages (`?ask=driver` or `?ask=problem`
    starts the message), Documents (one row per document with an icon for its kind).
  - **Balance due** (0132) stays above the cards with its Pay button, and is one of the parts of Money.
  - **Money** (right column; below on a phone): Paid and Owing totals (counting up once), each part (Rental, Extension,
    Add-ons, charges after the trip; the deposit as held; refunds), one Pay button for the first open part (sign then
    pay, the extension, the add-ons, a date change), "Price details" (the stored lines, HST and total, as before) and
    the receipts and statements.
- **Sign, pay, licence and coverage, photo report**: the step header (the car's thumbnail, the title, the trip, and the
  step bars 2 of 3 and 3 of 3) above the same forms.
- **Design**: phone first (390 px), the brand's red, black and white with red only for the one thing to do and what is
  owed; soft layered shadows, glass on the photo, larger type for titles and numbers (tabular figures). Motion (the hero
  rising, the photo settling, the ring filling, the countdown ticking, tiles lifting on hover, the timeline's current
  dot, smooth open and close of disclosures) only under `prefers-reduced-motion: no-preference`. Skeletons while a trip
  page loads (`loading.tsx`). Every control 44 px or more, focus rings, contrast AA, axe clean at both widths.

## The shared layer (`web/src/components/portal-ui/`)

One library for the renter, owner and investor portals (merged with the owner and investor redesign of 0150 in release 9).
The owner and investor callers are unchanged; the renter's pieces were added beside them, and the shared components took
the renter's needs as optional props (a superset):

| Piece | What |
| --- | --- |
| `StatCard` | Adds `variant="tile"` (the compact grey tile with an icon, a link when it has `href`, tones `brand` and `dark`); `StatGrid` (`cols` 2, 3 or 4) |
| `TimelineItem` | `date` optional (without it, a plain list of stages), `state` also `current` and `todo`, `href` on a step still to do |
| `ProgressRing` | Adds `testId` |
| `DocumentRow`, `DocumentList` | Adds `linkTestId` (a test id on the link itself) and `plain` (a list inside a panel, no card of its own) |
| `PhotoHero`, `CarPhoto` | The trip's photo hero: photo (or `media`, such as a licensed stock photo with its credit), scrim, glass panel, body and aside (the dark `PortalHero` stays the owner and investor home) |
| `QuickAction`, `QuickActions` | A grid of quick actions (icon, title, note, arrow; links, `tel:`, anchors). `ActionTile` stays one pending thing with its button |
| `MoneyCard` | Paid and owing totals, the Pay button, parts with their state and their own link, children. `MoneySummary` stays the rows-and-total list |
| `PortalCard`, `Disclosure`, `EmptyState`, `HeroSkeleton` | A `pu-panel` with a title row; smooth details; empty state; loading shapes |
| `LiveCountdown` (client), `span` | The ticking clock; figures that count up use `AnimatedNumber` |
| `PortalIcon` | The 24 px line icons beside the 20 px `PuIcon` set |

`portal-ui.css` keeps the 0150 tokens and classes and adds the renter's under their own names (`pu-ph`, `pu-stat--tile`,
`pu-tile`, `pu-mc`, `pu-next`, `pu-trip`, `pu-steph`, `pu-ringrow`, `pu-tl--nodate`, `pu-docs--plain`, `pt--renter`).

The renter's compositions are in `web/src/features/portal/trip.tsx` (`TripHero`, `NextStepBox`, `TripCard`,
`PastTripCard`, `StepHeader`) and `trip-model.ts` (the clock, short times in Toronto, the Maps link, the money by part;
unit tests in `trip-model.test.ts`).

## The database

- Migration 0152 (numbered 0140 on its first branch). `public.my_trip_photos()`: the photo of each car the signed-in renter booked, keyed by vehicle id; security definer,
  reads only the caller's bookings (`renter_bookings`), granted to `authenticated` and `service_role`. The cars that
  are not listed on the site show their photo too. Suite 86 (`supabase/tests/86_renter_portal_design.sql`).
  `SCHEMA_MARKER` 0152.
- The trip hero's image: the car's own photo; when it has none (or only a sample photo), the licensed stock photo of
  the model (`vehicle_stock_photo`, 0149) with its credit and "not one of our cars"; else the sample photo or the
  listing cover; else the placeholder. Thumbnails use the car's own or sample photo only.

## Tests changed

- `tests/e2e/portal.spec.ts`: the trip hero and the next step on Trips, the money summary and the manage tiles on the
  booking, axe at both widths; the existing flow unchanged.
- The test ids the suites use are kept (`next-step`, `status-badge`, `paid-panel`, `paid-live-panel`, `live-sign`,
  `live-pay`, `change-waiting`, `review-link`, `renter-photo-report`, `doc-*`, `file-*`, `generated-files`,
  `total-due`, `price-breakdown`, `portal-addons`, `booking-messages`, `trip-row`, `past-trips`).

## Guides

- `renter/your-offer`: Trips opens on the next trip with its photo and next step.
- `renter/before-pickup`: the booking page (the photo, the clock, the trip details with Maps, Next step, Manage your
  trip, Money, Progress).
- `renter/during-your-trip`: Report a problem and Add a driver.
- `renter/after-your-trip`: Book again.
- `renter/quick-reference`: Trips in the navigation table.

The screenshots of these chapters are retaken by the guides workflow after the deploy (guide upkeep).
