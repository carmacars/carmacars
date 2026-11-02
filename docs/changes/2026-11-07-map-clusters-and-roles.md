# Release 27 (part): who a person is, a calmer live map, a cleaner History, no jump to the top

Owner reports of November 7, 2026, one branch (`r27-mapfix`).

## 1. Roles: an owner is no longer "a renter"

- A visit linked to a `renters` row said "Known customer" and "Renter page" even for an owner who only has a renters row
  because they signed in on the renter side. `app.person_tags(user, renter, email, phone)` (migration 0470) now works out
  what a person is from every record: owner (an `owners` row by user, email or phone, or an owner-program lead), partner,
  investor, staff (admin, VA, field) and renter. A renters row makes a person a renter only when they have rented (a
  booking that is not an owner's and not cancelled, declined or expired) or have no other role.
- The Live visitors, Live map, Visitor history and captured contacts (Renter leads page) reads carry `roles` and
  `owner_id` on each row. The website shows the most relevant role first ("Owner", "Owner · renter", "Investor · renter")
  in Live now (badge and filter label), the map card, the History rows and the Renter leads rows, and links to the
  owner's page for an owner (the renter's page only when they are also a renter).
- An owner, partner, investor or staff member who is not also a renter is not a renter lead: never the "Hottest lead",
  never a hot pin. "Hottest lead" still leaves out anyone on rent or with a confirmed booking.
- Not changed: Admin > Search groups hits by what they are (owners, renters), each by its own table.

## 2. Live map: clusters instead of a pile

- Pins that crowd each other gather into a count bubble (`clusterPins` in `live-map/model.ts`, shared by the WebGL map and
  the Canvas fallback): the hottest members take their neighbours, the bubble sits in the middle of its members, takes
  its hottest member's colour, has a thicker ring when a hot lead is inside, and bubbles never overlap. A press zooms in
  to where the bubble splits (`splitZoom`); when its pins sit on one spot it opens as a ring of pins with fine lines
  (`spiderOffsets`), and a press elsewhere closes it. From zoom 12.5 nothing clusters. Photo cards show for lone pins only.
- Names by the dots show only for leads and hot visitors, from zoom 10.5, hottest first, with collision handling (a name
  with no room waits). Dots are a little smaller at city zoom, photo cards a little smaller below zoom 11.5.
- The Hamilton to Barrie framing, hover and click cards, Show contact and TV mode (`?tv=1`) are unchanged.
- Screenshots: a harness drove the real MapLibre engine (before and after) with 114 mock pins; the Canvas fallback shares
  `clusterPins` and is covered by its unit tests.

## 3. Visitors > History: one list by day

- Rows grouped by day (Today, Yesterday, the date) under a black band; each visit one compact row: time, who and role,
  city, short source, pages, up to 3 car photos and "+n", a score dot, the outcome (Request sent, Booked, Account, Lead,
  Chat, Left). A press opens the page trail (`app.visit_history_extra`, first 12 pages), facts, Open the visit and Show
  on the map. A search box narrows the rows on the page. Filters in one row (quick dates, From, To, Source, Led to) with
  the rest under More filters; the totals are one line, the chart and top lists under "Day by day and top pages".
- At 375 each row is two lines (who and outcome, then time, city and source with the cars); nothing scrolls sideways
  except the quick-range control, which scrolls on purpose.

## 4. Clicks no longer jump to the top

- `components/Link.tsx` is the one Link (every file imported `next/link` before): a link to the page you are on (only the
  search parameters change: tabs, filters, pages, sorts) gets `scroll={false}`; other pages still start at the top;
  `#hash` links keep the browser's own scroll. ESLint forbids importing `next/link` anywhere else.
- `components/GetForm.tsx` replaces the 7 `method="get"` filter forms (no reload, no jump). Router calls with a template
  target use `scrollOption(...)` (`lib/nav/same-page.ts`).
- Found and left alone: every `<button onClick>` already has a `type`, no `href="#"` links exist, server actions that
  `redirect()` go to other pages except Marketing > Social "add week" (redirects to the same page; it adds a week, so the
  top is where the result is).
- Unit tests (`lib/nav/nav.test.ts`) check the rule and scan the source for `next/link` imports, `href="#"`, untyped
  `onClick` buttons and query-only `router.push`.

## 5. Quick ranges

- `components/QuickRange.tsx`: Today, 7 days, 30 days, 90 days, Custom (focuses the page's From field); the dates travel in
  the address, links keep the scroll, it scrolls sideways at 375. On Visitors > History, Payments, Insurer statements and
  Bookings by channel (the pages with a from/to filter; the quick ranges are also inside the range picker of section 6); each page keeps its default range. Tests: `lib/nav/range.test.ts`
  and `visitor-history.spec.ts`.

## 6. One calendar everywhere

The public booking calendar (`features/calendar/Calendar.tsx`) is now the only date picker. New shared parts:
`components/DateInput.tsx` (`DateInput`, and `TypedInput` for forms that choose the input type by data) and
`components/DateRangePicker.tsx`. A date opens the calendar in a popover on a desktop and a bottom sheet on a phone (Escape,
outside click, arrow keys, Page Up/Down, focus returns to the field); a date and time adds a 15-minute time list; a time on its
own is that list. The box still takes a typed `2026-11-07` (or `2026-11-07 14:30`), so a person who prefers typing can, and the form
keeps posting the same `name` and the same `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM` or `HH:MM` value as before (`data-value` on the box
carries it for tests). The range picker has the quick ranges (Today, 7 days, 30 days, 90 days) inside it, two months on a
desktop, `min`/`max`, and sends the form when a range is chosen; it posts `from` and `to`. The calendar gained `max`, `single`,
`bare` and `start` props (the booking pages are unchanged). The admin master calendar's own classes were renamed `mcal*`, because
`.cal`, `.cal__head` and `.cal__day` of the admin grid clashed with the public calendar's. The `date-picker.test.ts` unit test fails
if a page puts a native date, datetime-local or time input back; `lib/date-input.test.ts` covers parsing and the 15-minute list.
e2e: `pickDate(page, label, date)` and `pickRange(page, label, ...)` in `tests/e2e/helpers.ts` (a typed date, or the calendar
clicked with `{ calendar: true }`); `visitor-history.spec.ts` opens the picker, runs axe at 375 and 1440, closes it with Escape
and picks a range. Screenshots of the picker only, in the session notes.

Converted (every native date, datetime-local or time input in the admin, staff and customer areas), by place:
Visitors > History, Payments, Insurer statements and Bookings by channel (range pickers); Master calendar (start date, block from
and to); Booking review (pickup, return, authorized until); Booking edit and changes (pickup, return); Booking money, Card tools,
Insurer confirmation, Owner money prompts, Deposit settle, Invoice editor, Approve step and Terms panel (received on, hold back
until, due, from); Car terms (from, lower from, raise from, pay from and until); Owner bookings and Apply wizard (pickup, return,
date of birth); Add owner car, Add car form and Registration (sticker expiry, SSC issued and expires); Maintenance record service
(expiry, made, done on); Manual rental (pickup, return, date of birth, licence expiry, authorized until, received, deposit
received); Offer composer, Quote form and Chauffeur form (pickup, return, date of birth, date); Turo sync (from, to); Rate card form
(from); Availability form (times); Agreement fields (date of birth, licence and policy expiry); Staff doc upload; Ready resolve
(expiry); Tolls (date and time, due on); Customer portal (licence expiry, self service date, coverage and policy expiry, details,
complete details); Manual records; Returns calculator; Career apply form; and every `Act`, `SaveForm` and `fields` form with a
`date` or `datetime` field (payments received, commissions, field pay, reconciliation, expenses, hiring, statements, invoices,
debits, investors, usage, settings, social, listings, referral partners, recruit, maintenance, insurers).

## Database

- 0471: the guide chapter (generated by `supabase/seed/0471_gen_guides.mjs`).
- 0470: `app.person_tags`, `app.visit_history_extra`; `app.live_visitors`, `app.live_map`, `app.captured_contacts`,
  `app.visitor_history` wrapped (the originals kept as `*_pre0470`).
- Tests: `supabase/tests/99_person_roles.sql`.

## Guides

- `admin/live-visitors-and-live-chat`: roles in Live now, the clusters and names on the map, and the new History list with
  the quick ranges.
