# Fewer pages: one menu link and a row of tabs for each subject (r27)

The owner, November 1, 2026: "There's way too many tabs at the moment and information is spread out too much", "We need
less pages not more", and "Look for other tabs and shit that can merged and revamped".

Then, the same day: "i think u can reduce staff menu links even further, along with admin". The admin menu had 78 links
in seven groups. It now has 20 in the same seven groups: Cars, People, Marketing, Money and Settings are one link each. Pages that showed the same records
from different angles are one page with tabs; separate tools on one subject are one menu link with a row of tabs on top.
The areas other branches own this week (Requests, Bookings, Calendar, Send an offer, Add a rental, Chauffeur; Live
visitors, Live map, Visitor history; To do, Overview, Staff tasks; Live chat; the pricing settings; My sales) are
unchanged, menu lines included.

- **Page groups** (`web/src/features/admin/hubs.ts`): a group is a name and its tabs. The menu shows it once (its first
  tab), and the link is current on every page of the group. The tab row (`HubBar`, in the admin and staff frames) shows
  on each page of the group: the group's name with a red mark, then its tabs, the current one black. On a phone the name
  sits above and the row slides sideways. Detail pages (an invoice, a statement, an incident) show no row.
- **Merged into one page, each tab its own `?tab=` address; the old address redirects to its tab with its query:**
  - Money > **Payments** (`/admin/money`): By day (was Payments by day, `/admin/payments`), All payments, Refunds,
    Deposits, Disputes, Reconciliation (was `/admin/reconciliation`). It opens on By day.
  - Money > **Owner money** (`/admin/owner-money`, new): Invoices (`/admin/invoices`), Debits (`/admin/debits`),
    Statements (`/admin/statements`), Payouts (`/admin/payouts`). The statements to approve count on its menu link.
  - Money > **Insurers** (`/admin/insurers`): Rates, Invoices (was `/admin/insurer-invoices`).
  - Bookings > **Damage and claims** (`/admin/damages`): Damage, Incidents, Claims (was `/admin/incidents` with its own
    two tabs; `?tab=claims` still goes to Claims).
  - Settings > **Logs** (`/admin/logs`, new): Emails and Blocked addresses (was the email log, `/admin/messages`),
    Changes and Data access (was the audit log, `/admin/audit`). The old tab values map to the new ones.
  - People > **Renters** (`/admin/renters`): Renters, Leads (was Renter leads, `/admin/leads`, under Bookings).
- **Grouped, each page keeping its address:** Cars > **Vehicles** (All cars, Rates for many cars, Calendar sync, Retire
  or delete), Cars > **Listings** (Listings, Similar cars), People > **Owners** (Owners, Paid and signed, Owner forms, Add
  a car), People > **Partners** (Rental partners, Referral partners), People > **Staff** (Staff and roles, Academy,
  Hiring, Portals and view as), Marketing > **Ads** (Ad listings, Posted ads, Social drafts, Listing channels, Bookings by
  channel), Marketing > **Owner recruitment** (Recruitment, Owner pipeline), Money > **Company accounts** (Monthly
  statements, Expenses), Money > **Staff pay** (Commissions, Field pay).
- **Settings:** the menu had 20 settings links and the page listed 34 cards in one block. The menu now has **Settings**
  and **Logs**. The Settings page is six sections (Website; Rentals and rules; Payments and coverage; Messages and
  reviews; Cars and partners; Team and records), each with an anchor in a row at the top, and a search box that filters
  the cards as you type. My phone alerts and Logs are cards on it. Every settings page is in exactly one section (a unit
  test). Ctrl+K still reaches every settings page and now every tab of every group. Reviews no longer shows twice in the
  menu: the review settings are a card on Settings (Messages and reviews).
- **Sections (second cut):** Cars, People, Marketing, Money and Settings are one menu link each (`ADMIN_SECTIONS`), opening
  on the page used most (Vehicles, Owners, Ads, Payments by day, Settings). On their pages a first row shows the area's
  pages (Money: Payments, Owner money, Tolls and tickets, Company accounts, Insurers, Staff pay) and, where the page is a
  group, a second row its tabs (Owner money: Invoices, Debits, Statements, Payouts). A section's link carries its pages'
  counts (Cars: listings to review; People: applications; Money: refunds, statements and tolls). Ctrl+K lists every
  page and tab. Shortcuts: g v Cars, g o People, g m Money, g s Settings.
- **Staff portal, every role audited** (the owner, the same day: "Lots of the tabs under admin and under each staff
  account are redundant and can be merged to avoid confusion and to have a smoother workflow", then "i think u can
  reduce staff menu links even further"): each role's shift was mapped from its guide chapter and the Academy. Every
  office role now has the same anchors and nine links: **To do** (Today at a glance is its second page), the role's
  five most frequent jobs, **More ...** for the rest of its work, **Bookings** (Bookings, Calendar, Find a car, Add a
  rental, New quote, Card coverage) and **Me** (My numbers: Scorecard and My sales; Academy). The role's group is always
  open. Customer service: Requests, Live chat, Messages, Send an offer, Live visitors. Sales: Requests and offers, Send
  an offer, New quote, Live chat, My sales. Fleet: Field jobs, Daily checks, Photo reviews, Maintenance, Listings.
  Finance: Money to handle, Payments by day, Tolls and tickets, Reconciliation, Turo trips. Field staff: My jobs, My
  hours, Report a problem, Add a rental, My sales, and Me (Referrals, Profile, Academy). Pages showing the same records
  are page groups (`STAFF_HUBS`: Money, Renters, Owners, Listings, Field jobs, Checks, My numbers) inside the sections
  (`STAFF_SECTIONS`); each page and tab names the functions it belongs to, so a person sees only theirs, and every page
  keeps its address and its own check. Links: customer service 26 to 9, fleet 22 to 9, finance 18 to 9, sales 19 to 9,
  field 8 to 6. Each role's five most frequent jobs are one tap from the menu.
- **Revamp of the merged pages:** one heading per tab with a plain line on what it is for (Damage, Incidents, Claims,
  Emails, Blocked addresses, Changes, Data access, Owner debits, Insurer invoices, Renter leads); the second-level tab
  rows inside the old pages are gone (their tabs are the group's tabs now); the buttons that only linked to a sibling page
  (Payments by day, Insurer invoices) are gone because the tab row does it. Tables still turn into cards on a phone.
- **The revamped look, admin and staff alike** (the owner, the same day: "a lot of other admin portal stuff [needs a
  revamp]. And this should edit the staff's corresponding versions of these portals too"): the Now view's design
  language (Bookings > Now) on every page of Money, Settings, Problems, Cars, People, Marketing and Customers (Reviews,
  Renter leads) and on their staff versions (Finance, Fleet, customer service, Sales and field pages). One shared
  stylesheet and one list of pages (`web/src/features/admin/revamp/`, `RevampScope` in both portal frames) restyle the
  shared pieces both portals already use (`features/admin/ui.tsx`), so admin and staff stay in sync: numbers in a dark
  band (Tiles, and the staff figures), white rounded cards, rows with room and a bold first column, status chips, one
  red button for the row's next action, filter chips, and every row a card on a phone. A car in a row shows a photo
  tile (`CarCell`: the photo when the row has one, else the make's letter on black): Damage, Incidents, Claims,
  Expenses, Owner debits, Listings (admin and staff) and the staff Field jobs. The car's cover photo (approved, as on
  its public page) comes from `server_row_car_photos` (migration 0430, service role only, `web/src/server/car-photos.ts`);
  the letter shows only for a car without one. New dark bands: Payments by day (admin
  and Finance: received, refunded, net, refunds waiting, the cash drawer), Owner invoices, Owner statements, Payouts,
  Insurer invoices, Damage and the email log. A number or an amount in a band never wraps: its size follows the tile's
  width (container units), so $123,456.78 fits a phone's half-width tile. The pages other branches own (Bookings, Requests, Calendar, Visitors, To
  do, Overview, Staff tasks, Live chat, My sales) are not in the list and keep their look; a unit test holds that.
- **Access:** unchanged. Every admin page checks the Admin role and two-step sign-in itself; the merged pages do the
  same with the same check. The staff Money group holds only Finance pages.
- **Links:** the links inside the site (invoice and statement pages, booking insurer box, settings pages, the usage card,
  the assistant) go to the new addresses; emails and bookmarks with the old addresses redirect. A search form or a filter
  on a tab keeps the tab (`Search` and the Payments by day form carry the tab as a hidden field).
- **Not merged** (different jobs): Applications (a queue with a count) and Owners; Tolls and tickets; Maintenance;
  Investors; the settings pages themselves (each is its own form). The owner, renter, investor and field portals were
  already small (6, 5, 5 and 8 links) and are unchanged.

## Counts

| | Before | After |
| --- | --- | --- |
| Admin menu links | 78 | 20 |
| Admin menu links outside other branches' areas | 65 | 7 |
| Admin list pages with their own content | 13 (the merged ones) | 6 |
| Staff menu links: customer service, fleet, finance, sales, field | 26, 22, 18, 19, 8 | 9, 9, 9, 9, 6 |
| Taps for each role's five most frequent jobs (desktop, from To do) | 10, 10, 10, 9, 4 | 5, 5, 5, 5, 4 |

## Database

- `0430_row_car_photos.sql`: `app.row_car_photos` and `public.server_row_car_photos` (service role only); test
  `supabase/tests/99_row_car_photos.sql`. `SCHEMA_MARKER` 0430.

## Tests

- Unit: `web/src/features/admin/revamp/scope.test.ts` (the revamped pages, never another branch's), `web/src/features/admin/hubs.test.ts` (which tab a page shows, detail pages show none, one group per tab, the menu
  link, old addresses with their query and old tab values), `web/src/features/admin/settings-index/groups.test.ts` (every
  settings page in one section, the search), `web/src/features/staff/nav.test.ts` (each role's menu size, its group first, its top five jobs one tap away, a group shows only the role's tabs).
- End to end: `web/tests/e2e/fewer-pages.spec.ts` at 375 and 1440: the admin menu's 34 links, each merged page and each
  tab with axe and no overflow, the tab row's current tab, every old address redirecting to its tab with its query, the
  Settings search and anchors, the staff Finance Money link and its tabs, the revamped look on each merged page (admin and
  staff) and not on another branch's page, the customer service and fleet menus (their group open, the link count, a
  group's tab row). The specs that opened the staff menu's old groups (Live, My work) use the new ones. The specs that opened the old addresses open
  the tabs now.

## Guides

- `admin/getting-around-admin`: the menu table, a new part "Tabs on a page", the shortcuts g m and g s.
- `admin/people-and-access`, `admin/requests-offers-and-bookings`, `admin/insurance-replacements-rates-and-billing`,
  `admin/owners-and-onboarding`, `admin/owner-money`, `admin/texts-and-calls-the-quo-phone-line`,
  `admin/text-alerts-email-text-or-both`, `admin/discount-games-and-leads`, `admin/referral-partners-and-rentalcoverage`,
  `admin/advertising-and-owner-recruitment`,
  `admin/search-car-pages-landing-pages-and-guides`, `admin/settings`, `admin/email-backups-and-site-health`: the new
  places (Owner money, Payments, Insurers, Staff pay, Company accounts, Logs, Renters > Leads, Owners > Paid and signed,
  Partners > Referral partners, Owners > Add a car, Ads > Ad listings; Settings without "All settings").
- `va/your-workday` (the menu of each role), `va/finance`, `va/sales`, `va/shared-tools`, `va/live-visitors-and-live-chat`,
  `va/texts-and-calls`, `va/discount-game-leads`, `va/academy`, `va/quick-reference`: the new staff menu, Today,
  Me and My numbers, the page groups.
- `field/my-jobs`, `field/academy`: the field menu (five jobs and Me).
