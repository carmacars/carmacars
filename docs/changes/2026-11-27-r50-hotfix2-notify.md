# Hotfix 2 R50: the notification audit (5190)

Migration `5190_r50h2_notify_matrix.sql`, test `supabase/tests/99_r50h2_notify.sql`, email `insurer_payment_received`.
The owner, Nov 27: "I think you need a thorough review of every single notification sent out as many are missing."
The matrix of every event, audience and channel is `scripts/notification-map.json` (checked by
`scripts/check-notification-map.mjs`); the audit notes with every gap are outside the repo (hotfix notes, Nov 27).

## What was wrong, and the change

- **Held, not missing.** Every email goes through Resend (connector: list_comms CC-10664, provider "resend"); its 100 a
  day ran out, so the request, the offer and "request waiting" went out at midnight. Amazon SES is the fix (comms).
- **An insurer's payment sent the renter a receipt.** `app.record_insurer_payment` writes a booking payment, so the renter
  got "Receipt: $X paid" and Admin got "payment received", and the insurer got nothing. Now: no renter receipt and no
  `payment_received` alert for it; the adjuster on the booking (else the insurer's billing contact) gets
  `insurer_payment_received` as Blind Spot Car Rental (no CarmaCars in subject or body); Admin and Finance get the alert
  `insurer_invoice_paid`.
- **Work given to you told nobody.** Alert `work_assigned` to the assignee: a To do a person made for someone else, or a
  To do or lead moved to you by someone else. To do's the site raises stay in the queue (the 5102 rule).
- **A bug reporter never heard the answer.** Alert `bug_report_closed` when an Admin marks it Fixed or Won't fix.
- **Stand-in texts for held emails.** 10 renter must-act messages added to `email_limit_text_codes`; at night a stand-in
  text waits for the end of quiet hours unless the pickup or return is within 6 hours, the type is urgent, it is a
  signing code, or an Admin pressed Text it.
- **Incident fan-out had no test.** Now tested: an accident tells staff, the renter and a third-party owner; a breakdown
  tells staff only.

## Not in this change

New-request and return-time alerts (5102), check-in visit copy (5103) and the job lock noise are on r50-hotfix2-errors;
CC-10067 and insurer rentals off owner notices (5120, 5123) on r50-hotfix2-insurance; SES, the email meter and auto
replies (5090, 5091) on r50-hotfix2-comms. Insurer emails still send from an address on carmacars.ca: they need a Blind
Spot mailbox on its own domain.

## Guides

No guide change: the alerts and emails it adds are listed in Settings > Alerts and the email catalogue, and no screen or button changed.
