# Fewer repeat messages, one combined email and text per booking, and the email limit worded truthfully (Release 35, part V: 0900, 0901)

Branch `r35-v`. Migration `0900_r35v_fewer_repeats.sql` (catalogue rows from `supabase/seed/0900_gen_catalogue.mjs`); guides in
`0901_r35v_guides.sql` (`supabase/seed/0901_gen_guides.mjs`). No applied migration is edited: functions are wrapped (`_pre0900`)
or patched in place. Tests: `supabase/tests/99_r35v_message_dedupe.sql`, `web/src/lib/email-combine.test.ts`,
`web/src/features/messages/email-choices.test.ts`, `web/src/features/usage/usage.test.ts`. SCHEMA_MARKER 0901.

The owner, November 8: "There seems to be a lot of repetitive messages and emails for renters." Booking CC-10080 got, within five
minutes of paying: the confirmation, the receipt, "Your rental agreement, version 2", "Tomorrow: your car at 11:00 am",
"Upload your licence and coverage proof" (the licence was approved) and the signed agreement; that morning "One step left to
book" while a staff pay link was out, and two staff "Payment for booking" emails a minute apart. Owners got
`owner_invoice_voided` four to six times a day, and `owner_vehicle_listed` was queued 44 times with no address.

## The causes, fixed where they start

| Message | Cause | Fix |
| --- | --- | --- |
| Agreement version 2 after paying | Paying replaced the card on file with the card that paid, and the deposit link set the deposit's method. Both are payment details in the agreement's snapshot, so the version job filed a "corrected" version with nothing in the terms changed | `app.agreement_changes` leaves out every `payment.*` detail: how the renter paid is what the signed agreement said would happen |
| "Tomorrow" two minutes after the confirmation | The reminders job sends it to any confirmed booking inside 24 hours of pickup | Not sent when the confirmation (which gives the date and time) went out within `notify_reminder_confirm_gap_hours` (12) before the reminder would be due (`app.ntf_confirmation_covers`) |
| "Upload your licence and coverage proof" with the licence approved | The 48-hour chase went whenever any driver was not verified or no coverage was confirmed, including what was uploaded and waiting for review, always with the same subject | The chase goes only for what the renter still has to send (`app.renter_todo`: licence photos or selfie not uploaded or rejected, the proof not sent; nothing for the Protection Plan or a car with coverage included), not right after the confirmation that listed it, and the subject, the copy, the confirmation's notice and the text name only what is missing (`needed_title`, `needed_line`, `needs_licence`, `needs_coverage`) |
| "One step left to book" while a pay link was out | The recovery job counted staff only by tasks, chats and messages written after the visit | `app.recovery_staff_handling` is also true while a pay link staff sent is open or a payment is pending |
| Two "Payment for booking" emails a minute apart | The pay link and the deposit link had the same subject | Each says what it is for: "Deposit hold for booking", "Save your card for booking", "Payment for booking" |
| `owner_invoice_voided` 4 to 6 times a day | One email per invoice voided | One email per owner per day: it waits `owner_void_hold_minutes` (30) and lists every invoice cancelled meanwhile; once the day's went, later ones wait for `owner_void_next_day_hour` (9 am) |
| `owner_vehicle_listed` 44 times, no address | A partner's imported cars were announced to the partner's owner record, which has no address | Never emitted for a partner car (`supply_type = 'partner'`), and never queued without an address or an account |

## The guards

- Emails (`notification_outbox_zdedupe`): the same email to the same person for the same booking (or record) within
  `notify_repeat_window_minutes` (30) is kept with status `suppressed` and the reason ("Repeat held back: ..."), and plans no
  text. Emails marked `always_send` always go: receipts, signed copies and other documents, staff messages, sign-in and signing
  codes, driver links.
- Texts (`phone_outbox_repeat`): the same for `phone_outbox` (status `suppressed`), next to the 10-minute identical-text guard.
- Portal notices (`notifications_repeat`): the same notice for the same record within the window is not written twice.

## One email and one text per booking (the owner's direction)

- Emails to the same person for the same booking queued within `notify_merge_window_minutes` (2) go as one. The first is held
  for the window (`hold_until`); each later one is `merged` into it. The sender (`send-outbox`, with
  `web/src/lib/email-combine.ts` copied next to it as `combine.ts`) renders each part from its own template and joins them: one
  subject naming the booking ("Update on your booking CC-10080: confirmed, receipt and agreement", `app.outbox_merge_parts`),
  each email as its own numbered section with its own buttons, every attachment kept, one header and footer. A lone email goes
  after the window as before. The parts are kept as `merged` with the time and provider id, and count as one email. If the
  combined email fails for good its parts fail with it; if it is cancelled or skipped they are skipped with it,
  with the reason (`app.outbox_merge_release`).
- Texts: the same window on `phone_outbox`; one text "CarmaCars updates:" with a short line per item and the opt-out line once.
- Never held: staff messages typed by a person, sign-in and signing codes, urgent texts and their emails, staff emails,
  digests and marketing (`notification_catalogue.hold_to_merge`).
- Admin > Logs, Emails: filters "Sent combined" and "Repeats held back", and a Why column.

## Cloudflare Email Service and the day's limit

Cloudflare's dashboard showed sends while the site said "Cloudflare Email Service is not sending / not set up yet" and held the
day to Resend's budget. The site judged Cloudflare only from outbox rows with a `cf:` provider id and a success within the last
day: a quiet day, a timeout counted as a refusal (the email then went through Resend too) or outbox history not on file made it
"not set up", and `app.email_day_cap` dropped Cloudflare's budget.

- `app.cf_email_ever_sent` also counts a success the sender recorded (`email_provider_state.cf_ok_at`).
- `app.cf_email_setup` is `ok` after a success, however long ago, unless Cloudflare refused since (a timeout is not a refusal
  once its 15 minutes of rest are over) or the Worker has no binding (`absent`).
- `app.cf_email_counted`: Cloudflare's budget counts while it is switched on, has sent, and its binding is not reported missing.
- `app.email_day_cap`: Cloudflare's budget plus Resend's whenever Cloudflare is on and works.
- The email pace read carries `cf_state` and `cf_counted`; the booking page's Email the renter box, Settings > Usage and
  Admin > Logs all say it the same way from that read: "98 of 100 today: only Resend is sending (Cloudflare Email Service is not
  set up, which adds 200)" or "120 of 300 today (Cloudflare 200 + Resend 100)" (`emailBudgetLine`; no number is written in code).

## Settings (Program settings)

`notify_repeat_window_minutes` 30, `notify_merge_window_minutes` 2, `notify_reminder_confirm_gap_hours` 12,
`owner_void_hold_minutes` 30, `owner_void_next_day_hour` 9. Each 0 (window) turns its behaviour off.

## Emails changed

`renter_identity_needed` (subject and sections for what is missing), `renter_booking_confirmed` (the notice names what is
missing), `owner_invoice_voided` (one or several invoices), and the trigger text of `renter_booking_reminder`,
`renter_recovery_pay` and `owner_vehicle_listed`. Texts: `renter_identity_needed` and `owner_invoice_voided` follow the
email's words (an Admin's own wording is kept).

## Guides

- `admin/email-backups-and-site-health`: why the day's limit is that number, combined emails and texts, repeats held back and
  their filters.
