# Email from the portal, insurance emails as Blind Spot Car Rental, deposit reminders (0187)

The owner, for the single deploy of October 29: email customers directly from the portal; emails about insurance go
from blindspotcarrental@carmacars.ca; and reminders to release deposits, since a deposit is never released by itself.
Migration `supabase/migrations/0187_portal_emails_deposits.sql`, SCHEMA_MARKER 0187.

## What existed
- **A staff reply to the renter** (0031, 0033): `app.staff_send_message` kept the message on the booking (`messages`,
  with `sent_by`), emailed it as `renter_staff_message` from `CarmaCars <bookings@carmacars.ca>` (replies to
  bookings@), showed it in the renter's account and closed the "renter replied" task. Only customer service and Sales
  had it, on the assistant booking page's Messages tab (a quick reply and a message, no subject). Admin had no form; the
  Admin booking page listed the booking's emails in its History tab.
- **Deposit reminders** (0020): `app.job_deposits_due` (pg_cron `carmacars-deposits-due`, hourly at :12, runs once a day
  from 06:00) raised one `release_deposit` task per deposit in the Finance queue from 2 business days before
  `release_due_on` (7 business days after the check-in), urgent once due; the guided settlement closed it. A deposit
  with no `release_due_on` (no check-in recorded) was never reminded, and nobody was told in the portal.
- **Insurer emails**: `insurer_invoice` went from `CarmaCars <billing@carmacars.ca>`, replies to billing@.

## What changes
1. **Email the renter** on the Admin booking page (a new **Messages** tab, and an "Email the renter" button at the top),
   on the assistant booking page (the Messages tab, now for customer service, Sales, Fleet and Finance) and on Admin >
   Renters > a renter (about their latest booking, or the one picked). A subject and a message, optionally from a quick
   reply. It extends the existing staff message rather than adding a second one: `renter_staff_message` now takes the
   subject staff type (`{{message_subject}}`; "Your booking CC-..." when none was given, as before). Each email is kept on
   the booking's messages with who sent it and from which address, and in the booking's history (`booking_events.kind
   = 'staff_email'`, the staff member as the actor). It goes through the outbox like every email, at the customer
   priority (class 1, the class limit 97 of the 100 a day), so it counts against the daily limit; the form shows today's
   use. The screen shows the conversation (both ways, the adjuster's emails marked) and every email of the booking with
   its sender and state. Fleet sees the renter's first name and never the address, as on its booking screen. Sales may
   write only on a request or an offer. A booking takes at most 20 staff emails a day (a runaway guard on the shared limit).
   New door calls: `ops_do booking_email` (`app.booking_email_send`) and `ops_read booking_conversation`
   (`app.booking_conversation`).
2. **Insurance emails as "Blind Spot Car Rental <blindspotcarrental@carmacars.ca>"**, replies to the same address.
   Codes switched (`update notification_catalogue ... where code in ('insurer_invoice')`): **`insurer_invoice`**, the
   only catalogue email to an insurer or adjuster. New: **`insurance_staff_message`**, the same sender, used by **Email the
   adjuster** (insurer-billed bookings, to `bookings.insurer_adjuster_email`, always Blind Spot) and by Email the renter
   when "Blind Spot Car Rental (insurance)" is chosen as the sender on a booking billed to an insurer (`bill_to` insurer
   or split). `blindspotcarrental@carmacars.ca` is added to the receiving aliases (`email_aliases`), `emails/src/brand.mjs`
   (FROM and ALIASES), `emails/check.mjs`, `web/tests/lint/emails-db.mjs` and `docs/email-aliases.md`.
   Not switched, on purpose: `renter_coverage_needed` and `renter_identity_needed` (they ask the renter for their own
   proof of coverage and licence before a CarmaCars pickup; the answers belong in the bookings inbox) and
   `staff_insurer_invoice_due` (an internal notice to Finance).
3. **Reminders to release deposits.** `app.job_deposits_due` (same signature, same schedule) now also covers a returned
   booking whose deposit has no release date: due `deposit_release_reminder_days` business days after the return (a new
   program setting, 7 by default, matching the 7 business days after a check-in). The task is titled "Release the deposit
   for CC-...: $amount, due <day>", one per deposit (`release_deposit:<deposit>`). On the due day and after, Finance (its
   assistants, and anyone covering Finance) and the Admins get one in-app notice per deposit and due day
   (`staff_deposit_release_due`, no email). The task closes by itself when nothing is left to give back, however the
   deposit was settled (a trigger on `deposits`: settled, released, kept against the charges, carried forward, failed).
   Admin > To do counts "Deposits due back today or overdue" (to the Finance queue).

## For the owner
- **Create the mailbox**: `blindspotcarrental@carmacars.ca` sends as soon as this deploys (carmacars.ca is the verified
  Resend domain), but replies from insurers, adjusters and renters bounce until the mailbox or a Google Workspace alias
  (of rent@carmacars.ca, like the others) exists.
- The deploy loads the email templates as usual (`scripts/deploy/email-templates-sql.mjs`), which brings
  `insurance_staff_message` and the new `renter_staff_message` subject.

## Files
- `supabase/migrations/0187_portal_emails_deposits.sql`, `supabase/seed/0187_gen_catalogue.mjs` (the catalogue block)
- `emails/src/emails/insurance_staff_message.mjs` (new), `renter_staff_message.mjs`, `insurer_invoice.mjs`, `brand.mjs`,
  `check.mjs`, `build.mjs`; generated `catalogue.json`, templates, README table and preview
- `web/src/features/messages/` (new: `EmailRenter.tsx`, `BookingConversation.tsx`, `email-choices.ts` and its unit test);
  `web/src/features/va/QuickReply.tsx` removed (the new form replaces it)
- `web/src/app/admin/bookings/[number]/page.tsx`, `web/src/app/va/bookings/[number]/page.tsx`,
  `web/src/app/admin/renters/[id]/page.tsx`, `web/src/features/va/tasks.ts` (a renter's message opens the Admin
  booking's Messages tab), `web/src/features/admin/fields.ts`, `web/src/lib/db/types.ts`, `web/src/lib/schema-marker.ts`
- Tests: `supabase/tests/99_portal_emails_deposits.sql` (new); counts and lists that grew: `07_notifications.sql`
  (the new email, built once), `08_booking_app.sql` (the staff_email history kind), `13_owner_answers.sql` (the alias),
  `20_gap_close.sql` (what emits renter_staff_message), `34_admin_redesign.sql` (the To do item), `71_text_alerts.sql`
  (the renter's text for an insurance message, `sms_templates`); `web/tests/e2e/gaps.spec.ts` (the form now has a subject)

## Guides
- `admin/requests-offers-and-bookings`: Email the renter or the adjuster
- `admin/insurance-replacements-rates-and-billing`: Emails as Blind Spot Car Rental
- `va/shared-tools`: Email the renter
- `va/finance`: Deposits to release
