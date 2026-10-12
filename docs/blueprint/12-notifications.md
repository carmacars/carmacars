# 12. Notifications

Owner: workstream F (`src/features/notifications/`, `supabase/functions/send-outbox/`), with the `messaging` integration from workstream A. The templates are in `/emails` (116 emails, catalogue at `emails/catalogue.json`, engine at `emails/src/engine.mjs`).

The owner's requirement: every actionable customer event results in an email (account creation, request to book, confirmation or adjustment, receipt, booking reminder, pickup details, check-in, return details, review request, come-back discount after 1 week and after 1 month, and more). Owners get billing and monthly statement emails. Admins and staff get theirs.

Constraints: email only, no SMS. Resend free plan: 100 emails a day and 3,000 a month, sent from `carmacars.ca`, replies to `info@carmacars.ca`. So staff notices are digested and sending is rationed by priority.

**The event key is the catalogue code.** `emit('renter_offer_ready', payload)` sends the email whose `code` is `renter_offer_ready`. Section 3 maps every catalogue code to the action, database function or job in this blueprint that fires it. Section 4 lists where the catalogue and the database disagree, and the events this blueprint needs that have no template yet.

## 1. How a notification is produced

```
 server action or SQL function  --emit(code, payload)-->  notification_outbox (same transaction)
                                                               |
 pg_cron every minute --> Edge Function send-outbox:  choose by priority within the daily budget
                                                      fill the template with emails/src/engine.mjs, send through Resend
                                                      write messages (the permanent log)
                                                      create the in-app notice
 Resend webhook --> delivery, bounce, complaint --> messages.status, email_suppressions
```

| Piece | Design |
| --- | --- |
| `emit()` | `src/features/notifications/emit.ts` on the server and `app.emit_event(p_code text, p_payload jsonb, p_recipient uuid, p_dedupe text)` **[new]** in SQL, so jobs and triggers use the same path. The set of valid codes is a TypeScript union generated from `emails/catalogue.json` plus the in-app-only codes of section 4.3; an unknown code fails the build and is rejected at run time |
| Payload | Exactly the names in the catalogue entry's `variables` (plus the two globals, `support_phone` and `company_address`, read from `program_settings`). Values follow the catalogue's conventions: money already formatted (`$468.95`), dates as `Fri, Oct 23, 2026`, times as `10:00 am` Toronto time, lists as arrays of objects, links as full https URLs. A builder per code (`src/features/notifications/payloads/<code>.ts`) turns database rows into these values; a test renders every code from a fixture through the engine, which throws on a missing value, so a half-filled email cannot be sent |
| Outbox | `notification_outbox` **[new]**: `id, code, category ('transactional', 'marketing'), priority (1 to 5), audience, recipient_user_id, recipient_email, recipient_name, payload jsonb, attachments jsonb (document ids), dedupe_key unique, send_after, status ('queued', 'sending', 'sent', 'failed', 'suppressed', 'cancelled', 'digested'), attempts, last_error, message_id, created_at, sent_at` |
| Digest queue | `staff_digest_items` **[new]**: `id, role, code, line, url, entity_table, entity_id, created_at, digest_outbox_id`. A staff notice whose catalogue entry has `digest: true` writes a row here instead of the outbox, unless its immediate exception applies (section 5) |
| Dedupe | `dedupe_key` = code plus the entity id plus a version (for example `renter_offer_ready:{booking}:{offer_version}`). A retried action or a job run twice cannot send twice |
| Log | Every sent email becomes a `messages` row (`direction = 'outbound'`, `channel = 'email'`, `template_code`, `subject`, `body` as rendered text, `to_address`, links to renter, owner, booking, vehicle, `provider = 'resend'`, `provider_ref`, `status`). `messages` cannot be deleted. `message_templates` gets one row per catalogue code so the foreign key holds |
| From and reply-to | From the catalogue entry: `bookings@`, `owners@`, `billing@` or `hello@` at `carmacars.ca`, display name CarmaCars; reply-to `info@carmacars.ca`. A reply reaches the staff mailbox; staff log important replies on the record (`messages`, `direction = 'inbound'`). A cancellation received by email is logged with its received time by CS (procedure 7) |
| Documents | Where the copy links a record (`signed_agreement_url`, `receipt_url`, `statement_url`, `supporting_document_url`), the value is a signed file link valid for 7 days, as the templates' copy states. ID images are never linked or attached |
| Links | Section 4.4 is the link contract: every path in `emails/src/links.mjs` must resolve. `verify_url`, `reset_url` and `sign_in_url` come from the sign-in service; `unsubscribe_url` is the one-click link per recipient |
| Marketing headers | For a `marketing` email the sender also sets `List-Unsubscribe` and `List-Unsubscribe-Post` to the same `unsubscribe_url` |
| No tracking | No tracking pixels and no click-tracking redirects |
| Sign-in emails | Supabase Auth is configured with custom SMTP through the same Resend account and with its email templates replaced by `account_sign_in_link` and `account_password_reset`. They count toward the daily limit; the sender reserves 10 a day for them |
| Failures | Three attempts with backoff (1, 5, 30 minutes). A hard bounce marks the outbox row `failed`, writes `email_suppressions`, and creates a `cs` task "Email to [name] bounced: confirm the address" for booking-critical codes |

## 2. Rationing 100 emails a day

Order when the cap is close, from the emails README, with the rest held for the next day:

| Priority | What | Rule |
| --- | --- | --- |
| 1 | Safety and late-return emails: `renter_late_return_first`, `renter_late_return_final`, `renter_vehicle_disabled`, `renter_accident_instructions`, `renter_breakdown_help`, and their staff alerts | Always sent at once. If the count has reached 100 they are the first out after midnight and the admins are alerted in the app immediately |
| 2 | Offers and confirmations: sign-in links, `renter_request_received`, `renter_offer_ready`, `renter_booking_confirmed`, `renter_agreement_ready`, cancellations, pickup and return details | Sent at once |
| 3 | Money: statements, extra charges, receipts, refunds, payment failures, owner invoices, statements and payouts | Sent at once while today's count is under 90 |
| 4 | Staff immediate notices; then staff digests | Immediate ones at once while under 95; digests at their times |
| 5 | Marketing: `renter_review_request`, `renter_comeback_1w`, `renter_comeback_1m` | Between 10:00 and 16:00 Toronto time, at most 15 a day, and only while today's count is under 60. Unsent ones roll to the next day; one older than 5 days is cancelled |

The sender counts outbox rows sent since Toronto midnight, and the calendar month against 3,000. At 80 in a day or 2,400 in a month it raises the in-app notice `staff_email_quota_warning` (no email is spent to say emails are running out). The admin dashboard shows today's count. Expected volume at 50 bookings a month, from the emails README: about 25 renter emails, 5 owner emails, 16 staff digests and 10 immediate staff notices a day, near 55, with the 10th and the 15th as the busy days. The paid tier (US$20 a month) is the first fixed fee worth buying if volume doubles.

Deliberate savings already in the catalogue: `renter_booking_confirmed` carries the receipt for the booking payment, so `renter_payment_receipt` is not sent for it; `renter_return_reminder` carries the return details, so `renter_return_details` is sent only if they change afterwards; `renter_identity_needed` is skipped when the confirmation email carried the notice. Stripe's own receipt emails are turned off in the Stripe dashboard so customers do not get two receipts (this changes `docs/setup.md` section 4 step 5).

## 3. Event to email map

Every catalogue code, and what fires it. "Job" names are the scheduled jobs in `docs/architecture.md` section 5 plus those added by this blueprint. D = digested by default.

### 3.1 Account (2)

| Code | Fired by |
| --- | --- |
| `account_sign_in_link` | Supabase Auth magic link event; also the invitation when an admin creates an owner, investor or staff account (`inviteStaff`, `inviteInvestor`), and the `/go/` expired-link fallback |
| `account_password_reset` | Supabase Auth recovery event |

### 3.2 Renter (45)

| Code | Fired by (action -> database) | Timing |
| --- | --- | --- |
| `renter_account_created` | `submitBookingRequest` or sign-up, when the user row is new | At once |
| `renter_request_received` | `submitBookingRequest` -> `app.request_booking()` | At once |
| `renter_request_needs_info` | `sendBookingMessage` on a `requested` booking (the staff question fills `info_request`). There is no `needs_info` status; see 4.1 | At once |
| `renter_request_declined` | `declineRequest` -> `app.decline_booking_request()` by staff | At once |
| `renter_offer_ready` | `sendOffer` -> `app.send_offer()`, for the first and every later version; also when `app.apply_promo_code()` issues a new version on an open offer | At once |
| `renter_offer_reminder` | Job `reminders`: 6 hours before `offer_expires_at` (halfway for a window under 12 hours), status still `offered` | Once per offer |
| `renter_offer_expired` | `app.job_offers_expire()` writes a `booking_events` row of kind `offer_expired`; a trigger on that insert emits | At once |
| `renter_offer_withdrawn` | `withdrawOffer` -> `app.withdraw_offer()`; or the system pushing a booking back when another booking took the car (`booking_events.kind = 'pushed_back'`) | At once |
| `renter_change_request_received` | `requestOfferChange` -> `app.request_offer_change()` on an offered booking; `requestDateChange` on a confirmed booking (`booking_change_requests` **[new]**) | At once |
| `renter_change_request_approved` | A change to a confirmed booking is applied (`app.apply_booking_change()` **[new]**) | At once |
| `renter_change_request_declined` | `declineChangeRequest` | At once |
| `renter_agreement_ready` | A signature request is opened for someone who is not in the middle of checkout: each additional driver after the renter signs; the renter when the agreement is reissued (a staff-proposed change, an extension that needs re-signing, a renewal) | At once |
| `renter_agreement_signed` | The signature request completes (`app.complete_signature_request()` **[new]**); to the renter and each additional driver who signed | At once |
| `renter_payment_failed` | Stripe webhook `payment_intent.payment_failed`. `is_booking_payment = true`: checkout for an offer, no fee. `false`: a Card on File charge declined, with the $40 fee (T10) | At once |
| `renter_booking_confirmed` | Stripe webhook -> `app.record_booking_payment()` **[new]** -> status `confirmed`; or `confirmInsurerBooking` when the renter owes nothing at booking | At once |
| `renter_identity_needed` | On confirmation if not carried by the confirmation email; job `reminders` 48 hours before pickup if anything is missing | |
| `renter_identity_approved` | `verifyDriver` or `confirmCoverage`, whichever completes the set (T4) | At once |
| `renter_identity_rejected` | `rejectDriver`, `rejectCoverage` | At once |
| `renter_booking_reminder` | Job `reminders`: confirmed and pickup 24 hours away (T5) | Once |
| `renter_pickup_details` | Job `reminders`: 3 hours before pickup when the field job has an assignee; at once if assigned inside the window; again if place, time or staff member changes (`reassignFieldJob`, `createFieldJob`) | |
| `renter_rental_started` | `completeHandover` -> `app.complete_handover()` **[new]** -> `on_rent` | At once |
| `renter_return_reminder` | Job `reminders`: `on_rent` and return 24 hours away (T6); again after an extension moves the return | |
| `renter_return_details` | Return field job changed after the reminder, or first assigned inside the last 24 hours | At once |
| `renter_extension_requested` | `requestExtension` | At once |
| `renter_extension_approved` | `approveExtension` (payment still outstanding) | At once |
| `renter_extension_confirmed` | Stripe webhook for the extension payment: `booking_extensions.status = 'confirmed'` (T11) | At once |
| `renter_extension_declined` | `declineExtension` | At once |
| `renter_late_return_first` | Job `late-returns`, 0 minutes late (T13) | Once |
| `renter_late_return_final` | Job `late-returns`, 2 hours late (T14); sets `tracker_commands.notice_sent_at` when a disable is later requested | Once |
| `renter_vehicle_disabled` | Tracker webhook confirms an approved engine disable (T15) | At once |
| `renter_accident_instructions` | `createIncident` of kind accident, theft or vandalism on an `on_rent` booking (T16) | At once |
| `renter_breakdown_help` | `dispatchRoadside` on a breakdown incident (T18) | At once |
| `renter_return_complete` | `completeReturn` -> `app.complete_return()` **[new]** -> `returned` | At once |
| `renter_damage_found` | `reportDamageToRenter` within 48 hours of Check-in (T8) | At once |
| `renter_final_statement` | `issueBookingStatement` with `kind = 'check_in'` (T9) | At once |
| `renter_extra_charge` | `chargeTollTicket`, `chargeDamage`, or a later charge line added by Finance (T19) | When the charge is taken |
| `renter_deposit_released` | `approveDepositRelease` or the hold-back applied | At once |
| `renter_payment_receipt` | Any renter charge or capture succeeds except the one that confirms a booking | At once |
| `renter_refund_issued` | Stripe webhook: refund paid (`refunds.status = 'paid'`), unless a cancellation email in the same hour reported it | At once |
| `renter_balance_overdue` | Job `reminders` daily: a statement 7 days old with a balance; then with each monthly interest posting on the 1st (`month-open`) | |
| `renter_booking_cancelled` | `cancelBooking`, `cancelBookingForRenter`, `markNoShow` (T12) | At once |
| `renter_booking_cancelled_by_us` | `cancelBookingByCompany` | At once |
| `renter_review_request` | Job `followups` daily 10:00: 2 days after `closed`, conditions in section 7 | Marketing category |
| `renter_comeback_1w` | Job `followups`: 7 days after `closed`, conditions in section 7; creates the promo code at send time | Marketing |
| `renter_comeback_1m` | Job `followups`: 30 days after `closed` | Marketing |

### 3.3 Owner (24)

| Code | Fired by | Timing |
| --- | --- | --- |
| `owner_account_created` | `submitOwnerIntake` (new user) or an admin adding an owner | At once |
| `owner_application_received` | `submitOwnerIntake`, `submitVehicleIntake` (`vehicle_onboardings` at `intake`) (T20's acknowledgement) | At once |
| `owner_application_declined` | `declineVehicle` | At once |
| `owner_agreement_ready` | `prepareOwnerDocuments`: onboarding `documents_sent` (the email also presents the terms set for the vehicle) | At once |
| `owner_agreement_signed` | Onboarding `documents_signed` | At once |
| `owner_upfront_invoice` | `app.issue_upfront_invoice()` after `documents_signed` | At once |
| `owner_payment_received` | An owner invoice becomes `paid` (debit cleared, card, e-Transfer recorded) | At once |
| `owner_onboarding_steps` | Onboarding `upfront_paid` (or from `documents_signed` for a shareholder-owned vehicle): the steps and pre-filled forms for the vehicle's method | At once |
| `owner_registry_visit` | `scheduleRegistryVisit` and any change to it (T21) | At once |
| `owner_document_due` | Job `expiry-watch` daily 06:00: plate renewal or a Turo-Only owner's insurance proof 14 days out, again at 3 days (T23). This blueprint also needs the safety certificate 7 days before it expires (4.2) | |
| `owner_vehicle_enrolled` | `confirmEnrollment`: onboarding `enrolled` (T22, the written confirmation) | At once |
| `owner_vehicle_listed` | `publishListing` -> `app.publish_listing()` **[new]** | At once |
| `owner_new_booking` | A standard or non-refundable booking on the owner's vehicle becomes `confirmed` (renter contact details only when Self-Managed) | At once |
| `owner_booking_confirmed` | An Owner Booking becomes `confirmed` | At once |
| `owner_incident_opened` | An incident or claim is opened on a third-party owner's vehicle (T17) | The same day |
| `owner_incident_update` | `setClaimStatus`, or an incident event marked visible to the owner | At once |
| `owner_fee_invoice` | Job `owner-billing` on the 15th; one email per vehicle (T24) | |
| `owner_payment_failed` | Job `debit-results`: invoice `failed` (T25) | |
| `owner_in_arrears` | Job `debit-retry`: invoice `in_arrears` | |
| `owner_statement_ready` | The statement is issued to the owner on the 10th: `approveStatement` has run and the payout run is released (T26, statement part) | |
| `owner_payout_sent` | `markPayoutPaid` for an owner payout (T26, payout part); not sent when the statement shows a balance owing | |
| `owner_toll_ticket` | `billTollToOwner` (`is_forwarded = false`) or `forwardTollToOwner` (`true`) | At once |
| `owner_exit_notice_received` | `giveExitNotice`, or an admin's removal decision: vehicle `exit_notice`, confirming the Exit Date | At once |
| `owner_exit_completed` | Vehicle `exited` (Form E signed) | At once |

### 3.4 Investor (3)

| Code | Fired by |
| --- | --- |
| `investor_statement_ready` | `generateInvestorStatement` or the `investor-statements` job |
| `investor_return_paid` | `markPayoutPaid` for a payout of kind `investor_return` |
| `investor_notice_received` | An admin logs a notice (election change, bank change, contact change); also sent when an investor submits a request from `/investor/profile` and the admin records it |

### 3.5 Staff (42)

| Code | Fired by | Delivery |
| --- | --- | --- |
| `staff_booking_request_new` | `app.request_booking()` | At once to every active CS VA; never batched |
| `staff_request_waiting` | Job every 5 minutes: `requested` for over 2 hours with no offer, question or decline | At once to CS and both admins, once per request |
| `staff_change_request_received` | `requestOfferChange`, `requestDateChange` | D; at once if pickup is within 48 hours or the booking is `on_rent` |
| `staff_offer_approved_paid` | Booking `confirmed` | D to CS and Fleet; at once if pickup is within 24 hours |
| `staff_identity_review` | `submitVerification` | D; at once if pickup is within 48 hours |
| `staff_extension_requested` | `requestExtension` | At once |
| `staff_review_received` | `submitReview` | D; at once for 2 stars or lower |
| `staff_cancellation_received` | A `booking_cancellations` row | D to Finance and CS; at once to admins when approval is needed |
| `staff_payment_failed` | A Card on File charge is declined | D; at once at 24 hours unpaid during a rental |
| `staff_return_findings` | `submitFindings` (T7) | D to Finance the same day; at once to admins when there is damage |
| `staff_toll_ticket_logged` | `createTollTicket`, `importTollBatch` after matching | D |
| `staff_toll_ticket_unmatched` | Daily 06:00: no match for 2 business days | D, morning |
| `staff_owner_invoice_failed` | Invoice `failed` or `in_arrears` | D; `in_arrears` also at once to admins |
| `staff_payouts_due` | Job `payouts` on the 10th at 08:00 and on the 15th for investor returns | At once to admins and Finance |
| `staff_statements_ready_for_approval` | `app.job_statements_draft()` on the 5th; reminder on the 8th | At once to admins |
| `staff_approval_needed` | An approval task is raised (refund outside the table or over the limit, deposit release with a hold-back, price override, fee off the grid, an escalated task) | D; at once if due within 4 hours |
| `staff_disable_approval_needed` | `requestTrackerCommand` for an engine disable | At once to both admins |
| `staff_dispute_opened` | Stripe webhook creates a `disputes` row | At once to admins and Finance |
| `staff_incident_reported` | An incident of kind accident, theft, vandalism or damage is created | At once to admins and Fleet |
| `staff_breakdown_reported` | A breakdown incident is created | At once to the on-call Fleet person |
| `staff_late_return_alert` | Job `late-returns` at 0 and 30 minutes (Fleet) and 2 hours (Fleet and admins) | At once |
| `staff_exit_notice_received` | Vehicle `exit_notice` | D; at once to admins if the fleet would fall below 10 |
| `staff_expiry_watch` | Job `expiry-watch` | D, morning; own email when an item is within 3 days |
| `staff_fleet_count_warning` | `app.job_fleet_recount()` Monday 08:00, or at once on an exit notice that takes the count to 11 or fewer | At once |
| `staff_listing_ready_for_review` | The listing job reaches `needs_review` | D to Fleet |
| `staff_owner_application_received` | `submitOwnerIntake` | At once to every active Sales VA (to CS when no Sales VA is active) |
| `staff_job_failed` | A `job_runs` row is marked failed | At once to both admins, once per job per day |
| `staff_weekly_summary` | Monday 07:45 | To both admins |
| `staff_field_job_assigned` | `createFieldJob`, `reassignFieldJob`, a re-shoot or retake request | At once to the assignee |
| `staff_field_job_changed` | A job's time, place or vehicle changes, or it is cancelled or reassigned | At once to the person who held it |
| `staff_field_jobs_today` | Daily 07:00 to each field staff member with a job that day | |
| `staff_field_jobs_tomorrow` | Daily 18:00 to each field staff member with a job the next day | |
| `staff_digest_morning_admin`, `_va_finance`, `_va_fleet`, `_va_cs`, `_va_sales` | Daily 07:30, always sent, so a missing digest is itself a warning | Carries queued notices plus the standing lists named in each template's trigger |
| `staff_digest_eod_admin`, `_va_finance`, `_va_fleet`, `_va_cs`, `_va_sales` | Daily 18:15, after the 18:00 reconcile job; skipped when empty | |

## 4. Where the catalogue, the database and this blueprint differ

### 4.1 Catalogue triggers that name things the database does not have

| Catalogue assumes | Database today | Resolution (the app fires the same code from the equivalent event) |
| --- | --- | --- |
| A `needs_info` booking status | No such status in migration 0016 | `renter_request_needs_info` fires when staff send a question on a `requested` booking (`sendBookingMessage` with "needs an answer" ticked). The booking stays `requested`; a flag `bookings.awaiting_renter_since` **[new]** drives the "waiting on the renter" list in the CS digest and stops the 2-hour `staff_request_waiting` clock |
| Booking status `expired` after an offer lapses | An expired offer puts the booking back to `requested`; the offer row becomes `expired` and a `booking_events` row of kind `offer_expired` is written | Fire `renter_offer_expired` from that event |
| "Booking status stays offered" until payment | Approval moves the booking to `pending_payment`; payment then confirms | Payload builders treat `offered` and `pending_payment` as "offer open" for `renter_payment_failed` and the digest lists |
| A booking change request row | No table | `booking_change_requests` **[new]** (`03-admin.md` section 4.5): one table for a renter's request and a staff proposal, with statuses `requested`, `proposed`, `approved`, `declined`, `applied` |
| Extension status `approved` | `booking_extensions.status` allows `requested`, `confirmed`, `declined`, `lapsed` | Add `approved` to the check and transitions |
| Owner statement status `issued` | `owner_statements.status` allows `draft`, `approved`, `paid`, `void` | Fire `owner_statement_ready` when the payout run is released on the 10th for an approved statement; add `owner_statements.sent_at` use (the column exists) as the idempotency mark |
| Incident `dispatched_at` | Not a column | Add `incidents.roadside_dispatched_at`, or use an `incident_events` row of kind `roadside` |
| Refund status `succeeded` | `refunds.status` uses `paid` | Fire on `paid` |
| "Marketing consent is true" for the come-back emails | `users.marketing_opt_in` and `consents` | Section 7 |
| Verification "pending review" | `identity_verifications.status = 'pending'` | Same thing |
| `staff_listing_ready_for_review` fires when "the vehicle status becomes ready_to_list" | `ready_to_list` is set by enrollment, not by the listing pipeline | Fire it when the listing job reaches `needs_review` (`09-listing-pipeline.md` section 5.2) |
| One `owner_fee_invoice` email per vehicle | Invoices are per vehicle | An owner with many vehicles gets many emails on the 15th. Kept as written; if the daily cap bites, combine per owner (a template change for the writer) |

### 4.2 Emails this blueprint needs that the catalogue does not have yet

To be added by the writer in the same format. Until each exists, the event creates the in-app notice only, and staff send the message by hand from the record where a customer must be told.

| Proposed code | Audience | Trigger | Why it is needed | Priority |
| --- | --- | --- | --- | --- |
| `renter_deposit_declined` | Renter | `takeDeposit` fails at pickup | The car cannot be released; the renter must fix the card now | Before launch |
| `renter_named_to_authority` | Renter | An admin names the renter to a toll or ticket authority | The renter must be told, with the notice | Before launch |
| `owner_fee_change_notice` | Owner | A fee notice is issued | Fee changes need 30 days' written notice (Enrollment Agreement 4.6) | Before the first fee change |
| `owner_bank_details_changed` | Owner | An admin changes payout bank details | Fraud control: notice to the old and new contact details | Before launch |
| `account_security_notice` | Any account | Password, email or two-step sign-in changed | Account takeover warning | Before launch |
| `staff_security_alert` | Admins | Staff sign-in from a new device, repeated failed codes, a role grant, a bank detail change | `13-security.md` section 4 | Before launch |
| `insurer_invoice`, `insurer_invoice_reminder` | Insurer (a new audience) | `sendInsurerInvoice`; 7 and 21 days after sending while unpaid | Insurer billing | With the insurer feature |
| `franchisor_fleet_report` | Franchisor, copy to admins | `sendFleetReport` on the 1st | Procedure 20 | Before November 1 |
| `staff_monthly_statements_ready` | Admins | The company statements are finalized on the 10th | Owner requirement 10 | Before November 10 |
| `renter_agreement_reminder` | Additional driver | 48 hours before pickup, not yet accepted | The driver cannot drive otherwise | Soon after launch |
| `renter_request_withdrawn` | Renter | The renter withdraws a request or declines an offer | Confirmation of their own action | Soon after launch |
| `owner_listing_changes_requested` | Owner | Staff ask an owner to retake listing photos | Only when owners shoot their own photos | Later |
| `owner_application_reminder` | Owner | Intake draft untouched for 24 hours | Recovery of abandoned applications | Later |
| `investor_return_held`, `investor_redemption_notice` | Investor | A return is held; a redemption notice is issued | `07-investor.md` | With the investor area |
| `enquiry_received` | Visitor | Contact or insurer enquiry form | Acknowledgement | Later |
| `renter_renewal_reminder`, `renter_card_expiring`, `renter_mid_rental_checkin` | Renter | Long rentals nearing 30 days; card expiring before a booking; day 2 of a long rental | Useful, not essential | Later |
| An extension of `owner_document_due` | Owner | Safety certificate 7 days from expiry with no registry visit done | The 36-day window | Before launch |

### 4.3 In-app notices with no email

These codes are valid for `emit()` and create only an in-app notice (and, for staff, a digest line): `owner_rental_started`, `owner_rental_ended`, `owner_booking_changed`, `owner_booking_cancelled`, `owner_vehicle_blocked`, `owner_kickback_earned`, `owner_deduction_added`, `owner_prepaid_refund`, `renter_review_published`, `staff_handover_done`, `staff_offer_declined`, `staff_offer_expired`, `staff_vehicle_listed`, `staff_enquiry_received`, `staff_email_quota_warning`. An owner sees them on the portal home; deductions and prepaid refunds also appear on the statement.

### 4.4 The link contract

Every path in `emails/src/links.mjs` must open the right screen, after sign-in where needed, with a return to the same path. The portals therefore use the same identifiers the emails use: **bookings by booking number** (`CC-10482`), invoices by invoice number, statements by statement number, incidents by incident number, vehicles and jobs by id. Where this blueprint's route differs from the email's path, the email's path is added as a route that redirects (HTTP 307) to the blueprint route. The link checker (`15-test-plan.md` section 3) loads `links.mjs` and fails on any path that does not resolve.

| Email path | Blueprint route |
| --- | --- |
| `/account/bookings/{booking_number}` , `/offer`, `/verify`, `/extend`, `/pay`, `/review` | Same |
| `/account/bookings/{n}/request` | The booking page while `requested` (section "Progress") |
| `/account/bookings/{n}/agreement` | `/account/bookings/{n}/sign` (and the additional driver's acceptance screen for a driver) |
| `/account/bookings/{n}/pickup`, `/return` | Anchors on the booking page: Pickup details, Return details |
| `/account/bookings/{n}/condition-report` | The Documents section of the booking page; `/photos` when the renter must upload a set |
| `/account/bookings/{n}/change` | `/account/bookings/{n}/cancel` and the change-request form on the same route group |
| `/account/bookings/{n}/statement` | `/account/statements` filtered to the booking |
| `/account/bookings/{n}/incident` | "Report a problem" on the booking page |
| `/terms#cancellation` | `/cancellation-policy` (the anchor exists on `/terms` and links there) |
| `/owner/application` | `/owner/onboarding` |
| `/owner/agreements` | The documents step of the vehicle in progress; `/owner/documents` when none |
| `/owner/billing` | `/owner/invoices` |
| `/owner/vehicles/{id}/onboarding`, `/calendar`, `/exit` | `/owner/onboarding/{id}`, the Calendar tab, the Leaving tab |
| `/owner/bookings/{n}`, `/owner/invoices/{n}`, `/owner/statements/{n}`, `/owner/claims/{n}` | Detail panels of the matching lists |
| `/admin/fleet` | `/admin/vehicles` |
| `/admin/disputes/{id}` | `/admin/money/disputes?panel={id}` |
| `/admin/incidents/{n}`, `/admin/approvals`, `/admin/statements`, `/admin/payouts`, `/admin/jobs` | Same |
| `/admin/reports/weekly` | `/admin/reports?view=weekly` |
| `/va/cs/bookings/{n}`, `/identity` | The booking review screen and its Drivers tab in the CS portal |
| `/va/cs/reviews`, `/va/finance/bookings/{n}`, `/va/fleet/bookings/{n}`, `/va/fleet/vehicles/{id}` | Same components under the VA portal |
| `/va/finance/tolls-tickets/{id}` | `/va/finance/tolls?panel={id}` |
| `/va/finance/owner-invoices/{n}` | The owner invoice panel |
| `/va/fleet/listings/{vehicle_id}` | The listing review screen |
| `/va/fleet/expiries` | A Fleet list of items from the `expiry-watch` job |
| `/va/sales/applications/{id}` | The owner intake record (the vehicle onboarding id) |
| `/field`, `/field/jobs/{id}` | Same |

## 5. Staff digests

| Rule | Detail |
| --- | --- |
| Times | Each role has a morning digest at 07:30 (always sent) and an end-of-day digest at 18:15 (skipped when empty), Toronto time. Field staff get today's jobs at 07:00 and tomorrow's at 18:00 |
| Contents | Every `staff_digest_items` row for the role since the last digest, plus standing lists computed at send time and named in each template's trigger (for CS: requests waiting for an offer, requests waiting on the renter, open offers and their expiry, documents to review, change requests, tomorrow's pickups with verification incomplete, reviews to moderate, bookings confirmed since the last digest) |
| Always immediate | New booking request, request waiting over 2 hours, extension request, late return, disable approval, incident, breakdown, dispute, job assigned or changed, owner application, failed scheduled job |
| Conditional immediate | Each digested notice's own exception from section 3.5 (for example pickup within 24 or 48 hours) |
| In the app | Every staff event also creates an in-app notice at once (section 6), so a VA on shift does not wait for the digest |
| Privacy | A digest line carries a first name and a booking number at most, and a link |
| Jobs | `app.job_staff_digests()` **[new]** at 07:30 and 18:15, `app.job_field_digests()` **[new]** at 07:00 and 18:00, both through the hourly Toronto-time pattern of migration 0015 |

## 6. In-app notices

| Item | Design |
| --- | --- |
| Table | `notifications` **[new]**: `id, user_id, code, title, body, link, entity_table, entity_id, priority, read_at, created_at`. A user reads only their own rows |
| Delivery | Supabase Realtime on the user's rows; the bell in the header shows the unread count; the list groups by day |
| Staff | Priority 1 notices also show as a banner until opened and play a sound if the staff member turned sounds on |
| Customers | The portal home's "Next step" card is driven by the same events, so the email and the portal always agree |
| Retention | Read notices are deleted after 90 days by the `retention` job |
| Push | No web push at launch. Field staff rely on the two daily emails, the immediate job emails and in-app notices; Fleet phones for changes inside 2 hours |

## 7. Marketing emails and Canada's anti-spam law

Three emails are in the `marketing` category: `renter_review_request`, `renter_comeback_1w`, `renter_comeback_1m`. Booking, payment, safety and account emails are not marketing and are always sent (privacy policy section 11).

### 7.1 Consent rules

| Rule | Implementation |
| --- | --- |
| Express consent | The optional, unticked box at request and in account settings, with the wording from Part 4 of the website policies, naming the sender (18122211 Canada Inc., operating as CarmaCars), its address and contact, and saying consent can be withdrawn. Stored in `consents (consent_code = 'marketing', text_version, text_shown, given_at, ip_address)`, `users.marketing_opt_in`, `marketing_opt_in_at`. It does not expire until withdrawn |
| Implied consent | An existing business relationship: the renter completed a paid rental. Government guidance states that this kind of implied consent may be valid for up to 2 years, and 6 months after an inquiry or application ([Government of Canada, CASL guidance](https://ised-isde.canada.ca/site/canada-anti-spam-legislation/en/node/7)) |
| `renter_comeback_1w`, `renter_comeback_1m` | Sent only with **express** consent (`users.marketing_opt_in = true`), as the catalogue specifies. This is the cautious reading and the default. Extending them to renters with implied consent only is the owner's choice (`99-traceability.md`); the conditions and the proof table below already support it |
| `renter_review_request` | Sent under the existing business relationship (implied consent, at most 24 months after the rental), as the catalogue specifies, so it carries the unsubscribe link and mailing address and respects an unsubscribe. It contains no offer or discount |
| Other conditions on all three | Booking `closed`; not unsubscribed; not in `email_suppressions`. Come-backs also: renter not blocked, no unpaid balance, no future booking or open request (1 week), no booking or request since (1 month). Review request: no review exists yet; while an incident, dispute or unpaid balance is open on the booking the request is **held, then sent when it closes** (it is not skipped, so that critical customers are asked too; see `14-seo.md` section 15) |
| A person who only enquired or requested | Receives no marketing without express consent |
| Proof | Each marketing send writes `marketing_sends` **[new]**: `user_id, code, consent_basis ('express', 'implied_purchase'), basis_date, basis_expires_on, booking_id, promo_code_id, outbox_id, sent_at`. The sender must be able to prove consent, so the basis is stored per message |
| Content | The sender's name (CarmaCars, operated by 18122211 Canada Inc.), a current mailing address and a phone number, email or web address, and an unsubscribe mechanism: the requirements in the same government guidance. The templates take `company_address` and `support_phone` as global variables; the sender refuses to send a marketing email while `program_settings.company_address` is empty (the catalogue's sample still reads "Mailing address to be confirmed") |
| Unsubscribe | Footer link plus `List-Unsubscribe` and `List-Unsubscribe-Post` headers. The guidance allows 10 business days to act; the platform acts at once. Tokens do not expire, so the link works for well over 60 days after sending |
| Owners, investors, staff | Receive no marketing emails. Investor emails are neutral servicing notices and carry the line that they are not an offer or a solicitation (the email checker enforces it) |
| Third parties | No addresses are bought, shared or imported. CarmaCars does not email a friend on anyone's behalf |
| Reviews and incentives | The review request offers nothing for a review, and the come-back discount goes to every eligible renter whether or not they reviewed (`14-seo.md` section 15) |

### 7.2 The come-back offers

| Item | 1 week | 1 month |
| --- | --- | --- |
| Scheduled by | `app.job_followups()` **[new]**, daily 10:00: selects eligible bookings closed 7 days ago, creates a `promo_codes` row for that renter (`source = 'followup_7d'`, `renter_id` set, `once_per_renter`, `max_uses = 1`, `valid_until` 30 days out) and the outbox row | Same with `source = 'followup_30d'`; skipped if the first code was used |
| Offer | A percentage off the rental charge of the next booking: `program_settings.comeback_1w_bps` and `comeback_1m_bps` **[new]** (recommended 10% and 15%) | |
| How it applies | `app.apply_promo_code()` at request or on an open offer. The discount comes off the rental charge only, after the non-refundable and staff discounts; one code per booking | |
| Who bears it | As migration 0016 ships, a discount lowers Owner Revenue, so the owner and CarmaCars share it in the proportion of the split, and on a Self-Managed vehicle the owner bears all of it. That is an open question for the owner (`99-traceability.md`); the recommended default is that CarmaCars absorbs its own promotions | |
| Frequency cap | At most the review request and these two per completed rental, and at most one marketing email per renter in any 7 days | |

### 7.3 Unsubscribe handling

| Step | Detail |
| --- | --- |
| One-click | A POST from the mail client to `/unsubscribe/[token]`, or the visitor opening the link: `users.marketing_unsubscribed_at = now()`, `users.marketing_opt_in = false`, `consents.withdrawn_at` on the marketing consent, an `email_suppressions` row with `reason = 'unsubscribed'`, queued marketing rows for that user set to `cancelled` |
| Scope | The three marketing emails only. The page and the footer say that booking, payment and safety messages continue |
| Complaints | A spam complaint from Resend's webhook is treated as an unsubscribe and creates an admin notice |
| Hard bounces | The address is suppressed for all categories and a `cs` task asks for a corrected address |
| Re-subscribe | Only by a fresh express consent in account settings |
| Staff view | `/admin/renters/[id]` shows the marketing status, the basis, its expiry and the history of sends |
| Records | `consents`, `marketing_sends` and `email_suppressions` are kept while the address is on file and for 3 years after the last message |

## 8. Preferences

| Audience | Can turn off | Cannot turn off |
| --- | --- | --- |
| Renter | The three marketing emails | Everything about a booking, money, safety, identity or account security |
| Owner | `owner_new_booking` (falls back to in-app) | Invoices, payment failures, statements, payouts, incidents, registry, enrollment, fee notices, exit |
| Staff | Sounds | Digests and immediate notices |
| Investor | Nothing | Statements and notices |

Stored in `notification_preferences` **[new]** (`user_id, code_group, email boolean, in_app boolean`).

## 9. Testing and operations

| Topic | Detail |
| --- | --- |
| Template checks | `node emails/check.mjs` (14 checks: dashes, banned words, one primary button, links only from `links.mjs`, brand spelling, no provider named) runs in CI with the app's own copy lint |
| Payload checks | Every code renders from a fixture through the engine in CI; the engine throws on a missing variable |
| Coverage check | CI fails if a code is emitted in `src/` and is neither in the catalogue nor in the in-app-only list, and reports catalogue codes that nothing emits |
| Staging | The messaging adapter in staging rewrites every recipient to a test inbox unless the address is on an allow-list. Production keys never exist in staging |
| Previews | `/admin/messages` previews any template with a real record's payload, in phone and desktop widths, HTML and text, using the catalogue's `preheader` for the inbox line |
| Deliverability | SPF and DKIM on `carmacars.ca`, a DMARC record on the subdomain, the four sender addresses verified, plain-text parts, no link shorteners |
| Clock | All scheduled sends use Toronto time through `app.local_date()` and `app.local_hour()` |
| Monitoring | A priority 1 or 2 outbox row older than 15 minutes raises `staff_job_failed`. A daily count by code is on `/admin/messages` |

## 10. Database additions needed

| Addition | Purpose |
| --- | --- |
| `notification_outbox`, `staff_digest_items`, `notifications`, `notification_preferences`, `marketing_sends`, `email_suppressions`, each with row-level security and an audit trigger where it records consent | The notification system |
| `app.emit_event()`; triggers that emit from `booking_events` (offer expired, pushed back), `status_history` (booking, vehicle, onboarding, invoice, claim changes) and `job_runs` failures | Events raised by the database |
| Jobs: `reminders` (offer reminder, identity needed, booking reminder, pickup details, return reminder, balance overdue), `late-returns`, `followups`, `expiry-watch`, staff and field digests, `staff_request_waiting` check; `pg_cron` schedule for `send-outbox` every minute | Schedules |
| One `message_templates` row per catalogue code; `audience` values extended to match the catalogue; a `category` column | The log's foreign key |
| `bookings.awaiting_renter_since`; `booking_change_requests`; `booking_extensions.status` value `approved`; `incidents.roadside_dispatched_at` | Section 4.1 |
| `program_settings`: `comeback_1w_bps`, `comeback_1m_bps`, `marketing_daily_cap`, `email_daily_limit`, `email_monthly_limit`, `support_phone` (or use `company_phone`) | Settings |
| Edge Function `resend-webhook` with signature verification and `webhook_events` idempotency | Delivery status and suppressions |
