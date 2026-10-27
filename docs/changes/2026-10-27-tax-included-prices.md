# Amounts typed after tax (0175)

The owner: "It should be easier to put after-tax values without having to do that math." Staff entering a rental or an
offer often know what the renter paid with tax: "$270 after tax for the rental and $50 after tax for the Protection
Plan, $320 total cash". Until now every "Change it ($)" box took the amount before HST, and only the rental charge had a
"Plus tax / Tax included" choice, under the table.

## What staff see
- **Add a rental** (Admin, VA, field staff), **Send an offer** and **Edit the offer** (and Adjust on a request) have one
  toggle at the top of the price: **Amounts I type: Before tax | After tax (HST included)**. It applies to every money
  line typed by hand: the rental charge (for the trip or a rate a day), the Protection Plan, young driver, delivery,
  pickup, additional driver, add-ons and charges of their own. A line without HST (its fee type's `hst_applies` off, or
  a charge of its own without + HST) is taken as typed. Switching converts what is already typed, so each box keeps
  meaning the same money. The choice is remembered on the device (`localStorage` key `cc-amounts-typed`; a private
  window falls back to Before tax) and kept with a draft.
- **Total the renter pays (after tax, $)**: typing a total works out the rental charge (tax included) so the total
  priced is exactly that, to the cent, the other lines kept as they are and the rounding put on the rental line. The
  line under it shows each line before tax, the HST and the total as the database priced them. A line that follows
  the rental charge (a non-refundable discount, a promo code) moves with it, so the screen takes a second step when
  needed (at most six). A total below the other lines says so.
- The old "The rental charge typed is: Plus tax / Tax included" select (and the "Tax" select on the offer screens) is
  replaced by the toggle: After tax sends the rental charge with `price_tax` `included` (0112), Before tax with `plus`.
- **The preview bug**: on Add a rental, "Total with your changes", the HST line and "Before you save" ignored a rental
  charge typed by hand (they kept the rate sheet's: $303.05 shown, $320.00 saved). The check now prices the rental
  charge typed, so the totals are the totals saved. A price on screen for an older entry is marked "updating".
- **The check**: when a total was typed (or lines typed after tax) and the total the database priced differs from it,
  the price and "Before you save" say "The total priced is $X: $Y more/less than the $Z typed." The confirmation after
  saving says so too.
- "Before you save" shows **No deposit** when No deposit is chosen (it said "Deposit $300.00 by no deposit"); the offer
  screens' price and the renter's view show it too.

## The arithmetic
- Before tax = round(after / (1 + rate)) to the cent, half away from zero, exactly `app.price_before_tax`; HST per line
  = round(before x rate), exactly `public.calc_hst`. The rate is always the settings' (`hst_bps` from the quote or the
  booking), never a constant in the code.
- What is sent is unchanged in kind: fee lines before tax (`line_overrides`, `custom_fees`), the rental charge with
  `price_tax` `plus` or `included` (0112: the database keeps the amount before tax and records the rest as HST, so that
  line is exactly the amount typed). A fee line typed after tax can land a cent away once its own HST is rounded ($1.00
  is $0.88 + $0.11); that cent goes on the rental charge when it is typed too, so the total is still what was typed.
- `web/src/features/sales/taxIncluded.ts` holds the pure functions (screens, assistant and tests share them);
  `TaxModeToggle.tsx` the toggle and the remembered choice.

## Staff assistant
- `create_offer` and `add_rental` take `rental_total`, `tax_included` ("$270 after tax"), `plan_price` (the Protection
  Plan for the trip) and `total_after_tax` ("$320 total after tax"; not with `rental_total`). After tax, the plan is
  worked back to before tax and the rental charge goes tax included; a total is solved the same way as on the screen,
  through the offer preview, and the card shows the price as it will be saved, "Total said" or "Amounts said", and a
  "Check" row if the total priced differs. Amounts typed as text ("$320") are accepted.

## How it works
- Migration `0175_tax_included_prices.sql` (SCHEMA_MARKER `0175`), no table change: `app.price_lines` also returns
  `rate_sheet_rental_cents`; `app.price_quote` takes the staff-only options `staff_rental_charge_cents`,
  `staff_price_tax` and `staff_rental_with_tax_cents` (honoured only in a staff session, `app.staff_pricing`, like the
  fee lines of 0132) and prices them as the booking's own rental charge; Add a rental's check
  (`app.manual_rental_quote_pre0132`, 0112's layer, and `app.manual_rental_quote_0058`) passes the rental charge typed
  with its choice, and its `rate_sheet_cents` stays the rate sheet's.
- Send an offer and Edit the offer were already priced by a rolled-back booking (their totals were right); they get the
  toggle, the total and the conversions.

## Tests
- `supabase/tests/99_tax_included_prices.sql` (new): $270 tax included + a $44.25 plan = $320.00 in the check and in
  the booking saved; plus tax; a non-refundable discount follows the rental charge typed in the check as in the booking;
  nothing typed; a visitor's quote ignores the staff-only options. The whole SQL suite passes (one time-of-day
  assertion in 99_promo_expiry failed locally after midnight UTC, unrelated).
- Unit: `taxIncluded.test.ts` (rounding to the cent, $320 with a $50 plan after tax = 238.94 + 44.25 + 36.81, lines
  without HST, several lines and the cent left over, the back-solve with a discount that follows), `model.test.ts`
  (the offer payload after tax), `assistant.test.ts` (the arguments, "$270 after tax", "$320 total after tax").
- e2e: `supply-rentals.spec.ts`, "manual rental: amounts typed after tax, the total the renter pays, no deposit"
  (375 and 1440): After tax, 270 and 50, the total $320.00 before saving and saved; the choice remembered; a total of
  $400.00 typed and saved; No deposit in the summary. `staff-commissions.spec.ts` uses the toggle for its tax-included
  price.

## Guides
Not republished by a migration (0173 and 0174 are in flight on other branches; the last guides migration republishes
the final text). Republish these chapters with the next guides block:
- `admin/requests-offers-and-bookings`: Send an offer, Amounts I type and the Total the renter pays; Edit the offer the
  same.
- `admin/partners-company-cars-and-rentals-added-by-hand`: Add a rental, Check the price (after tax, the total, the
  check), Before you save with No deposit.
- `admin/assistant`: amounts said after tax and a total after tax.
- `va/customer-service`: Send an offer, Amounts I type and the total.
- `va/add-a-rental-by-hand`: after tax and the total on Add a rental.
- `va/assistant`: amounts said after tax.
