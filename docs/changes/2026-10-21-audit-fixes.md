# The audit fixes of October 21, 2026 (migration 0079)

The audit of October 21, 2026 (origin/main 4ff90d1, live database at 0071) found these gaps outside the guided To do
(another branch) and the work in progress elsewhere. Each is fixed here, in the database first, with its test.

## 1. The CarmaCars address on documents

Program settings had no company address, so the owner Enrollment Agreement's notice clause, the staff agreement, the
investor agreement and the ServiceOntario registry context printed none. The owner's decision of October 16, 2026:
"mailing address is 2967 Dundas st w Unit 208B / street address is 1570 midland but this will change".

| What | Before | Now |
| --- | --- | --- |
| `program_settings.company_address` | null | 2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2 (the mailing address, for notices) |
| `site_settings.street_address` | 1570 Midland Ave, Toronto, ON | 1570 Midland Ave, Toronto, ON M1P 3C3 (Scarborough; the postal code from two listings of the building, Redfin and LoopNet) |
| `app.owner_agreement_facts_0029`, `app.staff_agreement_prepare_0057`, `app.investor_agreement_prepare`, `app.registry_context_0022` | `ps.company_address`, no fallback | `app.company_address()`: Program settings, else the site's mailing address |

The emails, the generated documents (`app.doc_company`) and the owner debit payee already fell back to the mailing
address and are unchanged. The business listing's street (`business_street`) is unchanged.

## 2. Every real car has its listing

Six real cars (the KIA Forte, the three Jettas, the CTS and the Macan) had no listing row: the row was made only when
someone first opened, wrote or published the listing, and 0070's automatic publishing ran only for cars added after it.
The owner published all six by hand on October 21 (18:10 to 18:23), so live there is nothing left to backfill; the
backfill in 0079 is kept for any other database.

Root cause fixed: a trigger on `vehicles` makes the draft listing (`app.ensure_listing`) when a real car is added, from
any entry point (Admin Add a car, a car added for an owner, an owner's application, an import). It shows at once in
Cars > Listings and in Not on the site yet, with Publish now. A listing written in full for a new car (an import, a
sample car) replaces that empty draft; a draft anyone worked on is never replaced.

## 3. The commission base

The owner's rule: commissions and kickbacks apply only to the rental charge after discounts, before tax, never to
delivery, kilometres, add-ons or anything else bought; late extra days count.

| Case | Before | Now |
| --- | --- | --- |
| Late extra days (their own line at the return) | Not counted | Counted |
| A refund of delivery or kilometres | Came off the base in full | Comes off nothing |
| A refund spread over the lines (a cancellation share) | Came off in full | Only its rental lines come off |
| A refund staff enter | Came off in full | Staff choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons, other charges); only the rental charge comes off |
| A refund made by a change of booking (the new price is already in the booking) | Came off a second time | Comes off nothing (marked `booking_change`) |
| An older refund that says nothing | Came off in full | Unchanged (treated as the rental charge) |

`refunds.refund_of` holds the kind; `app.refund_rental_part_cents`, `app.late_extra_days_cents`; `app.sales_revenue_cents`
and `app.commission_base_cents` use them. The Admin booking page (New refund) and Finance's booking page (Request a
refund) have the field "What it refunds", the rental charge by default; `admin_do` and `va_do` keep it and refuse an
unknown kind. Live: no refund and no staff commission exist yet, so nothing earned changes.

## 4. "Management fee (Revenue Share)" on staff screens

The owner calls the Revenue Share the management fee. Staff screens now say "Management fee (Revenue Share)": the
Approve step, the Terms tab, Add a car for an owner, the owner page, the vehicle page (Revenue to CarmaCars and the
terms), the Admin owner terms form, the staff statement page and the Turo trips table. The staff guides say the same.
Legal documents keep the defined term "Revenue Share"; the owner's own screens keep the term of their agreement.

## 5. Add-on photos

Each of the 9 add-ons has a studio illustration in the site's style (light studio, floor and shadow, the red line, the
product in charcoal, white and red, its name): `web/public/addon-photos/<code>.svg`, made by
`web/scripts/gen-addon-photos.py`. 0079 sets `photo_path` only where it was empty; Settings > Add-ons > Replace photo
puts a real photo in its place. `photoUrl` serves `/addon-photos/` from the site, as it does `/sample-photos/`.

## 6. The official ServiceOntario forms

All 5 official templates are still `verified = false`, so owners get data sheets. They are not marked verified here:
an Admin checks each one. Settings > Forms now has "Review and check" on every form not checked yet: a pop-up with the
form filled for one real car, drawn page by page, the fields filled and those empty for that car, then "Checked: use for
owners". A link to `/admin/settings/forms#<form code>` opens it at once; the guided To do (branch guided, 0077) lists
each form not checked as its own line with that link ("Preview it") and the one-press button.

Owner to-do: open Admin > To do (or Settings > Forms) and check SR-LV-006, SR-LV-012, ON00453, 013-1155 and 013-0169.

## 7. Car page speed

See the Measurements section.

## 8. Guides

The chapters of 0070 and 0071 were never written, and two lines were stale. Written now, and published by 0079 with
every chapter changed since the last release that published chapters (0069): 0072's rentals already underway too.

- Admin, Fleet and listings: Publish now and Publish new cars automatically, the checklist (paperwork, insurance,
  details, photos, No VIN yet, a possible duplicate, owner terms), the fleet policy rule at handover; the plate check
  holds back only that photo; an open duplicate flag no longer stops publishing.
- Admin, Partners and rentals added by hand: a car added by its plate alone.
- Admin, Owners and onboarding: the management fee in the Approve step. Owner money: the commission base.
- Admin, quick reference: "Publish a listing: Cover the plate, then Approve and publish" replaced (the same three lines
  as the guided branch, so the two merge cleanly).
- Assistants: Fleet (Publish now, the plate check, Similar cars no longer blocks), Finance (What it refunds),
  Commissions (the base).
- Renter: Before pickup, the three coverage options and what each needs, and the review.
- Staff review of proof of coverage and ID is written by the guided branch (where the Admin's review is built).
- The motion layer of 0070 has no guide: it changes no step on any screen.

Publishing: `supabase/seed/0079_gen_guides.mjs` writes the block in 0079 from `docs/guides/content`. After merging
another branch's guide changes, run `python3 docs/guides/src/export.py`, then the script again (`--check` fails while the
block is out of date), so 0079 never publishes a chapter without the other branch's text.

So that a feature never ships without its guide again: `scripts/check-change-guides.mjs`, run by CI (fast job), fails
when a change record dated after October 21, 2026 has no Guides section naming each chapter it changed as
`portal/slug`, or "No guide change" with the reason.

## Guides

`admin/fleet-and-listings`, `admin/partners-company-cars-and-rentals-added-by-hand`, `admin/owners-and-onboarding`,
`admin/owner-money`, `admin/quick-reference`, `va/fleet`, `va/finance`, `va/commissions`, `renter/before-pickup`.

## Tests

- `supabase/tests/57_audit_fixes.sql`: the address on the four documents and its fallback, the listing row of a car
  added and its replacement, the commission base (delivery, kilometres, add-on, late extra days, late fee, a delivery
  refund, a kilometre refund, an unknown kind, a rental refund, an older refund, a change's refund, a refund spread
  over the lines), add-on photos, privileges.
- `supabase/tests/00_owner_settings.sql`: the street address with its postal code.
- `web/tests/e2e/audit-fixes.spec.ts` at 375 and 1440: the management fee label, the add-on illustrations, What it
  refunds, Review and check from a link.
- `scripts/check-change-guides.mjs`.

## Measurements
