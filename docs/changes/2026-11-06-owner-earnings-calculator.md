# What a car can earn: the calculator on List your car (0354)

The owner, November 1, 2026: a calculator for people listing their car that shows how much they can make each month.

**Where.** /list-your-car, right under the program's key facts, and a compact one at the top of the application
(/list-your-car/apply), before the questions. The application's questions (personal or corporation; owned, financed or
leased; the matching methods) are unchanged.

**Inputs.** The car by year, make and model (the lists of Add a car; a make or model not on them is typed) or by its
VIN (one look-up, as the application does). The days rented a month, a slider from 5 to 28 (18 at first). The share
the owner keeps, a slider from 60% to 90% (70% at first), labelled "set in your agreement".

**The estimate.**
- The daily rate: the average daily rate of the real cars on the site of the same make and model; else of the same
  class (the class the car would get when added: the class rules of 0082, read in the same order); else the class's
  starting rate in Program settings (`listing_default_daily_rate_cents`). No price is written in the page.
- Monthly rental revenue = rate x days; the owner's share of it; less the monthly program fees, two new Program settings
  `owner_calc_insurance_fee` and `owner_calc_tracker_fee` (dollars a month in Settings, cents in the database). While
  either is empty the line reads "Insurance and tracker fees: quoted in your agreement" and the result says "before
  fees". No fee is made up.
- A big monthly number and the year (twelve of the month as shown), with "An estimate, not a promise".
- **Just cheaper insurance**: the fleet policy's monthly fee (the setting, or "quoted in your agreement") and what the
  owner keeps at only 5 days a month.

**How.** `public.owner_calc_data()` returns the small JSON (classes with their averages and starting rates, the
averages by make and model, the class rules, the two fees). List your car reads it with the page (cached with the page,
an hour); the application reads it once in the browser from the database API (kept for the tab). Every change of a
slider or the toggle is worked out in the browser (`src/features/owner/earnings.ts`): no server work per change. The
numbers run to their new value, never under reduced motion.

**Tests.** `src/features/owner/earnings.test.ts` (the class, the rate's order, the month before and after fees);
`tests/e2e/owner-calculator.spec.ts` (List your car and the application: the month and the year follow the sliders,
"before fees" while the fees are empty, the cheaper insurance view, axe, no overflow).

## Guides

- `admin/owners-and-onboarding`: the calculator, and the two fee settings it reads.
