# Renter sent an e-Transfer, checked by Finance (Release 49: 3610, 3611)

Migrations `3610_r49et_etransfer_reports.sql` and `3611_r49et_guides.sql`. The owner (Nov 24): Sales cannot record an e-Transfer a renter sent (only Finance or an Admin records payments, and that is correct), so they had to message him.

## What it does

- **Sales** (staff portal, a booking waiting for payment, Money tab): **Renter sent an e-Transfer** with the amount, what it covers (**The rental and fees**, **The deposit** or **Both**), the sender's name (optional) and a screenshot or PDF (required, checked by its first bytes, 10 MB at most, kept private in `documents/etransfer/<booking>/`). **Send to Finance** makes a Check e-Transfer item (`etransfer_reports`, `ET-1001`...) and changes no money. One open report per booking (a unique index; a second is refused). The booking shows **e-Transfer reported, waiting for Finance** (header chip, overview line, Money card) for every role.
- **Finance and the Admins**: the notice `staff_etransfer_reported` (email, in-app, push topic alerts) and a To do `etransfer_check` (Finance's queue, and the Admins' when someone holds Finance; it opens the booking's Money tab). The card shows the screenshot and what **Confirm received** will record. **Confirm received** (one tap; optional **Bank reference (optional)**, else the report number) records it through the door's `record_booking_payment` with method `e_transfer`, the same path as Record a payment: the single limit, the deposit by e-Transfer (3052), the reference rules and the confirmation of a booking waiting for payment all apply; it is all or nothing. Both: the deposit part is the deposit still owed by e-Transfer and the rest the rental and fees (the connector may give `deposit_cents`); a report that cannot be split, or whose rental is already paid, is refused with the reason (send it back). The screenshot becomes each payment's proof. **Not received** (with the reason, 5 characters or more) records nothing. Either closes the To dos and tells the rep (`staff_etransfer_confirmed`, `staff_etransfer_declined`: email, in-app, push topic bookings, at the rep's own address only).
- **Rules**: Sales never records money (the report function writes no payment; only `app.user_runs_finance` decides); the rep never checks their own report unless an Admin; a decided report is not decided again; every report and decision has an audit row (and the table's row trigger) and a line in the booking's history.
- **Admin portal**: Today shows the To do with **Confirm received**, **Not received** and **See the screenshot**; the booking's Money tab has the same card as Finance.
- **Connector**: `etransfer_check` (admin:write): `report` (ET-...) or `booking`, `decision` received or not_received, `reason`, `reference`, `received_on`, `deposit_cents`. The preview says what would be recorded (or why not) and changes nothing; the confirm runs `app.etransfer_decide` as the key's Admin.
- **Security**: every function is security definer with `search_path = public, app, pg_temp` and is executed by the server role only (revoked from public, anon and authenticated). The table is read only (row-level security: Admins, Finance, Sales); nothing writes it but these functions. The proof opens for Finance, Sales and the Admins only (`etransfer_proof` on `/staff/documents/<id>`).
- Also: `web/src/lib/db/types.ts` is regenerated from the schema (it had fallen behind r49's finance, gift card and notice tables).

## Tests

- DB: `supabase/tests/99_r49_etransfer_reports.sql` (47 assertions): who may report and decide, no money from a report, one open per booking, the To dos, the notices and their recipients, decline, the single limit, confirm (payments, proof, confirmation), both (rental and the doubled deposit), the connector's preview and confirm, privileges and `pg_temp`. `07_notifications`, `71_text_alerts` and `99_push_alerts` count the three new notices.
- Unit: `web/src/features/money/etransfer.test.ts`, `web/src/features/api-access/tools.test.ts` (etransfer_check).
- Generators: `supabase/seed/3610_gen_catalogue.mjs`, `supabase/seed/3611_gen_guides.mjs` (`--check`). Map: `scripts/notification-map.json` (three events).

## What's new

- For staff (Sales): **Renter sent an e-Transfer** on a booking waiting for payment: the amount, what it covers and the screenshot go to Finance; nothing is marked paid until they confirm it.
- For staff (Finance) and admins: **Check e-Transfer**: an alert and a To do; **Confirm received** records it and confirms the booking, **Not received** sends it back to the rep with the reason.

## Guides

- `va/sales`: Renter sent an e-Transfer.
- `va/finance`: Check e-Transfer.
- `admin/requests-offers-and-bookings`: Check e-Transfer on Today, and the connector.
