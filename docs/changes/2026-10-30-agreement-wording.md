# The rental agreement's wording, per booking (migration 0198)

The owner asked to make the rental agreement editable. Its fields already were (Edit the agreement, 0183); this makes
its **wording** editable for one booking, tracked like any other change of the agreement.

- **Edit the wording** on the booking's Rental agreements card (Admin only): every clause of CarmaCars' agreement (the
  15 sections of Part 2, the Schedule of Fees, the Owner Rental Addendum) with **Change**; **Add** writes Additional
  terms as the last section of Part 2. Each change needs a reason. The standard wording is one click away.
- Only clauses not required by law or the insurer can be removed: section 6 (Tolls, tickets and fines) and the
  Additional terms. Coverage, damage, charges, cancellation, tracking, privacy, liability and the rest are reworded,
  never removed. The Booking Consents (Part 6) are what the signer ticks: they are not reworded. A removed section keeps
  its number and reads "This section does not apply to this booking", so the cross-references still hold.
- Blind Spot's agreement is the insurer's official form: its printed terms are never changed (the card says so).
- Kept in `booking_clause_overrides` (edit, add, remove, restore; reason, who, when), append only: the latest row of a
  clause is in force; the catalogue is `agreement_clauses` (the same list as `web/src/features/agreement/wording.ts`,
  checked by its unit test). The booking's history records each change.
- The PDF and the signing screens print the merged text, with a line in Part 1 naming what is worded for the booking
  and "(worded for this booking)" on each changed heading. A key term the signer initials notes when its section
  (damage, charges, rental period, coverage, cancellation) is worded for the booking.
- Before the renter signs, the open agreement is simply made again. While a signature is in and the countersignature
  is not, a change is refused (the signed document stays as signed). After signing, the wording is part of the
  agreement's snapshot: a change is a **material** new version the renter and every additional driver sign through the
  version plan (0154), even after an amendment. **Every version** shows each clause before and after, and the
  standard wording. Bookings with the standard wording are unchanged (no new key in their snapshot).
- Dispute packs and certificates stay consistent: every version is rendered once, stored with its SHA-256, and the
  pack and certificates use those stored documents.

## Guides
Admin guide, "Rental agreements: every version, every field": a step for **Edit the wording**.
