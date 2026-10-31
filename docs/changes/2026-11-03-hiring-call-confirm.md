# Interview calls by role, remote calls confirmed, Quo texts counted (0229)

The owner, Release 23:

- **Phone or video follows the role.** Field staff and Sales in person are always called by phone (recorded with Quo),
  the remote roles (the three assistant roles and Remote Sales) always meet by video (a Jitsi link). An interview day's
  How is only the default shown. `app.hiring_mode(role)` is used by the booking, its emails, the booking page and the
  Calls tab. Future bookings that had the other way were put right by the migration, each with one corrected booking
  email (a phone call names the candidate's number; a video call gets its link).
- **Remote calls: one confirmation, no reminders.** No reminder emails and no texts for the remote roles. 24 hours before
  the call (at once when booked closer than that) one email, `applicant_confirm`, with **Confirm my call**: the candidate's
  link, no sign-in, one press on the page it opens (a button rather than the link itself, so a mail scanner opening links
  cannot confirm a call). Not confirmed within 12 hours of that email, or by 1 hour before the call, whichever is sooner:
  the call is cancelled, the time opens again, and one short email, `applicant_unconfirmed`, links to book again. A call
  booked again asks again.
- **Calls tab:** Confirmed, Waiting or Asked 24 hours before for each remote call; "Cancelled: not confirmed" for the
  last 7 days.
- **In-person roles** keep their reminders as before (email; a text only while hiring texts are on).
- **Settings > Usage:** "Texts this month (Quo)", the texts the phone job sent through Quo, about US$0.01 each, with the
  cost so far; the alerts (email and the Admins' texts, 0221) at 80% and 100% of 300 a month (change the allowance there).
- Code: `web/src/app/careers/book/[token]/confirm/page.tsx`, `web/src/features/careers/ConfirmCall.tsx`,
  `web/src/server/actions/careers.ts` (confirmCall), `web/src/app/admin/hiring/page.tsx`. Emails
  `emails/src/emails/applicant_confirm.mjs`, `applicant_unconfirmed.mjs` (catalogue rows by `supabase/seed/0229_gen_catalogue.mjs`).
- Tests: `supabase/tests/99_release_23.sql` section 9, `web/tests/e2e/release-23.spec.ts`.

## Guides

- `admin/hiring`: Phone or video, and the remote calls confirmed.
- `admin/usage-and-paid-usage`: Texts this month (Quo).
