# Placeholder bookings, conflicting dates and Live map polish (0283, 0284, 0285)

Release 25, part A. Three things the owner left for this release.

## 1. Placeholder bookings never get mixed up with the real rental (0283)

The owner, 2026-10-15: "for toll charges to go to the matched renter automatically when staff confirm a notice, that is
fine but what if there are 2 bookings on the same car (due to dummy bookings for insurance)". The release plan carried
it as "dummy booking mix-ups".

What was wrong (checked against the code):

- **Add a rental's Placeholder quick start left "Blocks the car's calendar" ticked.** A placeholder made that way blocked
  the car, so the real rental for the same days was refused as a double booking, and the placeholder counted as a real
  rental: for a toll at that time it was a candidate (never handed over, so the toll went to review instead of the real
  renter).
- A placeholder was told apart only by its shape (does not block, never handed over, 0046). One handed over or recorded
  as returned by mistake became a "real rental" for tolls, tickets and damage.
- A confirmed placeholder raised the renter's work like any booking: chase the verification, take the deposit, the
  insurer's "settle the dates and turn the calendar switch on", late returns; field jobs for the handover; a sales
  commission row; a pin on the Live map and a card in On the road.

Now:

- **`bookings.is_placeholder`** (with the reason, who and when). A placeholder never blocks the calendar (the switch is
  turned off whoever writes the row, and stays off), is never handed over (refused), sends the renter nothing
  (`do_not_email`), and is hidden from the owner (they see the dates as unavailable, as 0156's "never").
- **`app.booking_is_placeholder`**: the flag, or 0046's shape. Every toll, ticket and damage match, Add a rental's clash
  check and the commission already ask it, so a toll or ticket at that time goes to the real renter automatically when
  there is one real rental, and a placeholder cannot be chosen by hand.
- **Add a rental > Placeholder** (Admins) now turns the calendar switch off, marks the agreement as on paper (nothing to
  sign), says what a placeholder is under the quick starts, asks what it is for (optional; "Insurance or a hold" when
  empty) and sends `placeholder: true`. No agreement link is sent. The database refuses a placeholder from anyone but an
  Admin, and for a past rental.
- **On a booking: More actions > Mark as a placeholder / Make it a real booking** (Admins; `admin_do
  booking_placeholder`, `app.set_booking_placeholder`). Refused once money was taken (charge or capture succeeded) or once
  the car went out, and on a closed booking. Marking turns the switch off with who and why, hides it from the owner,
  cancels its field jobs and closes its renter tasks. Unmarking leaves the switch off for staff to turn on (that runs the
  usual overlap check). Both are in the booking history (`booking_events.kind = 'placeholder'`).
- **No renter work for a placeholder:** `app.raise_task` does not raise the renter task types of
  `app.placeholder_quiet_tasks()` for a placeholder (offer, verification, deposit, handover, late return, provisional
  dates, add-ons and the like); other work about the car still reaches staff. `app.field_jobs_sync` makes no field job.
- **No commission:** `app.commission_own_reason` says "Placeholder booking".
- **Revenue and statements:** a placeholder carries no money taken and never goes out, so it is never returned and never
  on an owner statement, the company statement or Collected this month. A booking with money is a real rental and cannot
  be marked.
- **The Live map** leaves placeholders out (no pin, not in On the road, not in Requests today or Bookings this week).
- **The booking page** shows "placeholder" next to the status and, instead of the next step, a note saying what it is
  and linking the real rental on the car.
- **Bookings made by the Placeholder quick start before this release** (the source note says so) become placeholders when
  nothing was taken and the car never went out; their renter tasks and field jobs are cancelled.

## 2. Conflicting dates on one car (0284)

The release plan carried "conflicting dates" next to the placeholder item; the owner's own words for it are not in the
session records that survive (only the plan's two words). Built as the owner's request reads with the item above: how
the site and the Admin handle two bookings, requests or offers on one car for overlapping dates.

- **Before:** on the calendar, two requests or offers for the same days on one car, or a request and a placeholder, were
  drawn on top of each other (one hid the other). The booking page's "Competing for these dates" listed every overlap
  the same way: a placeholder looked like a real rental, and it did not say which one keeps the car.
- **`app.booking_date_conflicts(booking)`:** everything else on the car for overlapping dates (the turnaround counted
  around a blocking booking): each booking with what it is (booked, a request or offer, not blocking, a placeholder),
  calendar blocks and Turo trips, and `holds`: whether it keeps this booking off the car. A placeholder never holds
  anything, and nothing holds against a placeholder.
- **The booking page:** "Competing for these dates" (Review and offer) uses it, with a label per line and, in red, the
  one that takes the car. Once booked, the Overview shows the same list as "Also on this car for these dates" when there
  is anything.
- **The calendar (`admin_calendar`):** each entry has `placeholder` and `clash` (what it collides with: a request, offer
  or non-blocking booking over a booked car or a block; two that take the car over each other). Bars that overlap in a
  lane are stacked one under the other and the row grows; a bar whose dates are taken has a red ring and a "!" and its
  panel says what it clashes with ("offer another car or other dates"); a placeholder is a dashed grey bar and never
  clashes. The legend has both. On a phone (the agenda), a line whose dates are taken says so in red.
- **Two calendar bugs found on the way:** the day headers sat off the bars (the car page's date picker also styles
  `.cal__head`, and its gap and spread moved the headers right, by more the wider the screen); and on the night the
  clocks go back the header showed the same date twice ("1 Nov, 1 Nov") because it stepped 24 hours at a time. The
  headers now line up and step by calendar day.
- **The site:** unchanged and checked: the car page crosses out the booked days, and the database refuses an offer or a
  confirmation over a blocking booking ("The vehicle is not available for these dates"). When one of two overlapping
  offers is confirmed, the other goes back to staff with an urgent "Re-offer" task (0016), now listed on its page.

## 3. Live map polish

- **On the road: a booking with no car** showed "Car ?". It shows "Car not assigned" with a neutral car drawn in the
  card's colour, a dashed top edge and the name in the quiet colour. A car with no name shows its code; a photo pin with
  no make to take an initial from shows the same car instead of "?" (`carLabel`, `CAR_SILHOUETTE` in model.ts).
- **City labels under the photo pins:** the photo pins, home base and the cars are page elements above the map, which
  the labels could not see. An invisible square the size of each now sits on the map's top layer (`blockers`, placed
  first), and each city label takes whichever of eight sides around its spot is free (`text-variable-anchor`); cluster
  counts keep labels clear too. The labels moved above the dots and under the clusters, with a stronger halo.
- **Highways:** the 401, 404, 410, 427, QEW, Don Valley Parkway and Gardiner Expressway (with the 400, 403 and 407 so the
  area keeps them), drawn by hand from public knowledge of their routes and simplified to a few points between
  interchanges (about 1 km: a wall map, not directions). CarmaCars' own work, so no licence applies; credited in the
  map's attribution ("GTA highways: CarmaCars") and the page's footnote. Served from
  `web/public/live-map/highways.geojson` (5 KB), the same origin as the basemap: no new host, no change to the security
  policy. `web/scripts/live-map/highways.mjs` writes it and takes Natural Earth's coarser (and partly mislabelled) roads
  out of the same area of `basemap.geojson`, so nothing is drawn twice. Styled as before: thin, faint amber, the
  parkways a little thinner; the number along each line only closer in, where nothing else is.

## Tests

- DB: `supabase/tests/99_placeholders_conflicting_dates.sql` (35): Add a rental's placeholder (Admins only, never past,
  not blocking, no emails, no field job), the real rental over it, the switch staying off, no handover, no renter tasks,
  other tasks still raised, no commission; the conflicts of the real rental, the placeholder and a request; the booking
  page and the calendar's `placeholder` and `clash`; the Live map; marking (Admins, not with money, not once out) and
  unmarking, the history, the door; a toll and a parking ticket to the real renter with a placeholder recorded as
  returned over the same days.
- Unit: `web/src/features/admin/calendar-stack.test.ts` (the stacking), `web/src/features/live-map/model.test.ts` (the
  car label, the highways file, no Natural Earth road left in the area).
- End to end: `web/tests/e2e/placeholders.spec.ts` (the placeholder's page, the request's page, the calendar's three
  stacked bars, the clash panel, at 375 and 1440); `web/tests/e2e/live-map.spec.ts` (the highways file loads from the site,
  the label blockers, "Car not assigned" in On the road at 1920x1080).

## Guides

- `admin/partners-company-cars-and-rentals-added-by-hand`: Placeholder bookings (new part).
- `admin/calendars`: the legend, stacked bars, dates taken.
- `admin/live-visitors-and-live-chat`: Car not assigned in On the road.
