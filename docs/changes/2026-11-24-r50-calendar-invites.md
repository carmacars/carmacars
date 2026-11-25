# Calendar invites by email: the weekly townhall and interview calls (Release 50: 5000)

Migration `5000_r50_calendar_invites.sql`, generator `supabase/seed/5000_gen_catalogue.mjs`, emails
`emails/src/emails/staff_townhall_invite.mjs` and `staff_townhall_cancelled.mjs`, `supabase/functions/send-outbox`
(`inlineFiles`), `web/src/app/api/townhall-ics/route.ts`, test `supabase/tests/99_r50_calendar_invites.sql`.

## What it does

- **Townhall, every staff member and Admin**: an email with an `.ics` attachment (`text/calendar; method=REQUEST`): one
  event, UID `townhall@carmacars.ca`, `RRULE:FREQ=WEEKLY;BYDAY=<the townhall's day>`, `DTSTART;TZID=America/Toronto`
  with the Toronto `VTIMEZONE` (EDT/EST rules), `ORGANIZER` hello@carmacars.ca, the person as `ATTENDEE` (RSVP),
  `LOCATION`/`URL` the in-site call page `https://carmacars.ca/staff/townhall/live`, a 15-minute alarm. Gmail, Google
  Calendar, Outlook and Apple Mail show Add / Yes.
- **When**: the migration sends it to everyone on the team at once; then `app.townhall_invites_sweep` (the townhall job,
  every 15 minutes, and at once on a change) sends it to whoever joins (staff_is_member, or an active Admin), an
  **update** (same UID, SEQUENCE + 1) when an Admin changes the day, the time or the length, a **METHOD:CANCEL** with
  `RECURRENCE-ID` for one townhall cancelled ahead (Townhall > Meetings; later invites carry it as `EXDATE`), the series
  again when it is put back on, and a **METHOD:CANCEL** of the series to someone who left the team.
- **Interview calls**: the booking confirmation (`applicant_booked`) carries a REQUEST for the booked slot (UID
  `interview-<application>@carmacars.ca`, Toronto time, the call's link or "Phone call" as the place, how to move it); a
  moved call is an update of the same event; the next email while the call is off (cancelled, released for no
  confirmation, declined) carries the CANCEL. The place is read at send time, so a Google Meet link that arrived later is
  the one in the file.
- **Record**: `calendar_invites` keeps every invite and cancellation (method, UID, SEQUENCE, times, place, attendee).
  RLS with `admin_all`, the audit trigger.
- **Sending**: `app.outbox_inline_files(outbox id)` gives the file (built from the record by `app.calendar_invite_ics`);
  send-outbox attaches it on every provider (SES, Resend, Cloudflare). The emails are CarmaCars-branded, never folded into
  the staff digest, never a text.
- **Add to calendar** (`/api/townhall-ics`): the same event as METHOD:PUBLISH from the database (`door ops_read
  townhall_ics`); the TypeScript builder is gone, so the download and the emails cannot differ.
- `/staff/townhall/live` and `/admin/townhall/live` exist (the invite's place): until the in-site call ships they open the
  townhall page.
- **Security**: every function security definer, `search_path = public, app, pg_temp`, the server role only.

## Guides

No guide change: the townhall chapter already says to add the townhall to your calendar; the invite now arrives by
email by itself.
