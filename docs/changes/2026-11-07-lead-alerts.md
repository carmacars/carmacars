# Staff alerts: leads, visitors and one rule-based alert system (0460 to 0467)

The owner: "I'll get alerted for literally everything right? And each staff member gets alerted for every single thing
relevant to them. For example active visitor, signals, requests, leads, games, unfinished forms or partial leads."

Why: the phone alerts of 0300 covered requests, payments, handovers, messages and urgent notices. Nothing told staff
about a new renter lead, a request typed and not sent, a new owner lead or a visitor turning Hot.

## The four notices

In the app and on the phone only (`has_email = false`: the daily email limit is untouched). No text: the staff text
pattern (0430) is per alert with no opt-in, and these are frequent, so a text would cost real money; revisit if wanted.

| Code | Made when | Topic |
| --- | --- | --- |
| `staff_lead_new` | A row is added to `leads`: contact form, phone number box (`phone_gate`), discount game claim, live chat, insurer, launch notice, sample car or another form. Names the source. Not for an unsent form (its own alert), a test address, a lead a person made on the phone, a Turo guest or owner recruitment. | `leads` |
| `staff_request_unfinished` | `app.job_capture` finds a booking request or contact form capture not sent `capture_continue_minutes` (30) after the last typing. Once per capture. | `leads` |
| `staff_owner_lead_new` | An owner lead is made (the list-your-car form, or an unfinished application when it becomes an owner lead: "Website form, unfinished"), and again when the 30-minute chase starts (`chased_at`, 0344). Not for leads added by hand. | `leads` |
| `staff_hot_visitor` | `visitor_sessions.hot_at` is first set. Analytics consent only, renters only, not signed-in staff, not a test address, Live visitors' `notify_hot` on. Key `visitor:day`: at most once per visitor per day. | `visitors` |

## Who

The Admins always (every Admin account that is active and not a test account; the shared Admin account is one, every
device that turned alerts on gets it). Plus, from `app.lead_alert_users`:

- Renter lead and unfinished request: the person the lead (or the capture's follow-up task) is assigned to; if nobody,
  customer service and Sales on duty (Live chat, Live visitors or Texts open within `chat_shift_minutes`, own or
  covered function). With nobody on duty only the Admins are alerted.
- Owner lead: the Sales person it is assigned to (Sales see only their own, 0342) and the Admins. An unassigned owner
  lead reaches the Admins only; the chase assigns it and alerts the assignee.
- Hot visitor: customer service and Sales on duty.
- Never a test account (`app.staff_is_test`); implemented as an outer `notification_recipients` wrapper like 0370.

## Topics and quiet hours

`leads` and `visitors` join the push topics (catalogue and preference constraints, `push_set_topics`). On by default for
Admins, and for customer service and Sales (`app.push_user_defaults`; Fleet, Finance and field staff do not get them
by default but can switch them on). People who had already chosen topics get the two added. A `leads` notice is queued
as urgent (patched into `push_from_notice`); staff alerts were never delayed by the customer quiet hours, so leads go at
once at any hour unless the person turned the topic off on their alerts card.

## Noise

One alert per lead, capture, owner lead stage and visitor per day (the event dedupe key). The outbox has no grouping, so
the grouping is made before the alert: more than `notify_lead_burst_count` (5) lead and unfinished alerts inside
`notify_lead_burst_minutes` (10) become one "N new leads in 10 minutes" alert (to the Admins and those on duty); the
rest of the window adds nothing. An assignee whose lead fell inside a burst sees it on Leads, not as its own alert.

## Settings

Program settings > Text alerts, "Staff alerts for leads and visitors": `notify_lead_new`, `notify_request_unfinished`,
`notify_owner_lead_new`, `notify_hot_visitor` (all on) and the burst count and window. Each person's per-device Leads
and Visitors toggles are on their alerts card (`web/src/features/push/topics.ts`).

## Tests

`supabase/tests/99_staff_alerts.sql` also covers 0465 and 0466: a sample of every group, test accounts, quiet hours, focus,
device topics, the buttons (a lead's Call), snooze, escalation to the next person on duty then the Admins, grouping, sign-in
security and the deploy result. `99_push_alerts` counts 145 notices with a topic. e2e `web/tests/e2e/staff-alerts.spec.ts`:
the bell, the feed (filters, mark read, snooze) and the settings (quiet hours, focus, the rule table) at 375 and 1440 with
axe. Unit: `web/src/features/alerts/types.test.ts`.
`supabase/tests/99_lead_alerts.sql` (emit, routing, assigned and on duty, dedupe, test accounts, consent, switches,
push topics and urgent flag, burst). `07_notifications` (15 in-app notices) and `99_push_alerts` (105 notices with a
topic, the new defaults) updated; `99_staff_alerts.sql` (rules, tiers, quiet hours, dedupe, test accounts and a sample of each group); `topics.test.ts` for the card's topics and the store link.

## One system: rules, emitter, feed (0462)

`staff_alert_rules` (rule, who, tier, topic, enabled, wired, fixed) is the table behind every staff alert; `app.staff_alert`
is the one emitter; the three notices `staff_alert_urgent`, `staff_alert_normal`, `staff_alert_digest` are the feed (the bell
and notifications list). Tiers: urgent pushes at once at any hour; normal pushes held to the end of the staff quiet hours
(21:00 to 8:00); digest is an in-app line and a daily staff digest item, never a push (patched into `push_from_notice`; the
topic comes from the rule). Who: `admin`, `assigned`, `on_duty:<fn>`, `unassigned_on_duty:<fn>`; never a test account. Admins
now default to all nine topics. `docs/alerts/matrix.md` lists every role and every alert.

Wired (`wired = true`): the mirror of what goes out to renters, owners and investors (`sent:*`, from `notification_outbox`),
the booking steps (confirmed, out, back, closed, no-show, offer sent, offer expiring), payments over `alert_money_threshold_cents`,
refunds paid, reviews (3 stars or less urgent), tolls, field jobs (assigned, started, finished, late), job applications, usage
alerts, the morning brief, the evening wrap and cash summary, and escalation (an urgent alert a non-Admin did not open in
`alert_escalate_minutes` goes to the Admins). The job `app.job_staff_alerts` runs every 5 minutes.

Since 0465 and 0466 every rule is wired (below).

## Customer push topics and the app download prompt (0463)

Every time-sensitive renter and owner notice that had no push topic now has one (renter started-rental, requests, signed
documents, review asks; owner application steps, agreements and forms, bank change, tolls, exit, debits, invoices, listings),
mapped in the matrix with the partner, referral partner and applicant gaps. Program settings `app_store_url` and
`play_store_url` (empty): when set, phones see "Download the CarmaCars app" instead of the browser steps (iPhone: instead of Add
to Home Screen); desktop keeps browser alerts; inside the app (user agent token `CarmaCarsApp`) the native prompt is used.
Prompt moments: see 0466.

## r27 merged: tracker, interviews, data health, deletion, academy (0464)

Built on origin/r27. The tracker alerts of 0400 (offline, left the zone or Ontario, speeding, still driving after the return
time, battery low or unplugged) were already urgent notices to the Admins and fleet staff but had blank titles; their words now
come through, they appear in the rule table (five rows) and a rule switched off stops its kind. A scored AI interview (0380) is
one normal alert to the Admins with the score and the suggestion. The nightly data health notice (0441) now reaches the phone
(topic alerts). A request to delete an account (0390) is an urgent alert; a passed or failed academy quiz is a digest line.
The customer portal pages of r27 already show the topic switches and the download prompt (the profile tabs use PushAlerts).
The data health notice and usage over 80% became in-app only in 0465, as the owner asked.

## Every rule with data wired (0465)

`app.staff_alert` now also fires for: offer viewed (Live visitors' `offer_viewed`, consent only) and accepted, extension asked
(with Approve and Decline) or paid, a change asked by the renter or applied, cancellation, deposit released, deposit hold failed
and card declined within 12 hours of pickup (urgent), owner debit failed (urgent), investor money and investor signed, owner
gives notice and owner banking changed (urgent; the first account is the set-up, not a change), the handover checklist incomplete
(details pending, licence or card not seen, no signature, no fuel or km), fuel 10 points lower or km over the allowance at
return, complaint words (Program setting `alert_complaint_words`) in chat or an inbound text or email (once per conversation a
day), unsubscribes and text STOPs (digest), licence to review, agreement signed (digest), service due (digest), a car paused or
unpublished, interview link expired, applicant hired, academy lesson finished (digest), quiz failed twice, certified (every
section of a path passed), first booking of a car, an owner's first payout. The 5-minute job adds (`app.sa_scheduled`): agreement
not signed 2 hours before pickup (urgent), insurance proof missing 24 hours before, insurer booking without a claim number, Sales
late (15 minutes) or idle (2 hours) inside their availability block (`sales_availability`, the only staff hours data), a record
day and, on Sunday, a record week at 21:00, the month's totals on the 1st at 8:00. Seven time-sensitive owner and renter notices
that had no push topic get one (re-signing, the PAD confirmation, the registry visit, a fee change cancelled, the recovery offer
and change, named to an authority). The rule table has 90 rows, all wired.

## Handy features (0466)

- **Alerts feed** behind a new bell in the Admin and staff frames (`/admin/alerts`, `/staff/alerts`): All, Unread, Urgent; open
  marks read; Mark all read; Snooze 30 min on urgent ones. Settings tab: phone alerts (with "a different choice on this device
  only": `push_subscriptions.topics`), quiet hours and focus mode (`staff_alert_prefs`), and for the Admins the rule table (each
  rule on or off, its tier; the lead rules keep their tier).
- **Quiet hours**: no row, the normal tier waits until 8:00 as before; once a person saves their hours they apply to every
  non-urgent staff push. **Focus mode** (1 or 3 hours): only urgent pushes.
- **Buttons** on staff pushes (`push_outbox.actions`, two at most): Call (the lead's, unsent request's or renter's number through
  `/alerts/call`, which hands it to the dialer, the Quo app where it handles calls), Send offer, Approve and Decline (they open
  the booking's tab; nothing is decided from the lock screen), Mark picked up, Snooze 30 min (`/api/alerts/snooze`; the push is
  queued again and escalation waits).
- **Escalation**: unopened urgent alert after `alert_escalate_minutes` goes to the next person on duty of the rule's function
  ("Passed to you", rule `escalation_duty`), then to the Admins after the same time again (or at once when nobody is on duty).
- **Grouping**: more than `alert_burst_count` (5) alerts of one non-urgent rule in `alert_burst_minutes` (10) push once as
  "N or more alerts: rule" (rule `alert_group`); each stays in the feed.
- **Morning brief per person**: Sales their open leads and offers waiting, customer service requests, chats and their tasks,
  fleet pickups and returns, field staff their jobs and the first one's time (none on a day without jobs).
- **Sign-in security**: the sign-in form records each password sign-in (`sign_in_events`: browser and system, Cloudflare's
  country, no address; kept 90 days). An Admin from a device or country not seen in 180 days, and 5 failed sign-ins on one
  address or 20 in all within 10 minutes, are urgent alerts. **Deploy result**: the deploy job's last step calls
  `server_deploy_result` (finished or failed).
- **Prompt moments**: a renter whose booking is confirmed is asked on that booking's page, with its own "Not now"; owners and
  staff on their portal's first page as before.

Still TODO (no data source): the investor live sheet month closing, and push to referral partners and job applicants (no
sign-in). docs/alerts/matrix.md lists every role and alert.

## Needs the owner

Nothing to set up. For a phone to be alerted a person must have turned phone alerts on (Settings > My phone alerts, or
Profile for staff) and be on duty for the unassigned alerts.

## Guides

- `admin/text-alerts-email-text-or-both` (new sections "Lead and visitor alerts" and "Everything else that alerts you")
- `admin/alerts-the-bell-and-your-phone` (new chapter: the list, what alerts you, the buttons, who gets what, the settings)
- `va/live-visitors-and-live-chat` (section "Alerts on your phone": the bell, the function alerts, the buttons, quiet hours and focus)
- `field/report-rentals-referrals-and-profile` (new section "Alerts")

Published by 0461 and 0467 (`supabase/seed/0461_gen_guides.mjs`, `supabase/seed/0467_gen_guides.mjs`). SCHEMA_MARKER stays
0490 (r27's highest is above this range).
