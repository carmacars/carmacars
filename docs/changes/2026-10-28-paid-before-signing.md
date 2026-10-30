# Paid before the renter signs (migration 0185)

A renter accepted an offer online and left the pay page. At the office, staff took the rental in cash and planned a
card deposit hold at pickup. Two things went wrong on the booking page:

- **Record a payment, "The rental and fees", Cash, amount empty** recorded only the rental part. The fees part failed
  with "CarmaCars countersigns once the amount due at booking is paid".
  - "Both" was two separate calls from the browser, so the second could fail after the first was saved. It is now one
    call: the rental part and the fees part are recorded in one transaction, or neither is.
  - Paying the last of the amount due confirms the booking, and confirming countersigns the rental agreement. The
    countersignature looked for one payment of the whole amount due (the website's card payment). Parts recorded
    another way now count once nothing is open for the rental and the fees.
  - Recording a payment no longer fails because the confirmation after it fails. The payment is kept and the answer
    says why the booking is not confirmed yet.
- **Paid before signing.** A booking paid in full another way is confirmed even when the renter has not signed. It is
  marked as waiting for the renter's signature. The renter can then sign in person on a staff member's device, online
  from their booking, or on paper. CarmaCars countersigns right after they sign, and the signed copy is queued. A
  booking paid another way is confirmed without a saved card; a card deposit is still taken before the car is released.
- **The car is not released without the signature.** Check-out (on rent) of a booking confirmed before signing is
  refused until its agreement is completed. The handover's ready check shows "awaiting signature".
- **The "Check-out, check-in and signing" card** was empty on a booking waiting for payment. It now offers **Sign now
  on this device** whenever the agreement waits for a signature or has not been made yet. This applies to bookings
  waiting for payment, confirmed or on rent, for an Admin and for the staff who may hand over (Fleet, Sales, Customer
  service, field staff). When there is no button, the card says where the agreement stands. If it has nothing to show,
  the card is not shown.

## Guides
No guide change: the screens keep their steps (Record a payment, Sign now on this device); the guide upkeep job
refreshes the sentence on offers paid another way ("approved and signed") after the deploy.
