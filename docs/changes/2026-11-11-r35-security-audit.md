# Security audit and engineering rules (Release 35, helper SEC: 1600)

Branch `r35-sec`. Migration `1600_r35sec_hardening.sql`. Tests: `supabase/tests/99_r35sec_security.sql`,
`web/src/lib/security/request-guard.test.ts`, `web/src/lib/file-sniff.test.ts`; `scripts/check-migrations.mjs` in CI.
The rules that came out of it: `docs/engineering-rules.md`.

The owner: "Make sure the website is extremely secure, and there are no gaps in the cyber security of the entire website and
backend", and "make sure you have not developed any bad habits when building and any bad habits get fixed".

## What was checked and found

| Area | Finding | Severity | Done |
| --- | --- | --- | --- |
| Row-level security | On for all 495 tables in `public`; off for 13 internal tables in `app` (no browser grant, so nothing exposed) | Low | On for every table; a test fails if any table lacks it |
| Policies for the anonymous role | None in any schema | OK | Test |
| Definer functions | All 4,470 set `search_path`. 20 older ones (trigger functions, kept copies, a few helpers) were executable by `PUBLIC`: `alter default privileges in schema app revoke ...` (0012) cannot remove PostgreSQL's global default | Medium | Closed; each keeps its explicit grants; test |
| `search_path` without `pg_temp` | A session able to create temp tables could shadow a table inside a definer function | Low | Left as is: browser sessions cannot run DDL through the API (revoking TEMP would also break the DB tests' fixtures) |
| Door allow-list | The functions the API serves a visitor (113) and a signed-in session (23 more) were only partly pinned by tests | Medium | Both lists pinned; a new one fails the test until added on purpose |
| Visitor writes | Cookie choice, tracking and the discount game check the per-address rate limit; chat and game reveal are token-gated | OK | Test |
| Views | Every view a browser reads is a security barrier except `staff_directory` | Low | Barrier on; test |
| Cross-site requests | Session cookies are SameSite=Lax and server actions check their Origin, but API routes checked Origin one by one (only a few did) | Medium | One guard before the app for every write; signed senders listed |
| Image optimizer | Next.js 16.3.8 has a critical advisory in `/_next/image` (GHSA-2464-fhr4-w9xw); the site never uses it | High | The path answers 404 before the app (Worker and local server) |
| Dependencies | `npm audit --omit=dev`: one critical, `next` 16.3.8 (the image optimizer above; a Server Actions denial of service, GHSA-p3m5-59mp-jv5r; `use cache` with typed arrays, GHSA-673q-mjm6-r5xr, not used here) | High | Decision: upgrade to 16.4.6 (needs an install and a full e2e run) |
| Webhooks | Stripe, Quo, Supabase's SMS hook and the tracker verify signatures on the raw body with a tolerance and fail closed; Twilio checks a per-call HMAC token and Twilio's signature when its Auth Token is set; jobs use a constant-time bearer token | OK | |
| Uploads | Sizes capped, types from the bytes, keys built by the server; but nine copies of the check, some reading two bytes | Low | One `imageSniff` used by 14 upload paths |
| Open redirects | `next=` goes through `safeNext` (relative only); OAuth returns only to claude.ai or loopback | OK | |
| SSRF | No server fetch takes a URL from a visitor. The partner CRM sync (a partner's feed and photo addresses) accepted only public https addresses but followed redirects blindly, so a public address could send the server on to an internal one | Medium | Each redirect hop is checked again (at most 5) |
| Secrets in the browser | Only `NEXT_PUBLIC_` URL, anon key, Stripe publishable key and Turnstile site key; server modules import `server-only` | OK | |
| PII in logs and URLs | No `console.log` in app code; database errors are logged masked; no email or phone in a URL | OK | Lint rule keeps it so |
| Security headers | CSP with nonce, HSTS preload, frame-ancestors none, nosniff, referrer and permissions policy on every response | OK | |
| Staff second factor | Enforced by the database for everyone who enrolled; `require_staff_two_step` is off, so staff who never enrolled sign in with a password alone | Medium | Decision (below) |
| Foreign keys | 956 had no index; 538 of them join paths (the visitor purge and booking cascades scanned the child table per row) | Medium | Indexes added; test keeps new ones indexed |

## Bad habits (AI-assisted coding)

| Habit | Found | Done |
| --- | --- | --- |
| Editing applied migrations | None on `main` now; nothing stopped it | `scripts/check-migrations.mjs` in CI |
| Hand-edited generated types | CI already regenerates and diffs | |
| Dead code | 5 components nothing imports | Deleted |
| Duplicated logic | Upload type checks in 9 variants | One helper |
| Flaky test | Card photos swipe: the card was measured while its reveal animation was still moving it, so the finger landed below the photo | Test waits for the card to settle and checks the finger is on the photo |
| Focused or skipped tests | None; skips are per screen width only | Lint and `forbidOnly` keep it so |
| Console noise | None in app code | `no-console` (warn and error only) |
| Code run from strings | None in app code | `no-eval`, `no-implied-eval`, `no-new-func` |
| Fake adapters in production | The fake payment provider's test-card table was compiled into 63 route chunks | Loaded only when used |
| Worker size | 40.5 MiB: 16.3 MiB are repeated copies of the same modules in Turbopack's per-route server chunks | Measured; the fix is a decision (below) |

## Decisions for the owner

1. Turn on the second factor for all staff (`require_staff_two_step`, Settings). Recommended at least for Admins. Staff who have
   not enrolled are sent to the setup page at their next sign-in.
2. Upgrade Next.js 16.3.8 to 16.4.6 (critical advisory). Until then the vulnerable image endpoint is closed.
3. Worker size: build the Worker with webpack instead of Turbopack (`next build --webpack`), or a Turbopack setting that shares
   server chunks, to drop the 16 MiB of repeated modules. Needs a full e2e run; proposed for r36.

## Guides

No guide change: nothing a person does on a screen changed; a form sent from another website is refused with a plain message.
