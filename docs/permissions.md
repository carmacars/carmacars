# Permissions

Who can see and do what, and how the database enforces it. Implemented in `supabase/migrations/0012_security.sql` and, for the tables and functions added later, in each migration from 0016 to 0025; proved by `supabase/tests/04_rls.sql`, the role sections of test files 06 to 11 and `13_owner_answers.sql`.

## 1. How it is enforced

| Layer | What it does |
| --- | --- |
| Row-level security | On all 171 tables (and `app.rate_limit_hits`). With no policy, a signed-in user sees nothing. Admins have a policy (`admin_all`) on every table |
| Limited views | Where a role may see a row but not all of its columns, the role has no access to the table and reads a view: `renter_bookings`, `owner_bookings`, `owner_claims`, `field_job_details`, `staff_directory`, `public_vehicle_listings` |
| Guards (triggers) | Approvals and limits that hold whoever is asking, the server included: refund and deposit-release limits, admin-only payout approval, own-approval-only, admin-only columns, tracker rules |
| Privileges | Browser sessions can select, insert and update, never delete. The anonymous role can read one view and call the public functions (section 3), including the cookie banner's `record_cookie_choice` (0025). Functions that move money are executable by the server only |
| Server actions | Renters, owners, field staff and investors change nothing directly; the server validates and writes for them |

A user who is suspended, or whose staff profile is ended, loses all access at once: every check reads `users.status` and `staff_profiles.is_active`.

## 2. Role matrix

R = read, W = create or update, A = approve, "none" = no access. "own" = only rows that belong to that person. "view" = through a limited view.

| Data | Admin | VA Finance | VA Fleet | VA CS | VA Sales | Field | Owner | Renter |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Bookings | RW | R | RW | RW | RW quotes only | view, assigned job | view, own vehicles | view, own |
| Renter record (name, contact) | RW | R in window | R in window | RW in window | W new lead, R in window | name and mobile on the job | name and mobile on Self-Managed only | own, R |
| Licences and drivers | RW | none | names on a booking | RW in window | none | on the job view | none | own, R |
| ID images and face photos | R | none | none | R in window | none | upload only | none | own, R |
| Identity checks | RW | none | none | RW in window | none | none | none | own, R |
| Card on File (brand, last four) | R | R in window | none | R in window | none | last four on the job | none | own, R |
| Card and debit tokens, processor payloads | R | none | none | none | none | none | none | none |
| Payments | RW | R | none | R | none | none | none | own, R |
| Charge lines | RW | RW | R | R | none | none | none | own, R (not internal lines) |
| Deposits | RW A | RW, release within limit | none | R | none | none | none | own, R |
| Refunds | RW A | W request, A within limit | none | R | none | none | none | own, R |
| Chargebacks | RW | RW | none | none | none | none | none | none |
| Cancellations | RW | R | R | RW | none | none | none | own, R |
| Booking split | RW | R | none | none | none | none | own vehicles, R | none |
| Vehicles | RW | R | RW (not owner, mode, dates) | R | R | job vehicle, R | own, R | none |
| Vehicle Schedule, fees, Revenue Share | RW | R | R | R | none | none | own, R | none |
| Rate cards | RW | R | RW | R | R | none | own, R | public listing |
| Fee catalogue and defaults | RW | R | R | R | R | catalogue | catalogue | catalogue |
| Per-booking price override | A | none | none | none | none | none | none | none |
| Owners | RW | R | R | RW (not shareholder, balance, payout) | none | none | own, R | none |
| Owner bank details | RW | none | none | none | none | none | own, R | none |
| Owner agreements and forms | RW | R | R | RW drafts | none | none | own, R | none |
| Onboarding, registration, exit | RW | R | RW | RW | none | none | own, R | none |
| Owner invoices | RW | R | none | R | none | none | own, R | none |
| Owner deductions | RW | RW (not "agreed") | none | none | none | none | own, R | none |
| Owner statements | RW A | R | none | none | none | none | own, approved only | none |
| Payouts | RW A | W prepare (owner, payroll) | none | none | none | own, R | own, R | none |
| Referral kickbacks | RW | R | none | none | none | own, R | own earned, R | none |
| Turo trips | RW | RW | R | none | none | none | own, R | none |
| Field jobs | RW | R | RW | R | none | own: progress only | none | none |
| Condition Reports and photos | RW | R | RW | R | none | own job, RW | baseline, exit, own | own, R |
| Tracker status (location) | R | R (toll proof) | R | none | none | none | own vehicles, always | none |
| Tracker commands | RW A | none | W request | none | none | none | own, blocked during a managed rental | none |
| Incidents | RW | R | RW | R | none | none | none | none |
| Claims and claim ledger | RW A | R | R claims | none | none | none | view: status only | none |
| Tolls and tickets | RW | RW | R | none | none | none | own, R | own, R |
| Tasks | RW | finance queue | fleet queue | cs queue | sales queue | none | none | none |
| Messages | RW | RW in window | RW in window | RW in window | none | none | own, R | own, R |
| Fleet reports | RW | RW | R | none | none | none | none | none |
| Investors, investments, returns | RW A | none | none | none | none | none | none | none (an investor reads their own) |
| Staff profiles and limits | RW | own, R | own, R | own, R | own, R | own, R | none | none |
| Users (emails, phones) | RW | own | own | own | own | own | own | own |
| Audit log, access log | R | none | none | none | none | none | none | none |

"In window" means: while the renter has a live booking, for 90 days after their last rental ends, while a task is open on them, or for 24 hours after a logged lookup.

## 3. Tables and functions added in migrations 0016 to 0025

Same notation as section 2. "RW" for an Admin means the portal may insert and update (privilege granted, policy `admin_all`); "R" for an Admin means the server's functions write and the browser only reads. No browser session deletes anything. Every table below has row-level security, `admin_all` and an audit trigger.

### Tables

| Data | Admin | VA Finance | VA Fleet | VA CS | VA Sales | Field | Owner | Renter | Anonymous |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `booking_offers` (0016) | R | R | R | R | R | none | none | own booking, R | none |
| `booking_events` (0016) | R | R | R | R | R | none | none | none | none |
| `insurers` (0016) | RW | RW | R | RW | R | none | none | none | none |
| `insurer_invoices` (0016) | R, update | R, update while draft or sent | none | none | none | none | none | none | none |
| `promo_codes` (0016) | RW | R | none | R | R | none | none | none | none |
| `promo_redemptions` (0016) | R | R | none | R | R | none | none | own, R | none |
| `reviews` (0016) | R, update | none | none | R, moderate (status and reply) | none | none | none | own, R | published, through `public_reviews` |
| `app_events` (0017) | R | none | none | none | none | none | none | none | none |
| `notification_catalogue`, `notification_link_paths` (0018) | RW | R | R | R | R | R | none | none | none |
| `notification_outbox`, `marketing_sends` (0018) | RW | none | none | none | none | none | none | none | none |
| `staff_digest_items` (0018) | RW | own role, R | own role, R | own role, R | own role, R | none | none | none | none |
| `notifications`, `notification_preferences` (0018) | R | own | own | own | own | own | own | own | none |
| `email_suppressions` (0018) | RW | R | none | R | none | none | none | none | none |
| `rental_agreements` (0019) | R | R | R | R | none | none | none | own, R | none |
| `rental_agreement_signers` (0019) | R | none | none | R | none | none | own signer row | own booking, R | none |
| `webhook_events` (0019) | R | none | none | none | none | none | none | none | none |
| `booking_change_requests` (0019) | R | R | R | R | none | none | none | own, R | none |
| `booking_info_requests` (0019) | R | R | R | R | R | none | none | own, R | none |
| `verification_uploads` (0019) | R | none | none | R in window | none | none | none | own, R | none |
| `vehicle_moves` (0020) | RW | R | RW | none | none | own, R | none | none | none |
| `required_shots` (0020) | RW | R | R | R | R | R | R | R | none |
| `task_rules` (0020) | RW | R | R | R | R | none | none | none | none |
| `quick_replies` (0020) | RW | R active | R active | R active | R active | none | none | none | none |
| `incident_steps` (0020) | RW | R | R, tick non-admin steps | R | none | none | none | none | none |
| `payout_reconciliations` and items (0020) | RW | R | none | none | none | none | none | none | none |
| `gl_accounts` (0021) | RW | R | R | R | R | none | none | none | none |
| `gl_account_map`, `company_expense_categories` (0021) | RW | R | none | none | none | none | none | none | none |
| `vehicle_transponders`, `vehicle_plate_history` (0021) | RW | R | RW | none | none | none | none | none | none |
| `toll_import_profiles` (0021) | RW | RW | none | none | none | none | none | none | none |
| `toll_import_batches`, `damage_intakes` (0021) | RW | R | R | none | none | none | none | none | none |
| `company_expenses` (0021) | RW | RW (not a final month) | none | none | none | none | none | none | none |
| `company_statements` and lines (0021) | RW | R | none | none | none | none | none | none | none |
| `owner_credits` (0021) | RW | R | none | none | none | none | own, R | none | none |
| `site_settings` (0022) | RW | R | R | R | R | R | none | none | public fields, through a function |
| `site_content_blocks` (0022) | RW | R | R | R | R | none | none | none | published, through a function |
| `form_drafts` (0022) | R | own | own | own | own | own | own | own | none (server, by token) |
| `leads` (0022) | RW | none | none | R W, not owner enquiries | R W | none | none | none | none |
| `owner_private_details` (0022) | R | none | none | none | none | none | own, R | none | none |
| `owner_applications` (0022) | R | R | R | R | none | none | own, R | none | none |
| `onboarding_situations`, `onboarding_checklist_items`, `listing_shot_types` (0022) | RW | R | R | R | R | R | R | R | none |
| `vin_decodes` (0022) | R | none | R | R | none | none | none | none | none |
| `pdf_templates`, `government_form_fields` (0022) | RW | none | R | R | none | none | none | none | none |
| `government_form_fills`, `vehicle_term_changes` (0022) | R | R | R | R | none | none | own (vehicles), R | none | none |
| `listing_redirects` (0022) | RW | none | R | R | none | none | none | none | through a function |
| `listing_intakes` (0022) | R | none | R | R | none | started by them, R | own vehicles, R | none | none |
| `listing_drafts`, `listing_jobs` (0022) | R | none | R | R | none | none | none | none | none |
| `provider_calls` (0022) | R | R | R | none | none | none | none | none | none |
| `vehicle_classes`, `deposit_tiers`, `km_allowance_choices`, `airports`, `email_aliases`, `email_reply_to` (0025) | RW | R | R | R | R | R | none | none | class list through `public.vehicle_classes` |
| `vehicle_class_links` (0025) | R (set through `set_vehicle_classes`) | R | R | R | R | R | own vehicles, R | none | in the public car rows |
| `coverage_prices` (0025) | RW | R | R | R | none | none | none | none | the price in a quote only |
| `review_request_decisions` (0025) | R | none | none | R (decides through `decide_review_request`) | none | none | none | none | none |
| `cookie_consents` (0025) | R | none | none | none | none | none | none | none | write only, through `record_cookie_choice` |
| Investor tables (0010; checked in 0025) | RW | none | none | none | none | none | none | none | none; an investor reads only their own rows after signing in (`self_read`) |

Views added: the work queues (`work_queue` for everyone with a queue, `va_finance_queue`, `va_fleet_queue`, `va_cs_queue`, `va_sales_queue`, `admin_queue`) each show only their own queue; `field_job_list` shows a field staff member their own jobs for today and tomorrow, with the renter's first name only; `toll_work_queue`, its summary and `damage_work_queue` are for Admins, Finance and Fleet; `owner_statement_vehicle_lines` is for Admins and Finance, and for an owner their own approved statements; the company statement views are for Admins and Finance. 0024 adds no table and no view; its new columns follow the policies of their tables.

### Functions

Every function in the `app` schema is revoked from `public`, `anon` and `authenticated` and granted to `service_role`, except the ones opened below. The server calls the rest after its own checks, and each of them checks the acting user (`p_by`) again.

| Group | Functions | Who may execute |
| --- | --- | --- |
| Public reads (0019, 0022) | `quote_booking`, `search_available`, `public_vehicle_calendar`, `public_reviews`, `vehicle_is_available`; `site_settings_public`, `site_content`, `car_page`, `fleet`, `model_hubs`, `model_hub`, `vehicle_photos_public`, `sitemap_rows`, `resolve_path` (wrapped in `public` as invoker functions) | anon, authenticated, server. None returns a person, VIN, plate, owner, cost or private field |
| Renter, own booking, read only (0019) | `my_cancellation_preview`, `my_extension_preview`, `my_booking_change_preview`, `my_booking_readiness`, `my_promo_code_problem` | authenticated (each checks the booking is the caller's), server |
| Renter and visitor actions (0019, 0022) | `submit_booking_request`, `renter_approve_offer`, `renter_request_offer_change`, `renter_withdraw_request`, `renter_cancel_booking`, `renter_request_extension`, `renter_request_booking_change`, `renter_agree_booking_change`, `renter_withdraw_booking_change`, `renter_reply_booking_info`, `submit_lead` | server only (the server checks the visitor or renter first; each checks `p_by` is the renter) |
| Own notices (0018) | `my_notifications`, `mark_notifications_read`, `my_notification_preferences`, `set_notification_preference` | authenticated, own rows only |
| Staff reads (0020) | `master_calendar`, `vehicle_calendar`, `calendar_preview_change`, `staff_field_jobs` | authenticated staff (each checks the caller) |
| Helpers (0019 to 0022) | `session_aal`, `from_browser`, `add_opening_minutes`, `money_text`, `required_shots_for`, `field_job_is_move`, `norm_plate`, `csv_field`, `multirange_days`, `slugify`, `model_hub_path`, `public_listing_row`, `public_listing_photos`, `onboarding_options`, `clean_vin`, the `fmt_*` formatters | as each needs; none reads a protected row |
| Booking flow, signing, payment, extensions, change requests (0016, 0019) | `request_booking`, `adjust_booking`, `send_offer`, `approve_offer`, `open_rental_agreement`, `record_signature`, `complete_signature_request`, `record_booking_payment`, `confirm_unpaid_booking`, `cancel_booking`, `request_extension`, `approve_extension`, `confirm_extension_payment`, `request_booking_change`, `approve_booking_change`, `agree_booking_change`, `apply_booking_change`, `review_verification_upload`, `waive_deposit` and the rest | server only. Inside: customer service, fleet or an Admin approve; only the renter agrees online; only an Admin records an agreement by phone, and only when nothing more is owed; only an Admin waives a Deposit |
| Operations (0020) | handover, return, assessment, statements, `settle_deposit`, field jobs, calendar apply, rates and fees, tasks, incidents, swap, tracker disable, reconciliation | server only. Inside: Fleet or an Admin complete handovers and returns; Finance or an Admin assess; damage lines and hold-backs need an Admin; a Finance assistant settles a Deposit only inside their Single Limit; rates are set by an Admin (Fleet enters them) or the owner of a Self-Managed car; a confirmed booking's calendar change goes through 0019's change request (0024) |
| Tolls and statements (0021) | intake, matching, charging, owner billing, disputes, naming the renter (Admin only), damage billing (Admin only), owner statement reissue and payout, company statements and finalizing (Admin only), CSV exports | server only |
| Owners, forms, listings (0022) | application, onboarding, terms (off-grid terms need an Admin), exit, fee change (Admin), bank details (verified by an Admin), owner portal reads, government form fills, the listing pipeline and review, `publish_listing`, `unlist_listing`, `claim_listing_jobs` and the worker's functions | server only. Inside: who may start, review and publish a listing follows `listing_review_required_roles` |
| Notification layer (0018, 0023) | `process_events`, the `outbox_*` sender functions, `unsubscribe`, `notification_payload` and its helpers, `dispatch_roadside` | server and scheduler only |
| Scheduled jobs (0015 to 0024) | every `job_*` wrapper, `sweep_listing_jobs`, `publish_scheduled_listings` | scheduler (pg_cron runs as the database owner) and server only |
| Timed publishing (0024) | `schedule_listing_publish` | server only; inside, an Admin or a customer service or fleet assistant |
| Public (0025) | `record_cookie_choice`, `cookie_choice`, `vehicle_classes`, `featured_cars` (wrapped in `public`) | anon, authenticated, server |
| Staff reads (0025) | `rate_card_choices`, `site_setup_problems` | authenticated |
| The owner's answers (0025) | `set_vehicle_classes` (Fleet, Admin), `review_listing_classes` (Fleet, customer service, Admin), `propose_listing_classes` (worker), `set_vehicle_deposit` (Admin), `set_coverage_price` (customer service, Admin), `set_booking_places` (staff), `reopen_expired_request` (staff), `decide_review_request` (customer service, Admin), the segment and split functions | server only; each checks `p_by` |

Two-step sign-in (0019): with `program_settings.require_staff_two_step` on, `app.is_admin()`, `app.va_has()` and `app.is_field()` are true only for a session signed in with a second factor, so a staff session without one reads and writes nothing as staff. Off by default until every staff member has enrolled.

## 4. What each role must never do, and what stops it

| Rule | Enforced by |
| --- | --- |
| A renter sees only their own data | Policies keyed on `app.my_renter_id()`; `renter_bookings` view |
| An owner never sees a renter's ID documents, licence, address, email or card | No owner policy on `renters`, `drivers`, `booking_drivers`, `identity_verifications`, `payment_methods`, `bookings`; the `documents` policy for owners excludes anything tied to a renter or booking; `owner_bookings` has no such column |
| An owner sees contact details only on a rental they manage | `owner_bookings` returns name and mobile only when the booking is Self-Managed |
| An owner keeps live location but cannot lock, alarm or shut off during a managed rental | `tracker_status` owner policy; `tracker_access_blocks`; the command is stored as `blocked` |
| An owner sees a statement only once approved | `owner_statements` policy |
| A VA never sees full card data or bank account numbers | `payment_method_secrets`, `payment_processor_details`, `owner_payment_method_secrets`, `owner_payout_accounts`, `investor_bank_accounts`: admin (and the account's own holder) only |
| A VA cannot pay out, refund or release above their limit | `app.guard_refund_approval()`, `app.guard_deposit_release()` against `staff_profiles.single_limit_cents`; a refund outside the cancellation table is admin only |
| A VA can never approve a payout | `app.guard_payout()`; the finance policy on `payouts` stops at "pending approval" |
| Nobody records another person's approval | `app.guard_approver()` |
| No bulk export path | No VA policy on `users`; renter records only in window; `app.staff_find_renter()` returns at most 10 names and is logged; no customer-list view exists; no delete privilege |
| Only an admin sets fees, Revenue Share, management mode, discounts or a per-booking price (0025: customer service may also price coverage sold on a request) | Admin-only write on `vehicle_schedules`, `vehicle_fee_history`, `fee_defaults`; `app.guard_admin_columns()`; `app.guard_booking_override()` |
| Only an admin changes a payee's bank details | Admin-only write on `owner_payout_accounts` |
| Field staff see only their assigned jobs | `field_jobs` policy; `field_job_details` view, from 36 hours before the job to 24 hours after it is done |
| Field staff cannot reassign a job or change a booking | `app.guard_field_job()`; no policy on `bookings` |
| Only an admin approves disabling a car, and never while it is moving | Check constraint on `tracker_commands` and `app.guard_tracker_command()` |
| Investor, staff and shareholder documents are admin only | `documents` policies exclude those kinds for every other role |
| Investment terms are seen only by the signed-in investor (and Admins) | No anon privilege on investor tables; only `admin_all` and `self_read` policies; no public function reads them (tested in 13) |
| Money-moving functions cannot be called from a browser | Execute revoked from everyone but `service_role` |

## 5. Adding a table later

1. Enable row-level security and add the `admin_all` policy in the same migration.
2. Add only the policies the role matrix calls for.
3. Call `app.attach_audit()`.
4. Run `scripts/test.sh`: it fails if any table lacks row-level security, the admin policy or an audit trigger.
