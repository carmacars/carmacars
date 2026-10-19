# First reply target, staff agreement defaults, sales tracking (October 18, 2026)

Migration `0057_sales_tracking.sql`; tests `supabase/tests/36_sales_tracking.sql` (76 assertions); end to end
`web/tests/e2e/sales-tracking.spec.ts` (phone 375 and desktop 1440); unit tests in
`web/src/features/person-agreements/model.test.ts`. No applied migration was edited.

## 1. The first reply target is 5 minutes

One Program setting, `request_response_target_minutes` ("First reply target for customer service and sales (minutes)",
under Booking requests and offers), default 5, from 1 to 1440. It already held the 2-hour target the Overview showed;
every dated row still at 120 was set to 5.

| What uses it | How |
| --- | --- |
| Task due times | New task rule kind `first_reply` (opening minutes, the amount read from the setting at the moment the task is raised): `booking_request` (was 2 hours), `offer_change_requested` (was 15 minutes), `enquiry` (was 1 business day), `renter_message` (was 15 minutes). A re-offer keeps its 30 minutes; owner leads keep 1 business day |
| Countdown | `tasks.sla_minutes` takes the same value |
| Scorecard | Customer service "First reply in opening hours" and Sales "Quote sent" print the target from the setting ("5 minutes"). Sales' "Quote sent" now counts the first-reply tasks (requests, enquiries, offer changes, renter messages); owner leads have their own measure "Owner leads answered", 1 business day |
| Staff screens | Admin > Today > Overview ("first reply target 5 min"), Admin and assistant Requests (red past the target, the target in the heading), the guides |
| Not changed | What renters are promised (Site settings, Reply wording: "within 2 hours") and the late-request staff alert (`notify_request_waiting_minutes`, 2 hours) are separate settings |

Tasks raised before the migration keep the due time they were given; new tasks follow the target. Changing the
setting changes the tasks raised after it (tested with 10 minutes).

## 2. Staff agreement defaults by function

`program_settings.staff_agreement_defaults.va.by_function` (Admin > Settings > Program, "Staff agreement defaults by
function", its own form):

| Function | Pay | Rate | Schedule | Days a week | Hours a day |
| --- | --- | --- | --- | --- | --- |
| Customer service | a month | US$350.00 | Full time | 6 | 10 |
| Fleet | a month | US$400.00 | Full time | 6 | 10 |
| Finance | a month | US$200.00 | Part time | 3 | 9 |
| Sales | not set | not set | not set | not set | not set |

Common assistant values stay (country, currency USD, OnlineJobs.ph, every two weeks, 30-day trial); "Days and times"
defaults to "Days and times as set in the weekly roster" (the old "Monday to Friday, 9:00 to 17:00" contradicted six
days). Field staff: CA$18.00 an hour, paid every two weeks. A value an Admin had already set is kept.

The generated VA agreement: `docs/source/va_agreement.md` gains a Schedule row ("Full time: 6 days a week, 10 hours a
day"), the Rate row reads "[●] (a month or an hour), in [●]", and section 3.1 says how a monthly Rate is paid ("A monthly
Rate covers the Coverage Hours of each month: a part month, and Coverage Hours missed without CarmaCars' approval, are
paid in proportion. An hourly Rate is paid for time you worked, recorded and CarmaCars approved."). The send form asks
for Pay (a month or an hour), Rate, Schedule, Days a week, Hours a day and Hours a week (computed), all pre-filled from
the person's function. Hourly pay still works. Template version `person-8f32ea9a26`. **For the lawyer:** the new 3.1
wording.

## 3. Sales tracking

### Who a booking is credited to

`bookings.sales_staff_id`, with `sales_source`, `sales_attributed_at` and `sales_attributed_by`:

| How | Credited to | Set by |
| --- | --- | --- |
| `quote` | The staff member who created the request (New quote, or a request an Admin typed in) | Trigger on insert (`created_by` is staff, not a website request, not an Owner Booking) |
| `manual_rental` | The staff member who added the rental (Add a rental) | The same trigger |
| `offer` | For a request nobody is credited with (the website), the staff member who sent its first offer | Trigger on `booking_offers`; later offers never change it |
| `admin` | Whoever an Admin chose, or nobody | `app.sales_reassign` with a reason; kept in the booking's history (`sales_credit`) and the audit log; the deal stays in its week and month |

Only the server (and an Admin) changes the credit; a browser session cannot. Existing bookings were credited by the same
rule.

### The figures (`app.sales_figures`)

| Figure | Rule |
| --- | --- |
| Quotes created | Requests the person created (not rentals added), by the day created |
| Offers sent | Every offer version they sent, by the day sent |
| Rentals added | Rentals they added by hand, by the day added |
| Bookings confirmed | Bookings credited to them, by the day confirmed (cancelled since shown separately) |
| Conversion | Of the deals credited to them in the period, the share confirmed so far |
| Booked revenue | `app.sales_revenue_cents`: the rental charge before tax less the non-refundable, staff and promo discounts, for bookings confirmed in the period; a cancelled booking counts the share kept (its refund percentage); other refunds approved or paid come off before tax (not a cancellation's or a date change's, already in the price) |
| Follow-ups due | Their open deals now (requested, offer out, waiting for signature and payment), each with the next step and its due time |

No commission is computed: the staff agreements allow none.

### Where to find it

| Screen | Who |
| --- | --- |
| VA portal > My work > **My sales** (`/va/my-sales`) | Sales: tiles for this week or month, By week or By month, Follow-ups due, Deals (renters by first name; a request, an offer, a payment wait or a rental they added opens from its number), How it is counted. (`/va/sales` stays the old email link to To do) |
| Admin > People > Staff > a staff member's **Sales** (`/admin/staff/[id]/sales`) | Admins: the same board for anyone, every booking linked, **Reassign** on each credited deal |
| Admin > Today > Overview, "Sales in <month>" | Admins: each person in Sales (and anyone else with a quote, an offer, a rental or a credited booking that month), the team's totals, a month chooser |
| Admin booking page, "Sales credit" | Admins: who and how, what it counts, **Reassign** |

### Sales adds rentals by hand

Confirmed: Add a rental exists for customer service and Sales (0046). Tested end to end for a Sales account within its
limits (the rate-sheet price, no price typed by hand, no past rental, no booking over a clash, a payment link or a
payment received at the counter within its single limit); the rental is credited to Sales and shows in My sales as
"Rental you added", in the follow-ups while it waits for signature and payment, and opens from My sales.

## 4. Guides

`docs/guides/src/guides/va.py` and `admin.py`, exported to `docs/guides/content`, the VA and Admin PDFs rebuilt; 0057
publishes the 9 changed chapters on the live guides where the text is still ours (`supabase/seed/0057_gen_guides.mjs`),
and keeps them as suggestions where an Admin edited a chapter. VA: the menu with My sales, the 5-minute target on the
scorecard and in customer service, My sales with how each figure is counted, a rental added counting in My sales, the
quick reference. Admin: the Overview's team sales, the target on Requests, who a booking is credited to and Reassign,
Sales by staff member, Program settings (the target, the defaults by function), staff agreements from the defaults.
The guides update themselves after the deploy (0055) for the screenshots. `web/scripts/portal-facts.mjs` reads Sales'
own My work group.

## 5. Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | 3651 passed, 0 failed (new suite 36; 08 and 09 updated for the new history kind and the 5-minute due time) |
| Unit (`npm run test:unit`) | 117 passed |
| End to end, 375 and 1440 | `sales-tracking.spec.ts` 4 of 4 locally; the full suite in the deploy run: 195 passed, 15 skipped by design |
| Emails (`emails/check.mjs`) | all 15 checks passed |
| Text check, copy lint, guide labels, 0057 guides block | passed |

## 6. Deploy and checks

| What | Run | Result |
| --- | --- | --- |
| Push CI (fast gates) | 39169887488 | Green |
| Deploy with the full suite (end to end at 375 and 1440 with axe, links, copy lint, crawl as every role including `va_sales`, SEO, emails) | 39170156039 | Green: 195 end-to-end tests passed (15 skipped by design), crawl, SEO and emails 0 problems; 1 migration applied (history 57); carmacars.ca, /cars and photos answer 200 |
| Guides after the deploy (auto) | 39173040720 | Failed on a 503 from `/api/jobs/guide-upkeep` (Error 1102 while the verification ran at the same time) |
| Guides (auto), again | 39179612157 | Green: 4 screenshots replaced, 1 section rewritten (owner), 2 to review (field/my-jobs, admin/requests-offers-and-bookings: an AI suggestion kept for review, the published text is 0057's), PDFs of the owner, field and admin guides printed |
| verify, full | 39184483520 | Green: every check passed |
| verify, full, before it | 39173066919, 39174087686, 39175095883, 39176031042, 39176702842, 39177502124, 39178280885, 39178877577, 39181263726, 39181978640, 39183190653 | Each failed one different sign-in, sign-up or email-link step on a 30-second timeout while the Worker answered Error 1102 (`503 exceeded resource limits`, on /sign-in, /admin, /investor, /va, /owner); no failure on a page this work changed |

**Error 1102 (separate).** Cloudflare stopped 211 requests in 24 hours with Error 1102 (the free plan's 10 ms CPU
limit; 69 in the hour of the verifications). It is what failed the eleven verifications before the green one. Workers
Paid removes the limit; the owner is upgrading.

## 7. What still needs the owner

- Program settings: the Sales function's pay, rate, schedule, days and hours (left blank as decided).
- The lawyer: the new section 3.1 of the VA agreement (a monthly Rate).
- Admin > Settings > Guides: two sections "To review" after the upkeep run (field/my-jobs, admin/requests-offers-and-bookings).
