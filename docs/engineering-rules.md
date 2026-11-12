# Engineering rules

Release 35 (security audit). The rules every change to CarmaCars follows, whoever writes it: a person, Claude Code or a
helper agent. They come from this repository's own audit and from current guidance on the usual faults of AI-assisted
("vibe") coding: missing database access control (row-level security left off is the most common critical finding in
apps built that way), permissive defaults, secrets in client code, code accepted without running the checks, tests that
are skipped or retried until green, duplicated logic, dead code, and fixes that edit history instead of adding to it.

Each rule says how it is enforced. "Test" means it fails CI; "review" means nothing checks it automatically yet.

## Security

| Rule | Enforced by |
| --- | --- |
| Every table in `public` and `app` has row-level security. A new table also gets the `admin_all` policy and nothing for `anon` or `PUBLIC`. | Test: `supabase/tests/99_r35sec_security.sql`, `04_rls.sql` |
| No policy applies to `anon` or `PUBLIC`; no insert, update or delete policy is a plain `true`. | Test: `99_r35sec_security.sql` |
| The anonymous role reads one relation (`public_vehicle_listings`) and writes none; browser roles have nothing in `app` except reading their own rate limit hits. | Test: `99_r35sec_security.sql`, `04_rls.sql` |
| Every view a browser session reads is `security_barrier` (or `security_invoker`). | Test: `99_r35sec_security.sql` |
| Every `SECURITY DEFINER` function sets `search_path`. None is executable by `PUBLIC`: end each migration by revoking from `public, anon, authenticated` and granting `service_role` (and a browser role only on purpose). PostgreSQL grants execute to `PUBLIC` by default, and `alter default privileges in schema ...` cannot take that away. | Test: `99_r35sec_security.sql` |
| The door allow-list: the functions the API serves to a visitor, and the ones it adds for a signed-in session, are listed in the test. Adding one is a decision, with its reason in the migration. Staff, owners and investors go through `public.door` from the server only. | Test: `99_r35sec_security.sql` (names any extra function) |
| A visitor-callable function that writes checks `app.public_rate_check` (or is token-gated). | Test: `99_r35sec_security.sql` |
| Business rules and role checks live in the database; the UI only mirrors them. Every rule has a DB test, role checks included. | Review; DB tests per release |
| The service role key, the database driver and every secret stay on the server: server modules import `server-only`; `postgres` is imported only through `src/lib/db/repo.ts`; only `NEXT_PUBLIC_*` values reach the browser and none of them is a secret. | Lint: `no-restricted-imports`; build fails on `server-only` in a client bundle |
| Every write (POST, PUT, PATCH, DELETE, server actions included) from another site is refused before the app runs. Senders that sign their requests (webhooks, jobs, tracker, OAuth and MCP, one-click unsubscribe) are listed in `SIGNED_SENDER_PREFIXES` and must verify their own signature or bearer token in constant time. | Unit test: `src/lib/security/request-guard.test.ts` |
| Webhooks verify the provider's signature on the raw body, with a time tolerance, and fail closed without a secret (Stripe, Quo, Twilio, Supabase's SMS hook, the tracker). | Unit tests per provider |
| Uploads: the size is capped, the type is read from the file's bytes (`src/lib/file-sniff.ts`), never from its name or the browser's claim, and the storage key is built by the server (ids and random UUIDs), never from user input. | Review; `file-sniff.test.ts` |
| Return paths (`next=`) go through `safeNext` (relative paths only); outside redirects only to a fixed allow-list (OAuth: claude.ai and loopback). | Review |
| Security headers come from `src/lib/security/csp.ts` on every response: CSP with a per-response nonce, HSTS with preload, `frame-ancestors 'none'` (the partner widget alone may be framed), `nosniff`, referrer policy, permissions policy. | Review; e2e header checks |
| No personal data in URLs or logs: logs carry ids and masked text (`maskPersonal`), never emails, phone numbers or bodies. | Lint: `no-console` allows only `warn` and `error`; review |
| No string is ever run as code. | Lint: `no-eval`, `no-implied-eval`, `no-new-func` |
| Dependencies: `npm audit --omit=dev` has no high or critical finding at release time; a finding is fixed by upgrading, or mitigated and listed in the release notes. Only packages that exist and are maintained are added (check the registry page before adding a name an assistant suggested). | Review at each release |

## Database and migrations

| Rule | Enforced by |
| --- | --- |
| Migrations are history: once on `main`, a migration is never edited, renamed or removed. A fix is a new migration. | CI: `scripts/check-migrations.mjs` |
| Migration file names are `NNNN_lower_snake.sql` with a number no other file uses; each helper works in its own number range. | CI: `scripts/check-migrations.mjs` |
| `web/src/lib/db/types.ts` is generated (`npm run db:types`), never edited by hand. | CI: regenerates and fails on a diff |
| Every join-path foreign key has an index. Columns that only record who acted (`created_by`, `approved_by` and the like) are exempt. | Test: `99_r35sec_security.sql` (names any missing) |
| Lists read in one query, never one query per row (no N+1). A page that needs several reads makes them in parallel, and a read asked twice in one render is cached for the request (`door()` does this). | Review |
| Prices, fees, thresholds, limits and wording an Admin may change are Program settings (or settings tables), never constants in code. Constants in code are for facts that cannot change (a file signature, a unit). | Review |

## Code

| Rule | Enforced by |
| --- | --- |
| Run the checks before calling work done: type check, lint, unit tests, and the DB suite for SQL changes. "It should work" is not done. | CI on every push |
| No dead code: a component or module nothing imports is deleted, not left "for later" (git keeps it). | Review (r35 removed five) |
| One implementation of a rule: before writing a helper, search for the one that exists (`file-sniff`, `safeNext`, `money`, `clock`). Copies drift: the upload checks had grown nine variants, some reading two bytes, some four. | Review |
| Fake adapters (payments, email, phone) load only where they are used, by a dynamic `import()`, so they never reach the production Worker. | Review |
| Keep components small enough to read: a file over about 600 lines is split by screen or section when it is next changed. | Review |
| Commits are one change each, with a message that says what and why; no unrelated refactor inside a fix. | Review |

## Tests

| Rule | Enforced by |
| --- | --- |
| Tests assert behaviour a person or the database would notice (what is shown, refused, stored, charged), not how the code is written. | Review |
| No focused test (`test.only`) is committed. | Lint (`no-restricted-properties`) and Playwright `forbidOnly` in CI |
| A test is skipped only for a project it does not apply to (a mouse test on the phone width), never because it fails. | Review |
| A flaky test is fixed at its root cause, not retried or slowed down. CI retries once, and a test that passed only on its retry is reported as flaky and treated as a failure to fix. Wait for a condition (`expect.poll`, an element's state, animations finished), never for a fixed time. | Review |
| Test data uses `example.test` addresses and made-up names; no real person, key, policy or account number. The repository is public. | Review |

## Worker size

The Worker's server bundle has a budget (`web/scripts/worker-size.mjs`, 50 MiB). Before adding a dependency to server code,
check its size; heavy libraries used by one route load with a dynamic `import()`. The r35 measurement (esbuild metafile
of the Nov 9 build): of 40.5 MiB, 30.7 MiB are Turbopack's server chunks, and 16.3 MiB of those are second and later
copies of the same modules compiled into each route's chunks. Removing that duplication is the large win (see
`docs/releases/r35.md`, security audit).
