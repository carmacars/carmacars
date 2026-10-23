# Portal cleanup (October 23, 2026)

Owner feedback: "there also seems to be a lot of confusion and clutter in the portals, try to make them a bit cleaner
and easier to use as they are a bit over complicated rn, thats the feedback im getting".

What changed: every portal has a short menu (six top items at most, the rest in sub-tabs or labelled parts of a group),
a home that shows what needs the person first and then the numbers, one page header (title, one line on what the page
is for, one primary action), the details most visits skip behind a disclosure, and tables that become cards on a
phone. Nothing was removed: every page, button and route is still there and every old address still works (no route
was moved or renamed, only menu labels and their grouping).

Screenshots: `2026-10-23-portal-cleanup/before-*.png` and `after-*.png`, each page at 390 and 1440 wide, taken on the
local stack with the seed data (`sample.renter`, `sample.owner`) and fresh Admin, assistant (customer service, fleet),
field and investor accounts. Each image is the top of the page (phones 2,000 px, desktops 1,400 px). The after shots
were taken once the end-to-end tests had run on the same database, so they show more bookings, requests and tasks than
the before shots (the fresh seed): compare the frame, the menus and the layout, not the counts.

## The audit: what was cluttered or confusing

| Portal | Problems found |
| --- | --- |
| Every portal | The public site's menu (Fleet, How it works, Delivery, Chauffeur, Requirements, List your car, FAQ) and "Find a car" sat above every portal page; the public site's long footer (rent links, 15 locations, company, legal, browse, the giant wordmark) sat under every portal page, often taller than the page itself. The "who is signed in" line wrapped Guide and Sign out onto a second line on a phone. The "New here?" guide banner was a tall black block. |
| Renter (`/account`) | "We found earlier requests" listed every request number (42 for the sample renter): a wall of text above the trips. Past trips listed in full under current and upcoming ones. The documents table scrolled sideways on a phone. |
| Owner (`/owner`) | Ten tabs (Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications, Profile) that ran off the screen on a phone. Home put 20 vehicle cards before the money figures, and the "add your bank account" and "set up the debit" prompts were small notes at the bottom. Bookings opened with two month calendars whose cells read "S-0..." on a phone, before the list. Invoices and Payouts opened with a paragraph of billing rules. |
| Admin (`/admin`) | Seven menu groups; Bookings (10 links), Money (11) and Settings (13) were long flat lists. "Tasks" next to "To do" and "Leads" (which holds renter contacts and game leads) were unclear. Site health listed eight checks, the alert rules and the text volume on the home page even when nothing was wrong. Tables (Bookings, Requests, Vehicles and every other list) scrolled sideways on a phone. Bookings showed three rows of filter chips before the list. |
| Staff (`/va`) | "My work" held eight links for customer service and Sales (To do, Today, My scorecard, My sales, Find a car, Live visitors, Live chat, Game leads). "To do" and "Today" side by side read as the same thing. To do showed three rows of filters before the list, and an empty queue said only "Queue clear." Tables scrolled sideways on a phone. |
| Field (`/field`) | The six links wrapped unevenly over two lines. "Report" did not say what is reported. An empty "Vehicle moves" card with nothing to press showed on every home. "No jobs today." gave no hint of what happens next. |
| Investor (`/investor`) | The menu was a row of underlined links with no gutter on a phone (text touched the screen edge). A large black "New" deck banner came before the investments. Each investment listed eight figures. Notices (redemptions, returns on hold) were plain notes. The statements table scrolled sideways on a phone. |

## Every portal (shared)

- Inside a portal the header shows the wordmark, "Your portal" and the Menu (phones); the public menu steps aside. The
  renter portal keeps "Find a car". The public pages stay one tap away (wordmark, Menu, footer).
- Inside a portal the footer is one short line: phone, email, Website, Contact, Terms of use, Privacy policy, Cookie
  choices.
- The "who is signed in" line keeps Guide and Sign out on one line on a phone (the email wraps instead).
- The guide banner ("New here? Read the ... guide.") is one slim strip.
- New shared pieces (`web/src/features/portal/Chrome.tsx`): `PageHeader` (title, one-line purpose, primary action),
  `Attention` ("Needs your attention": one line and one button each), `More` (a disclosure for details).
- Admin and staff `PageHead` takes a `purpose` line; `MoreFilters` folds the second and later filter rows ("More
  filters", open by itself when one is in use).
- Tables of the admin and staff portals (the shared `Table`), the renter's documents and the investor's statements are
  cards on a phone (under 768 px): the first column as the card's title, the others in two columns with their column
  names. Explicit table roles keep them tables for screen readers. Desktop is unchanged.

## Renter portal (`/account`)

- Menu unchanged (Trips, Documents, Notifications, Profile).
- Trips: page header with a one-line purpose; "We found earlier requests" shows the count past three requests, with the
  numbers behind "Show the numbers"; past trips fold into "Past trips (n)" when there are current or upcoming trips (shown
  as before when they are the only trips).
- Documents, Notifications, Profile: page header with purpose. Documents is a card list on a phone.

## Owner portal (`/owner`)

- Ten tabs became six: **Home**, **Vehicles**, **Bookings**, **Money** (Invoices, Statements, Payouts as chips under
  the tabs), **Documents**, **Account** (Profile, Banking, Notifications as chips; the unread count shows on Account and
  on Notifications). A partner sees Money without Invoices, and Documents with **Partner agreement**.
- Home: the next step first (unchanged), then "Also needs you" / "Needs your attention" (add the payout bank account,
  set up the pre-authorized debit, a payment processing: one button each), then Money (the figures, open invoices only,
  a link to invoices, statements and payouts), then the first four vehicles with "All n vehicles".
- Bookings: the list first; the two month calendars behind "Calendar: this month and next"; "Book my own car" jumps to
  the form on a phone.
- Invoices and Payouts: one line on what the page is for; the billing and payout rules behind "How billing works" and
  "When and how we pay you". Statements, Vehicles, Documents, Banking, Profile, Notifications: page header with purpose.

## Admin portal (`/admin`)

- Seven groups became six: **Today**, **Bookings**, **Cars**, **People**, **Money**, **Settings**. Every page is still
  two taps away on a desktop (group, page) and the keyboard shortcuts are unchanged.
- Long groups come in labelled parts: Bookings (Trips; Customers; Problems), People (Owners and partners; Renters,
  staff and investors), Money (Owners; Renters; Company), Settings (All settings; Website; Rules; Records).
- To do: one-line purpose; Site health shows one summary line ("All 8 checks working." or "Not checked yet.") and keeps
  every check, the alert rules, the text volume and the resolved problems behind "Every check, the alert rules and
  texts" (open by itself when a check fails; open problems always show).
- Bookings: one-line purpose; the supply and "Added by hand" filters under "More filters".
- Staff tasks and Renter leads: page titles follow the menu, with a purpose line.

## Staff portal (`/va`)

- My work is the person's own lists: **To do**, **Today at a glance**, **My scorecard**, **My sales**.
- Customer service and Sales get a **Live** group: **Live chat**, **Live visitors**, **Game leads** (moved from My
  work). Customer service now has six groups, Sales four, Finance four, Fleet five.
- **Find a car** moved from My work to **Bookings** (customer service, Sales) and **Rentals** (Finance, Fleet).
- To do: one-line purpose; Overdue/Due today/Escalated and the task types under "More filters"; the empty queue says
  what happens next, and a filtered empty list says how to see everything.
- Today at a glance: one-line purpose.

## Field portal (`/field`)

- The six places are one tidy block of buttons (three by two), all visible; the current one in black.
- **Report** is **Report a problem** (menu and page title), with one line on what can be reported.
- My jobs: the empty day says what happens next; the Vehicle moves card shows only when there is a car to move or a move
  to end.
- My sales and Referrals: one line on what the page is for.

## Investor portal (`/investor`)

- The same frame as the renter and owner portals: who is signed in with Guide and Sign out, then tabs (**Investments**,
  **Statements**, **Documents to sign**, **Investor deck** while it is shared, **Profile and notices**), with a gutter
  on a phone.
- Investments: "Needs your attention" first (documents to sign, redemption notices, returns on hold, one button each);
  each investment shows its Invested Amount, Yearly Percentage, how returns are handled and the Next Payment Date, with
  the principal, dates and amounts to date behind a disclosure; the deck is a plain card after the latest statement.
- Statements and Profile and notices: page header with purpose; statements are cards on a phone.

## Every label renamed or moved

| Portal | Before | After |
| --- | --- | --- |
| Admin | Menu group "Owners and partners" | Part of **People** (labelled part "Owners and partners") |
| Admin | Menu group "People" (Renters, Staff, Investors, Portals and view as) | Part of **People** (labelled part "Renters, staff and investors") |
| Admin | Today > "Tasks" (page title "Tasks") | Today > **Staff tasks** (page title "Staff tasks") |
| Admin | Bookings > "Leads" (page title "Leads") | Bookings > **Renter leads** (page title "Renter leads"); the Discount games settings text says "Bookings > Renter leads" |
| Staff | My work > "Today" (page title "Today", To do button "Today") | My work > **Today at a glance** (page title and button too) |
| Staff | My work > "Live visitors", "Live chat", "Game leads" | **Live** > Live visitors, Live chat, Game leads |
| Staff | My work > "Find a car" | **Bookings** > Find a car (customer service, Sales); **Rentals** > Find a car (Finance, Fleet) |
| Owner | Tabs "Invoices", "Statements", "Payouts" | **Money** tab, with Invoices, Statements, Payouts under it |
| Owner | Tabs "Profile", "Banking", "Notifications" | **Account** tab, with Profile, Banking, Notifications under it |
| Owner (partner) | Tab "Partner agreement" | **Documents** > Partner agreement |
| Field | "Report" (page title "Report something") | **Report a problem** (page title too) |
| Renter | Trips: section "Past" | **Past trips (n)**, folded when there are other trips |

## Guides

Chapters changed: `admin/getting-around-admin`, `admin/people-and-access`, `admin/partners-company-cars-and-rentals-added-by-hand`, `admin/chauffeur-service`, `admin/owners-and-onboarding`, `admin/discount-games-and-leads`, `admin/search-car-pages-landing-pages-and-guides`, `admin/quick-reference`, `va/your-workday`, `va/customer-service`, `va/live-visitors-and-live-chat`, `va/texts-and-calls`, `va/discount-game-leads`, `va/shared-tools`, `va/quick-reference`, `owner/start-here`, `owner/fees-payments-and-payouts`, `owner/for-partner-rental-companies`, `owner/notices-profile-and-leaving`, `owner/quick-reference`, `field/my-jobs`, `field/report-rentals-referrals-and-profile`, `field/quick-reference`, `investor/your-investments`, `investor/how-your-returns-work`, `renter/after-your-trip`.

The in-portal guides (`docs/guides/content/*.json`, seeded into the guide pages) and their sources
(`docs/guides/src/guides/*.py`) follow the new menu: Admin "People > ...", "Bookings > Renter leads", "Staff tasks", the
six groups and their parts; staff "Live > ...", "Bookings > Find a car", "Today at a glance", More filters; owner "Account
> Banking", "Account > Profile", "Money > Invoices", "Documents > Partner agreement" and the quick reference; field
"Report a problem"; investor the tabs and "Needs your attention"; renter "Past trips". `node scripts/guide-labels.mjs`
passes (74 sections, no missing label or menu path). The PDF guides (`docs/guides/pdf`) were not rebuilt: their build
needs the screenshot set in `docs/guides/screens`, which is not in the repository. The live guides on carmacars.ca are
rows in the database: the guide upkeep run (or Admin > Settings > Guides) brings them in line after the deploy.

## Left alone, on purpose

- Every route and page address; no page was removed or merged, so links in emails and bookmarks work.
- The database: no migration. Two texts stored in migrations still name the old admin group "Owners and partners"
  (an owner notification's trigger description in 0067 and a listing step's action in 0070); the menu shows "Owners and
  partners" as the heading of that part of People, so the path still reads true.
- Admin pages past the landing pages keep their own headers (most already had `PageHead`); the purpose line was added to
  the pages named above, not to all 80.
- The public site, its header and footer outside the portals.
- On a phone the admin and staff menus still fold behind one Menu button (Menu, group, page).
- The Admin To do prompts (migration 0078): every prompt still shows, most urgent first, with its own button. Folding
  them past a number would hide work and the guided-action tests rely on each prompt being on the page.
