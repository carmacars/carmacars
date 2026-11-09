# Fleet takes payments and calls, Sales sees numbers masked, the site's Call button, one alert per booking moment (Release 35, part Z: 0970, 0971)

Branch `r35-z` (on `r35-v`). Migration `0970_r35z_roles_alerts.sql`; guides in `0971_r35z_guides.sql`. No applied migration is
edited: functions are wrapped (`_pre0970`) or patched in place. Tests: `supabase/tests/99_r35z_roles_alerts.sql`,
`web/src/features/phone/twilio.test.ts`, `web/src/features/shared-pages/viewer.test.ts`; updated expectations in
`99_booking_moments.sql`, `99_staff_alerts.sql`, `99_r34n_caller_popup.sql` and `tests/e2e/shared-pages.spec.ts` (listed
below). SCHEMA_MARKER 0971.

## 1. Fleet collects payments and has its own phone lane

The owner: Fleet "can COLLECT payments (pay links, charge saved card, deposit holds, record cash/e-Transfer pending Finance
check; NOT refunds/voids), and take and make calls and texts ... on its own Fleet lane, separate from Customer service".

- Money: `app.user_collects_money` (Finance, Fleet or an Admin) now guards charging the saved card and the deposit hold on the
  card on file; `app.card_collect_allowed` (pay links, the card on the renter's phone, the reader) includes Fleet. Fleet records
  cash or an e-Transfer on a booking within its single limit (`app.booking_payment_allowed`, `app.record_manual_payment`), and
  each one raises a To do for Finance, "Check the payment Fleet recorded" (`manual_payments_z_fleet_check`). Captures, releases,
  refunds and voids stay with Finance and the Admins.
- The booking page: Fleet gets the Money tab (`bookingCan.money`, `manualPayments`, `collectOnly`), the Text button's inbox, and
  never the Refund button, offers, cancellations or extras.
- The lane: `app.phone_lane(renter, booking)` is `fleet` when the call or text is about a car on rent, or a pickup, return,
  delivery or collection within a day; `cs` otherwise. The caller pop-up (`app.caller_live`) now shows to Fleet: Fleet sees its
  lane's calls; customer service sees its own and a Fleet call when no Fleet staff member is on duty or nobody answered it within
  20 seconds; Admins see every call. The staff portal shows the pop-up to Fleet (`app/staff/layout.tsx`).
- Texts and calls for Fleet: Fleet > More fleet > Calls and texts (`/staff/fleet/calls`), the inbox on Fleet's lane; the inbox has
  Fleet and Customer service tabs, each conversation says its lane.

## 2. Customer numbers hidden from Sales only

- Every read a Sales rep makes through the door (`va_read`, `va_list`, `ops_read` while working as Sales, not an Admin) comes back
  with customer numbers masked, "(647) •••-••00" (`app.mask_phones_in`); our own number stays. Search by phone still matches on
  the server. In-app alerts and phone alerts to a Sales-only person carry masked numbers and no Call button with the number.
- The Call and Text buttons (`ContactButtons`) show the masked number with no `tel:` or `sms:` link and nothing to copy; the server
  finds the real number (`app.server_phone_unmask`, only numbers this person was shown, `phone_masks`).
- Admins, customer service and Fleet see full numbers. An Admin can reveal a masked number (Reveal, when viewing as a Sales rep):
  every reveal is in the audit log (`phone_reveal`).

## 3. The site's Call button through Twilio (item 13, decided November 8)

- `POST /api/staff/phone {action: 'phone_call'}`: the server makes the call with Twilio's REST API (`Calls.json`, Basic auth with an
  API key) to the signed-in staff member's own cell (their profile phone), caller ID the CarmaCars number (`TWILIO_CALLER_ID`, else
  Site settings). When they answer, `/api/webhooks/twilio/voice` returns TwiML that says "CarmaCars call. Connecting you now." and
  dials the customer with the same caller ID; `/api/webhooks/twilio/dial` gets the customer leg's status and length,
  `/api/webhooks/twilio/status` the staff leg's.
- Each webhook carries our own per-call token (HMAC-SHA256 of the call id with the API secret); with `TWILIO_AUTH_TOKEN` set,
  Twilio's `X-Twilio-Signature` is checked too (`web/src/features/phone/twilio.ts`, unit tested).
- Each call is kept in `outbound_calls` and written to the conversation, the renter's, the lead's and the booking's history
  (`phone_activity`, "Call from the site: connected, 2 min 5 s").
- `app.sales_call_minutes(user, from, to)` and the read `my_call_minutes`: "My call minutes" on the Sales home (today, this week,
  this month); an Admin's read carries the team's month.
- Secrets: `TWILIO_ACCOUNT_SID`, `TWILIO_API_KEY`, `TWILIO_API_SECRET` (and optional `TWILIO_CALLER_ID`, `TWILIO_AUTH_TOKEN`) are
  passed to the Worker by the deploy like the other secrets. Without them the Call button opens Quo as before and says why;
  for Sales (masked numbers) it says to ask customer service or an Admin.

## 4. One staff alert per booking moment (item 18, CC-10077 at its 5 pm return)

- `app.not_back_alerts`: one urgent alert per booking and return time (rule `booking_not_back`, dedupe on the booking and the
  stage): "CC-10077 not back: due 5:00 pm, renter reminded, return check-in not started", with Call and Open. It goes to the
  Admins, the person on the return job and every Fleet staff member, each once; the Admins and the field staff member get it by
  text too. The old two notices (`staff_not_back`, `staff_not_back_admin`) are no longer made.
- Copies of renter messages about a booking ("Sent to ...: please return the car now") are no alert of their own: they are in the
  booking's activity, and the not-back alert says whether the renter was reminded.
- A return job running late for a car that is not back is in that alert, not a "Job running late" of its own
  (`app.job_late_folded`); Fleet's stage alerts before the not-back minutes are folded in too.
- The renter's overdue chase (`renter_return_due`, T13, T14 from the reminders job) waits `late_chase_grace_minutes` (15) after
  the return time and stops as soon as staff press Returning now on the late panel (`bookings.returning_now_at`, for that
  return time), the return job starts, or the car's tracker reports it within `late_chase_at_place_km` (0.3 km) of our location
  (`app.renter_chase_paused`). The late panel's own T13 and T14 buttons still send at once.

## 5. Quiet hours: one summary when they end (item 15)

- A phone alert held by a person's quiet hours is marked (`push_outbox.quiet_hold`). When the quiet hours end and two or more
  wait, they go as one summary, "While your alerts were quiet: N alerts", grouped by the alert's group, newest first, opening
  Alerts (`app.push_quiet_summary`, run before each push batch). Each alert stays in the Alerts feed with its own link. Urgent
  alerts keep the urgent rules (never held). Off with `alert_quiet_summary`.

## 6. Hiring

- After one-step Hire (which sets the function and the first day) there is no "Offer accepted ... Set their function and first
  day" alert; instead one alert per hire: "<name> hired as <role>, starts <date>, training not started", opening their academy
  progress. A hire made the older way keeps the "Offer accepted" alert, now opening that candidate's page.
- One-step Hire works from any stage, a candidate referred to another role included: it hires into the role chosen in the Hire
  form and sends no booking link (`app.hiring_hire`, `app.hire_preview`, the candidate page).

## 7. The server check email

- `infra/vps/bin/health-local`: each failing pg_cron job with its last error message and whether the run after it succeeded. A
  job is a problem (and the check emails) only when its latest run failed or 2 or more runs in a row failed ("failed 2 runs in a
  row (last at 16:20), next run ok: ..."); one failure followed by a good run is a note (`cron_notes`, "failed once at 16:15,
  next run ok") and sends no email.

## Test expectations changed (minimal)

- `99_booking_moments.sql`: the not-back counts read the one `booking_not_back` alert; the return time notice is not sent inside
  the 15 minute grace (T13 at 15 minutes is the first chase).
- `99_staff_alerts.sql`: a renter late notice about a booking no longer makes a mirror alert.
- `99_r34n_caller_popup.sql`: Fleet gets the pop-up; the refusals are checked with Sales.
- `tests/e2e/shared-pages.spec.ts`: Fleet has the Money tab and the payments received another way.
- `tests/e2e/sales-request-offer.spec.ts`: Sales sees the renter's number masked with Call and Text, no `tel:` link.
- `03_flows.sql`: `phone_masks` joins the tables written only by the system (not audited row by row).
- `07_notifications.sql`: section D runs without the overdue grace, and Fleet's 0-minute alert is in the not-back alert.
- `08_booking_app.sql`: the booking history gains the kind `returning_now`.
- `55_quo_phone.sql`: Fleet reads the phone inbox (its lane).
- `82_offers_and_rentals.sql`: Fleet starts a card payment; the saved card's refusal names Fleet.
- `99_offer_claims.sql`: the renter's mobile reaches the Sales page masked.
- `99_r32_booking_flows.sql`: the saved card's refusal names Fleet.
- `99_r35v_message_dedupe.sql`: reads the reminders job's body from `notify_reminders_pre0970`.

## Guides

- `va/fleet`: Fleet's payments, its calls and texts, Returning now.
- `va/texts-and-calls`: the lanes, the Call button through Twilio, numbers hidden for Sales.
- `va/sales`: call minutes, hidden numbers.
- `admin/alerts-the-bell-and-your-phone`: one alert per booking moment, the renter's overdue grace, the quiet hours summary.
- `admin/texts-and-calls-the-quo-phone-line`: the Call button, its secrets, Reveal.
- `admin/hiring`: Hire from any stage, the one alert per hire.

## Follow-ups (integration)

- Academy: two Fleet sections (`new-r35-fleet-payments`, `new-r35-fleet-phone`) on the fleet path, migration
  `1040_r35z_fleet_academy.sql`, generated by `supabase/seed/1040_gen_academy.mjs` from `supabase/seed/academy/r35z.mjs`. Fleet
  staff who had passed their whole path keep a week before the new sections hold them.
- The Admin's team view of Sales call minutes: `my_call_minutes` already returns the team's month for an Admin; the Sales team page
  (`SalesTeam`, the Admin portal and the staff Sales lead area for an Admin) has a Call minutes, this month column.
