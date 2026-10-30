# Booking page: one "Next step", the other actions in a menu

The owner, October 30: staff were "not sure if it has become a booking or not… too many buttons".

- The Admin booking page and the staff booking page show **Next step** right under the booking number and status: one
  plain sentence of what happens next and who does it, and one button for that step when there is one.
  - Request: "Send the offer" (Sales or customer service); it says it is not a booking until the renter approves and pays.
  - Offered: waiting for the renter to approve, open until the date and time; no button.
  - Waiting for payment: the amount still open; "Record a payment or send a pay link" (the Money tab).
  - Booked, agreement not signed: the renter signs; "Sign on this device".
  - Booked and signed, deposit not taken, pickup ahead: take the deposit hold at the pickup.
  - Pickup day: "Check out the car" (and the deposit hold when it is not taken yet).
  - On the road: the return time; "Check in the car" (late returns say so).
  - Returned: Finance issues the final statement and settles the deposit.
  - Closed, cancelled, declined, expired: nothing to do (an expired offer says how to reopen it).
- On the staff page the button shows only to the function that does that step (for example "Settle the deposit" for
  Finance); everyone sees the sentence.
- The row of header buttons (Edit the offer, Withdraw the offer, Send again, Renter approved by phone, Reopen, Stop
  blocking the calendar, Cancel for the renter, Cancel by CarmaCars, Swap vehicle, Draft insurer invoice, Issue final
  statement, Ask the renter, Decline, Schedule a field job, Email the adjuster) is now one **More actions** menu
  (keyboard: Tab to it, Enter or Space opens it). **Email the renter** stays beside it. Every button keeps its test id.
- The sentence comes from `web/src/features/admin/next-step.ts` (unit tests for each status path in
  `next-step.test.ts`); the panel and the menu are `web/src/features/admin/NextStep.tsx`. The end-to-end test that
  edits an offer opens the menu first (`offers-and-rentals.spec.ts`).

## Guides
Admin guide ("A booking", "Change an offer that is out") and staff guide (offers changed in place): Next step and the
More actions menu. Changed in `docs/guides/src/guides/admin.py`, `va.py`, `docs/guides/content/admin.json`,
`va.json` and `docs/guides/src/admin.html`, `va.html` by hand (export.py needs the screenshots; the screenshots and
PDFs refresh on the next guides run).
