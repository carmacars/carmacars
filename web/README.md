# CarmaCars web app

The public site, request to book and sign-in for carmacars.ca: Next.js (App Router, TypeScript strict) built with
OpenNext and run as a Cloudflare Worker, on the Supabase database in `../supabase` (decision record
`../docs/decisions/0001-zero-fixed-fee-stack.md`). The database holds the rules; this app calls its public functions
and never re-computes money.

## Run it locally

```bash
cd web
npm install                       # through the session proxy here: /home/claude/bin/npm-net npm install
cp .env.example .env.local        # the defaults work for the local stack
npm run db:up                     # PostgreSQL on 127.0.0.1:54322: shim, all migrations, local auth, seed
npm run dev                       # http://localhost:3000 (next dev)
```

For a production-like server (the one the tests use): `npm run build && npm start`. `scripts/serve.mjs` runs
`next start` behind a small proxy that adds the same security headers, nonce and content security policy as the
Worker entry (`custom-worker.ts`).

`npm run db:reset` rebuilds the database from the migrations and seeds it again. `npm run db:down` stops it.

## The local stack, and why

Supabase local (`supabase start`) needs Docker images. In this environment the Docker daemon starts but every
registry (Docker Hub, `public.ecr.aws`) is refused by the network policy, and the Supabase CLI binary (a GitHub
release) cannot be downloaded. So the local stack is a faithful substitute:

| Piece | Supabase | Local substitute |
| --- | --- | --- |
| Database | Postgres with the migrations | PostgreSQL 16 with `../supabase/tests/shim/00_supabase_shim.sql` (the `auth` schema, `auth.uid()`, the three API roles) and every migration, exactly as `../scripts/test.sh` builds it (`scripts/local-db.sh`) |
| API (PostgREST) | `supabase.rpc()` as anon, authenticated or service_role | `src/lib/db/local.ts`: the `postgres` driver; every call is one transaction that first runs `set_config('role', ...)` and `set_config('request.jwt.claims', ...)` the way PostgREST does, so grants, row-level security and `auth.uid()` behave as on Supabase. Only functions in `public` are callable, with named arguments, like PostgREST |
| Browser reads (calendar, quote, search, cookie choice) | straight to the Supabase API with the anon key | `POST /api/rpc/[fn]` (local only; returns 404 on Supabase), limited to the functions the anonymous role may execute |
| Auth (GoTrue) | Supabase Auth: email and password, reset by email | `src/lib/auth/local.ts` with `local/local_auth.sql`: scrypt password hashes, an HS256 session cookie with Supabase's claims, reset links written to `local_auth.mailbox` (the tests read the link from there) |
| Files | Cloudflare R2 | `public/_local/vehicle-public`, filled by the seed from `../prototype/assets/photos` |

`DATA_BACKEND=local|supabase` switches all of it; the app code is the same (`src/lib/db/repo.ts`, `src/lib/auth`).
Generated types: `npm run db:types` reads the local catalog and writes `src/lib/db/types.ts` in the shape of
`supabase gen types typescript`. With a Supabase project, `supabase gen types typescript --project-id <ref>` gives the
same file.

## Seed

`node scripts/seed.mjs` (run by `db:up` and `db:reset`):

- **Content, every environment** (`--content-only` to run just this part against staging or production):
  `site_content_blocks` rows for the editable copy: FAQ lists, the steps, requirements and coverage options, the cookie
  banner wording and version, the owner's line, scene photos, and the legal pages from
  `../docs/source/website_terms_policies.md` (final text; the numbered company name is replaced by CarmaCars and every
  blank becomes a token filled from settings, so no blank reaches a page).
- **Sample fleet, local and staging only**: the 20 cars of `../prototype/tools/src/data.mjs` with owner, schedules,
  rate cards, classes, per-car young driver fees, listings, approved photos and the sample confirmed bookings that
  fill their calendars (dated from launch, moved forward when the seed runs later).

Site settings (brand, tagline, contact, logo slot, social links) are already in the database from migrations 0022
and 0025.

## What reads what

Every value an admin can change comes from the database: `site_settings_public()` (brand, logo slot, contact,
hours, social), `site_facts()` (policy numbers, fee catalogue, cancellation tiers; migration 0027),
`site_content()` (copy blocks), `fleet()`, `car_page()`, `model_hubs()`, `model_hub()`, `featured` order,
`public_vehicle_calendar()`, `quote_booking()`, `search_available()`, `handover_places()`, `sitemap_rows()`,
`record_cookie_choice()`. Copy in the templates carries `{{tokens}}` (`src/lib/site.ts`); an unknown token fails the
build. Server calls: `submit_booking_request()`, `submit_lead()`, `save_form_draft()`, `load_form_draft()`,
`submit_form_draft()`, `register_account()`, `delivery_origin()`.

## Renter portal (`/account`)

Phone-first, same design system (`src/styles/portal.css`). Every page reads as the signed-in user through
the invoker functions of migration 0028 (row-level security decides); every action is a server action
(`src/server/actions/portal.ts`) that re-checks the booking is the renter's and calls a service-role wrapper
that checks `p_by` again in the database.

| Route | Does |
| --- | --- |
| `/account` | Next step for the nearest booking, then current, upcoming and past trips |
| `/account/bookings/[number]` | Status, progress, trip and pickup details, questions from staff (`reply_booking_info`), drivers and their signing links, changes, documents, price and payments, actions |
| `.../offer` | Current version, changes as before and after, price, countdown, "an offer does not hold the car"; approve (`renter_approve_offer` with the version; a stale one is refused), ask for a change, decline |
| `.../sign` | Part A details (`renter_save_details`), the agreement (`src/features/agreement`, text from `../docs/source/v2_rental.md` via `npm run gen:agreement`) on screen and as PDF, four consents, drawn (canvas, touch) or typed signature (`renter_sign_agreement`, IP and browser from the server) |
| `.../pay` | Payment Element (Stripe) or the fake card form; authorize, `server_record_booking_payment`, capture on confirmation or void on refusal; the signed copy is rendered and attached |
| `.../verify` | Licence front, back, selfie per driver and coverage proof: browser re-encodes, presigned PUT, server checks magic bytes and size, `renter_register_upload` |
| `.../cancel`, `.../extend`, `.../change` | Previews from the database, then cancel (type to confirm), request and pay an extension, ask for a date change |
| `/account/documents`, `/account/documents/[id]` | Every readable document; a link is signed only after `my_document` passes row-level security (60 s for ID images, 5 min otherwise) |
| `/account/notifications`, `/account/profile` | Notification centre and preferences, marketing consent; contact details, drivers, Card on File |
| `/account/bookings/[number]/review` | A closed booking's review (stars, title, text, consent to publish; `renter_submit_review` of 0034), linked from the booking and from the review request email |
| `/unsubscribe`, `POST /api/unsubscribe` | The marketing emails' unsubscribe link (opening it changes nothing; the button does) and the RFC 8058 one-click request mail apps send (`List-Unsubscribe-Post`); `/email/unsubscribe` redirects here |
| `/sign/driver/[token]` | An additional driver accepts without an account |
| `POST /api/webhooks/stripe` | Signature checked on the raw body, `webhook_event_claim` / `webhook_event_finish`, settles authorized booking payments (the PaymentIntent is fetched again from Stripe) |
| `/api/storage/...` | Local only: what a presigned R2 link does for the local storage adapter (`.local-storage/`) |

Stripe needs `STRIPE_SECRET_KEY`, `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` and `STRIPE_WEBHOOK_SECRET` (events:
`payment_intent.amount_capturable_updated`, `payment_intent.succeeded`, `payment_intent.payment_failed`);
R2 buckets need a CORS rule allowing `PUT` from the site for uploads. `npm run test:unit` runs the Stripe
adapter's tests against a mocked fetch.

## Owner application, owner portal (`/owner`) and admin (`/admin`)

Same frame and design system as the renter portal (`src/styles/portal.css`, `src/styles/owner.css`). Owner reads go
through migration 0029's portal functions with the signed-in user's id (`app.portal_owner_id` refuses anyone who is
not an active owner); every write is a server action (`src/server/actions/owner.ts`, `apply.ts`, `admin.ts`) that the
database checks again (`p_by`, `p_admin`).

| Route | Does |
| --- | --- |
| `/list-your-car/apply` | The owner application (04-owner.md section 3): about you (individual or corporation, address lookup, licence and date of birth for the registry forms), one or many vehicles (VIN looked up once through `src/integrations/vin.ts`, NHTSA vPIC or the fake), how each will work (management mode, the onboarding methods open to it and the registry estimate the owner pays directly, lender permission and the Form C warning), review, account and submit (`submit_owner_application`). Autosaves to `form_drafts` (account, or a device cookie); "Email me a link" sends a one-time resume link (`/list-your-car/apply/resume`). An invitation link (`?invite=`) fills name and email |
| `/owner` | Next step (sign, pay), vehicles with their next action, money tiles and recent invoices |
| `/owner/vehicles`, `/owner/vehicles/[id]` | Status, fees, the onboarding checklist, uploads (ownership permit, lender permission, insurance), bookings, invoices, exit notice |
| `/owner/bookings` | Two months of the owner's cars, every booking (renter details only on Self-Managed rentals and Owner Bookings), "Book my own car" |
| `/owner/sign` | The Enrollment Agreement with Schedules A and B, the Title-Holding and Lease Agreement with Schedule 1, or an Additional Vehicle Schedule (`src/features/owner-agreement`, text from `../docs/source/v2_enrollment.md` and `v2_title_holding.md` via `npm run gen:owner-agreements`), signed once with three initialled confirmations; signed copies stored |
| `/owner/invoices`, `/owner/invoices/[number]` | Invoices; the pay page for the upfront and the monthly invoices: card, or Canadian pre-authorized debit (Stripe `acss_debit` with its mandate, saved for the 15th) |
| `/owner/statements`, `/owner/statements/[id]`, `/owner/payouts` | Approved statements with every line and the booking behind it; payouts |
| `/owner/documents` (+ `/[id]`, `/forms/[id]`) | Signed agreements and uploads (5-minute signed links); government form data sheets as PDF |
| `/owner/banking`, `/owner/profile`, `/owner/notifications` | Payout details (account number encrypted with `PAYOUT_ENCRYPTION_KEY`, verified by an Admin), payment methods, contact details, messages |
| `/admin/owners`, `/admin/owners/[id]`, `/admin/invoices` | Admin only, and two-step sign-in when `require_staff_two_step` is on: applications, terms per vehicle (standard grid by default), issue upfront invoices, record an offline payment (e-Transfer, cheque or bank transfer with its reference, audited), invitation or sign-in links |
| `POST /api/dev/fake-payments` | Local and tests only (fake payments, never production): settles a fake pre-authorized debit, as the bank does days later |

### The admin portal (`/admin`)

Desktop-first, usable on a phone (`src/styles/admin.css`, same tokens). Every page calls `requireAdmin` (Admin role, and
two-step sign-in when `require_staff_two_step` is on); every read and action goes through migration 0030's door:
`admin_list` (allow-listed tables and views), `admin_read` (screens), `admin_save` (settings) and `admin_do` (actions),
from `src/server/admin/api.ts` and `src/server/actions/admin-portal.ts` (`adminAct`, `adminSaveRow`, `adminPreview`).
Shared pieces in `src/features/admin/`: `ui.tsx` (tables, tabs, tiles), `Act.tsx` (one button or form per action, typed
fields), `BookingReview.tsx`, `MasterCalendar.tsx`, `ListingReview.tsx`, `TollImport.tsx`, `BulkRates.tsx`. Keyboard: `g`
then `t r b c v l m o k s` jumps to a section, `/` focuses search; on the calendar the arrows move a booking 30 minutes,
Shift resizes, Enter confirms, Esc cancels, `t` is today.

| Route | Does |
| --- | --- |
| `/admin` | Today: alerts (site setup problems, failed jobs), requests against the response target, offers out, pickups and returns, late now, tasks by queue, payments failed, deposits due, utilization and cash this month, approvals |
| `/admin/requests`, `/admin/bookings`, `/admin/bookings/[number]` | Request queue with flags and age; every booking; one booking: review and adjust with live re-pricing (applied and rolled back in the database) and the offer as the renter sees it, send, withdraw, resend, approve by phone, ask, decline, reopen, calendar switch, cancel, swap; money, change requests and extensions, history (events, status history, emails), drivers and documents |
| `/admin/calendar` | Master calendar (week, 2 weeks, month, agenda), filters and search, side panel, drag or resize with the database's preview and confirm, blocks; per vehicle at `/admin/vehicles/[id]?tab=calendar` |
| `/admin/vehicles`, `/admin/vehicles/[id]`, `/admin/vehicles/bulk-rates`, `/admin/listings`, `/admin/listings/[id]` | Fleet; rates and rate history, fees and overrides, deposit, classes, coverage, listing, owner terms, tracker, documents; bulk rates with preview; listing review (copy, photos, cover), publish, unlist |
| `/admin/settings/[section]` | Site settings and logo, content blocks, program settings (a new dated row), fee defaults, deposit tiers, km choices, classes, airports and delivery, coverage prices, email aliases and reply-to, staff (invite, limits, end access), insurers, promo codes, quick replies |
| `/admin/money`, `/admin/insurer-invoices`, `/admin/invoices`, `/admin/statements`, `/admin/payouts`, `/admin/reports`, `/admin/expenses`, `/admin/reconciliation` | Payments, refunds with approval, deposits, disputes; insurer invoices; owner invoices and the monthly run; owner statements per vehicle (build, approve, issue, reissue); payouts; company statements with the ties and CSV (`/admin/reports/export`); expenses; processor payout reconciliation |
| `/admin/tolls` (`/new`, `/import`, `/[id]`), `/admin/damages` (`/[id]`), `/admin/incidents` | Work queues by bucket and age, single entry, statement import with saved column mappings and the statement PDF attached, match review, charge, bill to owner, dispute; damage intake with before and after photos and the deductible routing; incidents and claims |
| `/admin/tasks`, `/admin/owners`, `/admin/investors`, `/admin/reviews`, `/admin/messages`, `/admin/audit` | Every queue; owner records; investors and returns; review moderation and review-request decisions; outbox and suppressions; audit log |

### Assistants (`/va`), field staff (`/field`), investors (`/investor`), two-step sign-in

Migration 0031's door (`public.door`, `src/server/door.ts`): every staff and investor read and action carries the signed-in
user and their session's assurance level; the database refuses a staff session without the second factor while
`require_staff_two_step` is on. The admin portal goes through the same door. Change record: `../docs/changes/0031_staff_investor_portals.md`.

| Route | Does |
| --- | --- |
| `/va`, `/va/today`, `/va/tasks/[id]` | The function's queue (Mine, Unassigned, Waiting; overdue, due today, escalated, type), today's digest, the task sheet (take, done, waiting, escalate, hand over, notes); each task opens its working screen |
| `/va/requests`, `/va/bookings/[number]` | Customer service and Sales: the request inbox and the admin review-and-offer screen without price overrides (offers open 48 hours at most); changes and extensions; messages with quick replies; Finance: money and refund requests (above the Single Limit an Admin approval); Fleet: schedule a field job |
| `/va/verify/[number]` | Identity and coverage review, only from an open review task; one-minute signed image links |
| `/va/money`, `/va/tolls` | Finance: failed payments, deposits to take and due back, refunds to request, failed owner invoices, statements to prepare; toll and ticket matching and import |
| `/va/fleet`, `/va/calendar`, `/va/listings`, `/va/vehicles/[id]` | Fleet: handovers and returns without a job, scheduling and assignment, expiry watch, vehicle documents; the master calendar; listing intake and review |
| `/va/leads`, `/va/messages` | Owner leads and applications (Sales, customer service); renter messages |
| `/field`, `/field/jobs/[id]` | Phone first: today and tomorrow, acknowledge, start, the handover and return checklists (ready check with the Deposit status, odometer, fuel, keys, the required photo set from the camera through an IndexedDB upload queue that retries when the connection returns, damage on a car diagram with close-ups, renter and staff signatures on screen), vehicle moves, damage found later. `POST /api/field/upload` checks the job and the bytes, stores the photo and registers it |
| `/investor`, `/investor/statements`, `/investor/statements/[id]`, `/investor/profile` | A signed-in investor's own investments, statements and notices; election, bank and transfer requests become Admin tasks |
| `/two-step/setup`, `/two-step` | Enrol an authenticator app (Supabase Auth TOTP; locally RFC 6238 in `local_auth.factors`) and the second step at sign-in |

After the password, sign-in goes to the page asked for (`?next=`, a path on this site only), or to the person's portal:
Admin `/admin`, assistant `/va`, field `/field`, investor `/investor`, owner `/owner`, renter `/account`; a person with two
or more portals gets `/choose-portal` (renting counts only when there is nothing else), and every portal's frame links
to the others. A person with an authenticator app is asked for the code first, and staff without one are sent to enrol
while the switch is on. A refusal page (`/admin/no-access`, `/va/no-access`, `/field/no-access`, `/investor/no-access`,
`/owner/not-an-owner`) names the account signed in and offers its own portals and Sign out.

### Sessions on the Worker, links and invitations (`docs/changes/2026-10-14-sign-in.md`)

| Piece | Where |
| --- | --- |
| Session refresh | `custom-worker.ts` refreshes a Supabase session whose access token is within two minutes of expiry before the app runs (`src/lib/auth/edge-refresh.ts`, the cookie format in `session-cookie.ts`), so the new tokens are stored. A page cannot store them, and Supabase ends a session whose spent refresh token comes back |
| Who is signed in | `src/lib/auth/supabase.ts` reads the session cookie and verifies the access token with the project's published key (`jwt-verify.ts`, ES256 through WebCrypto): no Supabase client and no round trip per page. An older or unverifiable token falls back to Supabase Auth |
| Email links | Every Supabase Auth email links to `/auth/callback?token_hash=...` (`scripts/deploy/auth-templates.mjs`). A link that has expired (one hour, the project's only setting for email links) or was used goes to `/link-expired`, which sends a new one in one step (the address asked with on this device is filled in). Saving on `/update-password` (a static page) without the link's session offers the same |
| Sign-in errors | An unknown address and a wrong password read the same ("That email and password do not match an account") with a pointer to set a password; an unconfirmed address says so and sends the confirmation again; too many tries says to wait |
| Invitations | Admin > Portals (any role: Admin, staff with the functions they cover, field, an owner or investor on file), Admin > Staff (staff roles), Admin > Owners and Investors (one click per record without a sign-in). The branded invitation email lands on `/update-password`, then the portal. Someone who already signs in just gets the role. Every account row has "Send password link" |
| Create account | An address already on file from a booking request gets a sign-in for that record and a link to choose the password (it used to leave a sign-in with no record) |

### View as (`src/server/view-as.ts`)

An Admin opens any portal as one of its people from Admin > Portals (or Staff, Owners, Investors): `POST /api/view-as/start`
checks the Admin and the database checks the person and the portal and writes the start to the audit log
(`app.view_as_start`). The choice is a signed (`LINK_SIGNING_KEY`), httpOnly, 30-minute cookie that names the Admin; it
counts only while that Admin is signed in and still an Admin (checked on every request, with two-step when required).
Portal pages then read as that person (their reads through row-level security use a 5-minute token made on the server
with `SUPABASE_JWT_SECRET`); the red banner says whose view it is, with Exit (`POST /api/view-as/exit`). Every write is
refused: the Worker entry (and `scripts/serve.mjs`) refuses any non-GET request outside `/admin` while the cookie is
set (a server action is sent to `/read-only`; `src/lib/security/view-as-guard.ts`), and the database layer refuses any
call made for that person that is not a read (`src/lib/db/repo.ts`, `src/server/door.ts`). In `/admin` the Admin is
always themselves. Tests: `src/lib/auth/session.test.ts`, `tests/e2e/signin.spec.ts`, the live verification.

Owner invoice payments: `src/server/owner/payment.ts`. The browser confirms in Stripe's form; the server fetches the
PaymentIntent again and records it (`server_record_owner_invoice_payment`); the webhook does the same for
`payment_intent.processing`, `payment_intent.succeeded`, `payment_intent.payment_failed` and `payment_intent.canceled`
with `metadata.purpose = owner_invoice` (add these events to the Stripe endpoint). Stripe needs Canadian
pre-authorized debits enabled on the account for `acss_debit`. Environment: `VIN_DECODER` (`fake` locally, `vpic` in
production) and `PAYOUT_ENCRYPTION_KEY` (a Worker secret of 32+ characters; never changed without re-encrypting).
`npm run gen:owner-agreements` rebuilds the owner agreement text from `../docs/source`.

## Listing pipeline, documents and maps (migration 0032)

| Piece | Where |
| --- | --- |
| Listing worker | `src/features/listing/worker.ts` (pure), `src/server/listing-worker.ts` (wiring), `POST /api/jobs/listing` (bearer: HMAC of a label with `LINK_SIGNING_KEY`), run by the Worker's cron trigger every five minutes (`custom-worker.ts` `scheduled`) and right after a submit or a retry |
| Providers | `src/integrations/llm` (`LLM_PROVIDER`: `workers-ai` through the Worker's `AI` binding, or `fake`), `src/integrations/photos` (`PHOTO_PROVIDER`: `cloudflare` image transformations, or `fake`; `PHOTO_FAKE_MODE=not_enabled` exercises the fallback), `src/integrations/vin.ts` |
| Screens | `src/features/listing/ListingCapture.tsx`, `ListingProgress.tsx`, `StartListing.tsx` on `/admin/listings/[id]`, `/va/listings/[id]`, `/owner/vehicles/[id]`; uploads through `POST /api/listing/upload` |
| Documents | `src/features/documents/pdf.ts` (owner and renter statements, receipts, insurer invoices, investor statements and yearly summary), `src/server/files.ts`; `/files/<kind>/<record>` (signed in), `/d/<token>` (7-day email links), `/admin/documents/<id>` |
| Money | `src/server/actions/ops.ts` (refund issuing through `payments().refund`, Deposit preview and settlement, toll notice, insurer email), `src/features/admin/DepositSettle.tsx`, `TollEntry.tsx` |
| Maps | `src/integrations/maps/google.ts` (Places API (New), Routes) when `MAPS_PROVIDER=google` and `GOOGLE_MAPS_API_KEY` are set (the deploy sets both when the vault holds `deploy_google_maps_api_key`), else the fake |

`npm run test:unit` runs the Stripe, Google Maps and listing worker tests. `node scripts/gen-backdrop.mjs` rebuilds the photo presets.

## The gaps closed (migration 0033)

Change record: `../docs/changes/0033_gap_close.md`.

| Route | Does |
| --- | --- |
| `/account/bookings/[number]#messages` | The booking's messages: what our team wrote (also emailed, `renter_staff_message`) and the renter's replies (a "Renter replied" task for customer service, `staff_renter_replied`) |
| `/va/scorecard`, `/admin/staff/[id]/scorecard` | The weekly scorecard (own, read-only; any assistant for an Admin) |
| `/va/reconciliation`, `/va/turo` | Finance: processor payouts against payments; Turo trips entered or imported from CSV |
| `/va/checks`, `/va/reviews`, `/va/review/[number]` | Fleet: the opening and closing checks; the photo sets side by side with "Ask for a re-shoot" |
| `/va/bookings/[number]` | Also the late-return panel (Fleet and customer service) and messages for Sales |
| `/va/renters`, `/va/quotes/new` | Find a renter (logged; a reason to open a record outside the window); a quote from a phone, email or WhatsApp lead |
| The rail's "Working as" | An assistant who covers more than one function (`staff_profiles.cover_functions`, set by an Admin under Staff) picks the one to work in |
| `/field/jobs/[id]` | A checklist for every job kind: detail, photo shoot (the listing capture), tracker install and removal, registry run, recovery, other, and re-shoots |
| `/field/report`, `/field/referrals`, `/field/profile` | The field report; the referral link (`/r/<code>`, kept in a cookie and sent with a request to book), QR code and kickbacks; details and sign-in |
| `/field/manifest.webmanifest` | Add to Home Screen (icons in `public/field`, `node scripts/gen-field-icons.mjs`) |
| `/investor/statements/year/[year]` | All of a year's statements as a ZIP (with the summary as CSV; `?format=csv` for the CSV alone) |
| `POST /api/jobs/statements` | Hourly from the Worker's cron: owner statements on the 10th and investor statements on their date, each PDF stored before its email |

Email links (`../emails/src/links.mjs`) that are sections of a page here redirect to that page (`next.config.ts`, `EMAIL_PATHS`).

## Search (migration 0061)

Change record: `../docs/changes/2026-10-19-seo.md`.

| Piece | Where |
| --- | --- |
| Car copy | `src/features/seo/copy.ts` (structure, prompts, checks), `worker.ts` (the job), `src/server/seo-job.ts` (wiring, IndexNow), `POST /api/jobs/seo` (the Worker's cron, every five minutes, with the listing worker's token), `CarCopyPanel.tsx` on the listing review and the vehicle's Listing tab |
| Landing pages | `/car-rental` and `/car-rental/[slug]` (`public.seo_page`, `public.seo_pages_public`, the footer's `public.seo_links`) |
| Guides | `/guides` and `/guides/[slug]` (`public.article`, Markdown rendered with `src/features/guides/markdown.ts`, tokens from `getTokens`) |
| Launch copy | `scripts/content/seo-content.json`, seeded by `scripts/seed.mjs`; sharing images by `node scripts/og-pages.mjs` (`public/og/pages`, `public/og/guides`, `src/features/seo/og-images.json`) |
| Sitemaps and root files | `/sitemap.xml` (index) and `/sitemap-{pages,cars,landing,guides}.xml` (`src/features/seo/sitemap.ts`); `/<IndexNow key>.txt` and the Google verification file through `/api/site-file/[name]` (rewrites in `next.config.ts`) |
| Admin | Settings > Search; Settings > Site: Search engines, Business name, address and phone, Business listings (`src/features/seo/SeoAdmin.tsx`, `src/server/actions/seo.ts`) |

`LLM_PROVIDER=fake` writes the copy from the facts (`src/integrations/llm/fake.ts`), so the job runs locally and in the tests.

## Worker size

The free plan takes a Worker of at most 3 MB compressed. The upload is minified (`"minify": true` in `wrangler.jsonc`) and
the server-only packages that were compiled into each route layer's chunks are resolved from `node_modules` instead
(`serverExternalPackages` in `next.config.ts`: pdf-lib, zod, supabase-js and supabase/ssr, jose, aws4fetch, postgres), so
the bundle holds one copy of each. To measure: `npx opennextjs-cloudflare build`, then
`npx wrangler deploy --dry-run --outdir /tmp/w` prints `Total Upload: ... / gzip: ...`;
`.open-next/server-functions/default/handler.mjs.meta.json` (esbuild's metafile) shows what each input contributes.

The free plan also allows 10 ms of CPU per request. Cached public pages stay well inside it; a server-rendered portal page
on a cold isolate sometimes does not, and Cloudflare answers Error 1102 ("Worker exceeded resource limits"; a reload
works). The live verification counts these. The Workers Paid plan (30 seconds per request) removes the limit.

What costs CPU and what avoids it (docs/changes/2026-10-21-cpu-and-storage.md): loading the Next.js server on a fresh
isolate is about a second. The Worker entry therefore answers repeat requests for the public pages and the sitemaps from
the data centre's Cache API (`src/lib/edge/page-cache.ts`, header `x-edge-cache: HIT`) without loading the app, refuses
scanner paths before the app, and the cron tick asks `server_jobs_due` before running the job routes
(`src/lib/edge/cron-gate.ts`). A rebuild on demand of a public page retires the kept copies (the tag cache wrapper,
`src/lib/edge/tag-cache-gen.ts`).

## Live verification

The `verify` workflow (`scripts/verify-live.mjs`) checks the public pages, headers and nonce, and with `--auth` signs in
through the live form with one test account per portal (`verify-signin@`, `verify-owner@`, `verify-investor@`,
`verify-va-cs@`, `verify-va-finance@`, `verify-va-fleet@`, `verify-va-sales@`, `verify-field@` and `verify-admin@carmacars.ca`).
The accounts are created or reset through the Supabase admin API and given their role by `public.server_verify_accounts`,
which puts every one on the email suppression list; the Admin's password is scrambled again at the end of the run. Each
must land on its own portal without errors and be refused the others by a page that names it. As the Admin it opens
every portal through view as, checks a write is refused and nothing changed, the audit log and Exit, and invites an
assistant from Admin > Portals through to the password and the portal (Resend's test inbox; removed again). The renter
signs out; a reset link goes through to a new password and the portal, and the same link again offers a new one.
`scripts/cf-analytics.mjs` then reports the Worker's last 24 hours and last hour from Cloudflare: invocations by outcome
(Error 1102 is "exceeded resources"), CPU time p50/p90/p99, 5xx answers by path, and CPU per path where Workers
Observability answers. The workflow fails when a sign-in check fails.

## Layout

```
src/app/                    routes (public pages, /book, /book/sent/[number], sign-in, /account, sitemap, robots)
src/components/             design system ported from ../prototype (header, footer, cards, FAQ, cookie banner)
src/features/               calendar, booking (wizard, schema, estimate), car, fleet, forms, legal, seo
src/integrations/<name>/    payments (Stripe), storage (R2), maps (Google), email (Resend), turnstile; each with a fake
src/lib/                    env (typed), db (repo, local, supabase, types), auth, site data, dates, formatting, security
src/server/                 server actions and request metadata
src/styles/                 tokens.css, core.css, pages.css (the prototype's, unchanged) and app.css (additions)
scripts/                    local-db.sh, seed.mjs, gen-types.mjs, serve.mjs
tests/e2e/                  Playwright at 375 and 1440, axe
tests/lint/                 link checker, copy lint, Lighthouse, role crawl, SEO audit, email audit
```

## Scripts

| Script | Does |
| --- | --- |
| `npm run dev` | Next dev server |
| `npm run build` | `next build` (type check and lint run separately below) |
| `npm start` | Production server with the Worker's headers (`scripts/serve.mjs`) |
| `npm run lint` / `npm run typecheck` | ESLint (zero warnings allowed) / `tsc --noEmit` |
| `npm run db:up`, `db:reset`, `db:down`, `db:types`, `seed` | Local stack |
| `npm run cf:build` | `opennextjs-cloudflare build` |
| `npm run cf:preview` | Build and run the Worker locally in workerd (`wrangler dev`) |
| `npm run cf:deploy` | Build and deploy to Cloudflare |
| `npm run test:e2e` | Playwright (needs `npm run build` and the local stack) |
| `npm run check:links`, `check:copy`, `check:lighthouse` | Against a running server (`BASE_URL`, default `http://localhost:3000`) |
| `npm run check:crawl` | Crawls every page anonymous and signed in as each role (renter, owner, investor, admin, each assistant function, field): no 404 or 5xx, no button without a handler, no toggle that does nothing or throws, no console error or failed request, no overflow at 375 and 1440, the copy rules. Local stack (it gives the accounts a known password; `--fresh` makes bare ones). `--per-shape 1` samples one page per shape (CI) |
| `npm run check:seo` | Every public page, car page, landing page and guide: titles and descriptions (unique, lengths), canonical and hreflang, Open Graph and Twitter cards, JSON-LD (business with its address, WebSite with its search, car, breadcrumbs, landing page lists and FAQ, Article; ratings only on a car with its reviews shown), headings, alt text, the sitemap index and its parts, robots, links from home, the fleet, the footer and the hub, the IndexNow key file, 404, redirects of removed cars |
| `npm run check:emails` | Every catalogue email rendered with the payload the database built (latest outbox row; `--test-db` adds the kept database of `scripts/test.sh`; `--samples` the catalogue samples): variables, links (signed ones verify), images, plain text, from and reply-to, 375 and 640 screenshots in `reports/emails/`, then unsubscribe end to end |

## Environment variables

All in `.env.example`, typed and checked in `src/lib/env.ts` (production refuses `DATA_BACKEND=local` and the fake
Turnstile). Public ones (`NEXT_PUBLIC_*`) are inlined at build time.

| Variable | Local | Production |
| --- | --- | --- |
| `DATA_BACKEND` | `local` | `supabase` |
| `DATABASE_URL`, `LOCAL_AUTH_SECRET` | local stack | not used |
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` | not used | Supabase project |
| `SUPABASE_SERVICE_ROLE_KEY` | not used | Worker secret (server only) |
| `NEXT_PUBLIC_VEHICLE_PHOTOS_URL` | `/_local/vehicle-public` | the `vehicle-public` R2 bucket's public domain |
| `TURNSTILE_PROVIDER`, `NEXT_PUBLIC_TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY` | `fake` with Cloudflare's test keys | `cloudflare` with the real keys |
| `PAYMENTS_PROVIDER`, `STRIPE_SECRET_KEY` | `fake` | `stripe` (test mode on staging) |
| `STORAGE_PROVIDER`, `R2_*` | `local` | `r2` |
| `MAPS_PROVIDER`, `GOOGLE_MAPS_API_KEY` | `fake` (sample Toronto landmarks) | `google` (Places Autocomplete (New), Place Details, Routes; server key) |

## Security

- Content security policy on every HTML response with a fresh nonce: `script-src 'self' 'nonce-…'` (plus Turnstile's
  origin). Pages stay static and cached: the Worker entry adds the nonce to every `<script>` as the page streams out
  (HTMLRewriter), and `scripts/serve.mjs` does the same locally. No inline script runs without the nonce.
- HSTS, `X-Content-Type-Options`, `X-Frame-Options: DENY`, `frame-ancestors 'none'`, Referrer-Policy,
  Permissions-Policy, COOP (`src/lib/security/csp.ts`). Portal and booking paths send `X-Robots-Tag: noindex`.
- `server-only` on everything that holds the service role key or the database driver; ESLint forbids importing the
  driver anywhere else.
- Turnstile is checked on the server before every public write (request to book, contact, owner application,
  sign-up, password reset). The database rate-limits requests and leads per address.

## Deploy

Production (https://carmacars.ca) is deployed by the `ci` workflow: Actions > ci > Run workflow, `deploy` = true
(or `gh api -X POST repos/carmacars/carmacars/actions/workflows/ci.yml/dispatches -f ref=main -f 'inputs[deploy]=true'`).
After the database and web checks pass, the `deploy` job runs `scripts/deploy/` with only five repository secrets
(`SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`).
Every step is idempotent; a failing step puts its last output lines into the run's annotations.

1. Secrets: the anon and service role keys from the Management API; `deploy_stripe_secret_key`,
   `deploy_stripe_publishable_key`, `deploy_resend_api_key`, `deploy_link_signing_key`, `deploy_payout_encryption_key`
   and `deploy_stripe_webhook_secret` from the project's vault. All are masked in the log.
2. Cloudflare: R2 buckets `carmacars-prod-{opennext-cache, vehicle-public, vehicle-originals, documents, identity,
   condition-photos, agreements}`, the D1 tag cache (its id replaces the zero id in `wrangler.jsonc` at deploy time),
   the Turnstile widget (off, with `TURNSTILE_PROVIDER=off`, when the token cannot manage widgets: the database rate
   limits still apply), and the DNS for the Worker's custom domains (only A/AAAA/CNAME on carmacars.ca and www).
3. Supabase: migrations through the Management API query endpoint, each file and its row in
   `supabase_migrations.schema_migrations` in one transaction, new files only (0001 to 0030 were applied before the
   runner and are recorded as the baseline). Auth redirect URLs and the invitation email link
   (`/auth/callback?token_hash=...&type=invite`). The Stripe webhook endpoint `/api/webhooks/stripe` (events below),
   its signing secret kept in the vault. The `send-outbox` Edge Function (`supabase/functions/send-outbox`, with
   `emails/src/engine.mjs` copied beside it) and the pg_cron job `carmacars-send-outbox` that calls it every minute
   through pg_net with the vault's `outbox_job_token` (free plan: about 45,000 calls a month of the 500,000 included).
4. Seed: `node scripts/seed.mjs --production` (content rows added, never overwritten; the 20 sample cars only while
   there is no listing, without sample bookings, their addresses suppressed); the stand-in photos into
   `carmacars-prod-vehicle-public` once.
5. Build and deploy: public settings in `.env.production` (written by the job), `opennextjs-cloudflare build`, then
   `opennextjs-cloudflare deploy -- --secrets-file` with the Worker secrets.

Files: `STORAGE_PROVIDER=r2-binding` uses the Worker's R2 bindings (no S3 keys). Private files go through
`/api/storage` with HMAC-signed, expiring links; the public bucket is served by the Worker under `/media`
(`NEXT_PUBLIC_VEHICLE_PHOTOS_URL=https://carmacars.ca/media`). Maps use the fake adapter until the vault holds `deploy_google_maps_api_key`; then the deploy sets
`MAPS_PROVIDER=google` and the `GOOGLE_MAPS_API_KEY` Worker secret. The listing worker needs Workers AI (the `AI` binding,
free daily neurons) and image transformations on the zone (the `images` step turns them on when the token may).

Staging needs its own Supabase project and an environment `staging` with its own secrets (and the repository
variable `STAGING_READY`) before `environment = staging` will run.
