# Rates and kilometres in one step, deleting sample cars with requests, rentals before the listing is finished (October 19, 2026)

Migration `0064_rates_form_sample_delete.sql`; tests `supabase/tests/43_rates_form_sample_delete.sql` (06, 08 and 42
updated); unit tests `web/src/features/rates/rates.test.ts`; end to end `web/tests/e2e/rates-form.spec.ts` (375 and 1440)
and `admin.spec.ts` updated. Guides: admin (Requests, Fleet and listings, Partners and company cars) and assistant
(Fleet, Add a rental by hand), published by the migration (`supabase/seed/0064_gen_guides.mjs`). No new email
template. No applied migration was edited.

## 1. The owner's report: "it breaks when having to put in a price"

### Root cause

The rate card was saved by two separate forms, and each one was refused for what only the other one held:

| Form (Admin > Vehicles > the car > Rates) | What it sent | Refusal on a car with no rate card (0020's `app.set_rate_card`) |
| --- | --- | --- |
| Rates from now: daily, weekend, weekly, monthly | the four rates, no kilometres | "A first rate card needs the kilometres per day, and an overage rate and Deposit either given or set in the fee defaults for the class" |
| Kilometres, overage, deposit, delivery | the kilometres plus the car's current rates, which a car with no rate card does not have (empty) | "The daily, weekend, weekly and monthly rates must all be above zero" |

So a new car could not get its first rate card from the screen at all. Reproduced on a 0063 database with the two door
calls the forms make (first: the kilometres refusal; second: the rates refusal). Add a car (company and partner cars)
did not go through the check but saved hard-coded 200 km and $0.25 a km (under the $0.35 default and outside the luxury
and exotic range), and had no rates at all for a program owner's car. Fleet had no rate screen. Bulk rates were not
affected (they only change cars that already have a card).

### What changed

| Change | Where |
| --- | --- |
| One check, `app.rate_card_check(vehicle, fields)`: the four rates, the kilometres ("Use the defaults" or "Custom for this car"), the deposit, delivery and pickup, validated together. Errors come back by field, in words; warnings (weekly above 7 days of the daily rate, monthly under weekly) never block | 0064 section 3 |
| Only the daily rate is needed. An empty weekend rate is the daily rate, weekly 6 days, monthly 22 days (the derivations Add a car already used), shown as "Empty: $X" in the fields | 0064 section 3, `RateFields.tsx` |
| `app.set_rate_card` (same arguments) runs the same check. A first card takes the default kilometres and overage instead of refusing; a later card keeps the car's own kilometres unless new ones are given (so bulk changes keep them) | 0064 section 4 |
| `app.rate_card_save` saves everything in one step (door `rate_card_save`, Admins and Fleet); `rate_card_check` and `rate_card_form` are the reads | 0064 sections 4 and 9 |
| `app.vehicle_add`: rates checked before anything is written and saved with `set_rate_card`, for company, partner and program owner cars | 0064 section 5 |
| One form everywhere: Add a car, the car's Rates tab (with delivery, pickup and the start time), the Fleet assistant's car page (linked from the listing as "The car and its rates") | `web/src/features/rates/*`, `AddCarForm.tsx`, `admin/vehicles/[id]`, `va/vehicles/[id]`, `va/listings/[id]` |
| The publish gate's "no rates are set" now says where to set them | `ListingReview.tsx` |
| The kilometre choices no longer say "0 unlimited": 0 was never unlimited (the overage would charge every km) and the choices table refuses 0 | `admin/settings/[section]` |

### What each rate means (from `public.calc_rental_charge`, 0003)

Each 24 hours from the pickup time is one day, on the Toronto clock.

| Rate | Meaning | Label |
| --- | --- | --- |
| Daily | per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday | Daily rate (per day, Sunday to Thursday) |
| Weekend | per day, **not** for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 weekend days; Sunday is a daily day | Weekend rate (per day, Friday and Saturday) |
| Weekly | the price for 7 days. 7 to 29 days cost weekly x days / 7, never more than the monthly rate; 1 to 6 days never cost more than the weekly rate | Weekly rate (price for 7 days) |
| Monthly | the price for 30 days (a rental is 30 days at most) | Monthly rate (price for 30 days) |

Under the fields, "What renters pay (before tax)" prices six examples with `public.calc_rental_charge`, the function
every booking is priced with: Friday to Sunday, Monday to Thursday, Friday to Monday, 7, 14 and 30 days, each with the
kilometres included.

### The defaults

| Value | Default | Where it is set |
| --- | --- | --- |
| Kilometres included a day | 200 | Program settings `default_km_allowance_per_day` (new; also on Settings > Kilometre choices) |
| Extra kilometre rate | $0.35 a km; luxury and exotic: the lowest of their $0.75 to $1.50 range | Fee defaults, Mileage overage, by class (unchanged) |
| Deposit | the class's Deposit default ($500 economy and standard; $1,000 premium and SUV; $2,500 luxury and exotic in production) | Fee defaults, Deposit (unchanged) |
| Custom kilometre choices | 400, 300, 200, 150 a day | Kilometre choices (unchanged, 0025) |

The repository records the 400, 300, 200 and 150 km a day as the choices offered on a rate card (0025, the owner's
answers), not as tiers by rental length: a rental includes the car's kilometres a day times its days. So there is one
default a day, with the choices offered under "Custom for this car".

A suggestion line shows the median rates of similar real cars (the same make and model, else the same class) with
"Use these"; it is a hint and never fills the fields by itself.

## 2. The owner's report: sample cars "cannot be deleted because of active bookings"

The blocker counted every booking, including requests that never became rentals (CC-10001 declined, CC-10003 expired,
CC-10002 still requested, none with a payment).

| Change | Where |
| --- | --- |
| `app.booking_never_confirmed(booking)`: requested, offered, tentative, declined, expired or cancelled, never confirmed, and no payment, deposit taken, refund, split, statement, signed agreement or swap | 0064 section 6 |
| Such bookings no longer block a delete. Only confirmed or paid bookings do, named by number: "1 confirmed or paid booking (CC-10005)" | `app.vehicle_delete_blockers` |
| The delete confirmation lists the requests that go (`app.vehicle_delete_removes`, door `vehicle_delete_preview`; Sample cars shows them per car). They are copied to `deleted_booking_requests` (the booking, its history and offers) and removed with the car; the renter records stay. Booking history and messages stay append-only (their triggers are lifted only for the length of the delete) | `app.vehicle_delete`, `DeleteCar.tsx`, `admin/vehicles/samples` |
| Delete all sample cars follows the same rule and reports the requests removed | `app.vehicles_delete_samples` |
| A request whose pickup time passed without an offer expires: the offers-expire job (every 5 minutes) also runs `app.expire_stale_requests`, writes "The pickup time (...) passed before an offer was sent ..." in the booking history, closes the request task, and emails the renter only when `stale_request_email_renter` is on (off by default). CC-10002 expires on the first run after the deploy | 0064 section 7 |

## 3. The owner's request: Add a rental before the listing is finished

| Rule | How |
| --- | --- |
| A car with a draft listing, in onboarding or ready to list, with no photos, no rates or the plate not checked can take a rental added by staff | `app.vehicle_bookable` accepts onboarding and ready to list; every public flow still reads only published listings (`public_vehicle_listings`), and publishing makes a car Available, so nothing changes on the public site |
| The car must have a valid supplier: an owner, CarmaCars, or a partner whose partnership has not ended. A program owner's car needs its terms (Revenue Share) first | `app.vehicle_bookable`, `app.vehicle_needs_terms` |
| No rates: a rental charge typed with its reason (the usual price flags). The quote is priced on a stand-in rate card from that price, rolled back at once; the booking gets the default kilometres, overage and class deposit | `app.manual_rental_quote`, `app.manual_rental_create`, trigger `bookings_rental_defaults` |
| A program owner's car with an unfinished listing that is not yet on the fleet insurance policy: only an Admin adds its rentals, ticking "I checked that this car is insured for this rental" (recorded in the audit log). CarmaCars-owned cars have no fleet policy step and partners insure their own | `app.vehicle_needs_policy_confirm` |
| Clashes, payment (link, saved card, paid another way), agreements, verification and handover are unchanged: the handover still needs the car to be Available, which the quote says | `app.manual_rental_create_pre0064` |
| The car picker tags these cars "Listing not finished" and "no rates yet" | `app.manual_rental_vehicles`, `ManualRentalForm.tsx` |
