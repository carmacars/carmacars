# CarmaCars platform

The rental platform of 18122211 Canada Inc. (CarmaCars), Ontario: public booking site, renter portal, owner portal, admin portal, VA portal and field staff portal in one Next.js app, on Supabase (Postgres, sign-in) and Cloudflare (hosting, files), with Stripe, built-in signing and a GPS tracker with remote killswitch. It is one responsive website for phones and desktops, not a native app.

**This commit is the foundation only:** the database, its rules, its permissions and its tests. The Next.js app is not scaffolded yet.

## What is here

| Path | What |
| --- | --- |
| `supabase/migrations/` | 15 migrations: 101 tables, the billing rules as SQL functions, status flows, row-level security, audit log, reference data, the scheduled SQL jobs |
| `supabase/tests/` | Five test files and a local shim for Supabase's `auth` schema (never applied to Supabase) |
| `scripts/test.sh` | One command: fresh database, all migrations, all tests |
| `scripts/check-text.sh` | Fails if a document or SQL file we write contains an em dash or a sentence en dash |
| `docs/architecture.md` | System overview, environments, app areas, integrations, scheduled jobs, file storage, what is out of scope, deploy and backups |
| `docs/decisions/` | Decision records. 0001: the launch stack with no fixed monthly fees |
| `docs/data-model.md` | Tables by group, status flows, where each billing rule lives, assumptions |
| `docs/permissions.md` | The role matrix and how it is enforced |
| `docs/setup.md` | The accounts (Stripe, GitHub, Supabase, Cloudflare, Resend, Google Workspace) and how they connect; environment variables and GitHub secrets; running the tests; backups |
| `docs/source/` | The agreements, billing specifications and procedures the model was built from |
| `.env.example` | Every environment variable, without values |

## Run the tests

```bash
scripts/test.sh
scripts/check-text.sh
```

The first needs PostgreSQL 15 or later on the machine (`psql`, `initdb`, `pg_ctl`) and ends with `ALL TESTS PASSED`. See `docs/setup.md` section 7.

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
| `0015_scheduled_jobs.sql` | The five scheduled jobs that are pure SQL, their once-per-day guard on `job_runs`, and their `pg_cron` schedule (skipped where `pg_cron` is absent) |

## Rules for changes

- Money is integer cents; percentages are basis points; HST is stored per line.
- A business rule changes in SQL first, with a test that quotes the specification.
- Never edit an applied migration; add a new one.
- A new table gets row-level security, an admin policy and an audit trigger in the same migration (`docs/permissions.md` section 4).
- The Option 3 coverage provider is never named in code, data or messages.
