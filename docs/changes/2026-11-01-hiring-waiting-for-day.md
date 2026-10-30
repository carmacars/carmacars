# No interview invitation without an open call time (0211)

Production, October 30, 2026: a Field staff applicant got "Let's talk, book a call" at 12:01 am and the booking page had
no times: the last interview day for Field staff and Sales in person was Thursday, October 29. Migration
`supabase/migrations/0211_hiring_waiting_for_day.sql`; email `emails/src/emails/applicant_new_times.mjs` (catalogue row by
`supabase/seed/0211_gen_catalogue.mjs`). Code: `web/src/features/careers/BookingPicker.tsx`, `web/src/app/admin/hiring/page.tsx`.
Tests: `supabase/tests/99_hiring_waiting_for_day.sql`, `web/tests/e2e/release-21b.spec.ts`.

- The invitation (`applicant_invited`) goes only while the role has an open call time (`app.hiring_open_slots`: a future slot
  of an active day for the role with a place left). Otherwise the applicant is invited and waiting for a day
  (`job_applications.waiting_for_day`); no email.
- The booking link with no open time says "No call times are open right now. We'll email you as soon as new times open."
  and records the visit (`no_slots_seen_at`; `no_slots_since` for one already emailed).
- Admin > Hiring: for each role, "N applicants invited but no interview day is open for <role>" with Add an interview day.
- Adding or opening a day (`hiring_day_save`) releases them (`app.hiring_release_waiting`): the waiting invitation goes, and
  those already emailed with no time open get **New times are open** (`applicant_new_times`). The applicants invited before
  this release while no time was open are marked at migration, so they get it with the next day.

## Guides

- `admin/hiring`: the note on candidates waiting for a day.
