# 0029: the owner portal, owner agreements and owner invoice payments

Migration `supabase/migrations/0029_owner_portal.sql`, tests `supabase/tests/16_owner_portal.sql`. Written with the owner
onboarding wizard (`/list-your-car/apply`), the owner portal (`/owner`) and the first admin screens (`/admin`) of the web
app. No table is added and no earlier function changes. Function bodies are checked when called
(`set local check_function_bodies = off`), because some refer to functions defined further down.

## Changed

| Object | Was | Now | Why |
| --- | --- | --- | --- |
| `payments.method` check | card, pre-authorized debit, e-Transfer, bank transfer | adds `cheque` | An Admin records a cheque as an offline payment |
| `owner_invoices.payment_method` check | pre-authorized debit, card, e-Transfer | adds `bank_transfer`, `cheque` | The method an invoice was actually paid by is stored on it |

## Added (app functions; each wrapped in `public` for the server only)

| Function | Does |
| --- | --- |
| `owner_program_facts`, `onboarding_options_json` | The grid, Install Fee, HST and method estimates; the methods open to one vehicle (0022's `onboarding_options`) for a visitor's wizard |
| `vin_lookup`, `record_vin_decode` | A VIN cleaned and checked, "already with CarmaCars" without any detail, the newest decode on file; a decoder's answer stored as the listing worker stores it, so 0022's `add_owner_vehicle` fills empty fields from it |
| `send_link_email` | A draft's resume link, an invitation or a sign-in link, queued as the catalogue's `account_sign_in_link` to the address given |
| `owner_portal_home`, `owner_portal_invoices`, `owner_portal_invoice`, `owner_invoice_view`, `owner_portal_statement`, `statement_line_json`, `owner_portal_document`, `owner_portal_forms`, `owner_portal_bookings_json`, `owner_save_profile` | The owner's reads, all through 0022's `portal_owner_id` (the caller must be an active owner): vehicles and checklists, invoices with "pending" and "payable", one invoice with lines and payments, an approved statement with every line and the booking or invoice behind it, a document's storage key only when 0022's `owner_portal_documents` lists it, the pre-filled government form data sheets, bookings (0022's rule on renter details), contact changes (never the legal name or corporation) |
| `owner_signing_needed`, `owner_agreement_facts`, `owner_open_agreements`, `owner_sign_agreements`, `attach_owner_signed_copy` | Built-in signing for the Enrollment Agreement (with Schedule A), the Title-Holding and Lease Agreement and Additional Vehicle Schedules, like 0019's rental agreement: the server renders and stores the PDF, the database opens a signature request on its SHA-256, the owner signs once (drawn or typed, three initialled confirmations), CarmaCars countersigns automatically in the name of `program_settings.signing_officer_name`, schedules are signed, and each vehicle moves `terms_set` to `documents_sent` (on opening) and to `documents_signed` (on signature), then to `upfront_paid` when its upfront invoice is already paid |
| `owner_invoice_payment_facts`, `owner_invoice_apply_payment`, `record_owner_invoice_payment` | Paying an owner invoice through the processor: a pending pre-authorized debit, then succeeded or failed, idempotent on the processor's payment id (the webhook also claims each event with 0019's `webhook_event_claim`). The balance paid marks the invoice `paid` (0007's triggers fund the prepaid months, 0023's sends `owner_payment_received`); an upfront invoice stamps `upfront_paid_at` and moves a signed vehicle to `upfront_paid`; `save_method` records the card or the debit authorization (with its mandate) through 0022's `record_owner_payment_method` for the monthly debit; a returned debit leaves the invoice payable and tells Finance (`staff_owner_invoice_failed`). Money that arrives on a settled invoice is recorded and given to an Admin task (`owner_payment_unapplied`) |
| `record_owner_offline_payment` | An Admin records an e-Transfer, cheque or bank transfer with its reference and date; audited in `audit_log` (`record_offline_payment`, method, reference, amount, note); the same reference again is a replay |
| `admin_gate`, `assert_admin`, `admin_owner_applications`, `admin_owner_detail`, `admin_owner_invoices`, `admin_set_vehicle_terms`, `admin_approve_vehicle_terms`, `admin_issue_upfront_invoices` | The admin screens: Admin only. Terms go through 0022's `set_vehicle_terms` (the grid by default; off the grid is the Admin's decision) and then pre-fill the method's government forms; upfront invoices through 0007's `issue_upfront_invoice` for every vehicle whose terms are set |

Every function above is revoked from public, anon and authenticated and granted to service_role.

## Decisions to confirm

1. **Upfront invoice before signing.** 0022's `issue_upfront_invoices` issues on `documents_signed`. The owner asked to bill
   first and last month's Insurance Fee and the Install Fee now, so `admin_issue_upfront_invoices` lets an Admin issue it once
   terms are set (`terms_set`, `documents_sent` or `documents_signed`). A vehicle paid before signing keeps `upfront_paid_at`
   and moves to `upfront_paid` when it is signed.
2. **A failed or pending owner payment does not change the invoice status.** The `processing` and `failed` statuses (and the
   $50 Late Fee they add) stay for the monthly debit run on the 15th. A pre-authorized debit the owner starts from the pay
   page is a `pending` payment; while one is pending the invoice cannot be paid again.
3. **Documents signed on screen move the vehicle to `documents_signed`.** Forms C and D (on paper, witnessed) and Forms A
   and B are not part of the on-screen packet yet; the checklist still lists them for staff.
4. **CarmaCars countersigns automatically** in the signing officer's name from settings, as the rental agreement is
   countersigned in the staff member's name. The blueprint's on-screen admin countersignature is not built.
5. **An owner's processor customer id** is kept in `payment_processor_details.raw` of their payments (no new column).

## Not done

- The monthly debit on the 15th itself (charging the saved method off-session) and the debit-results job.
- Form C and D upload and review, Forms A and B on screen, the ownership permit upload.
