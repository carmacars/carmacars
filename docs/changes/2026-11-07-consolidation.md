# Release 27 consolidation: staff parity, Live chat inside Visitors, five pages an area, Call and Text through Quo

Branch `r27-cons`, migrations 0500 and 0501 (SCHEMA_MARKER 0501). The owner on November 2, 2026: every Admin upgrade
reaches each relevant staff role's portal; Live chat belongs inside Visitors; every area still lists too many pages (aim
for five, actions as buttons); Call and Text should go through Quo, not the device's own apps. "I shouldn't be giving
you examples, you should be discovering this on your own": the audit below covers every admin area and every staff role.

## 1. Staff parity

Every staff page keeps its own check (vaPage, requireStaff) and the database checks every read again (the door). New
staff reads reuse Admin's database functions: `app.assert_admin` lets one call through for the one person a staff read
named (`app.staff_view`, transaction-local, set and cleared around the call after the staff read's own check), so the
staff version can never drift from Admin's. Admin's "view as" renders the staff frame and pages with the person's own
reads, so it shows exactly what each person sees (the new pages use the same frame and reads).

| Admin feature | Customer service | Sales | Fleet | Finance | Field |
| --- | --- | --- | --- | --- | --- |
| Visitors: live map with clusters, roles, Show contact | done (`/staff/visitors`, no fleet layer, no money) | done (same) | n.a. (no visitor work) | n.a. | n.a. |
| Visitors: Live now | done (replaces `/staff/live`) | done | n.a. | n.a. | n.a. |
| Visitors: History (one list by day, quick ranges) | done (rows open in place; the visit's own page stays Admin's) | done | n.a. | n.a. | n.a. |
| Visitors: Chat with Texts and calls (was Live chat) | done (replaces `/staff/chat`) | done | n.a. | n.a. | n.a. |
| Fleet tracking map | n.a. | n.a. | done (Fleet map, its own menu link, `/staff/fleet/map`) | n.a. | done (Map: the cars of their jobs, `/staff/field/map`) |
| Payments merged (By day, All payments, Refunds, Deposits, Reconciliation) with quick ranges | n.a. | n.a. | n.a. | done (Money tabs, `/staff/money?tab=`) | n.a. |
| Owner money (Invoices, Statements) | n.a. | n.a. | n.a. | done (read only, `/staff/owner-money`) | n.a. |
| Bookings > Now | done (already) | done (cars, no money, no renter contact) | done (already) | done (with the money) | done (Cars now, already) |
| Data health on To do | done: licences, papers missing on rent, old offers | done: stalled leads, old offers, sample car requests | done: car gaps, pickup not recorded, never closed, papers missing | done: unmatched payments, deposits held, expired but ran | n.a. (no To do) |
| Marketplace | n.a. | done: route and permission (`/staff/marketplace`, read only; the Sales Marketing tab builds on it) | n.a. | n.a. | n.a. |
| Call and Text through Quo | done | done | done (people of their work) | done (people of their work) | done (people of their work) |
| Actions as buttons (Send an offer, New quote, Add a rental, Add a car) | done | done | done | done | done (Add a rental, Report a problem on My jobs) |

Not brought over on purpose: the visit's own page (`/admin/live/history/<id>`, it holds every form's email and phone),
Data health's one-tap fixes and Check now (Admin's decisions), the Marketplace's logging, photo ZIP and settings, the
trackers' pairing and settings, approving statements and refunds above a limit (as before).

## 2. Live chat inside Visitors

- One page for Admin (`/admin/visitors`) and staff (`/staff/visitors`): tabs **Live now** | **Chat** | **History** on top,
  so they never move. Live now and History keep the map on top; Chat holds the live chat inbox with **Texts and calls**
  as its second inbox (`?view=chat&inbox=phone`). Badges: Live now the hot visitors, Chat the chats waiting plus unread
  texts; the menu's Visitors badge is chats waiting plus hot visitors (Admin and staff), so nothing that counted before is lost.
- Old addresses redirect with their query: `/admin/chat` and `/staff/chat` (`?id=` kept, `?view=phone` becomes
  `inbox=phone`), `/staff/live`, and as before `/admin/live`, `/admin/live/history`, `/admin/live-map` without `?tv=1`.
  Task links, To do prompts, the booking, renter and owner timelines and the chat links of Live now go straight to the new
  addresses. Alerts and emails stored with the old address still work through the redirects.

## 3. Five pages an area

Admin, before and after (the row on top of each area; tabs in brackets):

| Area | Before | After |
| --- | --- | --- |
| Today | To do, Overview, Staff tasks, Visitors | same; Visitors has Live now, Chat, History |
| Bookings | Bookings, Requests and offers, Calendar, Live chat, Reviews, Damage and claims (6) | Bookings, Requests and offers, Calendar, Reviews, Damage and claims (5); Live chat is Visitors > Chat |
| Cars | Vehicles (All cars, Fleet tracking, Rates for many cars, Calendar sync, Retire or delete), Listings (2), Maintenance | Vehicles (All cars, Fleet tracking, Calendar sync; Add a car, Rates for many cars, Retire or delete are buttons on All cars), Listings, Maintenance |
| People | Owners (Owners, Paid and signed, Owner forms, Add a car), Applications, Partners (2), Renters (2), Staff (4), Investors: 6 items, 13 pages | Owners (Applications, Owners, Owner forms, Paid and signed; Add a car for an owner a button), Partners (Partners, Referral partners), Renters (Renters, Leads), Team (Staff and roles, Academy, Hiring, Portals and view as), Investors: 5 |
| Marketing | Ads (Marketplace, Ad listings, Posted ads, Social drafts, Listing channels, Bookings by channel), Owner recruitment (2), plus an in-page row of all 8 (three rows of tabs) | Marketplace, Ads (Ad listings, Posted ads, Social drafts), Channels (Listing channels, Bookings by channel), Owner recruitment (Recruitment, Owner pipeline): 4, two rows at most |
| Money | Payments (6), Owner money (4), Tolls and tickets, Company accounts (3), Insurers (2), Staff pay (2): 6 | Payments, Owner money, Tolls and tickets, Company (Monthly statements, Company model, Expenses, Commissions, Field pay), Insurers: 5 |
| Settings | Settings, Logs | same |

Also removed: the in-page tab rows that repeated the area's rows (Owners, Vehicles, Fleet tracking, every Marketing
page). Every old address still opens (each page kept its address; the merged ones redirect). Ctrl+K lists every menu
link, every tab, every action button of a group (Add a car, Add a car for an owner, Rates for many cars, Retire or
delete), Send an offer, Add a rental and the Visitors tabs (Live now, Chat, Texts and calls, History).

Staff, each role's group before and after (To do, Bookings and Me for every office role):

| Role | Before | After |
| --- | --- | --- |
| Customer service | Requests, Live chat, Messages, Send an offer, Live visitors, More (6) | Requests, Visitors, Messages, More customer service (4) |
| Sales | Requests and offers, Send an offer, New quote, Live chat, My sales, More (6) | Requests and offers, Visitors, Marketplace, My sales, More sales (5) |
| Fleet | Field jobs, Daily checks, Photo reviews, Maintenance, Listings, More (6) | Field jobs, Fleet map, Checks (Daily checks, Photo reviews), Maintenance, More fleet (5) |
| Finance | Money to handle, Payments by day, Tolls and tickets, Reconciliation, Turo trips, More (6) | Money (To handle, By day, All payments, Refunds, Deposits, Reconciliation), Owner money, Tolls and tickets, Turo trips, More finance (5) |
| Field | My jobs, Cars now, My hours, Report a problem, Add a rental, My sales (6) | My jobs, Cars now, Map, My hours (4); Add a rental and Report a problem are buttons on My jobs; My sales is under Me |
| Bookings (office) | Bookings, Calendar, Find a car, Add a rental, New quote, Card coverage (6) | Bookings, Calendar, Find a car, Find a renter, Card coverage (5); Add a rental is a button on Bookings, New quote and Send an offer on Requests |
| More rows | up to 7 items (Fleet) | at most 5 for every role (unit test) |

`/staff/payments` and `/staff/reconciliation` redirect to their Money tabs with their query.

## 4. Call and Text through Quo

Research (support.quo.com, November 2026): Quo's documented deep links are `openphone://dial?number=&from=` (the dialer,
`&action=call` dials at once) and `openphone://message?number=&from=&text=`, in the phone apps only; on a computer the
Quo desktop app answers `tel:` links once it is the default calling app; the web app (`https://my.quo.com/inbox/`) has no
address for a number (its dialer opens with Alt+C, Ctrl+C on a Mac).

- `features/phone/QuoButtons.tsx` (`ContactButtons`) is the one Call and Text button, and `features/phone/quo-links.ts`
  the links (unit tested). It renders `tel:` and `sms:` links, so without JavaScript or with Quo off it is the device's
  own apps, as before.
- **Text** opens a composer: To, from the CarmaCars number, the booking it is about. **Send** posts `phone_compose`
  (migration 0500): the database checks the person and the number, refuses an opted-out number and queues the text in the
  person's thread; the server sends it at once through Quo (`staffCompose`, the same path as an inbox reply) and it shows in
  Texts and calls. Customer service, Sales and Admins get **Open the conversation**.
- **Call** logs `phone_call_log` (one per person and number a minute) and opens Quo: the app's dialer on a phone (a sheet
  with the web app and the phone's own dialer appears if the app did not open), the web app in a new tab on a computer
  with the number copied and a sheet saying how to paste it, or the desktop app when "On this computer, call with the Quo
  desktop app" is ticked (kept on that computer).
- Who: Admins, customer service and Sales for any number; fleet, finance and field staff for a number that is someone we
  know (renter, owner, lead or staff), the people their pages show them.
- Program setting `phone_quo_buttons` (on by default): off, or Phone and texts off, the buttons are `tel:` and `sms:`.
- Applied to: the Now view (every row), Requests and booking rows, the map's hover and click cards (not on the TV), the
  Texts and calls thread, the Admin booking page, the renter page, the staff booking page, field My jobs and the job page,
  the handover screen, the late return panel, game leads, captured contacts, Turo guests and the hiring pages. Left as
  `tel:`: the public site's CarmaCars numbers and the field page's "Call CarmaCars" (a staff member calling the office).

## Database (0500)

`va_read` live_map, visitor_history, data_health, marketplace; `phone_buttons`, `phone_compose`, `phone_call_log`;
`bookings_now_read` lets finance in with the money and Sales without it; `tracker_fleet` and `tracker_trip_path` for
field staff, narrowed to the cars of their jobs (two days back, three ahead). Suite `99_consolidation.sql`;
`99_now_board.sql` (Sales now reads the board) and `75_visitor_history.sql` (customer service reads History) updated.

## Tests

- Unit: `features/admin/hubs.test.ts` (five items an area, actions belong to their area), `features/staff/nav.test.ts`
  (rewritten for the new menus), `features/visitors/tabs.test.ts` (tabs and redirects), `features/phone/quo-links.test.ts`,
  `features/admin/data-health/model.test.ts` (staff links), `features/va/tasks.test.ts`, `features/guides/upkeep.test.ts`.
- e2e (375 and 1440, axe): `consolidation.spec.ts` (Admin Visitors tabs and redirects, the areas' rows and buttons and
  Ctrl+K, a Sales member's Visitors, Marketplace and menu, the Quo composer through the fake Quo line and the call log, the
  setting off). Updated: `fewer-pages`, `live-chat`, `live-signals`, `phone`, `guided-actions`, `gaps`,
  `legal-admin-redesign`, `staff-commissions`.

## Guides

`admin/getting-around-admin`, `admin/live-visitors-and-live-chat`, `admin/texts-and-calls-the-quo-phone-line`,
`admin/owner-money`, `admin/people-and-access`, `admin/settings`, `admin/fleet-and-listings`, `va/your-workday`,
`va/finance`, `va/fleet`, `va/live-visitors-and-live-chat`, `va/texts-and-calls`, `va/add-a-rental-by-hand`, `va/add-ons`,
`va/quick-reference`, `field/my-jobs`, `field/quick-reference`. Published by migration 0501 (`supabase/seed/0501_gen_guides.mjs`).
