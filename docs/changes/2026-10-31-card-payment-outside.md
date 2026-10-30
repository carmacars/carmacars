# A card payment taken outside the site (0201)

Release 21, item 2. Migration `supabase/migrations/0201_card_payment_outside.sql`. Tests:
`supabase/tests/99_card_payment_outside.sql`, `web/tests/e2e/release-21a.spec.ts`.

- **Record card payment** on a booking's Money tab (`web/src/features/money/CardTools.tsx`, action
  `recordCardPayment`, door `ops_do` `record_card_payment`, `app.record_card_payment`): a card taken in the Stripe
  Dashboard or on a card reader, for the rental and fees, the rental, the fees, a later charge or the deposit.
- The last 4 digits are always asked. A Stripe payment id (pi_... or ch_...) is optional for a payment: **Look up** reads
  it at Stripe (`terminal().lookupPayment`) and the database checks the amount, the last 4 digits and the state
  (succeeded for a payment, requires_capture for a hold). The same Stripe payment is never recorded twice.
- A payment: `payments` method card with the last 4 digits, `payment_processor_details` processor stripe (with the ids)
  or outside_card, `manual_payments` method card (`card_last4`, `card_source`, `stripe_verified`); the lines it pays are
  tied, the receipt goes out, a booking waiting for payment is confirmed. Rental and fees in one payment is split as
  Record a payment does.
- A deposit hold needs its PaymentIntent id: recorded as held (`deposits` card_hold, a hold payment authorized with
  the Stripe id), so Settle the deposit captures or releases it at Stripe and the release reminders apply. It lapses 2
  days after (on a reader) or 7 (in the Dashboard), unless Stripe gives `capture_before`.
- Who: an Admin, Finance, customer service or Sales, within the single limit of Program settings.

## Judgement calls

- A deposit charged (not held) in the Dashboard is recorded as a later charge, not as a deposit.
- A card payment recorded without a Stripe id cannot be refunded from the site: refund it in the Stripe Dashboard.

## Guides

- `admin/requests-offers-and-bookings`: Record a card payment taken outside the site.
- `va/finance`: Card payments outside the site and the card reader.
