# Field staff review the renter's licence, October 25, 2026

The owner's words: "License review should be done by field staff as well." Until now the renter's identity review (licence
front, licence back and the selfie: approve all, or reject with a reason) was for customer service and Admins (`/va/verify`,
the Review documents pop-up). Field staff could only check a licence in person inside the handover's ready check (0151).
Now field staff review the licence too, for the bookings on their own field jobs. Migration
`supabase/migrations/0162_field_licence_review.sql` (SCHEMA_MARKER `0162`), guides by `supabase/seed/0162_gen_guides.mjs`.

## 1. What field staff can do

- **My jobs** (`/field`) shows **Licences to check** when the licence front, back or selfie of a renter on one of their
  upcoming jobs waits for a decision: one card per booking (the day and time, the car and plate, the renter's first name and
  booking number, how many images wait) with **Review the licence**. The section is absent when nothing waits, and another
  field staff member's jobs never appear.
- The same **Check the licence** is on the job page (`/field/jobs/[id]`) while the booking has an image waiting.
- **Review the licence** opens a panel (the field design: black and white, 56 px buttons, one column): the renter, the car,
  the pickup and return, each driver's date of birth and licence details from the booking, and each image waiting, with what to
  check written once (the name and date of birth match, class G2 or G valid past the return and no alteration, the selfie
  matches). **Approve all (n)** approves every image waiting; **Reject this one** under an image takes a reason (at least
  5 characters) which the renter reads: they are told by email and asked for a new image, exactly as when customer service
  rejects it. A refused item is named with the reason and the rest approved, as with the office's Approve all.
- Only the licence front, licence back and selfie. The proof of coverage and the Protection Plan stay with Admin and
  customer service (`doc_review_can` is not changed, so the office's coverage and plan functions still refuse field staff).
- Only for bookings on their own jobs: assigned to them, not cancelled, scheduled today or in the next 7 days. Another field
  staff member's job, a cancelled job, a job more than 7 days away and a booking with no job of theirs are all refused.

## 2. Same decision, same trail

| | Customer service | Field staff |
| --- | --- | --- |
| Function that decides | `app.review_verification_upload` | the same one, called by `app.field_licence_decide` |
| Statuses | `approved`, `rejected` (with `reject_reason`), `reviewed_by`, `reviewed_at` | the same |
| Identity | three approved images verify the driver (`staff_review`); a rejection marks the identity failed | the same |
| Renter told | `renter_identity_rejected` on a rejection; `renter_identity_approved` when all is confirmed | the same events |
| Booking history | `verification` event, actor type `staff`, the reason as the note | the same, plus `details.reviewer_role = 'field'`; an approval's note reads "Licence reviewed by field staff" |
| Opening logged | `data_access_log` | the same (reason "licence review by field staff, booking ...") |

For one call the field staff member acts as customer service through the setting 0151 introduced (`app.field_as_cs`,
named for the user, cleared at once, so nothing else in the transaction gains anything); `app.review_role` marks the call so
`app.log_booking_event` (renamed `log_booking_event_pre0162` and wrapped) adds the role to the history line.

## 3. The database

- `app.field_licence_can(user, booking)`: a field staff member with a job of that booking, assigned to them, not cancelled,
  on a local date from today to today + 7.
- `app.doc_review_licence_can(user, booking)`: `doc_review_can` (an Admin, or customer service) or `field_licence_can`.
  `doc_review_can` itself is unchanged: Admin and customer service behave as before.
- Four door calls, all through `app.door` (wrapped as `door_pre0162`): `field_read licences` (the cards),
  `field_read licence_review` (one job's licence images, no coverage), `field_do licence_approve_all`,
  `field_do licence_reject`. Each is for field staff only; an Admin or customer service calling them is refused ("Only field
  staff may do this"), and the office's own calls (`ops_do doc_review_*`) still refuse field staff.
- All new functions are for `service_role` only.

## 4. The website

- `web/src/features/field/LicenceReview.tsx`: the panel; `web/src/server/actions/field-licence.ts`: loads the images with
  one-minute private links; the decisions go through `fieldAct` (`licence_approve_all`, `licence_reject`). The panel keeps its
  message on screen and refreshes the lists when it closes (those two actions do not revalidate `/field`, which would remove
  the card and the message together).
- `web/src/app/field/page.tsx` (the section) and `web/src/app/field/jobs/[id]/page.tsx` (Check the licence);
  `web/src/styles/field.css`; `dayLabel` in `web/src/features/field/format.ts`.
- `web/src/lib/db/types.ts` regenerated.

## 5. Tests

- `supabase/tests/99_field_licence_review.sql`: the list (own jobs only, not another's, not beyond 7 days, not a cancelled
  job; CS and Admin refused); the read (images, no coverage, the opening logged); refusals (another's job, an upload of another
  booking, beyond 7 days, cancelled; the office's own calls still closed to field staff); reject needs a reason, the status, the
  failed identity, the renter told, the history with the role; approve all (statuses and `reviewed_by`, the driver verified, one
  history line each with the role, nothing left on the list, nothing done twice); no rights left over; customer service and Admin
  unchanged and without a field role in the history; privileges.
- `web/tests/e2e/field-licence-review.spec.ts` (375): another field staff member's home has no section; the home lists the
  booking; the panel shows the three images; reject the front with a reason (database: status, reason, reviewer, history role,
  renter told); the job page has the same check; Approve all (three approved by the field staff member, the driver verified,
  three history lines with the role); the section is gone from the home; axe and no horizontal overflow.
- `web/src/features/field/format.test.ts`: `dayLabel`.

## Guides

- `field/my-jobs`: Check the renter's licence.
- `va/customer-service`: field staff review the licence images of their own jobs; the history says the role.
- `admin/requests-offers-and-bookings`: the same.
