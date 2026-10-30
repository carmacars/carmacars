# Credit card coverage: the same card pays the rental (0203)

Release 21, item 4. Migration `supabase/migrations/0203_card_coverage_same_card.sql`. Tests:
`supabase/tests/99_card_coverage_same_card.sql`.

- A booking with coverage option 2 (the renter's credit card) is paid on that card: the card of the coverage proof, else
  the Card on File, else the first card that paid the rental (`app.card_coverage_ref`). Same card: the Stripe
  fingerprint matches, or (typed by hand) the last 4 digits (`app.card_coverage_same_card`).
- Checked on: the pay page (`server_payreq_settle` refuses another card and the website refunds it at once), the reader
  (`server_payreq_card_check` before capture: another card is cancelled, never charged), Record card payment (last 4
  digits and the box "This is the same card"), and Record a payment (e-Transfer, cash and the like are refused for the
  rental and the fees).
- Deposits and later charges may go on any card.
- An Admin's override for one booking with the reason (`booking_card_overrides`, door `ops_do`
  `card_coverage_override`, **Allow another card** on the Money tab), logged on the booking.
- The Money tab shows the rule (`booking_money` adds `card_rule`, `readers`, `is_admin`).

## Guides

- `admin/requests-offers-and-bookings`: Credit card coverage: the same card.
- `va/finance`: Card payments outside the site and the card reader.
