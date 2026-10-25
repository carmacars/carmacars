# The renter portal, redesigned (October 24, 2026)

Migration 0140 (read only). The owner, October 24, 2026: "When a renter signs in and is looking at their active rentals,
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

| Piece | What |
| --- | --- |
| `portal-ui.css` | The tokens (`--pu-*`: canvas, surface, ink, hairlines, radii, padding, three shadows, glass, ring colour, easing) and every component's style; motion under the media query |
| `PortalHero` | Photo, scrim, glass panel (chips, kicker, title h1 or h2, subtitle), then a body with an optional aside |
| `StatCard`, `StatGrid` | A key number with icon, label, value and a line; a link when it has `href` |
| `ProgressRing` | value of total, animated fill, number in the middle, label beside |
| `ActionTile`, `ActionGrid` | Icon, title, note, arrow; links (pages, `tel:`, anchors); tones neutral, brand, dark, warn |
| `Timeline`, `TimelineItem` | done, current (pulsing dot) and to do; a link on a step still to do |
| `MoneySummary` | Paid and owing totals, the Pay button, parts with their state and their own link, children (price details, receipts) |
| `DocumentRow`, `DocumentList` | Icon for the kind, title, date, Download |
| `PortalCard`, `Disclosure`, `EmptyState`, `HeroSkeleton`, `CarPhoto` | Card with a title row; smooth details; empty state; loading shapes; photo or placeholder |
| `LiveCountdown`, `CountUp` (`live.tsx`, client) | The ticking clock and the count up; both render their final text on the server |
| `PortalIcon` | 30 line icons on one grid |

The renter's compositions are in `web/src/features/portal/trip.tsx` (`TripHero`, `NextStepBox`, `TripCard`,
`PastTripCard`, `StepHeader`) and `trip-model.ts` (the clock, short times in Toronto, the Maps link, the money by part;
unit tests in `trip-model.test.ts`).

## The database

- `public.my_trip_photos()`: the photo of each car the signed-in renter booked, keyed by vehicle id; security definer,
  reads only the caller's bookings (`renter_bookings`), granted to `authenticated` and `service_role`. The cars that
  are not listed on the site show their photo too. Suite 86 (`supabase/tests/86_renter_portal_design.sql`).
  `SCHEMA_MARKER` 0140. The licensed stock photo of the model (branch seophotos) is not used yet: when it lands, it
  goes between the car's own photo and the placeholder.

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
