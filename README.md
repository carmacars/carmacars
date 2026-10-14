# CarmaCars platform

The CarmaCars rental platform, Ontario: public booking site, renter portal, owner portal, admin portal, VA portal and field staff portal in one Next.js app, on Supabase (Postgres, sign-in, scheduler, Edge Functions) and Cloudflare (hosting, files), with Stripe, built-in signing and a GPS tracker with remote killswitch. It is one responsive website for phones and desktops, not a native app.

**This repository holds the database, its rules, its permissions, its tests, the email templates and the web app.** The Next.js app is in `web/` (public site, request to book, sign-in); see `web/README.md` for running it, the local stack and deploying.

## What is here

| Path | What |
| --- | --- |
| `web/` | The Next.js app on Cloudflare Workers (OpenNext): public site, request to book, sign-in, SEO, its own tests |
| `supabase/migrations/` | 38 migrations (0034 and 0035: the fixes of the handover and launch audits; 0036: sign-in for every portal; 0037: the automatic owner debit and statement PDFs by email); the first 25: 171 tables in `public` (plus `app.rate_limit_hits` and the event log), the billing rules as SQL functions, status flows, row-level security on every table, audit log, reference data, request to book, notifications, the booking application, operations, tolls and statements, owners and listings, the owner's answers, and 20 scheduled SQL jobs |
| `supabase/tests/` | Thirteen test files (2,235 assertions), shared helpers, a summary query, and a local shim for Supabase's `auth` schema (never applied to Supabase) |
| `supabase/seed/` | The generator that turns `emails/catalogue.json` into the notification catalogue rows of 0018 |
| `emails/` | The email catalogue, templates, samples and their checks (`node check.mjs`) |
| `prototype/` | The design prototype of the site and portals |
| `scripts/test.sh` | One command: fresh database, all migrations, all tests |
| `scripts/check-text.sh` | Fails if a document or SQL file we write contains an em dash or a sentence en dash |
| `docs/architecture.md` | System overview, environments, app areas, integrations, the request-to-book flow, the notification layer, the listing pipeline, statements, scheduled jobs, file storage, scope, deploy |
| `docs/data-model.md` | Tables by area, status flows, where each billing rule lives, assumptions |
| `docs/permissions.md` | The role matrix, every table and function group, and how it is enforced |
| `docs/changes/` | One record per migration from 0016 on (0025: the owner's answers): what was added, decisions, tests changed, what is not done |
| `docs/audit/` | The independent audits: the handover audit (2026-10-13) and the launch audit (`2026-10-13-launch-audit.md`: every requirement and decision with its status and evidence, links, emails, SEO, live operations, the Worker CPU limit, and what still needs the owner) |
| `docs/decisions/` | Decision records. 0001: the launch stack with no fixed monthly fees |
| `docs/blueprint/` | The product blueprint the later migrations follow |
| `docs/setup.md` | The accounts and how they connect; environment variables and secrets; running the tests; backups |
| `docs/source/` | The agreements, billing specifications and procedures the model was built from |
| `.env.example` | Every environment variable, without values |

## Run the tests

```bash
scripts/test.sh
scripts/check-text.sh
cd emails && node check.mjs
```

`scripts/test.sh` needs PostgreSQL 15 or later on the machine (`psql`, `initdb`, `pg_ctl`). It starts a throwaway server (port `CARMACARS_TEST_PORT`, default 54329), builds a fresh database, applies every migration in one transaction each, runs every test file in name order, prints a summary per file and ends with `ALL TESTS PASSED`. To use a server you already run, set `CARMACARS_TEST_PGURL`. A failed assertion never stops the run: it prints a `WARNING` line and is listed in the summary. See `docs/setup.md` section 7.

## Migrations

| File | Adds |
| --- | --- |
| `0001_foundation.sql` | Users, roles, staff profiles and limits, program settings, Toronto date helpers, documents, signatures, audit log, job runs |
| `0002_owners_vehicles.sql` | Owners, agreements, vehicles, signed vehicle schedules, fee history, onboarding, registration, exit, buyout, Turo, calendar, listings |
| `0003_pricing.sql` | Charge catalogue, defaults, rate cards, overrides; the pricing functions (rates, cancellation, late return, split, extension) |
| `0004_renters.sql` | Renters, drivers, card on file, identity checks, consents |
| `0005_bookings.sql` | Bookings, line items, deposits, payments, refunds, cancellations, chargebacks, extensions, renewals, statements, the split |
| `0006_operations.sql` | Field jobs, condition reports and photos, task queues, messages, tracker, franchisor fleet report |
| `0007_owner_billing.sql` | Owner invoices, prepaid months, deductions, kickbacks, statements, payouts; the split and statement builders |
| `0008_incidents_claims.sql` | Incidents, damage costing, claims and their ledger, total loss |
| `0009_tolls_tickets.sql` | Tolls and tickets, matched to whoever had the car |
| `0010_investors.sql` | Investors, investments, monthly returns, reinvestment, redemption |
| `0011_status_flows.sql` | Allowed status changes and what each step requires |
| `0012_security.sql` | Row-level security, limited views, approval and limit guards, privileges |
| `0013_audit.sql` | Audit trigger on every table that holds money, pricing or status |
| `0014_reference_data.sql` | Program settings, the charge catalogue and defaults, fee grid, onboarding estimates, message template codes |
| `0015_scheduled_jobs.sql` | The five monthly and weekly SQL jobs, the once-per-run guard on `job_runs`, and the `pg_cron` pattern (skipped where `pg_cron` is absent) |
| `0016_request_to_book.sql` | Request, offer, approve, sign and pay; offer versions, booking history, the calendar switch, insurers and insurer invoices, promo codes, reviews, offer expiry |
| `0017_events_core.sql` | `app_events` and `app.emit_event()`: the append-only list of business events |
| `0018_notifications.sql` | The notification layer: catalogue, outbox, staff digests, in-app notices, preferences, suppressions, the daily cap, the sender functions |
| `0019_booking_app.sql` | Quote and search, the public booking request, built-in signing, confirmation under a lock, renter self-service (cancellation, extensions, change requests, questions), identity and coverage uploads, handover guards, two-step sign-in for staff |
| `0020_operations.sql` | Handover and return, post-rental charges, renter statements and the Deposit, field jobs and vehicle moves, the calendar's drag and resize, rates and fees, rule-based task queues, incidents, swap, tracker disable, payout reconciliation |
| `0021_tolls_statements.sql` | Toll and ticket intake and matching, damage after the rental, the owner statement fixes and reissue, CarmaCars' monthly statements, chart of accounts, CSV exports |
| `0022_owners_forms_listings.sql` | Site settings and content, form drafts, leads, the owner application and onboarding, government form pre-fill, exit, fee and bank changes, the owner portal, the listing pipeline, the public website reads |
| `0023_notification_wiring.sql` | The full merge payload, the triggers that emit events from the tables of 0019 to 0022, the reminder and daily notification jobs |
| `0024_gap_fixes.sql` | Schedules for the remaining SQL jobs, timed listing publishing, the email for a charge line added by hand, one flow for changing a confirmed booking (calendar and change requests), a fixed order in the owner portal |
| `0025_owner_answers.sql` | The owner's answers: swap revenue by segment, expired offers closed and back to staff, 2-hour notice and turnaround, always open, several classes per car, Deposit and kilometre choices, no age or fee caps, additional driver at 25% of the daily rate, coverage sold through CarmaCars, delivery by distance and airports, review requests held on problem bookings, site defaults and reply-to aliases, cookie consent |
| `0026` to `0031` | Reply-to alignment, the website, renter, owner, admin, staff and investor portals' doors (see `docs/changes/`) |
| `0032_pipeline_documents.sql` | The listing pipeline's worker support (claims with budgets, results with units, retry, progress), generated documents and their access, signed links for emails, refunds through the payments module, the Deposit preview, the insurer invoice email (`docs/changes/0032_pipeline_documents.md`) |
| `0033_gap_close.sql` | The gaps of 0031 and 0032: renter messages both ways and their emails, the monthly statement emails (PDF first, 7-day links), the assistant's function switcher and scorecard, Turo trips, daily checks, photo review and re-shoot, the late-return panel, find a renter, Sales quotes, field checklists for every job kind, the field report, referrals and profile, the live verification's accounts (`docs/changes/0033_gap_close.md`) |
| `0034_audit_fixes.sql` | The handover audit's database fixes: one-click unsubscribe wrappers and the `/unsubscribe` link path, the renter's review with consent to publish, the disable approval email without a booking, the renter portal listing only the caller's documents, digest lines in words (`docs/changes/0034_audit_fixes.md`, `docs/audit/2026-10-13-audit.md`) |
| `0035_launch_audit.sql` | The launch audit's database changes: sample cars noindex and out of the sitemap until an Admin clears `vehicles.is_sample`, reviews published only with consent, marketing emails waiting for the mailing address, the owner FAQ on tracker fees, email wording, the registry visit email waiting for its date (`docs/changes/0035_launch_audit.md`, `docs/audit/2026-10-13-launch-audit.md`) |
| `0036_sign_in.sql` | Sign-in for every portal: view as (an Admin opens any portal read only, recorded in the audit log), Admin > Portals, invitations into any role, password links from Admin, the verification Admin and one assistant per function, lighter portal frames (`docs/changes/0036_sign_in.md`, `docs/changes/2026-10-14-sign-in.md`) |
| `0037_owner_debit.sql` | The automatic monthly owner debit (pre-debit notice, one PaymentIntent per invoice, results, retries, arrears, pauses, run log), statement emails with their PDFs on set days, the missing sections of the company statement (`docs/changes/2026-10-14-owner-debit.md`) |
| `0038_debit_run_test_owners.sql` | Fixes from 0037's live run: a debit run of test owners only stays with the verification accounts, a webhook before the run's record is not lost, a failed invoice whose retry could not be sent is noticed again |

## Test files

| File | Covers | Assertions |
| --- | --- | --- |
| `01_rules.sql` | The pricing and billing functions against the worked examples | 119 |
| `02_owner_month.sql` | A full owner month: invoices, split, statement, payout | 91 |
| `03_flows.sql` | Status flows and what each step requires | 120 |
| `04_rls.sql` | Row-level security for every role | 153 |
| `05_jobs.sql` | The scheduled jobs of 0015 and the cron count | 56 |
| `06_request_to_book.sql` | Request to book (0016) | 348 |
| `07_notifications.sql` | The notification layer and its wiring (0018, 0023) | 135 |
| `08_booking_app.sql` | The booking application (0019) | 414 |
| `09_operations.sql` | Operations (0020) | 309 |
| `10_tolls_statements.sql` | Tolls, damage and statements (0021) | 146 |
| `11_owners_forms_listings.sql` | Owners, forms and listings (0022) | 200 |
| `12_end_to_end.sql` | The newer flows end to end with the duplicate check across emitters, and the jobs of 0024 | 40 |
| `13_owner_answers.sql` | The owner's answers (0025), one block per decision | 104 |
| `14_web_app.sql` | What the website needs (0027): site facts, handover places, server wrappers | 29 |
| `15_renter_portal.sql` to `18_staff_investor_portals.sql` | The portals' doors (0028 to 0031) | 177 |
| `19_pipeline_documents.sql` | The listing worker, generated documents and links, refunds, Deposit preview, insurer email (0032) | 69 |
| `20_gap_close.sql` | The gaps closed by 0033, and every catalogue code emitted by something | 102 |
| `21_audit_fixes.sql` | The audit fixes of 0034 | 29 |
| `22_launch_audit.sql` | The launch audit changes of 0035 | 28 |
| `23_sign_in.sql` | Sign-in for every portal (0036) | 52 |
| `24_owner_debit.sql` | The owner debit, statement emails and company statement sections (0037, 0038) | 116 |

## Rules for changes

- Money is integer cents; percentages are basis points; HST is stored per line.
- A business rule changes in SQL first, with a test that quotes the specification.
- Never edit an applied migration; add a new one, with its record in `docs/changes/`.
- A new table gets row-level security, an admin policy and an audit trigger in the same migration (`docs/permissions.md` section 5).
- A value an admin may want to change goes in `program_settings` (or its own table), not in code.
- Events are emitted through `app.emit_event()` with the dedupe key `code:entity_id:discriminator`, from one place only.
- Public text says "CarmaCars". The legal company name appears only where the law needs it (invoices, registry forms), read from `program_settings.company_legal_name`.
- The Option 3 coverage provider is never named in code, data or messages.
