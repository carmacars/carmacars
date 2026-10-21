# Rentals already underway, added by hand (October 21, 2026; migration 0074)

The owner, October 21, 2026: a manual rental for the 2022 Chevrolet Malibu that had already started (picked up earlier,
due back later, the car out at that moment) failed with an error. "This will be a regular occurrence. Staff must be able
to enter a rental that is already in progress, easily, with no confusing errors."

Before: Add a rental took an upcoming rental (the pickup no more than an hour ago) or, with the Admin's tick "Record a
past rental", one whose return had passed. A rental picked up yesterday and due back next week fit neither, and the
messages pointed at the tick ("The pickup is more than an hour ago: record it as a past rental, or start it now"; "A past
rental has its return in the past").

## 1. Three cases, from the dates alone

| Dates | Case | Recorded as | Who |
| --- | --- | --- | --- |
| Pickup ahead | Upcoming | Confirmed (or waiting for the online payment with a payment link), handed over at pickup as before | Admin, every assistant function, field staff |
| Pickup passed, return ahead | In progress (new) | On trip (on_rent), handed over at the pickup entered, by the staff member who adds it | Admin, every assistant function, field staff |
| Return passed | Past | Completed (closed), as before | Admin only |

There is nothing to tick: the tick is gone from the form, which shows the case under the dates as they are typed ("This
rental is already underway: it will be recorded as on trip, picked up at the time you entered. Anything still missing
(signature, licence check, coverage proof, deposit, condition report) becomes a task."). The submit button reads "Add the
rental already underway" or "Record the past rental". The database decides the case the same way
(`app.manual_rental_phase`); an older screen that still sends "past": true with a return ahead is refused with "For a
past rental, the return must already have happened. Check the return date and time".

## 2. A rental in progress

- **The booking**: written on trip, `handed_over_at` = the pickup entered, `added_mode` = `in_progress`, confirmed at once,
  on the calendars for the remaining dates.
- **No handover gate stops it** (the car is already out). Each one still missing becomes a task, never an error:

  | Missing | Task | Queue, priority |
  | --- | --- | --- |
  | Drivers' licences checked | Verify the drivers of CC-x: the rental is already underway | Customer service, high (closes when an Admin verifies in person) |
  | Coverage confirmed | Coverage proof missing for an active rental: CC-x | Customer service, high |
  | Deposit taken | Deposit not taken for an active rental: CC-x ($) | Finance |
  | Pickup condition report | No pickup condition report for an active rental: CC-x | Fleet |
  | Agreement signed | Rental agreement not signed for an active rental: CC-x | Customer service, high (closes when the agreement is countersigned) |
  | Car on the fleet insurance policy | Insurance not confirmed for an active rental: CC-x on the car | Admin, urgent, escalated |
  | Car status cannot become On rent (onboarding, out of service) | The car is out on rental CC-x: set its status to On rent | Fleet, high |

- **As at a handover**: the car's status becomes On rent (from Available, Exit notice, Ready to list, or Cleaning through
  Available), and a managed car's owner tracker controls are held until the return.
- **No pickup or trip-start emails**: no pickup reminder, no "rental started", no offer email. The renter gets the
  rental-added email (unless "Do not email the renter"), saying the rental has started and to sign now; the owner or
  partner gets the new-booking notice.
- **Everything after works as for any rental**: the return reminders and the overdue check (on trip, return ahead), the
  return and check-in (`app.complete_return`), the cleaning block, toll and ticket matching (on trip from the pickup),
  the owner's revenue split at the return, commissions (accruing, earned once completed and paid in full).
- **Payment**: Paid another way, Unpaid, the saved card (charged when the renter signs, as for a confirmed rental added
  by hand) or a payment link. With a payment link the renter signs in the portal, then presses Pay now on the booking:
  the payment is checked as any online payment (the amount, the name, a credit card), recorded and tied to the charges,
  and the rental stays on trip (`app.finalize_booking` sends it to `app.finalize_live_payment`).
- **While the car is out**: the renter may sign the agreement, upload licence photos, the selfie and the coverage proof;
  staff may review them and an Admin may verify a driver in person.
- **The cars**: any active car, including a car whose listing is not finished and a car closed to public bookings
  (bookings turned off, Turo only, owner in arrears). A retired car, a car that left the fleet, a sample car, a car with
  no owner, a partner car whose agreement ended, or a return after the car's exit date are refused with what to do. Add
  a rental now lists every active car to assistants, tagged "closed to new bookings" when it is; an upcoming rental on
  such a car is refused with "Choose another car, or ask an Admin to open it for bookings ... If the car is already out
  with this renter, enter the pickup as when it left".

## 3. The clash check of a rental in progress

`app.manual_rental_live_clashes`: before now, the rentals that really happened on the car (on trip, returned, closed, or
confirmed and holding the calendar), as they were checked in and with no turnaround, so a car that went out an hour
after the last return is free; from now on, the trips to come with their turnaround and the calendar blocks (a cleaning
block of a trip already checked in, or a block that already ended, is history). The quote lists what is in the way the
same way. An Admin may still add it over a clash with a reason.

## 4. The past

Unchanged limits (an Admin; paid another way or unpaid; at most the setting's days back), with plain wording: "For a
past rental, the return must already have happened. Check the return date and time"; "This rental has already ended,
so it cannot be paid by payment link or saved card. Choose Paid another way or Unpaid"; "Only an Admin can record a
rental that has already ended. Check the return date and time, or ask an Admin to add it".

## 5. Every message of Add a rental says what to do

For example: "The car is not free for these dates: another rental, a calendar block or the cleaning time between trips
is in the way. Press Check the calendar and the price to see what, then choose other dates or another car"; "You cannot
take payment that way (only an Admin can). Choose one of the ways shown under Payment"; "$600.00 is above your single
limit of $500.00. Record it as Unpaid and ask an Admin to record the payment, or ask an Admin to add the rental";
"Enter the pickup and the return, each with a date and a time".

## 6. Files

- `supabase/migrations/0074_rentals_in_progress.sql`: the case, the car check, the clash check, the rental written on
  trip and its tasks, the quote, the signing and documents of a rental in progress, the online payment, the renter's
  email lines, the portal flags. Functions of 0046, 0051, 0053, 0058, 0064 and 0071 are restated with the change only.
- `supabase/tests/51_rentals_in_progress.sql` (63 assertions); suites 30 and 37 read the new wording.
- `web/src/features/supply/ManualRentalForm.tsx`: no tick; the case under the dates; the cars closed to new bookings
  listed and tagged; the payment ways per case.
- The renter portal: sign and Pay now on a rental in progress (`/account/bookings/[number]`, `sign`, `pay`, `verify`),
  `web/src/server/actions/portal.ts`, `web/src/features/portal/status.ts`.
- Admin booking page: "Added by staff while already underway".
- Guides: Admin, assistants and field staff, Add a rental (`docs/guides/src/guides/*.py`, `docs/guides/content/*.json`).
- `web/tests/e2e/rentals-in-progress.spec.ts` at 375 and 1440 pixels.
