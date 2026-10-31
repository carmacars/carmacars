# A credit card by default, debit and prepaid allowed per booking (0230)

The owner, Release 23a: the deposit must be on a credit card so the deductible can be charged, so a credit card stays
required by default. A renter who has only a debit or prepaid card is told to contact us, and an Admin can then allow one
for that booking.

- **Default (as before):** the pay page, staff pay links (0213) and the deposit hold refuse a debit or prepaid card
  (`card_not_credit`); a car marked "no credit card needed" still takes a debit card (0093). The refusal now reads:
  "Please use a credit card. If you only have a debit or prepaid card, contact us. Nothing was charged."
- **Override per booking (Admins):** Money tab, **Allow debit and prepaid cards for this booking**, with a reason
  (`bookings.debit_allowed_at`, `debit_allowed_by`, `debit_allowed_reason`; `app.booking_allow_debit`, audited;
  **Require a credit card again** turns it off). That booking's pay page, staff pay links and deposit hold then take a
  debit or prepaid card, and the renter sees: the deposit hold lowers the money available on the card or account until it
  is released, which can take several business days.
- **Site-wide default:** Program settings, **Card types accepted**: Credit only (the default) or Credit, debit and
  prepaid (`program_settings.card_types_accepted`), so the owner can open it up later without a release.
- **Never overridden:** a booking on credit card rental coverage (Coverage Option 2) is paid on the credit card that
  carries the coverage; the override is refused there and the site-wide setting does not apply.
- **The card's type on each payment:** `payments.card_funding` (credit, debit, prepaid, unknown), from the saved card
  (else the renter's saved card with the same brand and last four digits); payments made before are filled from their
  saved card. The Money tab lists the cards used with their type, and says whether the booking takes a debit card.
- Rule in one place: `app.booking_card_ok` (used by the booking's payment, `app.finalize_live_payment` and
  `public.server_payreq_card_ok`); `public.booking_takes_debit` tells the pay pages.
- Renter-facing texts still say credit card; the pay page and pay links add "If you only have a debit or prepaid card,
  contact us." The rental agreement is unchanged.
- Tests: `supabase/tests/99_release_23.sql` section 6; `web/tests/e2e/release-21b.spec.ts` (the refusal text).

## Guides

- `admin/requests-offers-and-bookings`: A renter with only a debit or prepaid card.
