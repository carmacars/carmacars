# Text is no longer squeezed on phones and wide screens (Release 48)

No migration.

On a phone, and in some places on a desktop, words were squeezed: a label broke letter by letter, a car name ran one word to a line, a note sat in a column a few letters wide, a button's text wrapped in three lines.

- Root cause: about 150 style rules used `overflow-wrap: anywhere` (including the shared `.small` text). On text inside a flex or grid cell it lets the cell shrink to one letter, so the browser squeezed it instead of giving it room. They use `break-word` now (a word breaks only when it cannot fit a line of its own). Only the elements that hold a long code, link or address (`.pt-mono`, `.gd-url`, the referral code, the VIN list, the email on the no-access page) keep `anywhere`.
- Buttons, chips, badges and table heads never break inside a word.
- The guide is laid out by the room it has, not by the window: beside a menu or inside the field portal's phone frame, notes and steps no longer sit in a column 8 pixels wide (`container-type` on each task, `@container` instead of `@media`). The field portal's guide uses the one-column layout.
- A guide section no longer grows wider than a 320px phone (its grid column is `minmax(0, 1fr)`).
- Floating labels in forms ("Where you are (city or neighbourhood)", "optional") use two lines at rest and one line with an ellipsis once shrunk, instead of running under the edge.
- The staff row of buttons shows "Assistant" whole at 320px; the live map's numbers wrap on a phone; owner page-head buttons shrink instead of running off the edge; a wide table's text columns keep room for a few words and the table scrolls inside its box; car names in tables and the field's now list keep a readable width.
- Check: `web/scripts/squish-audit.mjs` visits every public page and every portal page for each role (Admin, Customer service, Sales, Fleet, Finance, Field, renter, owner) at 320, 375, 768 and 1440 and lists squeezed text (`web/scripts/squish-lib.mjs`). Test: `web/tests/e2e/squish.spec.ts` runs the same check on a set of pages at 375 and 1440.

## Guides

No guide change: nothing a person does changes.
