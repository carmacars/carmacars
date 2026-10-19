# Calendar sync, booking recovery emails and the site check (October 19, 2026)

Migration `0062_calendar_sync_recovery_uptime.sql`; tests `supabase/tests/41_calendar_recovery_uptime.sql` (03, 07 and 34
updated); unit tests `web/src/features/calendar/ical.test.ts`; end to end `web/tests/e2e/calendar-sync.spec.ts` (375 and
1440). 8 new emails. No applied migration was edited.

## 1. Calendar sync with Turo and other platforms (both ways, iCal)

Turo, Getaround and most platforms sync calendars through iCal links, so that is what this uses: no platform account,
no API key.

### Import: their trips block the car here

| Part | How |
| --- | --- |
| Where | Admin > Cars > **Calendar sync** (`/admin/calendar-sync`) and Fleet's Cars > **Calendar sync** (`/va/calendar-sync`). Customer service, Finance and Sales cannot add links |
| Links | One or more per car, each with its platform (Turo, Getaround, Other) and an optional name. `webcal://` is read as `https://`. A CarmaCars export link pasted by mistake is refused. The URL is kept in `calendar_feeds` (Admins only by row-level security; the audit log records add, change and remove without the URL) |
| Reading | The `calendar-sync` Edge Function, called every 5 minutes by pg_cron through pg_net (`carmacars-calendar-sync`, scheduled by `scripts/deploy/supabase.sh calsync`). `app.calendar_feeds_due()` hands it the links not read for `calendar_sync_minutes` (10), claimed so two runs never read one link. ETag and Last-Modified are sent back (a 304 keeps everything); 20-second timeout; 3 MB at most; private addresses are never read from the server. **Sync now** on the page reads one link at once through the site with the same code |
| Reader | `web/src/features/calendar/ical.ts` (no imports; the deploy copies it and `sync-run.ts` beside the Edge Function's `index.ts`). Unfolds lines, skips alarms and time zone blocks, keeps events that hold time (not `STATUS:CANCELLED`, not `TRANSP:TRANSPARENT`) from a day ago to 18 months ahead. Times in UTC; with a `TZID` (IANA names, Outlook's Windows names, prefixed paths); floating times and all-day dates in America/Toronto (an all-day event runs midnight to midnight, right across the daylight saving changes); `DURATION`; repeating events (daily, weekly with days, monthly, yearly; `COUNT`, `UNTIL`, `INTERVAL`, `EXDATE`, a moved occurrence by `RECURRENCE-ID`). A web page or anything else in place of a calendar is a failure in words ("The link answered with a web page, not a calendar. Copy the calendar (iCal) link again.") |
| Blocks | `app.calendar_feed_apply()`: each event is a `calendar_feed_events` row holding one `vehicle_calendar_blocks` row, reason `external_booking`, source `external`, note "Turo: <title>", **widened by the car's turnaround before and after**. `app.vehicle_is_available()` already reads every block, so availability, search, the public calendar, request to book and confirmation respect it the moment it is written. A moved event moves its block; an event gone from the link frees it ("No longer in the Turo calendar"); a block a person removed stays removed; turning a link off or removing it frees its blocks |
| Clashes | `app.calendar_conflicts_check()` after every read: an imported event over a **confirmed or on-rent** booking of the car (turnaround counted) raises an urgent Fleet task "Double booking: <car> on Turo and CC-1042", the email `staff_calendar_conflict` (Fleet, also Admins, immediate) and the Admin To do line "Double bookings with Turo or another platform". Over an **offer or a booking awaiting payment**: a customer service task (its payment would be refused); no email. Both close by themselves when the dates no longer overlap |
| Failures | `app.calendar_feed_failed()` keeps the reason in words (404: "the link was removed or reset. Copy it again from the platform."). After `calendar_feed_alert_failures` (3) in a row: a Fleet task and one email `staff_calendar_feed_failing` per run of failures, and the To do line "Calendar links not working". The trips already read stay. The next good read closes the task |

### Export: our bookings block the car there

Every car has a private link `https://carmacars.ca/api/ical/<64 hex>.ics` (`vehicle_calendar_exports`, made for every car,
existing and new). It holds the car's busy times merged, each as "Booked": confirmed and on-rent bookings with the
turnaround (`calendar_export_turnaround`), and every block. Nothing about renters, no booking numbers, no prices. The page
shows one link per platform: `?for=turo` leaves out the trips that came from Turo (no echo), `?for=getaround` likewise,
`?for=other` for any other platform; the plain link leaves out every imported trip. **Make a new link** rotates the token
and the old link answers 404 at once. Each fetch is counted ("Read 12 times, last Oct 19, 2:10 p.m.").

## 2. Booking recovery emails

`app.job_booking_recovery()` (pg_cron `carmacars-booking-recovery`, every 15 minutes) reads the signals of 0060 of known
renters (signed in or arrived from our email).

| Moment | Email | First reminder | Kind |
| --- | --- | --- | --- |
| Offer opened, not answered | `renter_recovery_offer` | `recovery_offer_hours` (4) after it was opened | Transactional (their own pending offer) |
| Pay page left without paying | `renter_recovery_pay` | `recovery_pay_minutes` (60) after | Transactional |
| Change proposal opened, not answered | `renter_recovery_change` | `recovery_change_hours` (4) after | Transactional |
| Request started, not sent | `renter_recovery_request` | `recovery_request_hours` (2) after | **Marketing**: express consent only (the catalogue's consent rule for it is `express`, and the job checks it), unsubscribe link, one series per renter in 7 days |

Rules for all four: at most `recovery_max_emails` (2), the second `recovery_second_hours` (24) after the first; only between
`recovery_send_from_hour` and `recovery_send_until_hour` (9 to 21, Toronto), otherwise they wait; never to a renter who
unsubscribed from our emails (marketing unsubscribe after any consent), who turned that email off in their preferences, or
whose address is suppressed; never while a staff member is already handling the renter (a task on the renter or booking
that a person took or completed, a chat with a person, an outbound message from staff); not when the offer expires within
7 hours or an expiry reminder went in the last 12 hours (`renter_offer_reminder` covers it); not when a change's deadline is
within its own reminder window. Each reminder is a `recovery_emails` row (`subject_key` = the signal). When the renter
answers, pays, sends the request or the offer expires, the series stops for good and a reminder still waiting in the
outbox is marked skipped ("Not sent: the offer was answered, expired or withdrawn"). Every email carries the house style
and the `?m=` link of 0060.

## 3. The site check (uptime and error alerts)

No paid monitor and no GitHub Actions minutes: Supabase's pg_cron and pg_net, which cost nothing.

| Check | How | Fails when |
| --- | --- | --- |
| Home page, a car page (the first public car), sign-in, `/api/health` | `net.http_get` every `uptime_interval_minutes` (5) by `app.job_uptime()` (pg_cron `carmacars-uptime` every minute collects the answers); 15-second timeout | No answer in 3 minutes, a 4xx or 5xx, Error 1102 (named in words), or `/api/health` without `"ok": true` (the Worker could not reach the database). A page alerts after `uptime_fail_threshold` (3) failures in a row, so a single 1102 does not |
| Emails | The outbox | `uptime_email_failures` (3) failed in the last hour, or emails due 15 minutes ago still queued (the sender stopped) |
| Scheduled jobs | `cron.job_run_details` and `job_runs` | A failed pg_cron run or a failed job run in the last hour |
| Nightly backup | `job_runs` `backup-nightly` | The last run failed, or no good backup for `uptime_backup_max_hours` (30) |
| Stripe webhook | `webhook_events` | A Stripe event failed to process in the last hour |

A problem opens one `site_alerts` row (one open per check), an urgent Admin task "Site problem: <check>", the To do line
"Site problems found by the site check" first, and the email `staff_site_alert` to **`uptime_alert_email`
(rent@carmacars.ca)**. While it stays open nothing more is sent. When the check passes again the alert resolves, the task
closes and `staff_site_recovered` says how long it lasted. A new problem of the same kind within
`uptime_alert_cooldown_minutes` (60) of the last alert email opens silently (To do only), so a flapping page cannot flood
the inbox. Results are kept `uptime_keep_days` (14); pg_cron's own run log is trimmed to 14 days.

**Admin > Today**: To do has a **Site health** card: each check (Working, Problem, Not checked yet), what was found, the
failures of the last 24 hours, open problems with what to do, and the problems of the last 7 days.

`/api/health` is new: one small database call (`public.health_ping`), never cached, `{"ok": true}` or 503.

Tests never alert the real address: the database suite and the end-to-end test set `uptime_alert_email` to an
`@example.test` address first.

## 4. Settings (Program settings, new groups)

`calendar_sync_enabled`, `calendar_sync_minutes` (10), `calendar_feed_alert_failures` (3), `calendar_export_turnaround`;
`recovery_emails_enabled`, `recovery_request_hours` (2), `recovery_offer_hours` (4), `recovery_pay_minutes` (60),
`recovery_change_hours` (4), `recovery_second_hours` (24), `recovery_max_emails` (2), `recovery_send_from_hour` (9),
`recovery_send_until_hour` (21); `uptime_enabled`, `uptime_interval_minutes` (5), `uptime_fail_threshold` (3),
`uptime_alert_email` (rent@carmacars.ca), `uptime_alert_cooldown_minutes` (60), `uptime_backup_max_hours` (30),
`uptime_email_failures` (3), `uptime_keep_days` (14).

## 5. Emails (8)

`staff_calendar_conflict`, `staff_calendar_feed_failing`, `staff_site_alert`, `staff_site_recovered`,
`renter_recovery_offer`, `renter_recovery_pay`, `renter_recovery_change`, `renter_recovery_request`. Catalogue rows
generated by `supabase/seed/0062_gen_catalogue.mjs`; `app.notification_catalogue_refresh()` now marks
`renter_recovery_request` as needing express consent.

## 6. Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | 3944 passed, 0 failed (new suite 41, 88 assertions; 03 lists the new sync and check tables among those not audited, whose changes the functions write to the audit log themselves; 07 counts and builds the 8 new emails and 2 links; 34 has the three new To do lines) |
| Unit (`npm run test:unit`) | 144 passed. New `ical.test.ts` (8): the Turo, Getaround and Google sample feeds (`web/src/features/calendar/samples/`), time zones across both daylight saving changes, all-day and repeating events, errors in words, private addresses, one run with a mocked database and platform (not modified, 404, a web page, unreachable) |
| End to end, 375 and 1440 | `calendar-sync.spec.ts` 5 of 5 locally (the clash and site check test at one width): Fleet adds a link (another car's CarmaCars link with a block), Sync now, the block on the car, availability, the public calendar and search, the export link ("Booked" only, per platform), a new link ends the old one, remove frees the car; the clash on To do and Calendar sync; three failures open one alert to a test address, a pass resolves it; a renter opens her offer, one reminder is queued, she approves and it is skipped. `legal-admin-redesign`, `admin`, `staff` and `live-chat` specs: 40 passed. Emails with database values: the 8 new emails, 0 problems |

## 7. Guides

Admin: a new chapter "Calendar sync with Turo and other platforms" (after Calendars), "Recovery emails" in Live visitors
and live chat, "Site health and alerts" in Email, backups and site health (the backup line no longer says nothing is
emailed), the Program settings groups. VA: Calendar sync in Fleet, the recovery emails in Live visitors and live chat.
Released by the 0062 guides block (`supabase/seed/0062_gen_guides.mjs`, base commit 500406c).

## 8. Deploy and checks

RESULT_DEPLOY

## 9. What the owner must do

1. **For each car listed on Turo** (and Getaround or any other platform): on Turo, open the car's calendar settings and
   copy its calendar (iCal) export link; in Admin > Cars > Calendar sync, find the car, **Add a calendar link**, choose
   Turo, paste, **Add the link**. The card should say "Working" with the next trips.
2. **Then paste ours into Turo**: on the same card, **Copy** "For Turo" and paste it into the car's calendar import on
   Turo (and "For Getaround" into Getaround). Turo reads it on its own schedule (often every few hours), so CarmaCars
   bookings reach Turo with that delay; Turo trips reach CarmaCars within 10 minutes. If a platform shows no field to
   import a calendar link for a car, block those dates there by hand; its trips still reach CarmaCars through step 1.
3. Check the first sync of each car: the trips listed should match the platform. The sample feeds in the unit tests are
   in the shapes these platforms publish, not captured from your accounts.
4. Site alerts go to rent@carmacars.ca (Program settings, "Site check"). Expect a few "Error 1102" alerts on the free
   Workers plan if the site is busy; three failures in a row are needed, and Workers Paid removes the cause.
5. The lawyer: the recovery request email is marketing and goes only with express consent; the three others are
   reminders about the renter's own pending booking (transactional), stopped by an unsubscribe as well.
