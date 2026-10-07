# 00. Overview

The build blueprint for the CarmaCars platform (carmacars.ca), operated by 18122211 Canada Inc., launching October 15, 2026. Read this file first. Every other file in this folder assumes the conventions in sections 2 and 9.

Sources of truth, in order: the owner's requirements (quoted in `99-traceability.md`), then `docs/source/` (agreements, billing specifications, procedures), then `docs/data-model.md` and the migrations. Where this blueprint needs something the database does not have yet, the file says so under "Database additions needed". Nothing in this folder pretends a table or function exists when it does not.

## 1. Principles

| # | Principle | What it means in the build |
| --- | --- | --- |
| 1 | The database holds the rules | Prices, cancellation tiers, splits, statements and status changes are SQL functions. TypeScript calls them and never re-computes money |
| 2 | Request, never instant | A renter never pays or gives a card to ask for a car. Staff confirm and send an offer. The renter approves, signs and pays. Only then is the booking confirmed (`02-booking-and-renter.md` section 2) |
| 3 | Static first | The free Cloudflare Workers plan allows 10 ms of processing per request. Public pages are built ahead of time and cached. Portal pages are static shells that load data in the browser straight from Supabase under row-level security. The Worker runs only server actions |
| 4 | Enter once | A fact typed once (owner name, VIN, licence number, booking dates) pre-fills every later form, agreement and government PDF (`08-forms.md`) |
| 5 | Phone and desktop are both first class | Every route has a phone layout and a desktop layout. The field portal is designed for one hand |
| 6 | Money moves on the server only | A browser session can never charge, refund, release or pay out. Those are server actions that call functions executable by `service_role` only |
| 7 | Every event is written down | Status changes go to `status_history`, row changes to `audit_log`, every message to `messages` |
| 8 | Every actionable event sends an email | The event catalogue in `12-notifications.md` is the contract between the app and the templates |
| 9 | No fixed monthly fees | Every outside service is pay per use or free at launch volume (`docs/decisions/0001-zero-fixed-fee-stack.md`) |
| 10 | Plain, human copy | The name is always "CarmaCars". No em dashes. No filler sentences. A lint enforces both (`15-test-plan.md` section 4) |
| 11 | The coverage provider is never named | Not in copy, code, data, alt text or email |

## 2. Conventions used in every file

### 2.1 Notation

| Notation | Meaning |
| --- | --- |
| `table.column` | Where a field is stored |
| `app.fn()` | A database function that exists in migrations 0001 to 0015 |
| `app.fn()` **[new]** | A function this blueprint needs that is not in the database yet. It is listed again under "Database additions needed" in that file and consolidated in `99-traceability.md` |
| `[0016]` | Provided by migration 0016 (section 8) |
| `actionName` | A Next.js server action in `src/server/actions/<area>/` |
| R / W / A | Read, write, approve |
| P / D | Phone layout (under 768 px wide) / desktop layout (1024 px and wider). Between the two, the phone layout widens to two columns |

### 2.2 Standard states (apply to every route unless the route says otherwise)

| State | Behaviour |
| --- | --- |
| Loading | The page shell (header, navigation, headings) is in the static HTML. Data areas show skeleton blocks of the final size, so nothing shifts when data arrives. No spinner on a full page |
| Empty | One sentence that says what would appear here and one button for the action that creates it. Never a blank table |
| Error, read | Inline panel in place of the data: "We could not load this. Try again." with a Retry button. The error id from the response is shown in small text for support |
| Error, write | The form stays filled. A summary at the top lists each problem and links to the field. Field errors appear under the field. A database refusal (for example a status change that is not allowed) shows the database's own message, which is written in plain English |
| Offline | A banner: "You are offline. Changes will be saved when you reconnect." Forms keep their draft locally (`08-forms.md` section 3) |
| Not allowed | A signed-in user without the role sees a 404 page, not a 403, so route names are not disclosed |
| Stale | When a row changed since it was loaded (compare `updated_at`), a save is refused with "This record changed while you were editing. Reload to see the latest." |

### 2.3 Server action contract

Every server action:

1. Reads the session and checks the role with `requireRole()` (`src/lib/auth/guards.ts`).
2. Validates the input with the form's Zod schema (the same schema the browser used).
3. Checks Turnstile for public actions.
4. Calls one database function or performs one write. Multi-step work is one SQL function so it is one transaction.
5. Emits its events with `emit(eventKey, payload)`, which inserts into `notification_outbox` **[new]** in the same transaction where possible.
6. Returns `{ ok: true, data }` or `{ ok: false, code, message, fieldErrors }`. It never throws to the browser.
7. Passes `request_id` and the IP address to the database (`set_config('app.request_id', ...)`) so `audit_log.request_id` and `audit_log.ip_address` are filled.

### 2.4 Rendering rules for the 10 ms limit

| Kind of page | How it is rendered | Data |
| --- | --- | --- |
| Public content (home, fleet, car, location, guide, policy) | Static at build, revalidated on demand with `revalidateTag` when a listing, rate or review changes. Served from the Cloudflare cache | Read at build with the anon key from `public_vehicle_listings` and the public views |
| Live availability and quotes on public pages | In the browser | Supabase RPC called from the browser with the anon key: `app.public_vehicle_calendar()` `[0016]` through a `public` wrapper **[new]**, `app.quote_booking()` **[new]** |
| Portals | Static shell per route (no per-request server rendering). The shell checks the session in `middleware.ts` using only a signature check on the session cookie | The browser reads through `supabase-js` with the user's token; row-level security filters |
| Mutations | Server actions | Service role after the role check, or the user's own token for ordinary staff edits |
| Heavy work (PDF, image, email, Stripe calls in bulk) | Supabase Edge Functions, started by the action or by `pg_cron` | Service role |

Rules that follow: no `getServerSideProps`-style per-request rendering of lists; no PDF or image work in the Worker; no ORM (use `supabase-js` and generated types); no client bundle over 170 KB compressed on public routes.

## 3. Roles

| Role | Stored as | Area | Sign-in |
| --- | --- | --- | --- |
| Visitor | none | Public site | none |
| Renter | `user_roles.role = 'renter'`, `renters.user_id` | `/account` | Email link or password |
| Owner | `user_roles.role = 'owner'`, `owners.user_id` | `/owner` | Email link or password; two-step optional |
| Investor | `investors.user_id` (no role enum value; the guard is `app.is_my_investor()`) | `/investor` | Email link plus two-step, by invitation only |
| Field staff | `user_roles.role = 'field'`, `staff_profiles.field_function` | `/field` | Invitation; password plus two-step |
| VA Finance and Billing | `role = 'va'`, `staff_profiles.va_function = 'finance'` | `/va/finance` | Invitation; password plus two-step |
| VA Fleet Operations | `va_function = 'fleet'` | `/va/fleet` | same |
| VA Customer Service and Growth | `va_function = 'cs'` | `/va/cs` | same |
| VA Sales | `va_function = 'sales'` | `/va/sales` | same |
| Admin | `role = 'admin'` | `/admin` | Invitation; password plus two-step, always |

A user may hold several roles (an owner who rents, a field staff member who refers). The account menu shows a "Switch area" list of the areas the user can open. The full permission matrix is `docs/permissions.md`.

## 4. Sitemap of the whole product

```
/                                   Home
/cars                               Fleet (filters in the query string)
/cars/[slug]                        Car page
/car-rental/[category]              Category page (economy, suv, luxury, electric, 7-seater, ...)
/car-rental/toronto                 City page (hub)
/car-rental/toronto/[neighbourhood] Neighbourhood page
/car-rental/[city]                  Other GTA city pages (mississauga, brampton, vaughan, ...)
/airport/[code]                     Airport page (yyz, ytz)
/long-term-car-rental               Monthly rentals
/insurance-replacement              Rentals billed to insurers
/list-your-car                      Owner programme landing page
/list-your-car/apply                Owner intake form (public)
/how-it-works                       Request, offer, sign, pay
/reviews                            All published reviews
/guides, /guides/[slug]             Guides
/about, /contact, /faq
/terms, /privacy, /cancellation-policy, /rental-agreement (sample)
/unsubscribe/[token]                One-click unsubscribe
/r/[code]                           Referral link (stores the code, redirects to /cars)
/go/[token]                         Signed deep links from emails (offer, upload, pay)

/sign-in, /sign-up, /sign-in/verify, /reset-password, /two-step

/book/[slug]                        Booking request wizard
/book/sent/[bookingNumber]          Request received

/account                            Renter home
/account/bookings, /account/bookings/[id]
/account/bookings/[id]/offer        Review and approve the offer
/account/bookings/[id]/sign         Sign the rental agreement
/account/bookings/[id]/pay          Pay
/account/bookings/[id]/verify       Licence, selfie, coverage proof
/account/bookings/[id]/extend       Ask for an extension
/account/bookings/[id]/cancel       Cancel
/account/bookings/[id]/photos       Unattended or renewal photo set
/account/bookings/[id]/review       Leave a review
/account/drivers, /account/payment, /account/documents, /account/statements
/account/tolls-and-charges, /account/profile, /account/notifications

/owner                              Owner home
/owner/onboarding, /owner/onboarding/[vehicleId]/[step]
/owner/vehicles, /owner/vehicles/[id] (overview, calendar, bookings, listing, tracker, documents)
/owner/vehicles/new                 Add a vehicle (wizard)
/owner/bookings, /owner/bookings/new (Owner Booking, or a Self-Managed rental)
/owner/invoices, /owner/statements, /owner/statements/[id], /owner/payouts
/owner/claims, /owner/referrals, /owner/documents, /owner/profile, /owner/banking

/investor                           Investor home
/investor/statements, /investor/statements/[id], /investor/documents, /investor/profile

/field                              Today's jobs
/field/jobs/[id]                    Job detail and checklists (handover, return, detail, shoot, tracker)
/field/list-a-car                   Listing capture
/field/report                       Report damage or a problem
/field/referrals, /field/profile

/va/finance, /va/fleet, /va/cs, /va/sales   One queue home per function (see 05-va.md)

/admin                              Dashboard
/admin/requests                     Booking request inbox
/admin/bookings, /admin/bookings/new, /admin/bookings/[id]
/admin/calendar                     Master calendar
/admin/vehicles, /admin/vehicles/new, /admin/vehicles/[id]
/admin/listings                     Listing review queue
/admin/owners, /admin/owners/[id], /admin/onboarding
/admin/renters, /admin/renters/[id]
/admin/insurers, /admin/insurers/[id], /admin/insurer-invoices, /admin/insurer-invoices/[id]
/admin/money/payments, /deposits, /refunds, /disputes, /charges
/admin/tolls, /admin/tolls/import, /admin/tolls/[id]
/admin/incidents, /admin/incidents/[id], /admin/claims, /admin/claims/[id]
/admin/owner-billing/invoices, /admin/statements, /admin/statements/[id], /admin/payouts
/admin/reports                      CarmaCars' own statements: vehicle, owner, total
/admin/investors, /admin/investors/[id]
/admin/reviews, /admin/promo-codes, /admin/messages
/admin/tracker, /admin/fleet-report
/admin/staff, /admin/settings/*, /admin/audit, /admin/jobs, /admin/approvals
```

**Identifiers in URLs.** `[id]` in a booking route is the booking number (`CC-10482`), in an invoice route the invoice number, in a statement route the statement number, in an incident route the incident number; vehicles, owners, renters, jobs and tolls use their ids. This matches the links in the email templates. The email templates also use a few path names that differ from this sitemap (for example `/account/bookings/[id]/agreement` for the signing screen); each is provided as a redirecting alias, listed in `12-notifications.md` section 4.4, so no emailed link is ever broken.

VA routes mirror admin routes under `/va/<function>/...` for the screens that function may open. They are the same components with a narrower permission set, not copies (section 6).

## 5. Navigation for each portal

| Portal | Phone | Desktop |
| --- | --- | --- |
| Public | Top bar: logo, "Cars", menu button. Menu sheet: Cars, Locations, Long-term, List your car, How it works, Sign in. Sticky bottom bar on car pages: price and "Request to book" | Top bar: logo, Cars, Locations (mega menu), Long-term, List your car, How it works, Sign in. Footer: four columns (Rent, Locations, Company, Legal) |
| Renter | Bottom tab bar: Trips, Documents, Charges, Profile. The active booking's next step is a full-width card at the top of Trips | Left rail with the same four items plus Drivers, Payment, Notifications |
| Owner | Bottom tab bar: Home, Vehicles, Money, More. "Add a vehicle" is a floating button on Vehicles | Left rail: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Claims, Referrals, Documents, Profile |
| Investor | Top bar only: Statements, Documents, Profile | Same |
| Field | Bottom tab bar: Today, List a car, Report, Me. No side navigation anywhere | Same layout centred at 480 px |
| VA | Top bar: queue name, search, notifications. Bottom tab bar: Queue, Calendar, Search, More | Left rail grouped by the function's sections; right panel for the open task |
| Admin | Top bar: search, approvals count, notifications. Bottom tab bar: Today, Requests, Calendar, Money, More | Left rail groups: Today, Bookings (Requests, Bookings, Calendar), Fleet (Vehicles, Listings, Tracker), People (Owners, Onboarding, Renters, Insurers, Investors, Staff), Money (Payments, Deposits, Refunds, Charges, Tolls, Claims, Owner billing, Statements, Payouts, Reports), Growth (Reviews, Promo codes, Messages), System (Settings, Audit, Jobs) |

A global search (`/` on desktop, the magnifier on a phone) is available to staff. It searches booking number, plate, VIN, fleet number, owner name and notice number. A renter search goes through `app.staff_find_renter()` (at most 10 names, logged).

## 6. Shared components

All live in `src/components/`. Staff screens are composed from feature components in `src/features/<feature>/` that take a `capabilities` object, so the admin and VA portals render the same component with different buttons.

| Component | Used by | Notes |
| --- | --- | --- |
| `AppShell` (public, portal, field variants) | all | Header, navigation, skip link, toasts, offline banner |
| `DataTable` | staff | Server-paged (50 rows), column sort, saved filters in the query string, CSV export button where the role may export. On a phone each row becomes a card |
| `SidePanel` | staff | Slides from the right on desktop, full-screen sheet on a phone. Deep-linkable with `?panel=` |
| `StatusBadge` | all | One colour map for every status (section 7) |
| `Money` | all | Formats integer cents as CAD. Never does arithmetic |
| `DateTimeTO` | all | Shows Toronto time, with the zone named when the viewer's device is in another zone |
| `Form`, `Field`, `Wizard`, `Autosave` | all | `08-forms.md` |
| `PhotoCapture`, `PhotoSet` | field, owner, renter | Guided fixed-order capture, upload queue, retake |
| `LicenceCapture`, `SelfieCapture` | renter, field | `08-forms.md` section 7 |
| `SignaturePad`, `SignDocument` | renter, owner, field, investor | `08-forms.md` section 8 |
| `DocumentViewer` | all | Opens a short-lived signed link; PDF in a frame, images in a lightbox |
| `Calendar` (`MasterCalendar`, `VehicleCalendar`, `PublicAvailability`) | admin, VA, owner, public | One engine in `src/features/calendar/`; see `03-admin.md` section 5 |
| `PriceBreakdown` | public, renter, staff | Renders line items returned by the database; no arithmetic |
| `Timeline` | staff, renter | Merges `status_history`, `messages` and `audit_log` entries for a record |
| `ApprovalBar` | admin, finance | Approve or reject with a reason; shows the limit that applies |
| `ConfirmDialog` | all | Every money action and every destructive action confirms with the amount and the record number typed out |
| `Gallery`, `Parallax`, `Reveal` | public | Image components and the scroll effects (`01-public-site.md` section 2) |
| `Turnstile` | public forms | Invisible mode; visible challenge only when Cloudflare asks |
| `EmptyState`, `Skeleton`, `ErrorPanel` | all | Section 2.2 |

## 7. Design system

The visual source of truth is the prototype being built in parallel in `prototype/` (tokens in `prototype/assets/css/tokens.css`, components in `core.css`, a style guide page, and its own design notes). Workstream A ports those tokens and components into `src/components/` unchanged; where this table and the prototype differ, the prototype wins. The email templates use their own close red (`emails/src/brand.mjs`) for email clients.

| Token | Value (from the prototype) | Use |
| --- | --- | --- |
| `--red-600` | `#D0111B` | CarmaCars red: primary buttons, links on white, active states. White text on it passes WCAG AA (about 5.6 to 1) |
| `--red-700` | `#A30C14` | Hover and pressed |
| `--red-400` | `#FF4D52` | Red text and rules on black |
| `--black`, `--white` | `#000000`, `#FFFFFF` | Text, dark sections, backgrounds |
| Greys | `--grey-950` to `--grey-50`, true neutral | Surfaces, hairlines, secondary text (`--grey-600` on white, `--grey-400` on black). No other colours in the brand |
| Status colours | Used only inside badges and the calendar, never as brand colours, and always with a pattern or label | Requested: grey hatched. Offered: amber hatched. Signing and payment: amber hatched, filled edge. Confirmed: black. On rent: red. Returned: grey. Closed: light grey. Cancelled or declined: struck through. Block: diagonal stripes. Not blocking: outline only |
| Type | Headings: Heros Condensed Bold (`--font-display`), tight line height. Body and UI: Inter 400, 500, 600 (`--font-text`). Self-hosted with `next/font/local`, `font-display: swap`, converted to WOFF2 and subset to Latin | No third-party font request |
| Type scale | The prototype's fluid `clamp()` scale (`--fs-hero` to `--fs-2xs`) | |
| Radius | Square corners on photos; small radius on inputs and buttons as in the prototype | |
| Spacing | 4 px grid; section padding 64 px phone, 120 px desktop | |
| Touch targets | 44 px minimum (the prototype's `--cell`), 48 px for primary actions, 56 px in the field portal | |
| Photography | Every car on the same backdrop from the pipeline (`09-listing-pipeline.md`). Full-bleed, 3:2 for exteriors, 4:3 for interiors | |
| Motion | 200 ms ease-out for interface; scroll effects in `01-public-site.md` section 2. All motion is removed under `prefers-reduced-motion` | |
| Wordmark | "CarmaCars", one word, capital C twice, set as text. The lint rejects "Carma Cars", "Carmacars", "CARMACARS" in copy; the wordmark is never placed inside an upper-case style | |

## 8. Migration 0016 as shipped

Migration `0016_request_to_book.sql` landed while this blueprint was being written. Its own record is `docs/changes/0016_request_to_book.md`; that file wins on any detail. The blueprint files use its real names. The older documents (`README.md`, `docs/data-model.md`, `docs/permissions.md`, `docs/architecture.md`) still describe the hold-based flow and are out of date on these points.

| Topic | What 0016 provides |
| --- | --- |
| Flow | `requested -> offered -> pending_payment -> confirmed -> on_rent -> returned -> closed`. A request that does not go ahead ends in `declined`, whoever said no. `cancelled` and `no_show` keep their meaning for confirmed bookings. `tentative` is no longer used |
| What blocks the car | Only a `confirmed` or `on_rent` booking with `blocks_calendar = true`. A request, an offer and a booking awaiting signature and payment never block. Several requests and offers for the same car and dates may coexist |
| When one is confirmed | Every other `offered` or `pending_payment` booking on the same car and overlapping dates goes back to `requested`, its open offer is marked `withdrawn`, and CS gets a `reoffer_booking` task (urgent if a payment had been taken) |
| Offers | `booking_offers`: one immutable row per version sent: `version, status (sent, approved, change_requested, declined, expired, superseded, withdrawn), sent_by, sent_at, expires_at, message, vehicle_id, pickup_at, return_at, billable_days, rental_charge_cents, discount_cents, deposit_cents, subtotal_cents, hst_cents, total_cents, insurer_share_cents, renter_due_cents, terms jsonb, line_items jsonb, responded_at, responded_by, response_note`. There is no draft offer: staff adjust the booking itself while it is `requested`, then send. While an offer is out the booking's terms cannot change; staff withdraw it first |
| Expiry | `program_settings.offer_expiry_hours` (default 24, 1 to 720); `bookings.offer_expires_at`. An expired offer puts the booking back to `requested` (not to a dead end) with an `offer_expired` task for CS. A booking in `pending_payment` does not expire. Job `carmacars-offers-expire` runs `app.job_offers_expire()` every 5 minutes |
| History | `booking_events` (append-only): requested, adjusted, offer_sent, offer_approved, change_requested, declined, offer_withdrawn, offer_expired, pushed_back, calendar_switch, promo_applied, promo_removed, each with the actor type |
| Functions (server role only) | `app.request_booking(renter, vehicle, pickup, return, type, note, source, created_by, referred_by, promo_code, pickup_method, return_method, pickup_place, return_place)`; `app.adjust_booking(booking, by, changes jsonb, note)`; `app.reprice_booking(booking)`; `app.send_offer(booking, sent_by, message, expires_at)`; `app.approve_offer(booking, version, by, now)`; `app.request_offer_change(booking, by, note)`; `app.decline_booking_request(booking, by, note)`; `app.withdraw_offer(booking, by, note)`; `app.set_blocks_calendar(booking, blocks, by, reason)`; `app.expire_offers()` |
| Calendar switch | `bookings.blocks_calendar` (default true), with `blocks_calendar_changed_at`, `_changed_by`, `_reason`. Every flip needs who and a new reason. Turning it on runs the same availability check as confirmation |
| Availability and calendars | `app.vehicle_is_available(vehicle, from, to, ignore_booking)`; `app.public_vehicle_calendar(vehicle, from_date, to_date)` returning merged unavailable stretches with no reason (anonymous may call it); view `calendar_entries` and `app.master_calendar(from, to)` for staff and owners (`calendar_state`: pending, booked, out, done, void, blocked; `is_blocking`). Sales sees first names only; an owner sees own vehicles with first names, no insurer and no note. Turo trips and field jobs are not in it |
| Calendar blocks | `vehicle_calendar_blocks` gains `removed_at`, `removed_by`, `removed_reason`, `updated_at`. A block is removed by marking it. Blocks are not checked against existing bookings when created |
| Insurer billing | `insurers (name, billing_contact_name, billing_email, billing_phone, billing_address, notes, is_active)`. On `bookings`: `bill_to ('renter', 'insurer', 'split')`, `insurer_id`, `insurer_claim_number`, `insurer_adjuster_name`, `_email`, `_phone`, `insurer_authorized_daily_rate_cents`, `insurer_authorized_days`, `insurer_authorized_until`, `dates_provisional`, `insurer_share_cents`, `insurer_hst_cents`, `renter_due_at_booking_cents` (generated). `app.booking_insurer_share()` works out the insurer's part. A booking where the renter owes nothing at booking is confirmed without a card payment; a saved card is still required |
| Insurer invoices | `insurer_invoices (invoice_number 'INS-...', booking_id, insurer_id, claim_number, period_start, period_end, amount_cents, hst_cents, total_cents, status (draft, sent, part_paid, paid, written_off), lines jsonb, sent_at, paid_cents, balance_cents, paid_at, last_payment_reference, write-off fields, document_id, notes)`; `app.draft_insurer_invoice(booking, by)`; `app.record_insurer_payment(invoice, amount, by, method, paid_at, reference)` |
| Discounts | `bookings.staff_discount_cents` with a reason (admin only); `promo_code_id`, `promo_discount_cents`. Charge types `staff_discount` and `promo_discount`, both classed as Owner Revenue, so a discount lowers Owner Revenue and is shared in the proportion of the split |
| Promo codes | `promo_codes (code, description, percent_bps or amount_cents, valid_from, valid_until, max_uses, once_per_renter, renter_id, source ('followup_7d', 'followup_30d', 'manual', ...), is_active)`; `promo_redemptions (status applied, redeemed, released)`; `app.promo_code_problem(code, renter, booking, at)`, `app.apply_promo_code(booking, code, by)`, `app.remove_promo_code(booking, by)` |
| Reviews | `reviews (booking_id unique, renter_id, vehicle_id, rating, title, body, status (pending, published, hidden), staff_reply, published_at)`; `app.submit_review(booking, by, rating, title, body)` only for a `closed` booking; `app.public_reviews(vehicle, limit, offset)` returns published reviews with the reviewer's first name and the month |
| Booking numbers | `CC-` plus a sequence starting at 10001 |
| Tasks it creates | `booking_request`, `reoffer_booking`, `offer_expired` in the `cs` queue |
| Left to the app | Sending every email; fee lines other than delivery and pickup (young driver, additional driver, extras, coverage sold) are entered by the app, and `app.reprice_booking()` adds them into the totals; refunds for a paid booking that is pushed back; exposing the public functions to the browser (the `app` schema is not exposed, so thin wrappers in `public` are needed) |

Where a blueprint file still marks something `[0016]`, it means "provided by migration 0016" and the name is the real one.

## 9. Repository layout and directory ownership

Six engineers, six workstreams. A workstream owns its directories outright. Nobody edits a file outside their directories; they ask the owner or open a small pull request that the owner merges. Shared contracts (types, schemas, events) live in directories owned by workstream A and change only by pull request reviewed by the workstream that needs the change.

```
src/
  app/
    (public)/           B   public site, SEO pages, sitemap, robots
    (auth)/             A   sign-in, sign-up, reset, two-step
    book/               C   booking request wizard
    account/            C   renter portal
    owner/              E   owner portal and onboarding wizard
    investor/           E   investor area
    admin/              D   admin portal (route files only; they compose features)
    va/                 F   VA portals (route files only)
    field/              F   field portal
    go/, r/, unsubscribe/   A   signed links, referral links, unsubscribe
  components/           A   design system and shared components (section 6)
  lib/                  A   auth guards, supabase clients, money, dates, env, logging
  integrations/         A   payments, storage, messaging, identity, signing, tracker, photos, vin, llm, ocr, turo
  server/actions/
    booking/, renter/   C
    admin/, finance/    D
    owner/, investor/   E
    fleet/, field/, listing/, cs/   F
  features/
    booking/            C   request wizard, offer, quote, extension, cancellation
    payments/           C   pay page, deposits, refunds UI, card on file
    calendar/           D   calendar engine and the three calendar views
    bookings-admin/     D   request inbox, booking review and adjust
    money/              D   payments, deposits, refunds, disputes, charges screens
    tolls/              D   tolls, tickets, import, matching
    incidents/          D   incidents, damages, claims
    statements/         D   owner statements, payouts, company reports, exports
    insurers/           D   insurers and insurer invoices
    owners/             E   owner records, onboarding wizard, government PDFs
    forms/              E   form system (08-forms.md), signature pad, capture components' logic
    documents/          E   PDF templates, field maps, document viewer logic
    investors/          E   investor records and statements
    listing/            F   listing pipeline, review screen
    field-jobs/         F   jobs, condition reports, photo sets
    queues/             F   VA task queues
    notifications/      F   event catalogue, outbox client, in-app notices, preferences
    seo/                B   metadata builders, JSON-LD builders, internal link helpers
    reviews/            B   review display, review request page (with C for the form)
content/                B   location pages, guides, FAQs (MDX with typed front matter)
emails/                 (writer)  templates and emails/catalogue.json
supabase/
  migrations/           database engineer only; app engineers request changes (below)
  functions/
    stripe-webhook/     C
    tracker-webhook/    F
    render-document/    E   PDF rendering
    photo-worker/       F   listing photo pipeline
    send-outbox/        F   email sender and digests
    jobs-*/             the workstream that owns the feature the job serves
tests/
  e2e/                  each workstream owns tests/e2e/<its area>/
  lint/                 A   copy lint, link checker
docs/blueprint/         product architect
```

| Workstream | Engineer | Owns | Blueprint files |
| --- | --- | --- | --- |
| A. Platform | 1 | App scaffold, design system, auth and two-step, guards, integrations and their fake adapters, security headers, CI, deploy, backups, lint and link checker | 00, 13, 15 |
| B. Public and SEO | 2 | Public site, content, structured data, sitemaps, reviews display, Core Web Vitals | 01, 14 |
| C. Booking and renter | 3 | Request wizard, offer approval, signing flow for the rental agreement, payment, renter portal, Stripe webhook | 02 |
| D. Admin and finance | 4 | Admin shell, request inbox, booking review, calendars, money screens, tolls, incidents and claims, statements, payouts, insurers, reports | 03, 10, 11 |
| E. Owners, forms, documents | 5 | Form system, signature and capture logic, PDF templates and rendering, owner portal, onboarding wizard, investor area | 04, 07, 08 |
| F. Operations | 6 | VA portals and queues, field portal, listing pipeline, notifications outbox and jobs, tracker screens | 05, 06, 09, 12 |

**Database changes.** Only the database engineer writes migrations. An app engineer who needs a table, column, view or function adds a row to `docs/blueprint/99-traceability.md` section 3 (already seeded with everything this blueprint needs) and the database engineer ships it in the next numbered migration with row-level security, the admin policy, the audit trigger and a test. Generated TypeScript types (`src/lib/db/types.ts`) are regenerated by CI after each migration and are never edited by hand.

## 10. Build order

Launch is October 15, 2026. Today is October 7. That is six working days, so the order is strict and the cut line is explicit. Each day ends with a deploy to staging.

| Day | A. Platform | B. Public | C. Booking | D. Admin | E. Owners and forms | F. Operations |
| --- | --- | --- | --- | --- | --- | --- |
| 1 (Oct 8) | Scaffold, deploy pipeline, auth, guards, design tokens, `AppShell`, fake adapters | Home, fleet and car page from seed data; image component | Quote RPC wiring; request wizard steps 1 to 3 | Admin shell, `DataTable`, request inbox list | Form system core: schema, `Field`, `Wizard`, autosave | Outbox table client, `emit()`, first three emails; field shell |
| 2 (Oct 9) | Storage adapter (R2 signed uploads), `PhotoCapture`, Turnstile, security headers | Car page complete with calendar and JSON-LD; policies | Request submit, account creation, request received page | Booking review and adjust; send offer | `SignaturePad`, `SignDocument`, `render-document` function with the rental agreement template | Listing capture (VIN decode, photo upload), photo worker with the fake adapter |
| 3 (Oct 10) | Payments adapter (Stripe), two-step for staff, rate limits | Category, city, airport pages; sitemap, robots | Offer approval, sign, pay; Stripe webhook; confirmed state | Master calendar (read, filters, side panel); vehicle calendar; blocks | Owner intake and onboarding wizard steps 1 to 4; owner record | Listing review and publish; real photo adapter; CS verification queue |
| 4 (Oct 11) | Messaging adapter (Resend), digests with F; audit and logging | Reviews display, guides (first five), internal links | Verification upload, renter portal home, cancellation | Calendar drag and resize; deposits, charges, refunds; insurer bookings | Government PDF pre-fill for the six situations; owner agreements signing | Field handover and return checklists with the photo set |
| 5 (Oct 12 to 13) | Link checker, copy lint, accessibility pass, backups and restore test | Core Web Vitals pass; redirects; structured data validation | Extension, statements view, review form | Tolls single entry and matching; incidents and damage billing; owner invoices and statement approval | Owner portal money screens; investor area | Reminders and lifecycle emails; Fleet and Finance queues |
| 6 (Oct 14) | Security checklist, production deploy, smoke test | Search Console, analytics, Business Profile check | End-to-end pass on phone and desktop | End-to-end pass; payouts screen | End-to-end pass | End-to-end pass |

**Cut line.** If time runs out, these ship in the two weeks after launch, in this order, and are run by hand until then: bulk toll import and notice reading (single entry works at launch); calendar drag and resize (the edit form works at launch); company reports beyond the CSV exports; insurer invoice PDF (a CSV and a manual invoice until then); investor area (statements are emailed as PDFs); VA Sales portal; come-back discount emails (they first fire one week after the first completed rental, so they are not needed until about October 25).

**Never cut:** request to offer to sign to pay; staff two-step sign-in; row-level security tests; the rental agreement signature record; the handover and return checklists; the audit log; backups with a tested restore.

## 11. Definition of done for a route

1. Works at 360 px, 768 px and 1440 px wide.
2. The four standard states exist (loading, empty, error, not allowed).
3. Every field has a label, validation on both sides from one schema, and a stored column.
4. Every button names its server action, and the action writes an audit entry.
5. Keyboard reachable, visible focus, screen reader labels (`15-test-plan.md` section 5).
6. An end-to-end test covers the main path on a phone viewport and a desktop viewport.
7. The copy lint and the link checker pass.
8. No new database object was assumed without being listed in `99-traceability.md` section 3.
