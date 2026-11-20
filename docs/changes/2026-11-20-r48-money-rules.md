# Money rules: owner splits on the agreed terms, shareholders, extensions, deposits, speeding, connector fees (Release 48 part MR: 3100 to 3112)

Migrations `3100_r48mr_owner_split.sql`, `3101_r48mr_extensions_deposits.sql`, `3102_r48mr_speeding_named_fees.sql` (code) and
`3110_r48mr_terms_data.sql`, `3111_r48mr_statements_recompute.sql`, `3112_r48mr_cc10478_smoking.sql` (data, each runs once and again
without change). Schema marker 3112.

## What was wrong (owner reports of November 20, 2026)

- **Owner payouts ignored the agreed split.** The owner on a 40% management fee was paid at 30% on statement ST-1002 (144,798 of
  206,855). A booking kept the Revenue Share stamped the day it was booked (`bookings.company_share_bps`), so terms set or fixed
  later never reached it; and the connector's `change_owner_terms` refused to correct a car's terms from its start once a later
  term existed.
- **The referring owner's 10 points** (40% less the standard 30%) had no link set up, so he was paid nothing and could not see the
  referred owner's cars (0543 had the mechanism: `owner_referral_links`).
- **Shareholder cars** paid 90% of the rental only (ST-1008), not of the total collected with every fee.
- **Extensions** always credited the booking's salesperson, with no way to hand one over and no view of whether it was paid.
- **Debit deposits** could be turned on by an Admin only.
- **A $1,000 deposit hold on the card on file** (CC-10481, November 16) showed "That is already recorded (it may have been saved a
  moment ago) ... E-OKN1RH" and nothing happened. Stripe shows the first try at 18:50:46 declined for insufficient funds; the
  second tap made another staff hold request with channel `auto`, which the unique index `payment_requests_auto_hold_once` (0261,
  meant for the pickup-day job: one per booking) refused with a duplicate key. The friendly error layer turned that 23505 into the
  "already recorded" sentence.
- **`change_booking_fees`** refused every line shape for adding a smoking fee to a returned booking: the tool said `lines` is a
  list of objects; the database took only `{line key: cents}`.
- `get_owner` and `get_car` did not show a car's terms.

## What changed

### Owner splits (3100)

- **The term in force on each rental day.** The open part of a booking's split (not on an approved statement) takes the Revenue
  Share of each rental day (`app.vehicle_split_terms` of that day), averaged over its days (`app.split_day_share_bps`), on a program
  owner's car. A Revenue Share set for one booking, a flat monthly arrangement, a partner's listed rate and a booking left out of the
  owner's revenue keep their own rules. Wraps `app.compute_booking_split_pre2371` (`_pre3100`).
- **Shareholders** (an owner with `is_shareholder` or a car marked shareholder-owned): the shareholder keeps 90% (Program setting
  `shareholder_company_share_bps`, 10% to CarmaCars) of the total charged before tax: the rental, every fee (young driver, Protection
  Plan, delivery, late, km, fuel, cleaning, smoking, ...) and every amount kept from the deposit (incidentals, damage, tickets, fees
  billed from the deposit: these are charge lines paid from the deposit). HST is left out. The fees go in their own column
  (`booking_splits.shareholder_extra_cents`, in the Owner Revenue check). **Confirmed with the existing rules:** referral kickbacks and
  staff commissions are still taken off first as a booking expense (0058: `kickback_cents` carries both, on a program owner's car,
  shared by rental charge), unchanged. Claim money (deductible, loss of use) stays with claims.
- **A versioned correction of a car's terms** (`app.car_terms_correct`, Admin): from any date since the car's start, even before a
  later term. The periods from that date take the corrected values; the replaced ones are kept with the reason
  (`vehicle_terms_corrections`, audited). The owner signs an updated Vehicle Schedule only when the correction gives them less (a
  higher management fee or Fee); it confirms the corrected terms. Bookings not on an approved statement are worked out again.
  The connector's `change_owner_terms` takes `correction: true` (and `recompute_statements: true`).
- **Statements recomputed** (`app.owner_statement_recompute`, Admin): an approved statement not paid out is voided, built again on the
  corrected terms and approved again; its payout is replaced; an audit line (`audit_log` `owner_statement_recompute`) keeps the amounts
  before and after.
- **Connector reads**: `get_car` has `terms` (revenue_share_bps, insurance_fee_cents, tracker_fee_cents, effective_from, every
  period, shareholder, fees_paid_from, a correction awaiting signature, the referral); `get_owner` has each car's terms and the
  owner's referral links.
- **The terms audit**: `owner_terms_agreed` holds the agreed terms; `app.owner_terms_audit()` lists every program owner's car against
  them; `web/scripts/owner-terms-audit.mjs` prints it (`--fix --admin <id>` runs `app.owner_terms_audit_fix`).

### Extensions, deposits (3101)

- **Who handles an extension** (`booking_extensions.handled_by`, `handled_queue`): the booking's salesperson by default; an Admin (or
  whoever handles it) gives it to another salesperson or to Admin with the reason, in the booking's history (`extension_assign`).
- **Commission on an extension goes to whoever handled it**: the booking's salesperson earns on the booking less the paid extensions
  handled by someone else; a salesperson who handled one earns on its rental difference, as their own commission line, at their
  rate and tier. Given to Admin: no commission (Customer service, Fleet and Finance never earn commission).
- **The money of an extension** on the booking's Money tab (Admin and the Sales portal): the amount, paid or waiting for payment, how
  (card and last 4, or the way received and its reference) and by whom, who handles it; **Charge the card on file**, **Record a
  payment** (e-Transfer with its reference, cash, cheque, bank transfer, another way) and **Give to**. An Admin, Finance, or the
  salesperson handling it (or the booking's salesperson).
- **Debit deposits**: a salesperson turns **Allow debit and prepaid cards for this booking** on (and off) on the Money tab; logged in
  the audit log and the booking's history.
- **The deposit hold tapped twice**: a staff hold request is channel `link` with `auto` false (as 2970's morning try); the unique index
  covers the pickup-day job only (`channel = 'auto' and auto`). A second tap within two minutes says "The deposit hold on the card on
  file is already being placed ... refresh the page to see the result"; a deposit already taken names its amount and how. After a
  decline a new tap tries again.
- **Deposits are kept 30 days** after the return before release: Program setting `deposit_toll_window_days` ("Days a deposit is kept
  after the return before it is released") is 30 by default (it was 7). Releasing sooner stays an Admin's decision with the reason
  (0155). It was a Program setting already, under another name; it is now labelled and documented.

### Speeding charges, named fees (3102)

- **Rental agreement 10.5 Speeding charges** and three Fee Schedule lines (a new text version, `rental-v3-638e11f8b3`; agreements
  already signed keep theirs, nobody signs again). Program settings `speeding_180_fee_cents` ($500), `speeding_220_fee_cents`
  ($1,000), `speeding_300_fee_cents` ($2,500), plus HST; fee types `speeding_180/220/300`. `app.speeding_charge_add` (Admin or Finance,
  ops_do `speeding_charge_add`): one charge per tracker reading above the limit, only with the tracker's evidence (a `tracker_points`
  reading within two minutes of the time given, or a tracker alert, of the booking's car during the rental), kept on the line. After
  the return it is billed like damage: on a statement, from the deposit first.
- **`change_booking_fees` adds named fees**: `lines: [{"op": "add", "fee": "smoking", "amount_cents": 30000, "note": "..."}]`
  (`action` for `op`; `fee_code`, `kind` or `code` for `fee`). Names: smoking, cleaning, cleaning_heavy, pet_cleaning, late, km, fuel,
  ticket, toll, damage (damage through Bill damage, with photos or a document). Amounts before HST; empty takes the standard amount.
  After the return: from the deposit first (at once when the Check-out statement is out, else on it). The object shape
  `{line key: cents or null}` works as before. The tool's description gives the exact shape.

### Data (3110 to 3112)

- **3110**: `owner_terms_agreed` from the owner's notes; every car of those owners corrected from its start where its management fee or
  Insurance Fee differs (draft monthly invoices of a corrected Insurance Fee are made again); costs out of earnings set to "take from
  the revenue statement" (`fees_paid_from = statement`); no Insurance Fee on shareholder cars; the owner referral link (10 points,
  sees the cars) from the start of the referred owner's cars; the audit after the fixes is kept in `audit_log` (`owner_terms_audit`,
  entity `release 48`). The referring owner's own management fee is not in the notes: left as it is, flagged by the audit.
- **3111**: every approved statement not paid out recomputed (referred owners before referrers); one whose amounts come out the same
  is left as it is.
- **3112**: CC-10478's $300 smoking fee (plus HST), billed from its $600 deposit.

| Owner (notes) | Management fee | Insurance a car a month | Costs from earnings |
| --- | --- | --- | --- |
| Referring owner (6484ba68) | not in the notes: unchanged, flagged | $284 | |
| GLA (95a30580), Civic (42fb4ec9) | 30% | $350 | |
| Jeep (9f112d3c) | 30% | $300 | |
| Beetle (86c12980) | 30% | $300 | yes |
| Outlander (c0f92065) | 30% | $350 | yes |
| 4390af3a (every car) | 30% | $300 | yes |
| 16f187b8 (Jetta S, Macan, CTS) | 40% (10 points to 6484ba68) | $350 | |
| Shareholders (47c906a8, 8f32cc8f) | 90/10 of everything charged | none | |

## Tests

- `supabase/tests/99_r48_money_rules.sql`: a statement uses the term in force on each rental day (5 days at 30%, 5 at 40%); a
  correction's refusals, preview, kept periods and the signature only when the owner gets less; the connector path with
  `correction`; get_car and get_owner terms; an approved statement recomputed (void, rebuilt, approved, payout replaced, audit line);
  the referral share; the shareholder's 90% of rental, fees and amounts kept, HST out; extensions: default handler, refusals, the
  commission moving with the handler and to nobody for Admin, the money view, a payment recorded by the salesperson; Sales allows a
  debit deposit (logged); the deposit hold tapped twice; 30 days; speeding charges (evidence, the limit, once per reading); named fees.
- Unit: `web/src/features/agreement/speeding.test.ts`.
- The data migrations were run on a copy with the same owner ids and made-up names: Max's approved statement went from a 70% to a 60%
  payout, the shareholder's from 90% of the rental to 90% of rental and fees, CC-10478 got its smoking fee, and a second run changed
  nothing.
