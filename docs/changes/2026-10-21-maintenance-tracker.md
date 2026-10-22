# The maintenance and service tracker (October 21, 2026; migration 0089)

The owner: "We need a maintenance and service tracker for every car so we can track when the last oil changes were and
brakes and tires and if they're on summers or all seasons or winters. When service stuff is done and billed, it should
auto update the status of each car and reset the timers and reminders for service."

Migration `0089_maintenance_tracker.sql` (schema marker `0089`). No applied migration was edited.

## 1. Service items and their intervals

Admin > Settings > Maintenance holds each item's default; an Admin may set an interval for a class (the car's deposit
class) or for one car. A car's own interval comes first, then its class's, then the default. Whichever of km and months
comes first is due; 0 or empty means not by that measure.

| Item | Default | Kind |
| --- | --- | --- |
| Oil and filter | 8,000 km or 6 months (not for electric cars) | Interval |
| Tire rotation | 10,000 km | Interval |
| Brake inspection | 20,000 km or 12 months | Interval |
| Brake pads and rotors | Recorded when replaced (an interval may be set) | Record |
| Tires: tread and age | From the set on the car: due soon at 4 mm or 5.5 years, overdue at 3 mm or 6 years | Tires |
| Seasonal tire swap | Ontario: winter tires on by December 1 (reminder from November 1), off after April 1 (reminder from April 1, overdue after May 1); all-weather tires need none | Seasonal |
| Safety inspection or certificate | Expiry date (12 months from the service when none is typed); handover refused once expired | Expiry |
| Registration and plate sticker | Expiry date; until one is recorded, the end of the plate renewal month of the car's registration (never blocks); handover refused once a recorded expiry has passed | Expiry |
| Battery | 48 months | Interval |
| Wiper blades | 12 months | Interval |
| Cabin air filter | 24,000 km or 12 months | Interval |
| Engine air filter | 30,000 km or 24 months (not for electric cars) | Interval |
| Wheel alignment | 20,000 km or 12 months | Interval |
| Fluids check | 8,000 km or 6 months | Interval |
| Annual inspection | 12 months | Interval |

Each car keeps per item: last done (date and km), next due by date and km, the date the km projection gives, the status
(ok, due soon, overdue, unknown; "no schedule" for a record-only item, "off" when not tracked for the car) and a detail
line. Due soon: 1,000 km or 14 days before (Program settings `maint_due_soon_km`, `maint_due_soon_days`; an item may set
its own: 30 days for inspections, registration and the battery, 180 days for tire age).

The Ontario safety standards certificate a car gets for its transfer (onboarding) is not taken as the safety inspection:
it is valid 36 days and would block every car's handover afterwards. The item is the fleet's own inspection.

## 2. Tires

Tire sets per car (`vehicle_tire_sets`): summer, all-season, winter or all-weather; size, brand, model, tread depth and
when it was measured, made (DOT) and purchase dates, where it is stored, the set on the car; retired sets with the reason;
the swap history (`vehicle_tire_swaps`). A swap is recorded from the record pop-up (the seasonal swap item: the set that
went on and where the removed set is stored) or with Put on the car.

**The Winter tires add-on** (`app.addon_applies`, `app.addons_for_car`): offered only on a car with a winter set (on it or
stored) or with no tire record yet; a car on winter tires says "This car is on winter tires now." in the add-on's
description. Program settings `maint_winter_addon_link` (on) turns the link off.

## 3. The odometer and km a day

`vehicle_odometer_readings` gets every reading the system already has: handover and return condition reports (and the
other condition reports), field staff moves (start and end), the rental's odometer out and in, listing photos (the
listing intake's odometer, read from the owner's or staff's photos), the car record (owner wizard, VIN decode intake, the
Admin's edit), services, and readings added by hand (a reading lower than the last needs a tick; an Admin voids a wrong
one). Existing readings were copied in. The current odometer is the highest reading not voided; the car record follows it.

Km a day: the last reading against the one at the start of the window (`maint_km_per_day_window_days`, 90), else the
rentals' km over the last year, else `maint_default_km_per_day` (60). It gives the date a km interval will be reached, used
to sort and shown on the car.

## 4. Recording a service, and its bill

One pop-up (`RecordService`) from the car's Maintenance tab (Admin's car page and Fleet's car view), from each car of the
fleet overview, and from a To do line or a Fleet task (the link opens the car with the pop-up open). It takes the items
done (the ones due are ticked), the date and odometer (empty: the reading of that day, marked estimated), the shop, the
cost before HST and the HST (worked out at the Program settings rate, editable), who pays, "The bill is in: bill it now",
the receipt (PDF, JPEG or PNG, stored in the private documents bucket) and notes; per item: a new expiry date
(inspection, registration), the tread depth or new tires (a new set on the car, the old one retired as replaced), the set
that went on (seasonal swap).

Saving (`app.maint_record`, one transaction) records the service, resets each item's timer (last done, next due, expiry),
adds the odometer reading, makes the bill, refreshes the car's status and its task:

| Who pays | The bill |
| --- | --- |
| The owner (default for a program owner's car; owner agreement 11.1: the owner pays for maintenance and routine wear) | An open owner cost (`owner_deductions` kind `maintenance`, the total with HST, the receipt), deducted on the owner's next statement as an owner cost (agreement 8.6: owner costs CarmaCars paid) |
| CarmaCars (default for a company car) | A company expense with the car, the owner, the receipt, under the service category whose items match (else "Car maintenance and service") |
| A claim | A repair cost on the claim's ledger |
| The renter | A post-rental charge at cost on the rental (`damage_at_cost`) |
| No charge | Nothing (warranty, the owner paid the shop, a partner car's partner pays directly) |

Not billed yet: recorded and the timers reset; **Bill now** on the record later (cost, HST, who pays, claim or rental may be
changed then). An assistant's service above their single limit is recorded and waits for an Admin ("An Admin bills it"):
an Admin task, Bill now for the Admin. **Void** sets the timers back to the service before; a company expense is voided, an
open owner cost waived, a renter charge not yet on a statement voided; a cost already on a statement or a claim's ledger
stays and the void is refused with what to do.

**The other way**: an expense entered in Money > Expenses with a car under a service category records the service of the
category's items (source "from Expenses"); voiding the expense voids that record. Categories added: Car maintenance and
service, Car service: oil change (oil and filter, fluids), tires (new tires), tire rotation or seasonal swap, brakes
(inspection, pads and rotors), safety or annual inspection, Car registration and plate sticker, Car service: battery
(`maintenance_categories`, editable in Settings > Maintenance).

## 5. Reminders and blocks

- **Fleet task**, one per car (`maintenance_due`): "2022 Chevrolet Malibu ABC123: 2 service items overdue", the items in
  the detail, high when something is overdue, urgent when a blocking expiry has passed; kept up to date and closed when
  nothing is due. One task per car with no record yet (`maintenance_backfill`, low), asked once.
- **To do** (Admin): cars with a service overdue or due soon, services recorded and not billed yet, cars with no service
  record yet.
- **Quiet**: one line in the Admin's and Fleet's morning digest ("Maintenance: 2 cars overdue, 3 due soon"); no other
  email. The daily watch (`app.job_maintenance_watch`, hourly cron, runs once a day from 06:00) refreshes the statuses and
  tasks. Program settings `maint_tasks_enabled`, `maint_digest_enabled`.
- **Handover**: refused while a recorded safety inspection or registration has expired ("Do not release the car: Safety
  inspection or certificate expired on ... Renew it, record it under Maintenance, then hand the car over"); an item's
  "Refuse the handover once it has expired". Owner bookings and rentals already underway are not stopped.
- **New bookings**: "Block new bookings on a car while this is overdue" per item, by class or car: off for every item.

## 6. Screens

- Admin > Cars > **Maintenance** (`/admin/maintenance`) and Fleet's **Maintenance** (`/va/maintenance`; Finance:
  Maintenance bills): every real car most urgent first, counts by status, filters (show, service item, sort, search),
  each car's next item due, odometer, km a day, tires, last service, the items overdue or due soon, the record pop-up.
- The **Maintenance** tab of the Admin's car page and the Maintenance section of Fleet's car view: status per item with
  last done and next due, Tires (add, edit, put on, retire, swaps), Service history with the bill and the receipt (Bill now,
  Void), Odometer readings, Intervals for this car.
- Admin > Settings > **Maintenance**: items, intervals by class or car, the service categories, the reminder settings.
- The owner portal's car page: **Service and maintenance**, read only: what is due, the tires, every service with who paid
  and the amount billed to the owner.

## 7. Backfill

Every real car (not a sample, not retired or gone) got its items, unknown until recorded, and one task to record its last
service (at the first daily watch). The 9 real cars on the live site at this release start that way.

## 8. Files

- `supabase/migrations/0089_maintenance_tracker.sql`; `supabase/seed/0089_gen_guides.mjs` (the guides block).
- `web/src/features/maintenance/` (`model.ts`, `RecordService.tsx`, `Views.tsx`, `Settings.tsx`, `OwnerHistory.tsx`,
  `maintenance.css`), `web/src/server/actions/maintenance.ts`, the pages above, the navigation, the Fleet task links
  (`features/va/tasks.ts`), the receipt for Fleet (`app/va/documents/[id]`), Program settings labels.

## Tests

- Database: `supabase/tests/55_maintenance_tracker.sql` (116 assertions: defaults, backfill and the task asked once, km a
  day, due soon and overdue by km and date, the projection, recording and the reset, the company expense both ways and its
  void, the owner cost on the owner statement and its void, not billed and Bill now, the assistant's limit, claim and
  renter, settings by class and car, readings from moves, the rental, condition reports and by hand, tires and the seasonal
  dates, new tires, the winter add-on, the handover and booking blocks, permissions, the overview and car reads, To do and
  the digest). Suite 34 lists the three new To do lines.
- Unit: `web/src/features/maintenance/model.test.ts` (sort, filters, words, HST, preselection, the bill in words).
- End to end: `web/tests/e2e/maintenance.spec.ts` at 375 and 1440 (the overview and the pop-up as an Admin with the
  company expense, the car's tab and a tire set; Fleet from a task link with a receipt above the limit, the Admin's Bill now).

## Guides

Admin: `admin/maintenance-and-service` (new chapter). VA: `va/car-maintenance` (new chapter). Owner:
`owner/home-and-your-vehicles` (Service and maintenance). Published by the 0089 guides block.
