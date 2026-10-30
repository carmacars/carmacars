# Interview reminder an hour before: a text instead of an email (migration 0199)

Resend's free plan sends 100 emails a day, and interview bookings and reminders count against it.

- When phone and texts are on (Program settings: phone, and the hiring texts), the candidate gave a phone number and
  the text is queued (not opted out, a number the line can text), the reminder an hour before the call is the text
  alone: no email.
- A candidate without a phone, with a number that cannot take the text, or with texts off still gets the email.
- The booking confirmation email (with the link to change or cancel) is unchanged; the evening-before email stays off
  unless Program settings turn it on.
- `app.job_hiring` returns `hour_texts` (reminders sent as a text only). DB test: `supabase/tests/99_careers_hiring.sql`
  section 4 (text only with a phone; email with no phone; email when hiring texts are off).

## Guides
No guide change: the screens are unchanged.
