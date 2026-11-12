# Change protection, for staff and for the renter, with the coverage order (Release 41: 2540 to 2542)

Branch `r41-protection`. Migrations `2540_r41_protection_change.sql`, `2541_r41_coverage_choice.sql`, `2542_r41_guides.sql`.
Tests: `supabase/tests/99_r41_protection.sql`, `web/src/features/protection/model.test.ts`.

The owner, Nov 12: "Changing insurance protection options for renters became very easy for staff and admin to do right? If you have
[not] simplified that process then please do. And also simplify it for allowing renters themselves to change it." And: "Customers
input what credit card they have and check if that credit card has coverage through our live website checker and database. Only if
their selected credit card has coverage AND they acknowledge they must pay with that credit card can they pick credit card coverage.
If not, they must have OPCF27, and to use OPCF27 they acknowledge they must upload their policy. If they have neither, they must
purchase the Protection Plan."

## 1. One rule for both paths

| Item | What changed |
| --- | --- |
| The rules | `app.protection_block(booking, option, side)`: not an Owner Booking, not billed to an insurer, not a car with insurance included, not the option it has, not after damage was reported on the booking (an accident, theft, vandalism or damage incident), the plan has a price, card coverage only on a credit card in the renter's name. Staff: a request, an offer, a confirmed booking or a rental in progress (0890). Renter: from the approved offer; their own insurance or card coverage only while the documents are open (before pickup, 0072), so during the rental only the plan; one request in review at a time. The r35 switch (`app.coverage_switch_block`) asks the same function |
| The coverage order | `app.coverage_choice_problem`: card coverage only with a card from the coverage list that covers the car (`app.card_cover_for_car` before a booking exists, `app.card_product_check` for a booking, which also needs the same network as the card that paid) and the acknowledgement to pay with it; OPCF 27 only with the acknowledgement to upload the policy (the upload itself stays required before the handover, 0071 and 1401); otherwise the plan. The booking keeps `coverage_card_id`, `coverage_card_ack_at`, `opcf27_ack_at` |
| Where it is enforced | The website's request (the server marks it `details.source = web`; a refused request keeps nothing), the renter's change, the staff change (an Admin may override with the reason: `coverage_switches.override_reason`, booking history, audit log), and the verify page's option buttons, which now lead to Change my protection |

## 2. Staff: Change protection

The **Protection** card at the top of the booking page (Admin and staff portals, Overview and Money) replaces the r35 Coverage card:
one button, a small dialog with the three options, each with the price difference (the plan a day times the days, plus HST), the
deposit (no rule ties it to the coverage), what the renter provides and the rule; a required reason. It applies at once through the
r35 switch: more to pay is a balance to collect, less is a refund for approval; no money moves by itself; an offer is sent again,
a confirmed booking gets the amended agreement (`app.agreement_plan`) and one email (`renter_coverage_switched`). Going between own
insurance and card coverage, or from the plan to the option the booking did not have before, now works too (`to_own` changes).

## 3. The renter: Change my protection

On the renter's booking page (Protection card): the three options with prices. The plan applies at once (the difference is the
Balance due with Pay); before the offer is paid it reaches customer service as the 0071 request. Their own insurance and card
coverage switch at once before pickup. Leaving the plan needs the proof (photo or PDF, private storage) and is a request
(`protection_requests`, task `protection_change_review`): customer service approves (the change is made and the coverage
confirmed from the request) or declines with a note the renter reads; the renter can withdraw it.

## 4. Request form

Credit card coverage asks for the card from the list, shows the checker's answer live, and asks the acknowledgement; OPCF 27 asks
its acknowledgement.

## Not done

At checkout the card that pays is compared with the chosen card's network when the coverage is confirmed (1400); the pay page
does not yet stop a payment made with a card of another network.

## Guides

- `admin/requests-offers-and-bookings`: Change protection (replaces the r35 switch section)
- `va/customer-service`: Change protection and reviewing a renter's request
- `renter/before-pickup`: Change my protection and the coverage order
