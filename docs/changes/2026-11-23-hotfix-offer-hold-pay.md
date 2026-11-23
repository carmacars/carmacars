# Hotfix: the card box always shows, holds last as long as the offer, phone approval, alerts stay on (3420)

Migration `3420_hotfix_offer_hold_pay_alerts.sql`. Reported on CC-10599 (Nov 23) while the renter was at pickup.

The owner (Nov 23): "make paying and booking easier, never harder."

## What was wrong

- **Sign and pay showed no card box.** The site's content security policy allowed `js.stripe.com` but not `*.js.stripe.com` or `link.com`. Stripe.js now opens the Payment Element's frames there (Stripe's CSP guide), so the browser blocked them and the box stayed empty. Gates could also take the box's place: the pay step needed a confirmed account, and with the email cap used up and Quo out of credit, renters could not confirm. It also refused payment until the licence and the OPCF 27 pages were uploaded (CC-10599's insurance upload failed on the date field).
- **An accepted offer lapsed after about 2 hours** (2961): the unpaid hold was the approval plus `offer_unpaid_hold_minutes` (120). It ignored the offer's own expiry and the pickup, and an expiry staff typed was cut to 1 hour before the pickup. Reopening defaulted to 24 hours.
- **"Renter approved by phone" was refused** ("upload the driver's licence"): the gate (0130) needs the front, the back and the selfie on that booking and a licence expiry date. Her expiry was never saved (the date field bug). Book it now (0810) does not hit this gate: a booking staff add skips it.
- **Phone alerts switched themselves off**: three refusals in a row from a push service (any 400, 401, 403 or 413) deleted the device.

## Changes

- The CSP (Worker and the local server) allows `https://*.js.stripe.com` (scripts and frames) and `https://link.com https://*.link.com` (frames and calls). `Permissions-Policy` lets Stripe's frame use `payment` (wallets). Apple Pay and Google Pay are on in the Payment Element, except for credit card coverage (option 2), which pays on the covering card.
- Sign and pay: the card box always opens once the agreement is signed. What is still to send shows as a short note beside it ("Upload before pickup: Driver's licence (...), Insurance (...)") with an **Upload now** link. Paying no longer needs a confirmed account. Accepting still follows `signin_confirm_required`.
- Program settings: `booking_licence_before_payment` (new) and `opcf27_before_payment` are **off** by default, and the live setting is turned off too. The handover still refuses a car until every driver's identity is verified and the coverage is confirmed (0011).
- With the licence setting on, staff recording **Renter approved by phone** go ahead when the licence photos are there (any status but rejected), and the history lists what is still to check. An Admin goes ahead with a reason (the dialog's new optional field), also logged.
- The unpaid hold lasts until the latest of: the approval + `offer_unpaid_hold_minutes`, the offer's own expiry, and, for a pickup within 24 hours, the pickup + 2 hours. A typed offer expiry is kept as typed. A default offer for a pickup within 24 hours stays open until 2 hours after the pickup. **Reopen offer** is open, by default, as long as the original offer was.
- A push refusal keeps the device and records the error. Only 404/410 (the device is gone) remove it, and the browser subscribes again by itself (3113).

## Tests

`supabase/tests/99_hotfix_offer_hold_pay.sql` (new). Updated to the new rule: `99_r48_offer_holds.sql`, `99_push_alerts.sql`, `99_r35b_card_fuel_delivery.sql`, `56_phone_sign_in.sql`, `82_handover_signing_licence.sql`. Unit: `web/src/lib/security/csp.test.ts`.

## Guides

No guide change in this hotfix: the renter guide's line "Send both before you pay: the payment opens once they are in" (OPCF 27) is now out of date. It goes to the R49 guides accuracy pass, together with the new Admin override field.
