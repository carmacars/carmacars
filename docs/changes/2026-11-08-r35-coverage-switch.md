# A booking switches between card coverage and the Protection Plan, offer or active booking (Release 35, part U: 0890, 0891)

Branch `r35-u`. Migrations `0890_r35u_coverage_switch.sql` and `0891_r35u_coverage_switch_guides.sql`. No applied migration is
edited. Test: `supabase/tests/99_r35u_coverage_switch.sql`; unit test `web/src/features/money/coverage-switch.test.ts`.

The owner's request (November 8, 2026): "there needs to be a way to change bookings from rental card coverage to protection plan,
whether an offer or active booking."

| Item | What changed |
| --- | --- |
| The action | `app.coverage_switch(by, {booking, to: plan or card, note, notify, plan_cents})`, through the staff door (`ops_do` `coverage_switch`); `coverage_switch_state` (`ops_read`) gives the booking page its card. On the booking page: the Coverage card (Overview and the Money tab) with "Switch to the Protection Plan" and "Switch to card coverage", each showing the price, the new total and what it will do before it is pressed |
| Who | An Admin, customer service and fleet on any booking that is not finished; sales on a request or an offer. Customer service or an Admin may type the plan's price for this booking (for the days left); everyone else gets the price of the existing Protection Plan rules (`coverage_sold`, per rental, per period of a long rental). Refused with the reason for an Owner Booking, an insurer-billed booking, a car with coverage included, a car whose plan has no price, a cancelled or finished booking |
| An offer (requested, offered, waiting for payment) | The offer is opened as the "Change an offer that is out" flow does, repriced with the Protection Plan line and sent again as the next version with a message naming the change (the usual `renter_offer_ready` email: new price, what changed). A booking already paid for its total is not reopened (the existing refusal) |
| A confirmed booking or a rental in progress | The Protection Plan line is added by the price sync, the totals follow, and the difference is open on the Money tab (`booking_part_open` balance) for the pay link, the device or the saved card, exactly as any fee. The signed agreement gets an amended version by the agreement job (rental terms 15.4: the coverage option and the price are material). On a rental in progress the plan is active at once (a confirmed Protection Plan proof), since there is no handover left to gate |
| Card coverage holds cleared | The card or policy proof (submitted or confirmed) lapses, its uploads are marked replaced, and the review task, `coverage_proof_needed` and the verification task are cancelled, the verification task only when no licence document still waits for review; the renter's "ask for the plan" task is done. The readiness check no longer asks for the card |
| The reverse | The plan line is voided; a plan that was paid raises a refund for approval (a card payment is linked to its charge) and a finance task. The proofs, uploads and tasks cleared by the last switch come back as they were; when no proof is in review or confirmed, customer service gets `coverage_proof_needed` and the card coverage flow takes over (the renter ticks their card, staff review). The option returns to what the booking had before (card coverage unless it was OPCF 27). Refused while the renter's card is a debit, prepaid or not in their name |
| Record | `coverage_switches` (who, when, from and to, status, totals, plan amount, the reason, what was cleared), the booking history entry (`adjusted`), and the audit log (trigger) |
| The renter | New email `renter_coverage_switched` (what changed in Before and Now rows, the new total, the money in words, what to do next, the staff reason). On an offer the offer email does the telling instead. The renter's coverage read carries `last_switch`; the booking page's Coverage section says when and what changed and the totals. The renter can already ask for the plan (`protection_plan_request` task, migration 0071), so no new button was needed |
| Not changed | Option 4 (coverage included with the car), the proof flows, the usual prices and fee rules |

## Guides

- `admin/requests-offers-and-bookings`: Switch between card coverage and the Protection Plan.
- `va/customer-service`: Switch a booking between card coverage and the Protection Plan.
- `renter/before-pickup`: If we change your coverage.
