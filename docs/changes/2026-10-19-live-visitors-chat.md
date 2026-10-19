# Live visitors, buying signals and live chat (October 19, 2026)

Migration `0060_live_visitors_chat.sql`; tests `supabase/tests/39_live_visitors_chat.sql`; unit tests
`web/src/features/chat/guardrails.test.ts`; end to end `web/tests/e2e/live-chat.spec.ts` (phone 375 and desktop 1440).
No applied migration was edited.

## 1. Live visitors and buying signals

### What is recorded, and when

| Visitor | Recorded |
| --- | --- |
| Accepted analytics (cookie banner) | Session id, page views (path, car, time on page), dates searched, a car opened, a booking request started, stopped or sent, an email link opened, the offer, change proposal and pay page viewed or left, the chat opened; the referring site's host and UTM tags; device type; approximate city, region and country from Cloudflare |
| No analytics consent, anonymous | Nothing, until they open the chat (then one session row with the chat) |
| No analytics consent, known (signed in, or arriving from one of our emails) | Only their own booking pages: offer, change proposal, pay page (and leaving it), the email link opened |
| Staff, Admins, field staff (signed in) | Never recorded |

No network address is stored for this. The Worker turns the address into a salted, daily rate-limit key that lives in
`app.rate_limit_hits` for at most two days. Bots, link previews, monitors and headless browsers are dropped by their user
agent (`web/src/lib/track/shared.ts`).

**Who the visitor is.** A signed-in renter, or the recipient of the email whose link they opened: the `send-outbox` Edge
Function adds `?m=<outbox row id>` to every link of a renter email that points into their own booking pages. A sign-in
redirect would drop the query, so the Worker keeps the id for an hour in the first-party cookie `cc_m`, which the beacon
reads once. Once known, every earlier session of the same browser (`cc_vid`) is linked to the renter record.

### The path a batch takes (Worker stays light)

1. `web/src/features/live/beacon.ts` loads after the page is idle (never with the page), batches events (sent after
   4 seconds, at 25 events, on page hide with `keepalive`, and a 30-second heartbeat while the tab is visible).
2. `POST /api/t` is answered in `custom-worker.ts` before the Next.js app is loaded: origin check, bot check, size limit,
   the city from `request.cf`, then **one** call to the database (`public.track_ingest`) with the user's own token when
   signed in. Measured locally: the handler's own work is a JSON parse, a regular expression and one SHA-256 (well under a
   millisecond); the rest is waiting on the database, which Cloudflare does not count as CPU.
3. `app.track_ingest` (one transaction): rate limit (90 batches a minute per session, 600 per address key), the session,
   up to 30 events, the daily counts per car, the signals, and the answer (a chat a staff member started, the chat
   settings).

### Signals (Program settings, "Live visitors and live chat")

| Signal | Rule (default) | Follow-up task |
| --- | --- | --- |
| Viewing spree | `visitor_spree_cars` (6) different cars within `visitor_spree_minutes` (10) | Sales, known visitors only: "Reach out to ..." |
| Opened offer CC-1042, not answered | Offer page or offer email link opened while the booking is `offered` (count across the renter's visits) | After `visitor_offer_no_answer_hours` (6): "Call or message ...: opened offer CC-1042 twice, no answer for 6 hours" (Sales when the booking is credited to someone in Sales, otherwise customer service) |
| Opened the change proposal twice | `visitor_proposal_opens` (2) opens while a staff proposal waits | Customer service |
| Left the pay page | Pay page left while the booking is `pending_payment` | After `visitor_pay_left_minutes` (30), customer service |
| Returning visitor, 3rd visit this week | `visitor_returning_visits` (3) visits in 7 days | None (a badge) |
| Started a request and stopped | Request form touched, then left without sending | After `visitor_request_stopped_minutes` (30), Sales, known visitors only |

Follow-ups come from the job `app.job_visitor_followups()` (pg_cron `carmacars-visitor-followups`, every 15 minutes):
task type `visitor_follow_up`, one per signal (deduplicated), closed by itself when the offer is answered, the payment
made or the proposal answered. `visitor_followup_tasks` turns them off. My sales shows "Follow-ups done", "Booked after a
follow-up", "Chats you answered" and "Follow-ups waiting".

### Screens

| Screen | Who | What |
| --- | --- | --- |
| Admin > Today > **Live visitors** (`/admin/live`), assistants' My work > **Live visitors** (`/va/live`) | Admins, customer service, Sales | On the site now (known name or "Visitor from Toronto, phone"), current page and car, pages and cars this visit, visit number, device, city, referrer and campaign, signal badges, the visit's pages, **Start a chat**; signals of the last 24 hours; most viewed cars (7 days). Refreshed every 5 seconds |
| Admin > Cars > a car, Overview, **Interest on the site** | Admins | Looking now, views today and in 7 days, conversion (requests over viewers, 30 days), 14 days of views |
| Admin > Cars > Vehicles, **Most viewed cars this week** | Admins | The five most viewed cars |
| Admin > People > Renters > a renter (`/admin/renters/[id]`, new) | Admins | Details, bookings, **On the site**: the visits, signals and chats |
| A booking, History tab, **On the site** (Admin and assistants) | Staff | When the renter viewed the offer, opened the change proposal, viewed or left the pay page, and their chats |

Retention: raw events and sessions are deleted after `visitor_events_keep_days` (90) by
`app.job_visitor_housekeeping()` (pg_cron `carmacars-visitor-housekeeping`, daily); `vehicle_interest_daily` (counts
per car and day, no personal information) is kept.

## 2. Live chat

### The visitor

A chat button in the corner of the public site and the renter and owner portals (not the staff portals), loaded after the
page like the beacon; it waits for the cookie banner to be answered on a phone. Full screen on a phone, a panel on a
computer; keyboard and screen reader friendly (dialog, a live log, labelled controls, Esc closes). New messages are read
directly from the database by the conversation's 64-character secret (`public.chat_poll`, every 3 seconds while open, 15
while folded, nothing when closed). Sending goes through `/api/chat`.

### The assistant (Workers AI)

| Point | How |
| --- | --- |
| Model | `chat_ai_model`, `@cf/meta/llama-3.3-70b-instruct-fp8-fast` (JSON mode, temperature 0.2), 25-second timeout |
| Facts | `app.server_chat_facts()`: the fleet with rates and deposits from the database, the rules (ages, licences, notice, offer validity, cancellation tiers, the non-refundable discount, deposit release, airports, fees), the site's hours and reply time, today's date in Toronto, and the names it must never say (the insurers). Cached 5 minutes per Worker instance |
| Tools | `quote` (one car and dates: `public.quote_booking`, the pricing SQL), `search_cars` (`public.search_available`), `start_request` (name, email, phone, car, dates: a `chat` lead and a `chat_request` task for Sales), `handoff` |
| Guardrails (`web/src/features/chat/guardrails.ts`) | A reply may contain only amounts the database gave in this conversation (a quote, a search, the fleet's rates and fees) and only the percentages the site states; no discount other than the non-refundable one, no promise that a car is held or booked, never "insurance" or "coverage", never a provider's name, no legal advice; long dashes and the brand fixed. A refused reply is never shown: it is replaced by the quote's own words, or the chat goes to a person |
| Before the model | A complaint, damage, an accident or breakdown, a payment or refund, insurance or legal words, or "a person" send the chat to staff without calling the model |
| Budget | `chat_ai_daily_neurons` (6,000 a Toronto day for the chat) and `chat_ai_total_daily_neurons` (10,000: every Workers AI use of the day, listing copy, guides and vision included). Over either, or after `chat_ai_max_replies` (12) replies in one chat, the visitor reads "A person will reply shortly" and the chat waits for staff. Every call is a `provider_calls` row (`purpose = 'chat'`, neurons) |

**Cost.** Llama 3.3 70B fp8-fast is 26,668 neurons per million input tokens and 204,805 per million output tokens. One
model call is about 1,800 input tokens (facts and conversation) and 100 output tokens: about 50 + 20 = **70 neurons**; a
reply that needs a quote takes two calls (about **150 neurons**). A typical chat (4 to 6 visitor messages, one or two
quotes) is **400 to 700 neurons**, so the 6,000 default covers about **10 chats a day** inside the free 10,000 neurons
(the rest stays for the listing copy and guides). On Workers Paid, neurons beyond 10,000 a day cost US$0.011 per 1,000:
raising the cap to 20,000 would cost at most about US$0.15 a day.

### Staff

Admin > Bookings > **Live chat** (`/admin/chat`) and the assistants' My work > **Live chat** (`/va/chat`, customer service
and Sales): open and closed conversations (assistant, waiting for a person, with a person), unread counts, minutes waiting
against the first reply target (`request_response_target_minutes`, 5), the visitor typing; the thread with the visitor's
visit beside it (current page, pages, signals, the renter and their bookings). **Take over** (the assistant stops; a reply
also takes over), **Hand back to the assistant**, **Close** (the transcript goes to the visitor's email), **Email the
transcript**. Staff typing shows to the visitor. The menu counts chats waiting. **Notify me**: "Email me when a chat waits
(while I am on shift)" (email `staff_chat_waiting`) and desktop alerts in the browser. On shift: Live chat or Live visitors
open within `chat_shift_minutes` (15).

A hand-over raises task `live_chat_waiting` (customer service, due at the first reply target). With nobody on shift the
chat says the team is away and asks for name, email or phone ("Email me a copy of this chat"): a `chat` lead, task
`chat_contact`, and the transcript email `renter_chat_transcript` (transactional).

**Proactive chat**: **Start a chat** on Live visitors; the visitor sees the message in a bubble with the next beacon (a
page view, or the 30-second heartbeat) and replies from it. The assistant's greeting on car pages after
`chat_greeting_seconds` is off by default.

**Commission**: nothing is credited by itself. A booking that comes from a chat a staff member handled is credited through
the existing choice "I sourced this client" on the quote or offer (0058); the chat's request task and the inbox say so.

Retention: chats linked to a renter or booking stay with the rental records; others are deleted after `chat_keep_days`
(365). Chats left in the assistant's hands close after 12 quiet hours.

## 3. Privacy (for the lawyer)

`docs/source/website_terms_policies.md` and the live `legal.privacy` block (only where it still had our text):

- Section 1, table: "Site data" now lists approximate city, pages and cars viewed and booking steps, with the purpose "to
  secure and improve the Site, and, with your consent, to help you while you browse"; a new row "Live chat".
- Section 6, retention: site visit records 90 days (daily counts per car kept without personal information); live chat
  with the rental records for customers, otherwise 12 months.
- Section 10, Cookies and analytics: three new paragraphs. First-party measurement, no third-party analytics, what is
  recorded with consent, that staff see it while the visitor is on the site; what is recorded without the analytics choice
  (the chat, and a known customer's own offer, proposal, agreement and pay pages); that the chat is answered first by an
  automated assistant, a person reviews anything it collects, and the transcript by email.
- The cookie banner (`cookies.banner`, version `2026-10-19`, so every visitor is asked again): the banner text and both
  groups describe the above. "Last updated" October 19, 2026.

To review: the legal basis for the essential booking-page signals without consent (we rely on the service the customer
asked for); the automated assistant disclosure; the 90-day and 12-month periods; that remote staff (outside Canada) see
live visits.

## 4. Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | see section 6 |
| Unit (`npm run test:unit`) | guardrails and the assistant: invented prices refused, a quote's amounts allowed, discounts, promises, insurance words, provider names, escalation before the model, a model failure becomes a hand-over |
| End to end, 375 and 1440 | `live-chat.spec.ts`: signals on the Live page, chat with the assistant (the amount equals `quote_booking`), hand-over, take-over, reply, hand back, close, proactive chat, Admin pages |

## 5. Guides

Admin, VA and renter guides: Live visitors, Live chat, the car's interest, the renter page, the follow-up tasks, the chat
for renters. Released by the 0060 guides block.

## 6. Deploy and checks

(filled in after the runs)
