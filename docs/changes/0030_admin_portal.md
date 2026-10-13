# 0030: the admin portal's door

Migration `supabase/migrations/0030_admin_portal.sql`, tests `supabase/tests/17_admin_portal.sql` (38 assertions). Builds on 0001 to 0029. No earlier migration was edited.

The web app's admin portal (`web/src/app/admin`) reaches the database only through `public` functions, as the service role, with the Admin's user id. This migration adds the door it goes through. No business rule is added or copied: every action calls the function of the earlier migration that owns the rule.

## Functions

| Function (`app`, wrapped in `public` for the service role only) | Does |
| --- | --- |
| `admin_begin(admin)` | `assert_admin`, then sets `request.jwt.claim.sub` and the `sub` of `request.jwt.claims` for the transaction, so `auth.uid()` is the Admin: audit rows carry the Admin as actor, and the guards and staff-only reads of earlier migrations (`master_calendar`, the refund and payout guards) see the Admin |
| `admin_enrich(row)` | Adds `vehicle_name`, `booking_number`, `renter_name`, `owner_name`, `insurer_name`, `assignee_name`, `actor_name`, `investor_name` for the ids a row carries |
| `admin_list(admin, rel, p)` | The portal's lists. An allow-list of tables and views (secrets tables are not on it). Filters only on columns the relation has (`eq`, `not_null`, `gte`, `lt`), a text search, an order column, limit 1 to 500. Returns `{rows, count}` |
| `admin_read(admin, what, p)` | The screens: `dashboard`, `requests`, `booking`, `booking_preview`, `quote_vehicles`, `calendar`, `calendar_preview`, `cancellation_preview`, `vehicles`, `vehicle`, `listings`, `listing`, `settings`, `bulk_rate_preview`, `tolls`, `toll`, `toll_profile`, `damages`, `damage`, `owner_statement`, `company_statement`, `csv`, `reconciliation`, `investor`, `owner_records` |
| `admin_booking_preview(admin, booking, p)` | Applies the review screen's edits (`adjust_booking`, `set_booking_places`, promo code, `set_booking_fee_term`, `set_coverage_price`, `set_blocks_calendar`) inside a block that is always rolled back, and returns the booking as priced. Live re-pricing without saving |
| `admin_save(admin, table, p)` | Settings an Admin changes: an allow-list of tables and, per table, of columns. `updated_by`, `set_by` and `created_by` are filled with the Admin. `program_settings`: a new dated row copied from the row in force (or the row of that date when one exists); a date in the past is refused. `fee_defaults`: a new row from its effective date, the row it replaces closed |
| `admin_do(admin, action, p)` | Every action: requests and bookings (save, send, withdraw, resend, approve by phone, ask, decline, reopen, calendar switch, cancel, change requests, extensions, swap, calendar move, deposit, final statement, insurer invoice draft, review request decision, refund request), calendar blocks (create with the conflicting confirmed bookings listed first and an urgent fleet task per conflict when created anyway, update, end, remove with a reason), fleet (rate card, fee overrides, classes, details, status, deposit, bulk rates, fee change notice), listings (start, review, classes, publish, unlist, retry), staff (add after the sign-in account is created, end access, restore), money (refund approve and reject, payout approve with the two-principal rule, paid, cancel, owner invoice run, owner statements build, build all, approve, issue, reissue, company statement build and finalize, expense void, insurer invoice send, payment, write-off, dispute evidence submitted, processor payout record and match), tolls and damage (log, import, profile, confirm, bulk confirm, charge, bill to owner, dispute, close, rematch, paid), incidents and claims, tasks, reviews (publish, hide only for personal information, abuse or not about the rental, reply), email (resend, cancel, suppressions), investor returns accrual |

## Columns

- `program_settings.request_response_target_minutes` (default 120): the target for answering a booking request, shown on the dashboard.
- `coverage_prices.effective_from` now defaults to `app.today()` (Toronto) instead of `current_date` (the server's UTC date). A price entered after 8 p.m. in Toronto took effect only the next day; test 13 failed in those hours.

## Decisions

1. One dispatcher instead of one wrapper per action: each branch is a fixed call (no dynamic function names); the list and save readers build SQL only from names checked against the catalog and an allow-list.
2. Sending an insurer invoice records `sent` without an email: the catalogue has no `insurer_invoice` template yet.
3. Approving a refund records the approval (guarded by 0020's triggers); issuing the money through the processor stays with the payments module.
4. A hidden review's reason is written to `audit_log` (the table has no column for it).
5. Staff are added `active` once the sign-in account exists; until the invited person chooses a password they cannot sign in.
