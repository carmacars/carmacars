# Launch audit, October 13 and 14, 2026

An independent check of the CarmaCars platform before launch, by someone who did not build it: every owner
requirement, every decision in `docs/changes/` 0016 to 0034, every page and button for every role, every email,
SEO, the live operations and the Worker's CPU limit. What was found was fixed in the same pass; what could not be
fixed is listed as **not built** or **needs owner**, plainly. The earlier handover pass of the same day
(`2026-10-13-audit.md`) is kept as the record of what it fixed; this file is the launch status.

Status words, one per row:

- **works**: built, and the evidence below passed in this audit
- **fixed now**: was broken or missing; fixed in this audit (commit named), and the evidence passed after the fix
- **not built**: does not exist yet; said so, with what happens instead
- **needs owner**: works as far as code can take it; the rest is a key, a setting, content or a decision only the owner has

Evidence names: `NN_*.sql` are the database suite (`scripts/test.sh`, 2,671 assertions, all passing); `*.spec.ts`
are the Playwright end-to-end tests at 375 and 1440 px with axe; `crawl` is `web/tests/lint/crawl-roles.mjs` signed in
as every role; `seo` is `seo-audit.mjs`; `emails-db` is `emails-db.mjs` (every catalogue email rendered with database
values); `verify` is the live verification workflow against carmacars.ca (section 9).

## 1. Summary in numbers

| Check | Result |
| --- | --- |
| Database suite | 22 files, 2,671 assertions, 0 failed (0035 adds `22_launch_audit.sql`, 28 assertions) |
| Role crawl, production build | 10 roles (anonymous, renter, owner, investor, Admin, customer service, Finance, Fleet, Sales, field), 659 pages rendered, 1,917 links requested, 1,820 forms and buttons checked, at 375 and 1440: 1 problem found (a hydration error on the assistant's offer screen), fixed; after the last change a full re-crawl (one page of each shape: 517 pages, 1,739 links) 0 problems |
| SEO, production build | 32 pages checked in full (home, fleet, the information and legal pages, 20 car pages), 20 model pages, sitemap 11 entries (no car while every car is a sample), 41 noindex pages (20 sample cars, 20 model pages of samples, `/investors`), 0 problems |
| Emails | 126 catalogue codes rendered with database values (31 from the app database, 93 from the test database, 2 from samples: the two Supabase Auth sends itself), 157 links checked, 0 problems; 40 looked at by eye at 375 and 640 (every renter booking life-cycle email and every owner billing email); 6 wording defects fixed |
| Real sends | 34 emails through the Resend API to `delivered+<code>@resend.dev`, all 10 audiences and every renter life-cycle email: 34 of 34 "delivered" (section 4.3) |
| Lighthouse, mobile, local production build | Home 79, fleet 91, car page 79, model page 93 for performance; accessibility 100 on all four (section 5.4) |
| Copy | 81 pages and 126 emails: no long dashes, no numbered company name, no misspelled CarmaCars, no placeholder text (`copylint.mjs`, `check-text.sh`, `emails/check.mjs` 15 checks, `emails-db`) |
| Live scheduled jobs | 21 pg_cron jobs active; the last 24 hours: 4,622 runs succeeded, 0 failed; the last 360 calls of `send-outbox` all answered 200 |
| Live outbox | 17 rows: 9 sent, 8 suppressed on purpose (sample and test addresses), 0 failed, 0 waiting |

## 2. The owner's standard

| # | Requirement | Status | Evidence | Notes |
| --- | --- | --- | --- | --- |
| S1 | Every email fully functional, good-looking, every button and link works | fixed now | `emails-db` (126 codes, 157 links, 0 problems), `emails/check.mjs` 15 checks, screenshots at 375 and 640 in `web/reports/emails/`, 34 real sends (4.3) | Fixed: the monthly owner invoice claimed a pre-authorized debit that nothing runs (it now says how to pay); the payout email showed the fee card's last four digits instead of the payout account's; "our team will meet you" opening a heading; "1 new damage item(s)"; "Fuel: Not recorded" read as an instruction; an empty mailing address line in every footer; a registry visit email sent before the visit had a date ("Registry visit booked: To be booked at"); empty transfer reference and review text. Commit "Emails: ..." and 0035 |
| S2 | Every button and link works, no 404s, no dead buttons, no console errors | fixed now | crawl: 659 pages, 0 problems after the fix | Fixed: React hydration error #418 on `/va/bookings/[n]?tab=review` (the offer's "Open until" clock text); a Content Security Policy violation logged on every page with a form (Zod's code generation probe; now jitless) |
| S3 | Very well SEO optimized, no gaps | fixed now | `seo` 0 problems; Lighthouse SEO 100 on indexable pages | Fixed: the 20 sample cars were indexable and in the sitemap (now `vehicles.is_sample`, section 5.2) |
| S4 | Must not look like AI slop | works | Read by eye: home, how it works, list your car, requirements, 40 emails; `copylint.mjs` | The copy is specific (numbers, steps, who does what), not filler |
| S5 | No em dashes | works | `check-text.sh`, `copylint.mjs`, the crawl's long-dash rule, `emails/check.mjs`, `emails-db` | None found |
| S6 | Always "CarmaCars", never the numbered company publicly | works | crawl (anonymous rule), `seo`, `emails-db`, `14_web_app.sql` | The legal name appears only on legal documents, from `program_settings.company_legal_name` |
| S7 | Red, black and white | works | tokens `web/src/styles/tokens.css`; screenshots | The logo is the text wordmark until the owner uploads the file (needs owner) |
| S8 | Nothing hard-coded that should be editable | works, with two exceptions | Admin > Settings: site, content blocks, program settings, fees, deposit tiers, kilometres, classes, airports, coverage prices, aliases, staff, insurers, promo codes, quick replies; `admin.spec.ts` "rates, site settings ..." | Exceptions: the footer of the Supabase Auth emails (`scripts/deploy/auth-templates.mjs`) names the city and contact address in the template; the public "List your car" comparison table is template copy (the numbers in it come from settings) |
| S9 | Request to book, never instant | works | `06_request_to_book.sql`, `08_booking_app.sql`; `request.spec.ts`, `admin.spec.ts` "review a request, adjust, re-price, send the offer", `portal.spec.ts` "offer, approve, sign, pay, confirmed", `portal.spec.ts` "race" | Live: real requests CC-10001 and CC-10002 reached the database and the staff emails |
| S10 | Calendars: master and per vehicle; public page shows unavailable dates | works | `admin.spec.ts` "master calendar, blocks, and a drag"; `request.spec.ts` "car page: calendar"; crawl of `/admin/calendar`, `/va/calendar` | |
| S11 | Insurer bookings that do not block the calendar | works | `06_request_to_book.sql` (calendar switch), `pipeline.spec.ts` "insurer: an invoice is emailed" | |
| S12 | Owner first and last month insurance billed separately from tracker fees | fixed now | 0029 (`issue_upfront_invoice` insurance only, `issue_tracker_install_invoice`), `16_owner_portal.sql`, `owner.spec.ts`; upfront invoice email read at 640 | The invoices were right; the public owner page and owner FAQ still said the tracker install fee is paid before the car goes live and the tracker fee is billed monthly from the start. Fixed in the page and, through 0035, in the live FAQ |
| S13 | Every portal: renter, owner, admin, each VA function, field, investor | works | crawl as each; `gaps.spec.ts` "each portal home loads ... refuses the others"; verify signs in to renter, owner, investor, customer service and field on the live site | Admin is never signed in live by design (no test Admin on production). Fixed: the `/investors` sign-in sent investors to the renter portal |
| S14 | Secure | works, with owner switches | CSP with nonce, HSTS, frame denial (`site.spec.ts`); row-level security on every table (`04_rls.sql`, `15` to `18`); two-step sign-in (`staff.spec.ts`) | Two-step sign-in for staff is off on production until every staff member has an authenticator app (needs owner) |

## 3. The traceability rows (`docs/blueprint/99-traceability.md` section 2)

| # | Requirement | Status | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 1 | Responsive website, phone and desktop, not an app | works | every e2e test at 375 and 1440; crawl overflow check at both widths; field manifest (`gaps.spec.ts`) | |
| 2 | Visually appealing, photo-heavy, easy, secure, red black white, CarmaCars, no broken links, no AI text | works; photos need owner | S2 to S7 | Photos are stand-ins until the real fleet |
| 3 | Request to book; staff adjust and offer; renter approves, signs, pays; then the calendar | works | S9 | |
| 4 | Master calendar; a calendar on every vehicle page | works | S10 | |
| 5 | Insurer bookings may exist without blocking | works | S11 | |
| 6 | Smooth forms: owner registration (six situations, government PDFs pre-filled), rental agreement on a phone | works, except the PDFs (not built) | `owner.spec.ts` "apply with three vehicles"; `portal.spec.ts` sign on a phone; `11_owners_forms_listings.sql` | Not built: filling the official ServiceOntario PDFs; the owner gets a data sheet PDF with every value until the official forms are mapped (needs owner: the PDFs) |
| 7 | Listing with AI drafts, consistent backgrounds, review, live automatically | works; backgrounds need owner | `pipeline.spec.ts` "an owner lists a car on a phone ...", "a failed step ... Retry" | Background replacement needs Cloudflare image transformations on the zone (needs owner); the licence plate is not covered (not built) |
| 8 | Tolls, tickets, damages: single entry, bulk import, notice reading, matching, charge or bill owner, emails | works, except notice reading (not built) | `10_tolls_statements.sql`; `admin.spec.ts`; `pipeline.spec.ts` "tolls: a single entry keeps the uploaded notice" | Not built: reading fields from an uploaded notice (OCR). Bulk import works with column mapping; the first real statement file has to be mapped once |
| 9 | Every actionable event emails; owners and staff emails | works | 126 codes; `20_gap_close.sql` "every catalogue code emitted by something"; `emails-db` | Not built: an email for a staff proposal to change a confirmed booking (0024 item 1; customer service gets a task) |
| 10 | Owner statements monthly; company statements per car, owner, total | works | `02_owner_month.sql`, `10_tolls_statements.sql`; `admin.spec.ts` statements; `pipeline.spec.ts` statements PDFs | |
| 11 | SEO, every car page ranks | works in code; ranking needs owner | section 5 | Ranking needs the real cars, reviews, Search Console and time |
| 12 | Portals for every role | works | S13 | Two-step for investors is offered, not required |

## 4. Emails

### 4.1 Rendered with database values

`emails-db.mjs` takes, for each of the 126 codes, the latest outbox row the database built for a real event (local
app database, then the kept database of `scripts/test.sh`), adds what `send-outbox` adds (7-day signed file links with
the same key, sign-in links), renders HTML and text with `emails/src/engine.mjs` and the loaded template, and checks
every variable filled, no tag left, every link a real route (behind sign-in where it should be), signed links verify,
images load with alt text, no markup in the text version, from and reply-to by the rule, unsubscribe on marketing, no
overflow at 375 and 640. Result after the fixes: 0 problems. Warnings left are fixture values (test rows without a
renter on an owner booking notice, or without a hold-back reason).

### 4.2 Looked at by eye

At 375: the renter life cycle in order (request received, needs info, offer ready, offer reminder, agreement ready,
agreement signed, booking confirmed, payment receipt, documents needed, booking reminder, pickup details, rental
started, return reminder, return details, check-in complete, final statement, deposit released, review request,
come-back after 1 week and 1 month). At 640: every owner billing email (upfront invoice, monthly invoice, payment
received, payment failed, in arrears, statement ready, payout sent, fee change notice, toll invoice). Defects found
are in S1; all fixed.

### 4.3 Real sends through Resend

The rendered HTML and text of each email (database values, as `send-outbox` renders them) sent through the Resend
API from its catalogue sender and reply-to to `delivered+<code>@resend.dev`, then read back from Resend: 34 sent, 34
"delivered".

| Audience | Codes |
| --- | --- |
| Renter (21) | account created, request received, request needs info, offer ready, offer reminder, agreement ready, agreement signed, booking confirmed, payment receipt, identity needed, booking reminder, pickup details, rental started, return reminder, return details, return complete, final statement, deposit released, review request, come-back 1 week, come-back 1 month |
| Owner (4) | upfront invoice, monthly fee invoice, statement ready, payout sent |
| Investor (1) | return paid |
| Admin (1) | morning digest |
| Customer service (2) | request waiting, new booking request |
| Finance (1) | cancellation received |
| Fleet (1) | breakdown reported |
| Sales (1) | end-of-day digest |
| Field (1) | field job assigned |
| Insurer (1) | insurer invoice |

### 4.4 Live outbox, digests, Auth emails

- Live outbox: 0 failed rows; the sender runs every minute and answered 200 on every call in the last 24 hours.
- Digests: the morning and end-of-day Admin digests went out on October 13 with real content (one standing item:
  "Fleet is below the franchise minimum", linking to `/admin/approvals`, which redirects to `/admin/tasks`). They
  read "Due not set" because 0034 was not yet on production; after this deploy they read "No due date".
- Supabase Auth: confirmation, invitation, recovery, magic link and email change templates are branded and link to
  `/auth/callback?token_hash=...` (checked through the Management API, and verify opens each live). The
  reauthentication code template was Supabase's default; it is now branded (it is not sent while reauthentication
  is off). Supabase's security notification emails are all switched off.
- Marketing emails now wait while the mailing address is empty (0035), so none can go out without it.

## 5. SEO

### 5.1 Checks (`seo-audit.mjs`, production build; live through verify)

| Check | Result |
| --- | --- |
| Unique titles (about 60) and descriptions (70 to 170) | 0 duplicates, 0 out of range |
| Canonical on carmacars.ca; none on noindex pages | Correct |
| Open Graph and Twitter cards, absolute image, site name | On every public page |
| JSON-LD | AutoRental business node on home; Product and Car with offers and images on car pages; BreadcrumbList on every page but home; FAQPage only where the questions are on the page (car pages, FAQ); no self-serving ratings; all parse |
| Sitemap | Every indexable public page and every real car and model page; no staff, portal or private path; no sample car |
| robots.txt | `/book`, `/account`, `/owner`, `/investor`, `/admin`, `/va`, `/field`, `/api/`, sign-in pages, `/unsubscribe`, `/files/`, `/d/`, `/sign/`, `/r/` disallowed; sitemap listed |
| noindex on private pages | Header `X-Robots-Tag: noindex` on every private path, meta robots on the pages |
| Headings, alt text | One h1, no skipped level, alt on every image |
| Internal links | Every car linked from `/cars` in the HTML; every model page from its cars |
| 404 and removed cars | Styled 404 with status 404 and noindex; removed cars 301 to the twin or model page, or 410 |
| hreflang | Not needed (one language, one country) |

### 5.2 Sample cars kept out of search (0035)

The 20 cars on the live site are placeholders. They are now marked `vehicles.is_sample = true` (the migration sets the
flag on the 20 seeded cars; the seed sets it on any new seed). A sample car page sends `noindex, follow` and has no
canonical; sample cars are left out of the sitemap, and so are model pages whose cars are all samples. The cars stay on
the fleet page and still take requests. Admin > Today lists "20 sample cars are on the website" until they are gone.
To make a car real: Admin > Fleet > the car > Listing > "Not a sample" (audited); or unlist the sample when the real
car is listed. Until the first real car, the sitemap holds the 11 information pages only.

### 5.3 Before ranking

Search Console, Business Profile, real photos and reviews (section 11, items 6 to 9).

### 5.4 Lighthouse, mobile (local production build, Lighthouse's mobile throttling, 2-CPU sandbox)

| Page | Performance | Accessibility | Best practices | SEO | LCP | CLS | TBT |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `/` | 79 | 100 | 100 | 100 | 2.8 s | 0 | 670 ms |
| `/cars` | 91 | 100 | 100 | 100 | 2.2 s | 0 | 340 ms |
| `/cars/mercedes-benz-c300` | 79 | 100 | 96 before the fix | 66 (noindex: a sample car, intended) | 3.1 s | 0 | 580 ms |
| `/rent/toyota-corolla` | 93 | 100 | 100 | 66 (noindex: samples only, intended) | 3.2 s | 0 | 80 ms |

The CI runners measured home 93, fleet 97, car page 99, model page 94 on the same code (faster CPU). Best practices 96
on the car page was the CSP violation of S2 (fixed). Total blocking time is the React bundle on a throttled 2-CPU
machine; LCP is under 2.5 s on the CI runner for fleet and car pages.

## 6. The decisions of `docs/changes` 0016 to 0034

| Change | Decision or item | Status | Evidence |
| --- | --- | --- | --- |
| 0016 | Request, offer, approve, sign, pay; expired offers back to requested; declined as the one end state | works | `06_request_to_book.sql` (348), `portal.spec.ts` |
| 0016 | An offer does not hold the car; first to pay gets it, the other is voided | works | `portal.spec.ts` "race: another renter pays first" |
| 0016 | Calendar blocking switch, insurer billing and invoices | works | `06`, `pipeline.spec.ts` insurer |
| 0016, 0018 | A CarmaCars promo code is shared with the owner in the split (on a Self-Managed car the owner bears all of it) | needs owner | Blueprint 99 question 1 recommends CarmaCars absorbs its own promos; the database still shares it. Decide before sending come-back codes |
| 0016 | Turnaround buffer 0 at the constraint, 2 hours in availability (0025) | works | `13_owner_answers.sql` |
| 0018 | Outbox, digests, preferences, suppressions, daily and monthly caps | works | `07_notifications.sql`; live cron |
| 0018 | Come-back emails need express consent | works | `07_notifications.sql` |
| 0019 | Public wrappers, one price source, signing, payment under a lock, renter self-service, two-step | works | `08_booking_app.sql` (414), `portal.spec.ts` |
| 0019 | Change requests produce no amendment document for signature | not built | The renter's agreement is recorded on the request |
| 0020 | Handover and return, statements and the Deposit, field jobs, calendar drag, tasks, incidents, swap, reconciliation | works | `09_operations.sql` (309), `staff.spec.ts` field handover, `pipeline.spec.ts` Deposit |
| 0020 | Automatic cleaning block at return | not built | Staff add a block |
| 0021 | Toll intake, matching, damage after rental, owner statements and reissue, company statements, CSV | works | `10_tolls_statements.sql` |
| 0021 | OCR of notices; tracker position as proof; "adjustments to earlier months" section; funnel and investor capital in company statements | not built | Staff type notice fields; attach the tracker screenshot as a document |
| 0022 | Site settings and content, form drafts, leads, owner application, listing pipeline, public reads | works | `11_owners_forms_listings.sql`, `site.spec.ts`, `pipeline.spec.ts` |
| 0022 | Copy similarity between listings | not built | The reviewer reads the copy |
| 0023 | Payload and triggers for every code | works | `20_gap_close.sql`, `emails-db` |
| 0024 | Remaining SQL jobs scheduled, timed publishing, hand-added charge email, one change flow | works | `12_end_to_end.sql`; live cron (21 jobs) |
| 0024 | A staff proposal sends the renter no email of its own | not built | Customer service gets the task and calls or writes |
| 0025 | The owner's answers: swap revenue by segment, 2-hour notice, always open, classes, Deposit and km choices, no age caps, additional driver 25%, coverage through CarmaCars, delivery by distance and airports, held review requests, reply-to aliases, cookies | works | `13_owner_answers.sql` (106) |
| 0025 | Per-km delivery rate, origin, airports' surcharges, coverage default prices | needs owner | Empty until entered in Admin > Settings; delivery costs the car's fee, coverage is "priced in your offer" |
| 0025 | Marketing must not go out without the mailing address | fixed now | 0035, `22_launch_audit.sql` |
| 0026 | Reply-to alignment | works | `emails-db` reply-to rule |
| 0027 | Website reads and server wrappers | works | `14_web_app.sql`, `seo` |
| 0027 | Linking an account to an earlier request with the same email | not built | Staff do it by hand |
| 0028 | Renter portal | works | `15_renter_portal.sql`, `portal.spec.ts`, crawl |
| 0028 | Pending payment row at PaymentIntent creation; "Resend link" for additional drivers | not built | The payment is written at authorization; the renter copies the driver's link |
| 0029 | Owner portal; upfront invoice insurance only; tracker install invoice when installed; no tracker fee until installed | works | `16_owner_portal.sql`, `owner.spec.ts` |
| 0029 | The monthly pre-authorized debit on the 15th (off-session charge) and the debit-results job | not built | The owner pays each monthly invoice from its page by card or debit; the email now says so (fixed now) |
| 0029 | Form C and D upload and review, Forms A and B on screen | not built | Data sheet PDFs |
| 0030 | Admin portal through one door | works | `17_admin_portal.sql`, crawl (154 Admin pages) |
| 0031 | Staff and investor portals, two-step enforcement | works | `18_staff_investor_portals.sql`, crawl |
| 0032 | Listing worker, documents and 7-day links, refunds, Deposit preview, insurer email | works | `19_pipeline_documents.sql`, `pipeline.spec.ts` |
| 0032 | Field capture screen on a photo shoot job; plate covering; statement emails with PDFs on fixed dates (month-open, payouts, owner-billing jobs) | not built | Owners, Fleet and Admins capture; statements email signed links hourly |
| 0033 | Renter messages, statement emails, switcher, scorecard, Turo trips, daily checks, photo review, late-return panel, find a renter, Sales quotes, field checklists, verification accounts | works | `20_gap_close.sql`, `gaps.spec.ts` |
| 0033 | Tracker commands through the provider's API | not built | Installer's tick confirms tests |
| 0034 | Unsubscribe, the renter's review, disable approval email, renter documents, digest lines | works (live after this deploy) | `21_audit_fixes.sql`, `audit.spec.ts` |
| 0034 | Review published without consent | fixed now | 0035 |

## 7. Links, buttons and routes

The crawl renders every page reachable from each role's home (two of each page shape, such as one booking and
another), requests every link, opens every dialog and toggle, and fails on a 404 or 5xx, a GET form that fails, a
button with no handler, a dialog that does nothing, a console error or failed same-origin request, horizontal
overflow at 375 or 1440, a long dash, a misspelled brand, or the numbered company name on a public page. It never
submits a form that writes.

| Role | Pages | Links | Forms and buttons |
| --- | --- | --- | --- |
| Anonymous | 57 | 92 | 27 |
| Renter | 34 | 95 | 37 |
| Owner | 29 | 70 | 32 |
| Investor | 27 | 48 | 24 |
| Admin | 154 | 450 | 1,153 |
| Field | 28 | 45 | 27 |
| Customer service | 93 | 460 | 164 |
| Finance | 78 | 203 | 99 |
| Fleet | 86 | 312 | 140 |
| Sales | 73 | 142 | 117 |

Found: one hydration error (fixed), one CSP violation on form pages (fixed), the investor sign-in going to the renter
portal (fixed). Routes, naming, orphans and redirects for older paths were reviewed against `2026-10-13-audit.md`
section 6: no orphan page; every email path that is a section of a page redirects to it (`next.config.ts`); prototype
file names and `/sign-up` redirect permanently.

## 8. Live operations

| Item | Status | Evidence |
| --- | --- | --- |
| Deploy job and verify | see section 9 | |
| Scheduled jobs | works | 21 pg_cron jobs active, every one ran in the last hour; 24 hours: 4,622 succeeded, 0 failed (`cron.job_run_details`); `send-outbox` the last 360 HTTP calls, all 200 |
| Outbox | works | 0 failed, 0 queued; 9 sent, 8 suppressed (sample and verification addresses) |
| Stripe webhook | works (test mode) | Endpoint `https://carmacars.ca/api/webhooks/stripe` enabled for the three PaymentIntent events; recent events have 0 pending deliveries. Live keys are the owner's |
| Supabase Auth emails | works | Branded token-hash templates for confirmation, invitation, recovery, magic link, email change; reauthentication now branded; verify opens each live |
| Site settings | needs owner | Complete except: mailing address, street address, logo (light and dark), favicon, sharing image, Google place id, HST number (`app.site_setup_problems` lists the first two and the sample cars on Admin > Today) |
| Real request waiting | needs owner | CC-10002, a request from a real visitor on October 13 at 6:33 pm on a sample car, is still `requested` |

## 9. The Worker's CPU limit (Error 1102)

Cloudflare's Workers Free plan allows 10 ms of CPU per request. Server-rendered portal pages are dynamic Next.js
renders. Measured from Cloudflare's analytics (the verify workflow now records `workersInvocationsAdaptive` for the
last hour) before this audit's changes: 236 requests, CPU p50 12.0 ms, p90 445.7 ms, p99 974.9 ms. The median request
is already over the free limit; Cloudflare tolerates some overrun, which is why most portal pages load and some
answer 1102.

What this audit changed to cut CPU per request: every database call is now one plain PostgREST request instead of a
new supabase-js client per call as the signed-in user (a client builds its Auth, Realtime, Storage and Functions
sub-clients); the Supabase Auth client, the signed-in user (and its round trip to Supabase Auth), the access token,
the assurance level, the roles, the Admin gate and every repeated portal read are asked once per render instead of
two to six times (the frame and the page both asked); and the site frame (root layout), which runs on every page,
reads the site settings and the small "global" content blocks only, instead of every content block (39 KB), the
whole fleet and the policy facts. Measured after the deploys, from the same analytics: success p50 12.8 ms, p90
364.8 ms (from 445.7), p99 1,127 ms over the hour. The final verify run, with every portal signed in, had no 1102
answer and needed no retry (the hour's 29 exceeded-resources answers all came from the runs before the frame change:
the count did not move during the final run). Requests that Cloudflare stopped show CPU p50 10 ms: the free limit is
enforced on some requests, not all.

**Plain answer: yes, the Workers Paid plan (US$5 a month) is still needed for reliable portals.** The changes lower
the work per request, but a dynamic React server render with a cold isolate does not fit in 10 ms; only the Paid plan
(30 s CPU per request) removes 1102. The public pages are cached and unaffected either way.

## 10. Live results

| Run | Result |
| --- | --- |
| Push CI on the audit's commits | green (database, web with every e2e test at 375 and 1440, audit: crawl, SEO, emails, Lighthouse) |
| Deploy (`ci` with `deploy`), twice | green; migrations 0034 and 0035 applied (history 35 rows), 127 email templates loaded, Auth templates patched, `send-outbox` answering |
| Verify before the audit's changes (38510043692) | green; CPU p50 12.0 ms, p90 445.7 ms |
| Verify right after the first deploy (38513556410, 38514185326) | failed on cold isolates: Cloudflare answered 16 and 5 requests with 1102 (refusal pages `/va/no-access`, `/investor/no-access`, `/field`), each loaded again; the renter's refusal check gave up |
| Verify after the frame change (38517204349) | green: every portal signed in through the live form (renter, owner, investor, customer service, field), each refused the others, 0 console errors, 0 retries, no 1102; the three Supabase Auth links land signed in; the live SEO audit 0 problems (32 pages, sitemap 11 entries, 41 noindex) |
| Final verify | see the final report |

## 11. What only the owner can do, in order

1. **Answer the waiting request CC-10002** (a real visitor, October 13 at 6:33 pm, on a sample car): Admin > Requests
   > CC-10002 > Decline (or call the renter and offer a real car).
2. **Decide on the Workers Paid plan** (US$5 a month): Cloudflare dashboard > Workers & Pages > Plans > Workers Paid.
   Nothing in the code changes. Without it some portal page loads will keep failing with Error 1102.
3. **Enter the mailing address and the street address**: Admin > Settings > Site. Marketing emails (come-backs,
   review requests) wait until the mailing address is in, and every email footer shows it.
4. **Confirm the phone number**: the site shows 647-575-3377; check it is the CarmaCars line (Admin > Settings > Site).
5. **Replace the sample cars with the real fleet**: for each real car, the owner application or Admin > Fleet, then
   Listing > Start a listing with 8 photos > Publish; unlist each sample (Admin > Fleet > the car > Listing > Unlist).
   A real car is indexed automatically; a sample shows "Not a sample" only if it is in fact real.
6. **Logo, favicon and sharing image**: Admin > Settings > Site (logo light and dark, favicon, a 1200 by 630 sharing image).
7. **Google Search Console**: add a Domain property for `carmacars.ca`, put its TXT record in Cloudflare DNS, then
   submit `https://carmacars.ca/sitemap.xml`. Bing Webmaster Tools the same way.
8. **Google Business Profile**: create or claim it as a service-area business, then put its place id in Admin >
   Settings > Site (it fills the review link and the business markup).
9. **Stripe live mode**: in the Supabase vault set `deploy_stripe_secret_key` and `deploy_stripe_publishable_key` to the
   live keys, run the deploy (it creates the live webhook and stores its secret), and turn on Canadian pre-authorized
   debits in Stripe. Until then no real card is charged.
10. **Cloudflare**: enable R2 (Dashboard > R2) and image transformations on the zone (Dashboard > carmacars.ca >
    Images > Transformations > Enable), or give the deploy token Zone Settings edit. Needed for consistent photo
    backgrounds.
11. **Google Maps key**: add `deploy_google_maps_api_key` to the Supabase vault and deploy (address lookup, delivery by
    distance).
12. **Delivery and coverage prices**: Admin > Settings: delivery rate per km and the starting point, airport
    surcharges, coverage default prices.
13. **HST number**: Admin > Settings > Program settings `company_hst_number` once registered (receipts, invoices).
14. **Decide who pays a CarmaCars promo code**: today the owner shares it (and bears it all on a Self-Managed car).
    Before the first come-back code, decide whether CarmaCars absorbs its own promotions (a database change).
15. **Staff two-step sign-in**: once every staff member has an authenticator app, Admin > Settings > Program settings
    `require_staff_two_step` on.
16. **The official ServiceOntario PDFs** (SR-LV-006, SR-LV-012, ON00453, 013-0169, 013-1155) and **one real toll
    statement file**: send them to finish government form pre-fill and map bulk toll import.
17. **Legal**: the rental, enrollment and title agreements and the website policies are drafts until the lawyer
    approves them; the lawyer's approval of the automatic countersignature (99-traceability question 4).
18. **The monthly owner debit on the 15th** is not automated: until it is built, owners pay each monthly invoice from
    its page, and staff watch Admin > Invoices.
