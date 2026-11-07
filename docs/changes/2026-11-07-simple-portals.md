# Release 32 "Simple": fewer pages and tabs, one page per job (audit and plan)

Branch `r32` from main (e6aaed93). No migration in the first slice.

## Plan

1. Booking page (Admin and staff): six sections, the old `?tab=` values land in their new section:
   Overview (the next step, review and offer), Money, Drivers & documents (the agreement panel too), Car & handovers
   (handover jobs, the photo report, sign now, the car, what the owner sees), Messages & history (messages, history,
   the review), Claims & extras (changes, extensions, add-ons, damage and claims).
2. Vehicle page (Admin and Fleet): eight tabs to five: Overview (with the calendar), Rates & fees, Terms, Listing,
   Maintenance & records.
3. One page per object for Admin and staff: the 39 routes that exist twice (list below) move to one shared component
   per object with sections and buttons by permission; `/staff/...` copies redirect to the shared page. First:
   bookings/[number], vehicles/[id], listings/[id], requests, bookings.
4. Lists: Requests, Bookings, Expired and Returns become Bookings with status chips (`/admin/requests` and
   `/staff/requests` redirect to `?view=requests`, the queue's claim and timer kept).
5. Settings: one page with a search box over every section (`/admin/settings/[section]` stays as an anchor target).
6. Today home per role: Admin To do, staff To do by function, owner Home, renter Trips: next actions first, each with a
   link straight into the action (most exist; the gaps are listed below).
7. Navigation: Admin 7 top items (already), staff by function (at most 7 shown per role), renter 4, owner 5, investor 5:
   already within the targets after r27; kept and checked by `portal-nav/tabs.test.ts`.
8. Every old URL redirects (a `MOVED` map per portal with a unit test); guides, e2e and crawl follow; screenshots only of
   the changed pages.

Order: 1 and 2 in this slice (the two biggest pages), then 4, 3, 5, 6.

## Inventory (route per portal; "=" also exists in the other portal)

### admin (118 pages)

admin admin/academy admin/academy/learn admin/academy/learn/[path]/[section] admin/academy/sections/[id] 
admin/academy/staff/[id] admin/alerts admin/applications admin/applications/[id] admin/audit admin/bookings 
admin/bookings/[number] admin/bookings/[number]/handover/[job] admin/bookings/[number]/report 
admin/bookings/[number]/sign-now admin/bookings/new admin/calendar admin/calendar-sync admin/chat admin/chauffeur 
admin/damages admin/damages/[id] admin/debits admin/expenses admin/guide admin/guide/[portal] admin/hiring 
admin/hiring/[id] admin/incidents admin/incidents/[id] admin/insurer-invoices admin/insurers admin/insurers/[id] 
admin/investors admin/investors/[id] admin/investors/deck admin/invoices admin/invoices/[number] admin/invoices/new 
admin/leads admin/listings admin/listings/[id] admin/live admin/live-map admin/live/history admin/live/history/[id] 
admin/live/signals admin/logs admin/maintenance admin/marketing admin/marketing/ads admin/marketing/channels 
admin/marketing/listings admin/marketing/marketplace admin/marketing/owner-pipeline admin/marketing/recruit 
admin/marketing/recruit/[id] admin/marketing/report admin/marketing/social admin/messages admin/money 
admin/money/commissions admin/money/field-pay admin/money/model admin/no-access admin/offers/new admin/overview 
admin/owner-forms admin/owner-money admin/owners admin/owners/[id] admin/owners/add-car admin/partners 
admin/partners/[id] admin/payments admin/payouts admin/portals admin/reconciliation admin/referral-partners 
admin/referral-partners/[id] admin/renters admin/renters/[id] admin/reports admin/requests admin/reviews admin/search 
admin/settings admin/settings/[section] admin/settings/coverage-affiliate admin/settings/guides 
admin/settings/guides/[portal] admin/settings/meta-publishing admin/settings/partners admin/settings/partners/[id] 
admin/settings/profile admin/settings/rewards admin/settings/usage admin/similar-cars admin/staff 
admin/staff/[id]/sales admin/staff/[id]/scorecard admin/statements admin/statements/[id] admin/tasks admin/tolls 
admin/tolls/[id] admin/tolls/import admin/tolls/new admin/tolls/profiles admin/tolls/read admin/tolls/read/[id] 
admin/vehicles admin/vehicles/[id] admin/vehicles/bulk-rates admin/vehicles/new admin/vehicles/samples 
admin/vehicles/tracking admin/visitors 

### staff (76 pages)

staff staff/academy staff/academy/[path]/[section] staff/addons staff/alerts staff/bookings staff/bookings/[number] 
staff/bookings/[number]/handover/[job] staff/bookings/[number]/report staff/bookings/[number]/sign-now 
staff/bookings/new staff/calendar staff/calendar-sync staff/card-coverage staff/cars staff/chat staff/chauffeur 
staff/checks staff/field staff/field-hours staff/field/guide staff/field/hours staff/field/jobs/[id] 
staff/field/jobs/[id]/sign-now staff/field/map staff/field/now staff/field/profile staff/field/referrals 
staff/field/rentals/new staff/field/report staff/field/sales staff/field/sign staff/field/sign/[id] staff/fleet 
staff/fleet/map staff/game-leads staff/guide staff/leads staff/listings staff/listings/[id] staff/live 
staff/maintenance staff/marketing staff/marketplace staff/messages staff/money staff/my-sales staff/no-access 
staff/offers/new staff/owner-forms staff/owner-money staff/owner-pipeline staff/owners/add-car staff/payments 
staff/profile staff/quotes/new staff/reconciliation staff/renters staff/requests staff/review-requests 
staff/review/[number] staff/reviews staff/scorecard staff/sign staff/sign/[id] staff/similar-cars staff/tasks/[id] 
staff/today staff/tolls staff/tolls/profiles staff/tolls/read staff/tolls/read/[id] staff/turo staff/vehicles/[id] 
staff/verify/[number] staff/visitors 

### account (21 pages)

account account/bookings account/bookings/[number] account/bookings/[number]/addons/pay 
account/bookings/[number]/cancel account/bookings/[number]/change account/bookings/[number]/condition-report 
account/bookings/[number]/extend account/bookings/[number]/offer account/bookings/[number]/pay 
account/bookings/[number]/pickup account/bookings/[number]/returned account/bookings/[number]/review 
account/bookings/[number]/sign account/bookings/[number]/verify account/bookings/[number]/walkthrough 
account/documents account/guide account/notifications account/profile account/rewards 

### owner (24 pages)

owner owner/account owner/banking owner/bookings owner/documents owner/documents/form-c/[vehicle] 
owner/documents/forms/[id]/official owner/documents/screen/[code] owner/guide owner/invoices owner/invoices/[number] 
owner/money owner/not-an-owner owner/notifications owner/partner-agreement owner/payouts owner/profile owner/review 
owner/sign owner/sign/schedule/[id] owner/statements owner/statements/[id] owner/vehicles owner/vehicles/[id] 

### investor (11 pages)

investor investor/deck investor/documents investor/guide investor/model investor/no-access investor/profile 
investor/sign investor/sign/[id] investor/statements investor/statements/[id] 

### Duplicates (Admin and staff copies of the same screen, 39)

 /academy /alerts /bookings /bookings/[number] /bookings/[number]/handover/[job] /bookings/[number]/report 
/bookings/[number]/sign-now /bookings/new /calendar /calendar-sync /chat /chauffeur /guide /leads /listings 
/listings/[id] /live /maintenance /marketing /messages /money /no-access /offers/new /owner-forms /owner-money 
/owners/add-car /payments /reconciliation /renters /requests /reviews /similar-cars /tolls /tolls/profiles 
/tolls/read /tolls/read/[id] /vehicles/[id] /visitors 

### Tabs today

- Admin booking page: Review and offer or Overview, Money, Changes, Messages, History, Drivers and documents, plus
  panels above the tabs (review, agreement, what the owner sees) and separate pages for the handover, the report and
  sign now. Staff booking page: the same six tabs, its own copy.
- Admin vehicle page: Overview, Calendar, Rates, Fees, Terms, Listing, Maintenance, Records. Staff vehicle page: its
  own copy for Fleet.

### Rarely useful or dead (to fold, not delete)

- `/admin/no-access`, `/staff/no-access`, `/owner/not-an-owner`, `/investor/no-access`: kept (sign-in states).
- `/admin/portals`, `/admin/search`, `/admin/similar-cars`, `/staff/similar-cars`, `/admin/live/signals`,
  `/admin/vehicles/samples`: reached from one place each; candidates to fold into their parent page as a section.
- Toll pages (`/admin/tolls/*`, 7 routes) and marketing pages (`/admin/marketing/*`, 9 routes): candidates for one page
  each with sections.

### Multi-step flows that cross pages

- Hand over a car: booking > handover job page > report page > sign-now page (4 pages): to Car & handovers.
- Send an offer: requests list > booking (Review and offer) > offers/new for a new one: to Bookings (requests chip) and
  the booking's Overview.
- Collect money: booking > Money tab, or Money > Payments: both stay, the booking's Money section is the one screen.
- Approve a licence: booking > Drivers & documents (one screen already).
- Invoice a partner: Referral partners > Invoices (one screen already, r28).

## Filters (the headline of r32)

Rule for every list (owner, Nov 7): one search box across fields (name, booking number, plate, phone, email, VIN), one
row of at most 5 chips (statuses that need action), at most one date range and only where dates matter (bookings,
money), one sort of 2 or 3 options where useful. No "More filters" panel and no "More" chip. A filter that does not fit
is served by the search, or kept as a link (a saved view) when a real job needs it; old query parameters still work
(the list still reads them, Clear removes them). One shared `ListFilters` (`features/list-filters`).

Audit (static count from the code: chip groups, their fixed options, a search box, tabs, date fields, dropdowns):

| Portal | List | Chip groups | Options | Search | Tabs | Dates | Dropdowns |
|---|---|---|---|---|---|---|---|
| admin | `app/admin/applications/page.tsx` | 1 | 0 | no | 0 | 0 | 0 |
| admin | `app/admin/bookings/page.tsx` | 4 | 6 | yes | 0 | 0 | 0 |
| admin | `app/admin/hiring/page.tsx` | 5 | 5 | no | 1 | 1 | 0 |
| admin | `app/admin/insurers/Invoices.tsx` | 1 | 6 | no | 0 | 0 | 0 |
| admin | `app/admin/logs/Audit.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| admin | `app/admin/logs/Emails.tsx` | 1 | 7 | yes | 0 | 0 | 0 |
| admin | `app/admin/marketing/ads/page.tsx` | 1 | 1 | no | 0 | 0 | 0 |
| admin | `app/admin/marketing/recruit/page.tsx` | 1 | 3 | yes | 0 | 0 | 0 |
| admin | `app/admin/money/commissions/page.tsx` | 2 | 10 | no | 1 | 0 | 0 |
| admin | `app/admin/money/page.tsx` | 2 | 12 | no | 0 | 0 | 0 |
| admin | `app/admin/owner-money/Invoices.tsx` | 1 | 0 | yes | 0 | 0 | 0 |
| admin | `app/admin/owner-money/Payouts.tsx` | 1 | 5 | no | 0 | 0 | 0 |
| admin | `app/admin/owner-money/Statements.tsx` | 1 | 5 | no | 0 | 0 | 0 |
| admin | `app/admin/portals/page.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| admin | `app/admin/referral-partners/page.tsx` | 1 | 6 | no | 1 | 0 | 0 |
| admin | `app/admin/renters/page.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| admin | `app/admin/reviews/page.tsx` | 2 | 7 | no | 0 | 0 | 0 |
| admin | `app/admin/search/page.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| admin | `app/admin/tasks/page.tsx` | 2 | 8 | no | 0 | 0 | 0 |
| admin | `app/admin/tolls/page.tsx` | 1 | 0 | no | 0 | 0 | 0 |
| admin | `app/admin/vehicles/page.tsx` | 4 | 12 | yes | 0 | 0 | 0 |
| staff | `app/staff/bookings/page.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| staff | `app/staff/cars/page.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| staff | `app/staff/messages/page.tsx` | 1 | 0 | no | 0 | 0 | 0 |
| staff | `app/staff/money/Lists.tsx` | 2 | 12 | no | 0 | 0 | 0 |
| staff | `app/staff/owner-money/page.tsx` | 2 | 0 | no | 0 | 0 | 0 |
| staff | `app/staff/page.tsx` | 3 | 5 | yes | 0 | 0 | 0 |
| staff | `app/staff/renters/page.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| staff | `app/staff/tolls/page.tsx` | 1 | 5 | no | 0 | 0 | 0 |
| shared | `features/admin/AdminNav.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| shared | `features/admin/ui.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| shared | `features/bookings-now/RequestsQueue.tsx` | 1 | 0 | no | 0 | 0 | 0 |
| shared | `features/coverage/CardTable.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| shared | `features/games/GameLeads.tsx` | 1 | 5 | yes | 0 | 0 | 0 |
| shared | `features/guides/GuideClient.tsx` | 0 | 0 | yes | 0 | 0 | 0 |
| shared | `features/maintenance/Views.tsx` | 0 | 0 | yes | 0 | 0 | 3 |
| shared | `features/va/SalesBoard.tsx` | 1 | 2 | no | 0 | 0 | 0 |
| shared | `features/visitors/HistoryList.tsx` | 0 | 0 | yes | 0 | 0 | 3 |

Totals: 38 list surfaces, 43 chip groups with 122 fixed options (plus dynamic ones such as the vehicle statuses),
20 search boxes, 4 lists with more than 2 chip groups (Bookings 4, Vehicles 4 with every status as a chip, Hiring 5,
the staff queue 3).

## Guides

No guide change in this slice yet: the chapters that name the booking and vehicle tabs follow when the sections land.

## Filters after (first lists)

| List | Before | After |
|---|---|---|
| Admin Bookings (all) | search, status 6, bill to 3, More: supply 4, added 2 | search (also the insurer), status 5 |
| Admin Vehicles | search, every status, More: supply 4, retired 3, mode 4 | search (also supplier and mode), status 5; Retired cars a link |
| Admin Owners | nothing (no search) | search (name, email, car), 4 chips: terms to approve, invoices open, not invited |
| Staff To do queue | 4 chips, More: when 4, type n | 4 chips |
| Admin Hiring | 5 groups: role n, status 12, source n, score 4 | status 5 (open, invited, booked, interviewed) |

The old parameters (`bill`, `supply`, `added`, `mode`, `retired`, `only`, `type`, `role`, `source`, `min_score`) still
filter when a link carries them; Clear removes them.
