# Setup

How to stand the platform up: the accounts, the database, the hosting, the payment account, and how they connect. Do it once for **staging** and once for **production**; they share accounts but no keys, no data and no buckets. The reasons for each choice are in `docs/decisions/0001-zero-fixed-fee-stack.md`.

**One rule before anything else: no secret is ever pasted into a chat.** That includes a chat with an assistant, an email, a ticket and a shared document. Keys, passwords and signing secrets go from the provider's dashboard straight into GitHub repository secrets (section 6) or the company password manager, and nowhere else.

## 1. What you need first

Open the accounts in this order. Each is in the name of 18122211 Canada Inc., with both admins as members and two-step sign-in on.

| # | Account | Plan | Used for |
| --- | --- | --- | --- |
| 1 | Stripe | Pay per transaction | Cards, deposit holds, pre-authorized debit. Legal name 18122211 Canada Inc., trading name CarmaCars, category vehicle rental. See `docs/source/payment_esign_setup.md` section 4 |
| 2 | GitHub | Free | The code, the tests, the deploys, the nightly backup job, and the secrets |
| 3 | Supabase (Canada Central) | Free | Database, sign-in, `pg_cron`, Edge Functions |
| 4 | Cloudflare | Free | Workers (the app), R2 (files and backups), DNS for `carmacars.ca`, Turnstile (form protection) |
| 5 | Resend | Free (3,000 emails a month, 100 a day) | Platform email, sent from `carmacars.ca` |
| 6 | Google Workspace | Paid, by choice | The staff mailbox `info@carmacars.ca`, with aliases such as `bookings@` and `owners@` |

Also needed:

| Item | Notes |
| --- | --- |
| GPS tracker API | Base URL, key, webhook secret and the command reference |
| Domain | `carmacars.ca`, with its DNS moved to Cloudflare |
| Tools on a developer machine | PostgreSQL 15 or later (`psql`, `initdb`, `pg_ctl`), Git, Node.js 20 or later (for the app, later) |

No e-signature account and no SMS account is needed: signing is built into the platform and messaging is email only at launch.

## 2. Supabase project

1. Create a project per environment: `carmacars-staging` and `carmacars-prod`. Region **Canada (Central)**. Save the database password in the password manager.
2. **Authentication.** Enable email sign-in (magic link or password). Turn off open sign-up for staff: admins, VAs and field staff are invited. Set the site URL and redirect URLs to the app's domain. Require two-step sign-in for admin and VA accounts.
3. **API settings.** Expose the `public` schema only. Do not expose `app`.
4. **Extensions.** Turn on `pg_cron` and `pg_net` (Database, Extensions). Migration 0015 creates `pg_cron` itself if it is available; `pg_net` is used later, by the jobs that call an Edge Function.
5. **Apply the migrations**, in order, each in one transaction:

   ```bash
   export DATABASE_URL='postgresql://postgres:<password>@<host>:5432/postgres'
   for f in supabase/migrations/*.sql; do
     echo "$f"; psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -1 -f "$f" || break
   done
   ```

   (The Supabase CLI works too: `supabase link --project-ref <ref>` then `supabase db push`.) Do **not** apply anything under `supabase/tests/`: the shim there stands in for Supabase's own `auth` schema on a plain local database. Once the deploy workflow exists, GitHub Actions applies migrations and this step is not done by hand.
6. **Check the schedule.** In the SQL editor:

   ```sql
   select jobname, schedule, command from cron.job where jobname like 'carmacars-%' order by jobname;
   ```

   Five rows are expected (`docs/architecture.md` section 5). If there are none, `pg_cron` was not available when migration 0015 ran: turn it on, then run the `do $$ ... $$` block at the end of `supabase/migrations/0015_scheduled_jobs.sql` again. Each run is recorded in `job_runs`.
7. **First admins.** Invite the two admins in Authentication, then, in the SQL editor:

   ```sql
   insert into users (id, email, full_name)
   select id, email, coalesce(raw_user_meta_data ->> 'full_name', email) from auth.users where email in ('<admin 1>', '<admin 2>');
   insert into user_roles (user_id, role) select id, 'admin' from users where email in ('<admin 1>', '<admin 2>');
   ```

   Every later user row is created by the app when the person is invited or signs up; `users.id` always equals the auth user's id.
8. **Settings to fill in** (as an admin): company address, phone, incident line, privacy officer and HST number in `program_settings`; Ontario's statutory holidays in `holidays` (the fleet report job uses them); each VA's limits in `staff_profiles`.
9. **Edge Functions.** `supabase/functions/stripe-webhook` and `supabase/functions/tracker-webhook`, and one function per job that calls an outside service, are built with the app and deployed by GitHub Actions. Their secrets are set by the deploy job from GitHub repository secrets.

Files are not kept in Supabase Storage. They are in Cloudflare R2 (section 3).

## 3. Cloudflare

1. **DNS.** Add `carmacars.ca` to Cloudflare and move the nameservers. Keep the Google Workspace mail records on the root domain exactly as Google gives them.
2. **Workers.** The app is one Worker per environment: `carmacars-staging` and `carmacars-prod`. It is the Next.js app built with the OpenNext adapter. GitHub Actions deploys it: the `staging` branch to staging, `main` to production. Attach the public domain to `carmacars-prod` and a subdomain (for example `staging.carmacars.ca`) to `carmacars-staging`.
3. **R2 buckets.** Create the buckets in `docs/architecture.md` section 6 once per environment, with the environment prefix (for example `carmacars-prod-identity`), plus `carmacars-prod-backups`. All private except `vehicle-public`, which is served from a custom domain. Create one R2 API token per environment with read and write access to that environment's buckets only.
4. **Turnstile.** Create one widget per environment for the app's domain. The site key is public; the secret key is a secret.
5. **Deploy token.** Create one Cloudflare API token that can edit Workers and nothing else. It goes into GitHub as `CLOUDFLARE_API_TOKEN`.

The free plan allows 10 ms of processing per request and 100,000 requests a day. If requests start to fail on the limit under real traffic, move to Workers Paid (US$5 a month).

## 4. Stripe account

1. Complete business verification. Add both admins and the Finance VA as users with two-step sign-in; the VA's role must not be able to edit payout bank details.
2. Turn on: cards; **pre-authorized debit** (Canadian bank debits) for owner fees. Do not turn on Stripe Billing or Stripe Invoicing: the platform builds its own invoices and charges saved payment methods on its own schedule. Leave **Identity** off: identity checks are done by staff review. It can be turned on later (CA$2.00 per check) with `IDENTITY_PROVIDER=stripe`.
3. Ask Stripe for extended card holds for vehicle rental. Until Stripe approves them, the platform renews a card hold before it lapses (about every 7 days).
4. Create one tax rate: "HST 13%, Ontario, exclusive". Put its id in `STRIPE_HST_TAX_RATE_ID`. The platform sends tax per line; nothing is taxed on deposits, toll and ticket amounts, the deductible, loss of use, interest or owner Late Fees.
5. Customer emails: turn on receipts for successful payments and refunds.
6. Create a webhook endpoint for each environment at `https://<project-ref>.supabase.co/functions/v1/stripe-webhook` and subscribe it to payment, refund, dispute and mandate events. Its signing secret is `STRIPE_WEBHOOK_SECRET`.
7. Use **test mode** keys in staging and local, **live** keys in production only.

## 5. Connect the other services

| Service | Do |
| --- | --- |
| Resend | Add the sending domain `carmacars.ca` and put the DNS records Resend shows (SPF, DKIM) on that subdomain in Cloudflare. Nothing changes on the root domain, so Google Workspace mail is not affected. Set `RESEND_API_KEY`, `EMAIL_FROM` (an address at `carmacars.ca`) and `EMAIL_REPLY_TO` (for example `bookings@carmacars.ca`) |
| Google Workspace | Create the mailbox `info@carmacars.ca` and its aliases (`bookings@`, `owners@`). Staff read replies there. The platform does not sign in to this mailbox |
| GPS tracker | Point its event callback at `https://<project-ref>.supabase.co/functions/v1/tracker-webhook`. Set `TRACKER_*`. Test lock, alarm and shut-off on a parked car in staging first |
| Photo pipeline | Set `PHOTO_PIPELINE_*` |
| Signing | Nothing to connect. Load the agreement templates in the admin portal when the app is built. Forms C and D and the Shareholder Agreement are signed on paper with their witnesses, scanned and uploaded |

## 6. Environment variables and secrets

Listed with comments in `.env.example`. Variables starting `NEXT_PUBLIC_` reach the browser; nothing else does.

| Variable | Used by | Secret |
| --- | --- | --- |
| `NEXT_PUBLIC_APP_URL`, `APP_ENV` | App | No |
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Browser and server; row-level security applies | No |
| `SUPABASE_SERVICE_ROLE_KEY` | Server only: webhooks, jobs, money actions. Bypasses row-level security | **Yes** |
| `SUPABASE_JWT_SECRET` | Server only: Admin "view as" reads a renter's or owner's portal with a 5-minute token for that person. The deploy reads it from the project | **Yes** |
| `DATABASE_URL` | Migrations and the nightly backup only; never given to the app | **Yes** |
| `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` | Checkout in the browser | No |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_HST_TAX_RATE_ID` | Payments module; the `stripe-webhook` function | **Yes** |
| `IDENTITY_PROVIDER` | Identity module: `staff_review` (default) or `stripe` | No |
| `R2_ACCOUNT_ID`, `R2_BUCKET_PREFIX`, `NEXT_PUBLIC_VEHICLE_PHOTOS_URL` | Storage module | No |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | Storage module: uploads and signed links; the backup job | **Yes** |
| `RESEND_API_KEY` | Messaging module | **Yes** |
| `EMAIL_FROM`, `EMAIL_REPLY_TO` | Messaging module | No |
| `NEXT_PUBLIC_TURNSTILE_SITE_KEY` | Public forms in the browser | No |
| `TURNSTILE_SECRET_KEY` | Server check of public forms | **Yes** |
| `TRACKER_API_URL` | Tracker module | No |
| `TRACKER_API_KEY`, `TRACKER_WEBHOOK_SECRET` | Tracker module; the `tracker-webhook` function | **Yes** |
| `PHOTO_PIPELINE_URL`, `PHOTO_PIPELINE_KEY` | Photo module | **Yes** |
| `FIELD_ENCRYPTION_KEY` | Encrypts bank account numbers before they are stored | **Yes** |

### GitHub repository secrets

Create two GitHub environments, `staging` and `production`, and add these secrets to each with that environment's values. These are the exact names the workflows read.

| Secret | Where the value comes from | Used by |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | Cloudflare, section 3 step 5 | Deploying the Worker |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard | Deploying the Worker |
| `SUPABASE_ACCESS_TOKEN` | Supabase account, Access Tokens | Deploying Edge Functions |
| `SUPABASE_PROJECT_REF` | Supabase project settings | Deploying Edge Functions |
| `DATABASE_URL` | Supabase project settings, Database | Migrations; nightly `pg_dump` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase project settings, API | The Worker (server side) |
| `SUPABASE_JWT_SECRET` | Management API `/v1/projects/{ref}/postgrest` (`jwt_secret`), read by the deploy | The Worker (server side) |
| `STRIPE_SECRET_KEY` | Stripe, Developers, API keys | The Worker; Edge Functions |
| `STRIPE_WEBHOOK_SECRET` | Stripe, the webhook endpoint | The `stripe-webhook` function |
| `R2_ACCESS_KEY_ID` | Cloudflare R2 API token, section 3 step 3 | The Worker; the backup job |
| `R2_SECRET_ACCESS_KEY` | The same token | The Worker; the backup job |
| `RESEND_API_KEY` | Resend, API Keys | The Worker; Edge Functions |
| `TURNSTILE_SECRET_KEY` | Cloudflare Turnstile widget | The Worker |
| `TRACKER_API_KEY` | The tracker provider | The Worker; Edge Functions |
| `TRACKER_WEBHOOK_SECRET` | The tracker provider | The `tracker-webhook` function |
| `PHOTO_PIPELINE_KEY` | The photo pipeline | The Worker |
| `FIELD_ENCRYPTION_KEY` | Generated once per environment (32 random bytes); also in the password manager | The Worker |
| `BACKUP_ENCRYPTION_KEY` | Generated once (production only); also in the password manager | The backup job |

Values that are not secret (`NEXT_PUBLIC_*`, `APP_ENV`, `STRIPE_HST_TAX_RATE_ID`, `IDENTITY_PROVIDER`, `R2_ACCOUNT_ID`, `R2_BUCKET_PREFIX`, `EMAIL_FROM`, `EMAIL_REPLY_TO`, `TRACKER_API_URL`, `PHOTO_PIPELINE_URL`) go into GitHub environment **variables**, not secrets.

Rules for secrets:

- No secret is ever pasted into a chat, an email, a ticket or a document. If one is, treat it as leaked: revoke it at the provider and create a new one.
- The person who creates a key pastes it into GitHub (Settings, Secrets and variables, Actions) themselves. GitHub never shows it again.
- The deploy job copies secrets to Cloudflare (Worker secrets) and Supabase (Edge Function secrets). Nobody sets them by hand in those dashboards.
- `.env.local` on a developer machine holds test-mode and staging values only. Live keys never leave GitHub and the provider.
- `FIELD_ENCRYPTION_KEY` and `BACKUP_ENCRYPTION_KEY` are also kept in the company password manager, because losing them loses the data they protect.

## 7. Run the tests

One command, from the repository root:

```bash
scripts/test.sh
```

It starts a throwaway PostgreSQL server, creates a fresh database, loads the local shim, applies every migration, runs the five test files and prints a summary; the exit code is 0 only if every assertion passed, and the last line is then `ALL TESTS PASSED`. It needs `psql`, `initdb` and `pg_ctl` (PostgreSQL 15 or later) and nothing else. `pg_cron` is not needed: migration 0015 schedules nothing when it is absent, and the job functions are tested by passing them the time.

- To use a server you already run: `CARMACARS_TEST_PGURL=postgres://user:pass@host:5432/postgres scripts/test.sh` (it creates and drops the database `carmacars_test`).
- To choose where the throwaway server lives: `CARMACARS_TEST_TMP=/some/dir`. Port: `CARMACARS_TEST_PORT` (default 54329).

| File | Proves |
| --- | --- |
| `supabase/tests/01_rules.sql` | Every worked example in the two billing specifications, to the cent: rates, cancellation tiers, the split, fees, damage, claims; the Toronto date rules; the investment agreement's Schedule B |
| `supabase/tests/02_owner_month.sql` | The owner specification's worked month through the real tables, to the $1,922.25 payout; the VA hiring package's month ($1,364.05); kickback rules; the four owner cases; prepaid months and pro-rating; arrears |
| `supabase/tests/03_flows.sql` | Status flows and guards: booking lifecycle, 30-day maximum, renewals, deposits, onboarding, invoices, claims, tracker, tolls, investors, fleet minimum, audit log |
| `supabase/tests/04_rls.sql` | Each role signed in as the app signs it in, and what it cannot read or change |
| `supabase/tests/05_jobs.sql` | The scheduled job functions: each runs only on its Toronto day and hour, once per run key, and records what it did; a failed run is recorded and can be retried |

Run the tests before every migration is applied to staging. A new migration that adds a table without row-level security or an audit trigger fails the run.

A second check covers the wording of the documents and the SQL comments:

```bash
scripts/check-text.sh
```

It fails, listing file and line, if a tracked file under `src/`, `docs/` (except `docs/source/`), `supabase/` or `README.md` contains an em dash, or an en dash used as a sentence dash.

## 8. Backups and restore

1. A GitHub Actions job runs every night: `pg_dump` of production (with `DATABASE_URL`), encrypted on the runner with `BACKUP_ENCRYPTION_KEY`, uploaded to the R2 bucket `carmacars-prod-backups`. Use a `pg_dump` of the same major version as the Supabase database.
2. Keep 30 nightly files and the first file of each month.
3. **Before go-live, test a restore:** download last night's file, decrypt it, load it into a fresh local database, and run a few counts against production. Write the date of the test in the pull request. Repeat after any change to the backup job.
4. The job is added with the app's workflows; it is not in this repository yet.
