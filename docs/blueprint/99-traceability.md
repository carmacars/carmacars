# 99. Traceability, database additions and open questions

## 1. How to read this file

Section 2 maps each of the owner's twelve requirements, quoted, to the screens, tables, functions, jobs and emails that satisfy it, and to the tests that prove it. Section 3 is the consolidated list of everything the database still needs (the request list for the database engineer). Section 4 is the short list of questions only the owner can answer, each with a recommended default so that nobody waits. Section 5 lists source material this blueprint could not find and documents that are now out of date.

Names marked **[new]** do not exist in migrations 0001 to 0016.

## 2. Requirement traceability

| # | Owner's requirement (quoted) | Screens and routes | Tables | Functions | Jobs | Emails | Proved by |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | "A responsive website with a phone layout and a desktop layout. Not an iOS app." | Every route has a phone and a desktop layout: `00-overview.md` sections 4 to 6; the field portal is phone-first (`06-field.md` section 1) with a web manifest, no store app | none | none | none | Emails are single-column and readable on a phone (`emails/`) | `15` R1-1 to R1-4 |
| 2 | "Very visually appealing, photo-heavy, tasteful scroll effects, easy to use, secure. Colours red, black and white. The name is always "CarmaCars". No broken links. Must not read as AI-generated: no em dashes, no filler copy." | Design system and tokens from the prototype (`00` section 7); photo and scroll rules (`01` section 2); listing copy controls (`09` section 5.3); security (`13`) | `vehicle_photos`, `vehicle_listings`, `listing_redirects` **[new]** | `app.publish_listing()` **[new]** | Nightly link check | Email checker (`node emails/check.mjs`) | `15` R2-1 to R2-9; link checker (`15` section 3); copy lint (`15` section 4) |
| 3 | "Request to book, never instant book. No payment or card at request. Staff confirm, may contact the customer and adjust the booking, then send an offer; the renter approves, signs and pays; only then the booking goes live on the calendar." | `/cars/[slug]`, `/book/[slug]`, `/book/sent/[n]` (`01`, `02` sections 2 and 3); `/admin/requests`, `/admin/bookings/[id]` review, adjust, send (`03` sections 3 and 4); `/account/bookings/[id]/offer`, `/sign`, `/pay` (`02` sections 4 to 6) | `bookings` (statuses `requested`, `offered`, `pending_payment`, `confirmed`; `blocks_calendar`; `request_note`; `current_offer_version`; `offer_expires_at`), `booking_offers`, `booking_events`, `booking_drivers`, `booking_line_items`, `signature_requests`, `signature_records`, `consents`, `payments`, `payment_methods` | `app.request_booking()`, `app.adjust_booking()`, `app.reprice_booking()`, `app.send_offer()`, `app.approve_offer()`, `app.request_offer_change()`, `app.withdraw_offer()`, `app.decline_booking_request()`, `app.booking_before_write()` (confirmation needs signature, payment, saved card, free car), `app.vehicle_is_available()`; **[new]** `app.submit_booking_request()`, `app.quote_booking()`, `app.open_rental_agreement()`, `app.record_signature()`, `app.record_booking_payment()` | `carmacars-offers-expire`; `reminders` (offer reminder); `staff_request_waiting` check | `renter_request_received`, `renter_request_needs_info`, `renter_offer_ready`, `renter_offer_reminder`, `renter_offer_expired`, `renter_offer_withdrawn`, `renter_request_declined`, `renter_agreement_signed`, `renter_booking_confirmed`, `renter_payment_failed`; `staff_booking_request_new`, `staff_request_waiting`, `staff_change_request_received`, `staff_offer_approved_paid` | `15` R3-1 to R3-11; `supabase/tests/06_request_to_book.sql` |
| 4 | "A master calendar in the admin portal across all vehicles, and a calendar on every vehicle's page (public page shows unavailable dates; admin vehicle page shows everything)." | `/admin/calendar` (`03` section 5); `/admin/vehicles/[id]/calendar` and blocks (`03` section 6); public availability on `/cars/[slug]` (`01` section 4.3); `/owner/vehicles/[id]` Calendar (`04` section 5); VA calendars (`05`) | `calendar_entries` (view), `vehicle_calendar_blocks` (`removed_at`), `bookings`, `field_jobs`, `turo_trips` | `app.master_calendar()`, `app.public_vehicle_calendar()`, `app.vehicle_is_available()`, `app.adjust_booking()`; **[new]** `app.preview_booking_change()`, public wrappers | none | `renter_offer_ready` after a calendar move re-sends an offer | `15` R4-1 to R4-12 |
| 5 | "Bookings to insurance companies whose dates may not be correct yet: such a booking must be able to exist without blocking the car, with a switch staff can change." | Insurer fields and the calendar switch (`03` sections 4.2 and 7); `/admin/insurers`, `/admin/insurer-invoices`; calendar drawing of non-blocking bookings (`03` section 5.2); `/insurance-replacement` enquiry (`01` section 4.5) | `insurers`, `insurer_invoices`, `bookings` (`bill_to`, insurer columns, `dates_provisional`, `blocks_calendar` and its who, when, why), `booking_events` (`calendar_switch`) | `app.set_blocks_calendar()`, `app.booking_insurer_share()`, `app.adjust_booking()` (provisional dates), `app.draft_insurer_invoice()`, `app.record_insurer_payment()`; **[new]** guard that `on_rent` requires the switch on | **[new]** `insurer-provisional-watch` | **[to add]** `insurer_invoice`, `insurer_invoice_reminder` | `15` R5-1 to R5-7 |
| 6 | "Form filling must be smooth and efficient, especially the forms for car owners registering new cars (one owner, many vehicles, six ownership situations with different ServiceOntario forms: SR-LV-006, SR-LV-012, ON00453, 013-0169, 013-1155; the platform pre-fills the government PDFs from data entered once; registry costs are estimates the owner pays directly) and the rental agreement (pre-filled from the booking, signed on screen on a phone)." | The form system (`08`); owner wizard, six situations, documents, registry step (`04` sections 3 and 4); `/account/bookings/[id]/sign` (`02` section 5); signature pad (`08` section 8); pre-filled PDFs (`08` section 9) | `owners`, `vehicles`, `vehicle_schedules`, `vehicle_onboardings`, `onboarding_method_info`, `owner_agreements`, `owner_agreement_forms`, `vehicle_registrations`, `documents`, `signature_requests`, `signature_records`; **[new]** `form_drafts`, `pdf_templates`, `government_form_fills` | `app.issue_upfront_invoice()`, onboarding status triggers; **[new]** `app.submit_owner_intake()`, `app.set_vehicle_terms()`; Edge Function `render-document` | `expiry-watch` (safety certificate window) | `owner_application_received`, `owner_agreement_ready`, `owner_agreement_signed`, `owner_upfront_invoice`, `owner_onboarding_steps`, `owner_registry_visit`, `owner_vehicle_enrolled`; `renter_agreement_ready`, `renter_agreement_signed` | `15` R6-1 to R6-10 |
| 7 | "Listing a car: a VA, field staff member, admin or car owner enters the plate or VIN and uploads photos; the details are drafted with AI (VIN decode plus generated headline, description and features), the photos are edited with AI to a consistent background, and the car is added to the website and database automatically after a review step. This must be smooth." | `/field/list-a-car`, `/admin/vehicles/new`, `/owner/vehicles/new`; review at `/admin/listings/[id]` (`09`) | `vehicle_listings`, `vehicle_photos`, `photo_jobs`; **[new]** `listing_jobs`, `listing_intakes`, `vin_decodes`, `provider_calls` | **[new]** `app.submit_listing_capture()`, `app.publish_listing()`; modules `vin`, `photos`, `llm` | **[new]** `carmacars-photo-sweep` every minute (Edge Function `photo-worker`) | `staff_listing_ready_for_review`, `owner_vehicle_listed`, `staff_field_job_assigned` (retakes) | `15` R7-1 to R7-8 |
| 8 | "Entering tolls, tickets and damages and matching them to an active or past booking must be smooth and well built: single entry, bulk import from a toll operator's statement file, upload of the notice with fields read from it where possible, automatic match by plate and timestamp against bookings, staff moves and owner use, a confirm screen showing the match evidence, then charging the deposit or the card on file, or billing the owner, with the customer email. Cover damages found at return and after return." | `/admin/tolls`, `/admin/tolls/new`, `/admin/tolls/import`, the confirm screen; `/admin/incidents`, `/admin/claims`; return checklist damage steps (`10`, `06` section 5, `03` sections 11 and 12) | `toll_tickets`, `booking_line_items`, `booking_statements`, `deposits`, `deposit_events`, `payments`, `owner_deductions`, `incidents`, `incident_costs`, `claims`, `claim_ledger_entries`, `condition_report_damages`; **[new]** `toll_import_batches`, `toll_import_profiles`, `vehicle_transponders` | `app.match_toll_ticket()`, `app.toll_ticket_admin_fee()`, `app.open_claim()`, `app.incident_damage_cost()`, `calc_damage_billing()`, `app.settle_claim()`; **[new]** `app.match_toll_candidates()`, `app.import_toll_batch()`, `app.charge_toll_ticket()`, `app.issue_booking_statement()`; module `ocr` | `payment-retries`; unmatched check at 06:00 | `renter_extra_charge`, `renter_final_statement`, `renter_damage_found`, `renter_payment_failed`, `owner_toll_ticket`, `owner_incident_opened`, `staff_toll_ticket_logged`, `staff_toll_ticket_unmatched`, `staff_return_findings`, `staff_incident_reported` | `15` R8-1 to R8-11 |
| 9 | "Every actionable customer event results in an email (account creation, request to book, confirmation or adjustment, receipt, booking reminder, pickup details, check-in, return details, review request, come-back discount after 1 week and after 1 month, and more). Owners get billing and monthly statement emails. Admins and staff get theirs." | Event map and gaps (`12` sections 3 and 4); `/admin/messages`; preferences; `/unsubscribe/[token]` | `messages`, `message_templates`, `consents`, `promo_codes`, `promo_redemptions`; **[new]** `notification_outbox`, `staff_digest_items`, `notifications`, `notification_preferences`, `marketing_sends`, `email_suppressions` | **[new]** `app.emit_event()`, `app.job_followups()`; `app.apply_promo_code()` | **[new]** `send-outbox` every minute, `reminders`, `late-returns`, `followups`, staff and field digests; `expiry-watch` | All 116 codes in `emails/catalogue.json`, mapped one by one in `12` section 3: account creation `renter_account_created`; request `renter_request_received`; confirmation `renter_booking_confirmed` (with the receipt); adjustment `renter_change_request_approved`, `renter_offer_ready`; reminder `renter_booking_reminder`; pickup details `renter_pickup_details`; check-in `renter_rental_started` and `renter_return_complete`; return details `renter_return_reminder`, `renter_return_details`; review `renter_review_request`; come-backs `renter_comeback_1w`, `renter_comeback_1m`; owners `owner_fee_invoice`, `owner_statement_ready`, `owner_payout_sent`; staff digests and immediate notices | `15` R9-1 to R9-8 |
| 10 | "Owner statements generated automatically every month, and CarmaCars' own admin monthly statements per car, per owner and in total. Thorough." | `/admin/statements`, `/admin/statements/[id]`, `/admin/payouts`, `/admin/reports`, `/owner/statements` (`11`) | `owner_statements`, `owner_statement_vehicles`, `owner_statement_lines`, `booking_splits`, `owner_invoices`, `owner_invoice_lines`, `owner_deductions`, `referral_kickbacks`, `payouts`, `turo_trips`, `vehicle_prepaids`; **[new]** `company_statements`, `company_statement_lines`, `company_expenses` | `app.build_owner_statement()`, `app.approve_owner_statement()`, `app.compute_booking_split()`, `app.generate_owner_invoices()`, `app.payout_paid_effects()`; **[new]** `app.build_company_statement()`, `app.finalize_company_statement()` and three views | `returns-accrue`, `statements-draft`, `owner-invoices` (exist); `month-open`, `payouts`, `owner-billing`, `debit-results`, `debit-retry` (to build) | `owner_statement_ready`, `owner_payout_sent`, `owner_fee_invoice`, `owner_payment_failed`, `owner_in_arrears`, `owner_payment_received`, `staff_statements_ready_for_approval`, `staff_payouts_due`; **[to add]** `staff_monthly_statements_ready` | `15` R10-1 to R10-7; `supabase/tests/02_owner_month.sql` |
| 11 | "SEO: every car page should rank highly; the goal is to be the top ranking car rental company in Canada." | Car page template, model hubs, categories, locations, guides (`01` section 4, `14`); metadata and JSON-LD builders; sitemaps, robots, redirects; the honest limits (`14` section 19) | `vehicle_listings` (**[new]** `seo_title`, `seo_description`, `specs`, `faq`, `home_area`, `canonical_vehicle_id`), `vehicle_photos.alt_text` **[new]**, `reviews`, `listing_redirects` **[new]** | `app.public_reviews()`; **[new]** `public_vehicle_photos`, `public_model_hubs` | Nightly link check; sitemap revalidation on publish | `renter_review_request` (feeds reviews) | `15` R11-1 to R11-8; Lighthouse CI |
| 12 | "Portals: renter, owner, admin, VA (finance and billing, fleet operations, customer service and growth, sales), field staff (drivers and detailers, phone-first), and an investor area limited to statements for existing investors." | Renter `/account` (`02` section 7); owner `/owner` (`04`); admin `/admin` (`03`); VA `/va/finance`, `/va/fleet`, `/va/cs`, `/va/sales` (`05`); field `/field` (`06`); investor `/investor` (`07`) | `users`, `user_roles`, `staff_profiles`, `tasks`, `field_jobs`, `condition_reports`, investor tables; every table's row-level security | Role helpers (`app.is_admin()`, `app.va_has()`, `app.is_field()`, `app.is_my_owner()`, `app.my_renter_id()`, `app.is_my_investor()`), guards; **[new]** `app.session_aal()`, `app.complete_handover()`, `app.complete_return()`, `app.complete_task()` | Queue-filling triggers; digests | Staff, field and investor emails in `12` sections 3.4 and 3.5 | `15` R12-1 to R12-8; `supabase/tests/04_rls.sql` |

## 3. Database additions needed (consolidated)

Grouped so they can ship as a small number of migrations. Each new table needs row-level security, the admin policy, the policies named in its blueprint file and an audit trigger (`docs/permissions.md` section 4). Functions that move money stay executable by `service_role` only.

### 3.1 Public site and browser access (blocks workstreams B and C from day 1)

| Addition | From |
| --- | --- |
| Wrappers in the `public` schema for the functions the browser calls: `public_vehicle_calendar`, `vehicle_is_available`, `public_reviews`, `quote_booking`, `search_available`, `promo_code_problem` | `01`, `02` |
| `app.quote_booking(vehicle, pickup, return, options jsonb) returns jsonb`, sharing its fee logic with `app.reprice_booking()`; `app.search_available(from, to)` | `01` |
| `app.reprice_booking()` to create and maintain the young driver, additional driver, winter tire, baby seat and coverage lines from `booking_drivers` and the request's extras | `02` |
| View `public_vehicle_photos`; view or function `public_model_hubs`; anonymous read of the fee catalogue (`fee_types`, current `fee_defaults`) | `01`, `14` |
| `vehicle_listings`: `is_featured`, `specs jsonb`, `faq jsonb`, `home_area`, `seo_title`, `seo_description`, `staff_note`, `canonical_vehicle_id`, `publish_at`, `unpublished_reason`, `redirect_to`, `needs_rewrite`; expose the public ones, `published_at` and `updated_at` in `public_vehicle_listings` | `01`, `09`, `14` |
| `leads`, `action_links`, `listing_redirects`, `email_suppressions` | `01`, `13`, `14` |

### 3.2 Booking, signing and payment (blocks workstream C)

| Addition | From |
| --- | --- |
| `bookings.request_details jsonb`, `request_key text unique`, `awaiting_renter_since timestamptz` | `02`, `03`, `12` |
| `app.submit_booking_request(p jsonb)` wrapping `app.request_booking()` with drivers, lines and consents | `02` |
| `app.open_rental_agreement()`, `app.record_signature()`, `app.complete_signature_request()`; `signature_requests.in_person` | `02`, `08` |
| `app.record_booking_payment()` with the availability lock; `webhook_events` | `02`, `13` |
| `app.preview_cancellation()`, `app.preview_extension()` | `02` |
| `booking_change_requests`, `app.preview_booking_change()`, `app.apply_booking_change()`; `booking_extensions.status` value `approved` | `02`, `03`, `12` |
| Guards on `on_rent`: every additional driver has `accepted_at`; `blocks_calendar = true` | `02`, `03` |
| `reviews.publish_consent_at`, `reviews.google_prompt_clicked_at` | `02`, `14` |

### 3.3 Admin, money, insurers (workstream D)

| Addition | From |
| --- | --- |
| `app.assess_check_in()`, `app.issue_booking_statement()` (also writing claim ledger entries for claim-funds lines), `app.settle_deposit()` | `03`, `10` |
| `app.set_rate_card()` | `03` |
| `booking_line_items.covered_by_company_at`; `program_settings.insurer_terms_days`, `opening_hours`; job `insurer-provisional-watch` | `03` |
| Field jobs and Turo trips on the calendar: extend `calendar_entries` or add two views | `03` |
| `quick_replies`; `payout_reconciliations` and items | `03`, `05` |
| Job function `deposits-due`; Edge Function jobs `late-returns`, `payment-retries`, `reminders`, `deposit-holds`, `retention`, `expiry-watch`, `reconcile`, `month-open`, `payouts`, `owner-billing`, `debit-results`, `debit-retry` (named in `docs/architecture.md` section 5, not yet built) | `03`, `11` |
| Realtime publication on `bookings`, `vehicle_calendar_blocks`, `field_jobs`, `tasks`, `notifications` | `03`, `05`, `12` |

### 3.4 Tolls, tickets, damages (workstream D)

| Addition | From |
| --- | --- |
| `toll_tickets`: `time_unknown`, `note`, `external_ref`, `import_batch_id`, `toll_group_id`, `match_confidence`, `match_evidence jsonb`, `payment_reference`, `ocr_raw jsonb` | `10` |
| `toll_import_batches`, `toll_import_profiles`, `vehicle_transponders` | `10` |
| `app.match_toll_candidates()` (field jobs, swaps, plate history, evidence), `app.import_toll_batch()`, `app.charge_toll_ticket()`, `app.bill_toll_to_owner()`; a trigger creating the `match_toll` task | `10` |
| `incidents.roadside_dispatched_at` | `12` |

### 3.5 Statements and reports (workstream D)

| Addition | From |
| --- | --- |
| `company_statements`, `company_statement_lines`, `company_expenses`; `app.build_company_statement()`, `app.finalize_company_statement()`; views `v_company_vehicle_month`, `v_company_owner_month`, `v_company_total_month` | `11` |
| `fee_types.gl_account` | `11` |
| Confirm `booking_splits.uncollected_cents` exists (named in `docs/data-model.md`, not seen in the column list) | `11` |

### 3.6 Owners, forms, documents, investors (workstream E)

| Addition | From |
| --- | --- |
| `form_drafts`; `pdf_templates`; `government_form_fills` | `08` |
| `owners.licence_number`, `owners.date_of_birth`; `vehicle_onboardings.disclosures`, `new_corporation`, `safety_certificate_document_id`, `appraisal_document_id`; `owner_payout_accounts.submitted_by`, `verified_by`, `verification_method`, key version column | `04`, `13` |
| `app.submit_owner_intake()`, `app.set_vehicle_terms()`, `app.give_exit_notice()` | `04` |
| `document_kind` values: `debit_agreement`, `rental_amendment`, `insurer_authorization`, `insurer_invoice`, `government_form_cover`; `documents.page_count`, `byte_size`, `original_filename` | `04`, `08` |
| `program_settings.company_rin`, `signing_officer_name` | `08` |
| Job `investor-statements` | `07` |

### 3.7 Operations: queues, field, listing, notifications (workstream F)

| Addition | From |
| --- | --- |
| Task-creating triggers for the events in `05` section 1.3; `tasks.sla_minutes`, `wake_at`, `completion_rule`; `app.complete_task()` | `05` |
| `app.complete_handover()`, `app.complete_return()`; condition report columns (`renter_declined_to_sign`, `renter_decline_reason`, `car_diagram`), damage columns (`kind`, `size_cm`, `position`, `status_vs_pickup`), photo columns (`device_taken_at`, `latitude`, `longitude`, `width`, `height`, `quality_flags`); licence photos at handover stored with 90-day retention | `06` |
| `listing_jobs`, `listing_intakes`, `vin_decodes`, `provider_calls`; `photo_jobs` and `vehicle_photos` extra columns; `app.submit_listing_capture()`, `app.publish_listing()`; schedule `carmacars-photo-sweep`; `program_settings.photo_daily_budget_microusd` | `09` |
| `notification_outbox`, `staff_digest_items`, `notifications`, `notification_preferences`, `marketing_sends`; `app.emit_event()` and the emitting triggers; jobs `followups`, staff and field digests, `send-outbox` schedule; one `message_templates` row per catalogue code; `staff_profiles.shift`; `program_settings` come-back and email limit settings | `12` |

### 3.8 Security (workstream A)

| Addition | From |
| --- | --- |
| `app.session_aal()` and its use in the staff helper functions (two-step sign-in enforced by row-level security) | `13` |
| `rate_limit_hits`, `app.rate_limit()` | `13` |
| `security_incidents`; `program_settings.blocked_terms`; legal-hold automation on `documents`; `data_access_log` writes for ID image and bank detail views | `13` |

## 4. Open questions for the owner, each with a recommended default

Work proceeds on the default unless the owner says otherwise. The lawyer's and accountant's open points already listed in `docs/source/` review notes are not repeated here.

| # | Question | Recommended default | Why it matters |
| --- | --- | --- | --- |
| 1 | Who bears a CarmaCars promo discount (the come-back codes)? As migration 0016 ships, a discount lowers Owner Revenue, so the owner shares it, and on a Self-Managed car the owner bears all of it | CarmaCars absorbs its own promo codes: the split is computed on the rental charge before the promo discount. Until the database is changed, send come-back codes that apply to Managed and shareholder-owned vehicles only | Owners did not agree to fund CarmaCars' marketing; it changes `app.compute_booking_split()` |
| 2 | Should come-back emails also go to renters who did not tick the marketing box, under implied consent from the completed rental? | No: express consent only, as the email templates are written. Revisit after launch with the lawyer | Reach versus risk under the anti-spam law |
| 3 | An offer does not hold the car, so two renters can be offered the same car and the first to pay gets it. Accept that? | Yes, as migration 0016 is built. Staff see competing offers, and the loser is never charged (authorize, then capture) | The alternative, holding the car for 24 hours per offer, was not built and costs availability |
| 4 | Who signs for CarmaCars on a rental agreement? | The platform applies the countersignature automatically when payment succeeds, in the name of the staff member who sent the offer | A manual countersign by an admin would delay every confirmation. Needs the lawyer's yes |
| 5 | Is there a staffed address customers can visit? | Treat CarmaCars as a service-area business (address hidden on the Business Profile and the site) until the owner confirms a storefront. A mailing address is still required in marketing emails and on invoices | Business Profile eligibility, structured data, the anti-spam law's address requirement |
| 6 | Which places does CarmaCars deliver to at launch, at what fee, and is an airport hand-over allowed and how does it work? | Toronto only at launch, delivery at each car's own fee; no airport page until the airport's rules for off-airport rental hand-overs are confirmed | Decides which location pages may exist (`14` section 3) |
| 7 | HST number at launch | Show no number until registered; the accountant's question in the payment set-up notes decides. Invoices and statements print it once `program_settings.company_hst_number` is set | Invoices, the footer |
| 8 | The official PDFs for SR-LV-012, ON00453, 013-0169 and 013-1155, and a sample toll statement file | The team downloads the forms from the Ontario Central Forms Repository and maps them in the first week; until a form is mapped, the owner gets a data sheet to copy from. The first real toll statement is mapped once in the import wizard | Pre-fill and bulk import cannot be finished without the real files |
| 9 | Photo editing provider | Photoroom's image editing API for the eight exterior photos (about US$0.80 a car), with Cloudflare Images as the automatic fallback and for all resizing. Confirm at sign-up that billing is per image with no minimum | Cost and look of every listing |
| 10 | Address lookup provider | Launch without one (manual entry with postal code to city fill); add a pay-per-request Canadian address service after its price is confirmed | Avoids an unverified cost before launch |
| 11 | May AI crawlers read the public site? | Yes | Visibility in assistants |
| 12 | The review request is held, not skipped, while a booking has an open incident, dispute or unpaid balance | Hold then send | Google's review policy forbids selectively soliciting positive reviews |
| 13 | Turnaround buffer between bookings | Keep at 0, as migration 0016 advises; use a cleaning block when a gap is needed | A buffer above 0 is not enforced by the table's constraint |
| 14 | What ships after October 15 | The cut line in `00` section 10: bulk toll import and notice reading, calendar drag, company reports beyond exports, insurer invoice PDF, investor area, Sales portal, come-back emails | Six working days to launch |

## 5. Source material and documents

| Item | Status |
| --- | --- |
| "Onboarding automation" and "advertising automation" source documents | Not present in `docs/source/` when this blueprint was written (the folder holds the rental, enrollment, title-holding, investment and shareholder agreements, the two billing specifications, the website policies, the operating procedures, the payment set-up, the VA and field staff agreements and the VA hiring package). Onboarding is specified here from the Enrollment and Title Agreements and procedures 12, 13, 16 and 17. Advertising (posting cars to classified sites and social pages, procedure 17 step 5) is covered only as the `channels` field on a listing and the citations plan in `14` section 16; no posting automation is specified. If those documents exist, they should be added and this blueprint checked against them |
| `docs/data-model.md`, `docs/permissions.md`, `docs/architecture.md`, `README.md` | Out of date after migration 0016 (hold-based flow, 101 tables, `holds-expire`). `docs/changes/0016_request_to_book.md` is the current record. `docs/architecture.md` section 4 also still describes a single `photos` pipeline with `PHOTO_PIPELINE_URL`; `09` replaces it with the `vin`, `photos` and `llm` modules. `docs/setup.md` section 4 step 5 says to turn Stripe receipts on; `12` section 2 turns them off |
| `docs/source/payment_esign_setup.md` | Its recommendation of an outside signature service and Stripe invoices is superseded by decision 0001 (built-in signing, no Stripe Invoicing). Card payments here use PaymentIntents, so `STRIPE_HST_TAX_RATE_ID` is not needed; HST is computed per line by the database |
| `emails/catalogue.json` | Aligned in `12`. Differences and templates to add are in `12` sections 4.1 and 4.2. The catalogue's sample mailing address reads "to be confirmed": it must be set before any marketing email is sent |
| `prototype/` | The visual source of truth for the public site (`00` section 7, `01` section 2) |
| Legal texts | Every agreement in `docs/source/` is marked draft, not for signing. The platform loads only lawyer-approved templates (`08` section 9.4, `15` section 7 item 10) |
