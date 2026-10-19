# Turo by email, quiet site alerts, the deploy fix and the lawyer's approval (October 19, 2026)

Migration `0063_turo_email_quiet_alerts.sql`; tests `supabase/tests/42_turo_email_quiet_alerts.sql` (03, 34 and 41
updated); unit tests `web/src/features/turo/email.test.ts`, `web/src/lib/db/postgrest.test.ts`,
`web/src/lib/schema-marker.test.ts`, `web/src/features/legal-review.test.ts`; end to end `web/tests/e2e/turo-email.spec.ts`
(375 and 1440) and `calendar-sync.spec.ts` updated. No new email template. No applied migration was edited.

## 0. The deploy blocker: car, model and booking pages on demand

The deploy of 0062 (run 39289461880) stopped three times in "Build the Worker" on a database statement timeout (57014)
while pre-rendering `/rent/mercedes-benz-glc300` (`public.model_hub`).

| Change | Where |
| --- | --- |
| `/rent/[hub]`, `/cars/[slug]` and `/book/[slug]` are no longer pre-rendered: `generateStaticParams` returns nothing, so each page is rendered on its first visit and then served from the page cache for an hour (`revalidate = 3600`, ISR in R2, as before for new cars). The build makes no database call for them | `web/src/app/rent/[hub]/page.tsx`, `cars/[slug]`, `book/[slug]` |
| While `next build` runs (`NEXT_PHASE=phase-production-build`), a database call that fails with a statement timeout (57014), a connection error, a PostgREST connection error or a 5xx is tried again up to 5 times (1.5, 3, 6 and 12 seconds apart). A refusal is never retried; at run time nothing is retried | `web/src/lib/db/postgrest.ts` (`withBuildRetry`), `supabase.ts` |

The pages that are still built ahead (the home page, `/cars`, the sitemap) read the fleet once each. Proof: a local
`npx opennextjs-cloudflare build` passes, lists `/rent/[hub]`, `/cars/[slug]` and `/book/[slug]` as on demand with no
path under them, and the database's own function counters (`track_functions = all`) show `model_hub` and `car_page`
called 0 times during the build (section 8).

## 1. Turo by email

Turo has no calendar link (0062 assumed one). Turo leaves the calendar link platforms; **Getaround, Google Calendar and
Other** stay. Any Turo calendar link added since 0062 is turned off with a reason in words and its blocks freed. Turo
works by email instead, both ways.

### How an email arrives

```
Turo -> rent@carmacars.ca (Google Workspace, unchanged) -> Gmail filter "from:turo.com" forwards
     -> trips@in.carmacars.ca (Cloudflare Email Routing on the subdomain in.carmacars.ca: the root domain's MX stay Google's)
     -> the Worker's email handler (custom-worker.ts) -> POST /api/inbound/turo (the jobs' token)
     -> the reader (web/src/features/turo/email.ts): rules, then Workers AI for what the rules missed
     -> public.turo_email_receive (the parsed fields only) -> the trip, its block, clashes, the log
```

Free: Cloudflare Email Routing and Email Workers cost nothing on the free plan; Resend's inbound needs a paid plan. A
message over 1 MB is refused. When the app cannot take a message (the database is down), the handler throws and
Cloudflare answers a temporary failure, so Gmail tries again.

### The reader (`web/src/features/turo/email.ts`, no imports)

| Step | How |
| --- | --- |
| MIME | Headers (folded lines, encoded words), multipart, quoted-printable and base64, the charset; the HTML part turned into text (tables, links to turo.com kept) when it holds more than the plain part |
| From Turo | The `From:` is at `turo.com` (or a subdomain), or, for an email forwarded by hand, the forwarded `From:` line is. The envelope sender must be in `turo_email_forwarders` (rent@carmacars.ca; Gmail's `rent+caf_=...@carmacars.ca` counts as rent@) |
| Kind | From the subject and the first lines: booked, changed, extended, cancelled, request (not booked yet: nothing is blocked), other (news, payouts, reviews) |
| Trip number | The reservation link (`turo.com/.../reservation/48211907`), "Reservation ID", "Trip #" |
| Start and end | Labelled times ("Trip start", "Pickup", "New trip end"), the newest wording first when a change email lists the old and new dates, a range on one line ("Oct 30, 6:00 PM - Nov 2, 9:00 AM"), the start kept for an extension that gives only the new end. Times are Toronto time (both daylight saving changes); a date without a year takes the year nearest after the email's date |
| The car | Per car on Calendar sync: the **name on Turo** (as the emails show it) and, optionally, the **Turo car number** (the end of its Turo page address). Matched in order: the Turo car number in a link, the VIN, the plate, the name on Turo, then make and model only when no other car shares them. Two cars matching equally: review |
| Guest | The first name only ("Ayesha K. booked" gives Ayesha) |
| Workers AI | Only for a Turo email the rules could not finish, within the day's neuron limit (`turo_email_ai`, the shared `chat_ai_total_daily_neurons`). The model's answer fills only what was missing and only with values that check out: a date and time the email contains, a trip number in the email, a first name in the email, a car that matches one of ours. About 60 to 80 neurons an email, logged in `provider_calls` (`purpose = 'turo_email'`) |

Samples (written for the tests in the shapes Turo sends hosts, not captured from the account): booked (HTML,
quoted-printable, encoded subject), booked with a one-line range and no year, changed (old and new dates, base64),
extended across the end of daylight saving, cancelled, a request, an unclear car, forwarded by hand, and Gmail's
forwarding confirmation (`web/src/features/turo/samples/`).

### What the database does with it (`app.turo_email_receive`, `app.turo_trip_apply`)

| Email | Result |
| --- | --- |
| Booked | A `turo_calendar_trips` row (trip number, car, start, end, guest's first name) and, through the car's Turo email feed (a `calendar_feeds` row of kind `email`, never fetched), an **External booking** block with the turnaround before and after, note "Turo: Turo trip 48211907" (no guest name). Availability, search, the public calendar and request to book respect it at once |
| Changed, extended | The same block moves. An extension with only the new end keeps the start |
| Cancelled | The trip is cancelled and the car freed. A cancellation of a trip never seen frees nothing (logged) |
| An older email | An email sent before the last one applied to the trip changes nothing (Gmail can deliver out of order) |
| The same email twice | Nothing (the message id) |
| A clash | 0062's machinery: an urgent Fleet task "Double booking: <car> on Turo and CC-1042", the email `staff_calendar_conflict`, the To do line; it closes by itself |
| Unclear (car, dates or trip number missing) | **Turo emails to check** on Calendar sync, a Fleet task "Turo email to check" and the To do line "Turo emails to check". Staff add the trip with what they check on Turo (**Add as a Turo trip**) or **Dismiss** it |
| Not from Turo, not forwarded by rent@, a request, other | Logged as ignored, with the reason in words |
| Gmail's forwarding confirmation | Shown to the Admins on Calendar sync with the code and Gmail's link (Google addresses only), and the To do line "Gmail forwarding to confirm" until a forwarded Turo email arrives |

**What is kept**: the parsed fields and a short audit line per email (`turo_inbound_emails`, deleted after
`turo_email_keep_days`, 90). Never the email itself. An email waiting for review keeps a redacted excerpt of at most 600
characters (no email addresses, phone numbers or links) until it is handled, at most 14 days. Trips keep only the guest's
first name.

### Calendar sync (Admin > Cars, Fleet's Cars)

- **Turo by email** card: the inbound address, the last Turo email, Gmail's code (Admins), the emails to check, the last
  15 emails ("Done", "To check", "Ignored", read with the assistant).
- Per car: **This car is on Turo** (the name on Turo and the Turo car number), its Turo trips (with **Cancelled** for a
  trip whose cancellation email did not come), **Add a Turo trip** (start, end, the trip number and first name optional),
  and **Block on Turo**: Turo cannot read our calendar, so the confirmed and on-rent CarmaCars bookings not yet blocked on
  Turo are listed with the dates to block (the turnaround included) and a **Done on Turo** tick. A booking whose dates
  changed comes back with the old dates to free first; one cancelled here is listed to free on Turo (**Freed on Turo**).
  Every tick is in the audit log (`turo_blocked_bookings`).
- The export links: "For Getaround", "For Google Calendar", "For any other platform". No Turo link.

## 2. Site alerts that do not spam

| Before (0062) | Now (0063) |
| --- | --- |
| A page failing 3 checks in a row emailed | A page shows as a problem on Site health after 3 failures, and **emails only after failing every check for `uptime_page_alert_minutes` (15)** |
| Emails, jobs, backup, Stripe: a failure emailed at once | Emails failing or stuck for `uptime_email_alert_minutes` (30); Stripe failing for `uptime_stripe_alert_minutes` (30); the nightly backup failing: at once; **a failed scheduled job: never emailed** (Site health and the digest) |
| One alert email per problem, cooldown 60 minutes | At most `uptime_max_alert_emails` (3) alert emails a Toronto day; the next real outage is held ("Daily limit of 3 alert emails reached") and goes the next day if it lasts |
| Any hour | **No email from `uptime_quiet_from_hour` (23) to `uptime_quiet_until_hour` (7)**, unless the whole site (the home page) has been down for `uptime_quiet_outage_minutes` (60). An outage held in the night is emailed at 7:00 if it lasts |
| A recovery email per emailed alert | The same, one per incident; a recovery in the quiet hours waits for 7:00 unless the alert was a full outage emailed in the night |
| An urgent task and To do for every alert | Only for a real outage. A short problem (an Error 1102, a single failure) is on the Site health card only |
| Nothing | **The Admin's morning digest** gets one line for the last 24 hours: "Site check: 6 failed checks in the last 24 hours, no alert email", with the checks, the Error 1102 count and what was held |

The cooldown setting is no longer used. The site check job still runs every minute; `app.uptime_notify()` decides the
emails each minute, so a held alert goes at 7:00 sharp.

**`/api/health` waiting for the website deploy.** Every response of the website carries its schema marker (header
`x-carmacars-schema`, the newest migration it was built for, `web/src/lib/schema-marker.ts`; a unit test fails until it
is raised with each new migration), and `/api/health` returns it with the database's (`app.schema_marker()`: the newest
row of the migration history). When `/api/health` answers 404 from a website without a marker or with an older one, the
check reads **"Waiting for the website deploy"** (a calm state on Site health), not a failure. A 404 from a website as
new as the database is a real failure.

## 3. The lawyer's approval (October 19, 2026)

The owner confirmed that the lawyer approved everything flagged for review. Marked "Approved by the lawyer on
2026-10-19" in the change records: the recovery emails (0062), the privacy policy and cookie banner wording (0060), the
staff commission clauses and the Enrollment Agreement's kickback wording (8.1, 8.3, 8.5) with the Field Staff Agreement
7.5 (0058), the VA agreement 3.1, 3.2 and 7.4 and the Pay row (0057, 0059), the partner agreement and the investment
agreement (0046), the booking amendment and the Form C and D wording (0040), the PAD wording (0037) and the items of the
lawyer pack (0051).

The draft banners are gone from the platform documents: `docs/source/v2_investment.md` ("DRAFT FOR LEGAL REVIEW. NOT FOR
SIGNATURE."), `v2_rental.md`, `website_terms_policies.md`, and "Draft." from the cover summary of `v2_enrollment.md` and
`v2_title_holding.md`. The generated texts were rebuilt, so their versions changed by the usual rule (a new hash of the
source): staff and investment agreements `person-475a128136` (was `person-7571e78a38`), rental agreement
`rental-v3-8574950085`, owner agreements `owner-v3-8a1ad30011`. Signed documents keep the version they were signed
with; new ones get the new version. The investment agreement's PDF is generated from this text when an Admin sends it,
so it no longer shows the banner. **An investment agreement generated and sent before this deploy and not signed yet still
shows the old banner: send it again.** `docs/source/v2_shareholder.md` (the shareholders' own agreement, not a platform
document) keeps its banner.

## 4. Settings (Program settings)

`turo_email_enabled` (on), `turo_email_address` (trips@in.carmacars.ca), `turo_email_forwarders` (rent@carmacars.ca),
`turo_email_ai` (on), `turo_email_keep_days` (90); `uptime_page_alert_minutes` (15), `uptime_email_alert_minutes` (30),
`uptime_stripe_alert_minutes` (30), `uptime_max_alert_emails` (3), `uptime_quiet_from_hour` (23),
`uptime_quiet_until_hour` (7), `uptime_quiet_outage_minutes` (60).

## 5. Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | 4087 passed, 0 failed (43 files after the rebase on 0061; new suite 42, 87 assertions; 41 now uses a Google Calendar link named "Turo" and leaves the alert emails to 42; 34 has the two new To do lines; 03 lists the four new tables) |
| Unit (`npm run test:unit`) | 177 passed, including `turo/email.test.ts` (13: booked in two shapes, changed, extended across daylight saving, cancelled, a request, an unclear car, forwarded by hand, not from Turo, Gmail's confirmation, the redacted excerpt, dates, the model's answer checked against the email), the build retry, the schema marker and the approved texts |
| End to end, 375 and 1440 | `turo-email.spec.ts` 3 of 3 (a forwarded booked email blocks the car with the turnaround, a cancellation frees it, an unclear email resolved from the review list, Gmail's code shown and hidden, Done on Turo; the health check "Waiting for the website deploy"); with `calendar-sync`, `admin`, `supply-rentals`, `pages`, `site`, `staff` and `legal-admin-redesign`: 104 passed, 4 skipped (one width by design) |
| Local build | `npx opennextjs-cloudflare build` passes; `model_hub` and `car_page` called 0 times during the build (database function counters); typecheck, lint, text check green |

## 6. Guides

Admin: the chapter "Calendar sync with Turo and other platforms" rewritten (set up Turo by email once, Turo trips on the
calendar, Turo emails to check, Done on Turo, calendar links for Getaround and Google Calendar, double bookings), "Site
health and alerts" (the real outage rules, the daily limit, the quiet hours, the digest line, waiting for the website
deploy), Program settings. VA: Calendar sync in Fleet. Released by the 0063 guides block
(`supabase/seed/0063_gen_guides.mjs`, base commit 7d0817f).

## 7. What the owner must do

**A. Deploy** (the owner starts it): `ci.yml` with deploy on the commit in the final report. The migration, the Worker
(with its email handler) and the guides go out together. The deploy step "Turo by email" then reports whether Email
Routing is on for in.carmacars.ca and, when the API token may, points the rule for trips@in.carmacars.ca at the Worker.
It never turns Email Routing on and never touches the root domain's mail.

**B. Cloudflare Email Routing on the subdomain (once, in the dashboard, about 3 minutes).** The root domain's Google
Workspace MX records stay as they are: only `in.carmacars.ca` gets Cloudflare's.

1. Cloudflare dashboard, account, domain **carmacars.ca**, **Email** > **Email Routing**. If the page offers to set up
   Email Routing for the domain itself ("Get started" with carmacars.ca), **do not** add records or remove the Google MX
   records: go to **Settings** instead.
2. **Settings** > **Subdomains**: type `in` (for in.carmacars.ca) and press **Add**. Cloudflare adds its MX and SPF
   records to in.carmacars.ca only. Check under DNS that the MX records of carmacars.ca are still Google's.
3. **Routing rules** > **Custom addresses** > **Create address**: custom address `trips@in.carmacars.ca`, action **Send
   to a Worker**, destination **carmacars-prod**. Save. (The deploy step sets this rule itself when the API token has
   "Email Routing Rules: Edit"; the deploy notice says "Turo by email: ready" once it is in place.)

**C. Gmail in rent@carmacars.ca (once).**

1. Gmail, **Settings** (gear) > **See all settings** > **Forwarding and POP/IMAP** > **Add a forwarding address**: type
   `trips@in.carmacars.ca`, **Next**, **Proceed**, **OK**.
2. Gmail emails a confirmation code to that address. Within a minute it shows in Admin > Cars > **Calendar sync**, card
   "Turo by email" (and To do shows "Gmail forwarding to confirm"): type the code in Gmail and press **Verify** (or open the
   link shown). Leave "Disable forwarding" selected: only the filter forwards.
3. In the Gmail search box, open the search options (the sliders icon). **From**: `turo.com`. **Create filter**. Tick
   **Forward it to** and choose `trips@in.carmacars.ca`. Press **Create filter**. (Optionally also tick "Also apply filter
   to matching conversations" to send the recent Turo emails once; each trip is read only once.)
4. If Gmail says forwarding is disabled by the administrator: Google Admin console > Apps > Google Workspace > Gmail >
   End User Access > "Automatic forwarding": allow it.

**D. Each car on Turo (once per car).** Admin > Cars > Calendar sync: on the car, **This car is on Turo**, type its name
exactly as Turo's emails show it (for example "Mercedes-Benz GLC 2021") and, optionally, its Turo car number (the
number at the end of its Turo page address), **Save**. Then, under **Block on Turo**, block each listed CarmaCars booking
on Turo and press **Done on Turo**. Add the Turo trips already booked before the filter existed with **Add a Turo trip**
(or re-forward their emails).

**E. Check the first emails.** The samples are in Turo's shapes, not captured from your account. Watch "Turo emails to
check" for the first few days; anything unclear waits there with a task.

## 8. Deploy and checks

| What | Run | Result |
| --- | --- | --- |
| Push CI (fast gates) | after the push | |
| Deploy | not started (the owner starts it) | |
