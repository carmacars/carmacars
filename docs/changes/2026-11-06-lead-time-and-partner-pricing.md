# Lead-time pricing, and 01 Motors on our own pricing (0360 to 0362)

The owner: "cars booked ahead of time should be slightly cheaper than booking last minute, there should be a premium
for booking last minute. these dynamic pricing things should be implemented" and "remove the 10% markup on 01 motors
cars, we get a 20% kickback but we keep 100% of the fees and taxes we get to charge so instead of the current rules for
markups and kickbacks, keep their rates stored and apply a 10% discount on all of their rates into our system but
record that we get a 20% kickback from the listed rates they gave us. And then have all of our pricing rules apply to
their vehicles, such as the dynamic pricing i said earlier in this message and all of the fees".

## 1. Lead-time pricing (0360)

- **The tiers, in Program settings** (`lead_time_tiers`, each `{from_hours, bps}`, the first from 0 hours): a pickup
  under 24 hours away +15%, 24 to 72 hours +10%, 3 to 13 days 0%, 14 days or more −5%. `lead_time_enabled` turns it
  off for every car (on by default). `lead_time_insurer` (off by default): a booking billed to an insurer is not
  adjusted. The table is checked in the database (`app.lead_time_tiers_ok`: 1 to 8 tiers, the first from 0, rising
  hours, −50% to +50%) and on the screen.
- **Per car** (`vehicles.lead_time_mode`): Program settings, off for this car, or its own tiers (`lead_time_tiers`).
- **How far ahead**: from the moment of the quote or the request to the pickup, on Toronto clocks
  (`app.lead_time_hours`): a pickup at 10:00 two weeks later is 336 hours ahead whether or not the clocks changed in
  between. A pickup already passed takes the first tier.
- **What it adjusts**: the rental charge only, before tax, as one line of its own (`fee_types` `lead_time`, owner
  revenue and taxed like the rental charge, sorted right after it): "Short-notice pricing +10%" or "Booked ahead −5%"
  (a minus sign). Never the fees, the deposit, add-ons or the Protection Plan.
- **Where it shows**: the quote (`app.price_quote`, so the car page estimate and the request), the cars list once dates
  are chosen (`app.search_available` returns the rental charge with it), the offer and the booking's price lines.
  "From $X a day" and the rate tables stay at the base rate.
- **Locked**: a request (status requested, not an Owner Booking or a placeholder) locks the tier of the moment it is
  made on the booking (`bookings.lead_time_bps`, `lead_time_hours`, `lead_time_locked_at`, `lead_time_source`). The
  offer, a change of dates, a moved car and the payment keep that percentage; the tiers changing later do not move it.
  Extensions are priced from the rates as before, without an adjustment.
- **Staff override it**: on the review screen (More options, "Lead-time pricing (%)": a number, 0 for none, or empty
  for the tier of the request), which also edits an offer that is out in place (`app.admin_apply_booking_edit` takes
  `lead_time: {bps}` or `{auto: true}`; `app.booking_lead_time_set` for a request). A price typed by hand (custom price,
  plus tax or tax included) replaces it. Rentals added by hand are priced by staff and are not adjusted
  (`app.manual_rental_quote_0058` asks the quote for none).
- **Interactions**:
  - The weekend rule (0271) is on the rate card; the percentage applies to whatever the rates make, so a weekend day
    stays above a weekday.
  - The non-refundable discount (bookings made 7 days or more ahead, so only the 0% and −5% tiers meet it), a staff
    discount and a promo code are worked out on the rental charge from the rates, as before, and show beside the
    lead-time line. A negative adjustment never takes the rental below zero after them.
  - Owner revenue, staff commissions, the parts of a moved booking, the payments tied to the rental and a partner's
    split count the line with the rental charge (`app.commission_line_types`, `app.booking_split_parts`,
    `app.booking_line_allocation`, `app.booking_part_open_raw`, `app.booking_tie_lines_raw`, `app.sync_booking_price`,
    `app.preview_booking_change`), as they count the discounts.
  - Insurer-billed bookings: not adjusted unless `lead_time_insurer` is on.
  - It is never a fee of its own on the site, a fee term, or a fee staff set by hand.
- **Admin**: Settings > Program settings > Lead-time pricing (the switch, the tiers as a small table with what each does
  to a $500 rental, the insurer switch). Vehicles > the car > Rates > Lead-time pricing for this car. Door action
  `vehicle_lead_time` (Admin) and `booking_lead_time` (staff).

## 2. 01 Motors on our own pricing (0361)

- **Listed rates stay as given** (`partner_rates`).
- **Our selling base rate = listed × (1 − partner discount)**, to the nearest dollar (`app.partner_selling_cents`). The
  discount is Program settings `partner_discount_bps` (10%), per partner `partners.discount_bps`, per car
  `vehicles.partner_discount_bps`. The markup is gone (`partners.markup_bps` and `vehicles.partner_markup_bps` emptied;
  `program_settings.partner_markup_bps` is no longer used by the cars; the chauffeur service keeps its own markup).
- **Then every rule of our own cars**: the weekend rule (the sheet has no weekend rate, so the discounted weekend is the
  discounted daily rate and our rule gives daily + 15%, up to the dollar), lead-time pricing, every fee (delivery,
  young driver, additional driver, add-ons, admin fees), the deposit, HST, promo codes and the non-refundable discount.
- **The partner's money**: the listed rental is the listed rates times the booked days (the 1-2 / 3+ / 7+ tiers, before
  our discount; `bookings.partner_sheet_rental_cents`). CarmaCars receives a kickback of 20% of it (the partner's
  `commission_bps`, now the kickback; per car `vehicles.commission_bps`); the partner is owed the rest. Our lead-time
  adjustment, our discount and any discount CarmaCars gives do not change it; a refund lowers it in proportion.
  Kilometre overage, every fee and the taxes are CarmaCars' own, 100%.
- **The books**: `booking_splits.partner_sheet_cents` (the listed rental), `partner_kickback_cents` (the receivable,
  equal to `company_share_cents`), `owner_payout_cents` (payable to the partner), `partner_markup_cents` (CarmaCars'
  part of the rental: our rental charge less the listed rental, negative when we sell below it, plus the overage).
- **Statements**: the partner's statement shows each rental "at your listed rate $675.00, less the 20% kickback to
  CarmaCars ($135.00), payable to you $540.00", never our price. Admin > Partners > the partner: Pricing (our base rate,
  fees and taxes, the kickback, the payable), the cars (listed and our rates, discount and kickback), and **Kickback and
  payable** (each rental's listed rental, kickback receivable, payable and our rental charge, with the totals not on a
  statement yet).
- **The partner agreement** (`web/src/features/partner/agreement.ts`, now `partner-v4-2026-11-06`): sections 1, 3 and 4
  on the partner_rate basis describe this model (our price from the listed rate less the discount under our own
  rules; the kickback of the listed rental; the partner paid its listed rental less the kickback; fees, overage and taxes
  ours). `app.partner_agreement_facts` carries `discount_bps`. 01 Motors has not signed an agreement yet; have the new
  sections reviewed before it does.

### The migration of the data

- 01 Motors: markup removed, discount 10% (Program settings' value) in its place, kickback 20% kept.
- Every partner car's rate card is made again from its listed rates (`app.partner_rates_apply`); bookings keep the
  rates they were made with.
- Requests not yet offered (requested, tentative) on a partner car are priced again on the new rates and basis (a price
  typed by hand stays). Offers out and confirmed bookings keep their locked prices and are paid as before: a booking
  that still carries `partner_markup_bps` keeps 0093's split (the overage shared). Bookings made before 0360 have no
  lead-time adjustment.

### The money, worked

Mercedes-Benz C-Class C43 AMG (Blue): listed $250 / $225 / $200 a day. Our base rates: $225 daily, $259 weekend
(daily + 15%, to the dollar), $203 a day for 3 to 6 days ($202.50 up), $180 a day for 7 or more. Rented Sunday to
Wednesday (3 days), requested 21 days ahead, delivered 20 km:

| The renter pays | Amount |
| --- | --- |
| Rental charge, 3 days at the 3+ day rate (3 x $203) | $609.00 |
| Booked ahead −5% | −$30.45 |
| Delivery | $75.00 |
| Subtotal | $653.55 |
| HST 13% | $84.96 |
| Total | $738.51 |
| Deposit (a hold, returned) | $2,500.00 |

| Where it goes | Amount |
| --- | --- |
| Listed rental (3 x $225, the partner's rates for these days) | $675.00 |
| Kickback receivable from the partner (20% of $675) | $135.00 |
| Payable to the partner ($675 less the kickback; the statement nets the two) | $540.00 |
| CarmaCars' part of the rental ($578.55 less $540) | $38.55 |
| Delivery and any other fee: CarmaCars' own | $75.00 |
| HST: collected and remitted by CarmaCars | $84.96 |
| CarmaCars keeps before tax ($38.55 + $75.00) | $113.55 |

The same 3 days requested 2 days ahead: the rental is $609.00 + $60.90 (short-notice +10%) = $669.90, the partner is
still owed $540.00, and CarmaCars' part of the rental is $129.90. Before this change (0093's markup) the renter paid
$744.00 for the rental, the partner was owed the same $540.00 and CarmaCars kept $204.00.

## Tests

- DB: `supabase/tests/99_lead_time_partner_pricing.sql` (53 assertions): each tier and its boundaries (23.99, 24, 71.99,
  72, 335.99, 336 hours, a pickup passed), Toronto clocks across both changes of the clocks, the table check, the quote
  (the rental only, one line after the rental charge, HST, the deposit), the non-refundable discount and a promo code
  beside it, off globally and per car, a car's own tiers, the lock on the request and the offer (the tiers changed
  after), staff overrides through the offer edited in place and back to the tier, a renter refused, a price typed by
  hand replacing it, insurer bookings (off and on), Owner Bookings, owner revenue and commissions; 01 Motors: listed
  rates kept, base 90% of listed to the dollar, the weekend rule on every partner car, the quote with the lead-time
  line, the delivery and young driver fees and HST, the non-refundable discount, the fleet cards, a booking's listed
  rental, kickback, discount and lock, its split (rental $578.55, listed $675, kickback $135, payable $540), its
  statement line, Admin's partner page, the partner's and a car's own discount, and a booking made on the markup
  keeping 0093's split. `61_01_motors_partner.sql` and `73_partner_rate_agreement.sql` follow the new rates and words.
  The earlier suites run with lead-time pricing off (`helpers.sql`, as for the other switches that are on by default).
- Unit: `web/src/features/rates/lead-time.test.ts` (the tiers in words, the boundaries, the table typed),
  `web/src/features/partner/fleet-01-motors.test.ts` (our price from the listed rate, the weekend rule, the kickback).
- End to end: `web/tests/e2e/lead-time.spec.ts` at 375 and 1440 (the car page estimate shows "Short-notice pricing +10%"
  two days ahead and "Booked ahead −5%" twenty days ahead, right after the rental charge; a 01 Motors car at 90% of its
  listed rate); `partner-01-motors.spec.ts` follows the new rates.

## Guides

- `admin/settings` (Lead-time pricing: the switch, the tiers, insurer bookings, what it touches)
- `admin/fleet-and-listings` (a car's own lead-time pricing on the Rates tab)
- `admin/requests-offers-and-bookings` (the adjustment on a request and how staff change it)
- `admin/partners-company-cars-and-rentals-added-by-hand` (A partner fleet on its own rates: the listed rates, the
  discount, our rules, the kickback and the payable, with the worked example)

## Notes

- Mileage overage on a partner car is now CarmaCars' (the owner: "we keep 100% of the fees"); 0093 shared it with the
  partner. Change `app.compute_booking_split_pre0156` if the partner should share it again.
- The chauffeur service keeps its hourly markup on the partner's rates (it is not a rental and has no lead-time tiers).
- `program_settings.partner_markup_bps` and the markup columns stay for the bookings made before; nothing new reads them
  for a car.
