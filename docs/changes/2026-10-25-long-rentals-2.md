# Long rentals, part 2 (migration 0148)

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

### From the simulation report (scratchpad/sim/REPORT.md)

7. Item 2, Sign now: with no agreement made yet (the renter never saved their details at home), Sign now on this device
   still shows and offers Prepare the agreement to sign now (`server_sign_now_prepare`, then the site makes it as the
   renter, as the job does).
8. Item 3, insurance replacements added by hand: Insurer billed later shows the insurer (or Not listed: its name, added
   to the list), the claim, the adjuster (name, email, phone), the days and the daily rate authorized, the provisional
   end, and whether the insurer pays everything or the rental only. The booking is billed to the insurer (or split) with
   its share worked out (`app.booking_insurer_share`); never the raw bookings_bill_to_insurer error.
9. Item 4: Swap vehicle (on trip) picks the car from the free cars, not a typed id.
10. Item 7: Collect a card covers Everything open by default (the rental, the fees and later charges in one); Record a
    payment refuses a payment against a part with nothing open unless an amount is typed; Money tab words instead of raw
    codes (purpose, kind, status); the Payments table under Money by part shows only failed card payments, and the
    payments received another way fold under Correct or void (they are in Money by part's list already).
11. Item 8: Sales may record Renter approved by phone on its offers (as customer service does). Sales already photographs
    the licence in Sign now.
12. Item 9: the offer screen's car list narrows by type (body or class) and to the cars free for the dates.
13. Item 11: "Deposit not taken" closes itself when the deposit is taken (a trigger on deposits; the ones open by mistake
    are closed by the migration), and a staff-made offer leaves no "New booking request" task.
14. Item 12: on the offer screen, an address picked from the suggestions measures the distance from our location and
    prices the delivery (deliveryDistance).
15. Item 13: new dates keep a rental charge typed by hand, in proportion to the days (`app.booking_price_spec`), unless
    "recompute" is asked.
16. Item 15: the database's own refusals (a check, a unique key, a missing value, a bad value) reach staff and renters as
    sentences (`src/lib/db/friendly.ts`, in DbError itself; the raw text is kept on `raw`).

### Renters and price lines

17. Two records of one renter, merged: Possible duplicates (same email, same phone, or same name and date of birth) on
    the renter's page and on their bookings; Merge into this record moves every reference (bookings, drivers, cards,
    payments, documents, messages, tasks, signatures, payment links...) and fills what the kept record lacks, the sign-in
    too when it has none; the other record stays blocked with `merged_into`, and both histories say so.
18. The (i) beside every line of the booking's Fees table and the offer review's price lines.

### Finished after the audit

19. long_rental_autocharge: once a later period's agreement is made, what is still open for it (its share, never more
    than the booking's balance) is charged to the saved card off session (`server_period_charge_begin` and `_finish`,
    the five-minute job). The renter gets the receipt; a declined or missing card raises a Finance task
    (period_charge_failed). Monthly periods shows each period's charge.
20. Add a rental prices the delivery and the collection from the address, as the offer screen: an address picked from
    the suggestions is measured from our location; the check and the booking (pickup_distance_km, set while the booking
    is inserted, so its first pricing uses it) price it by app.delivery_fee.
21. The offer's email and text carry a one-time sign-in link for a renter whose email was never confirmed (staff
    entered them by phone): `app.offer_continue_link` makes a "continue" link (0090) landing on the booking, and the
    offer's payload uses it as its link.

## Privileges

Every new function is executable by service_role only; staff reach drafts and periods through the door
(`ops_read` drafts, draft_get, booking_periods, renter_duplicates; `ops_do` draft_save, draft_close, period_send_now, renter_merge). `rental_drafts` and
`booking_periods` have RLS with the Admin policy only.

## Not done yet

- The renter's licence review (Verify) stays with customer service.

## Guides

- `admin/partners-company-cars-and-rentals-added-by-hand`: Quick start at pickup, drafts and Unfinished rentals, Hold the car, Monthly periods, the insurance replacement fields.
- `admin/requests-offers-and-bookings`: Possible duplicates and Merge into this record; Collect a card covers everything open; Prepare the agreement to sign now.
- `va/add-a-rental-by-hand`: Quick start at pickup, drafts, Monthly periods.
- `va/customer-service`: Merge into this record.
