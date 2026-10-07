# Data model

101 tables in migrations 0001 to 0014 (`supabase/migrations/`); 0015 adds the scheduled job functions and no table. Standard PostgreSQL 15 or later.

**Conventions**

- **Money** is `bigint` integer cents, CAD. Column names end in `_cents`. Percentages are integer basis points (`_bps`; 3500 = 35%). HST is stored on every line (`hst_applies`, `hst_cents`), never recomputed from a total.
- **Rounding** is to the cent, half up (`calc_bps`, `calc_hst`). A credit mirrors its charge.
- **Time** is `timestamptz`, stored in UTC. Business dates (the 1st, 10th, 15th, 18th; "the month a rental ends") are Toronto calendar dates, taken with `app.local_date()` and never from the UTC date. The test run sets the session time zone to UTC to prove nothing depends on the server's zone.
- **Billable days** and "days starting Friday or Saturday" are measured on the Toronto clock, so 10:00 to 10:00 across a daylight-saving change is whole days. **Cancellation notice** (24 and 48 hours) is elapsed time.
- **Business days** are Monday to Friday except the dates in `holidays` (`app.add_business_days()`).
- **Snapshots.** A booking stores its rates, fee terms, owner, management mode and revenue share when it is made, and always uses them.
- **Append-only** tables: `audit_log`, `status_history`, `claim_ledger_entries`, `incident_events`, `data_access_log`; `tracker_commands` and `messages` cannot be deleted.
- **Supabase seam:** `app.uid()` only.

## 1. Tables by group

### Foundation (0001)

| Table | Holds |
| --- | --- |
| `users` | One row per login; id equals the auth user's id |
| `user_roles` | Roles per user: admin, va, field, owner, renter (a user may hold several) |
| `staff_profiles` | VA function (finance, fleet, cs, sales) or field function; referral code (field only); Single Limit and Dual Approval Threshold |
| `program_settings` | Dated rows of the standard numbers: HST, the 15th / 18th / 10th, Late Fee, Install Fee, deductible, kickback rate, shareholder 10%, 30-day maximum, minimum fleet, retention periods |
| `holidays` | Dates that are not business days |
| `documents` | One row per stored file: kind, bucket and path, retention class, legal hold, links to booking / owner / vehicle / renter / incident / claim / investor |
| `signature_requests` | A document opened for signature in the platform's built-in signing, with status and the signed copy |
| `signature_records` | Each signer: role, time, method, IP, initials |
| `audit_log` | Every insert, update and delete on audited tables: who, when, before, after |
| `job_runs` | One row per scheduled job run, keyed so a run cannot repeat (claimed by `app.job_claim()`, migration 0015) |

### Owners and vehicles (0002)

| Table | Holds |
| --- | --- |
| `owners` | Legal name, type, contact, HST number, referral code, shareholder flag, payout method, balance carried forward |
| `owner_payout_accounts` | Bank details for payouts (admin and the owner only) |
| `owner_payment_methods` | Debit authorization and card on file: display details |
| `owner_payment_method_secrets` | Processor tokens for the above (admin only) |
| `owner_agreements` | One live Enrollment Agreement per owner (and one Title Agreement), with the three initialled confirmations |
| `owner_agreement_forms` | Forms A to E of the Title Agreement, per agreement or per vehicle |
| `vehicles` | VIN, plate, class, status, management mode, shareholder flag, derived `billing_case`, enrollment and exit dates, arrears flag, "18 to 20 allowed" |
| `vehicle_schedules` | Each signed Vehicle Schedule entry (including Additional Vehicle Schedules): mode, onboarding method, Insurance Fee, Tracker Fee, Install Fee, Revenue Share, lender, lien |
| `vehicle_fee_history` | Fee terms in force over time; a notice needs 30 days; a share change needs a new schedule |
| `vehicle_onboardings` | The per-vehicle onboarding record and its status |
| `vehicle_registrations` | How CarmaCars appears at the registry (Title Schedule) |
| `vehicle_exits` | Notice, Exit Date, who pays transfer-back fees, Form E |
| `vehicle_buyouts` | Owner's offer, Black Book value, price, outcome |
| `onboarding_method_info` | The four methods and their estimates (information only; never billed) |
| `owner_fee_grid` | The standard grid (starting point only) |
| `turo_listings` | Turo-Only listing, insurance and plate expiry |
| `turo_trips` | Each Turo trip: gross, Turo's fees, net, Revenue Share, owner's amount (the Turo-Only payout record) |
| `vehicle_calendar_blocks` | Service, repair, owner and exit blocks |
| `vehicle_listings` | Website listing and where it is published |
| `photo_jobs`, `vehicle_photos` | Interface to the photo pipeline; listing photos |

### Pricing (0003)

| Table | Holds |
| --- | --- |
| `fee_types` | The charge catalogue: every renter charge with its unit, HST rule, stage, refund rule, D / V / B flags, and who it belongs to |
| `fee_defaults` | Admin defaults (D), dated, optionally per vehicle class, with caps and allowed ranges |
| `rate_cards` | Per-vehicle rates (V): daily, weekend, weekly, monthly, km per day, overage per km, deposit, delivery and pickup fee; dated, never overlapping |
| `vehicle_fee_overrides` | Any other fee set for one vehicle |

### Renters (0004)

| Table | Holds |
| --- | --- |
| `renters` | The account: name, contact, identity status, first completed booking, block flag |
| `drivers` | The renter and each additional driver: birth date and licence |
| `payment_methods` | Card on File: brand and last four digits only |
| `payment_method_secrets` | Processor tokens (admin only) |
| `identity_verifications` | Each check: method, result, images, purge date |
| `consents` | The exact wording shown and when it was accepted |

### Bookings and renter money (0005)

| Table | Holds |
| --- | --- |
| `bookings` | Type (standard, non-refundable, owner), status, renewal link, times, billable days (1 to 30), rate snapshot, discount, deposit, coverage option, referrer, Check-in readings |
| `booking_drivers` | Drivers as printed in the Summary, with age band and identity result |
| `booking_fee_terms` | Every fee rate and cap that applies to this booking, and its source (default, vehicle, booking override) |
| `coverage_proofs` | Proof for Coverage Option 1, 2 or 3 and who confirmed it |
| `booking_line_items` | Every charge: type, quantity, unit amount, amount, HST, **revenue class**, stage, payment, override, void |
| `payments` | Charges, holds, captures, releases and refunds: amount, status, decline count, retry time, dispute status |
| `payment_processor_details` | Processor ids and fees (admin only) |
| `payment_attempts` | Each attempt on a payment |
| `deposits`, `deposit_events` | Amount, hold or charge, expiry, applied, held back and why, released, carried over to a renewal |
| `refunds`, `refund_allocations` | Each refund with its approver; the refund spread over the booking's lines |
| `booking_cancellations` | The three times, who cancelled, the tier, refund and retained amounts |
| `disputes` | Chargebacks: evidence, Owner Revenue withheld and reversed |
| `booking_extensions` | Each extension: repriced total, difference, paid and confirmed before the return time |
| `booking_renewals` | Link between a booking and its renewal; deposit carried |
| `booking_vehicle_swaps` | Replacement vehicle after a breakdown |
| `booking_statements` | Itemized statements sent to the renter |
| `booking_splits` | Per booking: kickback, Owner Revenue, company share, owner payout, company-only and pass-through totals, payout month |

### Operations (0006)

| Table | Holds |
| --- | --- |
| `field_jobs` | Each piece of in-person work and who it is assigned to |
| `condition_reports` | Part 4 of the agreement: baseline, pickup, return, swap, exit |
| `condition_report_damages`, `condition_report_photos` | Marked damage; the photo set in its fixed order |
| `tasks` | VA work queues (finance, fleet, cs, sales, admin) with escalation |
| `message_templates`, `messages` | T1 to T26; the log of every message sent or received |
| `daily_checks` | Opening and closing checks |
| `tracker_devices`, `tracker_status` | Devices and the latest reading per device |
| `tracker_access_blocks` | When an owner's lock, alarm and shut-off are blocked |
| `tracker_commands` | The command log: who, why, approval, the reading before, result |
| `fleet_reports`, `fleet_report_vehicles`, `fleet_counts` | The franchisor report due on the 1st; weekly recounts |

### Owner billing (0007)

| Table | Holds |
| --- | --- |
| `owner_invoices`, `owner_invoice_lines` | One invoice per vehicle per month (and the upfront invoice): fees, HST, Late Fee, paid, deducted, status |
| `vehicle_prepaids` | Prepaid first and last month's Insurance Fee: applied, remaining, refund due |
| `owner_deductions` | The other things that may come off a payout: owner costs paid, claim shortfall, refund or chargeback share, agreed amounts |
| `referral_kickbacks` | One per qualifying booking: referrer, base, amount, status |
| `owner_statements`, `owner_statement_vehicles`, `owner_statement_lines` | The monthly statement: a block per vehicle, each rental and deduction as a line, owner totals |
| `payouts` | Every payment out (owner statement, Turo-only, prepaid refund, total-loss balance, claim profit, payroll kickbacks, investor return or redemption) and its approval |

### Incidents, claims, tolls (0008, 0009)

| Table | Holds |
| --- | --- |
| `incidents`, `incident_events`, `incident_costs` | The incident, its timeline, and the parts of the Damage cost |
| `claims` | One per damage event: path (at cost, fleet policy, total loss, Turo), deductible, result, settlement order |
| `claim_ledger_entries` | The per-claim ledger of money in and out |
| `toll_tickets` | Each notice: amount, who had the car, administration fee, how it was charged |

### Investors (0010)

| Table | Holds |
| --- | --- |
| `investors`, `investor_bank_accounts` | The register; bank account for payments |
| `investment_agreements` | The agreement, Schedules C and D, exemption relied on |
| `investments` | Each amount invested: principal, Yearly Percentage, Investment Date, Lockup End Date, reinvested, redeemed |
| `investment_elections` | Pay monthly or reinvest, and the month the choice takes effect |
| `investment_returns` | One Return per investment per Return Month |
| `investment_redemptions`, `investment_transfers` | Redemption on six months' notice, purchase on request, transfer with consent |

### Control (0011 to 0014)

| Table | Holds |
| --- | --- |
| `status_transitions` | The only status changes the database accepts |
| `status_history` | Every status change, with who and when |
| `data_access_log` | Staff searches for, and opens of, older customer records |

## 2. Status flows

Enforced by `app.enforce_status_flow()` from `status_transitions`. A change not listed is refused. A row may be inserted in any status, which is how the manual records kept before the platform are imported.

**Booking**

```
tentative ──▶ pending_payment ──▶ confirmed ──▶ on_rent ──▶ returned ──▶ closed
    │               │                 │
    │ (Owner Booking: straight to confirmed)
    ▼               ▼                 ▼
 expired / cancelled / declined   cancelled / no_show
```

| To | The database also requires |
| --- | --- |
| `confirmed` | Agreement signed; payment of the booking total succeeded; a saved card (not for an Owner Booking) |
| `on_rent` | Every driver's identity verified; a Coverage Option confirmed and the Deposit taken (not for an Owner Booking); the pickup Condition Report; vehicle available. Sets the owner control block on a managed rental |
| `returned` | The return Condition Report. Ends the control block, moves the vehicle to cleaning, sets the Deposit release date, records the renter's first completed booking, computes the split |
| `cancelled`, `no_show` from `confirmed` | A `booking_cancellations` row (the tier is computed by the database) |

**Vehicle**

```
onboarding ──▶ ready_to_list ──▶ available ◀──▶ on_rent
     │                              ▲  │           │
     ▼                              │  ▼           ▼
  declined                       cleaning ◀── out_of_service
                                    
any live status ──▶ exit_notice ──▶ exited          available / on_rent / out_of_service ──▶ total_loss
```

**Owner onboarding (per vehicle)**

```
intake ─▶ terms_set ─▶ documents_sent ─▶ documents_signed ─▶ upfront_paid ─▶ registry_booked ─▶ registered ─▶ tracker_installed ─▶ on_fleet_policy ─▶ enrolled
                                              │  Turo-Only ───────────────────────────────────────────────────────────────────────────────────────────▶ enrolled
                                              │  shareholder-owned (no upfront charges) ─▶ registry_booked
any step before enrolled ─▶ declined or withdrawn
```

`enrolled` sets the vehicle's Enrollment Date to the Toronto date of the written confirmation and opens its fee terms.

**Claim**

```
opened ─▶ submitted ─▶ accepted ─▶ in_repair ─▶ repaired ─▶ settling ─▶ closed
   │          │ └▶ denied ─▶ in_repair or closed
   │          └▶ total_loss ─▶ settlement_received ─▶ distributed ─▶ closed
   └▶ in_repair (under $2,500: no insurer)        └▶ withdrawn
```

**Owner invoice**

```
draft ─▶ issued ─▶ processing ─▶ paid
            │           └▶ failed (+ $50 Late Fee) ─▶ retry_processing ─▶ paid
            └▶ paid (card, e-Transfer)                       └▶ in_arrears ─▶ partially_deducted ─▶ deducted
                                                                    └▶ paid / deducted
draft or issued ─▶ void          paid ─▶ failed (a debit returned after settlement)
```

## 3. Where each billing rule lives

### Renter billing specification

| Section | Rule | Where |
| --- | --- | --- |
| 1 | Charge catalogue, D / V / B, HST, "belongs to" | `fee_types`, `fee_defaults`, `rate_cards`, `vehicle_fee_overrides`, `booking_fee_terms`; resolved by `effective_fee()` |
| 1 | Each charge as a tagged line with HST | `booking_line_items.revenue_class`, `hst_cents` |
| 1 | Per-day fees with per-rental caps | `calc_capped_per_day()` |
| 1 | Mileage overage; fuel; late return; loss of use; interest | `calc_mileage_overage()`, `calc_fuel_charge()`, `calc_late_return()`, `calc_loss_of_use()`, `calc_monthly_interest()` |
| 1 | Damage under / over $2,500, deductible, administration fees | `calc_damage_billing()`, `app.open_claim()` |
| 2 | Billable days; rate selection; 30-day maximum | `calc_billable_days()`, `calc_rental_charge()`; check constraints on `bookings` |
| 3 | Deposit: hold or charge, expiry, hold-back, release, carry-over | `deposits`, `deposit_events`, `calc_deposit_method()`, `app.guard_deposit()`; release date set at Check-in |
| 4 | Confirmed only when paid; deposit before handover; verification before release | `app.booking_before_write()` |
| 5 | Cancellation tiers, 95% rule, non-refundable, CarmaCars cancels | `calc_cancellation()`, `calc_refund_bps()`, `app.booking_cancellation_fill()` |
| 5 | Retained amount split across lines | `app.allocate_refund()`, `refund_allocations` |
| 6 | Extension repricing; renewal as a linked booking | `calc_extension()`, `booking_extensions`, `bookings.renews_booking_id`, `booking_renewals` |
| 7 | Declined payment fee and retries; chargebacks | `payments`, `payment_attempts`, `calc_payment_retry_at()`, `disputes` |
| 8 | Kickback, Owner Revenue, company share, owner payout | `calc_kickback()`, `calc_booking_split()`, `app.kickback_ineligible_reason()`, `app.compute_booking_split()`, `booking_splits` |
| 9 | Owner rentals | `bookings.booking_type = 'owner'` and its check constraint; no split; tolls at cost |

### Owner billing specification

| Section | Rule | Where |
| --- | --- | --- |
| 1 | Amounts from the signed Vehicle Schedule | `vehicle_schedules`, `vehicle_fee_history`, `app.vehicle_terms()` |
| 1 | Upfront: Install Fee and first and last month | `app.issue_upfront_invoice()`, `vehicle_prepaids` |
| 1 | Monthly invoice per vehicle on the 15th, pro-rated, prepaid applied | `app.generate_owner_invoices()`, `calc_fee_days()`, `calc_prorated_fee()` |
| 1 | Fees stop on a total loss | `vehicles.total_loss_decided_on`, `app.vehicle_fee_end()` |
| 2 | Owner Revenue, Revenue Share, when a rental counts | `app.compute_booking_split()`; `booking_splits.counts_on`, `payout_month`, `uncollected_cents` |
| 2 | Deductions allowed, negative balance, HST on payout | `app.build_owner_statement()`, `owner_deductions`, `owners.balance_carried_forward_cents` |
| 3 | The four cases | `vehicles.management_mode`, `is_shareholder_owned`, `billing_case`; `bookings.company_share_bps`; `turo_trips` |
| 4 | Fees billed separately, not netted | Invoices and statements are separate records; deduction happens only from `in_arrears` |
| 5 | Monthly statement | `owner_statements`, `owner_statement_vehicles`, `owner_statement_lines`; the information block is read from `owner_invoices`, `vehicle_prepaids` and the `owner_claims` view |
| 6 | 15th fails: $50; 18th retry; arrears; next 10th deduction; other vehicles; 30 days | `app.owner_invoice_status_effects()`, the owner invoice flow, `removal_allowed_on`, `arrears_moved` lines, `app.vehicle_bookable()` |
| 7 | Claims, the per-claim ledger, shortfall, total-loss order, shareholder 90/10 | `claims`, `claim_ledger_entries`, `calc_claim_result()`, `app.settle_claim()`, `calc_total_loss()`, `app.record_total_loss_settlement()` |
| 8 | Referral Kickback | `referral_kickbacks`, `app.resolve_referrer()`, `app.kickback_ineligible_reason()` |
| 9 | Exit: notice, final month, transfer-back fees, buyout | `vehicle_exits`, `calc_retransfer_payer()`, `vehicle_buyouts`, `calc_buyout_price()` |
| 10 | Worked month | `supabase/tests/02_owner_month.sql` |

### Other rules

| Rule | Where |
| --- | --- |
| Tracker: who, why, never while moving; owner controls blocked during a managed rental | `tracker_commands` and its check, `app.guard_tracker_command()`, `tracker_access_blocks` |
| Franchise: monthly fleet report, 10-vehicle minimum | `app.fleet_count()`, `app.build_fleet_report()`, `app.watch_fleet_minimum()` |
| Investors: lockup, monthly Return, reinvestment, redemption notice | `calc_investment_return()`, `app.accrue_investment_return()`, checks on `investments` and `investment_redemptions` |
| Approvals and limits | `app.guard_refund_approval()`, `app.guard_deposit_release()`, `app.guard_payout()`, `app.guard_approver()` |
| Audit on every change to money, pricing or status | `app.audit_row()` on every table except logs and telemetry (`app.attach_audit()`) |

## 4. Assumptions

Where the specifications are silent or disagree, the reading closest to the agreements was chosen. Each needs a yes or a correction from the client; the first eight change money.

1. **Late Fee, once or twice.** The Enrollment Agreement says $50 "per failed charge"; the owner specification says "per missed payment", and its worked month charges $50 once although both the debit and the retry failed. Built as once per invoice.
2. **Extra days after a late return** are priced at the booking's stored daily rate, one per started 24 hours once more than 30 minutes late. The specifications say "the rental charge for each extra billable day" and both worked examples ($100 and $90 for one day) fit the daily rate. The alternative, repricing the whole booking at its new length, gives different amounts on bookings near a weekly or monthly cap.
3. **Kickback base** is the Rental Charge after the discount and after any refund, including extra days after a late return (the Enrollment Agreement defines the Rental Charge that way). Not mileage overage, fees or tax.
4. **Revenue Share rounding.** The share is calculated per booking and the statement adds the bookings up. The owner specification's statement shows "% of the vehicle total"; the two agree to the cent in every worked example and can differ by a cent elsewhere.
5. **HST on a payout** to an HST-registered owner is 13% of net earnings (Owner Revenue less Revenue Share, Turo net included), not of kickbacks or deductions. Flagged for the accountant in the specification.
6. **Deductions on a statement.** Unpaid fees come off the vehicle's own net earnings first (fees and their HST before the Late Fee), then off the owner's other vehicles; what is left stays on the invoice as a debt. Owner costs and refund shares are deducted in full and can take a vehicle below zero; a negative owner total is carried forward.
7. **Fee periods.** Fees run on both the Enrollment Date and the Exit Date. A part month is monthly fee x days / days in the month. The terms in force on the billing date apply to the whole month. A vehicle enrolled after the 15th is billed for that part month in the next run. Prepaid months are collected with HST and credited with HST. The unused part of the prepaid last month is flagged as due back and paid as its own payout.
8. **"Once collected".** A rental reaches a statement when every Owner Revenue line on it is tied to a successful payment; otherwise it waits for a later statement. A rental "ends" on the Toronto date of Check-in.
9. **Debit timing.** The specification's 15th and 18th assume a debit result on the day; the payment notes say results take up to five business days. The invoice flow has a `processing` step, accepts a failure after `paid`, and the retry date defaults to the 18th.
10. **Shareholder as a case, not a mode.** The Enrollment Agreement has three Management Modes and the owner specification lists a separate shareholder flag. Built as the flag plus a derived `billing_case` with four values.
11. **VA money limits.** A finance VA may release a refund from the cancellation table or a deposit release up to their Single Limit; everything else, and every payout, needs an admin. The Dual Approval Threshold is stored but adds nothing while it is above the Single Limit. Both start at $0.
12. **Shareholder claim payments** need two different admins (the two Principals).
13. **Business days** exclude weekends and the `holidays` table, which is empty until an admin loads Ontario's holidays. The 10th, 15th and 18th are used as written even on a weekend.
14. **What an owner sees of a renter.** On a rental CarmaCars manages: dates, status, rental charge and live location only. On a Self-Managed rental: also the renter's name and mobile number. Never identification, address, email, licence or card. Owners do not see Condition Reports or incidents of a renter's booking.
15. **Staff reach to customer records.** A VA sees a renter's record while a booking is live and for 90 days after it ends (the same period as ID image retention), while a task is open on it, or for 24 hours after a logged lookup with a reason. This is an access design, not a rule from the specifications.
16. **Never while moving** is enforced as: speed 0, ignition off, on a reading no more than 5 minutes old, with an admin's approval. The 5 minutes is a technical threshold.
17. **First rental** means the renter has no earlier completed booking (Owner Bookings aside). The referrer must be on the booking before it is confirmed and cannot change afterwards.
18. **Declined-payment retries** run 1, 3 and 7 days after the first decline.
19. **Investor elections** apply per agreement, not per amount invested. A Return runs to the day before the Redemption Date.
20. **Recharging** is entered as a number of 10% steps; the specification does not say how a part step rounds.
21. **Total loss.** "Amounts the Owner owes" is unpaid invoices, open deductions and any debt carried forward.
22. **No deletes from a browser session**, including by an admin. Corrections are voids, reversals or new rows.
