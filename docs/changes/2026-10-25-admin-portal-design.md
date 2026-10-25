# Admin portal design (October 25, 2026)

The owner: "need to make each staff portal extremely easy to use and extremely good UI. Attractive, appealing and
interactive." This is the Admin portal (`/admin/**`); the assistant and field portals are separate changes. No business
logic, server action, database function, price, route or `data-testid` changed. Migration 0157 only publishes the guide
chapters whose wording changed.

## What changed, by screen

- **Every admin page** (`web/src/styles/admin-ui.css`, a layer over `admin.css` scoped under `.ad`, so the assistant
  portal's shared class names are untouched): calmer canvas, cards with 14px corners and a soft shadow, tables with a
  quiet header row and roomier rows (still cards on a phone), filter chips in one swipeable line on a phone, tabs as an
  underline with the current one in red, pill badges, an empty state with a mark, rounded dialogs. The menu's current
  page is black with white text; the current group has a red dot.
- **Jump to a page** (`features/admin/shell/AdminCommand.tsx`, `jump.ts`): Ctrl+K (Cmd+K) or the "Jump to a page"
  button under the search box opens a finder of every menu page and every settings page; arrows choose, Enter opens,
  the first line searches the records. `/` and the g-shortcuts work as before.
- **Toasts** (`features/admin/shell/toast.ts`): an action whose dialog closes (or a one-press button) now says what
  happened ("Refund sent.", "Question sent.") at the bottom of the screen for about four seconds. A polite live region
  without the status role, so the pages' own status lines stay the only ones found by role.
- **To do (home)** (`app/admin/page.tsx`, `features/admin/today/`): a dark band with the day, a greeting, "N things
  need you" and a board of seven counts, each one link: requests waiting (the oldest one's wait kept current, red past
  the reply target), pickups today (not ready), returns today (late), payments to chase, deposits to settle, staff tasks
  (overdue) and alerts. Under it "Needs you" (the same prompts and counts) beside today's pickups, returns and
  chauffeur bookings as a schedule by time. The heading is still "To do"; the counts come from the same `dashboard`
  read as Overview (the page works without it).
- **Requests**: the wait of a request still waiting keeps counting on the page and turns red past the reply target
  (`LiveWait`).
- **A booking** (`features/admin/BookingSummary.tsx`): under the booking number, where it is on its way (Request, Offer,
  Sign and pay, Confirmed, On trip, Returned, Closed) and the four facts looked for first: pickup to return, days, total
  at booking, bill to.
- **Vehicles**: who supplies the car, retired cars and the mode fold behind More filters (open by itself while one is in
  use).
- **Add a rental**: the intro and the form in the page's own column (no inline styles).
- **Settings**: every settings page as a card with its name and what is in it.

Motion: the board's counts rise in once, dialogs and toasts ease in, the waiting dot blinks past the target; all only
under `prefers-reduced-motion: no-preference`. Colour pairs pass AA (white or grey-400 on black, red-400 on black,
red-700 on red-50, grey-600 on white) and colour is never the only signal.

## Guides

- `admin/getting-around-admin`: To do's board of counts, the schedule beside the list, Jump to a page (Ctrl+K) and its
  key in the shortcuts table.
- `admin/requests-offers-and-bookings`: a booking at a glance under the booking number.
- `admin/fleet-and-listings`: Vehicles' More filters.

Published by migration 0157 (`supabase/seed/0157_gen_guides.mjs`); the screenshots follow with the guides workflow.

## Tests

No loading outline (`loading.tsx`) for the admin pages: a loading boundary streams the page, and a page's sign-in or
no-access redirect then happens after the first bytes instead of as an HTTP redirect, which the portal checks rely on.


Unit: `features/admin/shell/jump.test.ts` (the finder's ranking), `features/admin/today/board.test.ts` (the board's
counts). The end-to-end tests are unchanged: the To do heading, the menu's groups, `#gn-q`, the g-shortcuts and every
test id stay as they were.
