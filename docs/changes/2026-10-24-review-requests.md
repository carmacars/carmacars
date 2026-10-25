# Review requests (October 24, 2026)

Migration 0146. The owner, October 24, 2026: ask every renter for a review at the right moment, by email and text, never while charges are still open, stop as soon as they reviewed, and make the review fast and easy for the renter.

## What renters get

- **The messages** (email and text, as each renter chose in 0096; never after an unsubscribe; only from 9 am to 9 pm Toronto time, a message due outside those hours waits for 9 am):

| Message | When | Code |
| --- | --- | --- |
| Mid-trip check-in: "How is the car? If anything is off, reply or call." No review ask. | Rentals of 2 days or more, 24 hours after the pickup, never in the last 6 hours before the return | `renter_trip_checkin` (a service message) |
| Review request | 1 hour after the check-in (booking returned or closed) | `renter_review_ask` |
| Reminder | 24 hours after the request | `renter_review_reminder` |
| Final follow-up | 7 days after the request; nothing more after it | `renter_review_final` |

  Every timing is in Program settings (Admin > Settings > Reviews). The request and its follow-ups are marketing under the existing business relationship (implied consent): the outbox adds the unsubscribe link and the mailing address, and the marketing hours and daily cap of 0018 still apply. Each has its own text (`sms_templates`).
- **The review page** `/review/<token>` (no sign-in; the token is in the emails and texts; noindex, never cached at the edge, disallowed for crawlers): "How was your trip, Robin?" and three quick things: what they liked (chips: the car, the pickup or the delivery as the booking had it, communication, price, cleanliness, booking was easy, and the first name of each staff member who did the handover or the return), an optional star feel, and one sentence in their own words. The draft appears only once they answered: first person, made only from their answers and the booking's facts (the car, how many days, delivered or not), with varied phrasing ("Other words"). They edit it freely; **Copy**, and **Post on Google** (copies it and opens the Google review link). Everyone gets the Google link whatever their stars (no rating-based routing); a star feel of 3 or fewer also shows "Something wasn't right? Tell us directly" (the contact address and the phone; on the signed-in page, the booking's messages). "I already left a review" stops the requests; the email's link to it (`?done=1`) asks to confirm first, since mail scanners open links.
- **Signed in**: the booking's Review your rental page shows the same helper first ("Review us on Google"), then the on-site review as before.

## What staff see

- **The booking page** (Admin and every assistant): the card **Review requests**: each message with when it went or when it will go, the hold and what is open, the stop and why, what the renter did on the page. **Ask for a review** (a booking on a trip, returned or closed; now, or at 9 am; not twice in 24 hours; never after an unsubscribe or a review), **Send anyway** (held), **Mark reviewed**.
- **The hold**: no review request while a return or later charge is open: late return, kilometres, fuel or charging, cleaning, smoking, damage, tolls and tickets, other charges after the return (a line not on a statement yet, or on one not paid or covered by the deposit or the card), a toll or damage matched to the renter and not charged yet, or an open incident or card dispute. A waived line (0130) never counts. The booking is on **Review requests on hold** (Admin > Reviews; customer service and Sales: Renters > Review requests) and leaves it by itself once the charges are settled or waived; **Send anyway** releases it, **Do not ask** stops it. While the program is on, this replaces 0025's decision task for a problem booking (its old yes and no still work: yes is Send anyway, no stops the requests).
- **The stop**: the renter's "I already left a review", staff's Mark reviewed, an on-site review (at once, a trigger), a Google review matched to the renter, an unsubscribe, or a request that could not go within 45 days of the return.
- **Admin > Reviews**: requests sent (and check-ins), on hold, reviews detected (on the site, Google matched, said so, marked), the average rating (Google, the site, both), over 7, 30, 90 days or 12 months; the hold list; the Google reviews with their matches: **Confirm**, **Not this renter**, **Match to a booking**. Then the on-site reviews as before.
- **Admin > Settings > Reviews** (`/admin/settings/reviews`): the timings, sending hours and hold (Program settings `review_*`), the Google place id and an optional Google review link (`site_settings.google_review_link`, https only; else the place id's link), and the **Google Business Profile** card: Connect Google (OAuth for rent@carmacars.ca with offline access to `business.manage`; the refresh token goes to the vault as `google_reviews_refresh_token`), Disconnect, the status, the last read and error.

## Google reviews sync

- The Worker's five-minute tick asks `server_jobs_due` (now with `reviews`: connected and not read for 6 hours) and posts `/api/jobs/reviews`: a fresh access token, the account and location (the one whose place id is in Site settings, or the only one), the newest reviews (`accounts.locations.reviews.list`, up to 250), each matched to a renter in `src/features/reviews/match.ts`: the reviewer's display name against the renter's name (accents, case and punctuation ignored; full name, first and last, first name and last initial, a one-letter typo in a long name, first name only), among renters who returned a car in the 30 days before the review. One renter with a strong match: **matched** at once (stops their requests). A weaker match or two people with the same name: **suggested**, for staff. A staff decision is never undone by a later sync.
- **Without Google's approval** of the Business Profile API for the project, the sync records `api_not_approved` and the settings screen says so; everything else works. Without the OAuth client (`GOOGLE_REVIEWS_CLIENT_ID`, `GOOGLE_REVIEWS_CLIENT_SECRET`; the deploy reads them from the vault as `deploy_google_reviews_client_id` and `deploy_google_reviews_client_secret`, both optional), the screen says the keys are not set. A database without the vault (local and test) cannot keep the connection and says so.

## The database

- `review_requests` (one per booking; the token; each step's time; hold reasons; stop reason), `google_reviews`, `review_google_link` (the connection, never the token); row-level security, the admin policy, audited, granted to no visitor.
- `app.review_step` (one booking, one tick), `app.job_review_requests` (pg_cron every 10 minutes), `app.review_hold_items` and `app.review_hold_reasons`, `app.review_returned_at`, `app.review_next_window`, `app.review_may_ask`, `app.review_found`, `app.review_stop`; staff: `app.review_request_panel`, `app.review_ask_now`, `app.review_send_anyway`, `app.review_mark_reviewed`, `app.review_overview`, `app.review_google_match` (door: `ops_read` `review_request`, `review_overview`; `ops_do` `review_ask_now`, `review_send_anyway`, `review_mark_reviewed`, `review_google_match`; `admin_read` `review_settings`; `admin_do` `review_google_connect`, `review_google_disconnect`); the page: `public.server_review_helper`, `public.server_review_helper_act`, `public.renter_review_token`; the sync: `public.server_review_google_sync_begin`, `public.server_review_google_sync_finish` (service role only).
- Wrapped: `app.door` (`door_pre0146`), `app.notification_payload` (`ntf_payload_pre0146`: the review page's link, "I already left a review" and the Google link), `app.server_jobs_due` (`server_jobs_due_pre0146`), `app.hold_review_request` and `app.decide_review_request` (`*_pre0146`). `app.google_review_url` prefers the new review link. While `review_program_enabled` is on, 0023's `renter_review_request` and 0061's `renter_google_review_request` are not recorded in `marketing_sends`, so not sent (they would ask twice).
- The bookings already returned: one that had 0023's or 0061's email is finished, one with a review or back more than 7 days ago is stopped; the rest start the sequence.
- `SCHEMA_MARKER` 0146. Suite 91 (`supabase/tests/91_review_requests.sql`); the earlier suites run with the program off (`helpers.sql`), as they test 0023's and 0061's emails.

## Defaults chosen

On from the start; check-in for 2 days or more at 24 hours; request at 60 minutes; reminder 24 hours; final 7 days; 9 am to 9 pm; hold on; give up 45 days after the return; Google window 30 days; clear matches automatic. The star feel is never written into the draft (Google asks for the stars itself). Nothing is offered for a review.

## Checks

Typecheck, lint, unit tests (`src/features/reviews/reviews.test.ts`: the draft only from the renter's answers and the booking's facts, never a phrase for a chip not picked, delivery only for a delivered booking, staff names only from the booking, nothing without input, varied phrasing; the sequence's timing inside the sending hours across the change from daylight time; the hold's summary; the name matching and the window; `page-cache.test.ts`: the cron gate's `reviews`), the text check, `check-change-guides`, `node emails/check.mjs`, `scripts/test.sh` with suite 91, and end to end (`tests/e2e/review-requests.spec.ts`, 375 and 1440, axe).

## Guides

- `renter/during-your-trip`: the mid-trip check-in.
- `renter/after-your-trip`: Review your trip (the link, the three questions, the draft, Post on Google, "I already left a review", tell us directly), then the on-site review.
- `admin/requests-offers-and-bookings`: Review requests (the messages and when, the booking's card, Ask for a review, the hold and Send anyway, Mark reviewed).
- `admin/settings`: Settings > Reviews (timings, the Google review link, Connect Google, matches).
- `va/your-workday`: Review requests in customer service's menu.
- `va/customer-service`: Review requests (the hold list, Google matches, Ask for a review).

Published by migration 0146 (generated by `supabase/seed/0146_gen_guides.mjs`).
