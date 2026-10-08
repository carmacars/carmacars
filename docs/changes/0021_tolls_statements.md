# 0021: tolls, tickets and damages; statements

Migration `supabase/migrations/0021_tolls_statements.sql`, tests `supabase/tests/10_tolls_statements.sql`.

The owner asked for two things. First: "the process for inputting tickets and tolls and damages and matching them to an active or preexisting booking needs to be smooth as well and well built". Second: "car owners' statements need to be generated monthly automatically and we need our own version for admin purposes for our monthly statements per car and per owner and total. that has to be thorough and well done."

This migration runs after 0020 and before 0022. It uses nothing that 0022 creates. No other migration, shared document, email or prototype file was changed.

## Part A. Tolls, tickets and damages

### 1. Intake

| Object | Does |
| --- | --- |
| `app.log_toll_ticket(p, by)` | Single entry ("Save and match"). Validates the row, checks for duplicates, inserts it, runs the matcher, then emits `staff_toll_ticket_logged`. A duplicate or invalid row is refused with the reason |
| `app.import_toll_batch(p, by)` | Bulk import of a statement the server has already parsed. Creates a `toll_import_batches` row. Each row is validated and de-duplicated on its own, both against what is already logged and against earlier rows of the same file, and gets one result: `imported`, `duplicate` or `invalid` with the reason. Returns the counts, the per-row results, how many rows went to each kind of match, and the difference between the rows and the statement total |
| `app.toll_intake_row(row, by, batch, import_unknown)` | The shared step behind both functions |
| `toll_import_profiles`, `app.save_toll_import_profile`, `app.find_toll_import_profile` | The column mapping saved per toll operator and header row. The server applies it again the next time it sees the same header |
| `vehicle_transponders`, `vehicle_plate_history` | Date ranges, with an exclusion constraint so that one transponder or plate is never on two cars at the same time |
| `app.resolve_toll_vehicle(plate, transponder, on)` | Finds the car by transponder, then plate history, then registrations (0002), then the current plate. Stored on the notice as `vehicle_found_by` |

Duplicates are caught in two ways: the same authority and notice number, or the same plate, time and amount. A row is invalid when any of these is missing or unreadable: the authority, the plate or transponder, the time, the amount, or (for anything other than a toll trip) the notice number. A time in the future, or a plate that is not in the fleet, also makes a row invalid ("not ours"). Passing `import_unknown` imports unknown plates anyway. An occurred-at value with no time zone is read as Toronto time.

New `toll_tickets` columns: `time_unknown`, `note`, `external_ref`, `transponder`, `statement_number`, `import_batch_id`, `import_row_no`, `toll_group_id`, `vehicle_found_by`, `match_confidence`, `match_evidence`, `matched_how`, `payment_reference`, `ocr_raw`, `booking_statement_id`, `charged_at`, `charged_by`, `dispute_reason`, `disputed_at`, `named_at`, `named_by`, `forwarded_at`, `closed_reason`, `closed_at`.

A statement's own number is stored in `statement_number`. Each trip keeps its own notice or transaction number, so the existing unique index on authority and notice number still holds and was not changed.

### 2. Matching

`app.match_toll_candidates(vehicle, at, time_unknown)` returns everyone who could have had the car, ranked, with the evidence. It also has a form that takes a notice id.

| Candidate | Rule |
| --- | --- |
| Renter, Owner Booking | The booking actually on rent, from `handed_over_at` (else pickup) to `checked_in_at`, or still on rent. A late return and an extension are covered by Check-in. With a mid-booking swap (`booking_vehicle_swaps`), each car carries only its own part of the booking. Works the same for active and closed bookings |
| Booked but never handed over | Low confidence, never matched automatically, and cannot be confirmed |
| Staff | 0020's `vehicle_moves` |
| Owner | A Turo-Only car. An owner-use calendar block. A Self-Managed car outside a CarmaCars rental. A time before the Enrollment Date or after the Exit Date (`app.vehicle_fee_end`) |
| No one | `unmatched`, with the reason |

The evidence for each candidate: booking number, the renter's first name only, the window, minutes from the start and to the end, position in the window as a percentage, depth, `near_boundary` (inside the margin set by `program_settings.toll_boundary_margin_minutes`, default 30), the late-return, extended, swapped and still-on-rent flags, and the staff member's name and the purpose of the move.

| Decision | When |
| --- | --- |
| `auto` (high) | Exactly one candidate, not near a boundary, and the time is stated |
| `review` (medium) | One candidate near a boundary; time not stated with one party all day; a renter and a staff move that touch (a delivery or collection leg) |
| `review` (low) | Several candidates, or a booking confirmed but never handed over |
| `unmatched` (none) | Nobody on record |

`app.run_toll_match(ticket)` stores the evidence on the notice and applies an automatic match. A notice for review raises the Finance task `review_toll_match`, and an unmatched one raises `match_toll`. Both are due the day after `charge_by`. `app.match_toll_ticket()` (0009) keeps its signature and existing callers. It now reads the top candidate. `app.toll_ticket_admin_fee()` (0009) keeps its signature and now resolves the fee through 0020's `app.booking_fee_term()`.

Confirming: `app.confirm_toll_match(ticket, by, choice)` accepts the suggestion, a candidate by index, or a manual choice (the booking must have been on the car). A renter match below high confidence needs `tracker_proof_document_id`. `app.bulk_confirm_toll_matches(ids, by)` confirms only the high-confidence rows and skips the others with the reason.

### 3. Acting

| Function | Does |
| --- | --- |
| `app.charge_toll_ticket(ids, by, now)` | Groups the notices by booking and statement. Each notice gets one pass-through line (`toll_amount` or `ticket_amount`, no HST). Each group gets one administration fee: one per toll statement and booking, or one per ticket, read from booking fee terms, then vehicle overrides, then the defaults. Lines carry `stage = 'after_return'`, the notice as `supporting_document_id`, and the toll id. After the Check-in statement, a later-charge statement is issued with 0020's `app.issue_booking_statement()`, so the issued statement is never rewritten. Money is then settled with 0020's `app.settle_deposit()`: the Deposit first (including a hold-back), then a pending card charge for the rest. Before the Check-in statement, including on a booking still on rent, the lines wait for that statement. Each group succeeds or fails on its own, and a failure is reported with the reason. Emits `renter_extra_charge` with the notices and the statement |
| `app.charge_after_rental(booking, by, now)` | The shared statement-and-settle step, also used for damage |
| `app.bill_toll_to_owner(id, by)` | An Owner Booking becomes an `owner_deductions` row at cost (`owner_booking_toll` or `owner_booking_ticket`, with the notice as receipt, no fee), which goes on the next statement. Outside the program or Turo-Only, the notice is forwarded. Emits `owner_toll_ticket` with `is_forwarded` |
| `app.mark_toll_company_paid(id, by, reference, paid_at)` | Staff had the car: CarmaCars pays, noted against `staff_user_id` |
| `app.record_toll_authority_payment(id, by, reference, paid_at)` | CarmaCars paid the authority. This is pass-through money going out |
| `app.dispute_toll_ticket`, `app.name_renter_to_authority` (Admin only, emits `renter_named_to_authority`), `app.close_toll_ticket` (with the reason, cancels its tasks) | The other paths |
| `app.job_toll_watch(now)` | Daily from 06:00. A notice still `logged` once `program_settings.toll_unmatched_business_days` business days (default 2) have passed since receipt raises the Admin task `toll_unmatched` (escalated) and `staff_toll_ticket_unmatched`, once per notice |

`charge_by` is set from `program_settings.toll_charge_business_days` (default 3).

### 4. Damage after the rental

`damage_intakes` holds: the vehicle, when the damage was found, when it happened or the window it could have happened in, where it is and what it is, photos, the reports either side (`before_report_id`, `after_report_id`), the estimate or invoice (kind, amount, document, shop), the match and evidence, the incident, the route, the statement, and the company expense.

| Function | Does |
| --- | --- |
| `app.log_damage(p, by)` | Fleet, Finance or an Admin. Matches straight away. A time that is given uses the toll matcher. Otherwise every rental and staff move in the window is listed, and the pickup and return reports of one booking on either side make it high. Anything less raises `review_damage_match` |
| `app.confirm_damage_match(intake, by, choice)` | Suggestion, index, or manual choice |
| `app.bill_damage(intake, admin, now, override_reason)` | An Admin only. Opens the incident with 0020's `app.record_late_damage()` when the after-report is the booking's return report, which also reports to the renter inside the 48 hours. Otherwise uses `app.open_incident()`. Adds the estimate or invoice as an `incident_costs` row, then calls 0020's `app.assess_check_in()`, which applies the threshold rule. Under the deductible: damage at cost, loss of use and the administration fee. At or over: `app.open_claim()`, the deductible and the claim fee. On an Owner Booking: nothing under the deductible, and an `owner_booking_deductible` deduction when a claim is made. A renter's lines are then charged through `charge_after_rental` (event `renter_extra_charge`). Staff or nobody: a `company_expenses` row in `repair_absorbed` noted against the staff member. Turo-Only: route `turo`. Outside the program: the Owner repairs |

The check-in assessment is not duplicated.

### 5. Work queues

| View | Buckets |
| --- | --- |
| `toll_work_queue` | `unmatched`, `needs_review`, `matched_not_charged`, `matched_not_billed`, `matched_staff`, `charged_not_notified`, `disputed`. Each row has `age_days`, `age_band`, `due_soon` (setting `toll_due_soon_days`) and `past_charge_by` |
| `toll_work_queue_summary` | Count and amount by bucket and age band |
| `damage_work_queue` | `unmatched`, `needs_review`, `needs_estimate`, `ready_to_bill` |

## Part B. Statements

### 6. Owner statements

0015's job still drafts every Owner's statement through `app.build_owner_statement()`. The tests check every case on the list: owners with no activity, Self-Managed, Turo-Only, shareholder cars at 90/10, insurer-billed bookings, promo and staff discounts (0016), kickbacks, deductions, prepaid months, arrears, late fees, toll deductions from part A, and post-rental charges from 0020. Gaps found and fixed (the function was created again with these changes only):

1. **A car in the program with no activity had no block.** Every vehicle enrolled during the month now gets a block, even at zero.
2. **Owner Revenue raised after a booking was paid out was never paid to the Owner.** For example, mileage or late extra days billed later through 0020. `app.sync_later_owner_revenue()` now writes the difference to `owner_credits` (`later_rental_revenue`) once every Owner Revenue line is collected. It shows as a `later_revenue` line on the next statement. `owner_statement_vehicles.credits_cents` and `owner_statements.credits_cents` hold it. HST on the payout includes it.
3. **An approved statement could not be corrected.** `app.reissue_owner_statement(statement, admin, reason)` voids the statement and gives back everything it applied: invoice deductions, deductions, credits, kickbacks, splits, Turo trips and the Owner's balance. It cancels the payout and builds version + 1 (`version`, `supersedes_statement_id`, `voided_at`, `voided_by`, `void_reason`). This works only while the payout is not sent. After that, the correction goes on the next statement. The unique key on owner and month became a unique index on rows that are not void. Two `status_transitions` rows were added: an invoice that is `deducted` or `partially_deducted` may return to `in_arrears` when the statement that deducted it is reissued.
4. **Nothing recorded issue or payment.** `app.issue_owner_statement(statement, by, document)` sets `sent_at` and the PDF and emits `owner_statement_ready`. `app.record_owner_payout(statement, admin, reference, paid_at)` moves the payout from sent to paid. 0007's trigger then marks the statement paid.

`app.approve_owner_statement()` (0007) was created again, unchanged apart from marking credits as credited.

Per-vehicle breakdown for the owner portal: `app.owner_statement_breakdown(statement, by)` returns JSON with each vehicle block and every line with its booking number. Finance and Admins can read any statement. The Owner can read their own once it is approved. The view `owner_statement_vehicle_lines` has the same rows under the same rule.

### 7. CarmaCars' monthly statements

`company_statements` (one per month: `draft` or `final`, `checks`, `ties_ok`, `tie_problems`) and `company_statement_lines` (levels `vehicle`, `owner` and `total`, same columns at every level).

**Basis.** Earned: rentals and their charges count in the month the rental ends (the owner statements' month). A later-charge statement counts in the month it is issued. Owner fees count in the month they cover. Cash: `cash_collected_cents`, `cash_refunded_cents`, `cash_paid_out_cents` and `refunds_cents` are counted by the day the money moved. Point in time: `deposits_held_cents` and `claim_balance_cents` as at the build. Every revenue column is on the earned basis, and the cash columns sit beside it.

| Group | Columns |
| --- | --- |
| Fleet | `days_in_program`, `days_available` (less service, repair, owner, exit and Turo owner-use blocks), `days_rented` (renters and Turo trips), `owner_days`, `utilization_bps`, `rentals_ended`, `billable_days`, `avg_daily_rate_cents`, `revpad_cents` |
| Rentals | `rental_revenue_cents`, `mileage_cents`, `kickbacks_cents`, `owner_revenue_cents`, `revenue_share_cents` (company share), `owner_share_out_cents` |
| Discounts | `discounts_cents`, `discounts_owner_cents`, `discounts_company_cents` (who bore them, in the split's proportion; 0016's rule) |
| Company fees | `company_fees_cents`, `company_fees_by_type` (by charge type, net of refunds) |
| Turo | `turo_gross_cents`, `turo_fees_cents`, `turo_revenue_share_cents`, `turo_extras_cents`, `turo_owner_cents` |
| Owner fees | `insurance_fees_cents`, `tracker_fees_cents`, `install_fees_cents`, `other_owner_fees_cents`, `prepaid_last_month_cents`, `owner_fees_hst_cents`, `owner_fees_collected_cents`, `owner_fees_deducted_cents`, `owner_fees_outstanding_cents`, `late_fees_cents` |
| Insurers | `insurer_billed_cents`, `insurer_collected_cents` |
| Losses | `refunds_cents`, `chargebacks_cents`, `uncollected_cents` |
| Pass-through | `pass_through_in_cents`, `pass_through_out_cents`, `company_paid_tolls_cents` |
| Claims | `claim_money_in_cents`, `repairs_out_cents`, `claim_balance_cents`, `claim_surplus_cents` |
| Liabilities and tax | `deposits_held_cents`, `hst_collected_cents`, `hst_refunded_cents`, `hst_paid_cents` |
| Costs | `processing_fees_cents`, `expenses_cents`, `investor_returns_cents` (total) |
| Owner level | `owner_payout_cents`, `owner_deductions_cents`, `kickbacks_earned_cents` |
| Result | `company_net_cents` = Revenue Share + Turo share + Turo extras + company fees + owner fees + late fees + claim result, less processing fees, CarmaCars-paid tolls, expenses and investor returns. This is before costs the platform does not hold |

Month over month and year to date: the view `company_statement_report` (and `company_statement_vehicles`, `company_statement_owners`, `company_statement_totals`) adds last month's rental revenue and net, the change, and the year-to-date rental revenue, Revenue Share, company fees, net and days rented.

`company_expenses` holds expenses entered by hand: category (`company_expense_categories`, each with an account), amount, HST, and optionally a vehicle, an owner, a staff member and a document. A final month accepts no new or changed expense.

Chart of accounts: `gl_accounts` holds the payment set-up accounts plus 5100, 5110 and 5200 (added; to confirm with the accountant). `fee_types.gl_account` is set on every charge type, and a trigger gives a new charge type its account from its class. `gl_account_map` covers owner invoice lines, payouts and statement items.

`app.build_company_statement(month, by)` (a draft only) runs these reconciliation checks:

1. The vehicles sum to the owners, and the owners sum to the total, for nine money columns.
2. Rental revenue matches `booking_splits` directly.
3. Company fees match the charge lines directly.
4. Every succeeded payment in the month is tied to a vehicle's booking or owner invoice. The difference is named.
5. Refunds recorded as paid match the refund payments.
6. Owner payouts paid match their statements and match the owner lines.

A failed check is recorded on the draft (`ties_ok`, `tie_problems` naming the difference) and raises the urgent Admin task `company_statement_tie`, which a later build that reconciles closes. `app.finalize_company_statement(month, admin)` rebuilds first, and a failed check blocks it with the same message. On success the month is final (never rebuilt) and `staff_monthly_statements_ready` is emitted. `app.company_statement_rows(month, level)` is for the server's screens.

Monthly job: `app.job_company_statement_draft(now)` drafts last month's statement on the day the owner statements are drafted (`program_settings.company_statement_draft_days_before_payout`, default 5, before the payout date) from 06:00, and raises `review_company_statement`. Both new jobs are scheduled with pg_cron in 0015's pattern: `carmacars-toll-watch` at minute 18, `carmacars-company-statement` at minute 20.

### 8. CSV exports

`app.company_statement_csv(month, level)` gives every column of one level. `app.owner_statement_csv(statement)` gives every line with its vehicle and booking. `app.company_ledger_csv(month)` gives one signed row per account, vehicle and item: revenue share, owner share, pass-through in and out, owner fees, prepaid, late fees, HST, claims, processing fees, refunds, renter fees by their charge type's account, expenses by their category's account, investor returns, and HST on payouts. `app.csv_field()` does the quoting.

## Objects added

**Tables (12):** `gl_accounts`, `gl_account_map`, `vehicle_transponders`, `vehicle_plate_history`, `toll_import_profiles`, `toll_import_batches`, `damage_intakes`, `company_expense_categories`, `company_expenses`, `owner_credits`, `company_statements`, `company_statement_lines`. Each has row-level security, `admin_all` and an audit trigger.

**Views (8):** `toll_work_queue`, `toll_work_queue_summary`, `damage_work_queue`, `owner_statement_vehicle_lines`, `company_statement_report`, `company_statement_vehicles`, `company_statement_owners`, `company_statement_totals`.

**Sequences:** `toll_import_batch_number_seq` (TB-1001), `damage_intake_number_seq` (DI-1001).

**Columns:** `program_settings`: `toll_boundary_margin_minutes`, `toll_unmatched_business_days`, `toll_charge_business_days`, `toll_due_soon_days`, `company_statement_draft_days_before_payout`. `fee_types.gl_account`. The `toll_tickets` columns listed in section 1. `owner_statements`: `version`, `supersedes_statement_id`, `credits_cents`, `voided_at`, `voided_by`, `void_reason`. `owner_statement_vehicles.credits_cents`. `owner_statement_lines.owner_credit_id`, and the line type `later_revenue`.

**Functions (new):** `default_gl_account`, `fee_type_gl_default`, `norm_plate`, `resolve_toll_vehicle`, `match_toll_candidates` (two forms), `apply_toll_match`, `run_toll_match`, `toll_intake_row`, `log_toll_ticket`, `save_toll_import_profile`, `find_toll_import_profile`, `import_toll_batch`, `confirm_toll_match`, `bulk_confirm_toll_matches`, `charge_after_rental`, `charge_toll_ticket`, `bill_toll_to_owner`, `mark_toll_company_paid`, `record_toll_authority_payment`, `dispute_toll_ticket`, `name_renter_to_authority`, `close_toll_ticket`, `match_damage_candidates`, `apply_damage_match`, `log_damage`, `confirm_damage_match`, `bill_damage`, `company_expense_guard`, `job_toll_watch`, `sync_later_owner_revenue`, `reissue_owner_statement`, `issue_owner_statement`, `record_owner_payout`, `owner_statement_breakdown`, `multirange_days`, `vehicle_month_days`, `company_month_lines`, `company_statement_sum_columns`, `build_company_statement`, `finalize_company_statement`, `company_statement_rows`, `csv_field`, `company_statement_csv`, `owner_statement_csv`, `company_ledger_csv`, `job_company_statement_draft`. **Replaced (same signature):** `match_toll_ticket`, `toll_ticket_admin_fee`, `build_owner_statement`, `approve_owner_statement`.

**Task rules (6):** `match_toll`, `review_toll_match` (finance, procedure 11), `toll_unmatched` (admin), `review_damage_match` (finance, procedure 5), `review_company_statement`, `company_statement_tie` (admin).

## Permissions

| Data | Admin | VA Finance | VA Fleet | VA CS | VA Sales | Field | Owner | Renter | Anonymous |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `gl_accounts` | RW | R | R | R | R | none | none | none | none |
| `gl_account_map`, `company_expense_categories` | RW | R | none | none | none | none | none | none | none |
| `vehicle_transponders`, `vehicle_plate_history` | RW | R | RW | none | none | none | none | none | none |
| `toll_import_profiles` | RW | RW | none | none | none | none | none | none | none |
| `toll_import_batches`, `damage_intakes` | RW | R | R | none | none | none | none | none | none |
| `company_expenses` | RW | RW (not a final month) | none | none | none | none | none | none | none |
| `company_statements`, lines, report views | RW | R | none | none | none | none | none | none | none |
| `owner_credits` | RW | R | none | none | none | none | own, R | none | none |
| `toll_work_queue`, summary, `damage_work_queue` | yes | yes | yes | no | no | no | no | no | no |
| `owner_statement_vehicle_lines` | yes | yes | no | no | no | no | own, approved | no | no |

Every function in this migration is for `service_role`. A browser may run only the helpers `app.norm_plate`, `app.csv_field` and `app.multirange_days`.

## Events emitted

Dedupe key: `code:entity_id:discriminator`.

| Code | Entity | When | Discriminator |
| --- | --- | --- | --- |
| `staff_toll_ticket_logged` | `toll_ticket` | A notice is logged and matched (single entry or import) | `logged` |
| `staff_toll_ticket_unmatched` | `toll_ticket` | `job_toll_watch` finds it still unmatched | received date |
| `renter_extra_charge` | `booking_statement` | A toll, ticket or damage is charged on a later-charge statement | `toll` or `damage` |
| `owner_toll_ticket` | `toll_ticket` | Billed to the Owner (`is_forwarded` false) or forwarded (true) | `billed` or `forwarded` |
| `renter_named_to_authority` | `toll_ticket` | An Admin names the renter | `named` |
| `owner_statement_ready` | `owner_statement` | `issue_owner_statement` | `v` + version |
| `staff_monthly_statements_ready` | `company_statement` | `finalize_company_statement` | `final` |

`renter_named_to_authority` and `staff_monthly_statements_ready` are not in `emails/catalogue.json` yet. The blueprint lists the first as "to be added", and 0018 may add both. `renter_damage_found` is emitted by 0020's `report_damage_to_renter`, which `bill_damage` calls.

## Amounts and times: where each is read from

| Value | Read from |
| --- | --- |
| Toll and ticket administration fees | `app.booking_fee_term()`: booking term, vehicle override, class default, general default |
| Damage lines, deductible, claim threshold | 0020's assessment and 0008's `open_claim` (booking and settings) |
| Boundary margin, unmatched business days, charge-by business days, due-soon days, company draft day | The five new `program_settings` columns |
| Task queues, priorities and due times | `task_rules` |
| HST | The booking's `hst_bps`, through `public.calc_hst` |

Literals that remain, and why:

| Literal | Where | Why |
| --- | --- | --- |
| 06:00 and the cron minutes 18 and 20 | The two job wrappers and the cron lines | 0015's pattern: the schedule is part of the job |
| Age bands 0 to 2, 3 to 7, 8 to 30, over 30 days | `toll_work_queue` | Display buckets, not a business rule |
| 1 day before the finding | `match_damage_candidates` | The default window when neither a report nor a window is given |
| The account numbers and the 6 task rule rows | Data | Starting values; an Admin edits the rows |
| 0008's fallbacks in `open_claim` ($50 and $75) | Earlier migration | Used only when the fee defaults are missing; not changed here |

## Existing tests changed

| File | Assertion | Was | Now | Why |
| --- | --- | --- | --- | --- |
| `05_jobs.sql` | "J without pg_cron the migrations schedule nothing; with it, ..." | 6 jobs | 12 jobs (0015's five, 0016's one, 0020's four, 0021's two) | Two new pg_cron jobs. The count was already stale after 0020; the assertion only runs where pg_cron exists |

No other assertion changed. Final run: 1956 passed, 0 failed (10 tolls statements: 146 passed).

## Assumptions and decisions to confirm

1. **A notice charged before the Check-in statement** (the booking still on rent, or returned with no statement yet) waits on the booking and goes on the Check-in statement. The renter hears about it with that statement, so `notified_at` stays empty and the row shows as "charged, not notified".
2. **A hold-back stays held.** When a toll is taken from a held-back Deposit, the rest of the hold-back stays held: 0020's `settle_deposit` keeps the existing hold-back unless a plan changes it.
3. **Auto-match records `matched_by` as empty**, with `matched_how = 'auto'`. A person's confirmation (single or bulk) fills it in.
4. **A booking swap for utilization** counts on the booking's current car, but tolls follow each car's part.
5. **Owner credits for later revenue keep the kickback and the share percentage** of the paid split, and count on the day they are found (`incurred_on`), so they land on the next statement built after that day. A reissue waives the open credits of the bookings it releases, because the rebuilt split then carries the revenue itself. A refund after a credit is still worked out by 0016's split without the credit, so it can under-deduct.
6. **Reissue only before the payout is sent.** After that, the correction goes on the next statement, as the blueprint says.
7. **Company statement month** is the month a rental ends, the same as the owner statements.
8. **Deposits held and claim balances** are as at the build, so a rebuild later in the month moves them.
9. **The `5100`, `5110` and `5200` accounts** are additions to the chart, to confirm with the accountant.

## Not done, or not verified

- **pg_cron** is not present where the tests run, so the two `cron.schedule` calls were not executed.
- **Not built:** OCR of notices (blueprint 3.2, an app module); fetching the tracker position for proof (the app stores the document and passes its id); the declined-card retry; "Adjustments to earlier months" (the difference between a frozen month and a fresh build); processor payout tie (`payout_reconciliations`) in the company statement; the bookings funnel and investor capital sections of blueprint 11 section 3.3.
- **Shared documents are out of date** and were left alone: `docs/permissions.md`, `docs/data-model.md`, `docs/architecture.md` section 5.
