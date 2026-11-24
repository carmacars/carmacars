# Hotfix: booking and paying with no card processor (3650)

Migration `3650_hotfix_card_off.sql`. The owner (Nov 24): Stripe closed the account (`charges_enabled` and `payouts_enabled` false). Every card form, pay link, deposit hold and Collect a card failed, and renters could not book.

## What it does

- **One switch.** Program settings **Card payments** (`card_payments`, on by default) and **Card processor** (`card_provider`: `stripe`, or `helcim` once its adapter is in). Cards are on only when the switch is on **and** the processor takes charges. `app.card_payments_state()` is the one answer (`provider` is `stripe`, `helcim` or `off`, with `reason` `setting` or `processor`). The site reads it through `web/src/server/card-provider.ts`, the seam Helcim slots into.
- **Auto-detect.** The deposit guard (every 10 minutes once a processor has reported; `server_jobs_due` makes it due) reads Stripe's `/v1/account`. Stripe's `account.updated` webhook and a refused payment start do the same. `charges_enabled=false` turns cards off. The first report alerts the Admins once: the `admin_card_payments_paused` email, in-app and push notice, plus an urgent To do. When charges work again, the To do closes and a later pause alerts again. The processor's state is in `card_processor_state`. Admin > Settings > Program settings shows it at the top.
- **Renter, cards off.** On Sign and pay, the payment box is the e-Transfer box. It shows the company e-Transfer email (`e_transfer_email`, else the public email), the booking number as the message and the exact rental and deposit, each copied with one tap. The renter uploads the screenshot (JPG, PNG or PDF, 10 MB, checked by its first bytes), and it becomes the same **Check e-Transfer** item as Sales' (3610, `app.etransfer_report_renter`). Finance or an Admin confirms it in one tap through `record_booking_payment` (method `e_transfer`). The renter is emailed `renter_etransfer_confirmed` or `renter_etransfer_declined` with the reason and may upload again.
- **Pay links, the offer and the booking page.** A pay link shows the e-Transfer details (the upload is on the booking, where the renter is signed in). A link to save a card says no card is needed. The offer shows the deposit by e-Transfer or cash and how to pay. A confirmed or on-rent booking with the deposit owed shows the same box. A balance says to e-Transfer instead of the card button.
- **Deposit.** A deposit still to take by card becomes an e-Transfer deposit (`deposit_pay_method` `e_transfer`, the amount from `app.deposit_for_method`, so the offline multiplier applies), refunded by e-Transfer as 3052 does. A cash deposit stays cash, and cash at pickup is still offered.
- **Nothing waits on a card.** "The card box always shows" (3420) is now "the payment box always shows". With cards off, a booking is confirmed without a saved card. The unpaid hold never lapses while an e-Transfer report waits for Finance. Tips, add-ons, extensions and gift cards say to pay by e-Transfer instead of failing at the processor.
- **Staff, cards off.** The door refuses `payreq_create` (Collect a card, card links, the reader), `card_charge_begin`, `deposit_hold_saved_begin`, `hold_reauth_begin` and `extension_charge_begin` with "Card payments are paused". `booking_money` carries `card_payments`. The Money tab hides the card ways and shows **Card payments are paused** with the e-Transfer message to copy, for Sales, CS, Finance and the Admins alike. The field tools (Resolve deposit, Renter help) and the balance actions show the same note. Releasing an existing hold stays.
- **Connector.** `get_settings` returns `card_payments` (the state) beside the Program settings, which include `card_payments` and `card_provider`.
- **Security.** Every function is security definer with `search_path = public, app, pg_temp`, executed by the server role only (revoked from public, anon and authenticated). `card_processor_state` is read-only to Admins by row-level security and written only by `app.card_processor_report`. The renter's report checks the booking is theirs and the proof's path is under that booking.

## Not here

- Helcim itself (a separate helper). Its adapter goes behind `card-provider.ts` and `integrations/payments`; `card_provider = 'helcim'` then turns it on.

## Tests

- DB: `supabase/tests/99_hotfix_card_off.sql` covers the switch and the provider seam; the processor pause alerting once, ending and alerting again; the refused card calls; Money's state; the renter's state, report, refusals and proof path; the hold that never lapses; Finance's confirmation without a saved card; the decline told to the renter; get_settings; the notices through the pipeline; privileges and `pg_temp`. `07_notifications`, `71_text_alerts` and `99_push_alerts` count the three new notices.
- Unit: `web/src/features/money/card-pay.test.ts`.
- e2e: `web/tests/e2e/card-off.spec.ts` (Sign and pay with cards off: the e-Transfer box, the upload, Finance confirms; the staff note).
- Generator: `supabase/seed/3650_gen_catalogue.mjs` (`--check`). Map: `scripts/notification-map.json` (four events).

## Guides

No guide change in this hotfix: the e-Transfer box explains itself. The renter guide's card lines go to the next guides accuracy pass.
