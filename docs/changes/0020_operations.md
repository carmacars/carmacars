# 0020: operations

> **Merged with 0019.** Migrations 0019 and 0020 were written in parallel and have been integrated into one design. The Deposit waiver columns and `app.waive_deposit`, `app.user_va_has`, the setting `verification_due_hours_before_pickup` and the handover readiness check (`app.booking_readiness`) now come from 0019; the review-extension, refund-cancellation and verify-renter tasks come from this migration only. Every overlap and its resolution: [0019_0020_integration.md](0019_0020_integration.md). Where this record differs, that file wins.

Migration `supabase/migrations/0020_operations.sql`, tests `supabase/tests/09_operations.sql`.

Day-to-day operations on top of request to book (0016): handover and return on a phone, post-rental charges, the renter's statement and the Deposit, field jobs and vehicle moves, the calendar's new entries and its drag and resize functions, rates and fees, the task queues, four scheduled jobs, incidents, vehicle swap, tracker disable, and payout reconciliation. It relies on migrations 0001 to 0019 (see the merge note above). No shared document, earlier migration, email or prototype file was edited.

## 1. Pickup and return

| Function (server only) | Does |
| --- | --- |
| `app.save_condition_report(booking, kind, by, report, job, vehicle)` | Saves a Condition Report as it is filled in: answers, photos (a photo with the same `seq` is a retake), damage marks with their close-ups. Creates the report on the first call. Refused once the report is completed |
| `app.complete_handover(booking, by, report, job, now)` | Reads the booking's readiness from `app.booking_readiness` (0019): calendar switch, every driver verified, coverage confirmed, additional drivers accepted; takes note of the Deposit (the payment the server just placed, `deposit_payment_id`, or an Admin's waiver, `deposit_waiver`), requires odometer, fuel, keys, licence seen, card seen, Tracker reporting, both signature references and the complete photo set, checks the Deposit is taken or waived (readiness `deposit_ok`), then moves the booking to `on_rent` and the job to `done`. The booking's own triggers (0016, 0019) check their conditions again |
| `app.block_handover(booking, by, reason, job)` | "Do not release the car": an urgent, escalated Admin task |
| `app.record_deposit_taken(booking, payment, by, hold_expires_at, now)` | Records the hold (7 days or less) or the charge (longer) the server placed |
| `app.record_deposit_declined(booking, payment, decline_code, by, now)` | Deposit `failed`, urgent Admin task, event `renter_deposit_declined` |
| `app.waive_deposit(booking, by, reason)` | Defined in 0019 (one definition). Admin only. `bookings.deposit_cents` becomes 0 and the waiver is kept on the booking; `app.ops_booking_status_after` closes the `take_deposit` and `deposit_declined` tasks |
| `app.complete_return(booking, by, report, job, now)` | Completes the return report, works out lateness (a part day counts as a full day, through `calc_late_return()`), moves the booking to `returned`, the job to `done`. New damage opens an incident. Returns the findings |
| `app.submit_return_findings(booking, by, findings)` | Fleet confirms the findings (procedure 4 step 6): the return report is marked reviewed, the T7 note is written to `messages`, and the report's trigger raises the Finance task and the event |
| `app.review_condition_report(report, by)` | Marks any other report reviewed |
| `app.complete_condition_report(report, by, now)` | Completes a swap-out, swap-in, baseline, exit or "ready" report; the photo set must be complete |
| `app.record_late_damage(booking, by, damage, now, override_reason)` | Damage found in the 48-hour review: a damage mark on the return report (`found_later`), close-ups, an incident. Inside the window Fleet or an Admin also tells the renter. After it, only an Admin, with the reason |
| `app.report_damage_to_renter(damage, by, now, override_reason)` | Sets `reported_to_renter_at` and emits `renter_damage_found` |

**The photo list.** `required_shots (report_kind, vehicle_class, seq, shot, is_required, guide)`: 19 shots for baseline, pickup, return, swap-out, swap-in and exit, 4 for "ready". A row for one vehicle class replaces the general row for that class and may switch a shot off. `app.required_shots_for(kind, class)` returns the list; `app.condition_report_problems(report)` returns what stops completion: a required shot missing, the set out of order, a damage mark with no close-up. A handover or return with any problem is refused.

**Who may fill a report** (`app.condition_report_actor()`): field staff on a job assigned to them for that booking or vehicle; Fleet or an Admin; the Owner on a Self-Managed car or an Owner Booking; the renter of the booking (saving only: a handover or return is never completed by the renter).

## 2. After the return

| Function (server only) | Does |
| --- | --- |
| `app.assess_check_in(booking, findings, by)` | Writes, or brings up to date, the post-rental charge lines, each with `assessment_key` and `supporting_refs`. Lines already on a statement never change. Returns lines, what is pending, totals by class, and the Deposit |
| `app.issue_booking_statement(booking, by, now)` | The Check-in statement the first time (even with nothing to charge), a later-charge statement after that. Needs the return reviewed; a line without a supporting record is refused; damage lines need an Admin. Sets `interest_starts_on` |
| `app.settle_deposit(booking, by, plan, now)` | Applies the Deposit to the issued, unpaid lines, holds back, releases, and records a pending card charge for any shortfall. Returns `server_actions` |
| `app.post_rental_payment_result(payment, succeeded, decline_code, now)` | The processor's answer to one of those pending payments: paid (claim money goes on the claim's ledger, the split is recomputed, a fully paid statement is marked paid) or declined (counted, next retry set) |

Charge lines and who they belong to, all taken from `fee_types`:

| Finding | Charge type | Belongs to |
| --- | --- | --- |
| Kilometres over the allowance | `mileage_overage` | Owner Revenue |
| Late: each extra day or part day | `late_return_extra_days` | Owner Revenue |
| Late: per started hour, capped per 24 hours | `late_return_fee` | Company |
| Fuel short | `fuel` (pump cost plus the markup), `fuel_service_fee`; electric: `recharging` | Company |
| Cleaning by grade | `cleaning`, `cleaning_heavy`, `pet_cleaning`, `smoking` | Company |
| Lost key | `lost_key_cost` (pass-through), `lost_key_fee` (company) | |
| Damage under the deductible | `damage_at_cost` (pass-through, HST as invoiced), `loss_of_use` (claim funds), `admin_fee_other` (company) | |
| Damage at or over the deductible | A claim is opened (`app.open_claim()`); `deductible` (claim funds), `admin_fee_claim` (company). Loss of use is not added | |
| Claim denied for the renter's breach | The full cost, as under the deductible | |
| Owner Booking | Under the deductible: nothing. With a claim: an `owner_deductions` row (`owner_booking_deductible`) | |

**Deposit rules.** The Deposit is applied before the card and does not cap what is owed. A hold-back needs a reason and runs at most `program_settings.deposit_holdback_days` after Check-in. A card hold can be captured once, so applying, holding back and releasing happen in one step. Money at the processor moves by server action: the function inserts `payments` rows in status `pending` (`capture`, `release` or `refund` of the Deposit, `charge` of the Card on File) and returns them.

**Approval** (`docs/permissions.md`): an Admin may settle anything. A Finance assistant may settle when the release is inside their Single Limit and nothing is held back (the existing guard `app.guard_deposit_release()` checks the same). Otherwise nothing moves: the proposal becomes an `approve_deposit_release` Admin task and a `staff_approval_needed` event, and the Admin runs the function with the plan.

**Closing.** When the Check-in statement is issued and the Deposit is settled with nothing held back, the booking is closed. A balance still pending on the card does not keep it open.

## 3. Field jobs and vehicle moves

`app.create_field_job`, `assign_field_job` (also reassigns; the new person must accept again), `reschedule_field_job`, `accept_field_job`, `start_field_job`, `complete_field_job` (not for handover and return kinds), `cancel_field_job`. Fleet or an Admin dispatches; only the assignee accepts and starts.

- When a booking is confirmed with `pickup_method = 'delivered'` a `delivery` job is created at the pickup time and place; with `return_method = 'picked_up'` a `pickup_from_renter` job at the return. Both unassigned, `auto_created = true`. A booking the renter collects gets no automatic job: Fleet gets the `schedule_handover` task.
- A cancelled, no-show, declined or expired booking cancels its open jobs.
- View `field_job_list`: the signed-in field staff member's jobs for today and tomorrow (Toronto), with the car and the renter's first name only. `app.staff_field_jobs(staff, day)` gives the same list per staff member to Fleet, Finance, customer service and Admins, and to a field staff member for themselves.

`vehicle_moves (vehicle_id, staff_user_id, purpose, started_at, ended_at, from_place, to_place, odometer_start, odometer_end, field_job_id, booking_id, notes, created_by, created_at, updated_at)`. One open move per vehicle. A move opens when a job of kind delivery, detail, photo shoot, registry run, tracker install, tracker removal or recovery starts, and closes when the job is done or cancelled. For `pickup_from_renter` the move opens when the return is completed (the drive back) and is closed with `app.end_vehicle_move()`. `app.start_vehicle_move()` records any other move and closes a move still open on that car.

## 4. Calendar

- `calendar_entries` keeps the 21 columns of 0016 in the same order and gains four at the end: `related_booking_id`, `assigned_to`, `assignee_name`, `detail`. New entry types: `field_job`, `vehicle_move`, `turo_trip`. For these `booking_id` is empty and `related_booking_id` carries the link, so "the entry of booking X" is still one row.
- `app.master_calendar(from, to)` was dropped and created again with the same columns plus those four.
- `app.vehicle_calendar(vehicle, from, to)`: everything on one car (bookings in every status, blocks with removed ones flagged, field jobs, moves, Turo trips, the Owner's control blocks, incidents, exit notice) for Admins and assistants in fleet, finance or customer service.
- `app.calendar_preview_change(booking, changes, now)`: read-only. Returns `refusal`, `action` (`apply_now`, `resend_offer`, `renter_approval`, `extension`), old and new price, `difference_cents`, `available`, `conflicts`, `competing`.
- `app.calendar_apply_change(booking, by, changes, reason, renter_agreed, message, now)`: a request is adjusted at once; an offer is withdrawn, adjusted and sent again; a confirmed booking moves only with `renter_agreed` (an Admin recording the renter's word), otherwise customer service gets the task; a car on rent gets an extension request. Open jobs of the booking follow it.

## 5. Rates and fees

`app.set_rate_card(vehicle, daily, weekend, weekly, monthly, effective_from, by, other)` closes the card in force and opens the new one. `app.set_vehicle_fee_override()`, `app.end_vehicle_fee_override()`: Admin only, charges marked "V". `app.booking_fee_term(booking, fee)` resolves a fee (booking term, vehicle override, class default, general default). `app.snapshot_booking_fee_terms(booking)` writes the terms on the booking at confirmation. `app.set_booking_fee_term()`: Admin only, charges marked "B". `app.preview_bulk_rate_change(filter, change)` and `app.apply_bulk_rate_change(filter, change, admin, effective_from)`.

## 6. Tasks

`task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description)`: 50 rows. A trigger on `tasks` fills queue-independent fields from the rule on every insert, including the tasks 0015 and 0016 already create. An Admin changes a due time or priority by updating the rule.

`app.raise_task()` (one open task per dedupe key), `app.resolve_tasks()`, `app.assign_task()`, `app.snooze_task()`, `app.wake_tasks()`, `app.complete_task()` (refused while the completion rule does not hold; an Admin may force with a note), `app.cancel_task()`, `app.escalate_task()`.

Views: `work_queue`, `va_finance_queue`, `va_fleet_queue`, `va_cs_queue`, `va_sales_queue`, `admin_queue`. Table `quick_replies`.

Tasks created by trigger or by the function that performs the step:

| Task type | Queue | Created by |
| --- | --- | --- |
| `schedule_handover`, `offer_approved_paid` | fleet, cs | Booking confirmed |
| `schedule_detail` | fleet | Booking returned |
| `verify_renter` | cs | Identity verification pending, or coverage proof submitted |
| `review_photos` | fleet | A Condition Report completed |
| `price_findings` | finance | Return report reviewed |
| `price_damage` | admin | Assessment by a non-admin finds costed damage |
| `approve_deposit_release` | admin | Settlement that needs an Admin |
| `deposit_declined`, `handover_blocked` | admin | The two functions of section 1 |
| `refund_cancellation` | finance | Cancellation row with a refund or a Deposit to return |
| `review_extension` | cs | Extension requested |
| `booking_change_approval` | cs | Calendar change to a confirmed booking |
| `incident`, `breakdown` | fleet (and admin) | Incident row inserted |
| `vehicle_swap` | fleet | Swap |
| `approve_tracker_disable` | admin | Disable request inserted |
| `owner_intake`, `book_registry`, `list_vehicle` | cs, fleet, fleet | Onboarding row and its status |
| `collect_upfront`, `debit_failed`, `arrears` | finance | Owner invoice status |
| `review_statements` | finance | Draft owner statement (one per month) |
| `owner_exit` | fleet | Exit row |
| `check_owner_document` | cs | Document uploaded by the Owner |
| `moderate_review` | cs | Review row |
| `lost_property` | cs | Belongings recorded on a return or a detail job |
| `reconcile`, `unmatched_payment` | finance | Reconciliation |
| `chase_offer`, `chase_verification`, `take_deposit`, `late_return`, `late_return_admin`, `job_unacknowledged`, `insurer_provisional`, `opening_checks`, `closing_checks`, `fleet_report` | per rule | Job `ops-watch` |
| `release_deposit`, `settle_holdback` | finance | Job `deposits-due` |
| `turo_expiry`, `safety_certificate_window`, `plate_renewal`, `arrears_removal` | per rule | Job `expiry-watch` |

## 7. Scheduled jobs

| Job | Function | When | Does |
| --- | --- | --- | --- |
| `deposits-due` | `app.job_deposits_due()` | Daily from 06:00 | Deposits due back within the warning window, hold-backs near their last day |
| `ops-watch` | `app.job_ops_watch()` | Every 15 minutes | Wakes waiting tasks and raises the clock-driven tasks. Sends nothing, charges nothing, disables nothing |
| `expiry-watch` | `app.job_expiry_watch()` | Daily from 06:00 | Turo-Only expiry, safety certificate window, plate renewal, arrears past the removal date; emits `owner_document_due` and `staff_expiry_watch` |
| `reconcile` | `app.job_reconcile()` | Daily from 18:00 | Matches open payouts again; flags card payments no payout has carried |

Scheduled with pg_cron in the pattern of 0015 (nothing where pg_cron is absent).

Still an Edge Function, because each calls an outside service: `late-returns` (messages and charges; the tasks are now raised by `ops-watch`), `payment-retries`, `reminders`, `deposit-holds`, `retention`, `month-open`, `payouts`, `owner-billing`, `debit-results`, `debit-retry`, and the fetch step of `reconcile` (reading payouts from the processor, then calling `app.record_processor_payout()`).

## 8. Incidents, swap, tracker

- `incident_steps`: the first-response steps of procedures 8, 9 and 10 as a list, written by `app.open_incident(kind, vehicle, by, details, booking, reported_by, now)`. Reporter is `renter` (own on-rent booking; accident, theft, vandalism, breakdown), `staff` (Fleet, customer service, Admin) or `field` (a vehicle of their own jobs). A car that is not drivable goes `out_of_service` and gets an open-ended `repair` calendar block. `app.complete_incident_step()`.
- `app.swap_vehicle(booking, to_vehicle, by, reason, approved_by, incident, now)`: on-rent bookings only, Admin approval required, writes `booking_vehicle_swaps`, moves the Owner's control block, old car `out_of_service`, new car `on_rent`. `app.booking_km_driven()` joins the two cars' readings from the swap-out and swap-in reports.
- `app.request_tracker_disable()`, `app.approve_tracker_disable()`, `app.reject_tracker_disable()`. The request is stored as `requested` and nothing is sent. Approval needs an Admin and a fresh reading showing speed 0 and ignition off. The guard of 0006 still applies when the command is sent.

## 9. Reconciliation

`payout_reconciliations`, `payout_reconciliation_items`. `app.record_processor_payout(ref, paid_on, amount, items, processor, by)`, `app.match_processor_payout(id)`, `app.match_payout_item(item, by, payment, note)`. An item matches a payment when the processor reference agrees and the amounts are equal. Fee and adjustment items need no payment. Anything unmatched raises the Finance `reconcile` task.

## 10. Objects added

**Tables (7):** `required_shots`, `vehicle_moves`, `task_rules`, `quick_replies`, `incident_steps`, `payout_reconciliations`, `payout_reconciliation_items`. All have row-level security, `admin_all` and an audit trigger.

**Views (7):** `field_job_list`, `work_queue`, `va_finance_queue`, `va_fleet_queue`, `va_cs_queue`, `va_sales_queue`, `admin_queue`. `calendar_entries` replaced.

**Sequence:** `renter_statement_number_seq` (statement numbers `RS-20001` onward).

**Columns:**

| Table | Columns |
| --- | --- |
| `program_settings` | `opening_hours`, `insurer_terms_days`, `incident_report_hours`, `tracker_notice_minutes`, `tracker_reading_max_minutes`, `statement_interest_days`, `deposit_due_warning_business_days`, `holdback_warning_days`, `chase_offer_hours`, `chase_verification_hours`, `handover_schedule_hours`, `take_deposit_lead_minutes`, `job_acknowledge_lead_minutes`, `late_admin_minutes`, `provisional_watch_days`, `turo_expiry_notice_days`, `plate_renewal_notice_days`, `payout_unmatched_business_days`, `early_return_minutes` |
| `condition_reports` | `renter_signature_ref`, `staff_signature_ref`, `renter_declined_to_sign`, `renter_decline_reason`, `car_diagram`, `belongings_found`, `findings`, `completed_at`, `completed_by` |
| `condition_report_damages` | `kind`, `size_cm`, `position`, `status_vs_pickup` |
| `condition_report_photos` | `device_taken_at`, `latitude`, `longitude`, `width`, `height`, `quality_flags`, `purge_after` |
| `booking_line_items` | `assessment_key`, `supporting_refs` |
| `field_jobs` | `auto_created`, `cancel_reason`, `created_by` |
| `tasks` | `sla_minutes`, `wake_at`, `waiting_reason`, `completion_rule`, `completion_note`, `dedupe_key` |

All added with `add column if not exists`.

**Triggers on existing tables:** `tasks_fill_from_rule`, `field_jobs_after_write`, `condition_reports_after_write`, `incidents_after_insert`, `tracker_commands_task`, `bookings_ops_status_after`, and `*_ops_task` on `booking_cancellations`, `booking_extensions`, `identity_verifications`, `coverage_proofs`, `vehicle_onboardings`, `owner_invoices`, `owner_statements`, `vehicle_exits`, `reviews`, `documents`.

**Helper functions not named above:** `app.user_is_field`, `app.user_runs_fleet`, `app.user_runs_finance`, `app.user_works_queue`, `app.from_browser`, `app.add_opening_minutes`, `app.task_due`, `app.task_completion_problem`, `app.field_job_is_move`, `app.return_findings`, `app.set_assessed_line`, `app.money_text`, `app.bulk_rate_vehicles`, and the trigger functions `app.task_fill_from_rule`, `app.field_job_after_write`, `app.condition_report_after_write`, `app.incident_after_insert`, `app.tracker_command_task`, `app.ops_booking_status_after`, `app.ops_task_trigger`.

## 11. Permissions

| Data | Admin | VA Finance | VA Fleet | VA CS | VA Sales | Field | Owner | Renter | Anonymous |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `vehicle_moves` | RW | R | RW | none | none | own, R | none | none | none |
| `required_shots` | RW | R | R | R | R | R | R | R | none |
| `task_rules` | RW | R | R | R | R | none | none | none | none |
| `quick_replies` | RW | R active | R active | R active | R active | none | none | none | none |
| `incident_steps` | RW | R | R, tick non-admin steps | R | none | none | none | none | none |
| `payout_reconciliations` and items | RW | R | none | none | none | none | none | none | none |
| `field_job_list` | none | none | none | none | none | own | none | none | none |
| Work queue views | all | finance | fleet | cs | sales | none | none | none | none |
| Calendar: field jobs | yes | yes | yes | yes | no | no | no | no | no |
| Calendar: vehicle moves | yes | yes | yes | no | no | no | no | no | no |
| Calendar: Turo trips | yes | yes | yes | no | no | no | own vehicles | no | no |

A browser session may execute: `app.master_calendar`, `app.vehicle_calendar`, `app.calendar_preview_change`, `app.staff_field_jobs` (each checks the caller), and the helpers `app.from_browser`, `app.add_opening_minutes`, `app.money_text`, `app.required_shots_for`, `app.field_job_is_move`. Everything else is for `service_role`.

## 12. Events emitted

Dedupe key: `code:entity_id:discriminator`.

| Code | Entity | Emitted when | Discriminator |
| --- | --- | --- | --- |
| `staff_field_job_assigned` | `field_job` | A job is created with an assignee, or given to someone | assignee and time |
| `staff_field_job_changed` | `field_job` | Time, place or vehicle changes, the job is cancelled, or it is taken away | holder and time |
| `renter_deposit_declined` | `booking` | `app.record_deposit_declined()` | payment id, or the time |
| `staff_return_findings` | `booking` | The return report is marked reviewed | report id |
| `renter_damage_found` | `incident` | `app.report_damage_to_renter()` | damage id |
| `renter_deposit_released` | `deposit` | A hold-back is applied or released by `app.settle_deposit()` | applied and released totals |
| `staff_approval_needed` | `deposit`, `task` | A settlement needs an Admin; a task is escalated | `release:` amounts; `escalated` |
| `staff_disable_approval_needed` | `tracker_command` | `app.request_tracker_disable()` | `requested` |
| `owner_document_due` | `vehicle` | `expiry-watch` finds a Turo-Only expiry | expiry date |
| `staff_expiry_watch` | `job_run` | `expiry-watch` finds at least one item | day |

Not emitted here: anything driven by the status of a booking, payment, statement or incident, including `renter_final_statement`, `renter_extra_charge`, `staff_incident_reported`, `staff_breakdown_reported`, `owner_incident_opened`, `renter_accident_instructions`.

## 13. Amounts and times: where each is read from

Every price, fee, rate and threshold the functions use is read at run time.

| Value | Read from |
| --- | --- |
| Rates, kilometre allowance, overage rate, Deposit | The booking's snapshot, which comes from `rate_cards` |
| Late fee per hour, its daily cap multiplier, the grace period | `booking_fee_terms`, then `vehicle_fee_overrides`, then `fee_defaults` (`late_return_fee`: amount, `percent_bps`, `grace_minutes`) |
| Fuel markup, service fee, recharging, cleaning grades, lost key fee, administration fees | The same chain, per fee code |
| Deductible | `bookings.deductible_cents`, from `program_settings.deductible_cents` |
| Non-refundable discount, maximum rental days, hold length, release and hold-back periods, late-damage window | `program_settings` (existing columns) |
| Waiting times and warning windows of the procedures | The 20 `program_settings` columns of section 10 |
| Task queue, priority and due time | `task_rules` |
| Delivery, pickup and overage ranges | `fee_defaults.min_cents`, `max_cents` |
| Amounts named in incident steps | Formatted from the values above when the incident is opened |

A fee that an assessment needs and that is not set raises an error naming it; no fallback amount is used.

Literals that remain, and why:

| Literal | Where | Why |
| --- | --- | --- |
| The seed rows of `task_rules`, `required_shots` and the defaults of the new `program_settings` columns | Data | Starting values; an Admin edits the rows |
| `09:00` and `18:00` | `app.add_opening_minutes()`, `app.job_ops_watch()` | Used only if `opening_hours` lacks a key |
| 10 (per 10% of battery) | `app.assess_check_in()` | The unit of the `recharging` charge in the catalogue, not a price |
| Job hours 06:00 and 18:00, 15-minute cadence | The job wrappers and the cron lines | Same as 0015: the schedule is part of the job, documented in `docs/architecture.md` |
| 1 hour before each daily check; 1 day before a provisional booking's pickup; jobs older than 1 day ignored | `app.job_ops_watch()` | Lead times of internal reminders, not customer-facing; no setting was added |
| 1 hour (and at least 1 minute) | `calendar_entries`, `app.vehicle_calendar()` | The drawn length of a job with no end time |
| 1 minute | `app.swap_vehicle()`, `app.approve_tracker_disable()` | Guards against an empty range and clock skew |
| 30 days | `app.job_reconcile()` | Look-back so payments older than the first recorded payout are not flagged |
| 5 minutes for a Tracker reading | The check on `program_settings.tracker_reading_max_minutes` (1 to 5) | The table guard of 0006 hard-codes 5 minutes and cannot be edited here; the setting can only be stricter |
| `turo_expiry_notice_days` reused for the safety certificate window | `app.job_expiry_watch()` | No separate setting was added |
| Defaults in the signatures of `calc_late_return()`, `calc_fuel_charge()` (0003) | Earlier migration | Not used: the functions here always pass the values |

## 14. Existing tests changed

| File | Test | Change | Reason |
| --- | --- | --- | --- |
| `04_rls.sql` | "finance: sees the finance queue, not the CS queue" | `string_agg(queue, ',')` became `string_agg(distinct queue, ',')` | The new triggers raise Finance tasks from earlier fixtures (cancellations, owner invoices, draft statements), so the finance assistant now sees several finance tasks instead of one. The meaning (only the finance queue) is unchanged |

## 15. Assumptions and decisions to confirm

1. **Renter billing spec has no worked statement or Deposit example.** The tests use the spec's example rates (section 2) and catalogue amounts (section 1) and work the statement by hand.
2. **Nothing moves on a Deposit until the approver acts**, because a card hold can be captured only once.
3. **A hold-back always needs an Admin**, even inside an assistant's limit (the email catalogue lists "a deposit release with a hold-back" as an Admin approval).
4. **The booking closes when the Deposit is settled with nothing held back**, even if a card charge is still pending.
5. **Lines are paid from the Deposit in catalogue order** (`fee_types.sort_order`). A line the Deposit covers only in part is tied to the card payment.
6. **Claim ledger entries are written when the payment is confirmed**, for the full line amount, under the payment the line is tied to.
7. **The kilometre allowance does not grow with late extra days.**
8. **Odour counts as heavy soiling** unless the grade is already heavy or smoking.
9. **Damage lines are an Admin's**: a finance assistant's assessment lists them as pending.
10. **A vehicle swap keeps the booking's Owner, rates and split.** The existing trigger forbids changing them after confirmation, so revenue stays with the original vehicle's Owner even when the replacement belongs to someone else.
11. **A confirmed booking moves only to a car of the same Owner and management mode**, for the same reason.
12. **A renter's agreement to a change, recorded by word, is an Admin's act.** A signed amendment (the blueprint's `booking_change_requests`) is not built here.
13. **A lower price after a change is a refund request** (`reason = 'other'`, pending approval); the booking's lines are not rewritten.
14. **Field staff who record late damage do not notify the renter**; Fleet does, from the incident.
15. **Opening hours default to 09:00 to 18:00 every day.**
16. **An Admin may complete a handover when the Tracker is not reporting**; anyone else is stopped.
17. **`insurer_provisional` watch is part of `ops-watch`**, not a separate daily job.
18. **Finance can read processor transaction references** on payout items. They are identifiers, not tokens.
19. **Admin-queue copies of a task carry no creator**, so the person who caused them does not see the admin queue's row under the existing `tasks` policy.
20. **Calendar function names** are `calendar_preview_change` and `calendar_apply_change`, not the blueprint's `preview_booking_change` and `apply_booking_change`, to avoid replacing a function of the same name from the booking migration.

## 16. Not done, or not verified

- **pg_cron and the Realtime publication** are not present where the tests run, so the four `cron.schedule` calls and the `alter publication` block were not executed.
- **Not built:** automatic cleaning block at return; `renter_pickup_details` and `renter_return_details` events; `booking_change_requests`; the guard that `on_rent` requires `blocks_calendar` on the table itself (checked in `app.complete_handover()` only); the declined-payment fee line (left to `payment-retries`); `leads`-based `enquiry` task, `charge_question`, `match_toll` (other migrations); `covered_by_company_at`.
- **Not covered by a test:** the `list_vehicle` task (needs a full onboarding walk); a handover performed by the Owner of a Self-Managed car; an Owner Booking's damage path (`owner_deductions`); an unattended handover or return; the electric `recharging` line; lost key lines; a claim denied for the renter's breach; the `review_photos` task for swap reports.
- **Shared documents are out of date** and were left alone: `README.md`, `docs/data-model.md`, `docs/permissions.md`, `docs/architecture.md` section 5 (`deposits-due`, `expiry-watch` and the SQL part of `reconcile` now exist; `ops-watch` is new).
