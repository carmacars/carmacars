# Discounts on the rental charge only, e-sign without the code, clearable initials, insurer list (migration 0186)

The owner's requests for the October 29 deploy.

- **Discounts come off the rental charge only.** The rental charge is the daily, weekend, weekly or monthly rate part.
  No discount ever comes off the fees, add-ons, the Protection Plan, the young driver fee, delivery or the deposit.
  The audit of the pricing found:
  - the non-refundable discount is a percentage of the rental charge (`app.price_lines`);
  - promo and discount-game codes are computed on the rental charge less the other discounts (`app.price_lines`,
    `app.promo_discount_cents`, `app.preview_extension`);
  - the price typed by hand and its "discount from the rate sheet" flag look at the rental charge only.

  The one gap was the Admin's discount (the review and offer screens). It had no cap: a discount larger than the rental
  charge took the rest off the fees in a quote, and saving it on a booking failed with a database error. It is now
  capped at the rental charge (less the non-refundable discount), both in the price and on the booking. A promo code
  then takes what is left of the rental charge (nothing, when the discount took it all).
- **E-sign without the one-time code.** New Program setting, E-signing: **ask for a one-time code by text or email
  first**. It is off by default. When it is off, the signing page starts at "Read". A small **Verify by code (optional)**
  link still opens the code step. Everything else stays: reading, the initials of each key term, the consents and the
  drawn signature. The time, IP address and device of each step go in the certificate of completion. The certificate
  now says "Identity: not confirmed by a one-time code" when no code was used. The dispute evidence text says the same
  rather than claiming a code. Turn the setting on and the code is required again, as before. The setting is checked
  again at the moment of signing.
- **Initials can be cleared.** Each initials box is saved only when the signer presses **Save initials** (no
  half-drawn mark is saved). The box's **Clear** wipes the drawing. A saved initial has its own **Clear**, which removes
  it from the signing session and records "Initials cleared" in the audit trail; the signer initials it again. Typed
  initials (the accessibility fallback) work the same way. The main signature box keeps its **Clear**.
- **Insurers from a list.** The renter's own insurer (OPCF 27) is picked from a list of Canadian auto insurers, with
  **Other (type it)** for any other. It appears on the renter's coverage upload in the portal, on staff's
  **Upload a document**, and on the Agreement card's missing fields and **Edit the agreement**. The plain name is stored
  as before. A saved name not on the list opens as Other with that name.

Code: `supabase/migrations/0186_esign_no_code_discount_scope.sql`, `web/src/features/signing/EsignFlow.tsx`,
`web/src/features/signing/certificate.ts`, `web/src/features/insurers/companies.ts` and `InsurerSelect.tsx`. Tests:
`supabase/tests/99_esign_no_code_discount_scope.sql` (87 now runs with the code required),
`web/src/features/insurers/companies.test.ts`, `web/src/features/agreement/accuracy.test.ts`.

## Guides
- `admin/requests-offers-and-bookings`: signing that holds up in a dispute (the optional code, the setting, Save
  initials and Clear).
- `renter/sign-and-pay`: the signing steps without the code, Save initials and Clear.
