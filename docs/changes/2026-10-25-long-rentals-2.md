# Long rentals, part 2 (migration 0145)

The owner's requests after the first long rentals checkpoint (0139): "drafts and autosave of Add a rental and the offer
form", "Quick start at pickup: the renter's name and phone, the car, pickup now, kilometres and fuel; finish the rest
later", and "a monthly agreement for each period of a long rental, sent ahead".

## What changed

1. Drafts (table `rental_drafts`). Add a rental (Admin, assistants, field staff) and Send an offer are saved as a
   draft as they are typed (1.5 seconds after the last change, once a car, a name, a phone or a renter is in), on the
   server for the person who typed it, with a copy on the device when the server cannot be reached ("Restore what you
   were typing on this device"). Nothing is required to save. Save draft saves at once; Discard drops it.
2. Unfinished rentals: on Admin > Bookings, Add a rental, the assistant's Today and Add a rental, field staff's Add a
   rental (their own) and Send an offer (Unfinished offers). Each says who started it, when, whether the car is held, and
   what is still missing (the car, the dates, the renter, the email, the date of birth, how it is paid). Finish it opens
   the form where it was left (`?draft=`), on any device.
3. Hold the car while I finish: a calendar block of 2 hours on the car (reason admin, source staff), renewed each time
   the draft is saved, moved when the car changes, removed when unticked, discarded or added. A draft never blocks the
   calendar without it. Adding the rental lifts the draft's own hold first, so it is not a clash.
4. Quick start at pickup: the renter's name and phone, the car, the kilometres and the fuel; the pickup is now and the
   return tomorrow. Hold the car and finish later saves the draft held, and raises a task (finish_rental_draft, customer
   service, high, due in 2 hours) that closes itself when the rental is added or the draft discarded. The kilometres and
   the fuel go on the booking (`odometer_out_km`, `fuel_out_pct`) when it is added.
5. A long rental's periods (table `booking_periods`), kept in step with the booking's dates by a trigger: one row per
   period of `app.rental_periods`, each with its share of what is due. The first is covered by the booking's agreement.
   Each later period gets its own version of the agreement (CarmaCars' and Blind Spot's), made by the five-minute job
   `long_rental_agreement_lead_days` before it starts (`server_periods_due`, `server_period_begin`, the site renders it
   as the renter, `server_period_done`) and sent to the renter to sign; the agreement number gets the period (RA-20001-P2)
   and the agreement says "Period 2 of 3: dates, rent and fees for this period". The earlier version is kept as
   superseded (a new status), never voided. Three misses raise a task (Sign now or paper). Staff see Monthly periods on
   the booking (Overview and Money) and may press Send the agreement for period N now.
6. The agreement's Length line no longer says "30 days maximum".

## Privileges

Every new function is executable by service_role only; staff reach drafts and periods through the door
(`ops_read` drafts, draft_get, booking_periods; `ops_do` draft_save, draft_close, period_send_now). `rental_drafts` and
`booking_periods` have RLS with the Admin policy only.

## Not done yet

- Charging the saved card by itself for each later period (`long_rental_autocharge`): the period's share shows on the
  renter's Balance due, and staff take it as before.
- The sim report items, renter merge, and the (i) tips on the remaining screens: next checkpoint.

## Guides

- `admin/partners-company-cars-and-rentals-added-by-hand`: Quick start at pickup, drafts and Unfinished rentals, Hold the car, Monthly periods.
- `va/add-a-rental-by-hand`: the same for assistants.
