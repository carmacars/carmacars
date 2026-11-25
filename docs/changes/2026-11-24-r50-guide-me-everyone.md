# Guide me for everyone (Release 50: 4100)

Migrations `4100_r50_guide_me_everyone.sql` and `4101_r50_guide_me_everyone_guides.sql`, generator `supabase/seed/4101_gen_guides.mjs`.

## What it does

- **Every portal**: the Guide me button (3950) is also in the owner, renter and investor portals, and on the public sign-up (`/create-account`), booking (`/book/...`), owner application (`/list-your-car/apply`) and job application (`/careers/.../apply`) pages. Same engine, preference and placement rules; on the public site nothing is kept on the server.
- **Placement**: the card is never over Report a bug, the field tabs, or a primary button other than the one it points at, at 320/375 px.
- **Discovery**: the menu lists the workflows of the current page first (**On this page**), then the rest.
- **Workflows** (43 step files, listed per role in `docs/guide-me-coverage.md`): renters (sign up, licence, book, sign and pay, e-Transfer, pickup, extend, return, deposit, rewards), owners (apply, profile, sign, add a car, statements and payouts, invoices, documents), investors (dashboard, statements, documents), and the remaining staff pages (tolls, Turo trips, payroll, field spending, payments by day, maintenance, hours, marketing, leads, find a renter, first days, academy, field shifts, field pay, pay details), plus job applicants.
- **Stable targets**: `data-guide` on the page headers (`page-head`), the portal tabs (`portal-tabs`, `tab-<key>`), the sign-up form, the booking wizard's steps (`book-step-1` to `5`, `book-submit`) and the elements each step names.
- **Server**: every signed-in person may keep Guide me on and record runs (`app.guide_me_staff` answers for every user); runs say the portal (owner, renter, investor too). Admin > Academy counts everyone.

## Guides

- `renter/start-here`, `owner/start-here`, `investor/start-here`: Guide me.
