# Owner and investor portal design (October 24, 2026)

The owner: "The renter portal as well as the owner portal and investor portal have to be the most appealing and
interactive and look expensive." This change redesigns the owner portal (`/owner` and its tabs) and the investor portal
(`/investor`) on a shared set of premium components. Screens and read only loaders only: no table, rule, permission,
billing or payout function changed. Migration 0150 carries the guide chapters that describe the new screens.

## What changed

### Shared components (`web/src/components/portal-ui/`)

The components the renter, owner and investor portals share, with their styles in `portal-ui.css` (tokens `--pu-*` on
top of `tokens.css`: red, black, white and true greys, Inter Display for figures):

- `PortalHero`: the dark band at the top of a portal home (kicker, greeting, one line, figures, actions, media on the right from 64rem).
- `StatCard` and `Delta`: a figure with its label; numbers count up once when they come into view (`AnimatedNumber`). The
  server renders the final value, so a reader without script, a test or reduced motion never sees it move. A change
  against last month is said in words beside the arrow.
- `ProgressRing`, `ActionTile` and `ActionTiles` ("Needs your attention" as tiles), `TimelineItem` and `Timeline`,
  `MoneySummary`, `DocumentRow` and `DocumentList` (statements, invoices and agreements as rows with a file badge).
- Charts with no library: `BarChart` (HTML columns; with a handler each column is a button with `aria-pressed`),
  `Sparkline` and `LineChart` (inline SVG). Each chart carries its numbers as a visually hidden paragraph or as the buttons'
  names.
- Motion is CSS only, under `prefers-reduced-motion: no-preference`; only transform and opacity move. Every colour pair
  passes AA. Phone first: one column at 390, nothing wider than the screen.

The renter portal's redesign (branch renterui) builds the same component names in the same folder; the two are merged
when both land.

### Owner portal

- Home: a hero with each car's photo (its cover photo from the public website) and its status right now (On rent,
  Available, In service, Onboarding, Exit notice), this month's rental charges against last month, the next payout
  (the approved statement's amount and date, else the next payout date) and the days rented this month with a sparkline.
  Then the next step, "Needs your attention" as tiles, "Your earnings" (a column per month for six months: rental
  charges or payouts; a month switcher; each car alone or all cars; the month's bookings, days rented, rental charges,
  fees billed and the statement's payout; a table per car), Money (the same tiles as before), Coming up (the next
  bookings as a timeline) and the cars as photo cards with this month so far and the next booking.
- A car's page: the photo and status at the top, "This car by month" (twelve months), Coming up, then the page as before.
- Vehicles: the same photo cards. Bookings: Coming up above the list. Statements: payouts by statement month, paid out
  this year, the latest statement, and the statements as rows. Payouts: paid to date, the next payout and every payout
  on a timeline. Invoices and Documents: rows with file badges (the same links, tests ids and actions).
- Every owner and investor tab: rounded cards with a soft shadow (`.pt--lux` on the portal frame).

What the owner sees is only about their own cars: their bookings (owner_portal_bookings), their invoices and
statements (owner_portal_home). No utilization percentage and no fleet figure. Rental charges are before tax and after
discounts, counted by rental day (a rental over two months counts in each), and the page says the statement has the
final numbers (`web/src/features/owner/insights.ts`, with unit tests).

### Investor portal

- A hero with the investor's Invested Amount, the Returns paid (or reinvested) to date with the total earned, and the
  next payment: the Return on a statement not paid yet, else the next Payment Date with its amount estimated by the
  agreement's formula (the deck's `monthlyReturnCents`, the same as `public.calc_investment_return`) and labelled
  "Estimated". Beside it, the account month by month (Invested Amount, Returns to date, the next six months projected,
  dashed) from their own statements.
- Documents to sign as tiles; each investment with a ring for the lockup period (or "earning"); the payment schedule
  (the last Returns on statements, then the next three estimated); the latest statement as a row; the deck as a dark
  tile with the deck's own headline figures from Admin > Investors > Deck (the multiplier, with the deck's caveat that it
  is CarmaCars' internal figure and not a forecast, and the current offer). There is no video in the deck yet, so the
  tile links the deck only.
- Confidentiality: the page reads only `investor_read` home, statements and the deck settings; it shows nothing about
  the fleet's size, use, insurance or costs. The end to end test checks the page text for it.
- On a desktop the investor home uses the full width (80rem); the other investor pages keep the narrow column.

## Files

- `web/src/components/portal-ui/*` (new), `web/src/styles/investor.css` (new), `web/src/styles/owner.css`.
- `web/src/features/owner/insights.ts` and `insights.test.ts`, `OwnerMonths.tsx` (new), `Blocks.tsx` (photo cards,
  invoice rows); `web/src/features/investor/plan.ts` and `plan.test.ts` (new).
- `web/src/server/owner/data.ts`: `ownerView()` (read only: the owner's bookings, the public cover photos of their listed
  cars, their months and each car's status).
- `web/src/app/owner/` (layout, home, vehicles, a vehicle, bookings, statements, payouts, documents) and
  `web/src/app/investor/` (layout, home).
- `supabase/migrations/0150_owner_investor_portal_design.sql` and `supabase/seed/0150_gen_guides.mjs`;
  `web/src/lib/schema-marker.ts` (0150).

## Guides

- `owner/home-and-your-vehicles`: Home at a glance (the six tabs, the hero, your earnings, Money and Coming up, the car
  cards) and a car's page (photo, status, this car by month, Coming up).
- `investor/your-investments`: Read an investment (the hero and chart, the lockup ring, the payment schedule with
  estimated amounts).

The chapters keep their screenshots; the next run of the guides screenshot workflow replaces them with the new screens.

## Tests

- `web/tests/e2e/owner-investor-portal-design.spec.ts` (new, 375 and 1440, axe, no sideways scroll, copy rules): the owner
  hero, the months chart (month switcher, column buttons, car filter, payouts), Coming up, the car cards, a car's
  drilldown and every owner tab; the investor hero figures, the growth chart's text alternative, the schedule, the deck tile and
  the confidentiality check. Fixtures in `tests/e2e/portal-design-seed.ts`.
- Unit: `features/owner/insights.test.ts`, `features/investor/plan.test.ts`.
- The existing owner, investor deck, staff and gaps specs keep their test ids (`owner-next-step`, `owner-due`,
  `owner-next-debit`, `owner-vehicle`, `invoice-rows`, `invoice-row`, `invoice-status`, `owner-docs`, `investment`,
  `invested-amount`, `investor-name`, `investor-to-sign`, `deck-promo`).

## Not done

- The renter portal is the renterui branch's; the shared components are merged with it when both land.
- The guide screenshots are retaken by the guides workflow, not by hand.
