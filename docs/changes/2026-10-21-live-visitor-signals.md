# Live visitor signals: who is likely to book, why, and what to say (October 21, 2026)

The owner's request: "The signals for live visitors can be improved. They're too basic right now. We need more useful
and more creative signals."

Migration `0086_live_visitor_signals.sql` (next free number: origin/main is at 0077; the branches in flight use 0078 (deck,
guided), 0079 (fixes), 0080 (assistant), 0081 (games2), 0082 (vinfirst) and 0085 (quo); 0083 and 0084 left alone). Tests `supabase/tests/56_live_visitor_signals.sql`,
`web/src/lib/track/shared.test.ts`, end to end `web/tests/e2e/live-signals.spec.ts` (375 and 1440). Guides generator
`supabase/seed/0086_gen_guides.mjs`. No applied migration was edited.

## 1. What staff see

Admin > Today > Live visitors and the assistants' My work > Live visitors (customer service and Sales):

- **Booking likelihood** from 0 to 100 on every visit, with a band: Hot (60 or more), Warm (30 or more), Cold. The list is
  sorted by it (or by most recent), with a "Hot and warm only" filter. Hot rows are outlined in red.
- **Why**: the three strongest reasons, in words ("Pickup tomorrow · Reached step 3 of the request form · Tapped to call").
- **Signals** as badges with their strength (three dots: strong, medium, weak); the visit's details list each one with
  its group and points.
- **Suggested** next step with the message to send, and one-click actions: **Invite to chat with this message**,
  **Edit the message**, **Offer a 10% discount code**, **Assign to Sales**, **Suggest a similar free car**. The last action
  shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.
- **Others on this car now** ("2 others on this car now"), from an ad, the landing page.
- **Hot visitors today** (and whether someone acted), the signal feed (medium and strong only), the most viewed cars with
  the prices shown and the car most compared with each.
- The menus (Admin and assistants) count hot visitors on the site now beside Live visitors, from the read the menu
  already makes (`chat_counts`), so no extra call per page.
- A visitor who turns hot raises an alert at the top of the page for whoever has it open; a desktop alert too for those
  who turned on desktop alerts in Live chat, never in the site check's quiet hours (23:00 to 07:00). No email.
- Cars > a car: "Saw the price, 30 days" (and as a share of the people who looked) and "Most compared with".
- **Signal settings** (Admin only, `/admin/live/signals`): every number below, saved at once.

## 2. The signals

Each rule has a label, a short "why" (worked out per visit), points (its weight towards the score, -50 to 100), up to two
thresholds and a list where it needs one, a suggested action and a message (with `{car}`, `{other}`, `{days}`,
`{pickup}`, `{booking}`, `{topics}`, `{similar}`, `{first_name_sp}`, `{staff}` filled in). Defaults:

| Group | Signal (label) | Rule | Points | Action |
| --- | --- | --- | --- | --- |
| Intent | Searching dates again and again | at least 3 date searches in one visit | 10 | chat |
| Intent | Saw the full price | the price for their dates was shown (car page or form) | 10 | chat |
| Intent | Reached the booking form | started the request form; why gives the step reached | 15 | chat |
| Intent | Came back for the same car | a car viewed again on a later day | 15 | chat |
| Intent | Comparing cars | 2 or more returns to a car already seen, among 2 to 4 cars | 8 | chat |
| Intent | Read the cancellation policy | the policy page or a question about cancelling | 10 | chat |
| Intent | Read the rules | requirements, FAQ, or a question about price, deposit, insurance, km | 6 | chat |
| Intent | Tapped to call or message | tel, WhatsApp, sms or email link tapped, or our number copied | 20 | chat |
| Intent | Checked delivery | delivery priced, or the delivery page | 6 | chat |
| Intent | Looked closely at one car | 6 photos looked through, or 90 seconds on the car | 8 | chat |
| Urgency | Pickup soon | pickup within 72 hours | 12 | chat |
| Urgency | Weekend or holiday dates | a short trip from Thursday to Saturday, or over a holiday | 4 | chat |
| Urgency | On a phone late at night | a phone between 22:00 and 05:00 Toronto, looking at cars or dates | 3 | chat |
| Urgency | Came from a local search | landed on a city or model page, or "near me" in the search terms | 6 | chat |
| Value | Long rental | 7 days or more (weekly), 28 or more (monthly) | 12 | assign |
| Value | Premium car | a car in luxury, premium, exotic, SUV or van | 6 | chat |
| Value | Adding a driver | an additional driver priced or asked about | 4 | chat |
| Value | Asked about young drivers | a question or page about drivers under 25 | 0 | chat |
| Value | Business email | an email (chat, game, account) not on a list of personal providers | 6 | assign |
| Hesitation | Watching the price | sorted by lowest price, lowered the price limit, or 3 filter changes | 0 | discount |
| Hesitation | Left after seeing the price | price seen, no request: moved on, or 10 minutes passed | 0 | discount |
| Hesitation | Unsure about the deposit | a question about the deposit and no request | 0 | chat |
| Hesitation | Trouble with a form | 2 form errors, or 4 quick taps on the same thing | 5 | chat |
| Hesitation | Dates not free | the car priced is not free for their dates | 5 | similar |
| Context | Came from an ad | an ad click id in the address (only the flag is kept), or a paid UTM medium | 4 | none |
| Context | Past renter | a renter with a finished trip | 15 | assign |
| Context | Has an offer waiting | a renter with an offer or payment waiting | 10 | chat |
| Context | Has a game code to use | a discount game code still valid and not used | 8 | chat |
| Context | Popular car | 5 people looked at the car today | 3 | chat |
| (0060) | Opened the offer, not answered | unchanged rule (Program settings) | 25 | chat |
| (0060) | Opened the change proposal | unchanged | 15 | chat |
| (0060) | Left the pay page | unchanged | 25 | chat |
| (0060) | Started a request and stopped | unchanged | 15 | chat |
| (0060) | Returning visitor | unchanged | 10 | chat |
| (0060) | Viewing spree | unchanged | 5 | chat |

The visitor's own chat messages are read for key words only (deposit, insurance, young driver, additional driver,
cancel, deliver), which count as questions opened. Owners, investors and field staff on their portals get no score
("Owner").

## 3. The score

`score = min(100, max(0, sum of the points of the visit's current signals))`: the 0086 signals of the visit plus the
0060 signals still open for the visitor (visitor-wide ones such as an offer opened, the session ones of this visit).
Bands and strengths are settings (`visitor_signal_config`): hot 60, warm 30, strong from 15 points, medium from 8.
`visitor_sessions.hot_at` keeps when a visit first turned hot. The three strongest reasons are stored with the score.

## 4. Actions

| Action | What happens | Who |
| --- | --- | --- |
| Invite to chat with this message | 0060's proactive chat with the suggested (or edited) message; `{staff}` becomes the sender's first name | Admins, customer service, Sales |
| Offer a discount code | a single-use promo code (10% off the rental charge, at most $75, valid 3 days, tied to the renter when known, source `live_visitors`) sent in the chat with the discount message; one per visitor a week, 10 a day per person | Admins and Sales; customer service when the setting allows |
| Assign to Sales | the visit goes to the person chosen, else the caller if in Sales, else the Sales person on shift with the fewest visits today; a `visitor_follow_up` task in the Sales queue with the score, reasons and the contact when known | Admins, customer service, Sales |
| Suggest a similar free car | up to 3 cars sharing a class with theirs, free for their last searched dates, closest daily rate first, with links; staff check the message and send | Admins, customer service, Sales |

Every action is a row of `visitor_actions` (kept like the visits, 90 days). Signal settings shows the week's hot visits,
actions and discount codes (and codes used in 30 days).

## 5. New events (for the privacy policy; analytics consent only)

| Event | Details kept (each checked against a fixed list) | From |
| --- | --- | --- |
| `quote_seen` | days, total (whole dollars), free or not, delivery priced, an additional driver priced | the price block (`Estimate.tsx`) |
| `request_step` | the step number of the request form | the form on screen after a tap (nothing typed is read) |
| `help_open` | the topic of a FAQ question opened (price, deposit, requirements, insurance, cancel, delivery, young, drivers, km, other) | `<details>` in `.faq` |
| `contact_click` | how: call, WhatsApp, text, email, or a copied phone number | links on the page, the copy event (the copied text is not sent) |
| `photos` | how many photos of a car were looked at (3, 6, 10, all) | `Gallery.tsx` |
| `browse` | sorted by price (or other), filters changed, the price limit lowered | the fleet list's address |
| `friction` | a form error, or repeated taps | the form's errors, 4 taps within 0.7 seconds |
| session flag `from_ad` | true when the address had gclid, gbraid, wbraid, msclkid or dclid; the id never leaves the browser | the landing address |

Also: dates changed on a page without a reload are now sent as a search (they were missed before). Without analytics
consent none of this leaves the browser (`allowed()` in `beacon.ts` is unchanged) and the database drops it again.
Nothing typed, no session recording, no network address, no sensitive attribute.

**Privacy policy, section 10 (for the lawyer).** One addition, after "We do not store your network address for this.":

> With the same consent we also note a few actions on those pages: the prices you are shown for your dates, how far you
> get in the booking form, the questions you open, how many photos of a car you look through, how you sort or filter the
> cars, when you tap to call, text, WhatsApp or email us or copy our phone number, when a form shows an error or does not
> respond to repeated taps, and whether you arrived from one of our ads (not the ad's own identifier). We never record
> what you type in a form, and we do not record your screen. From these records we estimate how ready to book a visit
> looks, so our staff can offer help at the right moment, for example a chat or a discount code; this estimate is never
> used to approve, refuse or price a booking.

Applied only where our text is still in place; "Last updated" becomes October 21, 2026 (as 0074 on `quick` does). The
cookie banner's wording is unchanged (no new version, so nobody is asked again).

## 6. CPU and storage

- Signals are computed in the database: `app.visitor_live_eval(session)` runs after 0060's evaluation in
  `app.track_ingest`, only when a batch brought events (heartbeats do not), with one aggregate pass over the visit's events
  (indexed by session) and a few indexed lookups. `app.job_visitor_signals()` (pg_cron every 5 minutes) re-evaluates only
  visits seen in the last hour and not evaluated in the last 4 minutes, for the time-based rules (left after the price).
- The Live page reads stored rows (`visitor_live_signals`, `visitor_sessions.score`), no computing per render.
- The beacon grew by a few listeners (delegated click, copy, toggle, invalid) and stays batched.
- New tables: `visitor_signal_rules` (35 rows), `visitor_signal_config` (1 row), `visitor_live_signals` (per visit, deleted
  with the visit), `visitor_actions` (90 days), `vehicle_pairs_daily` (counts without a person, a year). Column
  `vehicle_interest_daily.quotes`.

## 7. Access

Reads and actions go through the door (`app.ops86`) and `/api/staff/live`: Live visitors staff only (Admins, customer
service, Sales); rules and settings are changed by Admins only; discount codes by Admins and Sales (customer service when
allowed). The browser roles execute none of the new functions and read none of the new tables.

## 8. Guides

Admin and VA guides, chapter "Live visitors and live chat": the likelihood, the signals, hot alerts, the actions and
Signal settings (`docs/guides/src/guides/admin.py`, `va.py`, exported to `docs/guides/content/*.json`, published by the
migration). The PDFs are printed again by the guides-pdf workflow.
