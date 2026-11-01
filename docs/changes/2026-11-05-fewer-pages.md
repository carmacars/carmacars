# Fewer pages: one menu link and a row of tabs for each subject (r27)

The owner, November 1, 2026: "There's way too many tabs at the moment and information is spread out too much", "We need
less pages not more", and "Look for other tabs and shit that can merged and revamped".

The admin menu had 78 links in seven groups. It now has 34 in the same seven groups. Pages that showed the same records
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
- **Staff portal, Finance:** Payments by day, Payments, deposits and refunds, and Reconciliation are one **Money** link
  with the tabs To handle, By day and Reconciliation. Each page keeps its address and its Finance check.
- **Revamp of the merged pages:** one heading per tab with a plain line on what it is for (Damage, Incidents, Claims,
  Emails, Blocked addresses, Changes, Data access, Owner debits, Insurer invoices, Renter leads); the second-level tab
  rows inside the old pages are gone (their tabs are the group's tabs now); the buttons that only linked to a sibling page
  (Payments by day, Insurer invoices) are gone because the tab row does it. Tables still turn into cards on a phone.
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
| Admin menu links | 78 | 34 |
| Admin menu links outside other branches' areas | 65 | 21 |
| Admin list pages with their own content | 13 (the merged ones) | 6 |
| Staff Finance menu links | 7 | 5 |

## Tests

- Unit: `web/src/features/admin/hubs.test.ts` (which tab a page shows, detail pages show none, one group per tab, the menu
  link, old addresses with their query and old tab values), `web/src/features/admin/settings-index/groups.test.ts` (every
  settings page in one section, the search), `web/src/features/staff/nav.test.ts` (Finance's Money link).
- End to end: `web/tests/e2e/fewer-pages.spec.ts` at 375 and 1440: the admin menu's 34 links, each merged page and each
  tab with axe and no overflow, the tab row's current tab, every old address redirecting to its tab with its query, the
  Settings search and anchors, the staff Finance Money link and its tabs. The specs that opened the old addresses open
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
- `va/your-workday`, `va/finance`, `va/quick-reference`: Finance's Money link and its tabs.
