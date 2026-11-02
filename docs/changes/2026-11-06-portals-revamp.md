# The customer portals revamped: renter, owner, investor and partner (r27)

The owner, November 1, 2026: "Every single portal is getting a revamp right? Functionality and organization and usability
and flow of work and looks wise." Admin and staff were revamped on r27-nav (2026-11-05-fewer-pages.md); this is the same
work for the people outside the company: renters, car owners, rental partners, referral partners and investors. Each
portal now opens on one home that answers "what do I need to do or know right now", has at most five menu links, and
merges the pages that were one job into one page with a row of tabs. Every old address redirects to its tab with its
query; every page keeps its own sign-in and role check. The look is the admin revamp's: numbers in a dark band, white
rounded cards, the tab row on a grey track with the current tab black, one red button for the next action.

## Before and after

| Portal | Before | After |
| --- | --- | --- |
| Renter | Trips, Documents, Rewards, Notifications, Profile (5) | Trips, Documents, Rewards, Account (4) |
| Owner and rental partner | Home, Vehicles, Bookings, Money (3 chips), Documents, Account (3 chips) (6) | Home, Cars, Money, Documents, Account (5) |
| Investor | Investments, Statements, Documents to sign, Investor deck, Profile and notices (5) | Home, Live sheets, Documents, Investor deck, Account (5) |
| Referral partner | one unstyled page | the same page in the revamped look |

Merged pages, each tab its own `?tab=` address, the old address redirecting with its query (`features/portal-nav/tabs.ts`
`movedTo`, the lists in `features/portal/menu.ts`, `features/owner/menu.ts`, `features/investor/menu.ts`):

- Renter **Account** (`/account/profile`): Profile, Notifications (was `/account/notifications`). `/account/bookings`
  goes to Trips.
- Owner **Cars** (`/owner/vehicles`): Your cars, Bookings (was `/owner/bookings`; `?vehicle=` for "Book it for myself" kept).
- Owner **Money** (`/owner/money`, new): Statements (was `/owner/statements`), Payouts (`/owner/payouts`), Invoices
  (`/owner/invoices`; not for a rental partner, which pays no fees). A statement and an invoice keep their own pages.
- Owner **Account** (`/owner/account`, new): Profile, Banking, Notifications (were `/owner/profile`, `/owner/banking`,
  `/owner/notifications`). The Banking tab shows 1 while no payout account is on file; Notifications shows the unread count.
- Investor **Documents** (`/investor/documents`, new): Statements (was `/investor/statements`), Documents to sign (was
  `/investor/sign`), Your files (the agreement and schedules, each now a download at `/investor/documents/<id>`; the
  Profile listed their names with no link). A statement and a document to sign keep their own pages.

## The homes: the next thing first

- **Renter (Trips)**: a black panel first with one sentence for the nearest trip, the car, the day in words and the time,
  and the place: "Return the 2024 Volkswagen Jetta today at 7:00 p.m." with the return address, or "Pick up ... tomorrow at
  10:00 a.m." with what to bring. An urgent step (approve an offer, sign, pay, upload the licence) takes the sentence and
  its button comes first, with the time under it. Then **Pay $Y** when a balance is owing after a change or a charge
  (tolls, damage, a late return: it was only on the booking page), **Extend**, **Trip details**, **Message us** and
  **Call us**. On a phone the first button is full width and the others two by two, 44px tall. The trip with its photo
  and tiles follows (`features/portal/now.ts`, `NowPanel`).
- **Owner**: the next step (sign, pay an invoice, a new Vehicle Schedule) is first now, above the greeting. The dark band
  says how many cars are out and shows four figures: **Earned so far this month** (the month to date's net earnings, marked
  provisional; the approved statement's payout once it exists; it said "Rental charges this month", the gross rental, not
  what the owner earns), **Cars out now**, **Next payout** and **Fees due now** (with the next debit), beside the cars'
  photos and their status. A rental partner sees **CarmaCars commission** in place of fees. The Money block that repeated
  the band (Next payout twice, Next payout date, Next billing date) is gone; Coming up and the months follow.
- **Investor**: what needs the investor (a document to sign, a redemption notice, a return on hold) is first, under
  "Needs you now", then the numbers. The schedule links to the live sheets.
- **Referral partner**: the totals in the dark band first (paid so far, referred rentals, not finished, waiting, paid),
  the link and the code each with **Copy**, the referrals as rows with a status chip (cards on a phone; the table
  scrolled sideways at 375).

## Usability fixes from the audit

- The owner's Notifications sent owners to the renter portal for their email preferences; the owner's Notifications tab
  has them now (the same `Preferences` form).
- The investor's files were names without links; they are downloads (the documents row passes the investor's own
  row-level security, `my_document`).
- Empty states with a reason and what happens next: no investor statements yet (the first Return Month starts when the
  lockup ends), no files yet, a partner with no cars (CarmaCars adds them), a renter with no drivers (how to add one).
- The menu at 375 wrapped to two rows (five underlined links, 40px). It is one row of equal cells, icon above the word,
  54px tall; from 48rem a pill track. Tab rows share the row on a phone (no sideways scroll), 44px tall.
- Amounts never wrap: every figure is on one line (`white-space: nowrap`) and shrinks to fit its tile (container units);
  dates and words in the trip tiles still wrap.
- Buttons in the portals are at least 44px tall on a phone.

## Investor confidentiality

Nothing new reads the fleet. The investor menu, tabs and homes show only the investor's own records and the Admin's deck
figures; a unit test holds that the menu names nothing about the fleet, and the e2e test reads every investor page for
fleet size, utilization, insurance, premium or operating cost.

## Not changed

- The booking page and its step pages (pay, sign, extend, verify, change, cancel, the photo report, the walkthrough):
  their flows are unchanged. The owner's sign, review, partner agreement and form pages keep their addresses.
- The investor's live sheets (`/investor/model`) are r27-invsheets' page; the menu links to it and the home's schedule
  links to it with the same words and test id as that branch.
- Admin and staff pages.

## Tests

- Unit: `web/src/features/portal-nav/tabs.test.ts`: each portal's link count, the current menu link on homes, merged
  pages, old addresses and detail pages, the deck and live sheets only when shown, no Invoices for a partner, every old
  address landing on a tab of its merged page with its query, every portal page checking the session and role itself
  (or redirecting), the renter's sentence (today, tomorrow, the urgent step first, Pay before Extend) and the owner's
  figures. `web/src/features/guides/upkeep.test.ts`: the investor menu's Account.
- End to end: `web/tests/e2e/portals-revamp.spec.ts` at 375 and 1440: each portal's menu (links, the current one), the
  renter's home sentence before the trip, the owner's figures, each merged page and each tab with axe and no sideways
  scroll, no amount on two lines, tap targets, every old address redirecting with its query, the investor pages without
  fleet words. Updated: `owner-investor-portal-design.spec.ts` (the new figures, the new addresses),
  `supply-rentals.spec.ts` (the partner's menu, Money tabs and the partner agreement on Documents),
  `referral-partners.spec.ts` (the partner page: totals, Copy, axe and no overflow at 375 and 1440).

## Guides

- `renter/after-your-trip`, `renter/quick-reference`: the four links, Account > Profile and Notifications, Trips first.
- `owner/home-and-your-vehicles`, `owner/bookings-and-your-own-use`, `owner/fees-payments-and-payouts`,
  `owner/for-partner-rental-companies`, `owner/notices-profile-and-leaving`, `owner/quick-reference`: Cars, Money and
  Account tabs, the new home figures.
- `investor/start-here`, `investor/your-investments`, `investor/how-your-returns-work`, `investor/the-investor-deck`,
  `investor/profile-and-notices`, `investor/quick-reference`: Home, Live sheets, Documents (Statements, Documents to sign,
  Your files), Account.
