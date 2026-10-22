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
| `site_settings.street_address` | 1570 Midland Ave, Toronto, ON | 1570 Midland Ave, Toronto, ON M1P 3C3 (Scarborough; the postal code from two listings of the building, Redfin and LoopNet). It stays public (the owner, October 21) |
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

The car gallery now gives the browser the sizes the listing pipeline made of each photo (`srcset` from the photo's
variants, with the original), for the main photo and the thumbnails, so a phone downloads the size it shows instead of
the 1,800 px original. The first photo keeps `fetchpriority="high"` and is never lazy. Sample cars use SVG studio
images and have no variants, so their pages are unchanged by this; real cars with processed photos gain the most.

## 8. The guides of 0070 to 0072, and the release rule

The chapters of 0070 and 0071 were never written, and two lines were stale. Written now, and published by 0079 with
every chapter changed since the last release that published chapters (0069): 0072's rentals already underway too.

- Admin, Fleet and listings: Publish now and Publish new cars automatically, the checklist (paperwork, insurance,
  details, photos, No VIN yet, a possible duplicate, owner terms), the fleet policy rule at handover; the plate check
  holds back only that photo; an open duplicate flag no longer stops publishing.
- Admin, Partners and rentals added by hand: a car added by its plate alone.
- Admin, Owners and onboarding: the management fee in the Approve step, a shareholder's own car, cancellation refunds.
  Owner money: the commission base. Add-ons: paid online when there is no card.
- Renter, Before pickup: paying add-ons with no card on file.
- Admin, quick reference: "Publish a listing: Cover the plate, then Approve and publish" replaced by "Publish a car: Cars >
  Vehicles, the car, then Publish now". The guided branch writes this line for its To do pop-ups ("Set rates and
  publish", "Mark insured", "Review documents"): when both merge, keep the guided branch's lines, then export the guides
  and run `supabase/seed/0079_gen_guides.mjs` again.
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

## 9. The second audit's settings and money rules (the owner's answers of October 21)

| What | Before | Now |
| --- | --- | --- |
| Pickup fee | An empty pickup fee was $0 ("not offered"): all 8 real cars had pickup $0 with delivery $75 | An empty pickup fee is the car's delivery fee (each way); the real cars' current rate cards with pickup $0 and a delivery fee take the delivery fee. 0 typed stays "not offered" |
| Possible duplicates | Two real cars whose copy was the plain template (the same sentences for every car) were flagged at 61 to 63%: 4 open flags, 2 Fleet tasks | Template copy (`car_copy.source = 'template'`) is never compared; those flags are removed (nobody decided them) and their tasks cancelled. Copy written for each car is still compared |
| Shareholder cars | No screen set `is_shareholder_owned` | Admin > Owners > the owner: "Shareholder's own car" per car, with what it changes (90/10, no Insurance Fee, Tracker Fee, first and last month or tracker install) and the reason in the audit log (`app.set_shareholder_car`, `admin_do` action `shareholder_car`). A first and last month or tracker install invoice is refused for such a car (trigger on `owner_invoices`); the monthly fees already skip it |
| The 2022 Chevrolet Malibu LS | Billed as Mahad Hussain's managed car (35%, $450 grid; INV-1044 void) | The owner's answer: Mahad's own car, Mahad a shareholder. Set by 0079 through the same function, as rent@carmacars.ca |
| Cancellation refunds | 95/75/50/0 written in `public.calc_cancellation` | Program settings `cancel_refund_within_24h_of_booking_bps` (9500), `cancel_refund_48h_plus_bps` (7500), `cancel_refund_24_to_48h_bps` (5000), `cancel_refund_under_24h_bps` (0), as of the booking's date. Behaviour unchanged |
| Add-on bought after booking, no card on file | The line waited unpaid; Finance collected by hand | "Pay for your add-ons" on the booking opens `/account/bookings/<number>/addons/pay`: one card payment (Stripe, captured at once, the card not kept) for everything due; recorded with its lines, the Finance task closed; the Stripe webhook settles it when the browser does not; a payment the database refuses is refunded at once |
| Card forms opened | A payment row only once the card was approved | `payment_intents_opened`: each PaymentIntent made for a card form (booking, add-ons, owner invoice) with the amount, purpose and who opened it, before anything is paid. The payment path's order is unchanged |
| Protection Plan prices | Economy 18 to 20 only, two rows ($60.00 and $25.00 a day) | The $60.00 row the lookup charged is kept, the other ends today; every class and age band gets a default where none is set (table below), all editable in Admin > Settings > Coverage prices |

Protection Plan defaults, per day (a typical Ontario rental damage waiver for a driver 26 and over by class, about $25 to
$50 a day and more for an exotic; times 1.4 for 21 to 25 and 2.4 for 18 to 20, anchored on the owner's economy 18 to 20
price of $60.00):

| Class | 26 and over | 21 to 25 | 18 to 20 |
| --- | --- | --- | --- |
| Economy | $25.00 | $35.00 | $60.00 (the owner's) |
| Standard | $28.00 | $39.00 | $67.00 |
| Premium | $35.00 | $49.00 | $84.00 |
| SUV | $35.00 | $49.00 | $84.00 |
| Van | $38.00 | $53.00 | $91.00 |
| Pickup | $38.00 | $53.00 | $91.00 |
| Luxury | $50.00 | $70.00 | $120.00 |
| Exotic | $80.00 | $110.00 | $190.00 |

A car in two priced classes pays the higher (the lookup of 0025).

## 10. The car code (the owner, October 21)

Every car has a public car code, "CC-" and 4 characters (more only when needed to stay unique), derived from the car's
id: stable, never the fleet number (which would show the fleet's size), from letters and digits that cannot be confused
(no I, L, O, 0 or 1) and always with a letter, so it never reads as a booking number (CC-10057).

| Where | What |
| --- | --- |
| Car page | "Car code CC-7F3A: quote it when you call or chat with us", under the price |
| Fleet cards | "Car code CC-7F3A" on the card's year line (every list built from `app.public_listing_row`) |
| Renter portal | Next to the car's name ("2021 KIA Forte (car code CC-7F3A)") on every booking page and the trips list |
| Booking emails | `car_code`, and the car's name with its code, in the payload of every booking event |
| Admin search | Finds the car by its code, typed any way (cc-7f3a, CC 7F3A, 7F3A); the car's line shows it |
| Assistants | My work > Find a car (`/va/cars`, every function; `va_read` `find_car`): code, plate, VIN or name |
| Add a rental | The car list shows each code; a box above Car chooses the car by its code or plate |
| Live chat | Each car's code is in the assistant's facts; a code in the visitor's message is resolved before it answers (`carByCode`, `codesIn`; a booking number is never taken for a code) |
| Staff assistant tools (branch assistant) | `public.server_vehicle_by_code(text)` (service role) and `app.vehicle_by_code(text)` resolve a code to the car |

`vehicles.car_code` (unique), filled on insert by `app.vehicle_car_code()` from `app.car_code_make(id, length)`; every
car, the samples too, got its code in 0079.

## Guides

`renter/find-a-car-and-send-a-request`, `renter/before-pickup`, `admin/getting-around-admin`, `admin/fleet-and-listings`, `admin/partners-company-cars-and-rentals-added-by-hand`,
`admin/owners-and-onboarding`, `admin/owner-money`, `admin/add-ons`, `admin/quick-reference`, `va/finance`, `va/fleet`,
`va/commissions`, `va/shared-tools`; and, never published by their releases, 0072's `va/add-a-rental-by-hand` and
`field/report-rentals-referrals-and-profile`, and main's `renter/during-your-trip` and `field/my-jobs` (0074 to 0076).

## Tests

- `supabase/tests/57_audit_fixes.sql`: the address on the four documents and its fallback, the listing row of a car
  added and its replacement, the commission base (delivery, kilometres, add-on, late extra days, late fee, a delivery
  refund, a kilometre refund, an unknown kind, a rental refund, an older refund, a change's refund, a refund spread
  over the lines), add-on photos, privileges.
- `supabase/tests/00_owner_settings.sql`: the street address with its postal code.
- `supabase/tests/57_audit_fixes.sql` also: the pickup fee, the street address, template copy, shareholder cars and the
  invoice guard, cancellation tiers from settings, Protection Plan prices, add-ons paid online, the card forms log.
- `supabase/tests/13_owner_answers.sql` unchanged in meaning (the street address stays public).
- `web/tests/e2e/audit-fixes.spec.ts` at 375 and 1440: the management fee label, the shareholder switch, the add-on
  illustrations, What it refunds, Review and check from a link, the add-on pay page.
- `scripts/check-change-guides.mjs`.

Results (CI on this branch, merged with main at 451c940 and later):
- Database suite: every migration and every test, 0 failed (fast job, run 39687541012), with lint, typecheck, unit tests
  (including `features/chat/carcode.test.ts`) and the generated types.
- End to end, every spec at 375 and 1440 (run 39686226260): 294 passed; the failures were this change's refund test
  (it now chooses its reason) and main's cookie notice test, which fails on main too (run 39686568037, e707523), as does
  main's link check. This change's specs with owner terms, add-ons and rentals in progress: 28 passed (run 39693282266).

## Measurements

Lighthouse (mobile, Lighthouse's default throttling, the CI build of this branch, run 39685568763):

| Page | Performance | Accessibility | Best practices | SEO | LCP | CLS | TBT |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `/cars/mercedes-benz-c300` (a car page) | 95 | 100 | 100 | 58 (a sample car is noindex) | 2.8 s | 0 | 110 ms |
| `/cars` | 94 | 100 | 100 | 92 | 3.0 s | 0 | 60 ms |
| `/` | 92 | 100 | 100 | 92 | 3.3 s | 0 | 100 ms |
| `/car-rental/toronto` | 97 | 100 | 100 | 92 | 2.6 s | 0 | 50 ms |

The car page measured 95 (the earlier report: 92). Lighthouse varies by a few points between runs on shared CI
machines, and the sample car measured has no photo variants, so this is not a controlled before and after.

