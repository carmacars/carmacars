# 0018 and 0023: notifications

Migration `0018_notifications.sql` is the notification layer: catalogue, outbox, staff digests, in-app notices, preferences, suppressions, consent, the daily cap and the sender functions. It runs after 0017 and before 0019 to 0022, so it uses only objects of 0001 to 0017. Migration `0023_notification_wiring.sql` runs last and holds everything that reads or watches the tables of 0019 to 0022: the full merge payload, the triggers that emit events, and the time-based jobs. Tests: `supabase/tests/07_notifications.sql`.

## 1. How it works

1. A function or trigger calls `app.emit_event(code, entity, id, payload, dedupe_key)` (0017). Dedupe keys follow `code:entity_id:discriminator`; 0023 emits through `app.ntf_emit(code, entity, id, discriminator, payload)`, which builds that key.
2. `app.process_events()` (pg_cron every minute through `app.job_notify_events()`) reads unprocessed events in order, looks up the catalogue row, finds the recipients by audience and, for each recipient:
   - a staff notice whose catalogue entry has `digest: true` becomes one `staff_digest_items` row per role (not per person), unless the emitter marked it immediate (`_immediate`, or `_immediate_roles` for some roles);
   - anything else becomes one `notification_outbox` row (dedupe key: the event's key, `|`, the recipient);
   - anyone with an account also gets one `notifications` row (in-app; free, outside the cap). A marketing notice appears in-app only when its email may go.
   The event is then marked processed with a count note. Rerunning writes nothing new.
3. The Edge Function `send-outbox` (service role) calls `app.outbox_claim(limit)`, renders each row with `emails/src/engine.mjs` (the row carries the subject, from, reply-to, template paths and payload), sends it, then calls `app.outbox_mark_sent(id, provider_id, body_text)` or `app.outbox_mark_failed(id, error, permanent)`.
4. The provider webhook calls `app.outbox_record_bounce(provider_id, 'bounce'|'complaint', detail)`. The unsubscribe page calls `app.unsubscribe_token_info(token)` before the click and `app.unsubscribe(token)` on the click (also the `List-Unsubscribe-Post` target).

### Recipients (by catalogue audience)

| Audience | Who |
| --- | --- |
| `renter` | `signer_email` / `signer_user_id` in the payload (a rental agreement signer); else each signer in `signers` except CarmaCars; else the renter of `renter_id` or of the booking; for an account event, the user |
| `owner` | `owner_id` in the payload, else the owner of the booking or vehicle; a lead without an owner record is reached at the payload `email` |
| `investor` | `investor_id` in the payload |
| `staff_*` | `recipient_user_id` when given (field staff on a job); else every active user of the audience role and of `also_sent_to` (admins; VAs by function). `_roles` in the payload replaces the catalogue roles |

### Decisions per outbox row

| Status | When |
| --- | --- |
| `skipped` | No email address; marketing without consent (express for the come-back offers, implied for the review request: "has not unsubscribed"); email turned off in preferences (only possible where `user_can_mute`: marketing, staff digests, the weekly summary) |
| `suppressed` | The address is in `email_suppressions`: scope `all` (hard bounce, complaint, manual) stops every email; scope `marketing` (unsubscribed) stops marketing only. Transactional email is never stopped by consent |
| `queued` | Everything else. `missing_variables` lists any catalogue variable neither built nor sender supplied (the tests keep it empty) |
| `sending`, `sent`, `failed`, `delayed` | Set by the sender functions |

### The daily cap

`outbox_claim` orders by priority class, then due time: 1 customer transactional, 2 owner and investor, 3 immediate staff, 4 digests and scheduled summaries (digests, field job lists, the weekly summary), 5 marketing. A class sends only while today's count (Toronto day; sent plus sending) is under `least(notify_daily_cap, notify_class_limits[class])` and the month under `notify_monthly_cap`. Marketing also needs the Toronto time inside `notify_marketing_from` to `notify_marketing_until` and today's marketing count under `notify_marketing_daily_max`. What cannot go is set `delayed` with `send_after` at the next Toronto midnight (or the next marketing window), never dropped, and each active admin gets one in-app `staff_email_cap_reached` notice that day. A row left `sending` longer than `notify_sending_lock_minutes` is returned to the queue. Failures retry after `notify_backoff_minutes` (1, 5, 30) up to `notify_max_attempts` (3), then `failed`. A hard bounce on a renter's booking email raises a customer service task `email_bounced`.

## 2. New objects

### 0018

| Object | What |
| --- | --- |
| `notification_link_paths` | The paths of `emails/src/links.mjs` (generated) |
| `notification_catalogue` | One row per email code (generated) plus the in-app-only `staff_email_cap_reached`; `priority`, `consent_rule`, `user_can_mute`, `sender_supplied` worked out by `app.notification_catalogue_refresh()`; `is_enabled` turns a code off; `emitted_by` documents the emitter |
| `notification_outbox` | Emails, one per recipient, unique dedupe key, status, attempts, `send_after`, provider id, `unsubscribe_token` (marketing), link to the `messages` row once sent |
| `staff_digest_items` | Digested staff notices per role, `digest_slot` next or morning, `digested_at` when carried |
| `notifications` | In-app notices per user, `read_at` |
| `notification_preferences` | Per user and code: email and in-app switches |
| `email_suppressions` | Address, scope `all` or `marketing`, reason, lifted by an admin |
| `marketing_sends` | One row per marketing email decided for a booking (unique code and booking), with the promo code and consent used |
| 48 `program_settings` columns `notify_*` | Every limit, time and percentage of the layer (section 5) |
| `app.fmt_money`, `fmt_date`, `fmt_day`, `fmt_time`, `fmt_at`, `fmt_datetime`, `fmt_km`, `fmt_pct`, `render_text` | Formatting in the catalogue's conventions (Toronto time, `$1,234.56`) and subject rendering |
| `app.notification_catalogue_refresh()` | Recomputes the derived catalogue columns and keeps `message_templates` in step (the `messages` foreign key) |
| `app.has_marketing_consent(user, rule)`, `app.email_suppressed(email, marketing)` | Consent and suppression checks |
| `app.notification_recipients(event, catalogue)`, `app.notification_payload(code, event, recipient)` (base; replaced in 0023), `app.digest_line`, `app.notification_url` | Recipients, payload, digest line and link |
| `app.process_events(limit, now)`, `app.job_notify_events(now)` | Events to outbox, digest items and notices; pg_cron `carmacars-notify-events` every minute |
| `app.outbox_sent_today`, `app.outbox_claim`, `app.outbox_mark_sent`, `app.outbox_mark_failed`, `app.outbox_record_bounce`, `app.unsubscribe_token_info`, `app.unsubscribe` | Sender functions, service role only |
| `app.my_notifications`, `app.mark_notifications_read`, `app.my_notification_preferences`, `app.set_notification_preference` | Signed-in users |

### 0023

| Object | What |
| --- | --- |
| `program_settings.notify_photo_base_url` | Base of the public vehicle photo URL |
| `app.ntf_contact`, `ntf_link`, `ntf_vehicle`, `ntf_booking`, `ntf_lines`, `ntf_missing_items`, `ntf_tracker_summary`, `ntf_fuel` | Payload helpers. Contact details come from 0022's `site_settings` (`mailing_address`, `phone`, `roadside_phone`), program settings as fallback; the numbered company is never read |
| `app.notification_payload` (replaced) | The full merge payload per code |
| `app.ntf_emit` | Emit with the `code:entity_id:discriminator` key |
| 23 triggers `*_notify` | On `booking_events`, `bookings`, `booking_cancellations`, `payments`, `refunds`, `booking_statements`, `user_roles`, `vehicle_onboardings`, `owner_invoices`, `payouts`, `investment_returns`, `investment_elections`, `investment_redemptions`, `incidents`, `claims`, `reviews`, `disputes`, `tracker_commands`, `fleet_counts`, `vehicle_exits`, `job_runs`, `tasks`, `field_jobs` |
| `app.dispatch_roadside(incident, eta_minutes, by, note)` | Logs the roadside dispatch on a breakdown and emits `renter_breakdown_help` with the arrival estimate |
| `app.notify_reminders`, `app.job_notify_reminders` | Every 5 minutes (`carmacars-notify-reminders`) |
| `app.notify_followups`, `notify_daily_checks`, `notify_statements_reminder`, `notify_payouts_due`, `notify_digests`, `ntf_standing_lists`, `notify_field_lists`, `notify_weekly_summary`, `app.job_notify_scheduled` | Daily and weekly parts, every 5 minutes (`carmacars-notify-scheduled`), each claimed once per Toronto day (week, month) in `job_runs` |
| `app.ntf_closed_at`, `ntf_booking_balance`, `ntf_renter_clear`, `ntf_fleet_payload`, `ntf_statements_payload`, `ntf_field_job_details`, `ntf_item` | Job helpers |

Every new table has row-level security, `admin_all`, role policies (catalogue and paths: staff and field read; digest items: each VA reads its own role's; notices and preferences: own rows; suppressions: finance and customer service read) and an audit trigger. Browser sessions write nothing directly: notices and preferences change through the functions.

## 3. Merge payloads

The payload holds exactly the catalogue's variables (keys starting `_` steer the digest and are dropped before the outbox). Money `$1,234.56`, dates `Fri, Oct 23, 2026`, times `10:00 am`, deadlines `Wed, Oct 21 at 2:15 pm`, all Toronto time. Links are `notify_base_url` plus the path of `notification_link_paths`. The variables the sender supplies, and nothing else (`notification_catalogue.sender_supplied`):

| Variable | Why the database cannot build it |
| --- | --- |
| `verify_url`, `reset_url`, `sign_in_url`, `link_expiry` | Issued by the sign-in service |
| `signed_agreement_url`, `receipt_url`, `statement_url`, `supporting_document_url` | Signed file links (valid 7 days) from the file store |
| `security_device`, `security_event`, `security_event_at`, `security_place` | Sign-in service events (the account emails are not emitted by the database) |

`unsubscribe_url` is built here, one token per marketing row. The test "G no wired code is missing a variable" builds every wired code against real records and checks `missing_variables` is empty.

## 4. Event codes: who emits each one

79 codes are emitted by this work (0023 triggers and jobs, including the 10 digests), 41 by functions of 0019 to 0022 (`renter_agreement_ready` by both: 0019 when it opens the agreement, 0023 as the one-hour unsigned reminder, under the same dedupe key, so never twice), and 3 by nobody.

| Code | Audience | Category | Emitted by |
| --- | --- | --- | --- |
| `account_password_reset` | renter +owner, investor, staff_admin, staff_va_finance, staff_va_fleet, staff_va_cs, staff_va_sales, staff_field | transactional | not emitted: sent by the sign-in service through its own email settings |
| `account_security_notice` | renter +owner, investor, staff_admin, staff_va_finance, staff_va_fleet, staff_va_cs, staff_va_sales, staff_field | transactional | not emitted: sent by the sign-in service (its events are not in the database) |
| `account_sign_in_link` | renter +owner, investor, staff_admin, staff_va_finance, staff_va_fleet, staff_va_cs, staff_va_sales, staff_field | transactional | not emitted: sent by the sign-in service through its own email settings |
| `investor_notice_received` | investor | transactional | investment_elections_notify, investment_redemptions_notify (0023) |
| `investor_return_paid` | investor | transactional | investment_returns_notify (0023) |
| `investor_statement_ready` | investor | transactional | investment_returns_notify (0023) |
| `owner_account_created` | owner | transactional | user_roles_notify (0023) |
| `owner_agreement_ready` | owner | transactional | vehicle_onboardings_notify (0023) |
| `owner_agreement_signed` | owner | transactional | vehicle_onboardings_notify (0023) |
| `owner_application_declined` | owner | transactional | vehicle_onboardings_notify (0023) |
| `owner_application_received` | owner | transactional | app.submit_lead, owner vehicle intake (0022) |
| `owner_bank_details_changed` | owner | transactional | payout details and payment method functions (0022) |
| `owner_booking_confirmed` | owner | transactional | bookings_notify_status (0023) |
| `owner_document_due` | owner | transactional | expiry-watch (0020) |
| `owner_exit_completed` | owner | transactional | app.complete_exit (0022) |
| `owner_exit_notice_received` | owner | transactional | app.give_exit_notice (0022) |
| `owner_fee_change_notice` | owner | transactional | app.give_fee_change_notice (0022) |
| `owner_fee_invoice` | owner | transactional | owner_invoices_notify (0023) |
| `owner_in_arrears` | owner | transactional | owner_invoices_notify (0023) |
| `owner_incident_opened` | owner | transactional | incidents_notify, claims_notify (0023) |
| `owner_incident_update` | owner | transactional | claims_notify (0023) |
| `owner_new_booking` | owner | transactional | bookings_notify_status (0023) |
| `owner_onboarding_steps` | owner | transactional | vehicle_onboardings_notify (0023) |
| `owner_payment_failed` | owner | transactional | owner_invoices_notify (0023) |
| `owner_payment_received` | owner | transactional | owner_invoices_notify (0023) |
| `owner_payout_sent` | owner | transactional | payouts_notify (0023) |
| `owner_registry_visit` | owner | transactional | vehicle_onboardings_notify (0023) |
| `owner_statement_ready` | owner | transactional | app.issue_owner_statement (0021) |
| `owner_toll_ticket` | owner | transactional | app.bill_toll_to_owner (0021) |
| `owner_upfront_invoice` | owner | transactional | owner_invoices_notify (0023) |
| `owner_vehicle_enrolled` | owner | transactional | vehicle_onboardings_notify (0023) |
| `owner_vehicle_listed` | owner | transactional | app.publish_listing (0022) |
| `renter_accident_instructions` | renter | transactional | incidents_notify (0023) |
| `renter_account_created` | renter | transactional | user_roles_notify (0023) |
| `renter_agreement_ready` | renter | transactional | app.open_rental_agreement (0019); unsigned-for-an-hour reminder, app.notify_reminders (0023) |
| `renter_agreement_signed` | renter | transactional | app.complete_signature_request (0019) |
| `renter_balance_overdue` | renter | transactional | app.notify_daily_checks (0023) |
| `renter_booking_cancelled` | renter | transactional | booking_cancellations_notify (0023) |
| `renter_booking_cancelled_by_us` | renter | transactional | booking_cancellations_notify (0023) |
| `renter_booking_confirmed` | renter | transactional | bookings_notify_status (0023) |
| `renter_booking_reminder` | renter | transactional | app.notify_reminders (0023) |
| `renter_breakdown_help` | renter | transactional | app.dispatch_roadside (0023) |
| `renter_change_request_approved` | renter | transactional | 0019 change requests |
| `renter_change_request_declined` | renter | transactional | 0019 change requests |
| `renter_change_request_received` | renter | transactional | 0019 change requests |
| `renter_comeback_1m` | renter | marketing | app.notify_followups (0023) |
| `renter_comeback_1w` | renter | marketing | app.notify_followups (0023) |
| `renter_damage_found` | renter | transactional | app.report_damage_to_renter (0020) |
| `renter_deposit_declined` | renter | transactional | app.record_deposit_declined (0020) |
| `renter_deposit_released` | renter | transactional | app.settle_deposit (0020) |
| `renter_extension_approved` | renter | transactional | 0019 extensions |
| `renter_extension_confirmed` | renter | transactional | 0019 extensions |
| `renter_extension_declined` | renter | transactional | 0019 extensions |
| `renter_extension_requested` | renter | transactional | app.request_extension (0019) |
| `renter_extra_charge` | renter | transactional | charge_toll_ticket, bill_damage (0021) |
| `renter_final_statement` | renter | transactional | booking_statements_notify (0023) |
| `renter_identity_approved` | renter | transactional | 0019 verification |
| `renter_identity_needed` | renter | transactional | app.notify_reminders (0023) |
| `renter_identity_rejected` | renter | transactional | 0019 verification |
| `renter_late_return_final` | renter | transactional | app.notify_reminders (0023) |
| `renter_late_return_first` | renter | transactional | app.notify_reminders (0023) |
| `renter_named_to_authority` | renter | transactional | app.name_renter_to_authority (0021) |
| `renter_offer_expired` | renter | transactional | booking_events_notify (0023) |
| `renter_offer_ready` | renter | transactional | booking_events_notify (0023) |
| `renter_offer_reminder` | renter | transactional | app.notify_reminders (0023) |
| `renter_offer_withdrawn` | renter | transactional | booking_events_notify (0023) |
| `renter_payment_failed` | renter | transactional | payments_notify (0023) |
| `renter_payment_receipt` | renter | transactional | payments_notify (0023) |
| `renter_pickup_details` | renter | transactional | field_jobs_notify; app.notify_reminders (0023) |
| `renter_refund_issued` | renter | transactional | refunds_notify (0023) |
| `renter_rental_started` | renter | transactional | bookings_notify_status (0023) |
| `renter_request_declined` | renter | transactional | booking_events_notify (0023) |
| `renter_request_needs_info` | renter | transactional | app.ask_booking_info (0019) |
| `renter_request_received` | renter | transactional | booking_events_notify (0023) |
| `renter_return_complete` | renter | transactional | bookings_notify_status (0023) |
| `renter_return_details` | renter | transactional | field_jobs_notify (0023) |
| `renter_return_reminder` | renter | transactional | app.notify_reminders (0023) |
| `renter_review_request` | renter | marketing | app.notify_followups (0023) |
| `renter_vehicle_disabled` | renter | transactional | tracker_commands_notify (0023) |
| `staff_approval_needed` | staff_admin | transactional, digest (next) | app.settle_deposit, task escalation (0020) |
| `staff_booking_request_new` | staff_va_cs | transactional | booking_events_notify (0023) |
| `staff_breakdown_reported` | staff_va_fleet | transactional | incidents_notify (0023) |
| `staff_cancellation_received` | staff_va_finance +staff_va_cs | transactional, digest (next) | booking_cancellations_notify (0023) |
| `staff_change_request_received` | staff_va_cs | transactional, digest (next) | 0019 change requests |
| `staff_digest_eod_admin` | staff_admin | transactional | app.notify_digests (0023) |
| `staff_digest_eod_va_cs` | staff_va_cs | transactional | app.notify_digests (0023) |
| `staff_digest_eod_va_finance` | staff_va_finance | transactional | app.notify_digests (0023) |
| `staff_digest_eod_va_fleet` | staff_va_fleet | transactional | app.notify_digests (0023) |
| `staff_digest_eod_va_sales` | staff_va_sales | transactional | app.notify_digests (0023) |
| `staff_digest_morning_admin` | staff_admin | transactional | app.notify_digests (0023) |
| `staff_digest_morning_va_cs` | staff_va_cs | transactional | app.notify_digests (0023) |
| `staff_digest_morning_va_finance` | staff_va_finance | transactional | app.notify_digests (0023) |
| `staff_digest_morning_va_fleet` | staff_va_fleet | transactional | app.notify_digests (0023) |
| `staff_digest_morning_va_sales` | staff_va_sales | transactional | app.notify_digests (0023) |
| `staff_disable_approval_needed` | staff_admin | transactional | app.request_tracker_disable (0020) |
| `staff_dispute_opened` | staff_admin +staff_va_finance | transactional | disputes_notify (0023) |
| `staff_exit_notice_received` | staff_va_fleet +staff_admin, staff_va_finance | transactional, digest (next) | app.give_exit_notice (0022) |
| `staff_expiry_watch` | staff_va_fleet +staff_admin | transactional, digest (morning) | expiry-watch (0020) |
| `staff_extension_requested` | staff_va_cs +staff_va_finance | transactional | app.request_extension (0019) |
| `staff_field_job_assigned` | staff_field | transactional | field_jobs trigger (0020) |
| `staff_field_job_changed` | staff_field | transactional | field_jobs trigger (0020) |
| `staff_field_jobs_today` | staff_field | transactional | app.notify_field_lists (0023) |
| `staff_field_jobs_tomorrow` | staff_field | transactional | app.notify_field_lists (0023) |
| `staff_fleet_count_warning` | staff_admin | transactional | fleet_counts_notify, vehicle_exits_notify (0023) |
| `staff_identity_review` | staff_va_cs | transactional, digest (next) | 0019 verification uploads |
| `staff_incident_reported` | staff_admin +staff_va_fleet | transactional | incidents_notify (0023) |
| `staff_insurer_invoice_due` | staff_va_finance +staff_admin | transactional, digest (morning) | app.notify_daily_checks (0023) |
| `staff_job_failed` | staff_admin | transactional | job_runs_notify (0023) |
| `staff_late_return_alert` | staff_va_fleet +staff_admin | transactional | app.notify_reminders (0023) |
| `staff_listing_ready_for_review` | staff_va_fleet +staff_admin | transactional, digest (next) | listing pipeline (0022) |
| `staff_monthly_statements_ready` | staff_admin | transactional | app.finalize_company_statement (0021) |
| `staff_offer_approved_paid` | staff_va_cs +staff_va_fleet | transactional, digest (next) | bookings_notify_status (0023) |
| `staff_owner_application_received` | staff_va_sales | transactional | app.submit_lead, owner vehicle intake (0022) |
| `staff_owner_invoice_failed` | staff_va_finance +staff_admin | transactional, digest (next) | owner_invoices_notify (0023) |
| `staff_payment_failed` | staff_va_finance | transactional, digest (next) | payments_notify; 24-hour alert in app.notify_reminders (0023) |
| `staff_payouts_due` | staff_admin +staff_va_finance | transactional | app.notify_payouts_due (0023) |
| `staff_request_waiting` | staff_va_cs +staff_admin | transactional | app.notify_reminders (0023) |
| `staff_return_findings` | staff_va_finance | transactional, digest (next) | condition report reviewed (0020) |
| `staff_review_received` | staff_va_cs +staff_admin | transactional, digest (next) | reviews_notify (0023) |
| `staff_statements_ready_for_approval` | staff_admin | transactional | tasks_notify; reminder in app.job_notify_scheduled (0023) |
| `staff_toll_ticket_logged` | staff_va_finance | transactional, digest (next) | app.log_toll_ticket (0021) |
| `staff_toll_ticket_unmatched` | staff_va_finance +staff_admin | transactional, digest (morning) | toll-watch (0021) |
| `staff_weekly_summary` | staff_admin | transactional | app.notify_weekly_summary (0023) |

Codes nobody emits: `account_sign_in_link`, `account_password_reset`, `account_security_notice`. They are sent by the sign-in service with its own email settings (custom SMTP and the replaced templates, blueprint 12 section 1), and their events never reach the database.

Wiring choices that avoid duplicates:

- Extensions, identity checks, change requests, agreement emails, deposit declines and releases, damage found, field job notices, tolls, statements, exits, fee changes and bank details are emitted only by their 0019 to 0022 functions; 0023 adds nothing for them.
- `renter_payment_receipt` is never sent for the `booking_total` payment (the confirmation carries it) nor for deposits; a deposit decline is 0020's `renter_deposit_declined`, not `renter_payment_failed`.
- `renter_refund_issued` is skipped when a cancellation logged within the hour carries that refund.
- `renter_identity_needed` is sent by the chase job only (48 hours before pickup): at confirmation `renter_booking_confirmed` carries the notice (`needs_verification`).
- Late returns: 0020's ops-watch raises tasks only, so the emails (`renter_late_return_first`, `renter_late_return_final`, `staff_late_return_alert`) are here. Document expiry and tracker disable approval are 0020's, so not here.
- `owner_incident_opened` uses one dedupe key per incident, so an incident and its claim notify the owner once.

## 5. Settings (program_settings, admin editable)

| Setting | Default | Used for |
| --- | --- | --- |
| `notify_daily_cap`, `notify_monthly_cap` | 100, 3000 | The provider limits |
| `notify_class_limits` | 100, 100, 95, 95, 60 | Day count under which classes 1 to 5 still send |
| `notify_marketing_daily_max`, `notify_marketing_from`, `notify_marketing_until` | 15, 10:00, 16:00 | Marketing rationing |
| `notify_max_attempts`, `notify_backoff_minutes`, `notify_sending_lock_minutes`, `notify_event_batch` | 3, {1,5,30}, 10, 500 | Sending |
| `notify_base_url`, `notify_unsubscribe_path` (0023: `notify_photo_base_url`) | https://carmacars.ca, /email/unsubscribe (https://carmacars.ca/media) | Links |
| `notify_digest_morning`, `notify_digest_eod`, `notify_field_today`, `notify_field_tomorrow` | 07:30, 18:15, 07:00, 18:00 | Digests and field lists |
| `notify_weekly_dow`, `notify_weekly_time` | 1 (Monday), 07:45 | Weekly summary |
| `notify_booking_reminder_hours`, `notify_pickup_details_hours`, `notify_return_reminder_hours` | 24, 3, 24 | Reminders before pickup and return |
| `notify_offer_reminder_hours`, `notify_offer_halfway_below_hours` | 6, 12 | Offer reminder (halfway for a shorter window) |
| `notify_identity_chase_hours`, `notify_agreement_unsigned_minutes`, `notify_request_waiting_minutes` | 48, 60, 120 | Chases |
| `notify_late_staff_minutes`, `notify_late_final_deadline_minutes` | {0,30}, 60 | Fleet alert stages; the deadline shown in the final notice. The final stage itself is 0020's `late_admin_minutes` (120) |
| `notify_review_request_days`, `notify_comeback_1w_days`, `notify_comeback_1m_days`, `notify_followup_time` | 2, 7, 30, 10:00 | Follow-ups |
| `notify_comeback_1w_bps`, `notify_comeback_1m_bps`, `notify_comeback_valid_days` | 1000, 1500, 30 | Come-back codes |
| `notify_balance_overdue_days`, `notify_daily_checks_time` | 7, 06:00 | Balance overdue and insurer checks |
| `notify_insurer_due_days`, `notify_insurer_repeat_days`, `notify_insurer_admin_days` | 30, 7, 60 | Insurer invoices outstanding |
| `notify_statements_reminder_day`, `notify_statements_reminder_time`, `notify_payouts_due_time` | 8, 09:00, 08:00 | Statement approval reminder; payouts due on `payout_day` and `investor_payment_day` |
| `notify_cancellation_admin_cents`, `notify_review_alert_max_rating`, `notify_offer_paid_immediate_hours`, `notify_payment_failed_alert_hours`, `notify_digest_waiting_hours` | 50000, 2, 24, 24, 2 | Immediate exceptions to the digests |

## 6. Time-based jobs (0015 pattern)

| Part | When (Toronto) | Once per |
| --- | --- | --- |
| Booking reminder, identity chase, pickup details, return reminder | Every 5 minutes, inside the window | Pickup or return time (a moved return sends again); pickup details per place, time and staff member |
| Late returns | Every 5 minutes: renter at 0 and at `late_admin_minutes`; fleet at each `notify_late_staff_minutes` stage; fleet and admins at the final stage | Stage and return time |
| Offer reminder, unsigned agreement, request waiting, unpaid charge during a rental | Every 5 minutes | Offer version; signer; request; payment |
| Follow-ups | Daily from `notify_followup_time`, for bookings closed up to 3 days before the due day (catch-up) | Booking (`marketing_sends` unique) |
| Daily checks (balance overdue, insurer invoices) | Daily from `notify_daily_checks_time` | Statement and month; invoice and day count |
| Payouts due | `payout_day` and `investor_payment_day` from `notify_payouts_due_time` | Payee type and day |
| Statement approval reminder | `notify_statements_reminder_day` from its time, if the approval task is open | Run |
| Morning and end-of-day digests per role | `notify_digest_morning`, `notify_digest_eod` (the evening one only when it has something) | Day and role |
| Field job lists today and tomorrow | `notify_field_today`, `notify_field_tomorrow` | Person and day |
| Weekly summary | `notify_weekly_dow` from `notify_weekly_time` | ISO week |

Each run key is claimed in `job_runs`; a part that throws is marked failed (raising the admin task and `staff_job_failed`) and the other parts still run.

## 7. When the catalogue changes

1. Edit `emails/src/emails/<code>.mjs`, run `node emails/build.mjs`, `node emails/check.mjs`, `node emails/shots.mjs`.
2. Run `node supabase/seed/0018_gen_catalogue.mjs`. It writes `supabase/seed/0018_catalogue.sql` (Node built-ins only). `--check` fails when the file is out of date; `--check --migration` also checks the copy inside 0018; `--embed` rewrites that copy (only before 0018 is first applied anywhere).
3. On a live database, run `supabase/seed/0018_catalogue.sql` (an upsert; a code that left the catalogue is kept with `in_catalogue` false), or copy it into a new migration. Then wire the new code (a trigger or job that emits it) and add it to the table in section 4.

## 8. Emails (inside `emails/`)

- Added `renter_named_to_authority` (an admin names the renter to the issuing authority for a ticket; 0021 emits it) and `staff_monthly_statements_ready` (the company statement is final and the month's owner statements need review; 0021 emits it), with templates, samples and screenshots.
- Removed the numbered company name and the "operated by" line from every email: `BRAND.legal` is gone from `emails/src/brand.mjs` and the footer in `emails/src/layout.mjs` reads "CarmaCars" above the mailing address. The sender name stays "CarmaCars". `brand.mjs` notes that the lawyer must confirm whether the legal name is required on commercial emails.
- `emails/check.mjs` check 10 required the legal name; it now requires "CarmaCars" above `{{company_address}}` and fails if the numbered company or "operated by" appears. All 14 checks pass; `grep -r 18122211 emails/templates emails/catalogue.json emails/preview` finds nothing (the only occurrence left under `emails/` is the guard in `check.mjs`).

## 9. Test assertions changed

| File | Assertion | Was | Now | Why |
| --- | --- | --- | --- | --- |
| `supabase/tests/05_jobs.sql` | "J without pg_cron the migrations schedule nothing; with it, ..." | 12 jobs | 15 jobs (adds notify-events of 0018 and the two of 0023) | New pg_cron jobs |
| `supabase/tests/09_operations.sql` | "J ops-watch sends nothing and disables nothing: it only raises tasks" | counted every `renter_late%` event | counts those created since the first ops-watch run | 07 (which runs earlier) emits late-return events on purpose; the assertion is about ops-watch |

## 10. Assumptions and limits

1. Come-back codes go through the existing promo path, where `app.compute_booking_split()` (0016) treats a promo discount as Owner Revenue: the owner and CarmaCars share it in the split, and on a Self-Managed car the owner bears all of it. The split cannot express "CarmaCars absorbs its own promotion" without changing that function (blueprint 99, open question 1). Not changed here. The codes are single use, bound to the renter, `source` `followup_7d` or `followup_30d`, percent and validity from settings.
2. `renter_account_created` and `owner_account_created` are emitted when the role is granted; "email not yet verified" is the sign-in service's knowledge, and `verify_url` comes from it.
3. `staff_breakdown_reported` goes to every active fleet assistant (there is no on-call roster table).
4. `owner_incident_update` is sent on claim status changes only; `incident_events` has no "visible to the owner" flag.
5. `investor_notice_received` is emitted for a later pay or reinvest election and for a purchase-on-request redemption; other written notices have no table.
6. `renter_extra_charge` comes from 0021 (tolls, tickets, damage). A later charge line added by Finance by hand is not emitted (no function owns that path yet).
7. The 24-hour unpaid-charge alert (`staff_payment_failed` to finance and admins) is a second notice; the first decline already went to the finance digest.
8. Digest standing lists cover the main lists of each trigger text (approvals, late returns, incidents, disputes, failed jobs, arrears; returns without a statement, refunds, retries, tolls, failed owner invoices, cancellations; field jobs, listings, incidents; requests, offers, documents, reviews; applications, unsigned documents, unpaid upfront invoices). Lists needing data the database lacks (tracker overnight movement, calendar mismatches, the on-call handover note) are not included.
9. `message_templates.audience` allows renter, owner and internal only: investor codes are stored as owner there.
10. 0023 changes no object of 0019 to 0022; the 0016 promo, 0019 functions and 0020 tasks are used as they are.

## 11. Values not editable by an admin, and why

| Literal | Where | Why |
| --- | --- | --- |
| 3 days of catch-up for follow-ups | `app.notify_followups` | Bounds the window a missed run may still serve; not a business rule |
| One hour for "reported by a cancellation in the same hour" | `ntf_refunds_after` | The catalogue's rule text |
| 7 days to sign owner documents (`sign_by`), "24 hours" `link_expiry` default text | payload | Display only until the document flow and sign-in service supply them |
