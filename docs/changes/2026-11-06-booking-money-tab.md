# The booking's Money tab: Rental charges and Security deposit (release 29, C0, migration 0582)

Branch `r29`, on top of r28's deposit holds (A5, 0541). SCHEMA_MARKER 0582. The owner: confusing, and the deposit could
not be collected clearly apart from the rental charges.

## What changed

- **One layout** (`features/money/BookingMoney.tsx`, `money-panels.ts`), for Admin (`/admin/bookings/<n>?tab=money`)
  and every staff role that sees the booking's money (`/staff/bookings/<n>`): a strip with **Rental due**, **Deposit**
  (one word: Not collected, Held, Charged, Released, Partly kept, Waived) and **Total paid**; then two panels, side by
  side on a wide screen and stacked under 900 px.
- **Rental charges**: the lines and the total, Paid, Balance due (later charges apart); one main button "Collect $X
  rental" (the card on file, a payment link by text or email, on this device, or cash, e-Transfer or another way
  recorded; the rental and fees by default, or one of them); **A later charge**; **Save a card**; the card reader and
  the card coverage rule (CardTools `only="rental"`); the fees editor, failed card payments, payments received another
  way and **Refund**; the rental payment history only.
- **Security deposit**: the amount and method (a credit card hold, a debit or prepaid card at the standard multiple, a
  charge, cash), the status word and one main button for the next step: "Collect $X deposit" (a hold on the card on
  file, a deposit link by text or email, a hold on this device, a charge as the deposit, cash or e-Transfer recorded),
  then **Release** and **Keep part (damage/fees)** (and **Re-authorize the hold**) while held, **Settle the deposit**
  after the return; **Waive the deposit**, **Change the debit deposit** and the debit card switch; the hold on the
  reader (CardTools `only="deposit"`); the deposit history only.
- Collecting one never touches the other: each form sends only its own part (`covers` rental, fees or both; deposit),
  the messages and printed receipts say "Rental" or "Security deposit" (a deposit receipt says it is not a payment for
  the rental), and each panel shows only its own open card requests.
- **The backend gap** (0582): a deposit hold on the card on file now, by staff (`ops_do deposit_hold_saved_begin` and
  `deposit_hold_saved_failed`, server action `holdSavedCard`): the same one-request hold as the pickup-day job (0261),
  for the deposit only, Finance or an Admin; an older open deposit request is replaced. Before, only a link, the
  pickup-day job or a charge could take it.
- The old "Money by part" card, the separate Deposit card, the Refunds card and the duplicate Record a payment,
  Collect a card, Charge the saved card, Capture the hold and Release the hold buttons are gone; every capability is in
  its panel.
- Tests: `money-panels.test.ts` (the status word, the next step, rental and deposit money never mixed),
  `tests/e2e/booking-money-panels.spec.ts` (the deposit alone, then the rental alone, each balance checked; before and
  after screenshots), the e2e specs that recorded payments follow the panels.

## Guides

- `admin/requests-offers-and-bookings`
- `admin/settings`
- `va/finance`
- `va/customer-service`

Published by migration 0580 (`supabase/seed/0580_gen_guides.mjs`), the guide block of release 29.
