# 11. Statements and reports

Owner: workstream D (`src/features/statements/`), PDFs through `render-document` (workstream E). Routes: `/admin/statements`, `/admin/statements/[id]`, `/admin/payouts`, `/admin/owner-billing/invoices`, `/admin/reports`, with Finance VA mirrors that can prepare but not approve.

The owner's requirement: owner statements generated automatically every month, and CarmaCars' own admin monthly statements per car, per owner and in total. Thorough.

Rules: owner billing specification sections 2, 5, 6 and 10; payment set-up section 6 (chart of accounts) and 7 (monthly close); `app.build_owner_statement()`, `app.compute_booking_split()`, `app.generate_owner_invoices()`; data model assumptions 4 to 8.

## 1. The monthly cycle (Toronto dates)

| When | What runs | By | Result | Emails |
| --- | --- | --- | --- | --- |
| 1st, 06:00 | `returns-accrue` | `app.job_returns_accrue()` (exists) | Investor returns for last month | none |
| 1st | `month-open` | Edge Function (to build) | Splits recomputed for rentals that ended last month (`app.compute_booking_split()`), interest on overdue renter charges (`calc_monthly_interest()`), fleet report sent | `franchisor_fleet_report` |
| 5th, 06:00 | `statements-draft` | `app.job_statements_draft()` (exists) calling `app.build_owner_statement()` per owner | One draft `owner_statements` row per owner with vehicle blocks and lines; a `finance` task `review_statements`; the company statements for the month are built as drafts (`app.build_company_statement()` **[new]**) | `staff_statements_ready_for_approval` |
| 5th to 9th | Review | Finance VA, then an admin | Corrections are made in the source records (a deduction added, a payment matched), then "Rebuild" re-runs the builder for that owner. A draft is never edited by hand | none |
| By the 9th | Approval | Admin: `app.approve_owner_statement()` | Statement `approved`; the owner can now see it; the `payouts` row is created `pending_approval` | none |
| 10th | `payouts` | Edge Function (to build) plus an admin | Approved payouts are listed for bank transfer; the admin pays from the bank, enters the reference and marks each paid; the statement PDF is rendered and sent | `owner_statement_ready` (T26) with the PDF; `staff_payouts_due` |
| 10th | Company statements final | `app.finalize_company_statement()` **[new]** | The month's company statements are frozen as a snapshot | `staff_monthly_statements_ready` with the PDF and CSV links |
| 15th, 06:00 | `owner-invoices` | `app.job_owner_invoices()` (exists) | One draft invoice per vehicle | none |
| 15th | `owner-billing` | Edge Function (to build) | Invoices issued and debits submitted; investor returns paid | `owner_fee_invoice` (T24) per owner, listing each vehicle; `investor_statement_ready` |
| 15th to 25th | `debit-results` | Edge Function | A failed debit sets `failed` and the database adds the $50 Late Fee | `owner_payment_failed` (T25) |
| 18th | `debit-retry` | Edge Function | Retry of fees plus Late Fee; failure sets `in_arrears` | `owner_in_arrears`, `staff_owner_invoice_failed` |

A rental reaches a statement in the month it ends, once collected, net of refunds and chargebacks. A rental with an uncollected Owner Revenue line waits for a later statement.

## 2. The owner statement

One per owner per month, one block per vehicle. Built only by `app.build_owner_statement(p_owner, p_month)`. Shown at `/admin/statements/[id]` (staff), `/owner/statements/[id]` (owner, approved only) and as a PDF (`documents.kind = 'owner_statement'`, bucket `statements`, path `owners/{owner_id}/statements/{yyyy-mm}.pdf`).

### 2.1 Layout and every line

| Block | Line | Columns shown | Source |
| --- | --- | --- | --- |
| Header | Statement | CarmaCars legal name, address, HST number; owner legal name and address; owner HST number if on file; statement number; statement month; payout date; "Final statement" when it is | `program_settings`; `owners`; `owner_statements.statement_number, statement_month, payout_date, is_final` |
| Vehicle (repeated) | Vehicle heading | Year, make, model, plate, fleet number, management mode | `vehicles` |
| Vehicle | Each rental ended in the month | Booking number; pickup and Check-in dates; Rental Charge (after discount, with late-return extra days); mileage overage; refunds; chargebacks; Referral Kickback; Owner Revenue | `owner_statement_lines` where `line_type = 'rental'`: `booking_id`, `starts_on`, `ends_on`, `rental_charge_cents`, `mileage_overage_cents`, `refunds_cents`, `chargebacks_cents`, `kickback_cents`, `owner_revenue_cents`; from `booking_splits` |
| Vehicle | Rental Charge kept on a cancelled booking | Booking number, cancellation date, retained Rental Charge | A `rental` line with the note "cancelled"; from `booking_cancellations` and `refund_allocations` |
| Vehicle | Each Turo trip | Dates; Turo gross; Turo fees; net; damage payment passed to the owner | `line_type = 'turo_trip'`: `turo_gross_cents`, `turo_fees_cents`, `owner_revenue_cents`; from `turo_trips` |
| Vehicle | Withheld | Booking number; Owner Revenue withheld while a chargeback is open | `line_type = 'withheld'`; `owner_statement_vehicles.withheld_cents` |
| Vehicle | Owner Revenue | Total | `owner_statement_vehicles.owner_revenue_cents` |
| Vehicle | Revenue Share | Percentage and amount kept by CarmaCars (10% on a shareholder-owned car; none on Self-Managed) | `owner_statement_vehicles.revenue_share_cents`; the percentage from the bookings' `company_share_bps` |
| Vehicle | Net earnings | Owner Revenue less Revenue Share | `net_earnings_cents` |
| Vehicle | Unpaid Fees and Late Fees deducted | Invoice number; Fee; HST; Late Fee | `line_type = 'fees_deducted'`: `owner_invoice_id`, `fee_cents`, `late_fee_cents`; totals in `fees_deducted_cents`, `late_fees_deducted_cents` |
| Vehicle | Owner costs deducted | Item; date; receipt link | `line_type = 'owner_cost'`: `owner_deduction_id`; from `owner_deductions` (plate renewal, Owner Booking tolls and tickets, lender handover cost, claim shortfall, Owner Booking deductible, re-transfer fee, agreed in writing) |
| Vehicle | Earlier refund or chargeback | Booking number; owner's share | `line_type = 'refund_or_chargeback'`; `refund_chargeback_deducted_cents` |
| Vehicle | Vehicle payable | Net earnings less deductions (may be negative) | `owner_statement_vehicles.payable_cents` |
| Owner | Vehicles payable | Sum of the vehicle blocks | `owner_statements.vehicles_payable_cents` |
| Owner | Arrears moved from another vehicle | From vehicle; to vehicle; amount | `line_type = 'arrears_moved'`: `from_vehicle_id`, `vehicle_id`; `arrears_moved_cents` |
| Owner | Referral Kickbacks earned | Booking number; Rental Charge; amount | `line_type = 'kickback_earned'`: `referral_kickback_id`; `kickbacks_earned_cents` |
| Owner | HST on payout | 13% of net earnings, only when the owner's HST number is on file | `line_type = 'hst_on_payout'`; `hst_on_payout_cents` |
| Owner | Balance brought forward | A debt from an earlier month (negative) | `line_type = 'balance_brought_forward'`; `balance_brought_forward_cents` |
| Owner | **Payout** or **Balance owing** | The amount paid on the 10th, or the debt carried forward | `payout_cents`; `balance_carried_forward_cents` |
| Owner | Paid | Date, method, bank reference | `payouts.paid_at, method, reference` |
| Information | Fees billed this month | Per vehicle: invoice number; amount; HST; status (paid, failed, deducted) | `owner_invoices` for the month |
| Information | Prepaid last month's Insurance Fee held | Per vehicle | `vehicle_prepaids.remaining_cents` where `kind = 'last_month_insurance'` |
| Information | Open claims | Vehicle; status | `owner_claims` |
| Information | Rentals awaiting collection | Booking number; reason (payment pending, insurer invoice unpaid, dispute open) | `booking_splits.uncollected_cents` above zero **[column named in the data model; confirm in the migration]** |
| Footer | Notes | "Fees are billed separately on the 15th." "Questions: reply to this email or use Statements in your portal." | static |

The worked month in the owner specification must reproduce to the cent: Vehicle A $1,144.00, Vehicle B $778.25, payout $1,922.25 (`supabase/tests/02_owner_month.sql` already proves the builder).

### 2.2 `/admin/statements` (list)

Columns: month, owner, vehicles, Owner Revenue, Revenue Share, deductions, kickbacks earned, HST, brought forward, payout, status, built at, approved by. Filters: month (default the current statement month), status, "negative balance", "has arrears moved", "has withheld". Totals row. Buttons: Build or rebuild month (`buildStatements(month)` runs the job wrapper for a missed or corrected month), Approve selected (admin; each still approved individually in the database), Export.

### 2.3 `/admin/statements/[id]` (review)

| Area | Content |
| --- | --- |
| Statement | Exactly the owner's layout |
| Checks panel | Automatic checks, each green or amber: every rental line's Owner Revenue equals Rental Charge plus overage less kickback; Revenue Share equals the sum of the bookings' shares; rentals that ended in the month but are missing (uncollected) are listed with the reason; deductions each have a receipt; the payout equals the sum of the parts; compared with last month (a change of more than 50% is amber) |
| Drill-down | Any line opens its source: booking money tab, invoice, deduction, kickback |
| Notes | Internal notes for the approver |

| Button | Who | Action |
| --- | --- | --- |
| Rebuild | Finance, admin | `rebuildStatement` -> `app.build_owner_statement()` again (drafts only) |
| Send for approval | Finance | Marks the review task done; appears in `/admin/approvals` |
| Approve | Admin | `approveStatement` -> `app.approve_owner_statement()`; creates the payout |
| Void | Admin | Reason; `status = 'void'`; lines are released for a rebuild |
| Preview PDF | All | Renders without storing |

An approved statement is never changed. A correction found later is a line on the next statement (a deduction, or an "agreed in writing" adjustment, or a positive adjustment recorded as an additional payout with an explanation).

## 3. CarmaCars' own monthly statements

Three levels, same month key as owner statements (the month a rental ends). Built by `app.build_company_statement(p_month)` **[new]** into `company_statements` and `company_statement_lines` **[new]**, drafted on the 5th and frozen on the 10th. Until frozen, the screens read live from the views below; after, from the snapshot, so a closed month never changes. Later corrections appear in the month they are made, in an "Adjustments to earlier months" section.

Two bases are always shown side by side where they differ: **Earned** (by the month the rental ends or the invoice period) and **Cash** (by the date the payment succeeded).

### 3.1 Per vehicle (`/admin/reports?level=vehicle&month=`)

One row per vehicle; the same figures as a one-page statement per vehicle (PDF).

| # | Column | Derived from |
| --- | --- | --- |
| 1 | Vehicle, plate, owner, mode, billing case | `vehicles`, `owners` |
| 2 | Days in the programme this month | Days of the month between `enrollment_date` and `app.vehicle_fee_end()` |
| 3 | Days available | Column 2 less days covered by `vehicle_calendar_blocks` (service, repair, owner, exit) |
| 4 | Days rented | Days of the month covered by bookings in `on_rent`, `returned` or `closed` (Toronto days of `handed_over_at` to `checked_in_at`), Owner Bookings counted separately |
| 5 | Utilization | Column 4 divided by column 3 |
| 6 | Rentals ended | Count of `booking_splits` with `payout_month` = the month |
| 7 | Rental Charge | Sum of `booking_splits.rental_charge_cents` (after discounts and refunds, with late-return extra days) |
| 8 | Mileage overage | Sum of `booking_splits.mileage_overage_cents` |
| 9 | Referral Kickbacks deducted | Sum of `booking_splits.kickback_cents` |
| 10 | Owner Revenue | Sum of `owner_revenue_cents` (= 7 + 8 - 9) |
| 11 | Revenue Share kept (CarmaCars) | Sum of `company_share_cents` |
| 12 | Owner payout on rentals | Sum of `owner_payout_cents` (= 10 - 11) |
| 13 | Company-only fees | Sum of `booking_line_items.amount_cents` where `revenue_class = 'company_only'`, not voided, on those bookings, net of `refund_allocations`; broken out by `charge_type`: delivery, pickup, young driver, additional driver, winter tire, baby seat, coverage sold, late return fee, fuel and service fee, cleaning, pet, smoking, lost key fee, toll and ticket administration, administration, declined payment, interest |
| 14 | Pass-through collected | Sum where `revenue_class = 'pass_through'` (tolls, tickets, key cost, damage at cost, call-outs, recovery) |
| 15 | Claim funds collected | Sum where `revenue_class = 'claim_funds'` (deductible, loss of use); also in the claim ledger |
| 16 | HST collected from renters | Sum of `booking_line_items.hst_cents` on those lines |
| 17 | Turo gross, Turo fees, Turo net | `turo_trips` with `statement_month` = the month |
| 18 | Turo Revenue Share kept; Turo extras kept | `turo_trips.revenue_share_cents`, `company_extras_cents` |
| 19 | Owner fees billed | `owner_invoices` for the vehicle with `period_month` = the month: Insurance Fee and Tracker Fee lines from `owner_invoice_lines`, plus Install Fee on an upfront invoice dated in the month |
| 20 | HST on owner fees | `owner_invoices.hst_cents` |
| 21 | Late Fees | `owner_invoices.late_fee_cents` |
| 22 | Owner fees collected, deducted, outstanding | `paid_cents`, `deducted_cents`, `balance_cents` |
| 23 | Claim result to CarmaCars | `claims.company_result_cents` for claims settled in the month (`settled_at`) |
| 24 | Processing fees | Sum of `payment_processor_details.processor_fee_cents` for payments on the vehicle's bookings and invoices with `processed_at` in the month |
| 25 | Company-paid tolls and tickets | `toll_tickets` with `status = 'company_paid'` and `matched_at` in the month |
| 26 | Direct costs entered | `company_expenses` **[new]** rows tagged to the vehicle (for example a repair CarmaCars absorbed) |
| 27 | **CarmaCars contribution from this vehicle** | 11 + 13 + 18 + 19 + 21 + 23 - 24 - 25 - 26 |
| 28 | Refunds issued; chargebacks | `refunds` paid in the month; `disputes` lost in the month |
| 29 | Uncollected | `booking_splits.uncollected_cents`; unpaid `booking_statements` |
| 30 | Incidents; days out of service | Count of `incidents`; days under a repair block |

Column 27 is before costs the platform does not hold (the fleet insurance premium, tracker service, staff, marketing) unless they are entered in `company_expenses`. The page says so above the table.

### 3.2 Per owner (`level=owner`)

| Column | Derived from |
| --- | --- |
| Owner, type, vehicles in the programme | `owners`, `vehicles` |
| Owner Revenue; Revenue Share kept; net earnings | `owner_statements.owner_revenue_cents, revenue_share_cents, net_earnings_cents` |
| Deductions: fees and Late Fees; owner costs; refund and chargeback shares; arrears moved | `owner_statement_vehicles` sums; `owner_statements.arrears_moved_cents` |
| Kickbacks earned by this owner | `owner_statements.kickbacks_earned_cents` |
| HST on payout | `hst_on_payout_cents` |
| Balance brought forward; payout; balance carried forward | `owner_statements` |
| Payout status, date, reference | `payouts` |
| Owner fees billed, collected, outstanding (all vehicles) | `owner_invoices` |
| Prepaid last months held | `vehicle_prepaids.remaining_cents` |
| Arrears and age | `owner_invoices` in `in_arrears`, days since `retry_failed_on`; `removal_allowed_on` |
| Company-only fees and contribution from this owner's vehicles | Sums of section 3.1 columns 13 and 27 |
| Open claims | `claims` |

### 3.3 Total (`level=total`)

The company statement for the month: an income summary mapped to the chart of accounts, positions held for others, receivables, and cash movements.

| Section | Line (account) | Derived from |
| --- | --- | --- |
| Revenue | Revenue Share (4000) | Sum of `booking_splits.company_share_cents` for the month plus `turo_trips.revenue_share_cents` |
| Revenue | Owner fee revenue (4010) | `owner_invoice_lines` of kinds `insurance_fee`, `tracker_fee`, `install_fee`, `first_month_insurance`, `last_month_insurance` recognized in the month they cover (prepaid amounts are recognized when applied: `prepaid_credit` lines), before HST |
| Revenue | Owner Late Fees (4020) | `owner_invoice_lines` of kind `late_fee` |
| Revenue | Renter service fees (4100) | Company-only lines: delivery, pickup, young driver, additional driver, winter tire, baby seat, late return fee, fuel, recharging, fuel service fee, cleaning, heavy cleaning, pet, smoking; plus Turo extras |
| Revenue | Coverage sold (4110) | `coverage_sold` lines |
| Revenue | Administration fees (4120) | `toll_admin_fee`, `ticket_admin_fee`, `admin_fee_claim`, `admin_fee_other`, `lost_key_fee`, `declined_payment` |
| Revenue | Interest (4130) | `interest` lines |
| Revenue | Claim surplus (4140) | `claims.company_result_cents` above zero, settled in the month |
| Costs | Processing fees (5000) | `payment_processor_details.processor_fee_cents`; dispute fees; fees kept on refunded deposits |
| Costs | Claim shortfalls borne by CarmaCars | `claims.company_result_cents` below zero |
| Costs | Company-paid tolls and tickets | Section 3.1 column 25 |
| Costs | Photo and AI services | `provider_calls.cost_microusd` |
| Costs | Entered costs by category | `company_expenses` |
| Costs | Investor returns (5010) | `investment_returns.return_cents` for the month |
| Result | Contribution before costs not in the platform | Revenue less costs above |
| Held for others | Collected for owners (2110) | Approved and draft owner payouts not yet paid, plus Owner Revenue collected for rentals not yet on a statement |
| Held for others | Renter deposits held (2100) | `deposits` charged or captured and not yet applied or released: `captured_cents - applied_cents - released_cents`; uncaptured holds listed separately as memo |
| Held for others | Prepaid last month's Insurance Fee (2120) | Sum of `vehicle_prepaids.remaining_cents` |
| Held for others | Referral kickbacks payable (2130) | `referral_kickbacks` in `earned` not `paid` |
| Held for others | Claim funds held (2140) | Balance of `claim_ledger_entries` per open claim |
| Held for others | Pass-through clearing (2150) | Pass-through lines collected less notices paid (`toll_tickets.paid_by_company_at`) |
| Tax | HST collected (2200) | `booking_line_items.hst_cents` plus `owner_invoices.hst_cents`, by the month charged; less HST on refunds (`refund_allocations.hst_cents`) |
| Tax | HST paid on payouts (2210) | `owner_statements.hst_on_payout_cents`; HST on `owner_deductions.hst_cents` and `company_expenses` |
| Receivables | Owner receivables (1200) | `owner_invoices.balance_cents` in `failed`, `in_arrears`, `partially_deducted`; open `owner_deductions`; negative `owners.balance_carried_forward_cents` |
| Receivables | Renter receivables (1210) | Unpaid `booking_statements` and failed `payments` with retries pending |
| Receivables | Insurer receivables | `insurer_invoices.total_cents - paid_cents` by age: current, 30, 60, 90 days |
| Cash | Collected in the month by method | `payments` succeeded by `processed_at`: card, pre-authorized debit, e-Transfer, bank transfer; by purpose |
| Cash | Refunded; released | `payments` of kind refund and release |
| Cash | Paid out | `payouts` paid in the month by kind (owner statements, Turo-only, prepaid refunds, total-loss balances, claim profit, payroll kickbacks, investor returns and redemptions) |
| Cash | Processor payouts received | `payout_reconciliations` |
| Fleet | Vehicles on the policy (start, added, removed, end); average utilization; rentals; average rental length; average daily rate achieved | `fleet_reports`, section 3.1 |
| Bookings funnel | Requests, offers sent, offers approved, confirmed, declined, expired offers, pushed back, cancelled, no-shows; median time from request to first offer | `bookings`, `booking_offers`, `booking_events` |
| Investors | Capital (2300): opening, invested, reinvested, redeemed, closing | `investments` |
| Adjustments to earlier months | Any line whose source changed after its month was frozen | Difference between the frozen snapshot and a fresh build |

Each line drills down to the rows behind it (a `DataTable` in a `SidePanel` with its own CSV export). The total statement's revenue lines equal the sum of the per-vehicle statements, and the per-owner payouts equal the sum of `payouts` of kind `owner_statement`: both are checked automatically and shown as a tick or a difference at the top of the page.

### 3.4 Screen: `/admin/reports`

| Item | Detail |
| --- | --- |
| Controls | Month picker (and a range for trends), level (vehicle, owner, total), basis (earned, cash), status badge (draft, final) |
| P layout | The total statement as stacked sections; vehicle and owner levels as cards with the six key numbers and "More" |
| D layout | Wide table with sticky first column and header; column chooser; totals row |
| Buttons | Rebuild draft (`buildCompanyStatement`), Finalize (admin; normally automatic on the 10th), Download PDF, Download CSV, Download accountant pack |
| Trends tab | 12-month lines for revenue by account, utilization, contribution per vehicle. Charts follow the status-colour rule: line styles and labels, not colour alone |
| Empty | "No rentals ended in this month yet." |

## 4. Exports

| Export | Format | Content | Who |
| --- | --- | --- | --- |
| Owner statement | PDF, CSV of lines | Section 2.1 | Owner, admin, Finance |
| Company statement: vehicle, owner, total | PDF, CSV | Section 3 | Admin |
| Accountant pack (monthly) | ZIP of CSVs | `journal.csv`: one row per account per source type with debit, credit, month, and a reference to the detail file; detail files for renter lines (every `booking_line_items` row with revenue class, HST, payment, booking), owner invoices and lines, payouts, refunds, deposits movements, claim ledger, HST summary, processor fees | Admin |
| HST summary | CSV | Collected by source and month; paid on payouts and costs; net | Admin |
| Payout run | CSV | Payee, amount, method, last four, statement number, for entering bank transfers; never the full account number | Admin |
| Payroll kickbacks | CSV | Field staff member, booking, amount, payroll period (`referral_kickbacks` with `referrer_type = 'field_staff'`) | Admin, Finance |
| Fleet report | PDF | Procedure 20 | Admin, Finance |
| Insurer aged receivables | CSV | By insurer and age | Admin, Finance |

Rules: CSV is UTF-8 with a header row, amounts in dollars with two decimals and a separate cents column, dates as ISO in Toronto time. Exports are generated by an Edge Function, stored in the `admin` bucket for 7 days and downloaded through a signed link. Each export writes an `audit_log` entry (`action = 'EXPORT'`). No export contains a renter's licence number, card data or bank account number. No customer list export exists.

## 5. Owner invoices (`/admin/owner-billing/invoices`)

| Item | Detail |
| --- | --- |
| Columns | Invoice number, owner, vehicle, kind (upfront, monthly, adjustment), period, days billed of days in month, fees, HST, Late Fee, total, paid, deducted, balance, status, billing date, retry date, removal allowed on |
| Filters | Month, status, owner, "failed or in arrears" |
| Row panel | Lines (`owner_invoice_lines`: Insurance Fee, Tracker Fee, prepaid credit, Late Fee, adjustments), payments, status history, the PDF |
| Actions | Issue now (draft to issued; normally the job), Record payment (e-Transfer or card: `recordOwnerPayment`), Retry debit now, Void (draft or issued, reason), Add adjustment line (admin), Send T24 or T25 again |
| Invoice PDF | CarmaCars legal name, address, HST number; owner; vehicle; period and pro-rating ("17 of 30 days"); each line; HST; Late Fee (no HST); total; payment method and date; "Fees are due every month, rented or not." |
| Arrears view | Vehicles `in_arrears`, days since the failed retry, the 30-day removal date, and what will be deducted on the next 10th |

## 6. Payouts (`/admin/payouts`)

| Item | Detail |
| --- | --- |
| Tabs | To approve, Approved (to pay), Paid, Failed |
| Columns | Scheduled date, payee, kind, statement, amount, HST part, method, bank last four, prepared by, approved by, second approver, reference, status |
| Approve | Admin (`app.guard_payout()`); kinds needing both principals wait for the second admin |
| Pay | The admin makes the bank transfer outside the platform, then "Mark paid" with the date and bank reference (`markPayoutPaid` -> `status = 'paid'`, `paid_at`, `reference`; `app.payout_paid_effects()` marks the statement paid, updates kickbacks, deductions and the owner's carried-forward balance). On marking a statement payout paid, `owner_statement_ready` (T26) is sent with the statement PDF |
| Failed | "Mark failed" with the bank's reason; the owner is asked to confirm bank details; nothing else changes until paid |
| Holds | A payout to an owner whose bank details changed in the last 24 hours shows "On hold" (`03-admin.md` section 9.1) |
| Turo-Only owners | `kind = 'turo_only_statement'`: same statement with only Turo trip lines |
| Field staff kickbacks | Listed for payroll on the 10th (`method = 'payroll'`); marked paid when payroll confirms |

## 7. Owner and admin emails for money

| Event | When | Attachment |
| --- | --- | --- |
| `owner_fee_invoice` (T24) | 15th | Invoice PDF per vehicle (one email per owner) |
| `owner_payment_failed` (T25) | Debit fails | none |
| `owner_in_arrears` | Retry fails on the 18th | none |
| `owner_payment_received` | An invoice is paid by card or e-Transfer | Receipt |
| `owner_statement_ready` (T26) | 10th, when the payout is marked paid (or when a statement with a nil or negative payout is approved) | Statement PDF |
| `owner_deduction_added` | A deduction is recorded, with the receipt | Receipt |
| `owner_prepaid_refund` | The unused prepaid last month is paid out | none |
| `staff_statements_ready_for_approval` | 5th | none |
| `staff_monthly_statements_ready` | 10th | Company statement PDFs |
| `staff_payouts_due` | 10th | CSV link |

## 8. Database additions needed

| Addition | Purpose |
| --- | --- |
| `company_statements (id, statement_month, level ('vehicle', 'owner', 'total'), vehicle_id, owner_id, status ('draft', 'final'), figures jsonb, built_at, finalized_at, finalized_by, document_id)` with a unique key on month, level, vehicle and owner; `company_statement_lines` for drill-down references | Frozen monthly snapshots |
| `app.build_company_statement(p_month date)`, `app.finalize_company_statement(p_month date, p_by uuid)`; views `v_company_vehicle_month`, `v_company_owner_month`, `v_company_total_month` implementing the derivations in section 3 | One definition of every number |
| `company_expenses (id, expense_month, category, vehicle_id, owner_id, amount_cents, hst_cents, description, document_id, created_by)` | Costs the platform does not otherwise hold |
| Job functions: `month-open`, `payouts`, `owner-billing`, `debit-results`, `debit-retry` Edge Functions listed in `docs/architecture.md` section 5 are still to build | Section 1 |
| `fee_types.gl_account text` | Mapping of each charge to the chart of accounts, so the mapping in section 3.3 is data |
| Confirm `booking_splits.uncollected_cents` exists in the migration (named in the data model; the column list read for this blueprint shows `collected_cents`, `refunded_cents`, `chargeback_cents`, `withheld_cents`) | "Rentals awaiting collection" |
| `audit_log` action value `EXPORT` written by the export function | Section 4 |
| Tests: the per-vehicle sums equal the total; the worked month's company side ($1,351 Revenue Share, $275 company-only fees) reproduces | Owner specification section 10 |
