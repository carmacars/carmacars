# 15. Test plan

Owner: workstream A for the tooling, each workstream for the scenarios in its area (`tests/e2e/<area>/`). The purpose of this file: the end-to-end scenarios, on a phone and on a desktop, that prove each owner requirement; the link checker; the copy lint; the accessibility checks; and the go-live checklist.

## 1. Layers

| Layer | Tool | Runs | Proves |
| --- | --- | --- | --- |
| Database rules | `scripts/test.sh` (six SQL test files, the sixth added with migration 0016) | Every push | Prices, tiers, splits, statements, status flows, row-level security, jobs, request to book |
| Text | `scripts/check-text.sh`, `node emails/check.mjs`, the copy lint (section 4) | Every push | No em dashes, brand spelling, banned phrases |
| Unit | Vitest | Every push | Form schemas, payload builders, JSON-LD builders, the situation function, calendar geometry |
| Contract | Vitest against a local database | Every push | Every server action's schema matches the database (a valid sample inserts; an invalid one is refused with a field error) |
| Emails | Render every catalogue code from a fixture | Every push | No missing variable; every link resolves |
| End to end | Playwright, two projects | Every pull request against a preview deploy; nightly against staging | Section 2 |
| Accessibility | axe in Playwright; manual passes | Pull request; before launch | Section 5 |
| Performance | Lighthouse CI | Pull request | Budgets in `14-seo.md` section 12 |
| Links | Link checker | Pull request; nightly on production | Section 3 |
| Security | Negative tests in Playwright and SQL | Pull request | `13-security.md` section 14 |

**Playwright projects.** `phone`: 390 by 844, touch, mobile user agent, slow 4G throttling for the public flows. `desktop`: 1440 by 900, mouse and keyboard. Every scenario in section 2 runs in both unless marked. A third project, `small`, at 360 by 640, runs the layout checks only.

**Test environment.** A dedicated Supabase project seeded by `tests/seed.sql`: 2 admins, one VA of each function, 2 field staff, 3 owners (individual, corporation, Turo-Only), 12 vehicles across classes and modes (one Self-Managed, one shareholder-owned, one flagged for drivers aged 18 to 20, one pair of identical twins), rate cards, 6 renters, 1 investor with an active investment, 1 insurer. Fake adapters for payments (Stripe test mode in nightly runs), storage, messaging (captures every email), tracker, photos, VIN, text generation and reading notices. Time is controlled: the app reads `now()` through a test clock header honoured only in the test environment, so reminders, expiry, the 5th, 10th and 15th can be exercised.

**Email assertions.** Tests read the captured outbox and assert the code, the recipient, the subject and that every link in the body returns 200 for that recipient.

## 2. End-to-end scenarios by owner requirement

Each scenario lists what must be true at the end. P and D mean it runs on the phone and desktop projects.

### R1. A responsive website with a phone layout and a desktop layout

| ID | Scenario | Assertions |
| --- | --- | --- |
| R1-1 | Visit every route in the sitemap of `00-overview.md` at 360, 390, 768 and 1440 px, signed in as the right role | No horizontal scroll; no overlapping or clipped text (a script compares element boxes); navigation matches the phone or desktop pattern for that portal; every primary action is visible without zoom |
| R1-2 | The same journeys complete on both projects | Every scenario below passes on P and D |
| R1-3 | Not an app | No app-store banner, no install prompt forced; the field portal's manifest exists and opens full screen when added to the home screen (manual check on iOS Safari and Android Chrome) |
| R1-4 | Orientation and zoom | The booking wizard and the signature pad work in portrait and landscape; pages work at 200% zoom |

### R2. Visually appealing, photo-heavy, scroll effects, easy, secure; red, black, white; "CarmaCars"; no broken links; not AI-sounding

| ID | Scenario | Assertions |
| --- | --- | --- |
| R2-1 | Visual regression | Screenshots of home, fleet, car, location, request, offer, sign, pay, owner home, admin calendar, field job on P and D match approved baselines within a small tolerance |
| R2-2 | Colours | A script collects computed colours on public pages: only the red, black, white and grey tokens appear outside photos and status badges |
| R2-3 | Photos | Every car page shows at least 10 photos; every image has width, height and alt text; the first image is not lazy; no image is stretched |
| R2-4 | Scroll effects | With normal motion, hero and reveal effects run; with `prefers-reduced-motion`, no element animates; no scroll listener blocks the main thread over 50 ms |
| R2-5 | Brand name | The copy lint finds no variant of the name other than "CarmaCars" in pages, emails, PDFs and metadata |
| R2-6 | Links | Section 3 passes with zero failures |
| R2-7 | Copy | Section 4 passes; a person reads every public page and every customer email once before launch and signs the checklist |
| R2-8 | Secure | `13-security.md` section 14 passes |
| R2-9 | Ease | Timed runs by three people who have not seen the product: request a booking on a phone in under 2 minutes; approve, sign and pay in under 4 minutes. Recorded in the release notes |

### R3. Request to book, never instant book

| ID | Scenario | Assertions |
| --- | --- | --- |
| R3-1 | P, D. A new visitor picks a car and dates and sends a request | No card field appears anywhere before the pay step; no Stripe script loads on the wizard; a `bookings` row exists with `status = 'requested'`; no `payments` row; the public calendar for the car is unchanged; emails `renter_account_created`, `renter_request_received`, `staff_booking_request_new` captured |
| R3-2 | Staff review the request, change the car and the return time, and send an offer | `app.adjust_booking()` recorded the changes in `booking_events`; a `booking_offers` row version 1 `sent`; booking `offered` with `offer_expires_at` 24 hours ahead; the renter's offer page highlights both changes; `renter_offer_ready` captured |
| R3-3 | The renter asks for a change; staff adjust; version 2 is sent | Booking back to `requested` then `offered`; version 1 not `sent`; version 2 `sent`; approving version 1 is refused |
| R3-4 | P. The renter approves, completes details, ticks four consents, signs with a finger, pays with a test credit card | Statuses in order `pending_payment` then `confirmed`; `signature_records` for the renter and CarmaCars; four `consents` rows with the exact wording; a signed PDF whose SHA-256 equals `documents.sha256`; one succeeded `payments` row for `renter_due_at_booking_cents`; `card_on_file_id` set; the car now shows as unavailable on its public page for those dates; `renter_agreement_signed`, `renter_booking_confirmed`, `owner_new_booking` captured |
| R3-5 | The booking is not on the public calendar until step R3-4 completes | Checked after each of: request, offer, approval, signature; only after payment is the range unavailable |
| R3-6 | Staff contact the customer | A question sent from the booking produces `renter_request_needs_info`; the renter's reply appears in the thread |
| R3-7 | Decline and expiry | Staff decline: `declined`, `renter_request_declined`. An offer left past its expiry (test clock): offer `expired`, booking back to `requested`, `renter_offer_expired`, a CS task `offer_expired` |
| R3-8 | Race | Two renters hold offers for the same car and dates; the first pays; the second's pay button reports the car is taken, nothing is charged (no captured payment), the booking is `requested` with a `reoffer_booking` task and `renter_offer_withdrawn` captured |
| R3-9 | Debit or prepaid card | Refused before any charge with the credit-card message |
| R3-10 | A forged or replayed payment webhook | Does not confirm a booking |
| R3-11 | Phone request by staff | `/admin/bookings/new` creates the same `requested` booking; the renter completes online |

### R4. Master calendar in admin; a calendar on every vehicle's page

| ID | Scenario | Assertions |
| --- | --- | --- |
| R4-1 | D. Open `/admin/calendar` with the seed fleet | Every vehicle has a row; each seeded booking and block is drawn in the right place, state and lane; pending items are hatched; a non-blocking confirmed booking is outlined |
| R4-2 | D. Drag a `requested` booking one day later and confirm | The dialog shows old and new times and totals; after confirm the booking's times and price changed through `app.adjust_booking()`; cancel leaves it untouched |
| R4-3 | D. Drag a booking with an offer out | The dialog warns that the offer will be withdrawn and re-sent; after confirm a new version exists and `renter_offer_ready` is captured |
| R4-4 | D. Drag a confirmed booking | A change request in `proposed`; the booking itself unchanged; a ghost shown |
| R4-5 | D. Drop onto a conflicting slot | Refused before the dialog with the reason |
| R4-6 | D. Keyboard | The same move done with arrow keys and Enter |
| R4-7 | P. The day list and the 3-day timeline | Today's pickups and returns listed; long-press drag moves a block; the side sheet opens on tap |
| R4-8 | Filters and search | Filter by status, class and "not blocking"; search by plate jumps to the row; the query string restores the view |
| R4-9 | Public car page calendar | Shows the confirmed booking's and the block's dates as unavailable, and nothing about who or why (the response contains only time ranges) |
| R4-10 | Admin vehicle calendar | Shows requests, offers, bookings in every status, blocks, field jobs, removed blocks (toggle) |
| R4-11 | Owner's vehicle calendar | Shows the owner's vehicles only, with first names only on managed rentals; another owner's vehicle returns 404 |
| R4-12 | Blocks | Create, edit, end and remove a block; a removed block no longer makes the car unavailable; creating one over a confirmed booking warns and raises a task |

### R5. Insurer bookings that do not block the car

| ID | Scenario | Assertions |
| --- | --- | --- |
| R5-1 | Staff create a booking billed to an insurer with provisional dates and the calendar switch off; the renter approves, signs and saves a card | Booking `confirmed` with `blocks_calendar = false`; the car's public calendar shows those dates free; a second, ordinary booking for the same dates can be confirmed |
| R5-2 | The switch | Turning it on with a free car: the range becomes unavailable publicly, a `calendar_switch` event with who and why. Turning it on over a conflict: refused with the conflicting booking listed. A blank or repeated reason: refused |
| R5-3 | "Dates are now final" | Dates corrected on the confirmed provisional booking, the price follows, the switch turns on |
| R5-4 | Handover on a non-blocking booking | Refused |
| R5-5 | Insurer invoice | Drafted at Check-in for the insurer's part; sent (`insurer_invoice` captured once that template exists; otherwise the PDF is produced); a part payment sets `part_paid`; full payment sets `paid` and the rental becomes eligible for the owner's statement |
| R5-6 | Split billing | The renter pays their part at booking; the insurer's part is invoiced |
| R5-7 | Master calendar | The booking is drawn outlined with "not blocking" and the insurer mark |

### R6. Smooth forms: owner vehicle registration and the rental agreement

| ID | Scenario | Assertions |
| --- | --- | --- |
| R6-1 | P. A new owner completes the intake for one vehicle (VIN typed, decode fills six fields, permit photo) | Under 6 minutes scripted at human typing speed; `owners`, `vehicles`, `vehicle_onboardings` rows; `owner_application_received` captured |
| R6-2 | The same owner adds a second vehicle | Only vehicle fields are asked (at most 9 typed fields); owner fields are not shown again |
| R6-3 | Each of the six situations (S1 to S6) and Turo-Only | The methods offered, the estimate shown and the form codes listed equal `onboarding_method_info`; a combination the database forbids cannot be selected |
| R6-4 | Pre-filled government PDFs | For each situation the generated PDFs contain the owner's name, address, VIN, plate, year and make in the mapped fields (text extracted from the PDF and compared); signature fields are empty; the cover page shows the estimate and "You pay these at the counter" |
| R6-5 | Registry costs | Nowhere does CarmaCars charge them: the upfront invoice has only the Install Fee and two months of Insurance Fee plus HST |
| R6-6 | Owner documents | The Enrollment Agreement is signed on screen with three separate initials; Forms C and D are downloaded pre-filled and a scan uploaded; statuses advance only in the allowed order |
| R6-7 | Autosave and resume | Start the intake on the phone project, stop at step 2, open on the desktop project signed in as the same user: the draft resumes at step 2 with all values except those marked transient |
| R6-8 | P. The rental agreement | Part 1 shows the booking's car, dates, rates, lines and totals exactly as the offer; the renter types only address and licence details; signs with a finger; the PDF matches the screen |
| R6-9 | Validation parity | For every form schema, a value the browser accepts and the server refuses does not exist (generated tests submit boundary values to both) |
| R6-10 | Offline | Drop the connection mid-form: the draft is kept, a banner shows, submit succeeds after reconnecting |

### R7. Listing a car

| ID | Scenario | Assertions |
| --- | --- | --- |
| R7-1 | P. Field staff enter a VIN and take the 14 photos | The decode fills year, make, model; photos upload with a visible queue; a `listing_jobs` row is queued |
| R7-2 | The pipeline runs with the fake adapters | Draft headline, description, features, FAQ and alt text exist; 8 exterior photos processed on the backdrop; variants written; state `needs_review` within the expected time |
| R7-3 | D. Review and publish | The reviewer edits the description, approves photos, sets the cover; the checklist blocks publishing without a rate card; after publish the car page returns 200, appears on `/cars` and in the sitemap, and `owner_vehicle_listed` is captured |
| R7-4 | A plate is entered for a car already on record | The existing vehicle loads; no VIN is asked |
| R7-5 | Failures | VIN decode fails: manual fields, pipeline continues. One photo fails four times: the listing still reaches review with that tile flagged and "Use original" works. The text draft fails: empty fields, publish still possible |
| R7-6 | An owner submits photos | The listing goes to staff review; the owner has no publish button |
| R7-7 | Waiting | A capture done before enrollment publishes itself when the vehicle is enrolled and has rates |
| R7-8 | Cost log | `provider_calls` holds one row per provider call with a cost; the per-car total is within the estimate |

### R8. Tolls, tickets and damages

| ID | Scenario | Assertions |
| --- | --- | --- |
| R8-1 | Single entry of a toll inside a rental | Auto-match to the renter at high confidence; the confirm screen shows the notice, timeline and margin; "Confirm and charge" creates the amount and $15 fee lines, charges the deposit (still held), sets `charged`, sends `renter_extra_charge` with the notice link |
| R8-2 | A ticket after the deposit was released | Charged to the Card on File with the $40 fee; a declined card adds the $40 declined-payment line once and schedules retries |
| R8-3 | A toll during a staff delivery leg | Matched to the staff member; no renter charge; logged |
| R8-4 | A toll during an Owner Booking | Billed to the owner at cost, no fee; appears as a deduction on the next statement draft; `owner_toll_ticket` captured |
| R8-5 | A toll before enrollment; a toll on a Turo-Only car | Forwarded to the owner; no charge |
| R8-6 | Bulk import of a 40-row statement file | Columns mapped once and the profile reused on a second file; duplicates skipped; rows matched; three trips for one booking produce three amount lines and one $15 fee; bulk confirm charges only high-confidence rows |
| R8-7 | Upload a notice image | Fields are pre-filled by the fake reader and marked; saving without touching a low-confidence field is refused |
| R8-8 | No match | The row stays in "To match" with an escalated finance task; `staff_toll_ticket_unmatched` is queued after 2 business days |
| R8-9 | Damage at return | Field staff mark new damage with a close-up; an incident opens; an estimate under $2,500 bills cost plus $50; an estimate of $2,500 or more bills $2,500 plus $75 and opens a fleet policy claim; statement and records sent |
| R8-10 | Damage found after return | Reported within 48 hours: `renter_damage_found` with photos. After 48 hours the button is disabled without an admin override |
| R8-11 | A duplicate notice number | Refused with a link to the existing record |

### R9. Emails for every actionable event

| ID | Scenario | Assertions |
| --- | --- | --- |
| R9-1 | Run one booking from request to review with the test clock | The captured emails, in order, include: `renter_account_created`, `renter_request_received`, `renter_offer_ready`, `renter_agreement_signed`, `renter_booking_confirmed` (with receipt), `renter_identity_needed` or the notice inside the confirmation, `renter_identity_approved`, `renter_booking_reminder`, `renter_pickup_details`, `renter_rental_started`, `renter_return_reminder`, `renter_return_complete`, `renter_final_statement`, `renter_deposit_released`, `renter_review_request`, `renter_comeback_1w`, `renter_comeback_1m` (the last three only with the consent conditions met) |
| R9-2 | Adjustment and cancellation paths | `renter_change_request_received`, `renter_change_request_approved`, `renter_booking_cancelled` with the right tier and refund |
| R9-3 | Owner month | `owner_fee_invoice` on the 15th; a failed debit sends `owner_payment_failed`; `owner_statement_ready` and `owner_payout_sent` on the 10th |
| R9-4 | Staff | `staff_booking_request_new` at once; digested notices appear in the 07:30 and 18:15 digests and not as separate emails; an urgent one is immediate |
| R9-5 | Coverage | Every catalogue code is emitted by at least one test or is on a short, reviewed list of schedule-only codes; no code is emitted that the catalogue lacks |
| R9-6 | Consent | A renter without marketing consent receives no come-back email; an unsubscribed renter receives no marketing email and still receives a booking email; one-click unsubscribe works without signing in |
| R9-7 | Cap | With the daily count forced to 95, a safety email still sends and a marketing email waits |
| R9-8 | Links | Every link in every captured email resolves for its recipient (section 3) |

### R10. Statements

| ID | Scenario | Assertions |
| --- | --- | --- |
| R10-1 | Seed the owner specification's worked month; run the 5th | A draft statement per owner; Vehicle A payable $1,144.00, Vehicle B $778.25, payout $1,922.25; the screen and the PDF show every line of `11-statements-and-reports.md` section 2.1 |
| R10-2 | Approve and pay | An admin approves; the owner cannot see the statement before approval and can after; marking the payout paid sends `owner_payout_sent`; a VA cannot approve |
| R10-3 | Company statements | Per vehicle, per owner and total for the same month: Revenue Share $1,351 and company-only fees $275 for the worked month; the vehicle rows sum to the total; the owner payouts equal the payouts table |
| R10-4 | Frozen month | After finalization, changing a source record does not change the frozen statement; the difference appears under adjustments |
| R10-5 | Exports | CSV and PDF download for each level; the accountant pack's journal balances; no export contains a licence number, card data or a bank account number |
| R10-6 | Automatic | With no person acting, the jobs on the 1st, 5th and 15th produce their records; a job run twice produces no duplicates |
| R10-7 | Investor statement | The seeded investment's monthly statement shows the Return to the cent per the agreement's Schedule B example |

### R11. SEO

| ID | Check | Assertions |
| --- | --- | --- |
| R11-1 | Every car page | Unique title, description and H1 by the patterns; self canonical; valid `Car` JSON-LD with an offer; no VIN or plate anywhere in the HTML; at least 10 images with alt text; description 120 to 220 words and under 60% similar to every other listing |
| R11-2 | Structured data | Validates against the schemas; the business node never carries a rating; rating markup appears only with 3 or more visible reviews of that vehicle |
| R11-3 | Sitemaps and robots | Every sitemap URL returns 200, is self-canonical and indexable; twins are absent; portals are disallowed and send `noindex` |
| R11-4 | Parameters | `/cars?class=suv` and a car URL with dates both canonicalize to the clean URL; HTML links to car pages carry no query string |
| R11-5 | Leaving the fleet | Unpublishing a car with a remaining model hub returns a single 301 to the hub; with nothing relevant, 410; pausing keeps 200 |
| R11-6 | Location pages | The build fails for a location page without delivery or a pickup point, with under 250 unique words, or over the similarity limit |
| R11-7 | Performance | Lighthouse budgets met on home, fleet, car, location and guide templates on the phone profile |
| R11-8 | Staging | Sends `noindex` on every response |

### R12. Portals

| ID | Scenario | Assertions |
| --- | --- | --- |
| R12-1 | Sign in as each role (renter, owner, investor, field, VA finance, VA fleet, VA CS, VA sales, admin) | Lands on the right home; sees its navigation only; every other portal's routes return 404 |
| R12-2 | Staff without the second factor | Redirected to two-step enrolment; database reads return nothing until it is done |
| R12-3 | VA limits | Finance cannot approve a payout or see a bank account number; Fleet cannot open an ID image or change a vehicle's owner; CS cannot give a staff discount; Sales cannot open a confirmed booking's money tab |
| R12-4 | Field staff, P | Sees only assigned jobs inside the time window; completes a handover with 21 photos and two signatures; the booking becomes `on_rent`; a handover with an unverified driver is stopped |
| R12-5 | Field staff, return, P | Completes the return; the booking becomes `returned`; new damage opens an incident |
| R12-6 | Owner | Sees own vehicles, bookings without renter contact details on managed rentals, invoices, an approved statement; tracker controls are blocked during a managed rental and location is still shown |
| R12-7 | Investor | Sees only their own statements and documents; no other route exists for them; the area is absent from the sitemap and navigation |
| R12-8 | Queues | A new request appears in the CS queue in real time; completing verification closes its task; an escalation appears for the admin |

## 3. Link checker

| Item | Detail |
| --- | --- |
| Tool | `tests/lint/links.ts` (the prototype's `tools/linkcheck.mjs` is the starting point) |
| What it crawls | Every public page from the sitemap and by following links; every portal page as each seeded role; every rendered email template with sample values; every generated PDF's links; `robots.txt` and the sitemaps |
| The email contract | Loads `emails/src/links.mjs` and requests every path (with sample identifiers, signed in as the right role): each must return 200 or a single redirect to a 200. A path that 404s fails the build |
| Checks | Internal links: 200, or one redirect at most; no link to a staging host; no `href="#"` or empty link; anchors exist on the target page; images and files load; `mailto:` and `tel:` are well formed and match `program_settings`. External links: 200 (checked nightly, with an allow-list for sites that block robots) |
| Redirects | Every stored row in `listing_redirects` resolves in one hop to a 200 or is a 410 |
| When | Every pull request on the preview deploy (internal only); nightly on production (internal and external), with a `staff_job_failed` notice on any failure |
| Release rule | Zero broken internal links and zero unresolved email paths |

## 4. Copy lint

`tests/lint/copy.ts`, run on source content (`content/`, component strings, `emails/src/`, PDF templates' text) and on rendered output (every public page's HTML and metadata, every rendered email, extracted PDF text).

| Rule | Detail |
| --- | --- |
| No em dash | U+2014 anywhere fails |
| No en dash used as a dash | U+2013 with a space on either side fails; number ranges are written with "to" |
| Brand name | Any of "Carma Cars", "Carmacars", "CARMACARS", "Carma cars", "carmacars" as a word (outside URLs, email addresses and code identifiers) fails. The wordmark is never inside an upper-case text transform (checked on computed styles of elements containing the name) |
| Coverage provider | A configurable blocked list (kept outside the repository's public files) fails if any term appears in copy, alt text, metadata, emails or PDFs |
| Banned phrases | A list of stock phrases that read as machine-written or as filler, for example "look no further", "elevate your", "seamless experience", "in today's world", "whether you are", "unlock", "nestled", "your journey", plus the list the email checker already enforces |
| Placeholders | "[●]", "TBD", "Lorem", "to be confirmed" in any rendered page, email or PDF fails (the email catalogue's sample address currently contains "to be confirmed"; the real address must be set before launch) |
| Claims | "Best", "cheapest", "#1", "guaranteed" fail on public pages |
| Punctuation | No exclamation marks in customer copy; straight ASCII quotes in emails; no double spaces |
| Listing text | Applied to every listing draft before it can be saved and again before publish (`09-listing-pipeline.md` section 5.3) |
| Names | The lint cannot judge tone. A person reads every public page, every customer email and one sample of each PDF before launch |

`scripts/check-text.sh` keeps covering `docs/`, `supabase/` and `src/` for dashes.

## 5. Accessibility

Target: WCAG 2.2 level AA on every route.

| Check | How |
| --- | --- |
| Automated | axe runs in Playwright on every route in both projects, in each main state (empty, filled, error, dialog open). Zero serious or critical findings is a release rule |
| Keyboard | Scripted: complete the booking request, offer approval, signing (typed signature), payment, owner intake, a calendar move, a toll confirm and a statement approval with the keyboard only. Focus is always visible and never trapped; Esc closes dialogs and returns focus |
| Screen reader | Manual, before launch: VoiceOver on iOS Safari and NVDA on Windows Chrome through the booking request, offer, signing, payment and the owner intake. Each form field, error, step change and status update is announced |
| Contrast | Tokens are checked in unit tests (red on white, white on red, greys on white and black); status badges and calendar states carry a pattern or label as well as colour |
| Targets | Interactive elements are at least 44 by 44 px (48 px primary, 56 px in the field portal), measured by script |
| Zoom and reflow | 200% zoom and 320 px width without loss or horizontal scrolling, except the desktop master calendar timeline, which has the day list as its reflow alternative |
| Motion | No animation under reduced motion; nothing flashes |
| Forms | Labels, groups, autocomplete tokens, error summary and focus management as `08-forms.md` section 11 |
| Signature | The typed-name method is tested as the equivalent of drawing |
| Media | Every photo has alt text; decorative images have empty alt; the gallery lightbox is operable by keyboard |
| Documents | Generated PDFs have a title, language, reading order and real text (not images of text) |
| Language | `lang="en-CA"` on every page |
| Timing | The offer deadline is announced, and a renter can ask for more time |

## 6. Other checks before launch

| Area | Check |
| --- | --- |
| Payments | In Stripe test mode: authorize and capture, a declined card, 3-D Secure, a refund, a deposit hold placed, renewed, captured in part and released, a Card on File charge off-session, a dispute event, a debit mandate and a failed debit |
| Time | Daylight-saving change on November 1, 2026 falls two weeks after launch: a booking across it bills whole days; jobs run once |
| Jobs | Each scheduled job runs on its day with the test clock, records `job_runs`, and a second run does nothing |
| Retention | An ID image past its date is purged; one on legal hold is kept |
| Backups | Restore test done and dated (`13-security.md` section 13) |
| Load | The public site at 20 requests a second for 5 minutes stays under the Worker CPU limit with no errors (cached pages); the quote function at 10 a second |
| Browsers | Current Safari on iOS, Chrome on Android, Chrome, Safari, Firefox and Edge on desktop. Camera capture and the signature pad are tested on two real phones |
| Data import | If manual records from before the platform are imported, row counts and three sample bookings are checked by hand |

## 7. Go-live checklist

| # | Item | Owner | Done |
| --- | --- | --- | --- |
| 1 | `scripts/test.sh`, `scripts/check-text.sh`, `node emails/check.mjs` pass on the release commit | A | |
| 2 | All R-scenarios pass on phone and desktop against staging; exceptions listed with the cut-line items of `00-overview.md` section 10 | All | |
| 3 | Link checker: zero broken links; every email path resolves | A | |
| 4 | Copy lint passes; a person has read every public page and customer email | B, writer | |
| 5 | Accessibility: zero serious automated findings; the two screen reader passes done | A | |
| 6 | Security checklist of `13-security.md` section 14 complete, each line initialled | A | |
| 7 | Production secrets set from GitHub; Stripe live keys in production only; webhooks registered and verified with a live $1 test that is refunded | A, C | |
| 8 | Migrations 0001 to the latest applied to production in order; `cron.job` shows every schedule; the first admins exist with two-step sign-in | DB | |
| 9 | `program_settings` filled: company address, phone, incident line, email, HST number or the accountant's written confirmation that none is needed yet, privacy officer, opening hours; Ontario holidays loaded | Admin | |
| 10 | Lawyer-approved texts loaded as templates: Rental Agreement, Enrollment Agreement, Title Agreement and Forms A to E, website terms, privacy policy, cancellation policy, the four consent statements word for word, the debit agreement. No "[●]" anywhere | Admin, E | |
| 11 | Government form templates loaded and their fixtures pass, or the data-sheet fallback is switched on for the forms not yet mapped | E | |
| 12 | Email: `carmacars.ca` verified in Resend with SPF, DKIM and DMARC; the four sender addresses work; replies reach `info@carmacars.ca`; Supabase Auth sends through it; Stripe's own receipt emails are off | F | |
| 13 | At least the launch fleet published: each car with a rate card, 10 or more approved photos, a reviewed description, a baseline Condition Report, a reporting tracker | F, Fleet | |
| 14 | Staff accounts created with the right functions and limits ($0 for the first month); field staff have tested the handover on their own phones | Admin | |
| 15 | DNS: `carmacars.ca` and `www` to the production Worker; the image domain to the public bucket; `staging` behind authentication with `noindex` | A | |
| 16 | Search Console and Bing verified; sitemap submitted; Cloudflare Web Analytics on; Business Profile verification started | B | |
| 17 | Backups: last night's file exists; restore test dated; keys in the password manager | A | |
| 18 | Monitoring: a failed job, a stuck outbox row and a failed nightly link check each reach the admins (tested by forcing each once) | A, F | |
| 19 | The 24-hour incident line number on the site, the agreement and the emails is answered | Admin | |
| 20 | A full rehearsal on production with a real card and a staff member as renter: request, offer, approve, sign, pay, verify, deposit, handover, return, statement, release, review; then refunded and the test records marked | Admin, all | |
| 21 | Rollback plan: the previous Worker version can be restored in one command; migrations in this release are additive | A | |
| 22 | The open questions in `99-traceability.md` section 4 are each answered or accepted at their default, in writing | Owner | |
