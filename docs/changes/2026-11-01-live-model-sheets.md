# The model spreadsheets, live: investor Live sheets and Admin Company model (0420, 0421)

Release 27, investor sheets. The owner, 2026-11-01: "Can u have these spreadsheets as live and auto updating on the
investor portal? Downloadable but on the website it's viewable as live." The spreadsheets are the CarmaCars model workbook
(CarmaCars_Investor_Model.xlsx, its share copy CarmaCars_Investors_Share.xlsx): investor-safe tabs (Read me, How it works,
Investment calculator, Fund a car) and internal tabs (Company P&L, Actuals, Forecast, Pro forma), DO NOT SHARE.

The hard rule holds throughout: investors never see fleet size, utilization, the fleet insurance premium, internal costs
or the company P&L. The investor pages read only the investor's own records and the investment terms; the internal model
is Admin only, in the database and on the page.

## 1. Investor portal: Live sheets (`/investor/model`)

One page with four tabs, in the investor menu as **Live sheets** (investors only):

- **My investment**: Invested Amount, start date, Yearly Percentage, lockup end, payouts made (amount and count, and what
  was reinvested), the next payout (on record, else estimated) and the schedule: the investor's statements as recorded
  (Paid, To be paid, On hold, Reinvested), then the months ahead projected with the agreement's own formula
  (`public.calc_investment_return`), 36 Return Months from the first one (or from a year ago for an older investment). A
  **Paid monthly / Reinvested** switch compares the months ahead; it does not change the investor's election. Everything
  comes from `investments` and `investment_returns` through `investor_read home` and `statements` (their rows only), so
  the page updates itself when a payout is recorded: no stored copy, nothing to refresh.
- **Calculator**: the workbook's "Investment calculator" in the browser, cell for cell: amount (minimum $20,000 flagged),
  start date, annual return (their rate, default the offer, 30%), the 6-month lockup, paid or reinvested, the results block
  and the 36-month schedule (months 24 and 36 highlighted). $50,000 at 30% pays $1,250 a month from month 7.
- **How it works**: the lawyer-approved headline "3.2x multiplier on money invested in the fleet" (from the deck settings),
  the terms in plain words, the steps and the examples table.
- **Fund a car**: the owner-program calculator for up to three cars (monthly, yearly, return on the car, the 12-month
  payout schedule paid on the 10th).
- **Download as Excel**: a fresh .xlsx made for this investor on each download, with only the investor-safe tabs (My
  investment as values, How it works, Investment calculator and Fund a car with the workbook's working formulas, filled
  with their numbers). Made by a dependency-free writer (`web/src/lib/xlsx.ts`, zipped XML through `src/lib/zip.ts`), so it
  runs in the Worker with almost no CPU; the workbook asks to be recalculated on open.
- **Download as PDF**: their investment, schedule, the terms and the calculator on their numbers, with the agreements'
  pdf-lib renderer.

New: `investor_read model_terms` (the investor's name, the minimum, lockup, payment day, their offered or the current
rate, the headline multiplier, the company's legal name): no fleet figure.

## 2. Admin: Money > Company model (`/admin/money/model`)

One page with four tabs, linked under Money > Company:

- **Forecast** (the default): tiles for the latest actual month, the EBITDA break-even month, the next 12 months' EBITDA
  and the lowest cash; a chart of EBITDA by month (actual black, forecast grey, losses red) with closing cash; and 36 months
  marked A or F: cars, utilization, revenue per rented day, rented days, rental, fees, shares paid out, net revenue,
  processing, gross profit, operating costs by line, EBITDA, investor returns, tax, net income, capital received, one-time
  costs, cash flow and closing cash.
- **Actuals**: every month since launch from the summary table (below), the month in progress marked "So far".
- **Pro forma 5 years**: income statement, cash flow and key figures by year (year 1 starts at the launch month).
- **Assumptions**: growth (cars added a month and for how long), the utilization ramp, revenue per rented day and its
  yearly growth, fees and the company's keep as a share of rental, processing, monthly costs (staff, software, marketing,
  repairs, other) and their growth, hires, planned capital raises, the return and lockup on them, tax, opening cash,
  one-time costs and the **fleet insurance premium (blank until entered; counts as $0 with a warning)**. Saved in
  `finance_model_settings`; fields marked "From the actuals" left blank use the latest complete month.
- **Download as Excel**: the full internal workbook, built fresh: the investor-safe tabs, then Assumptions (blue input
  cells as saved), Actuals (values from the database), Forecast (60 months of live formulas: A/F from the actuals, the base
  month found by formula, every forecast step, investors on file as a values row) and Pro forma 5y (SUMIF by year), each
  internal tab named "DO NOT SHARE". Changing a blue cell in Excel reworks every month. Checked against the page's engine
  with LibreOffice: every month's rental, costs, EBITDA, investor returns and closing cash and every pro forma year agree.
- **Refresh actuals now** recomputes all months at once.

The forecast (`web/src/features/finance-model/engine.ts`) runs from the latest complete actual month: cars plus cars
added, utilization ramping linearly to the target, the base month's revenue per rented day growing once a year, 30.4 days a
month; fees and the company's keep at the base month's percentages; costs from the assumptions growing once a year, plus
hires from their month; investor returns are the investors on file (their own agreements, after their lockups) plus
planned raises after the lockup; tax on EBITDA less investor returns. An actual month uses its actuals; an operating line
with nothing entered in Admin > Expenses that month uses the assumption, marked "est.".

## 3. Actuals fill themselves, cheaply (0420)

The site is over its CPU allowance, so nothing is aggregated on a page view. `finance_model_actuals` holds one row per
month, written by `app.finance_model_refresh` from **pg_cron each hour** (`carmacars-finance-model`, minute 17): the month
in progress and the one before each hour, every month once a night (3 a.m. Toronto). Each month
(`app.finance_model_month`):

- **Rental revenue earned**, accrual: each booking's rental lines (rental charge, extra days, discounts) spread evenly over
  its billable days, each day in the month its pickup-time day starts in; before HST; **insurer-billed and renter-billed**
  apart (insurer bookings fully, split bookings by the insurer's share); by segment (company, shareholder, program,
  partner). Confirmed, on rent, returned and closed bookings only: **placeholders** (the flag or 0046's shape), cancelled,
  unconfirmed and owner rentals are left out.
- **Fees by kind**, the same spread: company fees and mileage overage (tolls and tickets at cost, deductibles and loss of
  use are not revenue).
- **Cash received by method** (card, e-Transfer, cash, debit and so on, refunds apart), **rentals** and **rented days**,
  **cars on the fleet** at month end.
- **Owner and partner shares** (rental after kickbacks and commissions, by the booking's split; company cars none),
  **staff commissions**, **referral kickbacks**, **owner payouts paid**, **processing fees**.
- **Expenses** from Admin > Expenses by category (voided left out), **investor payouts paid** and **capital received**.

## 4. Permissions

- `admin_read finance_model`, `admin_save finance_model_inputs` and `admin_do finance_model_refresh` refuse anyone but an
  Admin. No existing permission lets Finance see company statements (Company statements are Admin only), so Finance does
  not see the company model either.
- `finance_model_actuals` and `finance_model_settings`: row level security on, policy `admin_all` (Admins only) for a
  signed-in session; the server reads through the door.
- The investor pages: `requireInvestor` and the door's `investor_of` (the signed-in investor's own record); their
  investments and Returns stay behind 0012's own-records policies.
- DB tests prove an investor (and Finance) cannot read the internal model or another investor's numbers.

## Tests

- DB (`supabase/tests/99_investor_model.sql`): accrual proration across a month end, the insurer split, placeholders and
  cancelled bookings left out, fees by kind, owner share, expenses by category; the job fills the table; permissions and
  row level security.
- Unit: `features/investor-model/calc.test.ts` (the workbook's calculator: $50,000 at 30% pays $1,250 a month from month
  7, $37,500 by month 36; reinvested compounding; How it works; Fund a car's $1,075 example; My investment from records),
  `features/finance-model/engine.test.ts` (base month, A then F, the ramp, costs and estimates, hires, investors and
  raises, break-even and the pro forma), `lib/xlsx.test.ts` (the package, escaping, the investor workbook has no internal
  word, the internal workbook's formulas).
- e2e (`web/tests/e2e/investor-model.spec.ts`) at 375 and 1440 with axe: an investor's Live sheets (all four tabs, a
  payout recorded shows as Paid on the next view, both downloads), an Admin's Company model (every tab, saving the premium,
  the Excel download), Finance and investors refused.

## Guides

- `investor/your-investments`: the Live sheets part and the tab list.
- `admin/owner-money`: the Company model part.
- `admin/getting-around-admin`: Company model in the Money row.

Published by `supabase/migrations/0421_live_model_guides.sql` (`supabase/seed/0421_gen_guides.mjs`).

## For the owner

- Enter the **fleet insurance premium** (yearly) in Admin > Money > Company model > Assumptions. Until then it counts as $0.
- Enter each month's **costs in Admin > Expenses** (VA pay, software, marketing, repairs, parking, towing, the premium if
  paid monthly). A month with nothing entered uses the assumptions, marked est.
- Check the **assumptions** (cars added a month, target utilization, staff costs, hires, planned raises, opening cash, the
  franchise fee as a one-time cost, tax rate) and save them.
