# Architecture

CarmaCars is the rental platform of 18122211 Canada Inc. (Ontario). This document describes the foundation in this repository and the shape of the application that will be built on it. The business rules themselves are in `docs/source/`; where they live in the database is in `docs/data-model.md`. The choice of services, and what each costs, is in `docs/decisions/0001-zero-fixed-fee-stack.md`.

## 1. System overview

```
 Browser (phone or desktop)          Cloudflare                            Supabase (Canada Central)
 ┌──────────────────┐   HTTPS   ┌──────────────────────────┐   SQL    ┌──────────────────────────┐
 │ public site      │──────────▶│ Worker: Next.js app      │─────────▶│ Postgres (RLS on every   │
 │ renter portal    │           │  (TypeScript, OpenNext)  │          │  table, rules in SQL)    │
 │ owner portal     │           │  route groups per role   │─────────▶│ Auth (email sign-in)     │
 │ admin portal     │           │  server actions          │          │ pg_cron (scheduled jobs) │
 │ VA portal        │           ├──────────────────────────┤          │ Edge Functions:          │
 │ field portal     │◀─────────▶│ R2 (private buckets,     │          │  stripe-webhook          │
 └──────────────────┘  signed   │  signed links)           │          │  tracker-webhook         │
                       links    │ DNS, Turnstile           │          │  jobs with outside calls │
                                └──────────────────────────┘          └────────────┬─────────────┘
                                                                                   │
                         ┌──────────────┬──────────────┬──────────────┬────────────┘
                         ▼              ▼              ▼              ▼
                      Stripe        GPS tracker     Resend         photo pipeline
                  (cards, holds,   (location,      (email from
                   bank debit)      killswitch)    mail.carmacars.ca)

 GitHub Actions: tests, deploy to Cloudflare and Supabase, nightly encrypted backup to R2
```

One Next.js application, built with the OpenNext adapter and run as a Cloudflare Worker. One Postgres database on Supabase, which also provides sign-in, the scheduler (`pg_cron`) and the Edge Functions that receive webhooks and run the jobs that call an outside service. Files are in Cloudflare R2. Everything else is an outside service reached through its own module (section 4).

Three rules shape the design:

1. **The database holds the rules.** Rate selection, cancellation tiers, the booking split, fee invoices, statements, claim results and investor returns are SQL functions, tested against the worked examples in the specifications. The TypeScript code calls them; it does not re-implement them. Status changes that are not allowed are refused by the database.
2. **Two ways into the database.** A browser session uses the `authenticated` role and is filtered by row-level security. The server (webhooks, scheduled jobs, any action that moves money) uses the `service_role`, after checking who is asking. Functions that move money can only be executed by the server.
3. **Standard Postgres.** No Supabase-only SQL in the rules. The single seam is `app.uid()`, which calls `auth.uid()`. To move hosts: provide the three roles (`anon`, `authenticated`, `service_role`; migration 0012 creates them if missing), replace the body of `app.uid()`, and run the job wrappers of migration 0015 from another scheduler. Files are already outside the database host, in R2.

Two limits of the free Cloudflare plan shape the app: 10 ms of processing per request and 100,000 requests a day. Pages are static or cached where possible. Pricing, availability and money logic stay in SQL functions, which the limit does not count.

## 2. Environments

| Environment | App | Database | Stripe | Purpose |
| --- | --- | --- | --- | --- |
| Local | `next dev` | Local Postgres with `supabase/tests/shim` | Test mode | Development, `scripts/test.sh` |
| Staging | Cloudflare Worker `carmacars-staging`, deployed from the `staging` branch | A separate Supabase project (`carmacars-staging`) | Test mode | Review before release; safe to reset |
| Production | Cloudflare Worker `carmacars-prod`, deployed from `main` | Supabase project `carmacars-prod`, Canada (Central) region | Live mode | Real customers and money |

Migrations are applied to staging first, then production. Each environment has its own keys, webhook secrets and R2 buckets (see `docs/setup.md`). Production data is never copied to staging.

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
| Webhooks | Supabase Edge Functions `supabase/functions/stripe-webhook` and `supabase/functions/tracker-webhook` | Outside services | Verified by the sender's signature; write with the service role |
| Scheduled jobs | `pg_cron` in the database; an Edge Function where an outside call is needed | The scheduler | Section 5 |

Renters, owners, field staff and investors never write to the database directly from the browser. Their actions are server actions that validate the request and then write. VAs and admins read and write through row-level security for ordinary work; anything that moves money goes through a server action. Public forms (booking request, sign-up, contact) are checked with Cloudflare Turnstile on the server before anything is written.

## 4. Integrations, each behind its own module

Each lives in `src/integrations/<name>/` behind a small TypeScript interface, with a real adapter and a fake adapter for tests. No other code imports a provider's SDK. Swapping a provider means writing one adapter.

| Module | Provider | Interface (what the app may ask) | Writes to |
| --- | --- | --- | --- |
| `payments` | Stripe, pay per transaction. No Stripe Billing, no Stripe Invoicing | create checkout for a booking; save card; place, capture and release a hold; charge the Card on File; refund; create a debit mandate; debit an owner invoice; handle dispute | `payments`, `payment_processor_details`, `payment_attempts`, `deposits`, `refunds`, `disputes`, `owner_invoices` |
| `identity` | Staff review of the licence photo and selfie (the default). Stripe Identity is a second adapter, off by default | start a check for a driver; read the result | `identity_verifications`, `documents` |
| `signing` | Built into the platform; no outside service | open a document for signature in signer order; record each signature; produce and store the signed copy | `signature_requests`, `signature_records`, `documents` |
| `tracker` | The custom GPS tracker | read status; send lock, unlock, alarm, engine disable, engine enable; set owner access | `tracker_status`, `tracker_commands`, `tracker_access_blocks` |
| `messaging` | Resend, email only at launch | send template T1 to T26 with values; record a reply | `messages` |
| `storage` | Cloudflare R2 | upload; signed download link | `documents`, `condition_report_photos`, `vehicle_photos` |
| `photos` | The vehicle photo pipeline | enqueue a photo job; receive processed images | `photo_jobs`, `vehicle_photos` |
| `turo` | None at launch (manual entry or CSV) | import trips and payouts | `turo_trips` |

Rules that apply to the adapters:

- **Tracker.** The app never sends an engine disable unless the command row is approved by an admin and carries a reading from the last five minutes showing speed 0 and ignition off. The database refuses the row otherwise, so a bug in the adapter cannot disable a moving car.
- **Payments.** Card numbers never reach the app or the database; only brand and last four digits are stored. Processor tokens sit in admin-only tables. Recurring owner fees are charged by the platform's own schedule (section 5) against the Owner's saved debit mandate, not by a Stripe subscription. A card hold lasts about 7 days: unless Stripe approves extended holds, the `deposit-holds` job renews a hold before it lapses.
- **Signing.** The signer reviews the document in the portal and signs by typing their name or drawing on the screen. For each signer `signature_records` stores the name, role, time (`signed_at`), method (`typed` or `drawn`), IP address, browser (`user_agent`), a reference to the stored signature (`provider_signature`) and any initialled confirmations (`initials`). The signed PDF is stored in R2 as a `documents` row with its SHA-256 hash (`documents.sha256`), linked from `signature_requests.signed_document_id`; the request row carries `provider = 'builtin'`. Forms that need a witness (Form C, Form D and the Shareholder Agreement) are signed on paper, scanned and uploaded as `documents` rows.
- **Identity.** A staff member compares the licence photo with the selfie and records the result (`identity_method = 'staff_review'` on the booking's driver). Switching on Stripe Identity is a setting in the `identity` module (`IDENTITY_PROVIDER=stripe`) and costs CA$2.00 per check; nothing else changes.
- **Messaging.** Email only at launch. Platform email is sent through Resend from the subdomain `mail.carmacars.ca`, so its DNS records do not collide with Google Workspace on the root domain. Replies go to the staff mailbox `info@carmacars.ca` (Google Workspace, with aliases such as `bookings@` and `owners@`). The `messages` table already allows SMS and WhatsApp as channels; no provider is connected.
- **Storage.** Buckets are private. The server issues a short-lived signed link only after the `documents` row has passed row-level security for the person asking (section 6).
- **Coverage (Option 3).** The provider is never named to a renter or in a message. The catalogue price is unset, so it cannot be sold until an admin sets it.
- **Idempotency.** Every webhook handler and job is safe to run twice: webhooks key on the provider's event id, jobs on `job_runs (job_name, run_key)`.

## 5. Background jobs and their schedule

Jobs are started by `pg_cron` inside the Supabase database. There are two kinds:

- **SQL.** `pg_cron` calls a wrapper function in the `app` schema directly. Nothing leaves the database.
- **Edge Function.** Where the job must call Stripe, send email or delete files, `pg_cron` calls a Supabase Edge Function (`supabase/functions/<job>`) over HTTPS with `pg_net`, sending the service role key held in Supabase Vault. The function calls the outside service and writes the result through the same SQL functions.

`pg_cron` runs on UTC. A job that belongs to a Toronto time is scheduled every hour; the job works out the Toronto date and hour itself and claims a row in `job_runs (job_name, run_key)`, so a daylight-saving shift or a retry cannot run a business day twice. A run that fails is marked `failed` with its error, raises one urgent admin task, and is tried again on the next hourly call that day. Times below are Toronto time.

| When | Job | What it does | Source | Runs as |
| --- | --- | --- | --- | --- |
| Every 5 minutes | `holds-expire` | Expire tentative holds after 2 hours | Procedure 1 | SQL; function not written yet |
| Every 5 minutes | `late-returns` | At 0, 30 minutes, 2 hours and T14 + 1 hour: messages, charges, admin task. Never disables a car by itself | Procedure 8 | Runs in an Edge Function, built with the app |
| Every 15 minutes | `payment-retries` | Retry declined charges due (1, 3, 7 days); add the $40 fee once | Renter spec 7 | Runs in an Edge Function, built with the app |
| Hourly | `reminders` | T5 the day before pickup, T6 24 hours before return, T3 chase | Procedures 2 to 4 | Runs in an Edge Function, built with the app |
| Hourly | `deposit-holds` | Before a card hold lapses: place a new hold and release the old one; once the rental passes 7 days in total, capture it instead | Renter spec 3; decision 0001 | Runs in an Edge Function, built with the app |
| Daily 06:00 | `deposits-due` | List deposits near 7 business days and hold-backs near 30 days | Renter spec 3 | SQL; function not written yet |
| Daily 06:00 | `retention` | Purge ID images and face data 90 days after the rental (not on legal hold) | Website policies | Runs in an Edge Function, built with the app |
| Daily 06:00 | `expiry-watch` | Turo-Only insurance and plate expiry (T23, 14 days before); safety certificate window; arrears older than 30 days | Procedures 12, 13, 14 | Runs in an Edge Function, built with the app |
| Daily 18:00 | `reconcile` | Match processor payouts to payments; raise a task for anything unmatched | Procedure 19 | Runs in an Edge Function, built with the app |
| Monday 08:00 | `fleet-recount` | Count the fleet less cars under exit notice; warn an admin at 11 or fewer | Procedure 20 | SQL, scheduled in migration 0015: `app.job_fleet_recount()` |
| Business day before the 1st, 08:00 | `fleet-report-prepare` | `app.build_fleet_report()` for the coming month | Procedure 20 | SQL, scheduled in migration 0015: `app.job_fleet_report_prepare()` |
| 1st, 06:00 | `returns-accrue` | `app.accrue_investment_returns()` for last month | Payment setup 7 | SQL, scheduled in migration 0015: `app.job_returns_accrue()` |
| 1st | `month-open` | Send the fleet report; compute last month's splits; interest on overdue charges | Payment setup 7 | Runs in an Edge Function, built with the app |
| 5th, 06:00 (by the 9th) | `statements-draft` | `app.build_owner_statement()` per owner; task for admin approval | Owner spec 5 | SQL, scheduled in migration 0015: `app.job_statements_draft()` |
| 10th | `payouts` | After admin approval: pay by bank transfer, send T26, list field staff kickbacks for payroll | Owner spec 2 | Runs in an Edge Function, built with the app |
| 15th, 06:00 | `owner-invoices` | `app.generate_owner_invoices()`: one draft invoice per vehicle | Owner spec 1 | SQL, scheduled in migration 0015: `app.job_owner_invoices()` |
| 15th | `owner-billing` | Submit the debits for the invoices; T24. Pay investor returns | Owner spec 1, 4 | Runs in an Edge Function, built with the app |
| 15th to 25th, daily | `debit-results` | Failed debit: status `failed` (adds the $50 Late Fee), T25 | Owner spec 6 | Runs in an Edge Function, built with the app |
| 18th | `debit-retry` | Retry fees plus Late Fee; on failure `in_arrears` | Owner spec 6 | Runs in an Edge Function, built with the app |

Notes on the table:

- The five jobs marked "scheduled in migration 0015" exist now and are tested (`supabase/tests/05_jobs.sql`). The schedule itself is created only where `pg_cron` is available, so the migration does nothing on a plain local database.
- The 1st and the 15th each had one job that mixed SQL work with an outside call. They are now two jobs each: the SQL step (`returns-accrue`, `owner-invoices`) runs at 06:00, and the step that needs Stripe or email (`month-open`, `owner-billing`) follows in an Edge Function.
- `statements-draft` runs 5 days before the payout date, which is the 5th while payouts are on the 10th. That leaves the admins until the 9th to approve.
- "SQL; function not written yet" means the job needs no outside call, but its function is not in migrations 0001 to 0015. It is added by a later migration, with the app.
- To run a missed day by hand, call the wrapper with the instant it should have run, for example `select app.job_owner_invoices(timestamptz '2026-11-15 06:00 America/Toronto')`. The run key still stops a second run.

## 6. File storage layout

Files are in Cloudflare R2. All buckets are private except `vehicle-public`. Files are reached through short-lived signed links that the server issues after the `documents` row has passed row-level security for the person asking. Every file has a `documents` row (or a photo row) carrying its retention class. The bucket names below are the names stored in `documents.storage_bucket`; in R2 each carries an environment prefix (`R2_BUCKET_PREFIX`), because staging and production share one Cloudflare account.

| Bucket | Path | Holds | Retention |
| --- | --- | --- | --- |
| `identity` | `renters/{renter_id}/{verification_id}/{id_front,id_back,face}.jpg` | Licence images and face photos | 90 days after the rental ends, or after the check |
| `agreements` | `bookings/{booking_id}/…`, `owners/{owner_id}/…`, `owners/{owner_id}/vehicles/{vehicle_id}/…` | Signed agreements, schedules, forms (including scanned witnessed forms), permits, insurer confirmations | 7 years |
| `condition-photos` | `bookings/{booking_id}/{pickup,return}/{seq}-{shot}.jpg`, `vehicles/{vehicle_id}/{baseline,exit}/…` | Condition Report photo sets | 7 years |
| `statements` | `bookings/{booking_id}/statements/…`, `owners/{owner_id}/{invoices,statements}/…` | Renter statements and supporting records, owner invoices and statements | 7 years |
| `claims` | `incidents/{incident_id}/…` | Estimates, invoices, police reports, tracker screenshots, dispute evidence | 7 years |
| `vehicle-originals` | `vehicles/{vehicle_id}/original/…` | Listing photos as shot | While listed |
| `vehicle-public` | `vehicles/{vehicle_id}/{angle}.jpg` | Processed listing photos (public) | While listed |
| `admin` | `investors/{investor_id}/…`, `staff/{user_id}/…`, `shareholder/…`, `fleet-reports/{yyyy-mm}.pdf` | Admin-only folder | 7 years or permanent |

Tracker position history stays with the tracker service for 12 months; only the reading a decision relied on is copied into `tracker_commands` or a screenshot.

**Backups.** One more private bucket, `backups`, holds the database backups. A GitHub Actions job runs `pg_dump` every night, encrypts the file before it leaves the runner, and uploads it to R2. The encryption key is a GitHub repository secret and is also kept in the company password manager; without it a backup cannot be read. A restore into a fresh database is tested before go-live and after any change to the backup job.

## 7. Deliberately out of scope for launch

| Not built | What happens instead |
| --- | --- |
| Paying owners and investors through the processor (Stripe Connect) | Bank transfer by an admin; the `payouts` table records and approves each one |
| A general ledger | The database tags every line (owner revenue, company only, pass-through, claim funds, HST). An export feeds the accountant's chart of accounts in `docs/source/payment_esign_setup.md` |
| An outside e-signature service | Signing is built in (section 4). Witnessed forms are signed on paper and uploaded |
| Automatic identity checks | Staff review. Stripe Identity can be switched on later in the `identity` module |
| SMS and WhatsApp | Email only. A provider can be added behind the `messaging` module |
| Stripe Billing and Stripe Invoicing | The platform builds its own invoices and charges saved payment methods on its own schedule |
| Turo integration | Trips and Turo payouts are entered by hand or imported from a file |
| Insurer and broker integration | Claims are run by an admin; the ledger records money in and out |
| Selling coverage (Option 3) | Listed in the catalogue with no price; cannot be sold until priced and cleared by the lawyer |
| Payroll | Field staff kickbacks are listed for payroll, not paid by the platform |
| Native mobile apps | One responsive website (section 8); the field portal is a phone-first web app |
| Dynamic pricing, promotions, loyalty | Rates are the four per-vehicle rates; the only discount is the fixed 10% non-refundable one |
| Automatic toll and ticket feeds | Notices are entered by Finance and matched by `app.match_toll_ticket()` |
| Renter-to-renter or owner-to-renter chat | Messages go through CarmaCars and are logged |
| Markets outside Ontario, currencies other than CAD | One tax (HST 13%), one time zone (America/Toronto) |
| Automatic disabling of a car | Every disable is a person's decision, approved by an admin |

## 8. One website for phones and desktops

The product is one responsive website. It is not a native app, and nothing is installed from an app store. Every area in section 3 works in a phone browser and in a desktop browser, from the same address and the same code.

The field staff portal (`/field`) is designed for a phone first: large buttons, the camera for the photo set, a signature drawn on the screen. It can be added to the phone's home screen from the browser's menu ("Add to Home Screen"), after which it opens full screen from its own icon like an app. It still needs a connection: jobs, photos and signatures are saved to the server as they are taken.

## 9. Deploy and operations

| What | How |
| --- | --- |
| Tests | GitHub Actions runs `scripts/test.sh` and `scripts/check-text.sh` on every push |
| App | GitHub Actions builds the Next.js app with the OpenNext adapter and deploys it to Cloudflare Workers: `staging` branch to staging, `main` to production |
| Migrations | Applied by GitHub Actions with `DATABASE_URL`, staging first, production after approval |
| Edge Functions | Deployed by GitHub Actions with the Supabase CLI |
| Backups | Nightly GitHub Actions job: `pg_dump`, encrypt, upload to the R2 `backups` bucket (section 6) |
| Secrets | GitHub repository secrets, per environment. The deploy job copies them to Cloudflare and Supabase. No secret is ever pasted into a chat, an email or a ticket (`docs/setup.md` section 6) |

The workflows themselves are added with the app; this repository does not hold them yet.

## 10. When a fixed fee starts

The launch stack has no fixed monthly fee except the staff mailbox. These are the points at which one begins (from the decision record):

| Trigger | Cost |
| --- | --- |
| Requests fail on the 10 ms limit under real traffic | Cloudflare Workers Paid, US$5 a month |
| Database nears 500 MB, or point-in-time recovery is wanted | Supabase Pro, US$25 a month |
| More than 100 emails a day | Resend Pro, US$20 a month |
