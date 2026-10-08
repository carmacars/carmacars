# 0019: the booking application

Migration `supabase/migrations/0019_booking_app.sql`, tests `supabase/tests/08_booking_app.sql` (415 assertions). Builds on migrations 0001 to 0017 only. No shared document, earlier migration or existing test was edited.

What it adds: the quote and the search for the public site, the public booking request, signing built into the platform, the confirmation under a lock on the vehicle when the card is authorized, renter self-service (cancellation, extensions, change requests, questions from staff), identity and coverage documents with staff review, the handover guards, two-step sign-in for staff, and the `public` wrappers the API needs.

## 1. Browser access (wrappers in `public`)

The Supabase API exposes the `public` schema only. Three kinds of wrapper:

| Kind | Functions | Who may execute | Invoker or definer, and why |
| --- | --- | --- | --- |
| (a) Public | `public_vehicle_calendar`, `public_reviews`, `vehicle_is_available`, `quote_booking`, `search_available` | anon, authenticated, service_role | Invoker. Each passes the call to an app function the caller may already execute and that is itself safe for the public (listed cars only, no person, owner, VIN, plate or reason) |
| (b) Own booking, read only | `my_cancellation_preview`, `my_extension_preview`, `my_booking_change_preview`, `my_booking_readiness`, `my_promo_code_problem` | authenticated, service_role | Definer: the app functions behind them read the bookings table, which a renter cannot read. Each first checks `app.is_my_booking()`; none writes |
| (c) Server, for a visitor or renter | `submit_booking_request`, `renter_approve_offer`, `renter_request_offer_change`, `renter_withdraw_request`, `renter_cancel_booking`, `renter_request_extension`, `renter_request_booking_change`, `renter_agree_booking_change`, `renter_withdraw_booking_change`, `renter_reply_booking_info` | service_role only | Invoker. Each renter action checks that `p_by` is the renter of the booking, so they cannot be used to act as staff |

**Decision: the actions that change a booking are not open to browser sessions.** The guards of 0012 and 0016 (`app.guard_admin_columns()`, `app.guard_approver()`) treat any session whose role is `authenticated` as a browser and refuse its writes to offer, approval and approver columns, and a security definer function does not change that role. A definer wrapper opened to `authenticated` would therefore fail on `approve_offer` and `request_offer_change`; and a request also needs facts only the server has (the bot check, the visitor's network address). So the server calls group (c) with the service key after its own checks. Opening them would need a change to those shared guards.

`04_rls.sql` still passes unchanged: the anonymous role has select on exactly one table or view; the public things are functions.

## 2. One source for prices

`app.price_lines(spec jsonb)` works out every line from one description of a booking. `app.price_quote()` builds the spec from the rate card in force and the visitor's options; `app.booking_price_spec()` builds it from the rates and terms stored on the booking. `app.sync_booking_price()` writes the lines and totals; `app.reprice_booking()` of 0016 is replaced (same signature, same rule on when a price may move) and now calls it. 0016's 348 tests pass unchanged.

Lines: rental charge (with the rate applied, the rule as words, and whether the weekly or monthly cap applied), non-refundable discount, staff discount, promo discount, delivery, pickup, and, when the booking carries its request (`request_details`) or for every quote: young driver fee per driver by band (18 to 20, 21 to 25), additional driver fee per additional driver, winter tire, baby seats, and coverage sold (a line only once an Admin sets its price; until then the quote says it is not available). HST per line. The quote also returns total, Deposit and how it is taken, kilometre allowance, overage rate, availability, the drivers and any problems (driver under the minimum age, young driver on a car not offered to them, too many drivers or seats, the car leaving the fleet, an unusable promo code). The visitor does not see `revenue_class`.

Fee terms: the booking's own `booking_fee_terms` row (snapshotted at the request, or an Admin's per-booking change), else `effective_fee()` (vehicle override, class default, default).

`app.quote_booking()` lets a visitor or customer price only a listed car; staff and the server any car with rates. `app.search_available(pickup, return, filters)` lists listed cars free for the whole range (`app.vehicle_is_available()`, exit date respected) with the quote total, cheapest first. Filters: class or classes, seats_min, transmission, fuel, make, young, max_daily_rate_cents, max_total_cents, options (quote options for every car).

Tested against every worked example of renter billing specification section 2 ($340, $560 capped, $800, 45 days refused with 30 + 15 = $3,000), the 29-day monthly cap, rounding up of days, every fee cap of section 1, the non-refundable discount on the rental only, HST and the discount rate as settings, a new dated fee default, and a submitted request whose lines and total equal the quote for the same choices.

## 3. The public request

`app.submit_booking_request(p_request jsonb, p_ip, p_user_agent, p_user)` returns `{ok, created, booking_id, booking_number, ...}`. In one transaction: finds or creates the user (with the sign-in account id the server passes, or a new id), the renter role, the renter and the renter's driver row; checks the request key, the dates (minimum notice, maximum length), the listing, ages (minimum age, the 18 to 20 flag of the car), the licence (classes accepted; "other" with its issuer is accepted and flagged for review), additional drivers (count, name, birth date, email, duplicates), extras, coverage option (1, 2, or 3 only when priced), the note length, delivery addresses and the Terms and Privacy consents; then calls `app.request_booking()`, inserts `booking_drivers`, snapshots `booking_fee_terms`, stores `request_key`, `request_details` and `coverage_option`, prices (per-driver and extras lines included), applies a promo code when it can be used (otherwise keeps and returns the reason, without failing the request), writes the consents (terms, privacy, and marketing as its own row with its version, setting `users.marketing_opt_in` and its time), and gives an Admin a task for a blocked customer. No card, no payment.

- Idempotency: an advisory lock on the key, then a second submit with the same key returns the first booking.
- Limits: `app.rate_limit('booking_request:ip:...', booking_request_hourly_limit, 1 hour)` and the open-request limit per customer return `{ok: false, error: 'rate_limited' | 'too_many_open_requests'}` with nothing written but the count. Anything wrong with the request itself raises an error and writes nothing.
- An existing email attaches the request to that account; what an unsigned-in visitor typed never overwrites the record (the difference is flagged). A signed-in user (`p_user`) uses their own record and may update their mobile.
- `request_details` keeps the request as sent minus dates of birth, licence details and other people's contact details (fewer staff may read driver records than bookings), plus `terms_version`, `terms_accepted_at`, `privacy_version`, `marketing_opt_in`, `conflict_at_submit`, `licence_needs_review`, `details_differ_from_record`, `new_account`, `promo_problem`, and whatever the form sent in `details`.

`app.rate_limit(key, max, window)` counts in fixed windows in `app.rate_limit_hits` (in the `app` schema, outside the API and the audit log); `app.rate_limit_purge()` removes old counters. An optional per-minute limit on quotes and searches from browsers (`public_rate_limit_per_minute`, 0 = off by default) reads the address from the request headers (`app.request_ip()`).

## 4. Signing

| Function | Does |
| --- | --- |
| `app.open_rental_agreement(booking, by, template_version, document_sha256, storage_path, bucket)` | For a booking in `pending_payment` with its current offer approved (or an Owner Booking). Assigns or keeps `RA-` number, writes the document row, a `builtin` signature request and a `rental_agreements` row for the approved version, one signer row for the renter (required before payment), one per additional driver, and one for CarmaCars in the name of the staff member who sent the approved offer (for an Owner Booking: the staff member who opened it, or who created it). The same version, text version and hash returns the open agreement; anything else voids it and opens a new one. Emits `renter_agreement_ready` to each additional driver, and to the renter when reissued or opened by staff |
| `app.record_signature(request, signer, typed_name, drawn_signature, ip, user_agent, consent_text, document_sha256, consents)` | A new `signature_records` row (method drawn or typed; a typed name must be the signer's name, ignoring case and spaces; the consent text and the document hash are stored); refuses a stale hash, a voided agreement, a second signature, and the CarmaCars signer. The renter signs only for the approved version. Optional booking consents are written as `consents` rows. An additional driver's signature sets `booking_drivers.accepted_at` |
| `app.complete_signature_request(request, payment, signed_path, signed_sha256)` | Countersignature for CarmaCars as its own signature record (method `automatic`, in the countersigner's name), request and agreement completed. Needs the renter's signature, the approved version, and the succeeded booking payment of exactly the amount due when one is due. Emits `renter_agreement_signed` |
| `app.attach_signed_agreement(request, path, sha256, bucket)` | Stores the signed copy once; never replaced |

A signature record on a rental agreement is append-only (trigger on update and delete). When a booking leaves `pending_payment` for `requested`, `declined`, `expired` or `cancelled` (an adjustment, a withdrawal, an expiry, another booking taking the car), its open or signed agreement is voided with the reason and the booking no longer points at it; the next approved offer is signed again.

## 5. Payment

- `webhook_events (provider, event_id unique)`; `app.webhook_event_claim()` and `app.webhook_event_finish()`.
- `app.record_booking_payment(booking, processor, amount, offer_version, card, event_id, by)`, called once the card is authorized. Under a `for no key update` lock on the vehicle it re-checks: status `pending_payment`, approved and current offer version equal to the one paid for, the agreement for that version signed by everyone required before payment, the amount equal to `renter_due_at_booking_cents`, a credit card, the car bookable and free. Then saves the Card on File (display fields in `payment_methods`, processor ids in the admin-only table), records or completes the payment and its processor details, ties the booking-stage lines to it (on a booking billed wholly to an insurer the rental lines wait for the insurer), countersigns, and confirms. Returns `{ok: true, action: 'capture'}`. Every refusal is returned as `{ok: false, reason, action: 'void_authorization'}` and logged in the booking history. If the car was taken (another confirmation pushed the booking back, a block appeared, or the exclusion constraint fires), the booking goes back to staff with an urgent `reoffer_booking` task. Replays (same event, or same processor payment) return the first result.
- `app.confirm_unpaid_booking(booking, by, card, processor)`: the same checks and lock when the renter owes nothing at booking (insurer pays everything: a credit card is saved, no charge; Owner Booking: no card).
- `app.booking_payment_capture_failed()`: if the capture fails after confirmation, the payment is marked failed and an Admin gets an urgent task.

## 6. Renter self-service

| Area | Functions |
| --- | --- |
| Cancellation | `app.preview_cancellation(booking, at, reason)` from `calc_cancellation()`; `app.cancel_booking(booking, by, reason, note, channel, at)`: renter (own, now, `renter_request`) or customer service / Admin (any reason the table covers, a no-show after pickup). Writes `booking_cancellations` (the existing trigger fills the tier), the status, a `refunds` row pending approval with allocations (renter-billed bookings), a Finance task, history. `app.booking_paid_cents()` |
| Extensions | `app.preview_extension`, `app.request_extension`, `app.approve_extension` (CS, fleet, Admin; checks calendar and an auto policy's expiry), `app.decline_extension` (staff with a reason, or the renter withdrawing), `app.confirm_extension_payment` (under the vehicle lock: before the return time, the exact amount, the calendar, the card hold captured past the hold period; writes the extension payment, extension-stage lines, moves the booking and confirms in writing), `app.lapse_extensions(now)`. `booking_extensions.status` gains `approved` |
| Change requests | `booking_change_requests`; `app.preview_booking_change`, `app.request_booking_change` (renter: `requested`; staff: `proposed`), `app.approve_booking_change`, `app.decline_booking_change`, `app.withdraw_booking_change`, `app.agree_booking_change` (renter, with address and browser; or an Admin by phone with a note when nothing more is owed), `app.apply_booking_change` (under the lock on both cars; the price must still be the price agreed; a payment of exactly the difference, or a refund for approval; booking, lines and totals change together) |
| Questions | `booking_info_requests`; `app.ask_booking_info` (staff, on a request, reply-by from the setting or given), `app.reply_booking_info`, `app.close_booking_info`. `bookings.awaiting_renter_since` is set while a question is open and cleared by the answer or when the request moves on (open questions are then closed) |

## 7. Identity and coverage documents

`verification_uploads`; `app.register_verification_upload(booking, by, kind, driver, storage_path, sha256, mime, details, bucket)` (renter, the driver, staff, field staff, or the server for a driver's link; booking `pending_payment` or `confirmed`): a `documents` row with only the key (licence images and selfie: `id_face_90d`, purge 90 days after the return; coverage proof: `records_7y`), the earlier upload of the same kind marked `replaced`, the driver's `identity_verifications` row reopened, or the `coverage_proofs` row (options 1 and 2; policy must run to the return; credit card coverage on the Card on File); one `verify_renter` task due before pickup. `app.review_verification_upload(upload, by, approve, reason)` (CS or Admin; a rejection needs a reason): three approved images verify the driver (identity check verified, `booking_drivers` method and date, driver and renter status); an approved proof confirms the Coverage Option on the booking. `app.booking_readiness(booking)` is the roll-up (drivers verified, coverage, additional drivers accepted, Deposit, calendar switch, agreement, pickup report, `ready_for_handover`, `missing`). The purge date follows the return time and is reset at Check-in, cancellation, decline, expiry or no-show.

## 8. Two-step sign-in

`app.session_aal()` reads `aal` from the token claims. `app.is_admin()`, `app.va_has()` and `app.is_field()` of 0012 are replaced to also require `app.staff_two_step_ok()`: true when `program_settings.require_staff_two_step` is off (the default), otherwise only for an `aal2` session. Every staff policy, view and guard reads those helpers, so with the switch on a staff session without a second factor reads and writes nothing as staff. Customers are unaffected. Existing role tests pass because the switch is off; the switch is tested both ways. Follow-up: turn it on once every staff member has enrolled.

## 9. Handover guards

A separate trigger (`bookings_handover_guard`, after `app.booking_before_write()` of 0016, which is not replaced) refuses `on_rent` unless the calendar switch is on, every additional driver has accepted the agreement, and the Deposit is held or captured or was waived. Identity and coverage are already required by 0016. `app.waive_deposit(booking, admin, reason)` (also possible from the portal by an Admin, signed with their own name): only on a confirmed booking, once; `deposit_waived_cents` keeps the amount and `deposit_cents` becomes 0. A booking offered with no Deposit also needs a waiver.

## 10. Objects added

**Tables (6, all with row-level security, `admin_all` and audit):** `rental_agreements`, `rental_agreement_signers`, `webhook_events`, `booking_change_requests`, `booking_info_requests`, `verification_uploads`. Plus `app.rate_limit_hits` (row-level security and `admin_all`; not audited by design). Sequence `rental_agreement_number_seq`.

**Columns:** `bookings.request_key` (unique), `request_details`, `awaiting_renter_since`, `deposit_waived_at`, `deposit_waived_by`, `deposit_waived_reason`, `deposit_waived_cents`; `booking_extensions.requested_by`, `note`, `lines`, `approved_by`, `approved_at`, `declined_by`, `declined_at`, `decline_reason`; `signature_records.typed_name`, `consent_text`, `document_sha256`; `signature_requests.in_person`; `reviews.publish_consent_at`, `google_prompt_clicked_at` (columns only; nothing sets them yet); `program_settings.booking_min_notice_minutes`, `booking_request_hourly_limit`, `booking_open_request_limit`, `public_rate_limit_per_minute`, `accepted_licence_classes`, `other_licence_for_review`, `max_additional_drivers`, `max_baby_seats`, `request_note_max_chars`, `info_request_reply_hours`, `verification_due_hours_before_pickup`, `verification_review_hours`, `require_staff_two_step`.

**Constraints rebuilt (keeping whatever is there):** the consent codes gain `terms_of_use`, `privacy_policy`; the booking history kinds gain `agreement_opened`, `agreement_signed`, `agreement_completed`, `agreement_voided`, `confirmed`, `payment_refused`, `info_requested`, `info_replied`, `cancelled`, `extension`, `booking_change`, `verification`, `deposit_waived`; the extension statuses gain `approved`.

**Functions replaced:** `app.reprice_booking()` (0016), `app.is_admin()`, `app.va_has()`, `app.is_field()` (0012).

**Functions added (app):** those named above, and the helpers `rate_limit_purge`, `request_ip`, `public_rate_check`, `staff_two_step_ok`, `user_va_has`, `age_on`, `age_band`, `fee_term`, `price_line`, `put_price_line`, `void_rental_agreements`, `save_card_on_file`, `push_back_booking`, `refuse_confirmation`, `finalize_booking`, `assert_my_booking`, `assert_booking_renter`, and the triggers `guard_signature_record`, `booking_app_before`, `booking_app_after`.

**Privileges:** new tables are read under their policies and written only by the server's functions. Every new app function is revoked from public, anon and authenticated, then granted: `app.quote_booking`, `app.search_available` (anon, authenticated), `app.session_aal` (anon, authenticated); everything to service_role.

## 11. Permissions on the new tables

| Table | Admin | VA Finance | VA Fleet | VA CS | VA Sales | Field | Owner | Renter | Anonymous |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `rental_agreements` | R | R | R | R | none | none | none | own, R | none |
| `rental_agreement_signers` | R | none | none | R | none | none | own signer row | own booking, R | none |
| `webhook_events` | R | none | none | none | none | none | none | none | none |
| `booking_change_requests` | R | R | R | R | none | none | none | own, R | none |
| `booking_info_requests` | R | R | R | R | R | none | none | own, R | none |
| `verification_uploads` | R | none | none | R in window | none | none | none | own, R | none |

No browser session writes to any of them (select privilege only). Admin's `admin_all` policy cannot write without the privilege, by design.

## 12. Event codes emitted

Only for things that originate in objects of this migration, with `code:entity_id:discriminator` dedupe keys: `renter_agreement_ready`, `renter_agreement_signed`, `renter_request_needs_info`, `renter_change_request_received`, `staff_change_request_received`, `renter_change_request_approved`, `renter_change_request_declined`, `renter_extension_requested`, `staff_extension_requested`, `renter_extension_approved`, `renter_extension_declined`, `renter_extension_confirmed`, `staff_identity_review`, `renter_identity_approved`, `renter_identity_rejected`. All are in `emails/catalogue.json`.

Not emitted here (left to 0018, which turns booking status changes and payment rows into events): `renter_account_created`, `renter_request_received`, `staff_booking_request_new`, `renter_booking_confirmed`, `staff_offer_approved_paid`, `owner_new_booking`, `renter_identity_needed`, `renter_booking_cancelled`, `staff_cancellation_received`, `renter_offer_withdrawn`, `renter_payment_failed`. **To check at merge:** the extension events are emitted here because `booking_extensions` gets its approval step and its functions in this migration; if 0018 also emits them from a trigger, one side should stop (the dedupe keys here use the new status as discriminator).

## 13. Assumptions and decisions to confirm

1. Group (c) wrappers are server-only (section 1).
2. "Booking made" for the 95% tier is the confirmation time (signed and paid), not the request time; a booking without one uses `booked_at`. Under request to book a renter confirmed days after asking would otherwise lose the 24-hour grace.
3. "Total paid" for a cancellation is card charges for the booking and its extensions or changes, less approved refunds. Refund allocation is skipped on insurer-billed bookings (finance allocates).
4. "Fully signed" before payment means the renter (and anyone flagged `required_before_payment`); additional drivers accept separately, before handover (blueprint).
5. The countersigner is the staff member who sent the latest offer up to the approved version that had a sender (a version issued by the system for a promo code has none).
6. A car change on a confirmed booking is applied only to a car of the same Owner, management mode and Revenue Share, at the booking's stored rates: 0016's `app.booking_before_write()` refuses changing owner, mode or Revenue Share once confirmed. For another Owner's car: cancel for CarmaCars and rebook. Changing that would mean replacing the shared trigger function.
7. A change request is not offered on an insurer booking, a booking with an extension, or a provisional one; staff use their own paths.
8. A change or an extension of a hand-set rental charge keeps the hand-set difference: the difference is the rate rule's difference.
9. An extension's discount lines follow the rental charge: the non-refundable discount stays its fixed share, a percentage promo code keeps its percentage.
10. A licence class "other" with an issuer is accepted for staff review (blueprint "another province or country").
11. A renter on a booking with no Deposit on it still needs an Admin's waiver for handover ("taken or waived").
12. The payment of an authorized card is recorded as `succeeded` when the booking is confirmed (the capture follows); the existing confirmation trigger requires `succeeded`.
13. A booking billed to the renter with a total of nil cannot be confirmed (0016 requires a succeeded payment and `payments.amount_cents > 0`); `confirm_unpaid_booking` refuses it with `nothing_due_but_billed_to_renter`.
14. The sign-in account id for a new customer comes from the server (`renter.user_id`); without it a new id is generated, which the server must then use for the auth user.
15. An existing email attaches an unsigned-in request to that account (blueprint), without changing the record.
16. The rate limit on requests counts accepted requests and refused attempts, not requests rejected for their content (those roll back).

## 14. Values an Admin still cannot change without a migration

| Value | Where | Why |
| --- | --- | --- |
| Age bands 18 to 20 and 21 to 25 | `app.age_band()` | Fixed by the check constraints of `booking_drivers` (0005) and the two young driver charge codes |
| 30 days as the ceiling of one rental | `calc_rental_charge()`, `bookings.billable_days` check | 0003 and 0005. The `max_rental_days` setting is applied below that ceiling |
| Fixed windows of 1 hour (request limit) and 1 minute (public limit) | `submit_booking_request`, `public_rate_check` | The counts per window are settings; the window lengths are part of the rule's definition |
| Default storage buckets `identity` and `agreements` | upload and agreement functions | Overridable per call; they name storage, not a business number |

Every price, fee, cap, percentage, age limit, notice period, limit and retention period used here is read from rate cards, fee defaults, vehicle overrides, booking fee terms or program settings.

## 15. Existing tests changed

None.

## 16. Not done

- Group 1 items of the traceability list outside this brief: `public_vehicle_photos`, `public_model_hubs`, anonymous read of the fee catalogue, the `vehicle_listings` additions, `leads`, `action_links`, `listing_redirects`, `email_suppressions`. Also `form_drafts`, `security_incidents`, `blocked_terms`, legal-hold automation.
- No job schedules the purge of rate limit counters or the lapse of extensions: `app.rate_limit_purge()` and `app.lapse_extensions()` are for the retention and reminders jobs (adding a pg_cron job would change the job count asserted in `05_jobs.sql`).
- Wrappers in `public` for the other server-only functions (signing, payment, staff actions) were not added; the brief limits wrappers to what visitors and renters call.
- Change requests do not produce an amendment document for signature (blueprint `03-admin.md` 4.5 step 3); the renter's agreement is recorded on the change request itself. Field jobs are not moved when dates change.
- `reviews.publish_consent_at` and `google_prompt_clicked_at` exist but `app.submit_review()` (0016) does not set them.
- The shared documents (`README.md`, `docs/data-model.md`, `docs/permissions.md`, `docs/architecture.md`) were left alone as instructed and do not mention this migration.
- pg_cron, Stripe and the API's request headers were not available where the tests run; the header-based public limit is tested with headers set by hand.
