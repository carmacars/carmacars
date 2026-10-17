# Architecture

CarmaCars is a car rental platform in Ontario. This document describes the foundation in this repository and the shape of the application that will be built on it. The business rules themselves are in `docs/source/`; where they live in the database is in `docs/data-model.md`. Sections 11 to 14 describe the flows built in migrations 0016 to 0024; each migration's full record is in `docs/changes/`. The choice of services, and what each costs, is in `docs/decisions/0001-zero-fixed-fee-stack.md`.

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
                   bank debit)      killswitch)    carmacars.ca)

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
| `tracker` | The custom GPS tracker. Not connected yet (0042): the interface is `locate`, `requestImmobilize` and `mileage` (`web/src/integrations/tracker/`), and the only adapter, `none`, answers "not connected"; the Admin vehicle page says "Coming soon" | read status; send lock, unlock, alarm, engine disable, engine enable; set owner access | `tracker_status`, `tracker_commands`, `tracker_access_blocks` |
| `vision` | Cloudflare Workers AI vision model through the Worker's AI binding (0042) | read a scanned toll notice page into JSON lines; suggest the licence plate box on a listing photo. Each call is recorded in `provider_calls` with its neurons and capped by `ai_vision_daily_neurons` | `provider_calls` (the answer itself goes back to the browser for a person to check) |
| `messaging` | Resend, email only at launch | send template T1 to T26 with values; record a reply | `messages` |
| `storage` | Cloudflare R2 | upload; signed download link | `documents`, `condition_report_photos`, `vehicle_photos` |
| `photos` | The vehicle photo pipeline | enqueue a photo job; receive processed images | `photo_jobs`, `vehicle_photos` |
| `turo` | None at launch (manual entry or CSV) | import trips and payouts | `turo_trips` |

Rules that apply to the adapters:

- **Tracker.** The app never sends an engine disable unless the command row is approved by an admin and carries a reading from the last five minutes showing speed 0 and ignition off. The database refuses the row otherwise, so a bug in the adapter cannot disable a moving car.
- **Payments.** Card numbers never reach the app or the database; only brand and last four digits are stored. Processor tokens sit in admin-only tables. Recurring owner fees are charged by the platform's own schedule (section 5) against the Owner's saved debit mandate, not by a Stripe subscription. A card hold lasts about 7 days: unless Stripe approves extended holds, the `deposit-holds` job renews a hold before it lapses.
- **Signing.** The signer reviews the document in the portal and signs by typing their name or drawing on the screen. For each signer `signature_records` stores the name, role, time (`signed_at`), method (`typed` or `drawn`), IP address, browser (`user_agent`), a reference to the stored signature (`provider_signature`) and any initialled confirmations (`initials`). The signed PDF is stored in R2 as a `documents` row with its SHA-256 hash (`documents.sha256`), linked from `signature_requests.signed_document_id`; the request row carries `provider = 'builtin'`. Forms that need a witness (Form C, Form D and the Shareholder Agreement) are signed on paper, scanned and uploaded as `documents` rows.
- **Identity.** A staff member compares the licence photo with the selfie and records the result (`identity_method = 'staff_review'` on the booking's driver). Switching on Stripe Identity is a setting in the `identity` module (`IDENTITY_PROVIDER=stripe`) and costs CA$2.00 per check; nothing else changes.
- **Messaging.** Email only at launch. Platform email is sent through Resend from the subdomain `carmacars.ca`, so its DNS records do not collide with Google Workspace on the root domain. Replies go to the staff mailbox `info@carmacars.ca` (Google Workspace, with aliases such as `bookings@` and `owners@`). The `messages` table already allows SMS and WhatsApp as channels; no provider is connected.
- **Storage.** Buckets are private. The server issues a short-lived signed link only after the `documents` row has passed row-level security for the person asking (section 6).
- **Coverage (Option 3).** The provider is never named to a renter or in a message. The catalogue price is unset, so it cannot be sold until an admin sets it.
- **Idempotency.** Every webhook handler and job is safe to run twice: webhooks key on the provider's event id, jobs on `job_runs (job_name, run_key)`.

## 5. Background jobs and their schedule

Jobs are started by `pg_cron` inside the Supabase database. There are two kinds:

- **SQL.** `pg_cron` calls a wrapper function in the `app` schema directly. Nothing leaves the database.
- **Edge Function.** Where the job must call Stripe, send email, call a listing provider or delete files, `pg_cron` calls a Supabase Edge Function (`supabase/functions/<job>`) over HTTPS with `pg_net`, sending the service role key held in Supabase Vault. The function calls the outside service and writes the result through the same SQL functions.

`pg_cron` runs on UTC. A job that belongs to a Toronto time is scheduled every hour (or more often); the wrapper works out the Toronto date and hour itself and claims a row in `job_runs (job_name, run_key)` with `app.job_claim()`, so a daylight-saving shift or a retry cannot run a business day (or a slot) twice. A run that fails is marked `failed` with its error, raises one urgent admin task and the `staff_job_failed` email, and is tried again on the next call. Every wrapper takes the instant to judge by, so a missed run can be made by hand, for example `select app.job_owner_invoices(timestamptz '2026-11-15 06:00 America/Toronto')`; the run key still stops a second run. Where `pg_cron` is absent (a plain local database) the migrations schedule nothing. Times below are Toronto time.

### Run by pg_cron inside the database (22 jobs)

| Cron job | When | Wrapper | What it does | Migration |
| --- | --- | --- | --- | --- |
| `carmacars-fleet-recount` | Monday from 08:00 | `app.job_fleet_recount()` | Count the fleet less cars under exit notice; warn an admin at the warning level | 0015 |
| `carmacars-fleet-report-prepare` | Business day before the 1st, from 08:00 | `app.job_fleet_report_prepare()` | `app.build_fleet_report()` for the coming month | 0015 |
| `carmacars-returns-accrue` | 1st, from 06:00 | `app.job_returns_accrue()` | Investor returns for last month | 0015 |
| `carmacars-statements-draft` | 5 days before the payout date, from 06:00 | `app.job_statements_draft()` | `app.build_owner_statement()` per owner; review task | 0015 |
| `carmacars-owner-invoices` | 15th, from 06:00 | `app.job_owner_invoices()` | One draft fee invoice per vehicle | 0015 |
| `carmacars-offers-expire` | Every 5 minutes | `app.job_offers_expire()` | An offer past its expiry goes back to `requested` with a task | 0016 |
| `carmacars-notify-events` | Every minute | `app.job_notify_events()` | `app.process_events()`: events to outbox, digests and in-app notices | 0018 |
| `carmacars-deposits-due` | Daily from 06:00 | `app.job_deposits_due()` | Deposits due back soon, hold-backs near their last day | 0020 |
| `carmacars-expiry-watch` | Daily from 06:00 | `app.job_expiry_watch()` | Turo-Only expiry, safety certificate window, plate renewal, arrears past the removal date | 0020 |
| `carmacars-reconcile` | Daily from 18:00 | `app.job_reconcile()` | Matches recorded processor payouts again; flags card payments no payout carried | 0020 |
| `carmacars-ops-watch` | Every 15 minutes | `app.job_ops_watch()` | Wakes waiting tasks; raises the clock-driven tasks (offers to chase, verification, Deposit, late returns, unacknowledged jobs, daily checks). Sends nothing, charges nothing | 0020 |
| `carmacars-toll-watch` | Daily from 06:00 | `app.job_toll_watch()` | A notice still unmatched after the set business days: Admin task and email | 0021 |
| `carmacars-company-statement` | The owner statements' draft day, from 06:00 | `app.job_company_statement_draft()` | Drafts CarmaCars' statement for last month with its checks | 0021 |
| `carmacars-notify-reminders` | Every 5 minutes | `app.job_notify_reminders()` | Booking, pickup, return and offer reminders, identity chase, unsigned agreement, late return stages, requests waiting | 0023 |
| `carmacars-notify-scheduled` | Every 5 minutes | `app.job_notify_scheduled()` | Follow-ups, daily checks, statement reminder, payouts due, digests, field job lists, weekly summary, each once per day, week or month | 0023 |
| `carmacars-rate-limit-purge` | Daily from `housekeeping_hour` (03:00) | `app.job_rate_limit_purge()` | Removes rate limit counters older than `rate_limit_keep_hours` | 0024 |
| `carmacars-form-drafts-purge` | Daily from `housekeeping_hour` | `app.job_form_drafts_purge()` | Removes expired drafts and submitted drafts past `form_submitted_keep_days` | 0024 |
| `carmacars-lapse-extensions` | Every 15 minutes | `app.job_lapse_extensions()` | An extension not paid by the current return time lapses | 0024 |
| `carmacars-listing-sweep` | Every 10 minutes | `app.job_listing_sweep()` | A listing job a worker claimed and did not finish goes back to the queue (or fails after its attempts); counts what is due | 0024 |
| `carmacars-listings-publish` | Every 5 minutes | `app.job_publish_listings()` | Publishes listings whose `publish_at` has come, in the scheduler's name; a refusal is kept in `publish_error` with a Fleet task | 0024 |
| `carmacars-owner-debit-notices` | The debit day less `owner_debit_notice_days`, from `owner_debit_run_hour` | `app.job_owner_debit_notices()` | Issues the month's fee invoices, emails each owner the pre-debit notice and schedules one debit per invoice (no mandate: the owner is asked to set one up, an Admin gets the exception) | 0037 |
| `carmacars-booking-changes` | Every 15 minutes | `app.job_booking_changes()` | A change staff proposed to a confirmed booking: one reminder `booking_change_reminder_hours` before its deadline, then it expires (the booking stays as it was; renter and customer service are told) | 0040 |

These are tested in `05_jobs.sql`, `06_request_to_book.sql`, `07_notifications.sql`, `09_operations.sql`, `10_tolls_statements.sql` and `12_end_to_end.sql`, by calling each wrapper with chosen instants.

### Still to run in an Edge Function (each calls an outside service)

| Job | When | What it does | Outside service |
| --- | --- | --- | --- |
| `send-outbox` | Every minute | `app.outbox_claim()`, render with `emails/src/engine.mjs`, send, then `app.outbox_mark_sent()` or `app.outbox_mark_failed()`; bounces through `app.outbox_record_bounce()` | Resend |
| `listing-worker` | Every few minutes | `app.claim_listing_jobs()`, call the provider, `app.complete_listing_job()` or `app.fail_listing_job()` (the sweep above only re-queues) | VIN decoder, copy model, photo processor |
| `late-returns` | Every 5 minutes | The charges of a late return (the tasks are raised by `ops-watch`, the emails by `notify-reminders`) | Stripe |
| `payment-retries` | Every 15 minutes | Retry declined charges due (1, 3, 7 days); add the declined-payment fee once | Stripe |
| `deposit-holds` | Hourly | Before a card hold lapses: place a new hold and release the old one, or capture it once the rental passes the hold period | Stripe |
| `retention` | Daily 06:00 | Purge ID images and face data 90 days after the rental (not on legal hold) | R2 |
| `reconcile` (fetch step) | Daily before 18:00 | Read processor payouts, then `app.record_processor_payout()`; the SQL matching runs in `carmacars-reconcile` | Stripe |
| `month-open` | 1st | Send the fleet report; interest on overdue charges | Email, Stripe |
| `payouts` | 10th | After admin approval: pay by bank transfer, list field staff kickbacks for payroll | Bank, email |
| `owner-debit` (built, 0037) | Hourly (`carmacars-owner-debit`); acts on the debit day and on retry days | `app.owner_debit_claim()`, one off-session PaymentIntent per invoice and attempt, `app.owner_debit_submitted()`; asks Stripe again about debits processing too long; results also arrive through the Stripe webhook (`app.owner_debit_result()`) | Stripe |
| `owner-billing` (investor part) | 15th | Pay investor returns | Bank |

The 1st and the 15th each have the SQL step at 06:00 (`returns-accrue`, `owner-invoices`) and the step that needs Stripe or email after it (`month-open`, `owner-billing`). `statements-draft` runs 5 days before the payout date, which leaves the admins until the 9th to approve.

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

**Backups.** A GitHub Actions job (`.github/workflows/backup.yml`) runs `pg_dump` every night through the session pooler, encrypts the file with age before it leaves the runner (the public key and the private key are vault secrets `backup_age_recipient` and `backup_age_identity`; keep the private key in the company password manager too), uploads it to the private Supabase Storage bucket `backups` (30 days kept) and restores it into a scratch PostgreSQL 17 to compare every table. Every Monday the newest backup is checked and restored again. See `docs/backups.md`.

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
| Automatic toll and ticket feeds | Finance uploads each notice or statement; it is read in the browser (CSV, PDF text with the issuer's reading profile, or the vision model for a scan), checked line by line beside the file, then imported and matched by `app.match_toll_ticket()` (0042) |
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
| Backups | Nightly GitHub Actions job: `pg_dump`, encrypt (age), upload to the Supabase Storage `backups` bucket, restore test; weekly check (`docs/backups.md`) |
| Secrets | GitHub repository secrets, per environment. The deploy job copies them to Cloudflare and Supabase. No secret is ever pasted into a chat, an email or a ticket (`docs/setup.md` section 6) |

The workflows themselves are added with the app; this repository does not hold them yet.

## 10. When a fixed fee starts

The launch stack has no fixed monthly fee except the staff mailbox. These are the points at which one begins (from the decision record):

| Trigger | Cost |
| --- | --- |
| Requests fail on the 10 ms limit under real traffic | Cloudflare Workers Paid, US$5 a month |
| Database nears 500 MB, or point-in-time recovery is wanted | Supabase Pro, US$25 a month |
| More than 100 emails a day | Resend Pro, US$20 a month |

## 11. Request to book (migrations 0016, 0019, 0020)

A booking is asked for, offered, approved, signed and paid; only then does it take the car.

1. **Quote and search.** `app.quote_booking()` and `app.search_available()` price a listed car from the rate card in force through one function, `app.price_lines()`, which also prices every stored booking. The visitor sees the total, the Deposit and the kilometre allowance.
2. **Request.** The server checks the bot test and calls `app.submit_booking_request()` with the visitor's address: one transaction finds or creates the user, renter and driver, checks dates, ages, licence, drivers, extras and consents, creates the request (`requested`) with its lines, and stores the request key, so a second press returns the first booking. Rate limits per address and per customer are settings.
3. **Offer.** Customer service may adjust the request (`app.adjust_booking()`), then sends a numbered offer (`app.send_offer()`); an offer expires after `offer_expiry_hours` and goes back to `requested`. The renter approves it (`pending_payment`) or asks for a change (`requested`).
4. **Sign.** `app.open_rental_agreement()` opens the `RA-` agreement for the approved version; the renter signs by typing or drawing (`app.record_signature()`, with the document hash and consent text).
5. **Pay and confirm.** When the card is authorized, `app.record_booking_payment()` checks everything again under a lock on the car (status, offer version, signature, amount, a credit card, the car free), saves the Card on File, countersigns for CarmaCars and confirms. Any refusal tells the server to void the authorization. Another booking that wanted the same dates goes back to customer service.
6. **Before pickup.** The renter uploads the licence, selfie and proof of coverage; customer service reviews them. `app.booking_readiness()` lists what is missing.
7. **Handover and return.** On a phone (`app.complete_handover()`, `app.complete_return()`) with the photo list in order, the Deposit taken or waived, signatures and readings. After the return Fleet reviews the photos, Finance assesses the charges (`app.assess_check_in()`), the Check-in statement is issued and the Deposit is settled (`app.settle_deposit()`), which closes the booking.
8. **Changes.** Cancellation by the tier table (`app.cancel_booking()`). An extension (`app.request_extension()`), from the renter or from the calendar, is priced by `app.preview_extension()` with its fee lines, approved by staff and paid before the current return time; unpaid, it lapses. A change of dates or car on a confirmed booking is one flow since 0024: a change request (`booking_change_requests`), asked by the renter or proposed by staff (on the calendar it is `source = 'staff_calendar'`), priced by `app.preview_booking_change()`, approved, agreed by the renter (an Admin may record an agreement by phone when nothing more is owed), and applied with the payment of exactly the difference or a refund for approval. Open field jobs follow the booking. Requests and offers are moved on the calendar directly; insurer-billed bookings keep the calendar's own path.
9. **After the rental.** Tolls, tickets and damage are matched to whoever had the car and charged on a later-charge statement (section 13). A charge line Finance adds by hand after the Check-in statement emails the renter once.

## 12. The notification layer (migrations 0017, 0018, 0023, 0024)

1. A business function or trigger calls `app.emit_event(code, entity, id, payload, dedupe_key)`. The dedupe key is `code:entity_id:discriminator`, so the same action never makes two events. Each code has one emitter (the catalogue's `emitted_by` says which).
2. `app.process_events()` (every minute) reads new events in order, looks up the catalogue, finds the recipients by audience and writes, per recipient, one `notification_outbox` row (or, for a staff notice that is digested, one `staff_digest_items` row per role) and one in-app notice for anyone with an account. The merge payload is built by `app.notification_payload()` from the records, in Toronto time and `$1,234.56`; the sender supplies only signed links and sign-in links. Consent, suppression and preferences decide `skipped` or `suppressed`.
3. The `send-outbox` Edge Function claims queued rows under the daily and monthly caps (customer email first, marketing last and only in its window; Supabase Auth's own emails, sent through the same Resend account, count against the day since 0043), renders the template from `emails/` and sends through Resend. What cannot go today is delayed, never dropped; Resend's own 429 holds a row without spending an attempt; at 80% of the cap and on a final failure the Admins are told in the portal.
4. Reminders, chases, follow-ups, digests, field job lists and the weekly summary are made by the two notification jobs of 0023.

`12_end_to_end.sql` drives the newer flows and checks that each business action produced exactly one outbox row per intended recipient, with no duplicate across the emitters of 0019 to 0023.

## 13. Statements (migrations 0005, 0007, 0020, 0021)

| Statement | Built by | When | Notes |
| --- | --- | --- | --- |
| Renter Check-in statement | `app.issue_booking_statement()` | After the return is reviewed and assessed | Charges, HST, Deposit applied, returned, held back, charged to the card; interest from `statement_interest_days` |
| Renter later-charge statement | The same, through `app.charge_after_rental()` | A toll, ticket or damage charged after the Check-in statement | The issued statement is never rewritten |
| Owner monthly statement | `app.build_owner_statement()` (job `statements-draft`) | 5 days before the payout date | A block per vehicle; Owner Revenue raised later is credited on the next statement; an approved statement can be reissued before its payout is sent |
| CarmaCars monthly statement | `app.build_company_statement()` (job `company-statement`) | The same day | Per vehicle, per owner and in total, with reconciliation checks; a failed check blocks finalizing; CSV exports and a ledger by account |

## 14. The listing pipeline (migration 0022, 0024)

1. An owner, field staff, Fleet or an Admin starts an intake for a car (`app.start_listing_intake()`) and uploads the shot list in order (`app.record_listing_upload()`), then submits it.
2. Jobs go to `listing_jobs`: decode the VIN, draft the copy, process and resize each photo. The `listing-worker` Edge Function claims due jobs (`app.claim_listing_jobs()`, skip locked), calls the provider, and reports success or failure; a failure is retried after the back-off in `listing_job_backoff_minutes` up to `listing_job_max_attempts`. Photo work stops for the day at `photo_daily_budget_microusd`. The `listing-sweep` job puts back any job a worker claimed and did not finish.
3. A failed decode or copy draft never stops the listing (the reviewer types it); a failed photo step puts the intake in `failed` until someone retries.
4. When everything is in, the intake waits for review if the starter's role is in `listing_review_required_roles` (owner and field staff by default); customer service, Fleet or an Admin approves with edits.
5. `app.publish_listing()` refuses, naming the first thing missing (status, rates, specifications, photos, copy, canonical twin), then sets a stable slug, publishes, makes the approved photos public and tells the owner. `app.schedule_listing_publish()` sets a later time instead; the `listings-publish` job publishes it then. `app.unlist_listing()` keeps what the address earned with a 301 or 410.
6. The public site reads only through functions (`car_page`, `fleet`, `model_hub`, `sitemap_rows`, `resolve_path`), which never return a VIN, plate, owner, cost or private field.

## 15. User guides, payments recorded by hand, paper signatures (migration 0044)

1. **Guides.** Each portal's guide is rows in `guides` and `guide_sections` (Markdown drafts, each save kept in `guide_section_versions`). Publishing renders the HTML on the server (`web/src/features/guides/markdown.ts`) and stores it with the section, so the guide page only reads stored HTML (no rendering in the Worker per view). Screenshots are static assets (`web/public/guides/img`, copied from `docs/guides/src/img` at build) or uploads to the public bucket under `guides/<portal>/`. The stored PDF (`guide_pdfs`, private `documents` bucket under `guides/<portal>/`) is printed from the published guide by `web/scripts/guides-pdf.mjs` (workflow `guides-pdf`); the October 2026 PDFs in `docs/guides/pdf` are uploaded where none is stored. `guide_reads` keeps who opened which version and the first-visit banner's dismissal. The guides are seeded from `docs/guides/content/*.json` (written by `docs/guides/src/export.py`).
2. **Payments recorded by hand.** `app.record_manual_payment()` records an e-Transfer, cheque, cash, bank transfer or other payment on an owner invoice (in full or in part) or a renter booking, as a `payments` row plus a `manual_payments` row with the reference, date, proof and note. It goes through 0023's `owner_invoice_apply_payment`, cancels or shrinks the scheduled debit, and sends the owner its own receipt (`owner_payment_recorded`). Admins and Finance (up to their single limit) record; only Admins void (`app.void_manual_payment()`, with a reason; `owner_payment_reversed`).
3. **Paper signatures.** `app.record_paper_signature()` records any signable document signed on paper (owner agreements and schedules, the debit agreement, Forms A to D, registry forms, the rental agreement and its amendments, investment and staff agreements): the scan becomes the person's private document, the signature records are written with method `paper` (witnesses as their own records), and the same effects as signing in the portal follow. `paper_signatures` keeps the scan, signer, date, witnesses, note and what it changed, so a void (`app.void_paper_signature()`) undoes exactly that.
4. **Signing in the portals.** `sign_requests` holds a document a person signs in their own portal: Forms A and B (rendered from the owner's records), investment agreements and staff agreements (a PDF an Admin sent). `app.sign_request_sign()` records the typed or drawn signature; the server files the signed copy. `app.owner_signables()` lists, per owner, everything to sign and pay with its status and how it was done (Admin > Owners > Paid and signed).

## 16. Admin access, the admin portal's shape, sample photos, applications, guides that keep up (migrations 0052 to 0055)

1. **Admin access.** Only the addresses in `site_settings.admin_allowed_emails` (rent@carmacars.ca) and `admin_test_emails` (verify-admin@carmacars.ca, the automated test account) may hold the Admin role; `app.admin_email_allowed()` is checked by triggers on `user_roles` and `users`, so no screen or script can give the role to anyone else. Admin > Settings > Staff and roles shows the list and who holds the role.
2. **The admin portal.** `/admin` is To do (`app.admin_todo`: ten counts in order of urgency, each with one button, then today's pickups and returns); the old dashboard is `/admin/overview`. The navigation (`web/src/features/admin/AdminNav.tsx`, rendered by `GroupNav.tsx`) has seven groups; on a phone it folds behind one Menu button. `/admin/search` (`app.admin_search`) finds bookings, cars, owners, partners and renters. The assistant portal uses the same `GroupNav` with its own groups (`web/src/features/va/VaNav.tsx`).
3. **Sample photos.** A listing with no approved public photo shows a sample (`app.vehicle_sample_photos`: a library photo by make and model, then make and body type, then body type, else the built-in `/sample-photos/<body>.jpg`), marked "Sample photo" on the site. The plate gate is skipped only while a listing has no real photo (`app.sample_photos_ok`). Real photos replace the sample as soon as they are approved.
4. **Owner applications.** `owner_applications.status` (new, waiting on owner, approved, declined) with four checks, the requested items and the owner's reply; `owner_application_notes` keeps the history. Admin > Owners and partners > Applications decides (`app.application_approve`, `application_request`, `application_decline`); the owner answers from a task on their portal's home.
5. **Guides that keep up.** After each successful production deploy the deploy job starts the `guides` workflow with `auto`. It stops within a minute when nothing under `web/src` or `docs/guides/src` changed since the commit of the last finished run (`guide_upkeep_runs`, read through `/api/jobs/guide-upkeep-run`). Otherwise it takes the screenshots on a local stack of the commit, replaces the changed ones (0049), and sends every section whose screenshot changed, or that names a button no screen shows (the label check, `web/scripts/guide-labels.mjs`), to `/api/jobs/guide-rewrite` with facts read from the code (`web/scripts/portal-facts.mjs`). Workers AI rewrites the section; the checks in `web/src/features/guides/upkeep.ts` (every screenshot line kept, every button named exists, no em dash, a sensible length, the text renders) decide whether `app.guide_auto_update` publishes it (the old text kept in `guide_sections.auto_prev` for the one-click revert) or keeps it as a suggestion to review. An Admin's unpublished draft is never overwritten. The PDFs of the guides that changed are printed in the same run.
