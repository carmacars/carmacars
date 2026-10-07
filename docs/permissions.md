# Permissions

Who can see and do what, and how the database enforces it. Implemented in `supabase/migrations/0012_security.sql`; proved by `supabase/tests/04_rls.sql`.

## 1. How it is enforced

| Layer | What it does |
| --- | --- |
| Row-level security | On all 101 tables. With no policy, a signed-in user sees nothing. Admins have a policy on every table |
| Limited views | Where a role may see a row but not all of its columns, the role has no access to the table and reads a view: `renter_bookings`, `owner_bookings`, `owner_claims`, `field_job_details`, `staff_directory`, `public_vehicle_listings` |
| Guards (triggers) | Approvals and limits that hold whoever is asking, the server included: refund and deposit-release limits, admin-only payout approval, own-approval-only, admin-only columns, tracker rules |
| Privileges | Browser sessions can select, insert and update, never delete. The anonymous role can read one view. Functions that move money are executable by the server only |
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

## 3. What each role must never do, and what stops it

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
| Only an admin sets fees, Revenue Share, management mode, discounts or a per-booking price | Admin-only write on `vehicle_schedules`, `vehicle_fee_history`, `fee_defaults`; `app.guard_admin_columns()`; `app.guard_booking_override()` |
| Only an admin changes a payee's bank details | Admin-only write on `owner_payout_accounts` |
| Field staff see only their assigned jobs | `field_jobs` policy; `field_job_details` view, from 36 hours before the job to 24 hours after it is done |
| Field staff cannot reassign a job or change a booking | `app.guard_field_job()`; no policy on `bookings` |
| Only an admin approves disabling a car, and never while it is moving | Check constraint on `tracker_commands` and `app.guard_tracker_command()` |
| Investor, staff and shareholder documents are admin only | `documents` policies exclude those kinds for every other role |
| Money-moving functions cannot be called from a browser | Execute revoked from everyone but `service_role` |

## 4. Adding a table later

1. Enable row-level security and add the `admin_all` policy in the same migration.
2. Add only the policies the role matrix calls for.
3. Call `app.attach_audit()`.
4. Run `scripts/test.sh`: it fails if any table lacks row-level security, the admin policy or an audit trigger.
