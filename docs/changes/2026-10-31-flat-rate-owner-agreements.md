# The flat-rate owner agreement set (0205)

Release 21, item 6. Migration `supabase/migrations/0205_flat_rate_owner_agreements.sql`; the text
`docs/source/v2_flat_rate_enrollment.md` (generated into `web/src/features/owner-agreement/flat-rate.generated.ts` by
`npm run gen:owner-agreements`). Tests: `supabase/tests/99_flat_rate_owner_agreements.sql`,
`web/src/features/owner-agreement/flat-rate.test.ts`.

- Owners on a flat monthly payment (0196) sign the **Flat-Rate Vehicle Enrollment Agreement**: a fixed Monthly Amount per
  car on the Payout Date, part months (and the month of removal) by the day, no revenue split, no Insurance, Tracker or
  Install Fee, no rental income or revenue report owed, 30 days' notice either way, repairs through the claim at approved
  shops, the Deductible as in the standard set, the owner drives their own car under a Rental Agreement at no cost. It
  names the company only as 18122211 Canada Inc. ("the Company"). The Title-Holding and Lease Agreement and Forms A to D
  are the standard ones.
- The set is picked by the pay model (`app.owner_pay_model`): flat_rate when every car of the owner in the program is on
  a flat monthly payment in force or starting later. `owner_agreements.variant` (standard | flat_rate).
- Switching pay model (`car_pay_set`, or terms set for a first car): an open Enrollment Agreement changes set; a signed
  one ends and a new one of the right set opens for signature (`packetKeys` asks for it even when every car is signed).
  Changed back before signing, the signed one is in force again and the new one is void.
- Program settings **owner_flat_agreements_awaiting_lawyer** (on by default): Admin shows "Awaiting lawyer OK" on the
  owner's page while it is on. Owners sign either way.

## Guides

- `admin/owner-money`: The flat-rate agreements.
- `owner/fees-payments-and-payouts`: A flat monthly payment and your agreement.
