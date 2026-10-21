# The investor deck (October 21, 2026; migration 0078)

The owner, October 21, 2026: "I need an outline of all the cool features we built and the profitability of this
business. Put it in the format of a pitch deck and put it in the investor portal." His directions during the work:

- **No internal costs.** No fleet insurance premium, fleet size or car count, utilization, staff pay, platform costs or any
  other internal cost figure; no blanks or "not entered yet" notes; no scenario tables on fleet counts and costs. The
  story is told with structure and public prices.
- **The profitability headline is the company's own figure**: "CarmaCars' figure: a 3.2x multiplier on the money we
  invest in the fleet", footnoted as internal, not audited, and that past results do not guarantee future results. The
  number is an Admin setting (`deck_multiplier`), not code.
- **The lawyer approved the deck and the 3.2x wording** the same day: "Show the deck to investors" is on by default (the
  Admin switch stays), linked prominently on the investor portal home.
- **Long, detailed and self-explanatory**: every feature with what it is, why it exists and its real screen, grouped by
  audience; how the 30% a year builds, exactly as the Investment Agreement calculates it, with worked examples and a
  calculator.
- The deck stays in the investor portal (signed-in investors and Admins), noindex. No public version.

## 1. Where it is

| Page | Who | What |
| --- | --- | --- |
| `/investor/deck` | A signed-in investor (an active or exited investor, or a prospect invited to sign, as the rest of the portal) while the switch is on; an Admin always | The deck. Linked from Investments (a card, "Open the deck") and the investor menu ("Investor deck") while it is shown |
| `/admin/investors/deck` | Admin | Settings (Act-style inline form) and the whole deck as investors see it, with "Open as investors see it" |
| Admin > Investors | Admin | "Investor deck (shown to investors / hidden)" and a one-click "Hide the deck from investors" / "Show the deck to investors" |

Everyone else: no session goes to sign-in, a signed-in person who is neither investor nor Admin goes to
`/investor/no-access`, and the database refuses them too (`app.deck_read`). Pages are noindex (and `/investor` is
disallowed in robots.txt).

## 2. The database (0078)

| Part | What |
| --- | --- |
| `deck_settings` (one row) | `show_to_investors` (default true), `deck_multiplier` (3.2, above 0 and under 100), `deck_return_bps` (3000, 1 to 10000: the yearly percentage of the current offer for the examples and the calculator), `updated_by`, `updated_at`. Row-level security with the admin policy, audit trigger, nothing for anon |
| `app.deck_figures()` | Every number the deck shows, read when it opens: the owner fee grid in effect (insurance, tracker, management fee by tier, and their monthly sum), the one-time tracker installation fee, `partner_commission_bps`, the deductible, the deposit range, the real cars' public daily rates (min, median, max; sample cars left out; the standard class default when no real car is listed) and their delivery fee, the active add-ons, the renter fees (young driver, cleaning, smoking, pet, fuel service, late return, lost key, toll and ticket administration), the number of automated emails (catalogue rows with an email, enabled), the investment terms of Program settings (minimum, lockup, redemption notice, payment day), the brand and contact details of site settings, and the sample 3-day rental with its split |
| The sample rental | 3 days at the median public daily rate, the median delivery fee, the first per-day add-on of the catalogue for 3 days within its cap, the 21 to 25 young driver fee for 3 days. Split per supply type: an owner car at each fee tier (the management fee of the rental charge), a company car (100%), a brokered partner car (the partner commission); every delivery, add-on and renter fee line is CarmaCars' own revenue (revenue class `company_only`, 0003 and 0066) |
| No internal figures | No fleet count, utilization, cost, wage or premium is read or returned (tested) |
| The door | `admin_read` "investor_deck" (Admin), `investor_read` "deck" (investor, refused while hidden: "The investor deck is not open yet"), `investor_read` "deck_visible" (for the menu and the home card), `admin_do` "deck_settings_save" (Admin; validates the switch, the multiplier and the percentage) |
| Guides | The chapter "The investor deck" in the investor guide (after How your returns work) and the Admin guide (after Add-ons), published by the migration (`supabase/seed/deck_gen_guides.mjs`, `--check` for CI) |

## 3. The slides

Built by `web/src/features/deck/Deck.tsx` from `app.deck_figures()`; feature words in `features.ts`; no amount in the
code. 16:9 cards from 60rem of card width (type scaled to the card with container units, so screen and print match);
on a phone a slide is a card that grows with its content. Keyboard (arrows, Page Up and Down, Home, End), swipe left
and right, Previous and Next, a jump list, and Download PDF (the browser's print: one slide per 13.333 x 7.5 inch
landscape page, nothing else of the site). Every slide's footer carries the short forward-looking notice; the contact
slide carries the full one.

1. Title (the tagline from site settings; "prepared for" the investor's name)
2. CarmaCars at a glance
3. The problem for renters
4. The problem for car owners
5. The solution
6. How a rental works (request, review, offer, sign, pay, verify, handover, return, statement)
7. How CarmaCars adds cars (owner program, brokered partner cars, company cars, a marketplace partner)
8. The owner program fees (the tier table)
9. Many revenue lines per rental (public rates, delivery, young driver fees, add-ons, after-trip charges)
10. A sample 3-day rental (the lines and the split by supply type)
11. Why the model scales (fixed owner fees, one fleet policy spread wider, growth without capital, revenue kept in
    full, automation, risk controls)
12. Profitability: 3.2x (the company's figure, footnoted)
13. The platform at a glance
14. to 58. Six audience sections, each a divider and one slide per feature with what it is, why it matters and its
    screen: renters (10), owners (7), investors (2), our team (7), Admin and automation (7), growth and marketing (6)
59. Safety and risk controls
60. Team and operations (no pay figures)
61. Roadmap (native iOS and Android apps after the web build, GPS trackers, more partner fleets, more marketplaces)
62. The investment offer
63. How your return builds (Investment Date, lockup, Lockup End Date, the monthly Return, the first payment; paid
    monthly, and reinvested for 12 months then paid)
64. Worked examples ($20,000 and $50,000, paid monthly and reinvested, after 1, 2, 3 and 5 years: a chart and a table)
65. Return calculator
66. Key risks (from Schedule C and section 8: could lose everything, unsecured, behind senior obligations, no right to
    demand repayment, exit by approved transfer or company redemption on six months' notice, lockup never made up, no
    shares, new business, more investors and senior debt, reinvestment risk and tax, not a deposit, no regulator review)
67. How to invest (talk to us, the agreement in Documents to sign, sign online, send funds, follow it in the portal)
68. Contact and the full forward-looking statements notice

## 4. The Return, exactly as the agreement

`web/src/features/deck/returns.ts`: the rules of sections 3 and 4 and of `public.calc_investment_return` /
`app.accrue_investment_return`: the Lockup End Date six months after the Investment Date (PostgreSQL month arithmetic),
no Return for the lockup, each Return Month (calendar month or part) earns round(Invested Amount x bps x days /
(120000 x days in month)) half away from zero, paid on the 15th of the next month or added to the Invested Amount at
month end. The calculator (amount at least the minimum, paid, reinvested, or reinvested for N years then paid, 1 to 10
years, the Investment Date) shows the Lockup End Date, the first payment date and how many months after investing, a
full month's payment, the total paid, the Invested Amount at the end, a chart and a month-by-month table. Unit tests
(`returns.test.ts`) reproduce Schedule B line by line: $20,000 at 30% pays $500.00 a month first on August 15, 2027;
reinvested for 12 months it reaches $26,897.77 and then pays $672.44 a month.

## 5. Screens

Public static assets in `web/public/deck/` (38 JPEGs, about 2.8 MB), all with fictional people and sample cars:

- 33 from the guides' screenshots (`docs/guides/src/img`, made by `web/scripts/guide-shots.mjs`), resized: the cars page,
  a car page, the request's review step, an offer, the agreement ready to sign, payment, licence and coverage uploads,
  extending a trip, a review; list your car, an owner's car, the owner calendar, a statement, an invoice, an official
  form, banking; the investor's investments and statement (phone) and profile and notices (phone); the customer service
  queue, review and offer, a new quote, field jobs, reading a toll notice, the sales scorecard, three field handover
  steps (phone); the fleet calendar, the plate editor, the email outbox, View as, Program settings.
- 5 photographed from the local build by `web/scripts/deck-shots.mjs`: a landing page (the top, without the sample
  fleet's count), a car page's add-ons, the live chat answering, Calendar sync and Turo by email, the Admin guide.

Screens that show internal money or utilization (the Admin's Today page, Finance's money) are not used. Four features
have no screen (live visitors, discount games, recovery emails, partner fleets): the games and the visitor page do not
show in automated browsers or without real visits.

## 6. Tests

| Test | What |
| --- | --- |
| `supabase/tests/52_investor_deck.sql` | The settings row (defaults, one row, checks, row-level security, admin policy, audit trigger, privileges); who reads it (investor while shown, Admin always; renter, owner, assistant, field staff, an uninvited prospect never; the Admin preview refused to an assistant and an investor); the switch off and on; the save (values, refusals, audit); the figures (median, investment terms, tiers, partner commission, the sample rental adding up, each split, the company car, the email count, no internal figures, no numbered company name) |
| `web/src/features/deck/returns.test.ts` | Schedule B examples 1 and 2 to the cent, part months at both ends, PostgreSQL month arithmetic, five years reinvested |
| `web/tests/e2e/investor-deck.spec.ts` | At 375 and 1440: the home card and menu link, the slides by button and keyboard, the tiers from the database, the calculator ($500.00, about 7.5 months, $672.44, the minimum, $1,250.00 on $50,000), axe, overflow and the copy rules; the PDF (one page per slide, the notice, no portal menu, no long dash); the Admin's preview, settings saved, hidden from the investor (no link, no deck) and shown again from Admin > Investors; anyone else turned away |

Run on October 21, 2026: the full database suite (`scripts/test.sh`) passed, 4,643 assertions in 55 files, 0 failed
(52 investor deck: 46); the unit tests 5 of 5; typecheck and lint clean; the deck's end-to-end file 6 of 6 (2 skipped by
design: the PDF and the switch run once, from the desktop). The production build (`next build`) could not run on the
shared machine (killed for memory each time, with other worktrees building), so the end-to-end runs used `next dev` on
the same local stack (`BASE_URL`); CI's build and full suite run on the branch as usual.

No applied migration was edited.
