# Restore this version on a confirmed booking (Release 45: 2861)

Migration `2861_r45b_booking_versions.sql`.

Revert to this offer works only before a booking is confirmed. After it, staff changing the dates and the fees could not go back (a 7 day booking changed to 4, then 3, then 7 again was repriced higher than the first 7).

- **Versions**: every change of a confirmed, on-trip or returned booking is kept with the booking before and after (0132) and now with every fee line (`booking_staff_edits.lines_before`, `lines_after`). A change of the fees alone on such a booking is kept as a change too. Overview shows **Versions of this booking**: version 1 is the booking before its first change, then one version after each change, the newest current.
- **Restore this version**: a preview first (the dates, the car, the rental charge, the total and what the renter would owe or be owed), then with the reason the booking goes back to that version's dates, car, rental charge and fee lines exactly, as one more change through the same edit (`app.booking_staff_edit`): who may change bookings and fees, the car free for the dates, the log and the reason. The renter is told only when ticked.
- **Money**: payments are never touched. A difference is a balance to collect or a credit to settle, as with any edit.
- **Who**: an Admin, and customer service and Sales while Program settings let staff change bookings (the same rule as Edit).
- A version kept before this release has no fee lines: its dates, car and rental charge go back and the fees stay as they are (the preview says so).

## Guides

`admin/requests-offers-and-bookings`, `va/customer-service` (migration 2865).
