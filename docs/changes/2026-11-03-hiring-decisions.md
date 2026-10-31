# Hiring: decisions recorded, decision emails sent together (0226)

The owner (before Monday November 2, when every applicant hears back): the rubric's decision gets "Good fit for Sales
instead"; decisions do not email at once; one list of the emails to send and one button.

- The rubric's Decision: Hire, Maybe, No, Good fit for Sales instead, No show. It is the hiring decision
  (`hiring_decisions`, kept in step): Hire sends the next steps (`applicant_hired`, new), No the polite decline
  (`applicant_declined`), Sales instead the referral with the one-click prefilled apply link (`applicant_referred`;
  Sales in person for Field staff and Sales in person, Remote Sales for the remote roles; a candidate who already applied
  for it gets a note on that application for the shortlist and no email), No show the polite no-show email
  (`applicant_no_show`, new). Maybe sends nothing.
- Hiring > Emails to send: every decided candidate, the email that will go, Change (decision, email on or off, a personal
  line) and Undo (back to Maybe). **Send all decision emails**: now, next Monday 9:00 am Toronto, tomorrow 9:00 am or
  another time (the hiring job sends the scheduled ones). One email per candidate, never twice (dedupe per application);
  the statuses follow (referred, Not hired, No show; Hire still needs the staff account).
- The candidate page shows the decision email and its state.
- Emails: `emails/src/emails/applicant_hired.mjs`, `applicant_no_show.mjs` (catalogue rows by `supabase/seed/0226_gen_catalogue.mjs`).
- Tests: `supabase/tests/99_release_23.sql` section 7, `web/src/features/careers/decisions.test.ts`, `web/tests/e2e/release-23.spec.ts`.

## Guides

- `admin/hiring`: Decisions and the emails they send.
