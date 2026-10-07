# 13. Security

Owner: workstream A, with each workstream responsible for the controls in its own area. This file is the threat model and the concrete controls. The permission matrix itself is `docs/permissions.md`; secrets set-up is `docs/setup.md` section 6.

## 1. What is being protected

| Asset | Where | Why it matters |
| --- | --- | --- |
| Licence images and face photos | R2 `identity` bucket; `documents`, `identity_verifications` | Identity theft; sensitive under privacy law; promised deletion at 90 days |
| Licence numbers, dates of birth, addresses | `drivers`, `renters`, `owners`, signed agreement PDFs | Identity theft |
| Card on File | Stripe only; the database holds brand, last four and processor ids | Fraud. Card numbers never reach CarmaCars |
| Bank account numbers | `owner_payout_accounts.account_no`, `investor_bank_accounts.account_no`, encrypted in the application | Payment diversion |
| The ability to move money | Server actions and Edge Functions holding the service role and Stripe keys | Theft by refund, payout or deposit release |
| The ability to disable a car | Tracker module, `tracker_commands` | Physical safety |
| Vehicle live location | `tracker_status` | Stalking, theft |
| Signed agreements and their signature records | R2 `agreements`; `signature_records` | Evidence in disputes |
| Investor records | Investor tables, `admin` bucket | Confidential; admin only |
| The audit trail | `audit_log`, `status_history`, `data_access_log`, `messages` | Integrity of everything above |

## 2. Threat model

| # | Actor and threat | Controls (section) |
| --- | --- | --- |
| T1 | An anonymous attacker floods the booking request, contact or intake forms with spam or scripted requests | Turnstile, rate limits, request limits per email (6) |
| T2 | An attacker guesses or reuses another customer's password, or takes over an email account | Supabase Auth protections, optional two-step for customers, security notices, re-authentication for sensitive changes (4) |
| T3 | A customer changes an id in a request to read or change another customer's booking, document or statement | Row-level security on every table; server actions re-check ownership; signed links issued only after the `documents` row passes row-level security (3, 7) |
| T4 | A stolen or phished staff account | Mandatory two-step sign-in, short sessions, new-device alerts, immediate suspension, in-window customer access only, no bulk export path (4, 3) |
| T5 | A dishonest or careless VA refunds to their own card, releases a deposit, redirects a payout, or copies the customer list | Money limits and admin approval enforced by database guards; bank details admin-only with a 24-hour payout hold on change; no customer list view; search limited to 10 names and logged; no delete (3, 5) |
| T6 | An owner tries to see a renter's identity documents or to use the tracker against a renter | No owner policy on renter tables; `owner_bookings` view; tracker controls blocked during managed rentals by the database (3) |
| T7 | A forged webhook marks a booking paid or a tracker command confirmed | Signature verification, timestamp tolerance, idempotency, and confirming the payment state with Stripe's API before a booking is confirmed (8) |
| T8 | A malicious file upload: a script disguised as an image, an oversized file, a PDF with active content | Signed uploads constrained by type and size, magic-byte checks, image re-encoding, private buckets on a separate origin, forced download headers (7) |
| T9 | Cross-site scripting through a review, a message, a name or a note | React escaping everywhere, no raw HTML rendering of user text, content security policy (10) |
| T10 | Cross-site request forgery against a server action | Same-site cookies, origin checks on every action, no state change on GET (10) |
| T11 | A leaked secret (service role key, Stripe key, R2 key) | Secrets only in GitHub and provider vaults, never in the browser bundle, rotation runbook, separate keys per environment (11) |
| T12 | Loss of the database, or of the encryption keys | Nightly encrypted backups to R2, keys in the password manager, a tested restore (13) |
| T13 | A bug in application code moves money or disables a car wrongly | Rules and guards live in the database and are tested; the tracker guard refuses a disable without an admin approval and a fresh stationary reading (3, 5) |
| T14 | Personal data kept too long | The retention job purges ID images and face photos at 90 days; legal holds are explicit (9) |
| T15 | Scraping of the fleet and prices, or of availability | Public data is public by design; rate limits on the quote and availability functions; nothing private is exposed by the public views (6) |
| T16 | A signed link or email link is forwarded or leaked | Short expiry, single purpose, single use where practical, tokens stored hashed (7) |
| T17 | Tampering with a signed agreement after the fact | SHA-256 of the signed PDF stored in `documents.sha256`; signed files are never overwritten (object paths are unique and the bucket rejects overwrites for the `agreements` prefix through the storage module) (7) |

## 3. Row-level security and the two ways into the database

| Rule | Implementation |
| --- | --- |
| Every table has row-level security | Enabled in migration 0012; `scripts/test.sh` fails if a table lacks it, the admin policy or an audit trigger. Every new table in this blueprint follows `docs/permissions.md` section 4 |
| Browser sessions use the `authenticated` role | `supabase-js` in the browser with the user's token. Policies filter rows. No delete privilege exists for browser sessions |
| The anonymous role reads only public views and calls only read-only public functions | Today: `public_vehicle_listings`. Migration 0016 added three functions the anonymous role may call: `app.vehicle_is_available()`, `app.public_vehicle_calendar()`, `app.public_reviews()`. Added by this blueprint: `public_vehicle_photos`, the fee catalogue, `app.quote_booking()`, `app.search_available()`, `listing_redirects`. Each is reviewed to expose no owner, VIN, plate, renter or reason |
| The server uses `service_role` only after checking who is asking | `requireRole()` in every server action; the service role client is created only inside `src/server/` and is not importable from client components (an ESLint rule and a build check that the key's name does not appear in any client bundle) |
| Customers never write directly | Renters, owners, field staff and investors have no insert or update policy on business tables (field staff: progress of their own job and their own Condition Report only). Their writes are server actions |
| Limited views | `renter_bookings`, `owner_bookings`, `owner_claims`, `field_job_details`, `staff_directory`, `calendar_entries` (0016: staff see everything, Sales and owners see first names only, owners only their own vehicles) |
| Staff access to customers is windowed | `app.va_sees_renter()`: live booking, 90 days after, open task, or 24 hours after a logged lookup with a reason |
| Tests | `supabase/tests/04_rls.sql` signs in as each role and proves what it cannot read or change. Every new policy in this blueprint adds a negative test there. An end-to-end test also tries cross-account access through the app (`15-test-plan.md` section 3) |
| Realtime | Supabase Realtime respects row-level security; only tables listed in the publication are streamed (`bookings`, `tasks`, `field_jobs`, `vehicle_calendar_blocks`, `notifications`), and customers subscribe only to `notifications` and their own booking |

## 4. Sign-in, sessions and two-step sign-in

| Topic | Control |
| --- | --- |
| Provider | Supabase Auth. Email link or password for customers; password for staff |
| Open sign-up | Renters and owners may create accounts. Staff, field staff and investors are invited only (`users.status = 'invited'` until first sign-in). The sign-up form cannot grant any role except `renter`; the owner role is granted by the intake action |
| Passwords | Minimum 12 characters; checked against known-breached passwords (Supabase's leaked password protection where the plan allows it, otherwise a k-anonymity range query from the server); no composition rules |
| **Two-step sign-in for staff** | Time-based one-time codes (TOTP) through Supabase Auth's multi-factor support. Required for admin, VA and field roles and for investors. Enrolment is forced at first sign-in: until a second factor is verified, the only reachable route is `/two-step`. Ten single-use recovery codes are shown once. Recovery otherwise needs an admin, who verifies by voice and resets the factor (logged) |
| Enforced in the database, not only the app | The staff helper functions (`app.is_admin()`, `app.is_va()`, `app.va_has()`, `app.is_field()`) are changed to also require the session's assurance level to be `aal2` (**[new]** `app.session_aal()` reading the token claim through the same seam as `app.uid()`). A stolen staff password without the second factor therefore reads nothing through row-level security. Server actions check the same claim in `requireRole()` |
| Customers | Two-step is optional for renters and owners and offered after the first payout or payment |
| Sessions | Staff: access token 1 hour, session ends after 12 hours or 60 minutes of inactivity, one browser session per device, "Sign out everywhere" in the profile. Customers: 30 days rolling. Cookies: `HttpOnly`, `Secure`, `SameSite=Lax`, host-only |
| Re-authentication | Required (password or a fresh code) before: changing email or password, changing two-step, viewing bank details, approving a payout, approving a tracker disable |
| Suspension | `users.status = 'suspended'` or `staff_profiles.is_active = false` cuts access at once (every policy checks them) and the action revokes refresh tokens |
| Alerts | `account_security_notice` on password, email or two-step change; `staff_security_alert` to admins on a staff sign-in from a new device, 5 failed codes, a role grant, or a bank detail change |
| Brute force | Supabase Auth's built-in limits on sign-in, links and codes, plus the rate limits in section 6 |
| Email links (`/go/[token]`) | 32 random bytes; stored as a SHA-256 hash; one purpose and one record each; expiry 72 hours for offers and uploads, 30 minutes for anything touching money; single use for pay and sign. A link signs the user in only for its destination: opening any other page asks for a normal sign-in |
| Additional drivers | Access by signed link only, limited to their own acceptance screen |

## 5. Server-only money actions and role checks

| Rule | Implementation |
| --- | --- |
| Functions that move money are executable only by `service_role` | Migration 0012 revokes execute on the `app` schema from everyone else and grants a named list to `authenticated`. Every money function this blueprint adds (`app.record_booking_payment()`, `app.issue_booking_statement()`, `app.settle_deposit()`, `app.charge_toll_ticket()`, `app.submit_booking_request()`, and the rest), like the request-flow functions of migration 0016, stays off that list |
| Stripe is called only from the server | `src/integrations/payments/` runs in server actions and Edge Functions. The browser has only the publishable key and Stripe's own frame for card entry (the card number never touches CarmaCars' pages or servers) |
| Every action checks the role and the record | `requireRole(['admin'])`, `requireVa('finance')`, `requireOwnerOf(vehicleId)`, `requireRenterOf(bookingId)`, `requireFieldJob(jobId)`. A missing check fails a lint rule that requires the first statement of every exported action to be a `require*` call |
| Limits and approvals hold even for the server | Database triggers: `app.guard_refund_approval()`, `app.guard_deposit_release()`, `app.guard_payout()`, `app.guard_approver()`, `app.guard_booking_override()`, `app.guard_admin_columns()`, `app.guard_field_job()`, `app.guard_tracker_command()` |
| Amounts come from the database | An action never accepts an amount from the browser for a charge. It passes ids; the function computes the amount. Refund amounts outside the cancellation table need an admin |
| Idempotency | Every Stripe call carries an idempotency key derived from the record and purpose. Every money action accepts a client key and returns the first result on a retry |
| Confirmation dialogs | Money and tracker actions show the amount and record number and require a typed confirmation for amounts over $500 |
| Separation of duties | The person who prepares cannot approve where two people are required; an admin's own preparation of a shareholder claim payment needs the second admin |
| Bank details | Encrypted with `FIELD_ENCRYPTION_KEY` (AES-256-GCM, a random nonce per value, key version stored with the ciphertext) in the server action before insert; decrypted only in the payout export for an admin after re-authentication; screens show the last four |

## 6. Rate limiting and bot protection on public forms

| Layer | Control |
| --- | --- |
| Cloudflare Turnstile | On every public write: booking request, contact, insurer enquiry, owner intake, launch notice, sign-up, password reset, review. The widget runs invisibly; the server action verifies the token with Cloudflare's verify endpoint before any database write, checks the hostname and the action name in the response, and rejects a reused token. Turnstile failure never loses the user's form data |
| Application rate limits | `app.rate_limit(p_key text, p_limit int, p_window interval) returns boolean` **[new]**, backed by `rate_limit_hits` **[new]** (key, window start, count). Keys combine the action, the IP address (from the `CF-Connecting-IP` header) and, where given, the email. Limits: booking request 5 an hour per IP and 3 open requests per email; contact 5 an hour per IP; owner intake 3 an hour per IP; sign-in link 5 an hour per email; quote and availability functions 120 a minute per IP; uploads 60 an hour per user; referral code check 20 an hour per IP (prevents code enumeration) |
| Cloudflare edge | Bot Fight Mode on; one rate limiting rule on the free plan, used for `POST` requests to the app (a coarse ceiling per IP); a rule that challenges requests from outside Canada and the United States to staff routes (`/admin`, `/va`, `/field`), with the VA team's country allowed |
| Honeypot | A hidden field on public forms; a filled honeypot returns a success page and writes nothing |
| Enumeration | Public forms never reveal whether an email, VIN or plate exists (messages are neutral). Booking numbers are sequential (`CC-` and a sequence), so no page ever shows anything personal on the strength of a booking number alone: every booking route needs the renter's session or a `/go/` token |
| Abuse review | Requests flagged by limits are logged with the reason; an admin can block an IP range in Cloudflare |

## 7. File uploads and private storage

| Topic | Control |
| --- | --- |
| Buckets | Private, except `vehicle-public`. Bucket names carry the environment prefix. One R2 token per environment |
| Upload path | The browser asks `createUpload(purpose, entity, contentType, size)`. The server checks the role and the entity, chooses the bucket and the exact object key (the client never chooses a path), and returns a pre-signed PUT link valid for 5 minutes, bound to that key, content type and maximum size |
| Allowed types and sizes | Images: JPEG, PNG, WebP (HEIC is converted in the browser), up to 15 MB. Documents: PDF up to 20 MB. Statement imports: CSV and XLSX up to 5 MB, staff only. Nothing else |
| Verification after upload | `confirmUpload` fetches the first bytes and checks the magic number against the declared type, checks the real size, computes the SHA-256, and only then inserts the `documents` or photo row. A mismatch deletes the object. Unconfirmed objects are deleted after 24 hours by the `retention` job |
| Images are re-encoded | Customer images are resized and re-encoded in the browser before upload (which strips location metadata); listing photos are re-encoded again by the pipeline before anything is published. A file that fails to decode as an image is rejected |
| PDFs | Stored as is, never executed. Served from the R2 origin, not the app's origin, with `Content-Disposition: attachment` for uploads from customers, `X-Content-Type-Options: nosniff` and `Content-Security-Policy: sandbox` on the object response headers. The in-app viewer renders PDFs to canvas with scripting disabled |
| Malware scanning | Not available without a paid service. Compensating controls: the type restrictions above, re-encoding, separate origin, sandbox headers, and staff guidance not to open customer PDFs outside the in-app viewer. Listed as a residual risk |
| Download path | The browser asks for a document by id. The server reads the `documents` row with the user's own token (so row-level security decides), then issues a pre-signed GET link valid for 60 seconds (5 minutes for large files). ID images: 60 seconds, `Cache-Control: no-store`, every staff open written to `data_access_log` |
| Public photos | Only pipeline output is written to `vehicle-public`; originals stay private. Plates are covered before publishing |
| Signed agreements | Written once to a unique key; the storage module refuses to overwrite under `agreements/`. The hash is stored in the database |
| Spreadsheet imports | Parsed in an Edge Function with a row cap (5,000) and a cell-length cap; formulas are treated as text. Exports prefix cells that begin with `=`, `+`, `-` or `@` with an apostrophe to prevent formula injection |

## 8. Webhooks

| Endpoint (Supabase Edge Function) | Verification | Idempotency | Extra |
| --- | --- | --- | --- |
| `stripe-webhook` | Stripe's signature header verified with `STRIPE_WEBHOOK_SECRET` against the raw body; events older than 5 minutes rejected | `webhook_events (provider, event_id)` **[new]**: insert first, process once | Before confirming a booking, the handler retrieves the PaymentIntent from Stripe and checks its status, amount, currency and `metadata.booking_id` against the database |
| `tracker-webhook` | HMAC of the raw body with `TRACKER_WEBHOOK_SECRET`; timestamp tolerance 5 minutes | Provider event id, or a hash of the body | Readings update `tracker_status` only for known device serials |
| `resend-webhook` | Resend's webhook signature | Event id | Updates `messages.status`; writes suppressions |
| Job endpoints (`send-outbox`, `photo-worker`, `jobs-*`) | Called by `pg_cron` through `pg_net` with the service role key from Supabase Vault in the Authorization header; the function rejects any other caller | `job_runs (job_name, run_key)` | Not reachable with the anonymous key |

All webhook functions return 2xx only after the event is stored, respond within 10 seconds (heavy work is queued), and log failures to `webhook_events.error` and an admin notice.

## 9. Personal data retention

| Data | Rule | Mechanism |
| --- | --- | --- |
| Licence images and face photos (uploads and handover photos) | Deleted 90 days after the rental ends, or 90 days after the check if the person does not rent (`program_settings.retention_id_face_days`) | `documents.retention = 'id_face_90d'`; `purge_after` is set when the booking reaches `returned`, `cancelled`, `declined` or `expired`, or 90 days after upload with no booking. The daily `retention` job (Edge Function, 06:00): selects rows past `purge_after`, not on `legal_hold`, not purged; deletes the R2 object; confirms the delete with a HEAD request; sets `documents.storage_path = null`, `purged_at`; sets `identity_verifications.purged_at`; writes an audit entry. A failure raises an admin task and retries next day |
| Legal hold | A claim, dispute, unpaid amount or legal duty on the booking keeps the images until it closes | `documents.legal_hold` set by `setLegalHold` (admin, reason required) or automatically when an incident, dispute or unpaid statement exists on the booking; cleared when they close, after which the 90 days are already past and the next run purges |
| Licence details in text | Kept 7 years as part of the signed agreement and booking record (the privacy policy says so) | `retention = 'records_7y'` |
| Tracker history | 12 months at the tracker service; the database keeps only the latest reading and readings a decision relied on | Tracker provider setting; `tracker_commands` snapshots |
| Rental, payment, owner records, Condition Reports, messages | 7 years | `records_7y`; an annual admin task lists records past 7 years for deletion or anonymization |
| Marketing contact details | Until unsubscribe | `12-notifications.md` section 7 |
| Form drafts, unconfirmed uploads, read notices, expired link tokens, rate limit rows | 30 days, 24 hours, 90 days, 7 days after expiry, 2 days | `retention` job |
| Backups | 30 nightly files and the first file of each month, per `docs/setup.md`. Monthly files are kept 12 months, then deleted, so purged data does not live on in old backups indefinitely. ID images are not in backups at all: they are in R2, and R2 object deletion is final |
| Access and correction requests | The Privacy Officer answers within 30 days. `/admin/renters/[id]` has "Export this person's data" (a ZIP of their records and documents) and a correction path; every export is audited |
| Breach record | An admin-only `security_incidents` **[new]** table records every breach of safeguards (date, what, who was affected, assessment of real risk of significant harm, notifications made), kept 24 months as the breach regulations require (noted in the website policies' legal review) |

## 10. Headers, content security policy and browser controls

Set on every response by the Worker (`middleware.ts`), except object responses from R2 which have their own.

| Header | Value |
| --- | --- |
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Permissions-Policy` | `camera=(self), geolocation=(self), microphone=(), payment=(self "https://js.stripe.com"), usb=(), interest-cohort=()` |
| `X-Frame-Options` and `frame-ancestors` | `DENY` and `'none'`: the site cannot be framed |
| `Cross-Origin-Opener-Policy` | `same-origin` |
| `Cache-Control` | Public pages: cacheable. Every portal route and every response containing personal data: `no-store` |

Content security policy:

```
default-src 'self';
script-src 'self' <hashes of the page's inline scripts> https://js.stripe.com https://challenges.cloudflare.com;
style-src 'self' 'unsafe-inline';
img-src 'self' data: blob: https://<vehicle photos domain> https://<signed R2 domain>;
font-src 'self';
connect-src 'self' https://<project>.supabase.co wss://<project>.supabase.co https://api.stripe.com https://<signed R2 domain> https://cloudflareinsights.com;
frame-src https://js.stripe.com https://hooks.stripe.com https://challenges.cloudflare.com;
worker-src 'self' blob:;
object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; upgrade-insecure-requests;
```

| Point | Detail |
| --- | --- |
| Why hashes and not nonces | Pages are static, so a per-request nonce is not possible without rendering on every request, which the 10 ms limit rules out. A build step (`scripts/csp-hashes.ts`) reads each built page, hashes its inline scripts and writes a route-to-hashes map that the middleware uses to set the header |
| Rollout | `Content-Security-Policy-Report-Only` with a report endpoint for the first week on staging and the first days of production, then enforced. A page whose hashes are missing falls back to report-only and raises an alert, never to no policy |
| No inline event handlers, no `eval` | Enforced by lint |
| User text | Reviews, messages, names and notes are rendered as text. No `dangerouslySetInnerHTML` outside the legal and guide content compiled from the repository at build |
| Cross-site request forgery | Server actions accept only POST with a same-origin `Origin` header (Next.js checks it; the allowed origin list is the app's own domain per environment), and cookies are `SameSite=Lax` |
| Open redirects | `/go/`, `/r/` and sign-in return paths accept only relative paths from a fixed allow-list of route patterns |
| Third-party scripts | Stripe and Turnstile only, loaded only on the routes that use them. Analytics is the Cloudflare Web Analytics beacon, which is allowed in `connect-src` above (`14-seo.md` section 18) |
| Subresource and dependencies | Lockfile committed; `npm audit` and a license check in CI; automated dependency update pull requests; no install scripts from untrusted packages |

## 11. Secrets

As `docs/setup.md` section 6, plus:

| Rule | Detail |
| --- | --- |
| Where they live | GitHub environment secrets, copied by the deploy job to Cloudflare Worker secrets and Supabase Edge Function secrets. The service role key used by `pg_cron` calls is in Supabase Vault. Nowhere else |
| Never in a chat, email, ticket or document | A secret pasted anywhere is treated as leaked: revoke and replace |
| Never in the bundle | Only `NEXT_PUBLIC_*` values reach the browser. CI greps the built client bundle for the names and prefixes of secret values (`sk_live`, `service_role`, `whsec_`) and fails on a match |
| Per environment | Staging uses Stripe test mode and its own Supabase project, R2 token and Turnstile widget. Production data is never copied to staging |
| Least privilege | The R2 token can reach only that environment's buckets; the Cloudflare deploy token can edit Workers only; Stripe restricted keys are used for the Edge Functions (payments, refunds, payment methods, disputes; no account or payout settings) |
| Rotation | On any staff departure with access, on any suspicion, and at least yearly: Stripe keys, service role key, R2 token, webhook secrets, Resend key. `FIELD_ENCRYPTION_KEY` rotation re-encrypts bank fields with the new key version in one migration script run by an admin |
| New secrets in this blueprint | `PHOTOROOM_API_KEY`, `LLM_API_KEY`, `ADDRESS_API_KEY`, `RESEND_WEBHOOK_SECRET`, `CLOUDFLARE_IMAGES_TOKEN`, `GO_LINK_SIGNING_KEY` are added to `.env.example`, `docs/setup.md` and the GitHub environments by workstream A |

## 12. Logging and audit

| What | Where | Contains | Never contains |
| --- | --- | --- | --- |
| Row changes on money, pricing and status tables | `audit_log` (append-only) | Actor, time, table, record, before and after, IP, request id | |
| Status changes | `status_history` (append-only) | From, to, who, when | |
| Staff opening or searching customer records, ID images, bank details | `data_access_log` (append-only) | Who, what, reason, when | |
| Messages | `messages` (no delete) | Rendered text, recipient, template | Attachments' contents |
| Tracker commands | `tracker_commands` (no delete, no rewrite) | Who, why, approval, the reading before, result | |
| Sign-ins and auth events | Supabase Auth logs; `staff_security_alert` for the notable ones | | Passwords, codes |
| Application logs (Worker and Edge Functions) | Cloudflare and Supabase log streams, short retention | Request id, route, action name, user id, role, outcome, duration, error code | Names, emails, phone numbers, licence numbers, addresses, card or bank data, tokens, signed links, document contents, free-text notes. A logger wrapper redacts known keys and truncates unknown strings |
| Provider calls | `provider_calls` | Provider, purpose, duration, cost, status | Request bodies |
| Exports | `audit_log` with `action = 'EXPORT'` | Who, which export, filters | |
| Outgoing staff messages | Checked before sending against `program_settings.blocked_terms` (the coverage provider's name and similar); a hit blocks the send and tells the staff member | | |

Admins review: failed jobs daily on the dashboard; `data_access_log` lookups outside the window weekly; five money entries traced to their documents weekly (VA hiring package section 5); the audit log for the leaver's last 30 days when a finance VA leaves.

## 13. Backups and the restore test

| Item | Detail |
| --- | --- |
| What | Nightly `pg_dump` of production by GitHub Actions, encrypted on the runner with `BACKUP_ENCRYPTION_KEY` before upload to the R2 `backups` bucket. Same major version of `pg_dump` as the database |
| Kept | 30 nightly files; the first file of each month for 12 months |
| Files | R2 objects are not in the dump. Signed agreements, statements and Condition Report photos are protected by enabling R2 object versioning or a weekly bucket-to-bucket copy for the `agreements`, `statements`, `condition-photos` and `claims` buckets. The `identity` bucket is deliberately not copied |
| Keys | The backup key and `FIELD_ENCRYPTION_KEY` are in GitHub and the company password manager. Losing them loses the data |
| Restore test, before go-live | Download last night's file, decrypt, restore into a fresh local database, run `scripts/test.sh` helpers' row counts for 10 key tables against production, decrypt one bank field with the application key, open one signed PDF by its stored path and verify its hash. Record the date and the result in the release pull request |
| Repeat | After any change to the backup job, and every quarter |
| Monitoring | The job writes a `job_runs` row; a missing or failed nightly run raises `staff_job_failed` |
| Recovery objectives | Up to 24 hours of data could be lost on the free plan (no point-in-time recovery); restore time about 2 hours. Stripe remains the record of payments in the gap; a reconciliation after any restore replays Stripe events from the last backup time. Moving to the paid database plan with point-in-time recovery is the upgrade if this is not acceptable |

## 14. Pre-launch security checklist

| # | Check | Owner |
| --- | --- | --- |
| 1 | `scripts/test.sh` passes, including every new table's row-level security, admin policy and audit trigger | DB |
| 2 | Negative access tests pass for each role through the app: renter A cannot open renter B's booking, document, statement or `/go/` link; an owner cannot open a renter's ID image; a VA cannot open a renter outside the window without a logged reason; field staff cannot open a job not assigned to them; an investor cannot open another investor's statement | A, all |
| 3 | Two-step sign-in is enforced for every admin, VA, field and investor account, in the app and in the database helpers; a staff session without the second factor reads nothing | A |
| 4 | No secret in the client bundle; live keys only in production; restricted Stripe keys in Edge Functions | A |
| 5 | Stripe webhook rejects an unsigned request, a stale timestamp and a replayed event; a forged "payment succeeded" does not confirm a booking | C |
| 6 | Money actions refuse amounts from the browser; refunds, deposit releases and payouts above the limits wait for an admin; an admin cannot approve their own payout where two are required | D |
| 7 | Tracker disable is refused without an admin approval, with a reading older than 5 minutes, or while moving; an owner's control request during a managed rental is stored as blocked | F |
| 8 | Turnstile is verified on the server for every public write; rate limits trigger at the stated thresholds | A |
| 9 | Uploads: wrong type, oversize and mismatched magic bytes are rejected; a signed link expires on time; an ID image link cannot be reused after 60 seconds | A, E |
| 10 | Security headers and the content security policy are present on every route; the policy is in report-only with reports arriving, with an enforcement date set | A |
| 11 | The retention job purges a test ID image at its purge date, skips one on legal hold, and records both | F |
| 12 | Backups run nightly; the restore test has been done and dated | A |
| 13 | Logs contain no personal data (sample 200 lines from each function) | A |
| 14 | Staff suspension cuts access within one request | A |
| 15 | Bank detail change: admin only, encrypted at rest, notice sent, payout held 24 hours | D |
| 16 | The public views expose no owner, VIN, plate, renter or block reason; published photos show no readable plate | B, F |
| 17 | Staging sends no email to real customers; production data is not present in staging | F |
| 18 | The staff mailbox, Stripe, Supabase, Cloudflare, GitHub and Resend accounts all have two-step sign-in for every member, and no shared logins | Admins |
| 19 | A dependency audit shows no known critical vulnerability | A |
| 20 | The privacy policy's promises in Part 2 section 7 (encryption, role-limited access, command logs) are each matched by a control in this file | Architect |

## 15. Residual risks, stated plainly

| Risk | Why it remains | Mitigation |
| --- | --- | --- |
| No malware scanning of uploads | No pay-per-use scanner in the stack | Section 7 controls |
| No point-in-time database recovery | Free plan | Nightly backups; upgrade trigger |
| Staff review of identity can be fooled by a good forgery | No automated document check at launch | Original licence checked in person at handover; the identity module can switch to an automated check per booking |
| VAs work on their own devices | Contractors abroad | Two-step sign-in, short sessions, no downloads of ID images, in-window access, logging, the contractor agreement |
| Static-page content security policy relies on build-time hashes | Platform limit | Report-only fallback and alerts |
| Email is the only channel | No SMS at launch | Critical steps are also on the portal; staff phone for same-day changes |

## 16. Database additions needed

| Addition | Purpose |
| --- | --- |
| `app.session_aal()` and its use in the staff helper functions | Two-step sign-in enforced by row-level security |
| `rate_limit_hits` and `app.rate_limit()` | Section 6 |
| `webhook_events` | Section 8 |
| `action_links` | Section 4 |
| `security_incidents` (admin only) | Breach record |
| `documents.legal_hold` automation: a trigger or job that sets and clears it from incidents, disputes and unpaid statements | Section 9 |
| `program_settings.blocked_terms text[]` | Section 12 |
| `data_access_log` writes from the document link action for ID images and bank details | Section 7 |
| Key version column beside each encrypted field (`account_no_key_version`) | Rotation |
