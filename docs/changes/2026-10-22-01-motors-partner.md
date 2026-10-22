# A partner's whole fleet and the chauffeur service (October 22, 2026; migration 0093)

The owner: add the partner rental company 01 Motors' whole fleet and a chauffeur service to CarmaCars, from its price
sheet (a one-page PDF in two columns: rental rates for 1 to 2 days, 3 or more days and 7 or more days, and a chauffeur
price guide with a rate an hour for 2 hours and for 3 hours or more). "Guideline rates; final pricing may change after
insurance review (driver risk, vehicle, use)."

## What changed

- **The partner.** 01 Motors (0046's partner model: an owners row of kind partner) with no portal sign-in: staff manage
  its cars; add its email on the partner page and invite it later. Its payout basis is the new **partner rate**.
- **62 cars, published as requests.** Every row of both columns of the sheet (24 Mercedes-Benz, 13 BMW, 25 in the right
  column; the request said about 83, the sheet has 62 rental rows and 11 chauffeur rows). Make, model, trim and colour
  from the row's name in proper case (Mercedes C43 AMG Blue is Mercedes-Benz, C-Class, C43 AMG, Blue), with the body,
  seats, doors, drive and gearbox of the model. Each went through the add path every car takes: fleet number, car code,
  standard settings (0087), the listing with the plain copy and the AI copy queued, the eight studio stand-ins with the
  model's name, published at once. The data is in the migration (`app.partner_fleet_import_0093`), keyed by the
  partner and the sheet row's name, so a second run adds nothing and keeps negotiated rates.
- **No years, VINs or plates.** The sheet has none; nothing is invented. The year is the latest plausible model year,
  flagged approximate (`vehicles.year_approximate`): the car's name, its web address, its text facts, the stand-ins'
  alt text and the public row leave the year out, and the page says "Year confirmed when you book". An offer waits
  until staff confirm the year (Admin > Partners, Edit on the car). A partner car may wait for its plate and VIN
  (the check `vehicles_plate_or_vin` and the listing gate); add them before the first handover.
- **Pricing on the partner's rates.** Each car keeps its sheet rates (`partner_rates`, per day, editable in Admin).
  The renter's rate card is made from them: the sheet rate plus the markup (10% by default; Program settings
  `partner_markup_bps`, the partner's `markup_bps`, the car's `partner_markup_bps`), to the nearest dollar (the site's
  whole-dollar prices). The 1-2 day rate is the daily and weekend rate, the 3+ day rate the new multi-day rate, the 7+
  day rate a day the weekly (7 days) and monthly (30 days) rates.
- **A 3+ day tier in the pricing engine.** `public.calc_rental_charge` with 8 arguments (the multi-day rate):
  3 to 6 days at that rate a day, never above what the daily rates or the week would cost. `rate_cards` and `bookings`
  carry `multi_day_rate_cents`; every place a booking is priced passes it (the quote, the request, the extension, the
  change previews, the calendar, rentals added by hand, the staff rate sheet), and the price line reads "3 days at the
  3+ day rate". `bookings.rate_applied` may be `multi_day`.
- **Commission on the partner's rate.** 0046's split took CarmaCars' commission as a percentage of what the renter
  paid. On the partner-rate basis the booking keeps the sheet amount of its dates (`partner_sheet_rental_cents`), the
  cut and the markup; the split pays the partner the sheet amount (scaled by what the renter kept of the planned
  rental: a refund lowers it in proportion, a discount CarmaCars gives does not) less the cut, and records the markup
  as CarmaCars' own (`booking_splits.partner_markup_cents`; the check on Owner Revenue includes it). The partner's
  statement shows each rental at the sheet rate, the cut and the payout, never the renter's price.
- **Insurance included and no credit card needed** on 12 cars: the rental S580 (not the Maybach), S63 AMG, G63 AMG,
  GLS600 Maybach, M440i Gran Coupe, M4 Competition Black, Range Rover Autobiography, Ferrari California T, McLaren
  570S, Lamborghini Urus, Cadillac Escalade ESV, Bentley Bentayga. Per-car flags `vehicles.insurance_included` and
  `vehicles.no_credit_card`, editable in Admin. Insurance included: the request takes coverage option 4 ("insurance
  included with the car"), confirmed at once with its proof, so readiness and the handover pass; the renter cannot
  switch it; the wizard shows "Insurance included" instead of the coverage choice; the car page's coverage section and
  questions say so. No credit card needed: a debit card in the renter's name pays and holds the deposit (a prepaid card
  is still refused); the car page, the wizard's review and the pay page say so. The deposit, the licence, selfie and
  identity checks and the ages are unchanged (drivers 18 to 20 follow Program settings as on every car).
- **Car pages.** The badges "Insurance included: no personal auto policy needed" and "No credit card needed: debit
  accepted", the tiered rates (1 to 2 days, 3 to 6 days, 7 days or more), "Guideline rates; final price confirmed after
  review", the year note, the requirements rows, the coverage section and the questions; the fleet card says
  "Insurance included". The search title and description start from the lowest rate a day.
- **The chauffeur service.** 11 vehicles (`chauffeur_vehicles`): 5 chauffeur only, 6 also rentals, linked to their
  rental cars (the Range Rovers to all five Range Rover rows; the sheet's S680 has no rental row, so it links to none).
  The client pays the sheet's rate an hour plus the markup; exactly 2 hours at the 2-hour rate, 3 or more at the 3+
  hour rate for every hour, plus HST; the partner is owed the sheet amount less the cut. `/chauffeur` lists the
  vehicles and rates (JSON-LD Service with one Offer per vehicle and its hourly price specifications);
  `/chauffeur/request` is the request form (vehicle, date, start time, hours from 2, pickup and drop-off, passengers,
  occasion, notes, contact, a live estimate, the bot check). A request is a lead of kind `chauffeur` with its quote
  (`chauffeur_requests`, CH-1001 and up) and a customer service task. The car offer and payment flow is built around
  days, the agreement, the deposit and coverage, so it does not carry an hourly line: staff send the quote line and
  confirm in Admin > Chauffeur (Quoted, Confirm, Change, Completed, Decline or Cancel). To do has the line "Chauffeur
  requests to quote" and the card "Chauffeur today". The header menu and the footer link to `/chauffeur`; the sitemap
  lists it.
- **Admin.** Partners > 01 Motors: Pricing (markup, cut, basis), Cars (sheet and renter rates, Edit for the rates, the
  car's own markup or cut, the two flags, the model year), Chauffeur vehicles (rates, markup, cut, passengers, on the
  site). Replacing the stand-ins with real photos is the car page's Photos, as for every car.
- **Investor deck.** The slide "Partner fleets and chauffeur service" (growth): partner fleets listed on CarmaCars with
  a markup plus a cut of their rates, exotic and luxury cars from partners, the hourly chauffeur service; two screens
  from `web/scripts/deck-shots.mjs`. The partner is not named.
- `ESV` and `EXT` stay in capitals in car names (0087's rule, SQL and `web/src/features/vin/name-case.ts`).
- The local seed's sample cars ignore the imported fleet when it checks whether the site already has cars.

## The money, worked

Mercedes-Benz C-Class C43 AMG (Blue), sheet $250 / $225 / $200 a day, markup 10%, cut 20%, 3 days:

| | Amount |
| --- | --- |
| Renter's rate card | $275 (1-2 days), $248 (3+ days, $247.50 rounded up), $220 (7+ days) |
| Renter pays (3 days at the 3+ day rate) | $744.00 plus HST |
| Sheet amount (3 x $225) | $675.00 |
| CarmaCars' cut (20% of the sheet) | $135.00 |
| Partner is owed | $540.00 |
| Markup (renter's price less the sheet amount) | $69.00 |
| CarmaCars keeps (markup plus cut) | $204.00 |

## The parsed sheet

| # | Sheet row | Car | Sheet 1-2 / 3+ / 7+ | Renter 1-2 / 3+ / 7+ (a day) | Flags |
| --- | --- | --- | --- | --- | --- |
| 1 | Mercedes A220 | Mercedes-Benz A-Class A220 | $140 / $120 / $100 | $154 / $132 / $110 |  |
| 2 | Mercedes A35 AMG | Mercedes-Benz A-Class A35 AMG | $200 / $175 / $150 | $220 / $193 / $165 |  |
| 3 | Mercedes C300 Conv | Mercedes-Benz C-Class C300 Cabriolet | $200 / $175 / $140 | $220 / $193 / $154 |  |
| 4 | Mercedes C300 Sedan Black | Mercedes-Benz C-Class C300, Black | $200 / $175 / $150 | $220 / $193 / $165 |  |
| 5 | Mercedes C300 Sedan Grey | Mercedes-Benz C-Class C300, Grey | $175 / $150 / $150 | $193 / $165 / $165 |  |
| 6 | Mercedes C43 AMG Blue | Mercedes-Benz C-Class C43 AMG, Blue | $250 / $225 / $200 | $275 / $248 / $220 |  |
| 7 | Mercedes C43 AMG White | Mercedes-Benz C-Class C43 AMG, White | $250 / $225 / $200 | $275 / $248 / $220 |  |
| 8 | Mercedes C43 AMG Grey | Mercedes-Benz C-Class C43 AMG, Grey | $240 / $200 / $180 | $264 / $220 / $198 |  |
| 9 | Mercedes C63s AMG | Mercedes-Benz C-Class C63 S AMG | $400 / $375 / $325 | $440 / $413 / $358 |  |
| 10 | Mercedes E43 AMG | Mercedes-Benz E-Class E43 AMG | $250 / $225 / $200 | $275 / $248 / $220 |  |
| 11 | Mercedes E53 AMG Coupe | Mercedes-Benz E-Class E53 AMG Coupe | $350 / $300 / $275 | $385 / $330 / $303 |  |
| 12 | Mercedes GT53 AMG | Mercedes-Benz AMG GT GT53 4-Door Coupe | $420 / $375 / $350 | $462 / $413 / $385 |  |
| 13 | Mercedes S500 | Mercedes-Benz S-Class S500 | $450 / $400 / $325 | $495 / $440 / $358 |  |
| 14 | Mercedes S580 | Mercedes-Benz S-Class S580 | $600 / $575 / $550 | $660 / $633 / $605 | insurance included, no credit card |
| 15 | Mercedes S580 Maybach | Mercedes-Benz S-Class Maybach S580 | $450 / $400 / $325 | $495 / $440 / $358 |  |
| 16 | Mercedes S63 AMG | Mercedes-Benz S-Class S63 AMG | $700 / $650 / $600 | $770 / $715 / $660 | insurance included, no credit card |
| 17 | Mercedes GLB250 | Mercedes-Benz GLB GLB250 | $150 / $120 / $100 | $165 / $132 / $110 |  |
| 18 | Mercedes GLB35 AMG | Mercedes-Benz GLB GLB35 AMG | $200 / $175 / $150 | $220 / $193 / $165 |  |
| 19 | Mercedes GLC43 AMG SUV | Mercedes-Benz GLC GLC43 AMG | $225 / $200 / $180 | $248 / $220 / $198 |  |
| 20 | Mercedes GLC43 AMG Coupe | Mercedes-Benz GLC GLC43 AMG Coupe | $250 / $225 / $200 | $275 / $248 / $220 |  |
| 21 | Mercedes GLE53 AMG | Mercedes-Benz GLE GLE53 AMG | $350 / $325 / $300 | $385 / $358 / $330 |  |
| 22 | Mercedes GLE53 AMG Coupe | Mercedes-Benz GLE GLE53 AMG Coupe | $400 / $400 / $400 | $440 / $440 / $440 |  |
| 23 | Mercedes G63 AMG | Mercedes-Benz G-Class G63 AMG | $1,000 / $1,000 / $900 | $1,100 / $1,100 / $990 | insurance included, no credit card |
| 24 | Mercedes GLS600 Maybach | Mercedes-Benz GLS Maybach GLS600 | $1,500 / $1,200 / $1,000 | $1,650 / $1,320 / $1,100 | insurance included, no credit card |
| 25 | BMW 330i MSport | BMW 3 Series 330i M Sport | $200 / $175 / $120 | $220 / $193 / $132 |  |
| 26 | BMW M340i | BMW 3 Series M340i | $250 / $225 / $200 | $275 / $248 / $220 |  |
| 27 | BMW M3 Comp | BMW M3 Competition | $500 / $475 / $400 | $550 / $523 / $440 |  |
| 28 | BMW 430i MSport | BMW 4 Series 430i M Sport | $225 / $200 / $175 | $248 / $220 / $193 |  |
| 29 | BMW M440i | BMW 4 Series M440i | $250 / $225 / $200 | $275 / $248 / $220 |  |
| 30 | BMW M440i Gran Coupe | BMW 4 Series M440i Gran Coupe | $300 / $275 / $250 | $330 / $303 / $275 | insurance included, no credit card |
| 31 | BMW M4 Comp White | BMW M4 Competition, White | $475 / $450 / $375 | $523 / $495 / $413 |  |
| 32 | BMW M4 Comp Black | BMW M4 Competition, Black | $750 / $725 / $700 | $825 / $798 / $770 | insurance included, no credit card |
| 33 | BMW 530i MSport | BMW 5 Series 530i M Sport | $200 / $175 / $150 | $220 / $193 / $165 |  |
| 34 | BMW X3M Comp | BMW X3 M Competition | $350 / $325 / $300 | $385 / $358 / $330 |  |
| 35 | BMW X4M40i | BMW X4 M40i | $250 / $220 / $200 | $275 / $242 / $220 |  |
| 36 | BMW X5 MSport | BMW X5 M Sport | $225 / $200 / $175 | $248 / $220 / $193 |  |
| 37 | BMW X6M | BMW X6 M | $375 / $350 / $325 | $413 / $385 / $358 |  |
| 38 | Audi A5 Conv | Audi A5 Cabriolet | $200 / $175 / $150 | $220 / $193 / $165 |  |
| 39 | Audi S5 | Audi S5 | $230 / $200 / $200 | $253 / $220 / $220 |  |
| 40 | Audi R8 Spyder | Audi R8 Spyder | $1,000 / $900 / $900 | $1,100 / $990 / $990 |  |
| 41 | Porsche 718 Boxster | Porsche 718 Boxster | $400 / $375 / $325 | $440 / $413 / $358 |  |
| 42 | Porsche 911 Turbo S | Porsche 911 Turbo S | $2,000 / $2,000 / $1,900 | $2,200 / $2,200 / $2,090 |  |
| 43 | Porsche Macan S | Porsche Macan S | $250 / $225 / $200 | $275 / $248 / $220 |  |
| 44 | Porsche Cayenne | Porsche Cayenne | $275 / $250 / $225 | $303 / $275 / $248 |  |
| 45 | Range Rover Velar White | Land Rover Range Rover Velar, White | $220 / $200 / $175 | $242 / $220 / $193 |  |
| 46 | Range Rover Velar Blue | Land Rover Range Rover Velar, Blue | $250 / $220 / $200 | $275 / $242 / $220 |  |
| 47 | Range Rover Sport V6 | Land Rover Range Rover Sport V6 | $250 / $220 / $200 | $275 / $242 / $220 |  |
| 48 | Range Rover Sport V8 | Land Rover Range Rover Sport V8 | $300 / $275 / $250 | $330 / $303 / $275 |  |
| 49 | Range Rover Autobiography | Land Rover Range Rover Autobiography | $600 / $600 / $600 | $660 / $660 / $660 | insurance included, no credit card |
| 50 | Ferrari California T | Ferrari California T | $1,500 / $1,450 / $1,400 | $1,650 / $1,595 / $1,540 | insurance included, no credit card |
| 51 | Ferrari 488 Spider | Ferrari 488 Spider | $2,000 / $1,800 / $1,600 | $2,200 / $1,980 / $1,760 |  |
| 52 | Mclaren 570s | McLaren 570S | $1,500 / $1,450 / $1,400 | $1,650 / $1,595 / $1,540 | insurance included, no credit card |
| 53 | Lamborghini Urus | Lamborghini Urus | $2,000 / $1,800 / $1,600 | $2,200 / $1,980 / $1,760 | insurance included, no credit card |
| 54 | Corvette C8 Stingray | Chevrolet Corvette Stingray | $700 / $600 / $500 | $770 / $660 / $550 |  |
| 55 | Chevrolet Suburban | Chevrolet Suburban | $400 / $375 / $325 | $440 / $413 / $358 |  |
| 56 | Cadillac Escalade | Cadillac Escalade | $600 / $550 / $500 | $660 / $605 / $550 |  |
| 57 | Cadillac Escalade ESV | Cadillac Escalade ESV | $600 / $550 / $500 | $660 / $605 / $550 | insurance included, no credit card |
| 58 | Rolls Royce Ghost | Rolls-Royce Ghost | $1,000 / $900 / $800 | $1,100 / $990 / $880 |  |
| 59 | Bentley Bentayga | Bentley Bentayga | $1,200 / $1,100 / $1,000 | $1,320 / $1,210 / $1,100 | insurance included, no credit card |
| 60 | Ford Mustang Conv | Ford Mustang Convertible | $150 / $120 / $100 | $165 / $132 / $110 |  |
| 61 | Infiniti Q60 | Infiniti Q60 | $200 / $175 / $150 | $220 / $193 / $165 |  |
| 62 | Maserati Levante | Maserati Levante | $250 / $220 / $200 | $275 / $242 / $220 |  |

| Chauffeur vehicle | Kind | Sheet 2 h / 3+ h | Client 2 h / 3+ h (an hour) | Rental link |
| --- | --- | --- | --- | --- |
| Mercedes-Maybach GLS (Mercedes GLS Maybach) | chauffeur only | $350 / $300 | $385 / $330 |  |
| Mercedes-Benz S580 (Mercedes S580) | chauffeur / rental | $200 / $175 | $220 / $193 | Mercedes S580 |
| Mercedes-Maybach S680 (Mercedes S680) | chauffeur / rental | $225 / $200 | $248 / $220 | none: no S680 row in the rental guide |
| Chevrolet Suburban (Chevrolet Suburban) | chauffeur / rental | $175 / $150 | $193 / $165 | Chevrolet Suburban |
| Cadillac Escalade (Cadillac Escalade) | chauffeur / rental | $200 / $175 | $220 / $193 | Cadillac Escalade |
| Range Rover (Range Rovers) | chauffeur / rental | $200 / $150 | $220 / $165 | Range Rover Autobiography, Range Rover Sport V8, Range Rover Sport V6, Range Rover Velar White, Range Rover Velar Blue |
| Rolls-Royce Ghost (Rolls Royce Ghost) | chauffeur / rental | $350 / $350 | $385 / $385 | Rolls Royce Ghost |
| Rolls-Royce Phantom (Rolls Royce Phantom) | chauffeur only | $600 / $500 | $660 / $550 |  |
| Rolls-Royce Cullinan (Rolls Royce Cullinan) | chauffeur only | $600 / $500 | $660 / $550 |  |
| Mercedes-Benz Sprinter (blue) (Sprinter Van Blue) | chauffeur only | $400 / $350 | $440 / $385 |  |
| Mercedes-Benz Sprinter (orange) (Sprinter Van Orange) | chauffeur only | $400 / $350 | $440 / $385 |  |

## Notes

- The repository is public: the partner's sheet rates are in the migration and the test fixture, as the import needs.
- The partner agreement text (0046) describes the commission as a share of rental revenue; review it for the
  partner-rate basis before 01 Motors signs.
- A booking moved to another car after pickup keeps 0058's split for its parts (the partner-rate split covers a
  booking on one car).
- Model years are approximate until staff confirm them: A-Class, C-Class sedans, GLB, GLC, GLE, G-Class, GLS, S580,
  S63, BMW and most others 2025; C300 Cabriolet and E53 Coupe 2023; E43 2020; S500, GT53, X3 M, A5, S5, Macan, Ghost,
  Bentayga, Urus, Levante, Mustang 2024; R8 2023; 488 Spider 2019; California T 2017; 570S 2021; Q60 2022.

## Tests

- Unit: `web/src/features/partner/fleet-01-motors.test.ts` (the sheet's text parses to every row of both columns, 62
  cars and 11 chauffeur vehicles; names; the 12 flagged cars; the markup and rounding; the tiers; the split; the
  chauffeur hours).
- Database: `supabase/tests/61_01_motors_partner.sql` (the import and its second run, the rates and the tiers in the
  engine and the quote, Admin's per-car and per-partner pricing, a request on an insurance-included car, debit
  accepted, the year and the offer, the split on a sample booking with a refund and its statement line, the chauffeur
  request, its quote, staff changes and To do). Suites 04, 13, 31, 34, 40 and 52 count the imported fleet.
- End to end: `web/tests/e2e/partner-01-motors.spec.ts` at 375 and 1440 (a partner car's page with the badges, the
  tiers and the guideline note; the request on a no-credit-card car with insurance included skips the coverage choice
  and says debit is accepted; the chauffeur page and request).

## Guides

- `admin/partners-company-cars-and-rentals-added-by-hand` (A partner fleet on its own rates)
- `admin/chauffeur-service` (new)
- `va/chauffeur-requests` (new)

## The partner agreement on the partner's rates (migration 0105)

The partner agreement (`web/src/features/partner/agreement.ts`, now `partner-v3-2026-10-22`) described only 0046's
basis (a commission of what the renter paid). A partner on the `partner_rate` basis, such as 01 Motors, now gets
sections 1, 3 and 4 on its real basis: its rates are the guideline rates on its rate sheet, adjustable by written
agreement or in Admin; the renter pays the sheet rate plus the markup (10%); CarmaCars keeps the markup plus its cut
(20% of the sheet rate); the partner is paid the rest (80%) of its sheet rate per completed rental, net of the
deductions the terms already had (refunds in proportion, chargebacks, uncollected damage, deposit shortfalls). The
cars table shows each car's sheet rates (1-2 / 3+ / 7+ days), markup and cut. `app.partner_agreement_facts` carries the
basis, the markup and each car's sheet rates (0105; `supabase/tests/70_partner_rate_agreement.sql`). A partner on the
`renter_price` basis signs the same text as before. 01 Motors has no agreement sent or signed yet, so no PDF is
stored; Admin > Partners > Print the partner agreement renders the new text.
