# 04. Owner portal and onboarding

Owner: workstream E. Routes under `src/app/owner/`; features in `src/features/owners/`. Every route needs the `owner` role and reads only the owner's own rows (`app.is_my_owner()`, `app.owns_vehicle()`, the views `owner_bookings` and `owner_claims`). Owners change nothing directly in the database: every write is a server action (`docs/permissions.md` section 1).

Business rules: `docs/source/v2_enrollment.md`, `docs/source/v2_title_holding.md`, `docs/source/owner_billing_spec.md`, operating procedures 12 to 16.

## 1. What an owner can and cannot see

| Can see | Cannot see |
| --- | --- |
| Their vehicles, schedules, fees, Revenue Share, rate cards | Any other owner's data |
| Bookings on their vehicles: dates, status, rental charge, their split | A renter's identification, licence, address, email or card, ever |
| A renter's name and mobile on a Self-Managed rental or an Owner Booking only | Renter contact details on a managed rental |
| Live location of their vehicles, always | Lock, alarm and shut-off controls during a rental CarmaCars manages (shown as blocked) |
| Their invoices, approved statements, payouts, deductions with receipts | Draft statements; Condition Reports and incidents of a renter's booking |
| Claim status on their vehicles | Claim money, except on a total loss or a shareholder vehicle |

## 2. `/owner` Home

| Item | Detail |
| --- | --- |
| P layout | Next-step card (onboarding step, a failed payment, a statement ready, a document to sign); then cards: "This month so far" (rentals ended, estimated Owner Revenue, labelled "estimate until the statement is approved"), Vehicles (status chips), Next payout date, Fees due on the 15th |
| D layout | Two columns: next step and vehicles left; money and notices right |
| Empty | A new owner with no vehicle sees only the onboarding card: "Add your first vehicle" |
| Data | `vehicles`, `vehicle_onboardings`, `owner_bookings`, `owner_invoices`, `owner_statements` (approved only), `payouts` |

## 3. Onboarding wizard: one owner, many vehicles

Routes: `/list-your-car/apply` (public, steps 1 and 2), `/owner/onboarding` (list of vehicles in progress), `/owner/onboarding/[vehicleId]/[step]`, `/owner/vehicles/new` (adds a vehicle to an existing owner: starts at step 2 with step 1 already answered).

Design rules: owner facts are asked once and reused for every vehicle and every document. A second vehicle asks only vehicle questions. Every step autosaves and can be resumed on another device (`08-forms.md` section 3). A VA or admin can fill any step for the owner from `/admin/onboarding` using the same forms (the record shows who entered what). Field staff can start a vehicle at the roadside from `/field/list-a-car` (VIN and photos) and the owner completes the rest.

### Step 1. About you (once per owner)

| Label | Type | Validation | Default | Stored |
| --- | --- | --- | --- | --- |
| I am enrolling as | radio: an individual / a corporation | Required | none | `owners.owner_type` |
| Full legal name | text | Required | Account name | `owners.legal_name` |
| Corporation name | text | Required for a corporation | | `owners.corporation_name` |
| Corporation number | text | Required for a corporation | | `owners.corporation_number` |
| Registrant identification number (RIN) | text | Optional; asked later when the Lease method needs it | | `owners.registrant_identification_number` |
| Signing officer name and title | text | Required for a corporation | | `owner_agreements.corporate_signatory_name`, `corporate_signatory_title` |
| Address | address lookup, manual fallback | Required; Canada | | `owners.address_line1, address_line2, city, province, postal_code, country` |
| Email | email | Required | Account email | `owners.email` |
| Phone | tel | Required | | `owners.phone` |
| HST number | text | Optional; format `^\d{9}RT\d{4}$` | | `owners.hst_number` |
| Driver's licence number | text | Required for an individual (it goes on the registry forms) | | `owners.licence_number` **[new]** |
| Date of birth | date | Required for an individual (registry forms) | | `owners.date_of_birth` **[new]** |
| Who referred you | text | Optional; checked against referral codes | `/r/` cookie | `owners.recruited_by` when it matches a staff code |

### Step 2. The vehicle (once per vehicle)

| Label | Type | Validation | Default | Stored |
| --- | --- | --- | --- | --- |
| VIN | text with camera scan | Required; 17 characters; check digit; not already in `vehicles` (unique on upper VIN). On entry the VIN is decoded (`09-listing-pipeline.md` section 3) and the next six fields fill in | | `vehicles.vin` |
| Year, make, model, trim | text, select | Required (trim optional); pre-filled from the decode, editable | Decode | `vehicles.year, make, model, trim` |
| Colour | select with "other" | Required | | `vehicles.colour` |
| Fuel | select | Required | Decode | `vehicles.fuel` |
| Plate | text | Required; Ontario format, upper case | | `vehicles.plate` |
| Odometer (km) | number | Required; 0 to 999,999 | | `vehicles.odometer_km`, `vehicle_schedules.odometer_km` |
| The vehicle is held by | radio: me personally / my corporation | Required; "my corporation" needs the corporation fields from step 1 | From step 1 | `vehicle_schedules.held_by` |
| It is | radio: owned outright / financed / leased | Required | | `vehicle_schedules.title_status` |
| Lender or lessor name | text | Required unless owned outright | | `finance_party_name` |
| Loan or lease account | text | Optional | | `finance_party_account` |
| Has it ever been branded rebuilt, salvage or irreparable | radio: no / yes | Required. "Yes" ends the wizard for this vehicle: `vehicle_onboardings.status = 'declined'`, `vehicles.title_brand_clear = false`, with a plain explanation (Enrollment Agreement 3.1) | | `vehicles.title_brand_clear` |
| Any open recall, or structural, flood or fire damage | radio and text | Required; "yes" needs details and flags the record for an admin | | `vehicle_onboardings.disclosures` **[new jsonb]** |
| Current insurer | text | Required | | `vehicle_onboardings.current_insurer` |
| How do you want it rented | radio with a three-column comparison: Managed / Self-Managed / Turo-Only | Required | Managed | `vehicle_schedules.management_mode` (proposed; an admin sets the final value) |
| Ownership permit (photo of both sides) | photo capture | Required before step 5 | | `documents (kind = 'ownership_permit')` |

"Add another vehicle" repeats step 2 only.

### Step 3. Your situation, method and estimate

The wizard derives the situation from step 2 and shows only the methods open to it. This is a pure function, `onboardingOptions(held_by, title_status, management_mode)` in `src/features/owners/situations.ts`, mirrored by the check constraints on `vehicle_schedules`.

| Situation | Held by | Status | Methods offered | Estimate the owner pays third parties directly | Government forms pre-filled | Extra CarmaCars forms |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Corporation | Owned outright or financed | Lease, existing corporation (recommended); Transfer | About $50, no tax (Lease) | SR-LV-006, SR-LV-012 | Form B; Form D; Form C if financed |
| S2 | Individual | Owned outright or financed | Lease through a new Owner Corporation | About $570, no tax | SR-LV-006, SR-LV-012, ON00453, 013-0169, 013-1155 | Form B; Form D; Form C if financed |
| S3 | Individual | Owned outright or financed | Co-Registrant | About $250 plus any tax | SR-LV-006, SR-LV-012 | Form A; Form D; Form C if financed |
| S4 | Individual or corporation | Owned outright | Transfer, with the optional Owner's Lien | About $250, or $260 with the lien, plus any tax | The sign-back on the ownership permit (no form to pre-fill; the checklist shows where to sign) | Form A; Form D; lien election |
| S5 | Individual or corporation | Financed | Transfer | About $250 plus any tax | The sign-back on the permit | Form A; Form D; Form C and the lender's written permission |
| S6 | Individual or corporation | Leased | Transfer (the only method) | About $250 plus any tax | SR-LV-006, SR-LV-012 | Form A; Form D; Form C and the lessor's written permission |
| Turo-Only (no registry) | Any | Any | None | $0 | None | Enrollment Agreement and Vehicle Schedule only; insurance proof; insurer permits Turo |

An individual who owns outright or finances sees S2, S3 and S4 or S5 as choices with a side-by-side comparison (cost, what changes at the registry, who stays on the ownership). The estimates and form lists are read from `onboarding_method_info`, never hard-coded.

| Label | Type | Validation | Stored |
| --- | --- | --- | --- |
| Method | radio (only the open ones) | Required | `vehicle_schedules.onboarding_method`, `vehicles.onboarding_method` |
| Owner's Lien | radio: elect / decline | Shown only for S4 | `vehicle_schedules.owners_lien` |
| Lender or lessor permission | radio: I have it (upload) / I do not have it yet / I will proceed without it | Shown for financed or leased. "Proceed without" shows the Form C warning in full before continuing | `vehicle_schedules.finance_permission`, `finance_permission_document_id` |
| New corporation details (S2) | Proposed corporation name or "numbered", director name and address | Required for S2 when the corporation does not exist yet | `vehicle_onboardings.new_corporation` **[new jsonb]**, later `owners.corporation_name`, `corporation_number`, `is_new_owner_corporation = true` |

The step ends with an estimate card: each third-party item and amount from `onboarding_method_info.typical_items`, the total, "plus any tax, calculated on appraised value at the registry counter", "Safety repairs are extra", and in bold: "You pay these directly to ServiceOntario, the inspection station and the appraiser. CarmaCars does not collect them. Amounts are estimates and may vary." CarmaCars' own charges are shown separately: the $100 Install Fee and first and last month's Insurance Fee, once the fees are set. The estimate is stored in `vehicle_schedules.onboarding_estimate_cents` for information only.

Button "Submit for review": `submitOwnerIntake` (or `submitVehicleIntake` for an added vehicle). `vehicle_onboardings.status` stays `intake`; a `cs` task is created (procedure 12, reply in 1 business day); emits `owner_application_received`, `staff_owner_application_received`.

### Step 4. Terms (CarmaCars sets, the owner reviews)

Staff side (`/admin/onboarding`, admin only): Insurance Fee, Tracker Fee, Revenue Share (pre-filled from `owner_fee_grid` by the owner's vehicle count; 0 and locked for Self-Managed; all zero for Turo-Only except the share), Management Mode, special terms, "Broker pre-approved" date. Action `setVehicleTerms` creates the `vehicle_schedules` row (and the `owner_agreements` rows on the first vehicle), sets `vehicle_onboardings.status = 'terms_set'`, `terms_set_by`, `terms_set_at`, and then prepares the documents (step 5), which sends `owner_agreement_ready`: one email that presents the terms and links to the documents to sign.

Owner side: a plain summary of the numbers for this vehicle, the upfront amount (Install Fee, two months of Insurance Fee, HST), the monthly amount charged on the 15th, the payout rule, and three statements to read. Button "Continue to documents". An owner who disagrees uses "Ask a question" (message to CS) or "Withdraw this vehicle" (`withdrawVehicle` -> `withdrawn`).

### Step 5. Documents: sign on screen, or print and witness

`prepareOwnerDocuments` (run when terms are set) builds every document for this vehicle from data already entered, through `render-document`, and sets `status = 'documents_sent'`.

| Document | When | Signed how | Records |
| --- | --- | --- | --- |
| Enrollment Agreement with the Vehicle Schedule entry | First vehicle | On screen. Three initialled confirmations, each its own tap: own insurance until confirmed (3.3); fees due every month, no income promised (2.3, 4.3); tracker records location, no pay for downtime (5, 10, 15). Then signature. CarmaCars countersigns (an admin, on screen) | `owner_agreements (kind = 'enrollment')`, `confirm_own_insurance_at`, `confirm_fees_no_income_at`, `confirm_tracker_downtime_at`, `signature_requests`, `signature_records` |
| Additional Vehicle Schedule | Each later vehicle | On screen, both sides | `vehicle_schedules (is_additional = true)`, `signed_at` |
| Title-Holding and Lease Agreement with Schedule 1 | First non-Turo vehicle | On screen. An individual and their Owner Corporation both sign | `owner_agreements (kind = 'title_holding')` |
| Form A, trust declaration | First Co-Registrant or Transfer vehicle (covers later ones) | On screen | `owner_agreement_forms (form_code = 'A')` |
| Form B, lease summary | First Lease vehicle | On screen | `form_code = 'B'` |
| Form C, lender or lessor permission acknowledgment | Each financed or leased vehicle | **On paper, with a witness.** The pre-filled PDF is downloaded, the three acknowledgments are initialled by hand, signed and witnessed, then photographed or scanned and uploaded. The app asks for the witness's name and records the three acknowledgment times as the upload time | `form_code = 'C'`, `witness_1_name`, `finance_permission`, `ack_read_warning_at`, `ack_no_advice_at`, `ack_bears_consequences_at`, `document_id` |
| Form D, limited power of attorney | Each owner (covers all vehicles) | **On paper, two witnesses for Part 1.** Same download, sign, upload path. Part 2 is signed by CarmaCars with a witness | `form_code = 'D1'`, `'D2'`, `witness_1_name`, `witness_2_name` |
| Pre-authorized debit agreement | Each owner | On screen in step 6 | `owner_payment_methods.authorization_document_id` |

Screen: a checklist of the documents with a status each (To sign, Signed, To print, Uploaded, Checked by CarmaCars). On-screen documents open in `SignDocument` one after another so the owner signs the set in one sitting with one drawn signature reused after an explicit "Use the same signature" confirmation per document. Paper documents have "Download pre-filled PDF" and "Upload signed copy" (camera capture with edge detection and multi-page support, `08-forms.md` section 6). CS checks each upload (`checkOwnerDocument`: accept or send back with a reason). When all are signed and checked: `status = 'documents_signed'`; emits `owner_agreement_signed`.

### Step 6. Payment set-up

| Block | Fields | Action |
| --- | --- | --- |
| Upfront invoice (not for Turo-Only or shareholder-owned vehicles) | Shows the invoice from `app.issue_upfront_invoice()`: Install Fee, first month's and last month's Insurance Fee, HST | "Pay by card" (`payUpfrontInvoice`: Stripe PaymentIntent, `payments (purpose = 'owner_upfront')`; the webhook marks the invoice `paid`, creates `vehicle_prepaids`, sets `vehicle_onboardings.upfront_paid_at` and `status = 'upfront_paid'`, which sends `owner_onboarding_steps` with the steps and pre-filled forms for the vehicle's method). "I will pay by e-Transfer" shows instructions; Finance records it (`recordOwnerPayment`). Emits `owner_payment_received` |
| Monthly debit | Bank account for pre-authorized debit: collected in Stripe's secure bank form with the debit agreement in CarmaCars' wording shown above it (amount: variable, the vehicle's fees plus HST; date: the 15th; retry on the 18th with the $50 Late Fee) | `createDebitMandate` -> Stripe SetupIntent for Canadian pre-authorized debit; on success `owner_payment_methods (kind = 'pre_authorized_debit', status = 'active', brand_or_bank, last4, authorized_at)` and its secrets row |
| Payouts | Payout method (bank transfer or e-Transfer); account holder, institution number (3 digits), transit number (5 digits), account number (7 to 12 digits), or e-Transfer email | `submitPayoutAccount`: encrypts the account number and inserts `owner_payout_accounts` with `verified_at` null and not current. An admin verifies and makes it current (`03-admin.md` section 9.1). The owner sees "Being verified" |

### Step 7. Registry visit

| Element | Detail |
| --- | --- |
| Pre-filled government forms | For the vehicle's situation, the forms in the table above are generated from data already entered and offered as "Download and print" (`generateRegistryForms` -> `render-document`; `documents (kind = 'registry_form')`). The mapping approach is in `08-forms.md` section 9. Each PDF carries a cover page listing what to sign, where, and what to bring |
| What to bring | Driver's licence, original ownership permit, proof of current insurance, lender or lessor permission if any, safety certificate, appraisal where the method needs one, and for a corporation proof of signing authority (Title Agreement 8.1) |
| Safety certificate | Upload plus inspection date. The app sets `safety_certificate_expires_on = date + 36 days` and shows the days left; the registry visit cannot be booked after it. A reminder goes out 7 days before expiry (`owner_document_due`, once the writer extends that template to the safety certificate; `staff_expiry_watch` already covers it for Fleet) |
| Appraisal | Upload plus date (Co-Registrant and Transfer) |
| Booking the visit | Fleet proposes a date, time and ServiceOntario location (`scheduleRegistryVisit`: `registry_visit_at`, `registry_place`, `registry_attended_by`; status `registry_booked`). The owner confirms or asks for another time. Emits `owner_registry_visit` (T21) with the list above and "You pay the registry fees and tax at the counter; amounts may vary" |
| After the visit | Fleet uploads the new permit and completes the Title Schedule (`recordRegistration`: `vehicle_registrations (registered_as, registered_on, plate, plate_renewal_month, permit_document_id, lease_recorded_on)`, `ppsa_registration_number` if a lien was registered; status `registered`) |

### Step 8. Tracker, fleet policy, enrolled

| Stage | Who | Action | Status |
| --- | --- | --- | --- |
| Tracker install | Field | Field job `tracker_install`; device bound to the vehicle; location, lock, alarm and shut-off tested while parked (`06-field.md` section 7) | `tracker_installed` |
| Owner access | Fleet | `grantOwnerTrackerAccess` sets `owner_access_granted_at` | |
| Fleet policy | Admin | Uploads the insurer's confirmation (`insurer_confirmation_document_id`), sets `on_fleet_policy_at`, `vehicles.on_fleet_policy`, `fleet_policy_added_on` | `on_fleet_policy` |
| Written confirmation | Admin | `confirmEnrollment`: sends `owner_vehicle_enrolled` (T22), sets `enrolled_confirmed_at`; the database sets the Enrollment Date and opens the fee terms (`app.vehicle_onboarding_after_status()`) | `enrolled`; vehicle `ready_to_list` |
| Listing | Field, Fleet, CS | The listing pipeline (`09-listing-pipeline.md`) | vehicle `available` |

The owner's screen for step 8 is a progress list with dates and the line, until T22: "Keep your own insurance on this vehicle until we confirm in writing."

**Turo-Only path.** Steps 1, 2, 3 (method None), 4, 5 (Enrollment Agreement and schedule only), then uploads: ownership permit, proof of comprehensive insurance with expiry (`vehicle_onboardings.owner_insurance_expires_on`, `turo_listings.owner_insurance_expires_on`), and a ticked confirmation that the insurer permits Turo rental (`insurer_permits_turo_confirmed_at`). `documents_signed -> enrolled`. No payment set-up except the payout account.

**Shareholder-owned path.** No upfront invoice and no debit; `documents_signed -> registry_booked`.

### Wizard states

| State | Behaviour |
| --- | --- |
| Resume | `/owner/onboarding` lists each vehicle with a progress bar and "Continue" at the first incomplete step |
| Waiting on CarmaCars | The step shows who has it and since when ("With our team since Oct 9. We reply within 1 business day.") |
| Sent back | A document or upload returned by staff shows the reason at the top of its step |
| Declined or withdrawn | The vehicle card shows the status and reason; the owner's other vehicles carry on |
| Duplicate VIN | "This vehicle is already with CarmaCars. If it is yours, contact us." No detail about the existing record is shown |

## 4. Staff view of onboarding

`/admin/onboarding/[vehicleId]` (admin, CS, Fleet with their column limits) shows the same steps as a checklist with owner-entered data, the documents, and the staff actions named in section 3 (`setVehicleTerms`, `checkOwnerDocument`, `recordOwnerPayment`, `scheduleRegistryVisit`, `recordRegistration`, `confirmEnrollment`, `declineVehicle` with a reason). Each status change is one allowed transition in `status_transitions (vehicle_onboarding)`; the database refuses a skipped step. Escalations (no lender permission, insurer declines, fee off the grid, undisclosed damage or lien) raise an admin task.

## 5. Vehicles

### `/owner/vehicles`

Cards: photo, year make model, plate, status, mode, next booking, this month's rentals. "Add a vehicle" -> `/owner/vehicles/new`.

### `/owner/vehicles/[id]`

| Tab | Content | Actions |
| --- | --- | --- |
| Overview | Status, mode, Enrollment Date, fees and Revenue Share from the current schedule, prepaid last month held, arrears flag with the amount and "Pay now" | `payOwnerInvoice` |
| Calendar | The vehicle calendar (`VehicleCalendar`) with: bookings (managed: dates and status only; Self-Managed and Owner Bookings: renter name), blocks, exit date. No renter details on managed rentals | "Block dates" (`requestOwnerBlock`: from, to, note; creates `vehicle_calendar_blocks (reason = 'owner_unavailable')` if no blocking booking overlaps; otherwise refused with the dates listed). "Book it for myself" -> Owner Booking |
| Bookings | From `owner_bookings`: number, dates, status, rental charge, mileage overage, kickback, Owner Revenue, company share, owner payout, payout month | Export CSV |
| Listing | The public listing as published, with "Suggest an edit" (message to CS). On a Self-Managed vehicle: the rates form (section 6) |
| Tracker | Map with the live location (always). Buttons Lock, Unlock, Alarm, Shut-off. During a rental CarmaCars manages they are disabled with the text "Controls are blocked during a rental we manage. Live location stays on." (`app.owner_controls_blocked()`) | `requestOwnerTrackerCommand` -> `tracker_commands (actor_type = 'owner', reason_code = 'owner_protecting_vehicle', reason typed)`; the database stores it as `blocked` when a block is active. Shut-off also needs a stationary, ignition-off reading under 5 minutes old |
| Documents | Schedules, agreements, forms, permit, insurer confirmation, baseline and exit Condition Reports | Open, download |
| Leaving | Section 9 | |

## 6. Bookings by the owner

### `/owner/bookings/new`

| Type | Who | Fields | Flow |
| --- | --- | --- | --- |
| Owner Booking (drive my own car) | Any owner | Vehicle, pickup and return date-times (30 days maximum), pickup and return place | `createOwnerBooking` -> booking `booking_type = 'owner'`, no price, no deposit, no coverage. A renter's confirmed booking has priority: refused on overlap. The owner signs the agreement with Part 5 on screen; `tentative -> confirmed` on signature. Licence validity is checked by CS (procedure 15). Handover and return use the normal checklists |
| Self-Managed rental (my renter) | Owner of a Self-Managed vehicle that is not in arrears | Vehicle, dates, renter's name, email, mobile, the price is from the owner's rate card | `createSelfManagedRequest` -> a `requested` booking with `source = 'owner'`. CarmaCars staff review and send the offer; the renter approves, signs and pays through CarmaCars' checkout. The car is enabled for the booked period only (Fleet, procedure 3 step 7). Refused while `vehicles.in_arrears` or `bookings_enabled = false` with the reason shown |

### Rates on a Self-Managed vehicle

The rates form of `03-admin.md` section 8.3 with the same validation, action `saveOwnerRateCard` (`set_by_owner = true`). Managed vehicles show rates read-only: "CarmaCars sets rates on managed vehicles."

## 7. Money

| Route | Content | Actions |
| --- | --- | --- |
| `/owner/invoices` | Per vehicle and month: invoice number, period, Insurance Fee, Tracker Fee, credits, HST, Late Fee, total, status (in plain words: Scheduled for the 15th, Processing, Paid, Failed and retrying on the 18th, In arrears, Deducted from payout), PDF | "Pay now" on a failed or in-arrears invoice (card); "Update bank account" |
| `/owner/statements` | Approved statements by month: payout, status, PDF | Open |
| `/owner/statements/[id]` | The statement exactly as laid out in `11-statements-and-reports.md` section 2, on screen and as PDF | Download PDF, download CSV of lines, "Question this statement" (message to Finance; creates a `finance` task escalated to an admin) |
| `/owner/payouts` | Date, kind, amount, method, reference, status | none |
| `/owner/claims` | From `owner_claims`: vehicle, claim number, status in plain words, opened date; for a total loss the balance and due date. The page states: "We manage the claim and repair at an approved shop. Please do not contact the insurer. Fees continue; downtime is not paid." | "Report an accident or damage" (within 24 hours): form with vehicle, when, where, what happened, photos; `reportOwnerIncident` creates an `incidents` row and an urgent admin task |
| `/owner/referrals` | The owner's referral link (`/r/[code]`) and QR code; kickbacks: booking, rental charge, amount, status (pending, earned, paid, reversed). Rules shown: 20% of the rental charge on a new renter's first rental; none on the owner's own vehicles, renewals or Self-Managed rentals | Copy link, share |
| `/owner/banking` | Debit account (bank, last four, status) and payout account (last four, verified or being verified) | Replace debit account (`createDebitMandate`); submit new payout details (verified by an admin before use) |

## 8. Profile and documents

`/owner/profile`: contact details (`saveOwnerProfile`; a legal name or corporation change is a request to CS because it affects agreements), HST number, password, two-step sign-in, notification preferences (statement and billing emails are always sent; marketing is opt-in). `/owner/documents`: every owner-level and vehicle-level document the policies allow.

## 9. Leaving: exit notice and buyout offer

| Element | Detail |
| --- | --- |
| Exit notice | `/owner/vehicles/[id]` Leaving tab. Shows: 30 days' notice; the Exit Date preview (end of notice or, if later, the end of a rental in progress); who pays the transfer-back fees (owner under 6 months on the Fleet Policy, CarmaCars after; computed by `calc_retransfer_payer()`); the final month's fee treatment; "Your other vehicles are not affected" |
| Fields | Reason (optional), "Return the registration to" (me, or a named person with name and address), confirmation checkbox |
| Action | `giveExitNotice` -> `vehicle_exits (initiated_by = 'owner', notice_received_at = now(), notice_ends_on, exit_date)`, vehicle `exit_notice`, an `exit` calendar block from the Exit Date, a `fleet` task (procedure 16), fleet minimum check. Emits `owner_exit_notice_received` (with the confirmed Exit Date) and `staff_exit_notice_received` |
| Withdraw notice | Allowed until the Exit Date if no step has been taken (`withdrawExitNotice`) |
| Before the Exit Date | The owner uploads proof of their own insurance from the Exit Date (`owner_insurance_document_id`) |
| Form E | Signed by both on screen at hand-back (tracker removed, lien discharged, vehicle, keys and permit returned, odometer) |
| Buyout offer | "Offer to sell this vehicle to CarmaCars": states that CarmaCars may decline, and the price rule (Canadian Black Book average trade-in on the offer date plus 10%, plus any tax). `offerBuyout` -> `vehicle_buyouts (offered_on, offer_document_id)`; an admin decides |

## 10. Edge cases

| Case | Handling |
| --- | --- |
| Owner is also a renter | One login, two roles; "Switch area" in the menu. An Owner Booking uses the owner's renter record (`renters.is_owner_account`) |
| Two people own one car | One `owners` row is the contracting owner; the co-owner is named in the legal name field as the agreement requires ("each person named as Owner, jointly and severally") and signs on paper if needed. Flagged to an admin |
| Corporation created during onboarding (S2) | The owner returns to step 3 to enter the corporation number and RIN once issued; documents are regenerated; anything already signed that names the corporation is re-signed |
| Safety certificate expires before the visit | The visit is unbooked, the owner is told a new certificate is needed at their cost (Title Agreement 8.2) |
| Insurer declines after registration | Admin runs `declineAfterRegistration`: immediate Re-Transfer at CarmaCars' cost unless non-disclosure (`vehicle_exits.initiated_by = 'insurer_declined'`) |
| Debit fails on the 15th | Invoice `failed`, $50 Late Fee, `owner_payment_failed` (T25); portal shows "Pay now" |
| Vehicle in arrears | Self-Managed: new bookings are blocked and the portal says why |
| Statement not yet approved | The owner sees "Your [month] statement is being prepared. Payouts are made on the 10th." |

## 11. Database additions needed

| Addition | Purpose |
| --- | --- |
| `owners.licence_number`, `owners.date_of_birth` | Registry forms for individuals. Sensitive: owner and admin read only |
| `vehicle_onboardings.disclosures jsonb`, `new_corporation jsonb`, `safety_certificate_document_id`, `appraisal_document_id` | Steps 2, 3, 7 |
| `government_form_fills (id, vehicle_id, form_code, template_version, data jsonb, document_id, generated_by, generated_at)` | What was pre-filled, for regeneration and audit |
| Functions: `app.submit_owner_intake(p jsonb)`, `app.set_vehicle_terms(...)`, `app.give_exit_notice(p_vehicle uuid, p jsonb)` | One transaction each |
| Owner insert through server actions only; no new owner write policies | Consistent with permissions |
| `document_kind` values: `debit_agreement`, `rental_amendment`, `insurer_authorization`, `insurer_invoice`, `government_form_cover` | Clearer than `other` |
| `owner_payout_accounts.submitted_by`, `verified_by`, `verification_method` | Section 3 step 6 and `03-admin.md` section 9.1 |
