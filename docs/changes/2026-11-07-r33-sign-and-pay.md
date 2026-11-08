# Sign and pay on one page, one rule for "signed", Charge the renter, deposit reasons, expired holds, the debit deposit fee (Release 33, part I: 0750 and 0751)

Branch `r33-i` (on `r33`). Migrations `supabase/migrations/0750_r33i_sign_pay_deposits.sql` and
`0751_r33i_sign_pay_guides.sql` (guide text only, `supabase/seed/0751_gen_guides.mjs`). SCHEMA_MARKER 0751. Tests:
`supabase/tests/99_r33i_sign_pay.sql` (50 assertions), `web/src/features/portal/sign-pay.test.ts`,
`web/src/features/money/charge-reasons.test.ts`, `next-step.test.ts`, `money-panels.test.ts`, `trip-model.test.ts`. No
applied migration is edited; the functions changed are wrapped (suffix `_pre0750`).

## The owner's requests (November 7, 2026)

| Item | How it works |
| --- | --- |
| 1. The sign and pay loop (booking CC-10080) | The sign page read the booking's latest agreement (`my_booking`: open, signed or completed, any offer version) and sent the renter to pay once the renter had signed; the payment (`server_booking_payment_facts`, 0072) counted only an agreement signed **for the approved offer version**, so the pay page said "Payment not available". They disagreed when (a) the approved offer version moved after the renter signed while the signed agreement stayed live (an approval that opened no new agreement: staff on the renter's word, or the agreement's render failing after the approval; CC-10080's state), (b) a rental added while underway with a payment link (0074) has an agreement with no offer version, which the payment refused and the live confirmation accepts, (c) an additional driver who must sign before payment had not signed: sent to pay, the card authorized, then refused (`agreement_not_signed`). Now **one rule**, `app.sign_pay_state` (step offer, sign, drivers, pay or none; signed; stale; what is due; who still signs): `my_booking` and `my_bookings` carry it (`sign_pay`), the payment facts take `agreement_signed` from it (so `startPayment` agrees), and `server_booking_sign_pay` gives it to the Admin and staff page. A signature for an older offer version opens a fresh agreement for the current one on the Sign and pay page (never sent to pay). Admin **View as** opens the page: `server_account_gate`, `renter_agreement_missing`, `server_agreement_extra`, `server_blindspot_facts`, `server_manual_rental_sign_charge` and `server_booking_sign_pay` are read-only calls in `src/server/view-as.ts` |
| 2. Sign and pay made easy | `/account/bookings/<n>/checkout`, **Sign and pay**, mobile first: what is left in one sentence with the amount ("Two steps left: sign the rental agreement, then pay $..."), the two steps (Sign, Pay), the agreement's summary and the signature, then the card form directly below on the same page (the signature returns to the page at `#pay`). The booking's Next step and the trips page show the same sentence and one button (**Sign and pay $...**, **Pay $...**); every other trip still to sign or pay gets its own card on the trips page. `/sign` and `/pay` redirect into the page (with their query, so a card's 3-D Secure return lands too), so every email and text that links to signing or paying lands on it; the offer page, the pickup page and the money list link to it. The Admin and staff booking page's Next step quotes what the renter sees ("The renter sees: ..."), and its Rental agreement essential follows the rule (`src/features/portal/sign-pay.ts`, shared) |
| 3. Deposit keep reasons | Keep part of the deposit and A later charge choose the reason from a list: Mileage overage, Fuel, Cleaning, Smoking, Late return, Tolls, Tickets/fines, Damage, Missing items, Other (Other shows a text box, required). Stored as `payments.reason_code` / `reason_note` and `deposit_events.reason_code` / `reason_note`, checked in the database (`app.charge_reason_text`); the renter's receipt has a Reason line and the Money tab's history shows it (`server_booking_charge_reasons`) |
| 4. Expired card holds | (a) A capture Stripe refuses because the hold lapsed (canceled) marks the deposit (`deposits.hold_lapsed_at`, its expiry set to now), the guard sweep marks a hold past its expiry, and the database refuses a capture of a lapsed hold before Stripe. The panel says **Hold expired**, hides Keep and Release, and **Charge the card on file instead** opens the later charge with the amount and reason filled in. (b) The deposit job re-authorizes a hold about 24 hours before it expires on bookings whose deposit is not settled (`server_deposit_reauth_due`, `_begin`, `_finish`; the existing Re-authorize, run as the system; one try per 6 hours); a failure is on the booking's history and alerts Finance and an Admin (staff alert **Deposit hold not re-authorized**, `deposit_reauth_failed`). Processor errors are mapped to plain sentences (`plainProcessorError`) in Keep, Release, the later charge, Re-authorize and the job |
| 5. Charge the renter | After the return the Money tab has one action, **Charge the renter**: the reason (the list above), the amount, an optional note, and one line that says where the money comes from before anything moves: the deposit hold while it is valid and covers the amount (the rest of the hold is released), otherwise the card on file, otherwise a pay link by text or email (otherwise record it). A hold that lapsed meanwhile is charged to the card on file instead. **Release** stays its own button; A later charge and Keep part stay for before the return |
| 6. Debit deposit fee | A deposit charged instead of held on a debit or prepaid card (Charge the card on file as the deposit) carries the **Card processing fee for a debit deposit** on the same charge, apart from the deposit (`payments.card_fee_cents`): Program settings `debit_deposit_fee_bps` (290: 2.9%) and `debit_deposit_fee_cents` (30). The deposit recorded is the deposit only, so its refund returns the deposit only. The receipt lists the deposit (refundable) and the fee (non-refundable); the Money tab's history shows the fee; the renter's Sign and pay page says it before they pay |

Every change is on the one booking page Admin and staff share (`src/features/booking-page/BookingPage.tsx`), so Finance,
Customer service and Fleet see it by their functions, as before.

## Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `web/src/features/portal/trip-model.test.ts` | the rental owing links `sign` or `pay` | `checkout` (Sign and pay) | item 2 |
| `web/tests/e2e/portal.spec.ts`, `second-agreement.spec.ts`, `rentals-in-progress.spec.ts` | `/sign`, then `/pay`; Sign and continue to payment | one page, `/checkout`; Sign, then pay $... below; the old addresses redirect | item 2 |
| `web/tests/e2e/offers-and-rentals.spec.ts` | a later charge's reason typed | chosen from the list | item 3 |
| `web/src/features/legal-review.test.ts` | Accept and sign on the sign page | on the Sign and pay page (`checkout/page.tsx`) | item 2 |
| `supabase/tests/99_r32_booking_flows.sql` | a cash payment received `current_date` (UTC) | today in Toronto | failed every evening after 8 pm Toronto time ("cannot be in the future") |
| `web/src/lib/schema-marker.ts` | 0722 | 0751 | the new migrations |

## Not done here

- **Admin override on handovers and Record a past trip** (the owner's item 7, CC-10049): not started in this part. The
  checks that block a pickup or a return live in several database functions (the insurance policy check of 0064 and its
  successors, the handover and return functions of 0130 to 0263); an override needs a reason-recorded bypass in each and
  the request and approve flow, best done as its own part.
- The reason code of a later charge recorded as paid another way or sent as a pay link is in its text (the receipt and
  the history read it); only charges to the card on file and kept deposits store the code.
- No local server: the pages were not opened in a browser; the updated end-to-end specs were not run (CI). Type check,
  lint, unit tests and the database suite ran.

## Guides

- `renter/sign-and-pay`: one page, the two steps, the updated offer, another driver still to sign, the debit deposit fee.
- `renter/quick-reference`: Sign and pay on one page.
- `admin/requests-offers-and-bookings`: Charge the renter, the reason list, Hold expired, the job's re-authorization and its alert, the debit deposit fee, what the renter sees.
- `admin/settings`: Card processing fee for a debit deposit.
- `va/finance`: Charge the renter, the reason list, Hold expired, the alert, the debit deposit fee.

Exported to `docs/guides/content`; migration 0751 publishes the 5 changed chapters (`supabase/seed/0751_gen_guides.mjs`).
