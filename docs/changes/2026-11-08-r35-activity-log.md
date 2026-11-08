# Release 35, part R: the renter's one Activity log (migrations 0850, 0869)

Branch `r35-r`. SCHEMA_MARKER 0869 (raise to the highest merged migration when merging).

The owner, November 8: "Our renters message and history tab needs to be just combined with all website usage messages calls
everything maybe with small little filters for each type of usage, but having everything as one big log as default."

## What changed

1. **One read.** `renter_activity` (door: `admin_read`, `va_read`, `ops_read`; `app.renter_activity`) unions, for a renter or one
   booking, newest first: emails and account messages both ways and the emails the platform sent (`messages`,
   `notification_outbox`), texts and calls with their summaries and next steps (`phone_activity`), live chat line by line
   (`chat_messages`), renter notes (`renter_notes`, 0800), booking events, payments and refunds, documents, identity checks and
   signatures, and the website: each visit, what was done there (not each page view) and the signals. 50 a page with a cursor
   (`before`, `before_k`) for Older; `types` filters, `q` searches the title, text and author. A booking's log is the booking's
   own items and the renter's items within 30 days around it that belong to no other booking.
2. **Who.** An Admin; office staff (customer service, Sales, Fleet, Finance) who may see the renter (`app.renter_notes_ok`, as
   the notes). A booking's log: an Admin, or staff who may email that booking's renter (`app.booking_email_problem`) and see the
   renter. Payments show to Admins, customer service, Sales and Finance (as the Money section); Fleet does not get the chip.
   No email address or phone number is in the log.
3. **The pages.** `features/activity/ActivityLog`: chips for All (the default) and each type, a search, the list grouped by day,
   Older and Newest, and every action one press away: Email, Call and Text at the top (`ContactButtons`), Reply on an email from
   the renter, Text or Call back on a text or call from them, Open the chat, Open the conversation, and Remove on a note for an
   Admin. It replaces, on the Admin renter page, the Calls and texts and On the site cards (the note box sits above the log, the
   email form stays under it, its own lists dropped); on the staff portal's renter (Find a renter, Open) it is new, under the
   record; on the booking page (Admin and every staff function) the Messages & history section is the log with the email form
   under it, in place of the Messages, Emails of this booking, Timeline, Status history, Calls and texts, On the site and Emails
   sent cards.
4. **Old addresses.** `?tab=messages` and `?tab=history` still open the section. The log's own parameters (`act`, `aq`,
   `before`, `bk`) never touch a page's own (`q`, `id`, `booking`, `tab`).

Tests: DB suite `99_r35r_activity_log.sql` (every type in one log, newest first, filters, search, pages without repeats, who
reads it, a booking's log, no address or number), unit `features/activity/model.test.ts`, e2e `tests/e2e/activity-log.spec.ts`
(Admin and staff, chips, search, Older, a note added, Fleet without payments). The e2e tests that read the old cards
(`phone`, `live-chat`, `caller-popup`, `admin`, `gaps`) read the log now.

## Guides

Published by `supabase/seed/0869_gen_guides.mjs` into `0869_r35r_guides.sql`: `admin/requests-offers-and-bookings`,
`admin/live-visitors-and-live-chat`, `admin/texts-and-calls-the-quo-phone-line`, `va/shared-tools`, `va/texts-and-calls`.
