# A pay link paid in full confirms the booking

Booking CC-10053 was waiting for payment (offer approved, agreement signed). Staff texted a pay link for "Everything
open"; the renter paid it, every part was then $0 open and the card was saved, but the booking stayed "Waiting for
payment" and the Money tab still asked to confirm it. The confirmation after a pay link only looked at a payment of the
rental or of the fees, never of the balance, and the history called the payment "later charges".

Now (migration 0260) any payment that leaves nothing open for the rental and the fees on a booking waiting for payment
with its offer approved runs the same confirmation as the renter's pay page, once: the car checked free, the booking
confirmed, CarmaCars countersigns the signed agreement, the confirmation messages and the calendar follow. It runs after
a pay link (Everything open, the rental or the fees) and after a charge of the saved card for the booking. The payment
counts for the booking total, and its history line says "for the booking (everything open)". A booking already stuck
this way (paid in full by a pay link in the last days) is confirmed when the migration runs, with its confirmation
messages.

## Guides

No guide change: staff send the pay link as before; the booking now moves on by itself once it is paid.
