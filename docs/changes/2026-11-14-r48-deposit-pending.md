# Picked up, deposit pending (Release 48: 2970)

Migration `2970_r48_deposit_pending.sql`.

A pickup could not be recorded until the deposit was taken or an Admin waived it ("The deposit is not taken"), so a renter at the lot whose card would not take the hold either waited or had the deposit waived for good. Staff who record handovers, and an Admin, can now let the car go with the deposit still owed, with the reason.

- `deposit_pendings`: one row per booking (the amount, who and why, the morning tries, the link of the day, the 48 hour alert, how it ended). `app.deposit_pending_ok` is the one rule the pickup checks use: Record now, the one-screen check-in, the full check-in (`complete_handover`), the status triggers, the override list and `record_deposit_taken` (a deposit taken later is recorded on the car already out).
- Door: `deposit_pending_allow {booking | job, reason}` (ops, field); `handover_record_now` and `handover_one_screen` take `deposit_pending_reason` (or `deposit_pending: true` with the reason). A refused pickup leaves nothing behind.
- Screens: **Deposit pending $X** beside the status on every booking page (Admin and every staff portal) with who, why and what the morning job did; the field checklist and the caller pop-up say pending; the renter's booking page says **Deposit still owed** and how it is asked for.
- Each morning (the deposit job, from the deposit hold hour, Toronto): the saved card is tried for the hold once; when it fails or there is no usable card the deposit link goes to the renter (text, else email; the words fit a car already out). Program settings `deposit_pending_retry` turns it off.
- After 48 hours still owed: one Admin To do `deposit_pending_overdue` and an urgent alert (`deposit_pending_overdue`), both opening the booking's Money tab. Taken, waived, the car back or the booking ended: the row ends and the To do closes by itself.
- Claude's connector: `record_handover` takes `deposit_pending: true` with `deposit_pending_reason` (and an Admin's `signature_override_reason`), previewed then confirmed as every write.
- Tests: `supabase/tests/99_r48_deposit_pending.sql`; unit: `deposit-chip.test.ts`, `caller/model.test.ts`, `api-access/tools.test.ts`.

## Guides

- `field/a-handover`, `va/fleet`: Let the car go with the deposit owed.
- `admin/requests-offers-and-bookings`: Deposit pending, the morning tries, the 48 hour To do, the setting, the connector.
- `renter/during-your-trip`: Deposit still owed.
