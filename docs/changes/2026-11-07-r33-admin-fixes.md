# Release 33, part L: admin fixes (migrations 0780, 0781)

Branch `r33-l`. SCHEMA_MARKER 0781 (raise to the highest merged migration when merging).

## What changed

1. **Identity review: the count is what is approved.** "Approve all (4)" showed with three items listed, and after it ran said (1).
   Cause: the button counted the waiting images the read lists, while Approve all approved every waiting image of the booking in
   the database, including one whose file was purged (cannot be looked at, never listed) and one tied to no driver of the booking
   (counted but not listed under any driver). One rule now, `app.doc_review_pending` (waiting, file not purged, optional kinds), is
   used by the Admin/customer service, Sales and Field "Approve all". An image not tied to a driver is listed under **Other
   documents** (admin pop-up, staff `/staff/verify/[number]`, field licence review). Unit test `doc-split.test.ts`; DB suite
   `99_r33l_admin_fixes.sql`.
2. **Duplicate expired requests and offers.** `bookings.superseded_by`: an expired booking of the same renter and car whose dates
   overlap a newer booking of theirs (not cancelled, declined or no-show) is linked to the newest and no longer listed in Requests
   (`app.admin_requests`, used by Admin and staff). Made by a trigger when a booking is made or expires, and once for the existing
   ones (backfill). The booking keeps its number and history; each link is in the audit log (`booking_duplicate_archived`). 0741's
   expired-offer-to-lead job skips linked ones (the newer booking speaks for the renter).
3. **Already paid outside the platform.** On the owner invoice page (Actions): choose e-Transfer, cash, cheque, bank transfer or
   card outside the platform, the date, reference and amount (empty: the balance). A draft is issued without the invoice email, the
   payment is recorded, and no receipt email is sent unless "Email the owner a receipt" is ticked (default off).
   `record_manual_payment` takes `receipt` false (or the setting `app.paid_receipt = off`). The First and last month "Already paid"
   paths (the Approve step and Admin > Today > Record what they paid) emailed the receipt; they now send none unless asked
   (`payment.receipt` true, or the new tickbox in the Today dialog). Test `46_owner_terms_invoices.sql` updated for that.
4. **Drive API key.** `audit_compact` writes `[hidden]` for `google_drive_api_key` (so a new dated settings row never logs it), the
   entries already in `audit_log` were masked once, `admin_settings`, `admin_save` and `admin_enrich` never return it, and the
   Settings page shows only "ends 1234" with a field for a new key (empty and Save removes it). The server still reads the whole key.

## Guides

Changed chapters (published by `supabase/seed/0781_gen_guides.mjs` into `0781_r33l_admin_fixes_guides.sql`):
`admin/requests-offers-and-bookings`, `admin/owner-money`, `admin/owners-and-onboarding`, `admin/fleet-and-listings`.
