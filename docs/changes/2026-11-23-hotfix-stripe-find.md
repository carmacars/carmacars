# Hotfix: find and record a Stripe payment with no booking (Tap to Pay) from the connector (3430)

Migration `3430_hotfix_stripe_find.sql`. Reported on CC-10607 (Nov 23): staff took CA$5,000.00 with Tap to Pay in the Stripe Dashboard app.

## What was wrong

- A payment taken in the Stripe Dashboard app has no booking in its Stripe metadata. The connector's `stripe_booking` finds a booking's PaymentIntents by that metadata, so it never showed the payment, and `stripe_record_paid` refused it (not made for the booking). `record_payment` refuses a card ("A card is paid through Collect a card"), so Claude had no way to record it.

## Changes

- New read-only API tool `stripe_find_payments` (admin:read): the PaymentIntents Stripe created in a window (the last 24 hours by default; `hours` up to 720, or `from` and `to`; 30 days at most) that succeeded or hold a card, optionally of one `amount_cents`. Each with its id, amount, status, time, the card brand and last 4, the method (`card_present` for a tap or a reader) and wallet, the booking in its Stripe metadata, and whether the site recorded it and on which booking. Untied payments not recorded are flagged. Stripe is only read (GET).
- `stripe_record_paid` takes an untied payment (no booking in Stripe): only when Stripe says it succeeded in Canadian dollars, nothing on the platform knows it (any booking, pay link or owner debit), the booking is not cancelled, declined or expired, and its amount is exactly what is open: the rental and fees, the deposit, or both. The preview says it is untied and how it will be linked. On confirm it is recorded as **Link a Stripe payment** does (1081, a card payment taken in the Stripe Dashboard; the deposit kept as captured), audited (`link_stripe_payment`, `connector_stripe_link_untied`, and the API call log), and the booking is written into the PaymentIntent's Stripe metadata (`purpose` `linked_outside`, never one the webhook settles). Nothing is charged, captured or refunded: a hold or any status but succeeded is refused.

## Tests

`supabase/tests/99_hotfix_stripe_find.sql` (new). Unit: `web/src/features/api-access/stripe-inspect.test.ts`, `web/src/features/api-access/tools.test.ts`.

## Guides

No guide change: the API tools are described to Claude by the connector itself; no screen changed.
