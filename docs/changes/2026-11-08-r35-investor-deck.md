# Release 35, part R: the 2026 investor deck, live, and its terms on every investor page (migrations 0851, 0869)

Branch `r35-r`.

The owner, November 8: update every investor-facing page so the terms and numbers match the current pitch deck exactly, and
put the deck itself live in the investor portal as a page, with its slides as responsive HTML.

## What changed

1. **The deck.** `/investor/deck` is the eight slides of the 2026 presentation (`features/deck/PitchDeck`): cover, model,
   competitors, difference, demand, per car, the ask, about. Every word and number is in one file, `features/deck/pitch.ts`;
   the slides are HTML in the existing deck frame (counter, previous and next, keyboard, swipe, Download PDF, one slide a
   landscape page). Signed-in investors see it while it is shown (0851 shows it); Admins always. The Per car multiplier is
   the Admin's figure (deck settings, 3.2). The Admin preview (`/admin/investors/deck`) shows the same deck.
2. **The terms, the same everywhere.** `TERMS` of `pitch.ts`: the raise of $500,000 ($400,000 fleet expansion, $50,000
   reserve for the funded cars, $50,000 operating cushion); Option 1, 10 to 15% a year paid monthly, simple interest ($4,167 to
   $6,250 a month on $500,000); Option 2, a 20 to 25% profit share from the cars the money puts on the road; eligible
   investors under a prospectus exemption; final terms in the signed agreement; 18122211 Canada Inc. as the only legal entity.
3. **What each investor page said before, and now.**
   - Investor Home, the deck tile: "Our multiplier on money invested in the fleet 3.2x" and "Our current offer, a year 30%"
     became Option 1 "10 to 15%" and Option 2 "20 to 25%", with the prospectus exemption and the signed agreement.
   - Live sheets, How it works: "30% a year on our current offer", the minimum investment, the 6-month lockup, exit by sale or
     buyback, "the company can repay with 6 months' notice", "not a loan, no shares", the four steps and the examples at 30%
     became the deck's terms and the Option 1 examples at 10% and 15% (simple interest).
   - Live sheets, the Excel download: the How it works sheet (the same older terms, the examples at the offer's rate) and the
     calculator's "Terms in brief" (lockup, exit, 6 months' notice, no shares) became the deck's terms and Option 1 examples.
   - Live sheets, the PDF download: the same older terms table and examples at 30% became the deck's terms and examples.
   - Live sheets, Fund a car: the example car at $80 a day with a $300 monthly insurance fee and a $25 tracker fee became the
     deck's $112 a rented day for 25 days (an illustration, not a forecast); the monthly fees are the investor's to enter from
     their agreement. The calculator starts at 10% (0851: `deck_return_bps` 3000 to 1000) for an investor without an agreement.
   - The investor deck: the older 40-slide deck (fixed 30% Yearly Percentage, 6-month lockup, owner fee tiers with insurance
     fees, the narrated video of that deck) became the 2026 deck. The older deck stays in the code only for the video script
     (`web/scripts/investor-video`); no investor page shows it or the video.
   - The investor guide chapters on the deck and Live sheets say the same.
   - `/investors` (the public sign-in page) publishes nothing about investing; unchanged.
4. **The rules, checked.** `pitch.test.ts`: the numbers worked out as the deck states them (the use of funds adds to $500,000,
   $4,167 and $6,250, $112 x 25 = $2,800), no fleet size, utilization, insurance premium or internal costs (the investor video's
   `forbidden.mjs` too), only 18122211 Canada Inc. as an entity, and that each investor page reads `pitch.ts` and states no
   older term.

Tests: unit `features/deck/pitch.test.ts`, `features/investor-model/calc.test.ts`; e2e `tests/e2e/investor-deck.spec.ts` (the
eight slides, the numbers, keyboard, PDF of eight pages, the Admin preview), `investor-model.spec.ts`,
`owner-investor-portal-design.spec.ts`.

## Guides

Published by `supabase/seed/0869_gen_guides.mjs` into `0869_r35r_guides.sql`: `admin/the-investor-deck`,
`investor/the-investor-deck`, `investor/your-investments`.
