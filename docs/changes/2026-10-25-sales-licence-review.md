# Sales review the renter's licence, October 25, 2026

The owner's words: "Sales should approve licenses ya". Until now the renter's identity review (licence front, licence back and
the selfie: approve all, or reject with a reason) was for customer service and Admins (`/va/verify`, the Review documents
pop-up), and, since 0162, field staff for their own jobs. Sales could only photograph the licence in Sign now. Now the Sales
function reviews the licence like customer service. Migration `supabase/migrations/0169_sales_licence_review.sql`
(SCHEMA_MARKER `0169`), guides by `supabase/seed/0169_gen_guides.mjs`.

## 1. What Sales can do

- **To do** (`/va`) shows **Licences to check** for Sales: one line per booking with a licence front, back or selfie waiting (the
  renter's first name, the car, the booking number, how many images, the wait) and **Review the licence**. It reads "Nothing
  waiting" when the list is empty.
- The booking page (`/va/bookings/[number]`) has the card **Renter licence** with **Review the licence** (the same pop-up the
  Admin's booking page has), for a booking being arranged or under way.
- `/va/verify/[number]` opens for Sales: the checks, each image with Approve or a reason to reject, and **Approve all**. The page
  has no coverage card for Sales.
- Only the licence front, licence back and selfie. The proof of coverage and the Protection Plan stay with customer service and
  Admins: `doc_review_coverage`, `doc_review_plan`, `coverage_review` and `protection_plan_confirm` still refuse Sales, and a proof
  of coverage upload sent to `doc_review_upload` or `verify_upload` by Sales is refused ("Sales reviews the licence and the selfie").
- Which bookings: `app.sales_licence_can(user, booking)`: an active Sales assistant, and the booking is requested, offered,
  tentative, pending payment, confirmed or on rent, or has a licence image waiting. A cancelled or closed booking with nothing
  waiting is refused. `app.doc_review_licence_can` (0162) admits Sales as well.

## 2. Same decision, same trail

| | Customer service | Sales |
| --- | --- | --- |
| Function that decides | `app.review_verification_upload` | the same one, called by `app.sales_licence_decide` |
| Statuses | `approved`, `rejected` (with `reject_reason`), `reviewed_by`, `reviewed_at` | the same |
| Identity | three approved images verify the driver (`staff_review`); a rejection marks the identity failed | the same |
| Renter told | `renter_identity_rejected` on a rejection; `renter_identity_approved` when all is confirmed | the same events |
| Booking history | `verification` event, actor type `staff`, the reason as the note | the same, plus `details.reviewer_role = 'sales'`; an approval's note reads "Licence reviewed by sales staff" |
| Opening logged | `data_access_log` | the same (reason "licence review by sales, booking ...") |

For one call the Sales assistant acts as customer service through the setting 0151 introduced (`app.field_as_cs`, named for the
user, cleared at once) and `app.review_role` marks the call so `app.log_booking_event` (wrapped in 0162) adds the role.

## 3. The database

- `app.sales_licence_can`, `app.sales_licence_read` (the review as customer service reads it, `coverage` null and `licence_only`
  true, no proof of coverage among the uploads), `app.sales_licence_decide`, `app.sales_licences` (the queue list).
- The office's calls answer a Sales assistant with the licence only, by wrapping the existing functions (`*_pre0169`):
  `doc_review_read`, `doc_review_upload`, `doc_review_approve_all` (the licence images only; the coverage and the Protection Plan
  are not touched), `va_read verification`, `va_do verify_upload`. For everyone else they behave as before. New call:
  `va_read licences_waiting` (Sales only).
- All new functions are for `service_role` only. No public function changed: `web/src/lib/db/types.ts` is unchanged.

## 4. The website

- `web/src/app/va/page.tsx` (Licences to check), `web/src/app/va/bookings/[number]/page.tsx` (the Renter licence card),
  `web/src/app/va/verify/[number]/page.tsx` (open to Sales, no coverage for them).
- `web/src/features/admin/DocumentReview.tsx`: for a licence-only review it names the identity only and drops the coverage check.

## 5. Tests

- `supabase/tests/99_sales_licence_review.sql`: the rule; the queue list; the read (licence only, logged, refused for fleet and
  for a cancelled booking); the proof of coverage and the Protection Plan still refused (office and assistant calls); Approve all
  leaves the proof waiting; reject needs a reason, the status, the failed identity, the renter told, the history with the role;
  approve all (statuses, `reviewed_by`, driver verified, history lines with the role, gone from the queue, nothing done twice); no
  rights left over; customer service, fleet, field staff and Admin unchanged; privileges.
- `web/tests/e2e/sales-licence-review.spec.ts` (375 and 1440): Licences to check on the queue; the booking card and pop-up (no
  coverage), reject the front with a reason (status, reviewer, history role, renter told); `/va/verify` without coverage and
  Approve all (three approved by Sales, driver verified, three history lines with the role); gone from the queue; axe.

## Guides

- `va/sales`: Check the renter's licence.
- `admin/requests-offers-and-bookings`: Sales review the licence images too; the history says the role, sales.
