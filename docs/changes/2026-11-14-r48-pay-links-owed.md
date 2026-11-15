# A pay link asks for what is owed, never more (Release 48: 2921, 2923)

Migrations `2921_r48_pay_links_owed.sql` and `2923_r48_pay_link_sweep.sql`.

A renter paid the booking total; the total later changed and staff sent a pay link for the whole new total, so the renter paid twice. Another renter whose payment had gone through got a balance pay link with nothing owed.

Root causes (`app.payreq_create`):

- The amount came from the screen (typed, or read before the payment landed) and only had to be at most what was open for the part; for an Admin even that was not checked.
- A new link cancelled only the open links of the same part, so a rental link and a balance link could both be open and both be paid.
- Nothing cancelled an open link once a payment landed.

What changed:

- `app.booking_amount_owed(booking)`: the booking's total (the renter's share on an insurer's booking) less every succeeded payment of it, refunds counted back. A link for the rental, the fees or the balance (staff, the card reader, the renter's own Pay the balance, and a saved card charged for them) defaults to and is capped at what is owed. With nothing owed it is refused: a charge on top is a later charge, with its reason. After a total change the link is for the difference.
- A new link for the booking's money replaces every open one for the rental, the fees or the balance.
- When a payment of the booking lands, open links for more than is then owed are cancelled by themselves (with a line in the booking history), and the pay page checks the link again just before the card is captured: a cancelled or too large link is voided, nothing charged.
- The balance panel after a change sends no amount: the database uses what is owed at that moment.
- Once, at deploy (2923, `app.payreq_sweep_overpaying`): every open pay link for the rental, the fees or the balance whose booking owes nothing or less than the link is cancelled, with a line in the booking history and one in the audit log; deposit holds, saved-card links, later charges and extensions are left alone. A cancelled link cannot be paid: the pay page refuses it and its Stripe authorization is voided if anyone tries.
- Claude's connector: `cancel_pay_link {payment_intent}` (an Admin, previewed then confirmed) cancels one open pay link and its PaymentIntent at Stripe; no money moves; a paid link is refused (that is a refund).
- Tests: `supabase/tests/99_r48_pay_links.sql`, `web/src/features/api-access/tools.test.ts`.

## Guides

- `va/finance`: a pay link asks for what is owed, the difference after a change, none when paid in full, and an open link cancelled by itself when a payment lands
