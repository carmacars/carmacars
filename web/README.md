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
tests/lint/                 link checker, copy lint, Lighthouse
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

## Deploy (once the accounts exist)

1. Supabase: create `carmacars-staging` and `carmacars-prod` (Canada Central); apply `../supabase/migrations` in order
   (`supabase db push`); run `node scripts/seed.mjs --content-only` with `DATABASE_URL` set to the project's direct
   connection. Turn on email confirmation and set the Site URL and redirect URL (`https://carmacars.ca/auth/callback`).
2. Cloudflare: `wrangler r2 bucket create carmacars-prod-opennext-cache`, `wrangler d1 create carmacars-prod-tag-cache`
   (put its id in `wrangler.jsonc`), and the same for staging. Create the Turnstile widget for carmacars.ca.
3. Secrets: `wrangler secret put SUPABASE_SERVICE_ROLE_KEY` (and `TURNSTILE_SECRET_KEY`, `STRIPE_SECRET_KEY`,
   `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `GOOGLE_MAPS_API_KEY`); public values as build-time environment
   variables in CI (`NEXT_PUBLIC_*`, `DATA_BACKEND=supabase`, `TURNSTILE_PROVIDER=cloudflare`).
4. `npm run cf:deploy` (staging: `npx opennextjs-cloudflare deploy -- --env staging`). Point carmacars.ca at the Worker.
5. Regenerate types from the project after each migration (`supabase gen types typescript`), and run the e2e suite
   against staging with `BASE_URL`.
