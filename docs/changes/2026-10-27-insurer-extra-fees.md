# Charges to the insurer: VLF, LDW, T&LDW, PAP/PEC, Waiver Saver (0179)

The owner: on insurance replacement rentals CarmaCars charges the insurer extra fees that appear on Blind Spot's rental
agreement (VLF in box 43, LDW in 45, T&LDW in 46, PAP/PEC in 47, and Waiver Saver). "Only add those fields for insurer
bookings." Clarified: on a booking the renter pays they are absent from every screen (not disabled, not listed).

## What changes
- **Five charges** (`fee_types`): `vlf`, `ldw`, `tldw`, `pap_pec`, `waiver_saver`. Fees a day like the winter tire:
  company revenue, HST applies, priced at booking, refundable by tier. No default price (`fee_defaults` amount empty):
  staff type the rate a day on each booking, kept in `booking_insurer_fees`. The line is the rate times the rental days
  ("VLF (vehicle licence fee): 3 days at $5.00 a day"), plus HST; it follows the dates when they change.
- **Where staff type them** (only once the booking bills an insurer):
  - Add a rental, Insurer billed later (or the Insurance replacement quick start): Charges to the insurer, under the
    insurer's details; the price check adds each line.
  - The review screen of a request or an offer (Save, Send offer, Edit offer and its preview) once Bill to is an insurer.
    Bill to back to Renter removes them in the same save.
  - The booking's Insurance replacement card: each charge with its rate, days and amount; Change the charges.
  - Send an offer (the composer) bills the renter until Bill to is set on the review screen, so it never shows them.
- **Insurer bookings only, in the database**: a rate, a price line, a fee set by hand of these codes, Add a rental's
  check and the rental itself are refused for a booking billed to the renter ("VLF, LDW, T&LDW, PAP/PEC and Waiver Saver
  are charged to an insurer only: booking CC-... is paid by the renter"); a booking that still has them cannot go back to
  the renter. The Fees card does not change them (a rate a day, on the Insurance replacement card).
- **The insurer pays them** whether billed wholly or for the rental only (`app.booking_insurer_share`); its invoice lists
  each on its own line (`app.draft_insurer_invoice`), the total unchanged.
- **The agreements**: CarmaCars' agreement lists them among the price lines. Blind Spot's prints each in its box with
  the rate a day and the amount (43, 45, 46, 47); Waiver Saver's amount goes in its white box beside Accepted, or in box
  48 ("See 48" in the white box) when it is too wide to read there. A box with a charge no longer says N/A; they stay out
  of box 48 and of box 14's Box 48 text, so the subtotal adds up exactly. Bookings without them print N/A as before.
- Changes recorded: `booking_fee_changes` and the booking's history ("Charges to the insurer: VLF $15.00 to $18.00").

## Guides
- `admin/insurance-replacements-rates-and-billing`: new task Charges to the insurer; the invoice lists each charge.
- `admin/partners-company-cars-and-rentals-added-by-hand`: Add a rental, Insurer billed later, the charges.
- `va/add-a-rental-by-hand`: the charges on an insurance replacement.

Published by the guide block of 0179 (`supabase/seed/0179_gen_guides.mjs`).

## Tests
- `supabase/tests/99_insurer_extra_fees.sql`: the charges, Add a rental's check and rental, refused on a renter's
  booking (door, table, price line, fee set by hand, review screen, back to the renter), changed from the booking and
  the review screen, rate x days with HST, the days changing, the insurer's share (wholly and split) and its invoice.
- `web/src/features/blindspot/fill.test.ts`: each in its box with its rate, no N/A, box 48 and the subtotal; Waiver
  Saver too wide goes to box 48. `web/src/features/insurers/fees.test.ts`: the payload of the rates typed.
