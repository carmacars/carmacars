# Bookings > Now: what is out, coming back, going out and owed, on one screen (0330, 0331)

Release 26. The owner: "the literal most important thing, which cars are currently out and to which renters and which
need to return it and at what time and when they need to pay next (whether they're on biweekly or weekly and they have a
payment coming up) or whether a car needs to go out soon and what not. There's no clear way to see all of these things
in one place." Then: "We need less pages not more", "some of the confirmed ones are on rent. Like this is a mess", and
"make it simpler and more organized. and put a filter for insurer billed or renter billed".

No new page: **Bookings** (`/admin/bookings`) now opens on **Now**. The list of every booking is its **All bookings**
tab (`?view=all`). Fleet and customer service staff get the same screen on **Rentals > Bookings** (`/staff/bookings`),
field staff a read-only **Cars now** without the money (`/staff/field/now`).

## What the screen shows

- **The numbers**: out now (and how many pickups were not recorded), due back today, overdue (red), going out in the next
  72 hours, payments due in 7 days with the total (red when one is overdue), free cars (and how many are in the shop).
  Each one jumps to its list.
- **Bill to**: All, Renter or Insurer (insurer billed in full or split). Every list and number follows it.
- **Out now**: one list, overdue returns first in red, then by due-back time. The car (photo, name, code, plate), the
  renter with Call and Text, when it went out, due back with a countdown, the next payment (amount, when, plan, which
  payment of how many), the deposit held, the km and fuel at pickup, and the booking link. Filters: Overdue, Due today,
  Payment due.
- **Out (pickup not recorded)**: a confirmed booking whose pickup time passed with no check-out recorded counts as out
  (in real life the car left). **Mark picked up** records the pickup at the booked time through 0195's "Record the pickup
  now (details later)": the booking goes on rent with its usual effects and Fleet gets the task for the photos, km and
  fuel. Every guard of that path stays: the deposit taken or waived by an Admin with a reason, the renter's signature or
  an Admin's reason, the agreement's claim check, every driver verified, the coverage confirmed, the tracker for staff.
  A refusal is shown in the dialog as the database words it.
- **Ended, never closed**: a confirmed booking with no check-out whose return time passed and whose car has gone out
  again since (the owner's Kia Forte of October 25 to 27). It is not counted as out. **Close** records the pickup and the
  return at the booked times through the same path, with the same guards.
- **Coming back**: overdue, today and tomorrow, with the time and countdown and how it comes back.
- **Going out**: confirmed pickups in the next 72 hours, delivery or pickup, with ticks and crosses: licence, signed,
  paid, deposit (a clock until the morning of the pickup day, 0261), check-out photos (done at the handover).
- **Money due**: every renter payment due in the next 7 days or overdue, across confirmed, on rent and returned
  bookings.
- **Free now**: available cars not out or booked for now, longest idle first, with their next pickup; then the cars in
  maintenance or cleaning (out of service, or a service, repair or cleaning block now). Partners' cars are counted apart.
  Placeholders (0283) never appear anywhere on the screen.

The page refreshes every 30 seconds while it is visible (the Live map's pattern, `/api/staff/bookings-now`), and the
countdowns move. Every time and day is Toronto time.

## Payment plans (0330)

`bookings.pay_every`: whole, weekly, biweekly or monthly; empty means automatic (monthly when the rental has periods,
0139 and 0148, else whole). `app.booking_pay_schedule` cuts the renter's part (the total less the insurer's share and its
HST) into payments by their days from the pickup (monthly uses the periods), and finds the next one: overdue (the
amount is everything due by now), soon (3 days) or upcoming. Insurer payments do not count toward the renter's part.
The booking page shows a **Payment plan** card (Overview and Money) with each payment and **Change the plan** (Admins,
customer service, finance; `ops_do booking_pay_every`, in the booking history). Fleet reads it.

## Database

- `app.fleet_board(p_now)`: the whole screen in one read. `app.bookings_now_read` checks who asks: Admins, fleet and
  customer service get everything; field staff get the cars without money, and the renter's phone only on their own
  jobs. Door: `ops_read bookings_now` (also `field_read`), `ops_read booking_pay_plan`, `ops_do booking_pay_every`,
  `ops_do booking_close_ended`.
- All bookings: the status choices are now All, **Out now** (on rent plus pickups not recorded, together), Booked,
  Returned, Closed, Cancelled, with **Bill to** beside them. `?status=on_rent` opens Out now; the other old `?status=`,
  `?q=`, `?supply=` and `?added=` links open All bookings with that filter. Requests, offers and bookings waiting for
  payment are under Requests and offers.
- Tests: `supabase/tests/99_now_board.sql` (weekly and biweekly next payments, an overdue return first, an insurer
  billed rental, a placeholder left out, a backdated rental behind on its payments, a long rental on monthly periods, a
  pickup not recorded and Mark picked up, ended never closed and Close, Bill to, who reads what);
  `web/tests/e2e/bookings-now.spec.ts` at 375 and 1440 with axe; `web/src/features/bookings-now/model.test.ts`.

## Fewer pages and tabs under Bookings

The admin menu's Bookings group, before and after:

| | Before | After |
| --- | --- | --- |
| Trips links in the menu | 6: Requests, Bookings, Calendar, Send an offer, Add a rental, Chauffeur | 3: Bookings, Requests and offers, Calendar |
| Bookings group links in all | 11 | 8 (Customers and Problems unchanged) |
| Trips pages | 6 (requests, bookings, calendar, chauffeur, offers/new, bookings/new) | 5 (Chauffeur is a tab of Requests and offers) |
| Status tabs on the bookings list | 9 (All, Requested, Offered, Waiting for payment, Confirmed, On rent, Returned, Closed, Cancelled) | 6 (All, Out now, Booked, Returned, Closed, Cancelled) |
| Tabs on Bookings | none (one list) | 2: Now, All bookings |

- Send an offer and Add a rental are buttons at the top of Bookings (and Add a rental on To do); their pages and
  addresses are unchanged.
- `/admin/chauffeur` redirects to `/admin/requests?tab=chauffeur` (with its status filter); the To do card, the
  partner page and the chauffeur task link there.
- Requests, offers and bookings waiting for payment are on Requests and offers only; their old `?status=` links on
  Bookings still list them.
- Staff: Rentals > Find a booking is now Rentals > Bookings (Now for fleet and customer service, with the search);
  field staff get Field work > Cars now.

## Guides

- `admin/requests-offers-and-bookings`: Bookings now, payment plans, Mark picked up, All bookings, Requests and offers.
- `admin/getting-around-admin` and `admin/quick-reference`: the Bookings menu.
- `admin/chauffeur-service`: Requests and offers > Chauffeur.
- `admin/partners-company-cars-and-rentals-added-by-hand` and `admin/referral-partners-and-rentalcoverage`: Add a rental
  is a button on Bookings.
- `va/fleet`: Bookings now for fleet and customer service.
- `va/shared-tools`: Rentals > Bookings (was Find a booking).
- `field/my-jobs`: Cars now.
