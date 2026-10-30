# The card reader, a Stripe Terminal S700 (0202)

Release 21, item 3. Migration `supabase/migrations/0202_card_reader.sql`. Code:
`web/src/integrations/payments/terminal.ts` (Stripe, fetch), `terminal-fake.ts` (local and tests),
`web/src/server/actions/card-tools.ts`, `web/src/features/terminal/`. Tests: `supabase/tests/99_card_reader.sql`,
`web/src/integrations/payments/terminal.test.ts`, `web/src/features/terminal/address.test.ts`,
`web/tests/e2e/release-21a.spec.ts`.

- Server-driven Stripe Terminal: no connection token. The server creates a card_present PaymentIntent (manual
  capture) and hands it to the reader (`readers/{id}/process_payment_intent`); the booking screen polls until the card
  is read.
- **Admin > Settings > Card reader**: **Pair reader** takes the three-word pairing code the S700 shows and registers it
  at Stripe (`terminal/readers`) to a Terminal location made, the first time, from the mailing address of Site settings
  (`parseCaAddress`: street, city, province, postal code). `terminal_locations`, `terminal_readers` keep them; Remove
  takes a reader off the list.
- From a booking's Money tab: **Charge on reader** (everything open, the rental, the fees or a later charge) and **Hold
  deposit on reader**. A reader request is a payment request (0129) of channel `reader` (`payment_requests.reader_id`,
  30 minutes); it settles through `server_payreq_settle` like the pay page. A charge is authorized, checked (0203), then
  captured; a hold stays uncaptured and lapses after 2 days (card present), captured or released from Settle the
  deposit. **Cancel** stops the reader and cancels the PaymentIntent. A card read on the reader is never saved as the
  Card on File.
- Statement descriptor: card PaymentIntents cannot set it per payment; the Stripe account's descriptor
  (18122211 CANADA INC.) is what renters see.
- The live reader is the primary path. The fake adapter simulates the reader for local work and the end-to-end tests
  (the card it reads: `setFakeReaderCard`); Stripe's simulated reader (test_helpers) is only for automated tests in
  Stripe's test mode.

## Guides

- `admin/settings`: Pair the card reader.
- `admin/requests-offers-and-bookings`: Charge or hold the deposit on the card reader.
- `va/finance`: Card payments outside the site and the card reader.
