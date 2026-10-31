# Card payments: no extended authorization request (hotfix)

- Renters paying for a booking saw "This account is not eligible for the requested card features" and could not pay.
  The booking payment and staff card holds asked Stripe for an extended authorization ("if available"), which this
  Stripe account is not eligible for. They no longer ask; the usual hold is placed and the platform renews it before it
  lapses, as before.
- The booking payment's idempotency key has a new suffix, so a renter who saw the error gets a fresh payment form at once
  (an old form opened with the refused option is left to expire; nothing was charged on it).

## Guides
No guide change: no screen or step is different; renters can pay again.
