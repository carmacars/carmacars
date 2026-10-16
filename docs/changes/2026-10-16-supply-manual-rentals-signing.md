# Supply types, rentals added by hand, retire and delete, official forms, simple signing and guide upkeep, October 16, 2026

Migrations `0046_supply_manual_rentals.sql`, `0047_official_forms_drafts.sql`, `0048_guide_supply_sections.sql`,
`0049_simple_signing_guide_upkeep.sql` and `0050_guide_upkeep_one_version.sql`; tests `supabase/tests/30_supply_manual_rentals.sql` (104 assertions) and
`31_signing_upkeep.sql` (56); end to end `web/tests/e2e/supply-rentals.spec.ts`, with the signing changes in
`owner.spec.ts`, `portal.spec.ts` and `guides-manual.spec.ts`; unit tests `src/features/person-agreements/model.test.ts`.
No migration that is applied on the live database was edited (0046 to 0049 were not applied before this deploy).

## 1. Vehicle supply types

Every car has one of three supply types (`vehicles.supply_type`):

| Supply type | Who it belongs to | Money |
| --- | --- | --- |
| `program_owner` | An owner in the owner program (as before) | Fees, invoices, owner statements and payouts as before |
| `company` | The one owners row of kind `company` (CarmaCars' own fleet) | No owner, no statement, fees or payouts; 100% of revenue to CarmaCars; the company statement has a company fleet section |
| `partner` | The partner's owners row of kind `partner` | Brokered: CarmaCars keeps the commission (Program settings `partner_commission_bps`, 20% by default; a partner's own; a car's own wins), the partner gets the rest on a monthly partner statement and payout |

- **Admin > Vehicles > Add a car** asks who supplies the car first, then the car. The duplicate check is the same for all
  three: a VIN once in the fleet, a plate on one active car, and 0040's similarity check.
- **Admin > Partners**: the partner record (business and legal name, contacts, HST number, commission, insurance company,
  policy and expiry, notes), its cars, bookings, statements and payouts, documents, a payout account (Admins only, the
  account number encrypted as an owner's), the partner portal (the owner portal with a partner flag: no Invoices page), and
  the partner agreement: a draft for lawyer review, filled from the record, signed in the portal or recorded as signed on
  paper.
- **Partner insurance reminders (0049)**: the daily check raises one Admin task per partner and expiry date when the
  insurance expires within `partner_insurance_warn_days` (30 by default), has expired, or has no expiry while the partner
  has cars. Saving a new expiry closes the old reminder. Admin > Partners also shows the warning.
- Pricing, the calendars (with a supply filter on the master calendar, 0049), the listing pipeline, tolls, damage,
  deposits, statements and reports, the Bookings filter and the duplicate check all read the supply type; the split reads
  the Revenue Share through `app.vehicle_terms()`, which answers 100% for a company car and the commission for a partner car.
- Program settings: a new group "Partners, rentals added by hand and agreements" holds `partner_commission_bps`,
  `partner_insurance_warn_days`, `manual_rental_va_payment_modes`, `manual_rental_va_promo`, `manual_rental_past_max_days`
  and `staff_agreement_defaults`.

## 2. Rentals added by hand

Admin > Bookings > Add a rental (and the same page in the VA portal for customer service and Sales, within their limits):
the car with an availability check that includes the turnaround (an Admin may book over a clash with a reason), dates and
times, places, the renter found or created, drivers, the price from the rates (an Admin may set it by hand; assistants
never type a price), extras, the Deposit, coverage, the source (phone, walk-in, Turo, partner, insurer, other), and how
it is paid: paid another way, a payment link, the saved card (charged at once, once) or unpaid. It is confirmed at once
(awaiting payment for a payment link), on the calendars, and the renter signs the agreement in their portal with no payment
step (or an Admin records a paper signature). Verification tasks run as usual and an Admin can mark a driver verified in
person. "Do not email the renter" stops the confirmation (refused with a payment link, which goes by email). A past rental
is recorded as completed for history and statements. Everything is in the audit log.

An assistant's car list shows only bookable cars with rates on file (0046, changed in this work): an assistant cannot
price a car without rates. Sales opens the bookings its inbox lists (0049): one waiting for payment (an approved offer, or
a rental added with a payment link) and a rental Sales added itself, without the money, as before for requests and offers
(the role crawl found the 404).

## 3. Retire and delete

**Retire** (soft, restorable): unpublishes the listing, leaves the calendars from then on, keeps every record; refused
while a confirmed booking is ahead. **Restore** brings it back. **Delete** (hard): only a car with no booking, payment,
statement, toll, damage or document; the plate (or the name) is typed to confirm; its photos are deleted from storage.
**Delete all sample cars** deletes every sample car that meets the rule and lists the others with why. Admins only;
audited.

## 4. Toll matching around placeholders

A placeholder booking (one that does not block the calendar and was never handed over, such as an insurer's booking) is
never a candidate. Two or more real rentals at the time of a notice are never charged automatically: the toll goes to
the exceptions (task `toll_two_rentals`, Finance) with every candidate. Tested in `30_supply_manual_rentals.sql`.

## 5. Official ServiceOntario forms

The forms-fetch workflow (runs 38866536454, 38866730538 and 38867389525, all green) resolved each form's dataset page to
its English PDF, stored it in the private documents bucket (`forms/templates/<code>/official-<sha>.pdf`) and recorded its
fields (`docs/forms/official-forms.json`). 0047 loads each as the current template with a draft mapping to the owner,
vehicle, corporation, CarmaCars (registrant) and lender values, unchecked: owners keep the data sheet until an Admin
presses "Checked: use for owners". The notes of each template say what the form is for and what is left blank on purpose.

Three sources were added for the drafts (0047): `always` (a box every copy ticks), `corporation.rin_missing` and
`owner.unit` (the unit number without its word, for the six-character unit boxes); the transform list offers
`date:YYYY/MM/DD`, the registry's style. The official texts keep their en dashes in the data as JSON escapes, so the text
check passes and a drop-down option still matches the form exactly. A signed copy of an official form drops the
publisher's Print and Clear buttons.

Each form was filled with sample data (`web/scripts/forms-sample.mjs`: a fictional owner with a corporation, each
onboarding method in turn, the database's own values, the browser's fill code, a sample drawn signature) and every page
was rendered and looked at:

| Form | What it is for | Kind | Fields | Mapped | Result |
| --- | --- | --- | ---: | ---: | --- |
| SR-LV-006 | Application for Vehicle Registration: the registrant, plates and status when a car changes registrant (Lease, Transfer) | fillable | 126 | 10 | Registrant name, plate, odometer, Passenger and Fit ticked, the signing officer and date in place. The registrant's RIN and address come from Program settings (`company_rin`, `company_address`), empty on the local stack; section 7 (insurer, policy) is written at the counter |
| SR-LV-012 | Supplementary Application: two registrants (Co-Registrant: the owner and CarmaCars) | fillable | 47 | 24 | Section 1 and the two members of section 2 filled for the Co-Registrant method only (`when`), the owner's drawn signature in its two boxes, dates as YYYY/MM/DD |
| ON00453 | Proof of Business Address: a corporation's RIN (the owner's corporation under a Lease method) | laid out (pure XFA, coordinates) | 34 | 16 | "New" ticked when the corporation has no RIN, the corporation, the contact person, phone, email, licence, the address and the signature drawn in their boxes. The province box is left empty: the laid-out form already prints "Ontario" there |
| 013-1155 | Sworn Statement for the Transfer of a Used Vehicle (retail sales tax exemption) | fillable | 27 | 10 | Recipient (the corporation), donor (the owner), cities, year, make, model, VIN. Sworn before a commissioner, so it is printed and signed in person |
| 013-0169 | Addendum: the exemption between a corporation and its shareholder | fillable | 11 | 7 | Seller (the owner), buyer (the corporation), the address with the unit as 1204, telephone. The province drop-down and the relationship are left for the owner |

Every value lands in its box at 70 dpi; nothing overflows. What an Admin still does: open Admin > Settings > Forms, press
"Download a filled preview" for one real car per form, and press "Checked: use for owners".

## 6. Signing, simply

The owner asked for signing that is easy, pre-filled and short. Every signing flow was audited:

| Flow | Before | After |
| --- | --- | --- |
| Owner program agreements and schedules | One page, every document's full text on screen, three confirmations ticked one by one, initials typed, signature drawn or the full name typed exactly, Sign all 2 | **One package for everything the owner signs on screen** (agreements, schedules, Forms A and B, the official forms that are ready, the partner agreement for a partner): "2 of 5 signed" at the top, a short list of the key values with a Fix link each, the full texts one tap away, one tap ticks the three confirmations (initials filled in from the name), the legal name on file is the signature (drawing is one tap away), one button |
| Forms A and B | A page each: draw or type the name, tick, Sign (two pages, two signatures) | In the package (one signature); their own page uses the same short form |
| Official registry forms | Their own page each: draw, Sign and save | In the package when ready: the browser fills and signs each with the package's signature (a typed signature is drawn in a handwriting style); their own page still works |
| Partner agreement | Read the full text, draw or type, tick, Sign | Key values, the text one tap away, Sign |
| Rental agreement | Four statements ticked one by one, draw or type the name, Sign | The key values with where to fix them, the agreement one tap away, "All four" ticks the four statements (each stays on screen), the name on file is the signature, Sign |
| Investment and staff agreements | An Admin uploaded a PDF; the person opened it, chose legal advice, typed initials, drew or typed, ticked, Sign | **Generated from the record** (investor and investment terms; staff profile with the settings' defaults), the Admin confirms the values and sends in one click (uploading stays possible); the person sees the key values, every open document is signed with one signature, legal advice chosen with one tap, initials filled in |
| Pre-authorized debit | The account holder typed | The account holder filled in from the owner (the bank details and the mandate stay with the processor) |
| Booking amendment | One tick, draw or type, Accept and sign | Unchanged: already one tick and one signature |
| Forms C and D | Download, print, sign with witnesses, upload a scan | **Still on paper**: the forms call for witnesses who sign in person (one for C, two for D), and Form D is a power of attorney, which Ontario's Electronic Commerce Act leaves out of electronic signing (also an open question for the lawyer in `docs/source/payment_esign_setup.md`). Now every spot to sign or initial is marked (SIGN HERE, INITIAL HERE; CarmaCars' Part 2 of Form D left unmarked), and "Take a photo of the signed page" opens the phone's camera directly |

Taps, measured in the end-to-end tests (desktop 1440 and phone 375):

| Flow | Before | After |
| --- | --- | --- |
| Owner: agreements, schedules and Forms A and B | 3 pages; about 16 taps, initials and the full name typed three times (or three drawings) | 1 page; 3 taps (Check and sign, All of these, Sign all). Recorded time from opening to signed in the test: 5 seconds (`signing_packages.seconds_to_sign`) |
| Renter: rental agreement | 6 taps and a drawing or the name typed | 2 taps (All four, Sign) |
| Investor | 6 taps, initials and the name typed | 3 taps (legal advice, Schedule C, Sign) |
| Staff | 4 taps and a drawing or the name typed | 1 tap (Sign) |

**Evidence kept.** Each document is still signed by its own function and keeps its own signature record: the time, the IP
address, the device, the method, the typed name or the drawn image, the document's SHA-256 (checked against the document
opened) and its consent text. The rental agreement's records stay append-only. What is new (0049) is the package:
`signing_packages` (who, the method, the consent, IP, device, the seconds from opening to signing) and
`signing_package_documents` (each document's signature record, its SHA-256 and the consent shown for it: "I sign
<document> with the one signature I gave for these N documents: ..."). A package is recorded only after every one of its
documents carries a signature by that person, with the package's method, from the last half hour.

## 7. Guide upkeep and the guides

- **Upkeep** (`web/scripts/guide-upkeep.mjs`, the `guides` workflow with `upkeep` on, 0049): the new screenshots are
  cropped as the guides crop them (`docs/guides/src/export.py` into a folder of its own), each is compared with the image
  the live guide shows now (the committed one, or the latest replacement), perceptually (160 pixels wide, grey, the mean
  difference above 3%, or a different shape). A changed one goes to `POST /api/jobs/guide-upkeep` with the jobs' token: it
  is stored in the public bucket, put in place of the old image in every draft and published copy (the guide's version
  goes up, so its PDF shows as older), and its sections are flagged "Needs review" with the old and new image.
- **Admin > Settings > Guides** shows "To review" per guide; the section shows both images, **Suggest a text update**
  (Workers AI vision, the same daily allowance as the toll reader; the fake model locally), **Use this text as the
  draft**, **Dismiss the suggestion** and **Mark reviewed**.
- Checked on the local stack: the 119 current screenshots compared with the committed crops, 119 unchanged (the crop and
  the comparison are stable).
- **Guide text** updated for every feature of this work (`docs/guides/src/guides/*.py`, exported to `docs/guides/content`,
  HTML and committed PDFs rebuilt): Owner (sign everything at once, Forms C and D with the phone camera, the partner
  agreement, insurance reminders), Renter (sign: All four, the name as the signature), Investor, VA and Field (documents to
  sign), Admin (partners and insurance reminders, owners signing at once, Forms C and D photos, official forms' drafts and
  what each is for, agreements generated from the records, keeping the screenshots current). 0048 adds the three new
  chapters of 0046; 0049 updates the ten changed chapters on the live site: a chapter still showing the text that was
  shipped (checked by its MD5) gets the new text, published; a chapter an Admin edited keeps the Admin's text and gets the
  new one as a suggestion to review.

## 8. Actions minutes

The repository is public, so minutes are not billed; runs stay short all the same (`docs/ci-minutes.md`). Push runs the
fast gates only; the guide upkeep is part of the manual `guides` run (about 20 minutes), not of every deploy.

## 9. Tests

- `30_supply_manual_rentals.sql` (104) and `31_signing_upkeep.sql` (56): agreements generated from the records (facts,
  numbering, template version, summary), signing packages (refused before signing, for someone else, with another method;
  recorded with each document's own record and consent; the signature evidence unchanged), the owner's checklist, partner
  insurance reminders (once per expiry, closed by a new expiry), guide upkeep (replacement in drafts, published text and
  HTML, the flag, the version, suggestions, applying, the chapters CarmaCars updated), the vision gate for guide review,
  the official form sources, privileges.
- End to end at 375 and 1440 with axe and the copy rules: Add a car (partner and company), Admin > Partners, Add a rental
  (Admin; customer service within its limits), the renter signing a rental added by hand, retire and restore, delete, the
  sample cars page, the partner portal signing; the owner signing everything in one package (adopted name on the phone,
  drawn on the desktop) with the package recorded; the renter signing with All four; Forms A and B in the package; the
  investment agreement generated from the record and signed in the investor portal ("0 of 1", then "1 of 1 signed"); the
  staff agreement drawn in the VA portal.
- Unit: the generated agreements leave no blank and fill Schedule A (`model.test.ts`).

## 10. Deploy and checks

| What | Run | Result |
| --- | --- | --- |
| Push CI (fast gates: database suite, text check, lint, types, unit, generated types) | 38887121046, 38890504066, 38892706617, 38901840443 | Green. The earlier pushes of this work (38870923964, 38876089670) had failed on the text check (the official forms' en dashes) and a lint warning |
| Deploy with the full suite (end to end at 375 and 1440 with axe, links, copy lint, crawl as every role, SEO, emails) | 38895943872 | Green: 175 end-to-end tests passed (15 skipped by design), crawl, SEO and emails 0 problems; 4 migrations applied (0046 to 0049); carmacars.ca, /cars and photos answer 200 |
| Earlier deploy attempts | 38891322802 (cancelled: the crawl found Sales' 404, fixed), 38892715244 (a contrast check measured a button mid-hover; the test now waits) | Not deployed |
| Guides workflow with upkeep | 38899642454 | Green: 206 screenshots; 98 compared with the live guides, 81 changed (3% to 24% different: the screens changed since the October 15 shots) and replaced in the live guides; 29 sections flagged for review (Admin 10, VA 6, Owner 5, Renter 5, Investor 3, Field 0) |
| 0050 (one guide version per run), deployed with checks off (SQL only) | 38902459100 | Green: 1 migration applied, history 50 rows |
| guides-pdf | 38901851864 | Green: the six PDFs printed from the published guides and stored |
| verify, full | 38903085430 | Green: every check passed (pages, headers and nonce, sign-in as every portal, view as, invitation, reset and confirmation links, sign-up paths, the guide in every portal, owner debit, tolls and forms, SEO). The first full verify (38899680158) failed on timeouts while the Worker hit Error 1102; the run before this work (38863629274) failed the same way |
| Deploy of the style fix (the progress list on a phone) | 38904582980 | Not deployed: the statement test picked the company fleet's owners row (no owner statement) when the supply tests ran first. Admin > Statements > Build one no longer lists the company fleet and marks partners; the test leaves it out |

**Error 1102 (separate).** Cloudflare stopped 211 requests in 24 hours with Error 1102 (the free plan's 10 ms CPU limit;
19 in the last hour of the verification). The verification loads such a page again; a sign-in step that meets several in
a row times out, which is what failed the first verification. Workers Paid removes the limit.

## 11. What still needs the owner

- The lawyer: the partner agreement draft, and whether the generated investment agreement may be sent (its source,
  `docs/source/v2_investment.md`, still says "Draft for legal review. Not for signature"); whether a witness signing
  electronically in person is enough for Form C (Form D stays on paper either way).
- Admin > Settings > Forms: check each official form with a real car and press "Checked: use for owners"; fill in
  `company_rin` and `company_address` in Program settings (the registrant on SR-LV-006 and SR-LV-012).
- Program settings: confirm the staff agreement defaults (rate, hours, platform, trial period) and the partner commission
  and insurance warning days.
- Admin > Settings > Guides: 29 sections show "To review" after the first upkeep run (the screenshots are already new):
  read each against its new screenshot, use a suggestion if it helps, mark it reviewed, publish.
- Run `guides` (upkeep) after deploys that change screens, then `guides-pdf`.
- Error 1102: Workers Paid removes the CPU limit that times out a few requests a day.
