# CarmaCars portal style guide

Release 35, UX batch (November 9, 2026). Live: **/admin/style-guide** (every shared component, drawn by the same code the
portals use). The sheet: `web/src/styles/ui-kit.css`, imported last by every portal layout (admin, staff, field, renter,
owner, investor, partner) so it wins over the per-portal sheets. The guard: `web/src/styles/ui-kit.test.ts`.

The owner: "make all the buttons on the portals ... have the same style, like the visitors tab", "theres a lot of very nice
styling stuff on the bookings page but it doesnt match the requests page. make sure design styling is coherent across every
portal and every page and every staff member."

## Where the patterns come from

| Pattern | From | Used for |
| --- | --- | --- |
| Pill buttons | Visitors (Today > Visitors) | Every `.btn`, in every portal |
| Segmented tabs: grey track, black pill with a red underline for the current tab | Visitors | `SegTabs`, and every existing tab bar (`.ad-tabs`, `.bk-tabs`, `.vs-tabs`, `.ph-tabs`, `.ptabs`) |
| Page head: display title, one lead line, actions right, tabs under | Bookings | `PageHeader`; `.ad-head` titles take the same type |
| White sections, 16px corners, hairline border, soft shadow | Bookings (Now) | `.pt-card` / `Card` everywhere |
| Filter chips: bordered pills, black when chosen | Bookings | `.ad-filters`, `.bn-chip` |
| Counts as round badges, status badges as words | Bookings, Admin | `.pt__count`, `Badge` |
| Empty states: dashed, quiet grey | Bookings | `.ad-empty`, `Table`'s empty |
| Checklists: a round mark, green when done, the hint when not | r35 UX | Ready for the rental, Prepare |

## Tokens

- Shape: `--r-pill` / `--ui-r-pill` 999px (buttons, tabs, chips, badges), `--ui-r-card` 16px (cards, sections),
  `--ui-r-tile` 12px (tables, tiles, empty states). Inputs keep `--r-2` (6px). Since Release 41 these tokens are in
  `web/src/styles/tokens.css`, read by the public site too; `--r-3` (panels, sheets, modals) is 16px.
- Colour: black for the firm thing, CarmaCars red (`--red-600`) for what needs someone and the one primary action, true
  greys (`--grey-100` tracks, `--grey-200` hairlines, `--grey-600` quiet text), `--ui-ok` green only beside a word.
- Type: the display face (`--font-display`) for page titles, section titles and big figures; the text face for the rest.
- Every colour pair passes WCAG AA; colour is never the only signal.

## Components

- **Buttons** (`.btn`, `.btn--primary`, `.btn--ghost`, `.btn--quiet`, `.btn--sm`, `.btn--lg`, `.btn--block`): one pill
  shape. One primary (red) action per screen; black for a firm action; ghost for secondary; quiet inside a line of text.
  No page gives a button its own background, border or corners (the guard fails the build).
- **Tabs** (`SegTabs` in `web/src/components/ui`): links, so each tab has an address; the count as a red badge.
- **Page head** (`PageHeader` in `web/src/components/ui`; admin pages: `PageHead`, same look): title, lead, actions, tabs.
- **Cards** (`Card` in `features/admin/ui`, `.pt-card`): a title (display face), an optional aside (a badge, a count, a link).
- **Tables** (`Table`): numbers right-aligned and tabular; on a phone they become cards (existing behaviour).
- **Badges** (`Badge`): the status word, always.
- **Filter chips** (`.ad-filters a`, `.bn-chip`): `aria-current` or `aria-pressed` marks the chosen one.
- **Empty states**: a sentence that says what will show there.
- **Checklists** (`.ready-list`, `.prep-list`): one line each, a mark, the label, the hint while not done.

## Rules for new work

1. Use the shared components first (`components/ui`, `features/admin/ui`, `components/portal-ui`). A new look goes into
   `ui-kit.css` and this guide, not into one page.
2. Keep `data-testid`s and accessible names when restyling: e2e specs find elements by them.
3. Phone first: everything works at 375px wide, nothing scrolls sideways.
4. Motion only with `prefers-reduced-motion: no-preference`, and only transform and opacity.

## Applied in this release

- Every portal layout loads `ui-kit.css` last: buttons, tabs, chips, cards, tables, badges and empty states share one look
  in admin, every staff function (Sales, customer service, Fleet, Finance), field, renter, owner, investor and partner.
- The renter's and owner's pages outside the portal layouts load it too (pay, the three signing pages, the owner application,
  the partner portal); the guard lists them.
- Page heads read the same in every portal: the admin and staff sheets' stronger head selectors are matched in `ui-kit.css`
  (Requests' head is now the exact size and spacing of Bookings', for Admin and for staff).
- Admin > Requests and offers uses the Bookings head (`PageHeader`) and the segmented tabs.
- One-off button corners removed (`.ad .btn--sm`, the revamp tables, the renter's Now actions).

## Left for later

- Page-by-page markup passes (replacing per-page head markup with `PageHeader` beyond Requests; the renter, owner and
  investor heroes keep their own layout, restyled through the shared classes only).
- The field portal keeps its large tap targets (`fd-*`); it shares the button shape and the tokens.

## The public site (Release 41)

The owner: "A lot of the buttons and stuff on the actual public pages don't follow the design language ... for the portals."
The public sheets (`core.css`, `pages.css`, `app.css`, `seo.css`, `vehicles.css`) now use the same tokens, with no page-level rules:

- Pills: icon buttons, the header's search button, the Google sign-in button, the quantity stepper, badges, perks, filter
  chips (a grey hairline, black on hover, as the portals' chips) and the segmented control (grey track, black pill, red underline).
- Cards (16px, hairline, the soft shadow): panels, the search panel, the request form's sections, hub and guide cards,
  careers cards, the vehicle pages' request box.
- Tiles (12px): choices and add-ons in the request form, the calendar and seat boxes, the address lookup, car photos in cards.
- A button that is working: `aria-busy="true"` on a `.btn` shows the spinner and blocks a second press.

