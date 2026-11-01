# Messages when a booking starts and ends, also when the pickup was never recorded (0430, 0431)

The owner, November 1: "There isn't enough messaging and emails when a booking is ending or starting. The booking that
ended 44 mins ago, I had to manually reach out to them."

Why it happened: every reminder and late notice of the end of a rental (the 24-hour return reminder T6, the late
notices T13 and T14, the staff late alerts, the late tasks) required status `on_rent`. A booking whose pickup nobody
tapped stays `confirmed`, so it got nothing at its end, although Bookings > Now already counted it as out ("pickup not
recorded"). That afternoon every overdue booking was one of those.

## Out, for messaging

`app.booking_is_out(booking, now)`: on rent, or confirmed with its pickup time passed and no handover or check-in
recorded (not a placeholder, and not "ended, never closed", 0330). It never changes the status. Every renter reminder
and late notice of the end of a rental, the staff late alerts, the late tasks of ops-watch, the late panel and its
T13 and T14 buttons use it. A confirmed booking counts for the late notices for 24 hours after its return time, so no
old booking is chased. Bookings > Now already used the same rule (0330) and is unchanged.

## What the renter gets

By email, by text (their channel, 0096) and as a phone alert where they turned alerts on (0300). Each once per booking
and per pickup or return time: a moved time (an extension) sends it again.

| When | Code | Text |
| --- | --- | --- |
| The day before pickup | `renter_booking_reminder` (T5, as before) | unchanged |
| About 2 hours before pickup (new) | `renter_pickup_soon` | CarmaCars: see you today at {{pickup_time}} for the {{vehicle_name}} at {{pickup_place}}. Bring your licence and the card you booked with. Details: {{link}} |
| 30 minutes after a pickup nobody recorded (new) | `renter_trip_started` | CarmaCars: you're all set with the {{vehicle_name}}. Return by {{return_date}} at {{return_time}}, {{return_place}}. Trip details and help: {{link}} |
| The day before the return | `renter_return_reminder` (T6) | unchanged; now also for a pickup not recorded |
| About 3 hours before the return (new) | `renter_return_soon` | CarmaCars: booking {{booking_number}} ends at {{return_time}}. Please return it to {{return_place}} with the same fuel, clean and with all keys. Need more time? Extend: {{link}} (the Extend page) |
| At the return time (new) | `renter_return_due` | CarmaCars: your booking {{booking_number}} ended at {{return_time}}. Please return the {{vehicle_name}} now, or extend here if you need more time: {{link}} (the Extend page) |
| 15 minutes late (was at 0) | `renter_late_return_first` (T13) | CarmaCars: booking {{booking_number}} is past its return time of {{return_time}}. Late fees start 30 minutes after it. Please return the car now or extend: {{link}} (only where an Admin had not changed it) |
| 2 hours late | `renter_late_return_final` (T14) | unchanged; at least 30 minutes after T13, never in the same run |

- T5 and T6 are skipped when the pickup or the return is already inside the window of the shorter reminder (the old
  "Tomorrow" email for a pickup that is today).
- `renter_trip_started` never goes after `renter_rental_started`; when the pickup is recorded later the rental-started
  email (with the condition report) still goes.
- The late notices and the short reminders go from 7 am to 10 pm Toronto time. Overnight the job does not send them
  and checks again at 7 am; a car returned in the night gets nothing. Their texts are urgent so the text quiet hours
  (9 pm to 8 am) do not hold them past the pickup or return.
- T13 and T14 were already automatic; the late panel's buttons send the same events (same keys), never twice.
- Insurer-billed bookings message the renter like any other. Opt-outs, each person's channel, the email limit and the
  quiet hours apply as before; while emails are held for the email limit (0212) these seven go by text at once too.
- The emails: `emails/src/emails/renter_pickup_soon.mjs`, `renter_trip_started.mjs`, `renter_return_soon.mjs`,
  `renter_return_due.mjs` (catalogue block of 0430 from `supabase/seed/0430_gen_catalogue.mjs`). The trigger texts of
  T5, T6, T13 and T14 say the new timing.

## What staff get

In the app and as a phone alert (in-app only codes: nothing from the daily email limit), and by text to the phone on
their profile.

- `staff_pickup_unrecorded`, 30 minutes after the pickup time with no handover or pickup report: the field staff of the
  handover (alert and text "CarmaCars: record the pickup for CC-xxxxx (car, due 2:00 pm), or mark it a no-show: job
  link") and Fleet in the app, and one Fleet task "Record pickup for CC-xxxxx, or mark no-show".
- `staff_pickup_unrecorded_admin`, at 3 hours: the Admins, with an Admin task.
- The tasks close themselves when the booking leaves confirmed (picked up: done; cancelled or no-show: cancelled). The
  late tasks close when the booking is closed or cancelled too.
- `staff_not_back` and `staff_not_back_admin`, 15 minutes after the return time with no return recorded: the field
  staff of the return (else of the handover) and the Admins, alert and text "CarmaCars: CC-xxxxx not back, due 5:00 pm
  (car). Renter name, call phone. Booking: link", at any hour. Fleet's late emails and the late_return_admin task are
  as before.

## Settings

Settings > All settings, Text alerts, "Booking start and end": one switch per moment (all on) and its minutes or hours;
the same values are in Program settings under Email and notifications. Each new text is in the list of texts on the
same page (edit, off, urgent).

## Database

- 0430: `app.booking_is_out`, `app.booking_pickup_unrecorded`, `app.renter_notice_hours`, `app.staff_text`,
  `app.notify_booking_staff`; `app.notify_reminders` rewritten (the same loops, out instead of on_rent, the new
  moments); `app.job_ops_watch`, `app.late_panel` and `app.late_action` patched in place; `app.notification_payload`
  wrapped (the Extend and pickup links); 15 `notify_` settings; two task rules; catalogue rows, texts and push topics.
- 0431: the guide chapters.
- Tests: `supabase/tests/99_booking_moments.sql` (a confirmed booking never picked up gets the whole end, the insurer
  booking too, cancelled and returned get nothing, dedupe, a moved return time re-arms, the overnight hold and T14
  after T13, the pickup not recorded alert, text, task, escalation and closing, the late panel's T13 for a confirmed
  booking, a switch off).
- Not changed: Bookings > Now (`app.fleet_board`) already counts the same bookings as out.

## Guides

- `admin/text-alerts-email-text-or-both`: Booking start and end.
- `field/a-handover`: finish the handover in the app, or you get the pickup not recorded alert.
- `renter/during-your-trip`: the reminders before the return and the late notices.
