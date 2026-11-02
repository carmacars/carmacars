# Alerts matrix: every role, every alert

Source of truth for the alert design and for the native app build (branch r27-apps, one app for every role, FCM through
`push_subscriptions` kind `fcm`, same outbox and topics as the browser, 0300). Written for migrations 0460 to 0466. The
tables of existing notices are generated from `notification_catalogue` after 0463; the staff rule table from `staff_alert_rules`
after 0466 (every rule wired).

How to read it:

- **Tier**: urgent = push at once at any hour; normal = push, held until the quiet hours end (21:00 to 8:00, except the
  `alerts` topic for customers); digest = an in-app line and the daily staff digest, never a push.
- **Channels**: push (browser or app), text (SMS, customers only, their channel choice 0096), email, in-app (the bell).
- **Topic**: the per-device switch on the person's Alerts card. Nine topics: requests, bookings, payments, handovers,
  messages, alerts, documents, leads, visitors.
- **Exists**: a catalogue `code` today; `yes (0460-0464)` = wired before; `new (0465)` or `new (0466)` = wired in this release.
  `TODO` only where there is no data source at all (said where).
- Marketing never pushes and never defaults on (CASL). Sign-in links and codes never push.

## The system (staff side)

- One rule table `staff_alert_rules` (rule, who, tier, topic, enabled, wired), one emitter `app.staff_alert`, three notices
  `staff_alert_urgent`, `staff_alert_normal`, `staff_alert_digest`, one feed (Alerts, behind the bell in the Admin and staff portals: `/admin/alerts`, `/staff/alerts`). Who
  tokens: `admin`, `assigned`, `on_duty:<function>`, `unassigned_on_duty:<function>`. Never a test account.
- The four lead notices of 0460 are fixed rows, switched in Program settings.
- Admin gets every topic by default; customer service and Sales also leads and visitors; Fleet, Finance and field staff can
  switch them on.
- Mirror of outbound messages: when an important notice goes to a renter, owner or investor, the Admins get a line (`sent:*`
  rules).
- Jobs: every 5 minutes (late field jobs, offers expiring within the hour, escalation, morning brief 8:00, evening wrap and
  cash summary 21:00, Toronto; 0465: agreement unsigned 2 hours before pickup, insurance proof 24 hours before, insurer claim
  number, Sales late or idle in their availability block, record day and week at 21:00, the month's totals on the 1st).
- 0466: per-person quiet hours (default 21:00 to 8:00) and focus mode (urgent only) on Alerts > Settings; per-device topics
  (`push_subscriptions.topics`); buttons on the phone alert (below); escalation first to the next person on duty of the rule's
  function, then the Admins after the same time again (`alert_escalate_minutes`, 15); grouping of bursts (more than
  `alert_burst_count` of one non-urgent rule in `alert_burst_minutes` push once as a group, each stays in the feed); sign-in
  security (`sign_in_events`); the deploy result (the deploy job calls `server_deploy_result`).
- Buttons (two at most on a phone; a tap on the alert always opens it): Call (the lead's, visitor's or renter's number, through
  `/alerts/call`, which hands it to the phone's dialer: the Quo app where it handles calls), Send offer (a request or an offer
  about to expire: the booking's review tab), Approve and Decline (an extension or change asked: the booking's changes tab;
  nothing is decided from the lock screen), Mark picked up (a no-show or a late handover: the booking), Snooze 30 min (urgent
  ones: the alert comes again in 30 minutes and its escalation waits). Customers' alerts open the page; no buttons.

## Admin

All defaults on; every group of `staff_alert_rules` below goes to the Admins. Each rule is switched on or off, and its tier
chosen, on Alerts > Settings (Admins).

| Alert | Rule | Who | Tier | Channels | Topic | Default | Buttons | Exists |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| New renter lead | `staff_lead_new` | admin, assigned, unassigned_on_duty:cs, unassigned_on_duty:sales | urgent | in-app, push | leads | on | Open, Call, Snooze 30 min | yes (0460-0464) |
| Request typed and not sent | `staff_request_unfinished` | admin, assigned, unassigned_on_duty:cs, unassigned_on_duty:sales | urgent | in-app, push | leads | on | Open, Call, Snooze 30 min | yes (0460-0464) |
| New owner lead | `staff_owner_lead_new` | admin, assigned | urgent | in-app, push | leads | on | Open, Snooze 30 min | yes (0460-0464) |
| Visitor turned Hot | `staff_hot_visitor` | admin, on_duty:cs, on_duty:sales | urgent | in-app, push | visitors | on | Open, Snooze 30 min | yes (0460-0464) |
| Sent: late return notice (T13) | `sent:renter_late_return_first` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Sent: final late return notice (T14) | `sent:renter_late_return_final` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Sent: return time notice | `sent:renter_return_due` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Sent: balance overdue | `sent:renter_balance_overdue` | admin | normal | in-app, push | payments | on | Open | yes (0460-0464) |
| Sent: payment failed | `sent:renter_payment_failed` | admin | normal | in-app, push | payments | on | Open | yes (0460-0464) |
| Sent: payment link | `sent:renter_recovery_pay` | admin | normal | in-app, push | payments | on | Open | yes (0460-0464) |
| Sent: owner debit failed or refused | `sent:owner_debit_returned` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Sent: owner statement | `sent:owner_statement_ready` | admin | digest | in-app | payments | on | Open | yes (0460-0464) |
| Sent: owner payout | `sent:owner_payout_sent` | admin | digest | in-app | payments | on | Open | yes (0460-0464) |
| Sent: investor payout | `sent:investor_return_paid` | admin | digest | in-app | payments | on | Open | yes (0460-0464) |
| Sent: offer to renter | `sent:renter_offer_ready` | admin | digest | in-app | requests | on | Open | yes (0460-0464) |
| Sent: agreement to sign (renter) | `sent:renter_agreement_ready` | admin | digest | in-app | documents | on | Open | yes (0460-0464) |
| Sent: agreement to sign (owner) | `sent:owner_agreement_ready` | admin | digest | in-app | documents | on | Open | yes (0460-0464) |
| Payment received over the threshold | `payment_received` | admin | normal | in-app, push | payments | on | Open, Call | yes (0460-0464) |
| Refund issued | `refund_issued` | admin | normal | in-app, push | payments | on | Open, Call | yes (0460-0464) |
| Daily cash summary, 9 pm | `cash_summary` | admin | digest | in-app | payments | on | Open | yes (0460-0464) |
| Deposit hold failed | `deposit_hold_failed` | admin | urgent | in-app, push | alerts | on | Open, Call, Snooze 30 min | new (0465) |
| Card declined at pickup | `card_declined_pickup` | admin, on_duty:fleet | urgent | in-app, push | alerts | on | Open, Call, Snooze 30 min | new (0465) |
| Investor money received | `investor_money_in` | admin | normal | in-app, push | payments | on | Open | new (0465) |
| Owner debit failed | `owner_debit_failed` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | new (0465) |
| Booking paid and confirmed | `booking_confirmed` | admin | normal | in-app, push | bookings | on | Open, Call | yes (0460-0464) |
| Offer sent to the renter | `offer_sent` | admin | digest | in-app | requests | on | Open, Call | yes (0460-0464) |
| Offer expires within the hour | `offer_expiring` | admin, on_duty:sales | normal | in-app, push | requests | on | Open, Call, Send offer | yes (0460-0464) |
| Car going out (pickup recorded) | `booking_out` | admin, on_duty:fleet | normal | in-app, push | bookings | on | Open, Call | yes (0460-0464) |
| Car back (return recorded) | `booking_back` | admin, on_duty:fleet | normal | in-app, push | bookings | on | Open, Call | yes (0460-0464) |
| Booking closed | `booking_closed` | admin | digest | in-app | bookings | on | Open, Call | yes (0460-0464) |
| No-show | `booking_no_show` | admin, on_duty:fleet | urgent | in-app, push | alerts | on | Open, Call, Mark picked up, Snooze 30 min | yes (0460-0464) |
| Booking cancelled | `booking_cancelled` | admin, on_duty:fleet | normal | in-app, push | bookings | on | Open, Call | new (0465) |
| Offer viewed by the renter | `offer_viewed` | admin | digest | in-app | requests | on | Open, Call | new (0465) |
| Offer accepted | `offer_accepted` | admin | normal | in-app, push | requests | on | Open, Call | new (0465) |
| Extension asked or paid | `extension_paid` | admin | normal | in-app, push | bookings | on | Open, Call, Approve, Decline (when asked) | new (0465) |
| Booking change asked or applied | `date_change` | admin | normal | in-app, push | bookings | on | Open, Call, Approve, Decline (when asked) | new (0465) |
| Deposit released | `deposit_released` | admin | digest | in-app | payments | on | Open, Call | new (0465) |
| Insurer booking without a claim number | `insurer_claim_missing` | admin, on_duty:cs | normal | in-app, push | alerts | on | Open, Call | new (0465) |
| Field job assigned | `job_assigned` | admin, assigned | normal | in-app, push | handovers | on | Open | yes (0460-0464) |
| Field job started | `job_started` | admin | normal | in-app, push | handovers | on | Open | yes (0460-0464) |
| Field job finished | `job_done` | admin | digest | in-app | handovers | on | Open | yes (0460-0464) |
| Field job running late | `job_late` | admin, assigned | urgent | in-app, push | alerts | on | Open, Mark picked up, Snooze 30 min | yes (0460-0464) |
| Handover checklist incomplete | `handover_checklist_incomplete` | admin | normal | in-app, push | handovers | on | Open, Call | new (0465) |
| Fuel or km off at return | `return_fuel_km` | admin | normal | in-app, push | handovers | on | Open, Call | new (0465) |
| Review of 3 stars or less | `review_low` | admin, on_duty:cs | urgent | in-app, push | messages | on | Open, Snooze 30 min | yes (0460-0464) |
| New review | `review_new` | admin | normal | in-app, push | messages | on | Open | yes (0460-0464) |
| 5-star review | `review_five` | admin | normal | in-app, push | messages | on | Open | yes (0460-0464) |
| Complaint words in chat or email | `complaint_keyword` | admin, on_duty:cs | normal | in-app, push | messages | on | Open, Call | new (0465) |
| Asked to delete their account | `account_delete_request` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Opt-out or unsubscribe | `opt_out` | admin | digest | in-app | messages | on | Open | new (0465) |
| Toll or ticket received | `toll_received` | admin | digest | in-app | alerts | on | Open | yes (0460-0464) |
| Licence uploaded, needs review | `licence_review` | admin, on_duty:cs | normal | in-app, push | documents | on | Open, Call | new (0465) |
| Agreement signed | `agreement_signed` | admin | digest | in-app | documents | on | Open, Call | new (0465) |
| Agreement unsigned 2 hours before pickup | `agreement_unsigned_pickup` | admin, on_duty:cs | urgent | in-app, push | alerts | on | Open, Call, Snooze 30 min | new (0465) |
| Insurance proof missing 24 hours before pickup | `insurance_missing` | admin, on_duty:cs | normal | in-app, push | documents | on | Open, Call | new (0465) |
| Tracker offline | `tracker_offline` | admin, on_duty:fleet | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Left the zone or Ontario | `tracker_zone` | admin, on_duty:fleet | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Car due for service or inspection | `maintenance_due` | admin | digest | in-app | alerts | on | Open | new (0465) |
| Speeding | `tracker_speeding` | admin, on_duty:fleet | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Car unpublished or blocked unexpectedly | `car_unpublished` | admin | normal | in-app, push | alerts | on | Open | new (0465) |
| Still driving after the return time | `tracker_afterhours` | admin, on_duty:fleet | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Tracker battery low or unplugged | `tracker_battery` | admin, on_duty:fleet | urgent | in-app, push | alerts | on | Open, Snooze 30 min | yes (0460-0464) |
| Owner gave notice or asked to leave | `owner_notice` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | new (0465) |
| Owner changed banking | `owner_banking_changed` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | new (0465) |
| Investor signed or invested | `investor_invested` | admin | normal | in-app, push | payments | on | Open | new (0465) |
| Usage over 80% of an allowance | `usage_80` | admin | digest | in-app | alerts | on | Open | yes (0460-0464) |
| New job application | `application_new` | admin | normal | in-app, push | requests | on | Open | yes (0460-0464) |
| Admin sign-in from a new device or country | `admin_new_device` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | new (0466) |
| Burst of failed sign-ins | `failed_sign_ins` | admin | urgent | in-app, push | alerts | on | Open, Snooze 30 min | new (0466) |
| Deploy finished or failed | `deploy_result` | admin | normal | in-app, push | alerts | on | Open | new (0466) |
| Data health found new problems | `data_health` | admin | digest | in-app | alerts | on | Open | yes (0460-0464) |
| AI interview finished | `interview_finished` | admin | normal | in-app, push | requests | on | Open | yes (0460-0464) |
| AI interview link expired | `interview_expired` | admin | normal | in-app, push | requests | on | Open | new (0465) |
| Applicant accepted the offer (hired) | `applicant_hired` | admin | normal | in-app, push | requests | on | Open | new (0465) |
| Academy lesson, quiz or certification | `academy_progress` | admin | digest | in-app | alerts | on | Open | yes (0460-0464) |
| Staff has not touched their queue in 2 hours | `staff_idle` | admin | normal | in-app, push | alerts | on | Open | new (0465) |
| Academy lesson finished | `academy_lesson` | admin | digest | in-app | alerts | on | Open | new (0465) |
| Academy quiz failed twice | `academy_quiz_failed_twice` | admin | normal | in-app, push | alerts | on | Open | new (0465) |
| Academy path finished (certified) | `academy_certified` | admin | normal | in-app, push | alerts | on | Open | new (0465) |
| Sales late for their block | `staff_late` | admin | normal | in-app, push | alerts | on | Open | new (0465) |
| First booking of a newly listed car | `win_first_booking` | admin | normal | in-app, push | bookings | on | Open, Call | new (0465) |
| Record day or week of payments | `win_record_day` | admin | normal | in-app, push | payments | on | Open | new (0465) |
| Owner car earned its first payout | `win_first_payout` | admin | digest | in-app | payments | on | Open | new (0465) |
| Monthly totals on the 1st | `win_month_totals` | admin | digest | in-app | payments | on | Open | new (0465) |
| Morning brief (Admin), 8 am | `morning_brief_admin` | admin | normal | in-app, push | alerts | on | Open | yes (0460-0464) |
| Morning brief (your own), 8 am | `morning_brief_staff` | assigned | normal | in-app, push | alerts | on | Open | yes (0460-0464) |
| Evening wrap (Admin), 9 pm | `evening_wrap` | admin | urgent | in-app, push | payments | on | Open, Snooze 30 min | yes (0460-0464) |
| Urgent alert nobody opened | `escalation` | admin | urgent | in-app, push | alerts | on | Open, Call, Snooze 30 min | yes (0460-0464) |
| Urgent alert passed to the next person on duty | `escalation_duty` | assigned | urgent | in-app, push | alerts | on | Open, Call, Snooze 30 min | new (0466) |
| Several alerts of one kind (grouped) | `alert_group` | admin | normal | in-app, push | alerts | on | Open | new (0466) |

Other Admin alerts that exist today as catalogue codes (`staff_*`, in app, email or digest): `staff_alert_digest`, `staff_alert_normal`, `staff_alert_urgent`, `staff_approval_needed`, `staff_data_health`, `staff_deposit_link_not_sent`, `staff_digest_eod_admin`, `staff_digest_morning_admin`, `staff_disable_approval_needed`, `staff_dispute_opened`, `staff_email_cap_reached`, `staff_email_cap_warning`, `staff_email_failed`, `staff_fleet_count_warning`, `staff_hot_visitor`, `staff_incident_reported`, `staff_job_failed`, `staff_lead_new`, `staff_monthly_statements_pdfs`, `staff_monthly_statements_ready`, `staff_not_back_admin`, `staff_owner_debit_exception`, `staff_owner_debit_run`, `staff_owner_lead_new`, `staff_payouts_due`, `staff_pickup_unrecorded_admin`, `staff_request_unfinished`, `staff_site_alert`, `staff_site_recovered`, `staff_statements_ready_for_approval`, `staff_tracker_alert`, `staff_usage_alert`, `staff_weekly_summary`.

## Customer service (VA)

On by default: requests, bookings, messages, alerts, leads, visitors. Gets: leads and unfinished requests when assigned or on duty, hot visitors on duty, licence to review, 3-star-or-less reviews, complaint words, agreements unsigned 2 hours before pickup (urgent), insurance proof missing 24 hours before, insurer claim number missing, live chat messages (`staff_chat_message`), renter replies (`staff_renter_replied`), identity review (`staff_identity_review`), urgent alerts passed on by a colleague (`escalation_duty`). Morning brief: open requests, chats waiting, their tasks. Buttons: Open, Call, Snooze 30 min.

Catalogue codes today: `staff_booking_request_new`, `staff_change_proposal_answered`, `staff_change_request_received`, `staff_chat_message`, `staff_chat_waiting`, `staff_digest_eod_va_cs`, `staff_digest_morning_va_cs`, `staff_extension_requested`, `staff_identity_review`, `staff_offer_approved_paid`, `staff_owner_form_uploaded`, `staff_renter_replied`, `staff_request_waiting`, `staff_review_received`.

## Sales (VA)

On by default: requests, bookings, messages, alerts, leads, visitors. Gets: renter leads when assigned or on duty, unfinished requests, owner leads assigned to them (they see only their own, 0342), hot visitors on duty, offers expiring within the hour, quote replies (`staff_renter_replied`). Morning brief: their open leads and their offers waiting. Buttons: Open, Call, Send offer, Snooze 30 min.

Catalogue codes today: `staff_commission_approved`, `staff_commission_paid`, `staff_digest_eod_va_sales`, `staff_digest_morning_va_sales`, `staff_owner_application_received`.

## Fleet (VA)

On by default: requests, bookings, messages, alerts (handovers can be switched on). Gets: car going out and back, no-show, pickup not recorded (`staff_pickup_unrecorded`), not back, field jobs late (urgent), tracker alerts (offline, left the zone or Ontario, speeding, driving after the return time, battery; 0400 and 0464), cancellations, card declined at pickup (urgent), calendar conflicts. Morning brief for their own work (pickups, returns, overdue). Buttons: Open, Call, Mark picked up, Snooze 30 min.

Catalogue codes today: `staff_breakdown_reported`, `staff_calendar_conflict`, `staff_calendar_feed_failing`, `staff_digest_eod_va_fleet`, `staff_digest_morning_va_fleet`, `staff_exit_notice_received`, `staff_expiry_watch`, `staff_late_return_alert`, `staff_listing_ready_for_review`, `staff_listing_similarity`, `staff_pickup_unrecorded`, `staff_tracker_alert_fleet`.

## Finance (VA)

No staff-alert defaults beyond the shared topics (requests, bookings, messages, alerts). Payment received, refunds, deposit and debit alerts go to the Admins today; Finance on duty can be added to any rule's `who` (`on_duty:finance`, a data change, no code). Catalogue codes today: `staff_cancellation_received`, `staff_deposit_release_due`, `staff_digest_eod_va_finance`, `staff_digest_morning_va_finance`, `staff_insurer_invoice_due`, `staff_owner_invoice_failed`, `staff_payment_failed`, `staff_return_findings`, `staff_toll_ticket_logged`, `staff_toll_ticket_unmatched`.

## Field staff

Defaults: handovers, payments. Gets: job assigned (`job_assigned`, `staff_field_job_assigned`), job changed (`staff_field_job_changed`), the day's list, not-back (`staff_not_back`, also a text), pickup not recorded, pay. Late job (urgent, assigned). Morning brief: their jobs today and the first one's time. Buttons: Open, Mark picked up (late handover), Snooze 30 min.

Catalogue codes today: `staff_field_job_assigned`, `staff_field_job_changed`, `staff_field_jobs_today`, `staff_field_jobs_tomorrow`, `staff_not_back`, `staff_pay_statement`.

## Renter

All seven customer topics on by default (requests, bookings, payments, handovers, messages, alerts, documents); marketing never. Channels: email, text (their choice), push, in-app. Text and email exist for most; push now covers every time-sensitive notice below (0300 and 0463). A tap opens the page of the notice (no buttons on customers' alerts). The prompt to turn alerts on comes on the portal's first page and, once a booking is confirmed, on that booking's page.

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
| `renter_named_to_authority` | Immediate, when the admin names the renter | yes | yes (their channel) | alerts | urgent | on | Open |
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
| `renter_recovery_change` | Some hours after the proposal was opened | yes | yes (their channel) | requests | normal | on | Open |
| `renter_recovery_offer` | Some hours after the offer was opened | yes | yes (their channel) | requests | normal | on | Open |
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

Defaults: requests, bookings, payments, alerts, documents. A tap opens the page (an agreement to sign opens the signing page).

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
| `owner_fee_change_cancelled` | Immediate | yes | some | bookings | normal | on | Open |
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
| `owner_pad_confirmed` | Immediate, when the debit mandate becomes active | yes | some | payments | normal | on | Open |
| `owner_payment_failed` | The day the bank reports the failed debit | yes | some | payments | normal | on | Open |
| `owner_payment_received` | Immediate | yes | some | payments | normal | on | Open |
| `owner_payment_recorded` | Immediate | yes | some | payments | normal | on | Open |
| `owner_payment_reversed` | Immediate | yes | some | payments | normal | on | Open |
| `owner_payout_sent` | 10th of each month, when the transfer is sent | yes | some | payments | normal | on | Open |
| `owner_recruit_outreach` | Immediate, when the Admin sends it | yes | some | none | none | - | - |
| `owner_registry_visit` | Immediate | yes | some | documents | normal | on | Open |
| `owner_schedule_resign` | Immediate | yes | some | documents | normal | on | Open |
| `owner_statement_ready` | 10th of each month | yes | some | documents | normal | on | Open |
| `owner_toll_ticket` | Immediate, when Finance matches the notice | yes | some | alerts | urgent | on | Open |
| `owner_upfront_invoice` | Immediate | yes | some | payments | normal | on | Open |
| `owner_vehicle_enrolled` | Immediate | yes | some | bookings | normal | on | Open |
| `owner_vehicle_listed` | Immediate | yes | some | bookings | normal | on | Open |

Every time-sensitive owner notice that exists has a topic (0463, 0465), the debit notice included (`owner_debit_notice`, payments). Owners are not told when their car goes out or comes back, and the tracker alerts are staff-only: there is no such owner notice to map.

## Rental partner (e.g. 01 Motors)

Rental partners sign in to the owner portal (`owners.kind = 'partner'`, 0046), so every owner notice and topic above is theirs, with the same Alerts card on Account > Notifications. No partner-only notice exists to map.

## Investor

Defaults: payments, messages, documents. Statement and payout notices exist with topics; live sheet month closed: TODO, no data source (the live sheets keep no closing event).

| Code | When | Email | Text | Topic | Tier | Phone default | Buttons |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `investor_notice_received` | Immediate, when the notice is logged | yes | no | messages | normal | on | Open |
| `investor_return_paid` | 15th of each month, when the transfer is sent | yes | no | payments | normal | on | Open |
| `investor_statement_ready` | Monthly, when the statement is issued | yes | no | documents | normal | on | Open |
| `person_document_to_sign` | - | in app | no | documents | normal | on | Open |

## Referral partner

Referral partners have no sign-in (Admin > Referral partners keeps them), so no device can receive a push: TODO, no account to send to. Their earnings reach the Admins in the Money alerts.

## Job applicant

Applicants have no account, so no device can receive a push (TODO, no account). Emails exist (below); the Admins get the hiring alerts (new application, AI interview scored, link expired, offer accepted).

| Code | When | Email | Text | Topic | Tier | Phone default | Buttons |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `applicant_ai_interview` | Immediate | yes | no | none | none | - | - |
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

- The invitation (`PushInvite`) shows on each portal's first page (renter, owner and partner, investor, staff on their first
  sign-in, Admin), never to automation and never while an Admin views as someone; "Not now" hides it 30 days on that device.
- 0466: a renter whose booking is confirmed is asked on that booking's page ("Get your pickup reminders as alerts"), with its
  own "Not now". Owners are asked on their portal's first page, which they reach once approved.
- iPhone and iPad: the Add to Home Screen steps (Share, Add to Home Screen, open from there) on the card and the invitation.
- Done (0463): Program settings `app_store_url` and `play_store_url` (empty until published). When set, phones see "Download the
  CarmaCars app" with the store link instead of the browser steps (an iPhone no longer sees Add to Home Screen); desktop keeps browser
  alerts; inside the app (user agent token `CarmaCarsApp`, set by the app build) the native permission prompt is used.
- Marketing never pushes and is never on without consent; sign-in links and codes never push.

## Still TODO (no data source)

1. Investor live sheet month closed: the live sheets keep no closing event.
2. Push to referral partners and job applicants: they have no sign-in, so no device to send to (email stays).
