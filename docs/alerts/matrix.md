# Alerts matrix: every role, every alert

Source of truth for the alert design and for the native app build (branch r27-apps, one app for every role, FCM through
`push_subscriptions` kind `fcm`, same outbox and topics as the browser, 0300). Written for migrations 0460 to 0463. The
tables of existing notices are generated from `notification_catalogue` after 0463.

How to read it:

- **Tier**: urgent = push at once at any hour; normal = push, held until the quiet hours end (21:00 to 8:00, except the
  `alerts` topic for customers); digest = an in-app line and the daily staff digest, never a push.
- **Channels**: push (browser or app), text (SMS, customers only, their channel choice 0096), email, in-app (the bell).
- **Topic**: the per-device switch on the person's Alerts card. Nine topics: requests, bookings, payments, handovers,
  messages, alerts, documents, leads, visitors.
- **Exists**: a catalogue `code` today; `new` = made by 0460 to 0463; `TODO` = not wired yet (the trigger data is not in the
  database, or it needs the app).
- Marketing never pushes and never defaults on (CASL). Sign-in links and codes never push.

## The system (staff side)

- One rule table `staff_alert_rules` (rule, who, tier, topic, enabled, wired), one emitter `app.staff_alert`, three notices
  `staff_alert_urgent`, `staff_alert_normal`, `staff_alert_digest`, one feed (the bell and the notifications list). Who
  tokens: `admin`, `assigned`, `on_duty:<function>`, `unassigned_on_duty:<function>`. Never a test account.
- The four lead notices of 0460 are fixed rows, switched in Program settings.
- Admin gets every topic by default; customer service and Sales also leads and visitors; Fleet, Finance and field staff can
  switch them on.
- Mirror of outbound messages: when an important notice goes to a renter, owner or investor, the Admins get a line (`sent:*`
  rules).
- Jobs: every 5 minutes (late field jobs, offers expiring within the hour, escalation, morning brief 8:00, evening wrap and
  cash summary 21:00, Toronto).

## Admin

All defaults on; every group of `staff_alert_rules` below goes to the Admins. Buttons: Open on all; others TODO (see Action buttons).

| Alert | Rule | Who | Tier | Topic | Exists |
| --- | --- | --- | --- | --- | --- |
| New renter lead | `staff_lead_new` | admin, assigned, unassigned_on_duty:cs, unassigned_on_duty:sales | urgent | leads | new (0460/0462) |
| Request typed and not sent | `staff_request_unfinished` | admin, assigned, unassigned_on_duty:cs, unassigned_on_duty:sales | urgent | leads | new (0460/0462) |
| New owner lead | `staff_owner_lead_new` | admin, assigned | urgent | leads | new (0460/0462) |
| Visitor turned Hot | `staff_hot_visitor` | admin, on_duty:cs, on_duty:sales | urgent | visitors | new (0460/0462) |
| Sent: late return notice (T13) | `sent:renter_late_return_first` | admin | urgent | alerts | new (0460/0462) |
| Sent: final late return notice (T14) | `sent:renter_late_return_final` | admin | urgent | alerts | new (0460/0462) |
| Sent: return time notice | `sent:renter_return_due` | admin | urgent | alerts | new (0460/0462) |
| Sent: balance overdue | `sent:renter_balance_overdue` | admin | normal | payments | new (0460/0462) |
| Sent: payment failed | `sent:renter_payment_failed` | admin | normal | payments | new (0460/0462) |
| Sent: payment link | `sent:renter_recovery_pay` | admin | normal | payments | new (0460/0462) |
| Sent: owner debit failed or refused | `sent:owner_debit_returned` | admin | urgent | alerts | new (0460/0462) |
| Sent: owner statement | `sent:owner_statement_ready` | admin | digest | payments | new (0460/0462) |
| Sent: owner payout | `sent:owner_payout_sent` | admin | digest | payments | new (0460/0462) |
| Sent: investor payout | `sent:investor_return_paid` | admin | digest | payments | new (0460/0462) |
| Sent: offer to renter | `sent:renter_offer_ready` | admin | digest | requests | new (0460/0462) |
| Sent: agreement to sign (renter) | `sent:renter_agreement_ready` | admin | digest | documents | new (0460/0462) |
| Sent: agreement to sign (owner) | `sent:owner_agreement_ready` | admin | digest | documents | new (0460/0462) |
| Payment received over the threshold | `payment_received` | admin | normal | payments | new (0460/0462) |
| Refund issued | `refund_issued` | admin | normal | payments | new (0460/0462) |
| Daily cash summary, 9 pm | `cash_summary` | admin | digest | payments | new (0460/0462) |
| Deposit hold failed | `deposit_hold_failed` | admin | urgent | alerts | TODO: not wired yet |
| Card declined at pickup | `card_declined_pickup` | admin, on_duty:fleet | urgent | alerts | TODO: not wired yet |
| Investor money received | `investor_money_in` | admin | normal | payments | TODO: not wired yet |
| Booking paid and confirmed | `booking_confirmed` | admin | normal | bookings | new (0460/0462) |
| Offer sent to the renter | `offer_sent` | admin | digest | requests | new (0460/0462) |
| Offer expires within the hour | `offer_expiring` | admin, on_duty:sales | normal | requests | new (0460/0462) |
| Car going out (pickup recorded) | `booking_out` | admin, on_duty:fleet | normal | bookings | new (0460/0462) |
| Car back (return recorded) | `booking_back` | admin, on_duty:fleet | normal | bookings | new (0460/0462) |
| Booking closed | `booking_closed` | admin | digest | bookings | new (0460/0462) |
| No-show | `booking_no_show` | admin, on_duty:fleet | urgent | alerts | new (0460/0462) |
| Offer viewed by the renter | `offer_viewed` | admin | digest | requests | TODO: not wired yet |
| Offer accepted | `offer_accepted` | admin | normal | requests | TODO: not wired yet |
| Extension asked or paid | `extension_paid` | admin | normal | bookings | TODO: not wired yet |
| Date change asked or approved | `date_change` | admin | normal | bookings | TODO: not wired yet |
| Deposit released | `deposit_released` | admin | digest | payments | TODO: not wired yet |
| Insurer booking without claim number at pickup | `insurer_claim_missing` | admin, on_duty:cs | normal | alerts | TODO: not wired yet |
| Field job assigned | `job_assigned` | admin, assigned | normal | handovers | new (0460/0462) |
| Field job started | `job_started` | admin | normal | handovers | new (0460/0462) |
| Field job finished | `job_done` | admin | digest | handovers | new (0460/0462) |
| Field job running late | `job_late` | admin, assigned | urgent | alerts | new (0460/0462) |
| Handover checklist incomplete | `handover_checklist_incomplete` | admin | normal | handovers | TODO: not wired yet |
| Fuel or km off at return | `return_fuel_km` | admin | normal | handovers | TODO: not wired yet |
| Review of 3 stars or less | `review_low` | admin, on_duty:cs | urgent | messages | new (0460/0462) |
| New review | `review_new` | admin | normal | messages | new (0460/0462) |
| 5-star review | `review_five` | admin | normal | messages | new (0460/0462) |
| Complaint words in chat or email | `complaint_keyword` | admin, on_duty:cs | normal | messages | TODO: not wired yet |
| Asked to delete their account | `account_delete_request` | admin | normal | messages | TODO: not wired yet |
| Opt-out or unsubscribe | `opt_out` | admin | digest | messages | TODO: not wired yet |
| Toll or ticket received | `toll_received` | admin | digest | alerts | new (0460/0462) |
| Licence uploaded, needs review | `licence_review` | admin, on_duty:cs | normal | documents | TODO: not wired yet |
| Agreement signed | `agreement_signed` | admin | digest | documents | TODO: not wired yet |
| Agreement unsigned 2 hours before pickup | `agreement_unsigned_pickup` | admin, on_duty:cs | urgent | alerts | TODO: not wired yet |
| Insurance proof missing 24 hours before pickup | `insurance_missing` | admin, on_duty:cs | normal | documents | TODO: not wired yet |
| Tracker offline over 2 hours on rent | `tracker_offline` | admin, on_duty:fleet | urgent | alerts | TODO: not wired yet |
| Geofence exit, speeding, after-hours movement | `geofence_exit` | admin, on_duty:fleet | urgent | alerts | TODO: not wired yet |
| Car due for service or inspection within 7 days | `maintenance_due` | admin | digest | alerts | TODO: not wired yet |
| Car unpublished or blocked unexpectedly | `car_unpublished` | admin | normal | alerts | TODO: not wired yet |
| Owner gave notice or asked to leave | `owner_notice` | admin | urgent | alerts | TODO: not wired yet |
| Owner changed banking | `owner_banking_changed` | admin | urgent | alerts | TODO: not wired yet |
| Investor signed or invested | `investor_invested` | admin | normal | payments | TODO: not wired yet |
| Usage over 80% of an allowance | `usage_80` | admin | normal | alerts | new (0460/0462) |
| New job application | `application_new` | admin | normal | requests | new (0460/0462) |
| Admin sign-in from a new device or country | `admin_new_device` | admin | urgent | alerts | TODO: not wired yet |
| Burst of failed sign-ins | `failed_sign_ins` | admin | urgent | alerts | TODO: not wired yet |
| Deploy finished or failed | `deploy_result` | admin | normal | alerts | TODO: not wired yet |
| Data health found new problems | `data_health` | admin | digest | alerts | TODO: not wired yet |
| AI interview finished | `interview_finished` | admin | normal | requests | TODO: not wired yet |
| Academy lesson, quiz or certification | `academy_progress` | admin | digest | alerts | TODO: not wired yet |
| Staff has not touched their queue in 2 hours | `staff_idle` | admin | normal | alerts | TODO: not wired yet |
| First booking of a newly listed car | `win_first_booking` | admin | normal | bookings | TODO: not wired yet |
| Record day or week of revenue | `win_record_day` | admin | normal | payments | TODO: not wired yet |
| Owner car earned its first payout | `win_first_payout` | admin | digest | payments | TODO: not wired yet |
| Monthly totals on the 1st | `win_month_totals` | admin | digest | payments | TODO: not wired yet |
| Morning brief (Admin), 8 am | `morning_brief_admin` | admin | normal | alerts | new (0460/0462) |
| Morning brief (your own), 8 am | `morning_brief_staff` | assigned | normal | alerts | new (0460/0462) |
| Evening wrap (Admin), 9 pm | `evening_wrap` | admin | urgent | payments | new (0460/0462) |
| Urgent alert nobody opened | `escalation` | admin | urgent | alerts | new (0460/0462) |

Other Admin alerts that exist today as catalogue codes (`staff_*`, in app, email or digest): `staff_alert_digest`, `staff_alert_normal`, `staff_alert_urgent`, `staff_approval_needed`, `staff_deposit_link_not_sent`, `staff_digest_eod_admin`, `staff_digest_morning_admin`, `staff_disable_approval_needed`, `staff_dispute_opened`, `staff_email_cap_reached`, `staff_email_cap_warning`, `staff_email_failed`, `staff_fleet_count_warning`, `staff_hot_visitor`, `staff_incident_reported`, `staff_job_failed`, `staff_lead_new`, `staff_monthly_statements_pdfs`, `staff_monthly_statements_ready`, `staff_not_back_admin`, `staff_owner_debit_exception`, `staff_owner_debit_run`, `staff_owner_lead_new`, `staff_payouts_due`, `staff_pickup_unrecorded_admin`, `staff_request_unfinished`, `staff_site_alert`, `staff_site_recovered`, `staff_statements_ready_for_approval`, `staff_usage_alert`, `staff_weekly_summary`.

## Customer service (VA)

On by default: requests, bookings, messages, alerts, leads, visitors. Gets: leads and unfinished requests when assigned or on duty, hot visitors on duty, licence review (TODO), 3-star-or-less reviews, complaint words (TODO), live chat messages (`staff_chat_message`), renter replies (`staff_renter_replied`), identity review (`staff_identity_review`), agreements unsigned before pickup (TODO). Buttons: Open, Call renter (TODO), Snooze 30 minutes (TODO).

Catalogue codes today: `staff_booking_request_new`, `staff_change_proposal_answered`, `staff_change_request_received`, `staff_chat_message`, `staff_chat_waiting`, `staff_digest_eod_va_cs`, `staff_digest_morning_va_cs`, `staff_extension_requested`, `staff_identity_review`, `staff_offer_approved_paid`, `staff_owner_form_uploaded`, `staff_renter_replied`, `staff_request_waiting`, `staff_review_received`.

## Sales (VA)

On by default: requests, bookings, messages, alerts, leads, visitors. Gets: renter leads when assigned or on duty, unfinished requests, owner leads assigned to them (they see only their own, 0342), hot visitors on duty, offers expiring within the hour, quote replies (`staff_renter_replied`). Buttons: Open, Call, Send offer (TODO).

Catalogue codes today: `staff_commission_approved`, `staff_commission_paid`, `staff_digest_eod_va_sales`, `staff_digest_morning_va_sales`, `staff_owner_application_received`.

## Fleet (VA)

On by default: requests, bookings, messages, alerts (handovers can be switched on). Gets: car going out and back, no-show, pickup not recorded (`staff_pickup_unrecorded`), not back, field jobs late (urgent), tracker alerts (TODO, r27-tracker), maintenance due (digest, TODO), calendar conflicts. Morning brief for their own work (pickups, returns, overdue). Buttons: Open, Mark picked up (TODO).

Catalogue codes today: `staff_breakdown_reported`, `staff_calendar_conflict`, `staff_calendar_feed_failing`, `staff_digest_eod_va_fleet`, `staff_digest_morning_va_fleet`, `staff_exit_notice_received`, `staff_expiry_watch`, `staff_late_return_alert`, `staff_listing_ready_for_review`, `staff_listing_similarity`, `staff_pickup_unrecorded`.

## Finance (VA)

No staff-alert defaults beyond the shared topics (requests, bookings, messages, alerts). Payment received, refunds, deposit and debit alerts go to the Admins today; Finance on-duty routing is TODO (add `on_duty:finance` to the rule `who` when wanted: a data change, no code). Catalogue codes today: `staff_cancellation_received`, `staff_deposit_release_due`, `staff_digest_eod_va_finance`, `staff_digest_morning_va_finance`, `staff_insurer_invoice_due`, `staff_owner_invoice_failed`, `staff_payment_failed`, `staff_return_findings`, `staff_toll_ticket_logged`, `staff_toll_ticket_unmatched`.

## Field staff

Defaults: handovers, payments. Gets: job assigned (`job_assigned`, `staff_field_job_assigned`), job changed (`staff_field_job_changed`), the day's list, not-back (`staff_not_back`, also a text), pickup not recorded, pay. Late job (urgent, assigned). Buttons: Open, Accept job, Call renter (TODO).

Catalogue codes today: `staff_field_job_assigned`, `staff_field_job_changed`, `staff_field_jobs_today`, `staff_field_jobs_tomorrow`, `staff_not_back`, `staff_pay_statement`.

## Renter

All seven customer topics on by default (requests, bookings, payments, handovers, messages, alerts, documents); marketing never. Channels: email, text (their choice), push, in-app. Text and email exist for most; push now covers every time-sensitive notice below (0300 and 0463). Buttons (TODO, app): Open; Extend on return soon and due; Call us on late notices; Pay now on payment due.

Time-sensitive set the owner named: offer ready, payment due or failed, pickup soon, trip started, return soon and due, late, extension approved, licence rejected, message from staff, deposit released, damage and toll charge, review ask: all are catalogue codes below with a topic.

| Code | When | Email | Text | Topic | Tier | Phone default | Buttons |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `account_password_reset` | Immediate | yes | yes (their channel) | none | none | - | - |
| `account_security_notice` | Immediate | yes | yes (their channel) | none | none | - | - |
| `account_sign_in_link` | Immediate | yes | yes (their channel) | none | none | - | - |
| `insurance_staff_message` | Immediate | yes | yes (their channel) | messages | normal | on | Open |
| `renter_accident_instructions` | Immediate | yes | yes (their channel) | alerts | urgent | on | Open |
| `renter_account_created` | Immediate | yes | yes (their channel) | none | none | - | - |
| `renter_agreement_ready` | Immediate | yes | yes (their channel) | documents | normal | on | Open |
| `renter_agreement_signed` | Immediate | yes | yes (their channel) | documents | normal | on | Open |
| `renter_agreement_version` | Immediate | yes | yes (their channel) | documents | normal | on | Open |
| `renter_balance_overdue` | 7 days after the statement, then monthly on the 1st | yes | yes (their channel) | payments | normal | on | Open |
| `renter_booking_cancelled` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_booking_cancelled_by_us` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_booking_confirmed` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_booking_reminder` | 24 hours before pickup | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_breakdown_help` | Immediate | yes | yes (their channel) | alerts | urgent | on | Open |
| `renter_change_applied` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_change_proposal_expired` | At the deadline | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_change_proposal_reminder` | Once, the reminder hours before the deadline | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_change_proposed` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_change_request_approved` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_change_request_declined` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_change_request_received` | Immediate | yes | yes (their channel) | requests | normal | on | Open |
| `renter_chat_transcript` | Immediate | yes | yes (their channel) | none | none | - | - |
| `renter_comeback_1m` | 30 days after the booking closes | yes | yes (their channel) | none | none | - | - |
| `renter_comeback_1w` | 7 days after the booking closes | yes | yes (their channel) | none | none | - | - |
| `renter_continue_request` | Some minutes after a form was left unfinished (new account), or at once (an existing account) | yes | yes (their channel) | none | none | - | - |
| `renter_coverage_needed` | 48 hours and 24 hours before pickup, while the proof is missing or was declined | yes | yes (their channel) | documents | normal | on | Open |
| `renter_damage_found` | Immediate, within 48 hours of return | yes | yes (their channel) | alerts | urgent | on | Open |
| `renter_deposit_declined` | Immediate | yes | yes (their channel) | payments | normal | on | Open |
| `renter_deposit_released` | Immediate | yes | yes (their channel) | payments | normal | on | Open |
| `renter_driver_link` | Immediate | yes | yes (their channel) | documents | normal | on | Open |
| `renter_extension_approved` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_extension_confirmed` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_extension_declined` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_extension_requested` | Immediate | yes | yes (their channel) | requests | normal | on | Open |
| `renter_extra_charge` | Immediate, when the charge is taken | yes | yes (their channel) | payments | normal | on | Open |
| `renter_final_statement` | When the statement is issued, within 7 business days of check-in | yes | yes (their channel) | documents | normal | on | Open |
| `renter_game_code` | Immediate | yes | yes (their channel) | none | none | - | - |
| `renter_game_code_reminder` | The day before the last day of the code | yes | yes (their channel) | none | none | - | - |
| `renter_game_code_reminder_3d` | promo_reminder_3d_days (3) days before the last day of the code | yes | yes (their channel) | none | none | - | - |
| `renter_google_review_request` | google_review_delay_days after the booking closes | yes | yes (their channel) | none | none | - | - |
| `renter_identity_approved` | Immediate | yes | yes (their channel) | documents | normal | on | Open |
| `renter_identity_needed` | On confirmation, then 48 hours before pickup if still missing | yes | yes (their channel) | documents | normal | on | Open |
| `renter_identity_rejected` | Immediate | yes | yes (their channel) | documents | normal | on | Open |
| `renter_late_return_final` | 2 hours after the return time | yes | yes (their channel) | alerts | urgent | on | Open |
| `renter_late_return_first` | 15 minutes after the return time | yes | yes (their channel) | alerts | urgent | on | Open |
| `renter_named_to_authority` | Immediate, when the admin names the renter | yes | yes (their channel) | none | none | - | - |
| `renter_offer_expired` | Immediate | yes | yes (their channel) | requests | normal | on | Open |
| `renter_offer_ready` | Immediate | yes | yes (their channel) | requests | normal | on | Open |
| `renter_offer_reminder` | 6 hours before the offer expires | yes | yes (their channel) | requests | normal | on | Open |
| `renter_offer_withdrawn` | Immediate | yes | yes (their channel) | requests | normal | on | Open |
| `renter_payment_failed` | Immediate | yes | yes (their channel) | payments | normal | on | Open |
| `renter_payment_receipt` | Immediate | yes | yes (their channel) | payments | normal | on | Open |
| `renter_pickup_details` | 3 hours before pickup | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_pickup_soon` | About 2 hours before pickup | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_promo_expiry_1d` | The day before the last day of the code | yes | yes (their channel) | none | none | - | - |
| `renter_promo_expiry_3d` | promo_reminder_3d_days (3) days before the last day of the code | yes | yes (their channel) | none | none | - | - |
| `renter_recovery_change` | Some hours after the proposal was opened | yes | yes (their channel) | none | none | - | - |
| `renter_recovery_offer` | Some hours after the offer was opened | yes | yes (their channel) | none | none | - | - |
| `renter_recovery_pay` | An hour after the pay page was left | yes | yes (their channel) | payments | normal | on | Open |
| `renter_recovery_request` | Some hours after a request was started | yes | yes (their channel) | none | none | - | - |
| `renter_refund_issued` | Immediate | yes | yes (their channel) | payments | normal | on | Open |
| `renter_rental_added` | Immediate | yes | yes (their channel) | bookings | normal | on | Open |
| `renter_rental_started` | Immediate | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_request_declined` | Immediate | yes | yes (their channel) | requests | normal | on | Open |
| `renter_request_needs_info` | Immediate | yes | yes (their channel) | requests | normal | on | Open |
| `renter_request_received` | Immediate | yes | yes (their channel) | requests | normal | on | Open |
| `renter_return_complete` | Immediate | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_return_details` | Immediate, only inside the 24 hours before return | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_return_due` | At the return time | yes | yes (their channel) | alerts | urgent | on | Open |
| `renter_return_reminder` | 24 hours before return | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_return_soon` | About 3 hours before return | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_review_ask` | 1 hour after the check-in, 9 am to 9 pm | yes | yes (their channel) | none | none | - | - |
| `renter_review_final` | 7 days after the review request | yes | yes (their channel) | none | none | - | - |
| `renter_review_reminder` | 24 hours after the review request | yes | yes (their channel) | none | none | - | - |
| `renter_review_request` | 2 days after the booking closes | yes | yes (their channel) | none | none | - | - |
| `renter_rewards_expiring` | About 30 days before the points end | yes | yes (their channel) | none | none | - | - |
| `renter_signing_code` | Immediate | yes | yes (their channel) | none | none | - | - |
| `renter_staff_message` | Immediate | yes | yes (their channel) | messages | normal | on | Open |
| `renter_trip_checkin` | 24 hours after the pickup, rentals of 2 days or more | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_trip_started` | 30 minutes after the pickup time, when the handover was not recorded | yes | yes (their channel) | handovers | normal | on | Open |
| `renter_vehicle_disabled` | Immediate | yes | yes (their channel) | alerts | urgent | on | Open |

## Owner

Defaults: requests, bookings, payments, alerts, documents. Buttons: Open, Sign now on agreements (TODO).

| Code | When | Email | Text | Topic | Tier | Phone default | Buttons |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `document_signing_code` | Immediate | yes | some | none | none | - | - |
| `owner_account_created` | Immediate | yes | some | none | none | - | - |
| `owner_agreement_ready` | Immediate | yes | some | documents | normal | on | Open |
| `owner_agreement_signed` | Immediate | yes | some | documents | normal | on | Open |
| `owner_application_approved` | Immediate | yes | some | requests | normal | on | Open |
| `owner_application_declined` | Immediate | yes | some | requests | normal | on | Open |
| `owner_application_info_requested` | Immediate | yes | some | requests | normal | on | Open |
| `owner_application_received` | Immediate | yes | some | requests | normal | on | Open |
| `owner_bank_details_changed` | Immediate | yes | some | alerts | urgent | on | Open |
| `owner_booking_changed` | Immediate | yes | some | bookings | normal | on | Open |
| `owner_booking_confirmed` | Immediate | yes | some | bookings | normal | on | Open |
| `owner_car_set_up` | Immediate, after approval | yes | some | bookings | normal | on | Open |
| `owner_cosigner_sign` | Immediate | yes | some | documents | normal | on | Open |
| `owner_debit_notice` | The notice days before the debit day (the 5th for the 15th by default) | yes | some | payments | normal | on | Open |
| `owner_debit_returned` | The day the bank reports the returned debit | yes | some | payments | normal | on | Open |
| `owner_debit_setup_needed` | The notice day, or the debit day when the agreement was cancelled since the notice | yes | some | payments | normal | on | Open |
| `owner_document_due` | 14 days before the expiry, again at 3 days | yes | some | documents | normal | on | Open |
| `owner_exit_completed` | Immediate | yes | some | alerts | urgent | on | Open |
| `owner_exit_notice_received` | Immediate | yes | some | alerts | urgent | on | Open |
| `owner_fee_change_cancelled` | Immediate | yes | some | none | none | - | - |
| `owner_fee_change_notice` | Immediate: at least 30 days before the effective date of a higher amount; on the day a lower amount is set | yes | some | bookings | normal | on | Open |
| `owner_fee_invoice` | 15th of each month | yes | some | payments | normal | on | Open |
| `owner_form_approved` | Immediate | yes | some | documents | normal | on | Open |
| `owner_form_rejected` | Immediate | yes | some | documents | normal | on | Open |
| `owner_in_arrears` | The day the bank reports the failed retry (18th or after) | yes | some | payments | normal | on | Open |
| `owner_incident_opened` | Immediate, the day the incident is opened | yes | some | alerts | urgent | on | Open |
| `owner_incident_update` | Immediate | yes | some | alerts | urgent | on | Open |
| `owner_invoice_issued` | Immediate | yes | some | payments | normal | on | Open |
| `owner_invoice_voided` | Immediate | yes | some | payments | normal | on | Open |
| `owner_mode_change_notice` | Immediate: at least the Notice Period (30 days by default) before the date of a change against the owner; on the day it is made for a change the owner asked for | yes | some | bookings | normal | on | Open |
| `owner_new_booking` | Immediate | yes | some | requests | normal | on | Open |
| `owner_onboarding_steps` | Immediate | yes | some | requests | normal | on | Open |
| `owner_pad_confirmed` | Immediate, when the debit mandate becomes active | yes | some | none | none | - | - |
| `owner_payment_failed` | The day the bank reports the failed debit | yes | some | payments | normal | on | Open |
| `owner_payment_received` | Immediate | yes | some | payments | normal | on | Open |
| `owner_payment_recorded` | Immediate | yes | some | payments | normal | on | Open |
| `owner_payment_reversed` | Immediate | yes | some | payments | normal | on | Open |
| `owner_payout_sent` | 10th of each month, when the transfer is sent | yes | some | payments | normal | on | Open |
| `owner_recruit_outreach` | Immediate, when the Admin sends it | yes | some | none | none | - | - |
| `owner_registry_visit` | Immediate | yes | some | none | none | - | - |
| `owner_schedule_resign` | Immediate | yes | some | none | none | - | - |
| `owner_statement_ready` | 10th of each month | yes | some | documents | normal | on | Open |
| `owner_toll_ticket` | Immediate, when Finance matches the notice | yes | some | alerts | urgent | on | Open |
| `owner_upfront_invoice` | Immediate | yes | some | payments | normal | on | Open |
| `owner_vehicle_enrolled` | Immediate | yes | some | bookings | normal | on | Open |
| `owner_vehicle_listed` | Immediate | yes | some | bookings | normal | on | Open |

Not wired yet: car going out and returned on their car (owner-facing copy of `booking_out`/`booking_back`), damage on their car with photos, tracker offline on their car (r27-tracker), debit upcoming (`owner_debit_notice` is mapped to payments in 0463).

## Rental partner (e.g. 01 Motors)

No partner audience exists in the catalogue today. Planned (all TODO, new audience `partner`): their car booked, out and back (normal, bookings), payable statement ready (digest, payments), payout sent (normal, payments). The partner portal needs its own push role in `app.push_role`.

## Investor

Defaults: payments, messages, documents. Statement and payout notices exist with topics; live sheet month closed (TODO, r27-invsheets).

| Code | When | Email | Text | Topic | Tier | Phone default | Buttons |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `investor_notice_received` | Immediate, when the notice is logged | yes | no | messages | normal | on | Open |
| `investor_return_paid` | 15th of each month, when the transfer is sent | yes | no | payments | normal | on | Open |
| `investor_statement_ready` | Monthly, when the statement is issued | yes | no | documents | normal | on | Open |
| `person_document_to_sign` | - | in app | no | documents | normal | on | Open |

## Referral partner

No audience in the catalogue today. Planned (TODO): referral signed up, booked, commission earned, commission paid (normal, payments). Needs `referral_partner_earnings` hooks and a push role.

## Job applicant

Applicants have no account, so no push today. Emails exist (below). TODO: push in the app after sign-in for interview link, reminder and decision (topic requests).

| Code | When | Email | Text | Topic | Tier | Phone default | Buttons |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `applicant_booked` | Immediate | yes | no | none | none | - | - |
| `applicant_cancelled` | Immediate | yes | no | none | none | - | - |
| `applicant_confirm` | 24 hours before the call | yes | no | none | none | - | - |
| `applicant_declined` | Immediate | yes | no | none | none | - | - |
| `applicant_hired` | When the Admin sends the decision emails | yes | no | none | none | - | - |
| `applicant_invited` | Immediate | yes | no | none | none | - | - |
| `applicant_new_times` | Immediate | yes | no | none | none | - | - |
| `applicant_no_show` | When the Admin sends the decision emails | yes | no | none | none | - | - |
| `applicant_received` | Immediate | yes | no | none | none | - | - |
| `applicant_referred` | Immediate | yes | no | none | none | - | - |
| `applicant_reminder` | About an hour before the call, only for candidates who do not get the text (no phone, or phone and texts off); the evening-before email is off unless Program settings turn it on | yes | no | none | none | - | - |
| `applicant_unconfirmed` | When the call is cancelled | yes | no | none | none | - | - |

## Insurer

| Code | When | Email | Text | Topic | Tier | Phone default | Buttons |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `insurer_invoice` | When Finance or an Admin sends the invoice | yes | no | none | none | - | - |

## Prompts and the app download switch

- Prompt moments (TODO, web): renter after a booking is confirmed ("Get pickup and return alerts on this phone?"), owner after approval,
  staff on first sign-in; never on the first page load. Today the prompt is the Alerts card on each profile page (`PushAlertsCard`).
- Done (0463): Program settings `app_store_url` and `play_store_url` (empty until published). When set, phones see "Download the
  CarmaCars app" with the store link instead of the browser steps (an iPhone no longer sees Add to Home Screen); desktop keeps browser
  alerts; inside the app (user agent token `CarmaCarsApp`, to be set by the app build) the native permission prompt is used.

## Not built in this release (TODO list for the app build)

1. Action buttons on alerts (Web Push actions and FCM actions), and the per-alert snooze.
2. Per-person quiet hours and a focus mode (only urgent). Staff quiet hours are the text quiet hours (21:00 to 8:00) today.
3. Generic grouping of bursts of the same kind (only leads are grouped, 0460).
4. Escalation to the next person on duty before the Admins (today: unopened urgent alert goes to the Admins).
5. An Alerts inbox filter by topic and tier (the bell list shows them all; the notifications UI can filter by `code`).
6. A rules editor in Settings (rows are editable by an Admin through the assistant or SQL; `enabled` is honoured at once).
7. Wiring of every row marked TODO above; the ones that need other branches: tracker (r27-tracker), data health (r27-health),
   interviews (r27-interviews), live sheets (r27-invsheets).
8. Text alerts for staff leads: not built (no opt-in pattern for staff, and volume).
