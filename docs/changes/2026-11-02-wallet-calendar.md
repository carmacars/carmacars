# Add to calendar from the email, and Add to Apple Wallet (0213)

Abbas's request (Release 22, item 2). Migration `supabase/migrations/0213_booking_calendar_wallet.sql`; the confirmation
email `emails/src/emails/renter_booking_confirmed.mjs` (catalogue row by `supabase/seed/0213_gen_catalogue.mjs`). Code:
`web/src/app/api/booking-ics/[token]/route.ts`, `web/src/features/portal/booking-ics.ts`, `web/src/features/wallet/pkpass.ts`,
`web/src/server/wallet.ts`, `web/src/app/account/bookings/[number]/wallet/route.ts`, `web/src/app/admin/settings/page.tsx`.
Tests: `supabase/tests/99_booking_calendar.sql`, `web/src/features/wallet/pkpass.test.ts`, `web/src/features/portal/booking-ics.test.ts`.

- The booking confirmed email has "Add pickup and return to my calendar": `/api/booking-ics/<bookings.calendar_token>`,
  two events with the address, only while the booking is confirmed or on rent. The booking page already had Add to
  calendar.
- Apple Wallet: a complete .pkpass builder (an event ticket with the booking number, car, pickup and return times and
  address, a QR code of the booking number; manifest and a detached CMS signature made with WebCrypto, checked with
  `openssl cms -verify` against a test certificate). Google Wallet is out of scope.
- It needs CarmaCars' own Apple Pass Type ID certificate. Until WALLET_PASS_CERT, WALLET_PASS_KEY (PKCS #8),
  WALLET_WWDR_CERT, WALLET_PASS_TYPE_ID and WALLET_TEAM_ID are set, the button is hidden, the route answers 404 and Admin >
  Settings shows the step in its Setup checklist.

## Guides

- `renter/after-your-trip`: your trip in your calendar or wallet.
- `admin/settings`: Setup checklist.
