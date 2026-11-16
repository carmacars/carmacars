# A payment covers every line; the deposit by how it is paid; top-ups, overpaid deposits, deposit changes and voids; CC-10478 (Release 48 part 2: 3051, 3052, 3054)

Migrations `3051_r48_payment_allocation.sql`, `3052_r48_deposit_by_method.sql`, `3054_r48_cc10478_repair.sql`.

## What was wrong (found live on CC-10478)

- A payment of the whole total ($186.73, HST included) recorded for "the rental" paid the rental and short-notice lines only. The young driver fee and the Protection Plan (the fees part) stayed open: the booking showed $115.26 open, stayed waiting for payment and blocked the pickup.
- Changing the deposit (`change_booking` deposit_cents 30000 to 60000) left the Money tab's deposit card and **Collect $X deposit** at $300.
- Voiding a deposit recorded by hand showed **Not collected** on the Money tab, but `record_payment` said "already been taken", **Record the deposit** did nothing and the header still said "Deposit collected $300". The deposit record stayed collected in the database.

## What changed

- **Every line up to the total** (`app.booking_part_open_raw`): what is paid past one part (the rental or the fees) pays the other, so a payment covers every line whichever part it was recorded for. After a payment of the rental, the fees or both, every line of a part paid in full is tied to it, and a booking waiting for payment with nothing open is confirmed (`app.record_booking_payment`). The bookings already stuck that way are repaired by the migration (`app.repair_payment_allocation`: lines tied, confirmed when waiting for payment).
- **The deposit by how it is paid** (`app.deposit_for_method`, the one rule): a credit card hold is the deposit; e-Transfer and cash are the deposit times `program_settings.offline_deposit_multiplier` (2, on by default with `offline_deposit_double`); a debit or prepaid card keeps its multiplier (0262). An amount set for the booking (`bookings.debit_deposit_cents`) wins for every way but a credit card. `record_payment`, the connector, the Admin and staff Money tabs (`deposit_state`), the renter's offer and pay page (`server_booking_deposit_options`) read it. The debit deposit's card processing fee stays a separate, named, non-refundable amount (0750).
- **Top-ups and overpaid deposits** (`app.record_offline_deposit`): `covers=deposit` with no amount takes what is still owed; an amount below records a part (the Money tab says **under, still owed $X** and offers **Collect the $X still owed**); an amount above is held and given back with the deposit (**over, to return $X**: `deposits.amount_cents` is all that was taken). The same e-Transfer reference twice is one deposit.
- **A deposit raised while waiting for payment**: Edit booking and the connector's `change_booking` with only `changes.deposit_cents` change it at once (an Admin, with the reason), with no need to reopen the offer (`app.booking_deposit_raise`).
- **A deposit change reaches every record** (trigger `bookings_deposit_follow`): the deposit not taken yet, the deposit owed at pickup (`deposit_pendings`) and the open deposit links.
- **A void resets what the payment paid** (`app.void_manual_payment`): voiding a deposit puts the deposit back to not taken (or to what is left of it), with a "voided" line in the deposit history; voiding a rental payment unties the lines it paid. Deposits left "collected" by an earlier void are reset by the migration.
- **CC-10478** (`app.repair_cc10478`, runs once and again without change): the $800.00 e-Transfer C1AqmwK7G9Hu of November 15 is recorded as $186.73 for the booking (every line now paid, nothing open), $600.00 deposit by e-Transfer (its deposit by e-Transfer set to the $600 agreed, so it is not doubled again) and a $13.27 tip. The booking stays on rent.

## Tests

- `supabase/tests/99_r48_money_fixes.sql`: the whole total recorded for the rental pays the fee lines and confirms; a part then the rest; a stuck booking repaired (and the repair again changes nothing); the deposit by method and the Program setting; a top-up, an amount over the deposit; a deposit change on a confirmed booking and while waiting for payment (an Admin only); a void then record again; CC-10478 repaired twice to the same state.
- Unit: `web/src/features/money/deposit-state.test.ts`, `money-panels.test.ts` (a tip is not rental money).

## Guides

- `admin/requests-offers-and-bookings`: payments by e-Transfer or cash, the doubled deposit, top-ups and overpaid deposits, deposit changes, voids.
- `admin/settings`: the deposit multiplier for e-Transfer or cash.
- `va/finance`: the same on the staff Money tab.
- `renter/sign-and-pay`: the deposit by e-Transfer, cash or debit.
