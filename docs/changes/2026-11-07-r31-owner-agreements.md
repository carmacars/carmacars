# Owner agreements for every special deal (Release 31, 0640 and 0641)

Branch `r31-agr`. Migrations `supabase/migrations/0640_owner_agreements_fleet_lease.sql` (records, billing, claims,
agreements, the checklist) and `0641_r31_owner_agreement_guides.sql` (guide text only). SCHEMA_MARKER 0641. Tests:
`supabase/tests/99_r31_owner_agreements.sql` (66 assertions), `web/src/features/owner-agreement/fleet-lease.test.ts`.
Texts: `docs/source/v2_fleet_lease.md` (new), `docs/source/v2_referral_override.md` (new), `docs/source/v2_enrollment.md`
(4.2, 4.9 and Schedule B amended). No applied migration is edited; no amount, rate or person is in the repository: each
supplier's numbers are entered in Admin.

## 1. Fleet lease (a supplier's corporation leases many cars to the Company)

| Item | How it works |
| --- | --- |
| Terms type | The owner's pay model `fleet_lease` (every car of the owner on a fleet lease); its agreement set is the **Fleet Supplier Lease Agreement** (`owner_agreements.variant = 'fleet_lease'`) with the standard Title-Holding and Lease Agreement and Forms A to D |
| Supplier terms | `owner_fleet_lease_terms`, dated, per supplier: Regular Rate and Troubled Rate (the lease a month of each car of that tier), Claim Profit Share, Early Write-Off Share, Write-Off Period (months), Later Write-Off Share, Notice Period (days). Admin > the owner > Terms > **Fleet lease** > Enter the lease terms. All required, none preset. Before the supplier signs: in force from their date and the cars are repriced. After: the new row waits (`awaiting_signature`), the signed agreement ends and a new one opens for signature; on signature the rates apply from their date |
| Tier | Per car on `vehicle_owner_arrangements` (kind `fleet_lease`, `lease_tier`). Set once when the car is onboarded and never changed: **Add another car** for a fleet lease owner requires it (with the delivery date); `staff_add_owner_car` refuses a car without one. Shown read only. Only an Admin corrects a data-entry mistake (`fleet_lease_tier_correct`, with the reason, audited), from the delivery or from the day after the last approved statement |
| Payment | 0196's flat monthly mechanics: a credit a month on the owner statement, paid with the payout run; CarmaCars keeps every rental. In arrears: a car's first payment is on the first Payout Date (the 10th) at least one full month after delivery and covers every month up to then (`app.fleet_first_pay_month`); after that each month on the next 10th. Part months by the day (`calc_prorated_fee`); the line shows it: "Lease payment, August 2026, Regular car: $X a month x 27 of 31 days (Aug 5, 2026 to Aug 31, 2026) = $Y". The lease runs from delivery, before the car is on the fleet policy |
| No fees | The supplier pays CarmaCars nothing: a trigger on `owner_invoices` refuses any invoice (except a credit note) for a fleet lease car or an owner whose cars all are; the monthly run passes the car by (`generate_owner_invoice`); `owner_debit_block` blocks any debit; a car joining the lease has its unpaid fee invoices voided (debits cancelled) |
| Claims | `settle_claim`: on a car leased on the day of the incident, the supplier's Claim Profit Share of a profit is a credit on its statement; a shortfall stays with the Company. `record_total_loss_settlement`: any lender first, then the Early Write-Off Share of the balance under the Write-Off Period of months in service (from delivery to the loss), the Later Write-Off Share after it, as a credit; the Company keeps the rest. Lease payments continue while a car is in a claim and end on a write-off decision |
| Upkeep | `owner_upkeep_split` (the Upkeep Table): engine, transmission, shocks, rustproofing, refurbishment, tires, brakes, oil changes, ball joints, each the supplier's or the Company's. A supplier cost is an owner deduction (off the lease payment): Record an upkeep cost (`fleet_upkeep_cost`), and r29's repair costs (`vehicle_repair_costs.cost_type`, the new "Upkeep type" on the repair cost form) bill the supplier by trigger when CarmaCars paid and no claim is involved; voided, the deduction goes |
| Statement | The owner statement of the supplier: lease lines (`flat_payment`), claim profit and write-off credits, upkeep deductions |
| Agreement | `fleetEnrollment` in `features/owner-agreement/model.ts`: the cover summary with the Lease Terms and the Upkeep Table, the articles, Schedule A per car (tier, lease rate, delivery date); Additional Vehicle Schedules for cars added later. Signed in the portal with the full e-signature flow (the packet) |

## 2. The audit of every other deal

| Deal | Platform | Agreement | Result |
| --- | --- | --- | --- |
| Standard split owners | owner_terms per car; first and last and one-off fees (0067, 0238 `collect_by` payout); later monthly Fees by debit | 4.2 said the first and last were paid before the Enrollment Date and Schedule B that CarmaCars' only onboarding charges were the Install Fee and the first and last | **Fixed**: 4.2 allows the first and last and the listed onboarding costs (such as registration) to be deducted from payouts, later Fees by debit; Schedule A shows the first and last, the onboarding costs and how they are paid. [LAWYER] |
| Management-fee owner (40% plus $350 a car) | Revenue Share 4000 bps and the $350 as the car's monthly Insurance Fee (owner_terms); the 10 points to the referrer as an `owner_referral_links` share of 1000 bps of the revenue base (0543), out of CarmaCars' share | Vehicle Schedule shows them as Revenue Share and Insurance Fee | Fits. Owner to confirm the $350 is the monthly fee the agreement calls the Insurance Fee |
| Referrer | 0543 `sees_cars`: the referred cars read only, statement lines | none existed | **Added**: Referral Override Agreement (portal `/owner/referral-agreement/<link>`, doc_type `referral_agreement`, countersigned at once) |
| Shareholder-owned cars | 0079: 90/10, no Insurance, Tracker, Install Fee or first and last (invoice guard) | Schedule A printed the grid fees for such a car | **Fixed**: Schedule A marks a Shareholder Vehicle with no fees and the company share; new 4.9. [LAWYER] |
| Flat monthly payment | 0196 and the flat-rate set (0205) | Flat-Rate Vehicle Enrollment Agreement | Fits, unchanged |
| Turo-only management | Management Mode turo_only: no fees, no Title Agreement (packetKeys) | Enrollment 6.3 | Fits, unchanged |
| Brokered partner fleets | partner_rate basis (0361): listed rates less `partner_discount_bps`, kickback `commission_bps` | Partner agreement v4 sections 1, 3, 4 | Fits, unchanged |
| Owner exclusions | none on the platform (agreement only, r28 A9) | Enrollment 11.1, flat-rate 9.1; fleet lease: the Upkeep Table | Fits |

## 3. Admin > Owners > Agreements

`/admin/owners?view=agreements` (button **Agreements** on Owners) and the top of each owner's Terms tab
(`app.owner_agreements_checklist`): per owner the agreements their deal needs (the program set of their pay model, the
Title-Holding and Lease Agreement where a car is not Turo-Only, an Additional Vehicle Schedule, the Partner agreement, a
Referral Override Agreement per referral), each **Signed**, **Sent, not signed**, **Not sent** or **Missing** (no terms
yet), with **Send**: the email `owner_agreement_to_sign` (new) with the link, logged in `owner_agreement_sends`.

## 4. The lawyer's open points

Marked `[LAWYER: ...]` in `docs/source`; left out of the portal text by `scripts/gen-owner-agreements.mjs` and listed
(`FLEET_LAWYER_NOTES`, `REFERRAL_LAWYER_NOTES`, `ENROLLMENT_LAWYER_NOTES`). Program settings
`fleet_lease_agreements_awaiting_lawyer` and `referral_agreements_awaiting_lawyer` (on) show "Awaiting lawyer OK" in
Admin; owners can sign either way.

## 5. Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `supabase/tests/07_notifications.sql` | catalogue 209/21 | 210/21 | the email `owner_agreement_to_sign` |
| `web/src/lib/schema-marker.ts` | 0585 | 0641 | the new migrations |

## Guides

- `admin/owners-and-onboarding`: Agreements: who still needs to sign; A fleet supplier: the fleet lease.
- `owner/documents-and-forms`: The agreement for your deal.

Exported to `docs/guides/content`; migration 0641 publishes the 2 changed chapters (`supabase/seed/0641_gen_guides.mjs`).
