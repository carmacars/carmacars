# Setup

How to stand the platform up: the database, the hosting, the payment account, and how they connect. Do it once for **staging** and once for **production**; they share nothing.

## 1. What you need first

| Item | Notes |
| --- | --- |
| Supabase organization | Owner: 18122211 Canada Inc. Both admins as members |
| Vercel team | Pro plan (the every-5-minute scheduled jobs need it) |
| Stripe account | Legal name 18122211 Canada Inc., trading name CarmaCars, category vehicle rental. See `docs/source/payment_esign_setup.md` section 4 |
| E-signature account | With API access (the plan that only sends from the provider's website is not enough for the platform) |
| GPS tracker API | Base URL, key, webhook secret and the command reference |
| Domain | The public site's domain, and a sending domain for email |
| Tools on a developer machine | PostgreSQL 15 or later (`psql`, `initdb`, `pg_ctl`), Git, Node.js 20 or later (for the app, later) |

## 2. Supabase project

1. Create a project per environment: `carmacars-staging` and `carmacars-prod`. Region **Canada (Central)**. Save the database password in the password manager.
2. **Authentication.** Enable email sign-in (magic link or password) and phone sign-in if wanted. Turn off open sign-up for staff: admins, VAs and field staff are invited. Set the site URL and redirect URLs to the Vercel domain. Require two-step sign-in for admin and VA accounts.
3. **API settings.** Expose the `public` schema only. Do not expose `app`.
4. **Apply the migrations**, in order, each in one transaction:

   ```bash
   export DATABASE_URL='postgresql://postgres:<password>@<host>:5432/postgres'
   for f in supabase/migrations/*.sql; do
     echo "$f"; psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -1 -f "$f" || break
   done
   ```

   (The Supabase CLI works too: `supabase link --project-ref <ref>` then `supabase db push`.) Do **not** apply anything under `supabase/tests/`: the shim there stands in for Supabase's own `auth` schema on a plain local database.
5. **Storage.** Create the buckets in `docs/architecture.md` section 6. All private except `vehicle-public`. No public policies: the server issues signed links.
6. **First admins.** Invite the two admins in Authentication, then, in the SQL editor:

   ```sql
   insert into users (id, email, full_name)
   select id, email, coalesce(raw_user_meta_data ->> 'full_name', email) from auth.users where email in ('<admin 1>', '<admin 2>');
   insert into user_roles (user_id, role) select id, 'admin' from users where email in ('<admin 1>', '<admin 2>');
   ```

   Every later user row is created by the app when the person is invited or signs up; `users.id` always equals the auth user's id.
7. **Settings to fill in** (as an admin): company address, phone, incident line, privacy officer and HST number in `program_settings`; Ontario's statutory holidays in `holidays`; each VA's limits in `staff_profiles`.
8. Copy the project URL, the anon key and the service role key for step 3.

## 3. Vercel project

1. Import the Git repository as a Next.js project. Production branch: `main`. Preview deployments for every other branch.
2. Add the environment variables below: production values for Production, staging values for Preview.
3. Add the domain and point DNS at Vercel.
4. Scheduled jobs are declared in `vercel.json` when the app is scaffolded (`docs/architecture.md` section 5). Vercel sends `Authorization: Bearer $CRON_SECRET`; each job route checks it.

## 4. Stripe account

1. Complete business verification. Add both admins and the Finance VA as users with two-step sign-in; the VA's role must not be able to edit payout bank details.
2. Turn on: cards; **pre-authorized debit** (Canadian bank debits) for owner fees; **Identity** for licence-and-selfie checks. Ask Stripe for extended card holds for vehicle rental if the 7-day hold is too short.
3. Create one tax rate: "HST 13%, Ontario, exclusive". Put its id in `STRIPE_HST_TAX_RATE_ID`. The platform sends tax per line; nothing is taxed on deposits, toll and ticket amounts, the deductible, loss of use, interest or owner Late Fees.
4. Customer emails: turn on receipts for successful payments and refunds.
5. Create a webhook endpoint for each environment at `https://<domain>/api/webhooks/stripe` and subscribe it to payment, refund, dispute, mandate and identity verification events. Put its signing secret in `STRIPE_WEBHOOK_SECRET`.
6. Use **test mode** keys in staging and local, **live** keys in production only.

## 5. Connect the other services

| Service | Do |
| --- | --- |
| E-signature | Build the templates in `docs/source/payment_esign_setup.md` section 5. Point the provider's callback at `/api/webhooks/esign`. Set `ESIGN_*` |
| GPS tracker | Point its event callback at `/api/webhooks/tracker`. Set `TRACKER_*`. Test lock, alarm and shut-off on a parked car in staging first |
| Email and SMS | Verify the sending domain (SPF, DKIM). Set `EMAIL_*`, `SMS_*` |
| Photo pipeline | Set `PHOTO_PIPELINE_*` |

## 6. Environment variables

Listed with comments in `.env.example`. Variables starting `NEXT_PUBLIC_` reach the browser; nothing else does.

| Variable | Used by | Secret |
| --- | --- | --- |
| `NEXT_PUBLIC_APP_URL`, `APP_ENV` | App | No |
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Browser and server; row-level security applies | No |
| `SUPABASE_SERVICE_ROLE_KEY` | Server only: webhooks, jobs, money actions. Bypasses row-level security | **Yes** |
| `DATABASE_URL` | Migrations only; not set on Vercel | **Yes** |
| `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` | Checkout in the browser | No |
| `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_HST_TAX_RATE_ID` | Payments module | **Yes** |
| `ESIGN_PROVIDER`, `ESIGN_API_KEY`, `ESIGN_WEBHOOK_SECRET` | E-signature module | **Yes** |
| `TRACKER_API_URL`, `TRACKER_API_KEY`, `TRACKER_WEBHOOK_SECRET` | Tracker module | **Yes** |
| `EMAIL_PROVIDER_API_KEY`, `EMAIL_FROM`, `SMS_PROVIDER_API_KEY`, `SMS_FROM` | Messaging module | **Yes** |
| `PHOTO_PIPELINE_URL`, `PHOTO_PIPELINE_KEY` | Photo module | **Yes** |
| `CRON_SECRET` | Scheduled job routes | **Yes** |
| `FIELD_ENCRYPTION_KEY` | Encrypts bank account numbers before they are stored | **Yes** |

## 7. Run the tests

One command, from the repository root:

```bash
scripts/test.sh
```

It starts a throwaway PostgreSQL server, creates a fresh database, loads the local shim, applies every migration, runs the four test files and prints a summary; the exit code is 0 only if every assertion passed. It needs `psql`, `initdb` and `pg_ctl` (PostgreSQL 15 or later) and nothing else.

- To use a server you already run: `CARMACARS_TEST_PGURL=postgres://user:pass@host:5432/postgres scripts/test.sh` (it creates and drops the database `carmacars_test`).
- To choose where the throwaway server lives: `CARMACARS_TEST_TMP=/some/dir`. Port: `CARMACARS_TEST_PORT` (default 54329).

| File | Proves |
| --- | --- |
| `supabase/tests/01_rules.sql` | Every worked example in the two billing specifications, to the cent: rates, cancellation tiers, the split, fees, damage, claims; the Toronto date rules; the investment agreement's Schedule B |
| `supabase/tests/02_owner_month.sql` | The owner specification's worked month through the real tables, to the $1,922.25 payout; the VA hiring package's month ($1,364.05); kickback rules; the four owner cases; prepaid months and pro-rating; arrears |
| `supabase/tests/03_flows.sql` | Status flows and guards: booking lifecycle, 30-day maximum, renewals, deposits, onboarding, invoices, claims, tracker, tolls, investors, fleet minimum, audit log |
| `supabase/tests/04_rls.sql` | Each role signed in as the app signs it in, and what it cannot read or change |

Run the tests before every migration is applied to staging. A new migration that adds a table without row-level security or an audit trigger fails the run.
