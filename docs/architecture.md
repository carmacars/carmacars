# Architecture

> **Superseded in part.** Hosting, scheduled jobs, webhooks, file storage, signatures and identity checks follow `docs/decisions/0001-zero-fixed-fee-stack.md`. Where this file says Vercel, Vercel Cron, Supabase Storage or an e-signature service, the decision record wins.

CarmaCars is the rental platform of 18122211 Canada Inc. (Ontario). This document describes the foundation in this repository and the shape of the application that will be built on it. The business rules themselves are in `docs/source/`; where they live in the database is in `docs/data-model.md`.

## 1. System overview

```
 Browser / phone                     Vercel                                Supabase
 ┌──────────────────┐   HTTPS   ┌──────────────────────────┐   SQL    ┌──────────────────────┐
 │ public site      │──────────▶│ Next.js app (TypeScript) │─────────▶│ Postgres (RLS on     │
 │ renter portal    │           │  route groups per role   │          │  every table)        │
 │ owner portal     │           │  server actions          │─────────▶│ Auth (email, phone)  │
 │ admin portal     │           │  /api/webhooks/*         │─────────▶│ Storage (private     │
 │ VA portal        │           │  /api/cron/*             │          │  buckets)            │
 │ field portal     │           └────────────┬─────────────┘          └──────────────────────┘
 └──────────────────┘                        │
                         ┌───────────┬───────┴───────┬─────────────┬───────────────┐
                         ▼           ▼               ▼             ▼               ▼
                      Stripe     e-signature     GPS tracker    email / SMS    photo pipeline
                  (cards, holds,   service      (location,      / WhatsApp
                  debit, identity)              killswitch)
```

One Next.js application on Vercel. One Postgres database on Supabase, which also provides sign-in and file storage. Everything else is an outside service reached through its own module (section 4).

Three rules shape the design:

1. **The database holds the rules.** Rate selection, cancellation tiers, the booking split, fee invoices, statements, claim results and investor returns are SQL functions, tested against the worked examples in the specifications. The TypeScript code calls them; it does not re-implement them. Status changes that are not allowed are refused by the database.
2. **Two ways into the database.** A browser session uses the `authenticated` role and is filtered by row-level security. The server (webhooks, scheduled jobs, any action that moves money) uses the `service_role`, after checking who is asking. Functions that move money can only be executed by the server.
3. **Standard Postgres.** No Supabase-only SQL. The single seam is `app.uid()`, which calls `auth.uid()`. To move hosts: provide the three roles (`anon`, `authenticated`, `service_role`; migration 0012 creates them if missing), replace the body of `app.uid()`, and move the files out of Supabase Storage.

## 2. Environments

| Environment | App | Database | Stripe | Purpose |
| --- | --- | --- | --- | --- |
| Local | `next dev` | Local Postgres with `supabase/tests/shim` | Test mode | Development, `scripts/test.sh` |
| Preview | Vercel preview deployment per branch | A separate Supabase project ("staging") | Test mode | Review before release; safe to reset |
| Production | Vercel production | Supabase production project, Canada (Central) region | Live mode | Real customers and money |

Migrations are applied to staging first, then production. Each environment has its own keys and webhook secrets (see `docs/setup.md`). Production data is never copied to preview.

## 3. The app's areas

Each area is a Next.js route group with its own layout and a guard that checks the user's role on the server. The database enforces the same boundaries again (see `docs/permissions.md`).

| Area | Path | Who | What it does |
| --- | --- | --- | --- |
| Public site | `/`, `/cars`, `/cars/[slug]`, `/book`, `/terms`, `/privacy` | Anyone | Listings, quote, booking request, checkout, policies |
| Renter portal | `/account` | Renters | Bookings, agreement, identity and coverage upload, statements, extension request, cancellation |
| Owner portal | `/owner` | Vehicle owners | Vehicles, calendar, bookings on their cars, fee invoices, statements, payouts, live location, Owner Booking, exit notice |
| Admin portal | `/admin` | The two owners of the company | Everything; approvals (refunds, deposit releases, payouts, tracker disable), fee and rate setting, claims, investors, audit log |
| VA portal | `/va/finance`, `/va/fleet`, `/va/cs`, `/va/sales` | Remote staff | One work queue per role, built on the `tasks` table and the 20 operating procedures |
| Field portal | `/field` | Drivers and detailers | Phone-first: today's jobs, handover and return checklist, photo set in fixed order, signature on screen |
| Webhooks | `/api/webhooks/{stripe,esign,tracker}` | Outside services | Verified by signature; write with the service role |
| Scheduled jobs | `/api/cron/*` | Vercel Cron | Section 5 |

Renters, owners, field staff and investors never write to the database directly from the browser. Their actions are server actions that validate the request and then write. VAs and admins read and write through row-level security for ordinary work; anything that moves money goes through a server action.

## 4. Integrations, each behind its own module

Each lives in `src/integrations/<name>/` behind a small TypeScript interface, with a real adapter and a fake adapter for tests. No other code imports a provider's SDK. Swapping a provider means writing one adapter.

| Module | Provider | Interface (what the app may ask) | Writes to |
| --- | --- | --- | --- |
| `payments` | Stripe | create checkout for a booking; save card; place, capture and release a hold; charge the Card on File; refund; create a debit mandate; debit an owner invoice; handle dispute | `payments`, `payment_processor_details`, `payment_attempts`, `deposits`, `refunds`, `disputes`, `owner_invoices` |
| `identity` | Stripe Identity (staff review as the fallback) | start a check for a driver; read the result | `identity_verifications`, `documents` |
| `esign` | The e-signature service | send a document for signature in signer order; read status; download the signed copy and audit trail | `signature_requests`, `signature_records`, `documents` |
| `tracker` | The custom GPS tracker | read status; send lock, unlock, alarm, engine disable, engine enable; set owner access | `tracker_status`, `tracker_commands`, `tracker_access_blocks` |
| `messaging` | Email, SMS and WhatsApp providers | send template T1 to T26 with values; record an inbound message | `messages` |
| `storage` | Supabase Storage | upload; signed download link | `documents`, `condition_report_photos`, `vehicle_photos` |
| `photos` | The vehicle photo pipeline | enqueue a photo job; receive processed images | `photo_jobs`, `vehicle_photos` |
| `turo` | None at launch (manual entry or CSV) | import trips and payouts | `turo_trips` |

Rules that apply to the adapters:

- **Tracker.** The app never sends an engine disable unless the command row is approved by an admin and carries a reading from the last five minutes showing speed 0 and ignition off. The database refuses the row otherwise, so a bug in the adapter cannot disable a moving car.
- **Payments.** Card numbers never reach the app or the database; only brand and last four digits are stored. Processor tokens sit in admin-only tables.
- **Coverage (Option 3).** The provider is never named to a renter or in a message. The catalogue price is unset, so it cannot be sold until an admin sets it.
- **Idempotency.** Every webhook handler and job is safe to run twice: webhooks key on the provider's event id, jobs on `job_runs (job_name, run_key)`.

## 5. Background jobs and their schedule

Vercel Cron calls `/api/cron/<job>` with `CRON_SECRET`. Cron runs on UTC; every job works out the Toronto date itself (`app.today()`) and records a run key in `job_runs`, so a daylight-saving shift or a retry cannot run a business day twice. Times below are Toronto time.

| When | Job | What it does | Source |
| --- | --- | --- | --- |
| Every 5 minutes | `holds-expire` | Expire tentative holds after 2 hours | Procedure 1 |
| Every 5 minutes | `late-returns` | At 0, 30 minutes, 2 hours and T14 + 1 hour: messages, charges, admin task. Never disables a car by itself | Procedure 8 |
| Every 15 minutes | `payment-retries` | Retry declined charges due (1, 3, 7 days); add the $40 fee once | Renter spec 7 |
| Hourly | `reminders` | T5 the day before pickup, T6 24 hours before return, T3 chase | Procedures 2 to 4 |
| Hourly | `deposit-holds` | Capture a card hold that would lapse before the return time | Renter spec 3 |
| Daily 06:00 | `deposits-due` | List deposits near 7 business days and hold-backs near 30 days | Renter spec 3 |
| Daily 06:00 | `retention` | Purge ID images and face data 90 days after the rental (not on legal hold) | Website policies |
| Daily 06:00 | `expiry-watch` | Turo-Only insurance and plate expiry (T23, 14 days before); safety certificate window; arrears older than 30 days | Procedures 12, 13, 14 |
| Daily 18:00 | `reconcile` | Match processor payouts to payments; raise a task for anything unmatched | Procedure 19 |
| Monday 08:00 | `fleet-recount` | Count the fleet less cars under exit notice; warn an admin at 11 or fewer | Procedure 20 |
| Business day before the 1st | `fleet-report-prepare` | `app.build_fleet_report()` | Procedure 20 |
| 1st | `month-open` | Send the fleet report; compute last month's splits; interest on overdue charges; `app.accrue_investment_returns()` | Payment setup 7 |
| By the 9th | `statements-draft` | `app.build_owner_statement()` per owner; task for admin approval | Owner spec 5 |
| 10th | `payouts` | After admin approval: pay by bank transfer, send T26, list field staff kickbacks for payroll | Owner spec 2 |
| 15th | `owner-billing` | `app.generate_owner_invoices()`; submit debits; T24. Pay investor returns | Owner spec 1, 4 |
| 15th to 25th, daily | `debit-results` | Failed debit: status `failed` (adds the $50 Late Fee), T25 | Owner spec 6 |
| 18th | `debit-retry` | Retry fees plus Late Fee; on failure `in_arrears` | Owner spec 6 |

## 6. File storage layout

All buckets are private except `vehicle-public`. Files are reached through short-lived signed links that the server issues after the `documents` row has passed row-level security for the person asking. Every file has a `documents` row (or a photo row) carrying its retention class.

| Bucket | Path | Holds | Retention |
| --- | --- | --- | --- |
| `identity` | `renters/{renter_id}/{verification_id}/{id_front,id_back,face}.jpg` | Licence images and face photos | 90 days after the rental ends, or after the check |
| `agreements` | `bookings/{booking_id}/…`, `owners/{owner_id}/…`, `owners/{owner_id}/vehicles/{vehicle_id}/…` | Signed agreements, schedules, forms, permits, insurer confirmations | 7 years |
| `condition-photos` | `bookings/{booking_id}/{pickup,return}/{seq}-{shot}.jpg`, `vehicles/{vehicle_id}/{baseline,exit}/…` | Condition Report photo sets | 7 years |
| `statements` | `bookings/{booking_id}/statements/…`, `owners/{owner_id}/{invoices,statements}/…` | Renter statements and supporting records, owner invoices and statements | 7 years |
| `claims` | `incidents/{incident_id}/…` | Estimates, invoices, police reports, tracker screenshots, dispute evidence | 7 years |
| `vehicle-originals` | `vehicles/{vehicle_id}/original/…` | Listing photos as shot | While listed |
| `vehicle-public` | `vehicles/{vehicle_id}/{angle}.jpg` | Processed listing photos (public) | While listed |
| `admin` | `investors/{investor_id}/…`, `staff/{user_id}/…`, `shareholder/…`, `fleet-reports/{yyyy-mm}.pdf` | Admin-only folder | 7 years or permanent |

Tracker position history stays with the tracker service for 12 months; only the reading a decision relied on is copied into `tracker_commands` or a screenshot.

## 7. Deliberately out of scope for launch

| Not built | What happens instead |
| --- | --- |
| Paying owners and investors through the processor (Stripe Connect) | Bank transfer by an admin; the `payouts` table records and approves each one |
| A general ledger | The database tags every line (owner revenue, company only, pass-through, claim funds, HST). An export feeds the accountant's chart of accounts in `docs/source/payment_esign_setup.md` |
| Turo integration | Trips and Turo payouts are entered by hand or imported from a file |
| Insurer and broker integration | Claims are run by an admin; the ledger records money in and out |
| Selling coverage (Option 3) | Listed in the catalogue with no price; cannot be sold until priced and cleared by the lawyer |
| Payroll | Field staff kickbacks are listed for payroll, not paid by the platform |
| Native mobile apps | The field portal is a phone-first web app |
| Dynamic pricing, promotions, loyalty | Rates are the four per-vehicle rates; the only discount is the fixed 10% non-refundable one |
| Automatic toll and ticket feeds | Notices are entered by Finance and matched by `app.match_toll_ticket()` |
| Renter-to-renter or owner-to-renter chat | Messages go through CarmaCars and are logged |
| Markets outside Ontario, currencies other than CAD | One tax (HST 13%), one time zone (America/Toronto) |
| Automatic disabling of a car | Every disable is a person's decision, approved by an admin |
