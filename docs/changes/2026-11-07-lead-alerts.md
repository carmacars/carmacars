# Staff alerts: leads, visitors and one rule-based alert system (0460 to 0463)

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

Not wired yet (rows exist with `wired = false`, listed in the matrix): deposit hold failed, card declined at pickup, investor
money, offer viewed and accepted, extensions, date changes, deposit released, insurer claim number missing, handover checklist
and fuel or km at return, complaint words, account deletion and opt-out, licence review, agreements signed or unsigned before
pickup, insurance proof, tracker offline and geofence (no tracker data on this branch; r27-tracker), maintenance due, car
unpublished, owner notice and banking change, investor invested, Admin new device and failed sign-ins, deploy result, data
health (r27-health), AI interview finished (r27-interviews), academy and staff idle, wins. Not built: action buttons on alerts,
per-person quiet hours and focus mode, generic burst grouping beyond leads, an Alerts inbox filter, a rules editor page (an
Admin or the assistant edits the table), staff text alerts, escalation to a function before the Admins.

## Customer push topics and the app download prompt (0463)

Every time-sensitive renter and owner notice that had no push topic now has one (renter started-rental, requests, signed
documents, review asks; owner application steps, agreements and forms, bank change, tolls, exit, debits, invoices, listings),
mapped in the matrix with the partner, referral partner and applicant gaps. Program settings `app_store_url` and
`play_store_url` (empty): when set, phones see "Download the CarmaCars app" instead of the browser steps (iPhone: instead of Add
to Home Screen); desktop keeps browser alerts; inside the app (user agent token `CarmaCarsApp`) the native prompt is used.
Prompt moments per role (after a booking is confirmed, after owner approval, first staff sign-in) are TODO.

## Needs the owner

Nothing to set up. For a phone to be alerted a person must have turned phone alerts on (Settings > My phone alerts, or
Profile for staff) and be on duty for the unassigned alerts.

## Guides

- `admin/text-alerts-email-text-or-both` (new section "Lead and visitor alerts" and the topic defaults)
- `va/live-visitors-and-live-chat` (new section "Alerts on your phone")

Published by 0461 (`supabase/seed/0461_gen_guides.mjs`). SCHEMA_MARKER 0463.
