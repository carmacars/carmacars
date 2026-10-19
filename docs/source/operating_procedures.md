# CarmaCars Operating Procedures

**Roles:** Admin (Abbas, Mahad) · Finance · Fleet · CS · Field (employees). **RA** = Rental Agreement PDF (Part 1 Summary, Part 3 Schedule, Part 4 Condition Report, Part 6 Consents). **Signing:** fill the PDF, send it through the e-signature service, file the signed copy with the booking or owner record. **Record:** manual record now → platform record later.

## 1. Renter inquiry to confirmed booking

**Trigger:** inquiry by call, email, WhatsApp or web · **Owner:** CS · **Time limit:** reply in 15 minutes during opening hours; tentative hold lasts 2 hours

1. Get dates, times, place, car, delivery or self-collect, each driver's age, and who referred them.
2. Every driver: 18 or older, G2 or G licence. Under 21: only cars flagged "18 to 20".
3. Check the car's calendar. Length must be 30 days or less. Add a tentative hold.
4. Quote from the rate sheet and RA Part 3: rental charge (table), delivery and pickup ($75 to $200 each way), young driver fee (procedure 2), additional driver ($10 a day, max $70), extras, 13% HST; Deposit separate, taken at pickup. Offer 10% off the rental charge for non-refundable. Send T1.
5. On yes, fill RA Part 1 and send it for signature. Renter ticks all four Part 6 consents; each Additional Driver signs and ticks 1 to 3.
6. Send a CarmaCars checkout link for "Total due at booking". Credit card in the renter's name only. Enter type and last four digits as Card on File.
7. Signed and paid: countersign, file the signed RA, mark the calendar Confirmed, send T2, start procedure 2.
8. Self-Managed car: the Owner sets the price; steps 2 to 7 and CarmaCars' checkout still apply.

| Length | Rental charge |
| --- | --- |
| 1 to 6 days | Daily rate; weekend rate for days starting Friday or Saturday. Cap: weekly rate |
| 7 to 29 days | Weekly rate ÷ 7 per day. Cap: monthly rate |
| 30 days | Monthly rate |

Mileage allowance = allowance per day × days.

**Record:** Bookings log row with "Referred by" (Owner, Field staff or none), signed RA in the booking folder → Booking (Confirmed, referred_by), Payment.

**Escalate to admin when:** other discounts; travel outside Ontario; pets; a refusal; a request over 30 days.

## 2. Renter verification and coverage proof

**Trigger:** booking confirmed · **Owner:** CS · **Time limit:** 24 hours before pickup; no car is released without it

1. Send T3. Collect what it lists from each driver.
2. Staff review: name, date of birth, class G2 or G, expiry after the return date, face matches. Tick "Identity verified – Staff review" and the date in RA Part 1.
3. Apply the age fee per driver, by age at pickup.
4. Collect and check one Coverage Option. Tick "Proof or activation confirmed". Send T4.
5. Identity not verified: refuse and refund everything paid. False documents, or no coverage at pickup: cancellation at that moment (procedure 7).

| Age at pickup | Rule | Fee |
| --- | --- | --- |
| 18 to 20 | Only cars flagged for them | $35 a day, max $350 per rental |
| 21 to 25 | Any car | $20 a day, max $200 per rental |

| Option | Collect | Check |
| --- | --- | --- |
| 1. OPCF 27 on own auto policy | Policy page or insurer letter showing OPCF 27 | Active to the return date; covers this car and every driver. Enter insurer, policy number, expiry. |
| 2. Credit card rental coverage | Card benefits certificate | Same card pays the rental and is Card on File; covers this car class and rental length. Enter issuer, last four digits. |
| 3. Bought through CarmaCars | Payment of the Option 3 line | Send the provider's terms first. Activate; file the confirmation. Never name the provider. |

**Record:** verification checklist in the booking folder → Renter.identity_status, Booking.coverage_option, Booking.coverage_proof.

**Escalate to admin when:** non-Ontario licence; doubtful document; proof that does not clearly cover the car; any refusal.

## 3. Delivery or pickup handover

**Trigger:** pickup day, procedure 2 complete · **Owner:** Field (Fleet dispatches and reviews) · **Time limit:** car ready 30 minutes before pickup; photos reviewed within 1 hour

1. Fleet, the day before: send Field the job on WhatsApp and the renter T5.
2. Finance, at pickup before handover: take the Deposit in the Summary. Card hold for rentals of 7 days or less; charge and refund for longer.
3. Field: hand over only to the Renter, in person. See the original licence and the physical Card on File; match them to RA Part 1.
4. Complete every line of RA Part 4, Pickup column. Fleet confirms "Tracker in place and reporting" and, on a rental CarmaCars manages, blocks the Owner's lock, alarm and shut-off (live location stays).
5. Take the photo set in this order: front · front-left corner · left side · rear-left corner · rear · rear-right corner · right side · front-right corner · roof · windshield · four wheels · instrument cluster with ignition on · front seats · rear seats · trunk · keys · close-up of each D.
6. Renter and Field sign Part 4 with date and time. Upload to the booking folder; post "Handed over" in the ops group. Fleet reviews and marks the calendar On Rent.
7. Self-Managed car: the Owner does steps 3 to 6; Fleet then enables the car for the booked period only.

**Record:** Part 4 Pickup column, photos → Inspection (check-out), Booking.status On Rent, Deposit.

**Escalate to admin when:** wrong person; licence or card mismatch; renter seems unfit to drive; Deposit declined; Tracker not reporting; unattended handover requested. Do not release the car.

## 4. Return and inspection

**Trigger:** return time · **Owner:** Field (Fleet reviews) · **Time limit:** inspect at hand-back; unattended return by noon next business day

1. Fleet: send T6 24 hours before return.
2. Field: take the car and all keys. That moment is Check-in; write the time.
3. Complete Part 4, Return column, and the same photo set in the same order.
4. Compare both columns with the renter present: new D, odometer, fuel, cleanliness, odour, keys, extras.
5. Renter and Field sign.
6. Fleet: compare both photo sets. Send Finance T7 the same day.
7. Damage found later: Fleet sends T8 with photos within 48 hours of return.
8. Mark the calendar Cleaning, then Available after procedure 18. Fleet restores the Owner's controls; a Self-Managed car is disabled again.

**Record:** Part 4 Return column, photos, T7 → Inspection (check-in), Booking.status Returned.

**Escalate to admin when:** any damage; car left somewhere else; Tracker tampering; renter disputes a finding.

## 5. Post-rental charges and deposit release

**Trigger:** T7 received · **Owner:** Finance · **Time limit:** Deposit balance released within 7 business days of Check-in (target 2); up to 30 days for the amount expected on an open claim, toll or ticket; refunds within 10 business days

1. Price each finding from the table. Amounts are before HST.
2. Email the itemized statement with the supporting record for each line: photos, receipts, shop estimate (T9).
3. Capture from the Deposit what is owed, hold back the amount expected on an open item, release the rest. Charge any excess to the Card on File.
4. Declined: add $40, send T10, retry after 24 hours. Overdue amounts carry 1.5% a month.

| Charge | Rule |
| --- | --- |
| Extra kilometres | (Km driven − allowance) × $0.35; $0.75 to $1.50 for luxury and exotic, per the Summary |
| Fuel or charge | Pump price plus 25%, plus $25; or $10 per 10% battery, plus $25 |
| Cleaning | $75; $250 heavy soiling or odour; pet $150; smoking $300 |
| Lost key or fob | Replacement cost plus $50 |
| Damage under $2,500 | At cost: approved shop estimate or invoice, towing, storage, loss of use (daily rate per day off the road, max 30), plus $50 administration fee |
| Damage of $2,500 or more | $2,500 plus $75 administration fee (procedure 9) |

**Record:** Charges log, statement → Invoice lines, Deposit.applied, Deposit.released_at.

**Escalate to admin when:** any damage line; a dispute; a charge unpaid after 24 hours.

## 6. Extension and monthly renewal

**Trigger:** renter asks to keep the car · **Owner:** CS (Finance takes payment) · **Time limit:** confirmed in writing and paid before the current return time

1. Check the calendar, unpaid charges, and coverage proof to the new return date.
2. Total length stays at 30 days or less: reprice the whole booking at its new length (procedure 1), take the difference, send T11 (the written confirmation), update the Bookings log and calendar. Total now over 7 days: capture the card hold as a charged Deposit.
3. Total would pass 30 days: new booking number and new RA marked "Renewal of agreement no. __", signed and paid before the current rental ends.
4. Renewal day: the renter uploads the photo set, filed as the old Return column and new Pickup column. Finance bills the old agreement (procedure 5) and carries the Deposit over.

**Record:** Bookings log → Booking.return_at (extension), or new Booking with renews_booking_id.

**Escalate to admin when:** rate change; unpaid charges; clash with another booking.

## 7. Cancellation and refund

**Trigger:** cancellation received by email or online (WhatsApp: ask for an email; its time counts) · **Owner:** CS logs, Finance refunds · **Time limit:** refund within 10 business days (target 2)

1. Log three times: booking made, cancellation received, start (pickup time in the Summary).
2. Non-refundable booking: no refund.
3. Standard booking: use the first row that fits.
4. Refund = percentage × total paid at booking. Any Deposit is returned in full.
5. CarmaCars cancels (no car or accepted substitute): refund everything, even non-refundable bookings.
6. Free the calendar. Send T12.

| Cancellation received | Refund |
| --- | --- |
| Within 24 hours of booking and 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 hours or more, but less than 48 hours, before the start | 50% |
| Less than 24 hours before the start, after it, or a no-show | None |

**Record:** Bookings log (cancelled_at, row used, refund) → Booking.status Cancelled, Refund.

**Escalate to admin when:** any refund outside the table; any refund over $500; a chargeback.

## 8. Late return and non-return

**Trigger:** car not back at the return time · **Owner:** Fleet; Admin decides disabling, repossession and police · **Time limit:** counted from the return time in the Summary

| Time after return time | Action |
| --- | --- |
| 0 | Call. Send T13. Check the Tracker. Offer a paid extension (procedure 6). |
| 30 minutes | Charge the rental charge for each extra day, plus the late return fee counted from the return time: $25 an hour, max 1.5 × daily rate per 24 hours. |
| 2 hours | Call twice. Send T14: 1 hour to return or pay. Tell Admin. |
| 1 hour after T14 | Only an Admin approves disabling. Fleet disables only when the Tracker shows the car stationary, ignition off. Never while moving. Send T15. |
| 24 hours, renter unreachable | Admin may report the car stolen. Fleet gives police the Tracker location; tell the Owner. |

1. Anyone at risk where the car is disabled: re-enable at once so they can reach a safe place.
2. Other grounds, same 1-hour notice: a Charge unpaid 24 hours after request; a serious breach; coverage ended.
3. No notice needed: suspected theft, abandonment, fraud, unsafe, impaired or unlicensed driving; Tracker tampering, or silence with the renter unreachable; police, court or insurer order.
4. Repossession: peacefully, from a street, driveway or open lot. Never by force, never from a dwelling or locked garage.
5. After recovery: procedures 4 and 5, plus recovery costs; no refund.

**Record:** Incident log timing every call, message, command and pre-disable Tracker screenshot → Incident (late), TrackerCommand.

**Escalate to admin when:** 2 hours late; always before disabling, repossession or police.

## 9. Accident, damage and claim

**Trigger:** accident, theft, vandalism, or damage found at return · **Owner:** Fleet opens, Admin runs the claim, Finance bills · **Time limit:** renter calls within 24 hours and sends report, photos and keys within 48 hours; Owner reports within 24 hours; broker told the same day

1. Anyone hurt: 911. Send T16 and talk the renter through it.
2. Open an Incident log entry: booking, driver, time, place, other party, police report number. Tell Admin.
3. Not drivable: tow to an approved shop (Admin's list). The rental ends: no replacement car, no refund.
4. Get the estimate from an approved shop only. Total = repair + towing + storage + loss of use.
5. Total under $2,500: no claim. Bill the renter at cost plus $50 (procedure 5).
6. Total $2,500 or more: Admin notifies the broker and claims on the fleet policy. Bill the renter $2,500 plus $75. The renter claims on their Coverage Option, payment directed to CarmaCars.
7. Claim denied for the renter's breach (unapproved driver, impairment, prohibited use, false information): Admin bills the full cost.
8. Third-party Owner's car: claim money pays the repair and claim costs; CarmaCars keeps any balance. Total loss: the settlement pays the lender, then amounts owed to CarmaCars, then the Owner.
9. Send the Owner T17.
10. Block the calendar until the shop releases the car, then procedure 18.

**Record:** Incident log, estimate, claim number → Incident, Claim, Invoice.

**Escalate to admin when:** every incident, immediately.

## 10. Breakdown and roadside

**Trigger:** call to the 24-hour line · **Owner:** Fleet (on call) · **Time limit:** roadside dispatched in 15 minutes

1. Confirm the renter is safe. Get location (check the Tracker), symptom, warning lights.
2. Dispatch the roadside provider on file. Send T18. Result: see table.
3. Replacement car: Part 4 Return for the old car, Part 4 Pickup for the new one; enter the new car in the Summary.
4. Tell the Owner: mechanical repair is the Owner's cost. Mark the car Out of Service.

| Cause | Result |
| --- | --- |
| Mechanical, not the renter's fault | Roadside free. Replacement car, or refund of unused time. |
| Lockout, out of fuel or charge, flat battery from lights left on, tire damage, stuck | Renter pays the call-out cost plus $50 (procedure 5) |

**Record:** Incident log (breakdown), roadside invoice → Incident, Invoice.

**Escalate to admin when:** replacement or refund needed; second breakdown of the same car; car unsafe.

## 11. Tolls and tickets

**Trigger:** toll invoice, ticket, camera offence, parking or impound notice arrives · **Owner:** Finance · **Time limit:** matched and charged in 3 business days, and before the notice's due date

1. Log: plate, date, time, place, amount, notice number, due date.
2. Match plate, date and time to who had the car (Rental Period: pickup to Check-in). Tracker data is the proof.
3. Apply the table. Renter: charge the Deposit if still held, otherwise the Card on File; send T19 with the notice.

| Who had the car | Action |
| --- | --- |
| Renter | Pay it; charge the amount plus $15 per toll invoice or $40 per ticket, fine, tow or impound |
| Owner on an Owner Rental | Bill the Owner at cost, no fee |
| Owner outside the program, or a Turo-Only car | Forward to the Owner |
| CarmaCars staff | CarmaCars pays; log the staff member |

**Record:** Toll and Ticket log → TollTicket linked to Booking, Invoice line.

**Escalate to admin when:** no match; court summons; impound or tow; dispute; naming the renter to the authority instead of paying.

## 12. Owner inquiry to live car

**Trigger:** owner inquiry, recruited lead, or an enrolled Owner adding a vehicle · **Owner:** CS to signature, then Fleet; Finance and Admin steps marked · **Time limit:** reply in 1 business day; registry visit inside the safety certificate's 36 days

1. CS: send T20 and collect the answers per vehicle. One agreement per Owner; each vehicle runs steps 2 to 13.
2. Rebuilt, salvage or irreparable brand: decline that vehicle. Turo-Only: procedure 13.
3. Offer only the methods open to that car (table) and give the Owner the estimate for their situation. The Owner pays ServiceOntario, the safety inspection, the appraisal and other third parties directly; amounts may vary.
4. Admin: set the vehicle's Insurance Fee, Tracker Fee, Revenue Share (grid in Enrollment Agreement Schedule B; none for Self-Managed) and Management Mode. Ask the broker to pre-approve the car.
5. Send for signature. First vehicle: Enrollment Agreement (three initials) with its Vehicle Schedule entry, and Title Agreement. Later vehicle: an Additional Vehicle Schedule signed by both sides. Every vehicle: Schedule 1, Form D (Part 1 needs two witnesses). Add Form B for Lease; Form A for Co-Registrant or Transfer; Form C, witnessed, plus the lender's written permission for a financed or leased car.
6. Finance: collect only the vehicle's first and last month's Insurance Fee and the $100 Tracker Install Fee. No security deposit.
7. Owner obtains and pays for the safety certificate and appraisal the method needs. Fleet prepares the government forms and books the registry visit. Send T21.
8. Registry visit: Admin attends for CarmaCars. Owner brings the T21 items and pays at the counter; a corporation also brings proof of signing authority.
9. File the new permit. Complete Schedule 1: how CarmaCars appears, date, plate, renewal month, Owner's Lien number if registered.
10. Field installs the Tracker. Fleet tests location, lock, alarm and shut-off while parked, and gives the Owner access; lock, alarm and shut-off are blocked during rentals CarmaCars manages.
11. Admin: broker adds the car to the Fleet Policy and the insurer's confirmation is filed.
12. Send T22. That date is the vehicle's Enrollment Date in the Vehicle Schedule. Until T22 the Owner keeps their own insurance.
13. Procedure 17.

| How the car is held | Method | Owner's estimate (paid direct) | Government forms |
| --- | --- | --- | --- |
| Corporation, not leased | Lease | $50, no tax | SR-LV-006, SR-LV-012 |
| Individual, not leased | Lease through a new Owner Corporation | $570, no tax | SR-LV-006, SR-LV-012, ON00453, 013-0169, 013-1155 |
| Individual, not leased | Co-Registrant | $250 plus HST | SR-LV-006, SR-LV-012 |
| Any, owned outright or financed | Transfer | $250 plus HST; $260 with Owner's Lien (owned outright only) | Sign-back on the permit |
| Leased | Transfer (only method) | $250 plus HST | SR-LV-006, SR-LV-012 |

**Record:** Owner folder (signed set per vehicle, permit, insurer confirmation), Fleet register row → Owner, Vehicle, VehicleSchedule (fees, share, mode, method, enrollment_date).

**Escalate to admin when:** no lender permission; insurer declines; fee off the grid; undisclosed damage or lien.

## 13. Turo-only owner setup

**Trigger:** owner chooses Turo-Only · **Owner:** CS (Fleet lists) · **Time limit:** listed 2 business days after documents

1. Sign the Enrollment Agreement and the Vehicle Schedule entry only: Management Mode Turo-Only, Onboarding Method None, Revenue Share. No Title Agreement, registry visit, Fleet Policy, Fees or Tracker.
2. Collect: ownership permit in the Owner's name; proof of active comprehensive insurance with expiry; the Owner's written confirmation that their insurer permits Turo rental.
3. Fleet: list the car on CarmaCars' Turo account (photos per procedure 17).
4. Diary insurance and plate expiry. Send T23 14 days before. Unlist the car if proof lapses.
5. Owner wants the car: block the dates on Turo first, then confirm to the Owner.
6. Trips, damage and claims follow Turo's process, not procedures 3 to 10.
7. Payout on the 10th (procedure 14): Turo earnings after Turo's standard fees, less the Revenue Share.

**Record:** Owner folder, Fleet register (mode Turo-Only) → Vehicle.mode, TuroListing.

**Escalate to admin when:** insurance lapse; Turo claim; Turo account warning.

## 14. Monthly owner billing and payouts

**Trigger:** 15th (billing) and 10th (payouts) · **Owner:** Finance · **Time limit:** same day

Billing, 15th:

1. Charge each Vehicle's Insurance Fee and Tracker Fee plus HST from its Vehicle Schedule, Enrollment Date to Exit Date, rented or not. Send T24.
2. Skip Turo-Only cars and cars owned personally by Abbas or Mahad.
3. Pro-rate by day in the first and last month. The prepaid first month pays the enrollment month and the prepaid last month the exit month; credit or refund the unused part.

| Missed payment | Action |
| --- | --- |
| Debit returned for insufficient funds | Add the $50 Late Fee per Vehicle as its own invoice line. Send T25. |
| Debit returned for another reason | No retry, no Late Fee. The invoice's automatic debit is paused; Admin is alerted; the Owner is emailed to pay from the invoice page or update the bank account. |
| The later of the 18th and 3 business days after the return (within 30 days of the debit) | Retry once for the original amount. The Late Fee goes with the next scheduled debit. |
| Retry fails | Deduct from that Vehicle's revenue at the next payout. Do not enable a Self-Managed car for new bookings. Tell Admin. |
| Balance left at the next 10th | Debt payable on demand. Deduct from the Owner's other Vehicles. |
| 30 days after the failed retry | Admin may remove the Vehicle (procedure 16) |

Payouts, 10th, for the previous month:

1. Per Vehicle, list each Rental collected, net of refunds and chargebacks, with its "Referred by" entry.
2. Owner Revenue = Rental Charge + mileage overage − every kickback: the Referral Kickback (20% of the Rental Charge on a referred new renter's first rental, referred by an Owner; none to an Owner on their own Vehicle) and every Staff Commission (the commission of the staff member who sourced or referred the booking, field staff included: 10%, or the Sales tier of 10%, 15% or 20%). On a partner's car CarmaCars pays the Staff Commission from its own commission; on a CarmaCars-owned car it is a CarmaCars expense.
3. Pay Owner Revenue less the Revenue Share (shareholder-owned car: 90%; Self-Managed: 100%), plus Referral Kickbacks this Owner earned. Staff Commissions are approved by an Admin and paid by hand (Admin > Money > Staff commissions).
4. Deduct only: unpaid Fees and Late Fees, Owner costs CarmaCars paid, the Owner's share of a refund or chargeback, amounts agreed in writing.
5. Admin approves the run. Pay by the Owner's payout method. Send T26 with the statement.

**Record:** Owner ledger, statement PDF → OwnerInvoice, Payout, Statement.

**Escalate to admin when:** retry fails; negative balance; Owner disputes a statement.

## 15. Owner rental of their own car

**Trigger:** Owner asks to drive their car · **Owner:** CS · **Time limit:** answer the same day

1. Check the calendar. A renter's confirmed booking has priority.
2. Fill RA Part 1, type "Owner Rental": no rental charge, fees, Deposit or Coverage Option; 30-day maximum. Owner signs and ticks the consents.
3. Check the Owner's licence is valid (procedure 2, step 2).
4. Hand over and return with Part 4 and photos (procedures 3 and 4). Self-Managed car: Fleet enables the car for the booked period only.
5. Tolls and tickets: bill at cost, no fee (procedure 11).
6. Damage under $2,500: the Owner repairs it themselves. A fleet policy claim: bill the Owner the $2,500 deductible (procedure 9).

**Record:** Bookings log → Booking (type Owner Rental).

**Escalate to admin when:** clash with a renter booking; any damage.

## 16. Owner exit and re-transfer

**Trigger:** Owner's written notice naming the vehicle, or Admin's decision to remove it · **Owner:** Fleet (Finance final account, Admin signs) · **Time limit:** 30 days' notice; CarmaCars' part of the Re-Transfer within 10 business days after the Exit Date

1. Log the notice date and the vehicle; the Owner's other vehicles carry on. Set its Exit Date: last day of notice or, if later, the end of a rental in progress. Confirm it to the Owner in writing. Block the calendar after it. Check the fleet stays at 10 or more (procedure 20).
2. Re-transfer fees (registry charges and any required safety only): CarmaCars pays after 6 months on the Fleet Policy; otherwise, and always on Owner default, the Owner pays.
3. Get the Owner's proof of own insurance from the Exit Date. Never delay a Re-Transfer because money is owed.
4. Exit Date: Field removes the Tracker and records odometer and photos. Admin has the broker remove the car from the Fleet Policy.
5. Re-Transfer. Lease: return the car, remove the lessee record. Co-Registrant: remove CarmaCars as registrant. Transfer: sign the registration back to the Owner or the person named in writing.
6. Both sign that vehicle's Form E (Tracker removed, Owner's Lien discharged). Return car, keys and permit.
7. Finance: bill the final month pro-rated (procedure 14) and pay the final balance on the first Payout Date after the month of the Exit Date.

**Record:** Form E, Fleet register (exit_date) → Vehicle.status Exited.

**Escalate to admin when:** fleet would fall below 10; insurer cancels cover; Owner default; buyout offer; sale to a third party; Owner's written reminder after the deadline.

## 17. New vehicle listing and photos

**Trigger:** T22 sent, or Turo-Only documents complete · **Owner:** Fleet (Field photos, CS publishes) · **Time limit:** live in 2 business days

1. Field: detail the car (procedure 18). Shoot in daylight, landscape, plain background: the eight exterior angles of procedure 3, dashboard, front seats, rear seats, trunk, one wheel, odometer.
2. Fleet: add the Fleet register row: year, make, model, trim, colour, fuel, plate, VIN, class, Owner, Management Mode.
3. Admin sets (Self-Managed: the Owner sets rates), Fleet enters: daily, weekend, weekly and monthly (30 days) rates; Deposit ($500 economy and standard, $1,000 premium and SUV, $2,500 luxury and exotic); mileage allowance per day and overage; delivery and pickup fee; "18 to 20 allowed" yes or no.
4. Create the car's calendar; block service and Owner dates. File a baseline Part 4 with the photos.
5. CS: publish on the website, classified sites and social pages. Say "liability coverage included".

**Record:** Fleet register row, photo folder → Vehicle, RatePlan, Listing (published).

**Escalate to admin when:** rates or Deposit not set; existing damage.

## 18. Cleaning and detailing standard

**Trigger:** every return; before every handover or photo shoot · **Owner:** Field (Fleet checks photos) · **Time limit:** within 24 hours of return and before the next handover

Standard:

1. Before cleaning, photograph anything beyond a standard clean. Report it as $75, $250 heavy, pet $150 or smoking $300.
2. Bag left belongings, label with the booking number, tell CS.
3. Wash and dry the exterior, wheels, glass and mirrors.
4. Vacuum seats, carpets, trunk. Wipe dashboard, screens, console, steering wheel, handles. Clean interior glass. No odour.
5. Check washer fluid, tire pressures and warning lights.
6. Fill fuel to full, or charge to 80% or more.
7. Put in the car: permit, insurance slip, charging cable, spare, tools, extras ordered.
8. Post four "ready" photos to the ops group: front, rear, front seats, instrument cluster.

**Record:** Cleaning log → DetailJob (completed_at, photos).

**Escalate to admin when:** damage found; warning light on; service due.

## 19. Daily opening and closing checks

**Trigger:** start and end of each day · **Owner:** Fleet · **Time limit:** opening by 9:00, closing by 18:00

Opening:

1. Tracker: every car reporting; no overnight movement of an idle car; no tamper alert.
2. Today's handovers and returns each have a Field person who has acknowledged.
3. Tomorrow's pickups: procedure 2 complete, T5 sent.
4. Overdue: late returns, charges unpaid over 24 hours, Deposits nearing 7 business days.
5. CS: inbox, WhatsApp and voicemail cleared.

Closing:

1. Every handover and return has a signed Part 4 and photo set filed, and T7 sent for every return.
2. Calendar statuses correct; tomorrow's cars cleaned.
3. Finance: card processor payouts matched to the Bookings log.
4. Incidents updated; handover note sent to the on-call person.

**Record:** Daily checklist sheet → DailyCheck.

**Escalate to admin when:** a car is not reporting; a job has no Field person; a payment does not match.

## 20. Monthly franchisor fleet report

**Trigger:** 1st of each month · **Owner:** Finance · **Time limit:** sent on the 1st; prepared the business day before

1. Export from the Fleet register every vehicle on the Fleet Policy: year, make, model, VIN, plate, date added. List removals since the last report.
2. Match the list to the broker's vehicle list.
3. Count. The fleet must be 10 or more at all times. Turo-Only cars are not counted.
4. Email the report and count to the franchisor, copy Admin. File the sent copy.
5. Each Monday: recount, less cars under exit notice. Warn Admin at 11 or fewer.

**Record:** report file, sent email → FleetReport (month, count).

**Escalate to admin when:** count under 10 or about to be; list differs from the broker's.

## Message templates

Never name the coverage provider.

| Code | Use | Text |
| --- | --- | --- |
| T1 | Quote | [Car], [pickup] to [return]: $[total] with HST, [km] km included, $[amount] refundable deposit taken at pickup. Non-refundable booking saves 10%. Reply YES for the agreement and payment link. |
| T2 | Confirmed | Booking [no.] confirmed: [car], pickup [date, time, place]. Next we verify licence and coverage. |
| T3 | Verify | Please send, for each driver, licence front and back and a selfie holding it. Then choose coverage: (1) OPCF 27 proof, (2) credit card rental coverage proof, (3) coverage bought from us. |
| T4 | Verified | Verified, coverage confirmed. Bring your original licence and the card ending [last four]. |
| T5 | Pickup reminder | [Car] tomorrow, [time], [place]. Bring your original licence and the card ending [last four]. A $[amount] deposit is taken before handover. |
| T6 | Return reminder | Your rental ends [date, time] at [place]. Return with the same fuel and all keys. Need longer? Reply before then. |
| T7 | Findings (internal) | Booking [no.]: km out/in [ ]/[ ], allowance [ ]. Fuel out/in [ ]/[ ]. Cleaning [grade]. Damage [none or list, photo nos.]. Minutes late [ ]. Keys [ ]. |
| T8 | Late-found damage | Booking [no.]: our inspection on [date] found [damage]. Photos attached. An itemized statement will follow. |
| T9 | Statement | Booking [no.] statement and records attached. Charges $[ ]. Deposit applied $[ ]. Held back $[ ]. Deposit returned $[ ]. Charged to card ending [last four] $[ ]. |
| T10 | Declined payment | Card ending [last four] declined for $[amount], booking [no.]. A $40 fee applies. Pay within 24 hours: [link]. |
| T11 | Extension confirmed | Extension confirmed, booking [no.]. New return: [date, time, place]. Booking repriced to $[total]; paid today $[amount]. Other terms unchanged. |
| T12 | Cancellation | Booking [no.] cancelled, received [date, time]. Refund [ ]% of $[paid] = $[amount]. Any deposit is returned in full. Refunds arrive within 10 business days. |
| T13 | Late, first | Your rental ended at [time]. Return [car] now or call [number] to extend. You owe the rental charge for each extra day plus a late fee of $25 an hour. |
| T14 | Late, final | [Car] is 2 hours overdue. Return it or pay for an extension by [time]. After that we may end the rental, disable the car once parked, and recover it. |
| T15 | Car disabled | Your rental has ended and [car] will not restart. If anyone is unsafe where it is parked, call [number] and we will re-enable it. |
| T16 | Accident | If anyone is hurt call 911. Report to police where required. Get the other party's details, take photos, do not admit fault. Send us a written report, photos and all keys within 48 hours. |
| T17 | Owner incident | Your [car] was in [incident] on [date]. We manage the claim and repair at an approved shop. Please do not contact the insurer. Fees continue; downtime is not paid. |
| T18 | Breakdown | Help is on the way to [location], about [minutes] minutes. Stay somewhere safe. Call [number] if anything changes. |
| T19 | Toll or ticket | Booking [no.]: [toll/ticket] dated [date, time], $[amount], plus $[15/40] administration fee. $[total] charged to your [deposit/card]. Copy attached. |
| T20 | Owner intake | To estimate your costs and fees we need, per vehicle: your name; individual or corporation; year, make, model, VIN, plate, kilometres; owned outright, financed or leased; lender; current insurer. |
| T21 | Registry visit | Registry visit [date, time, place]. Bring driver's licence, original ownership permit, proof of current insurance, [lender permission], [safety certificate], [appraisal]. You pay the registry fees and tax at the counter; amounts may vary. |
| T22 | Enrolled | Written confirmation: [car], VIN [ ], is on the CarmaCars fleet policy from [date], your Enrollment Date. You may now cancel your own insurance on it. |
| T23 | Turo-Only expiry | Your insurance on [car] expires [date]. Send renewed proof before then or we must pause the Turo listing. |
| T24 | Owner invoice | Invoice [no.], [month], [car]: insurance fee $[ ], tracker fee $[ ], HST $[ ]. Total $[ ], charged on the 15th. |
| T25 | Missed payment | Your $[amount] payment for [car] failed. A $50.00 late fee is added to your next debit. We retry [amount] on or after [retry date]. The $50.00 late fee is collected with your next debit. If that fails too, this vehicle goes into arrears. |
| T26 | Payout | [Month] statement attached: rentals $[ ], kickbacks deducted $[ ], kickbacks earned $[ ], revenue share $[ ], deductions $[ ]. Paid today $[amount]. |
