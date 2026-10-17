# Legal review, admin redesign, guides that keep up (October 16, 2026)

Migrations 0052 to 0055. The owner's document "CarmaCars: legal text changes before launch" (every decision final and
approved), the settings it needs, Admin access only for rent@carmacars.ca, listings without photos, a simpler admin
portal with an applications inbox, and user guides that update themselves after every deploy.

## 1. The legal review (0053)

Text versions bumped: rental agreement `rental-v3`, owner agreements `owner-v3` (Enrollment Agreement, Title-Holding and
Lease Agreement, Forms C and D), partner agreement with the approved sections 3 to 11. New versions apply to signings
after the change; signed documents keep the text they were signed with.

### Changed strings (old, then new)

**Billing and pre-authorized debit**

| Where | Old | New |
| --- | --- | --- |
| Payee in the PAD agreement (1.1, 1.2), the PAD confirmation (1.5), the Stripe mandate, every owner billing email (footer and Payee fact) | CarmaCars | [company legal name], operating as CarmaCars (public pages keep CarmaCars) |
| Late Fee rule (PAD agreement, Banking, invoice list and page, `owner_debit_notice`, `owner_debit_setup_needed`, `owner_fee_invoice`, `owner_payment_failed`, PAD confirmation) | If your bank returns the automatic debit of an invoice, we add the $50.00 Late Fee to that invoice once and try again from the 18th, as section 4.4 of your Enrollment Agreement sets out. | If your bank returns the automatic debit of an invoice for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit. |
| Stripe mandate description (1.3) | On the 15th of each month for the fees on your CarmaCars invoices, with notice 10 days before; a returned debit is tried again from the 18th | [company legal name] o/a CarmaCars: fees on your CarmaCars invoices on the 15th of each month, with notice 10 days before. A debit returned for insufficient funds is retried once for the same amount. |
| Invoice page, pay by debit (1.1) | One box: "I accept the pre-authorized debit agreement" | Two boxes. One-time (required): "I authorize [company legal name], operating as CarmaCars, to debit [amount] for invoice [invoice number] from the bank account I give now. I waive pre-notification and any waiting period for this one-time debit." Recurring (ticked, can be unticked): the recurring agreement of 1.2 with the new payee and Late Fee rule; unticked, no mandate is kept |
| PAD confirmation email (1.5) | Summary and link | Summary, the full text of the accepted recurring agreement, and the link |
| Failed debit email (7.4), preview | A $50 late fee applies. We retry on [retry date]. | A $50.00 late fee is added to your next debit. We retry [amount] on or after [retry date]. |
| Failed debit email, total line | We retry on [retry date]: [retry amount] | We retry [amount] on or after [retry date]. The $50.00 late fee is collected with your next debit. |
| Failed debit email, last line | If that fails too, the amount is deducted from this car's revenue at the next payout. | If that fails too, this vehicle goes into arrears. |
| Debit returned for another reason (new email `owner_debit_returned`) | (none: every return was retried) | "The debit of [date] was returned: [reason]" and "Pay this invoice from its page or update your bank account under Banking. We will not debit this invoice again." |
| Void notice (6.2), added | (none) | No late fee applies. If this invoice has an automatic debit scheduled, it is debited on [debit date] for [balance]; otherwise pay it from the invoice page. |

**Signatures**

| Where | Old | New |
| --- | --- | --- |
| Every automatic countersignature (5.3) | Countersigned for CarmaCars automatically ..., in the name of the staff member who proposed, approved or added it | Signed electronically for [company legal name], operating as CarmaCars, by Abbas Al-Mashita, Director, under a standing authorization dated [authorization date]. (method "automatic") |
| Staff on signed documents | Named as the signer | "Proposed by: [staff name]" or "Added by: [staff name]" in the signature record and PDF; never the signer |
| Booking amendment, section 4 | CarmaCars signs this amendment electronically, in the name of [staff], who proposed the change, at the moment the Renter signs it. | CarmaCars signs this amendment electronically at the moment the Renter signs it. |
| Owner signing statement | I have read these documents and I sign them electronically, for myself and for every Owner named in them. | I have read these documents and I sign them electronically. Each Owner named in the Title Schedule signs with their own link (email `owner_cosigner_sign`); the agreements take effect when the last Owner signs. |
| Form C witness | On paper only | May sign on screen in person, on the same device: typed name and "I witnessed [owner legal name] sign in my presence." Form D stays on paper |
| Investment agreements | Countersigned automatically | Not countersigned automatically: "Awaiting countersignature" until the signing officer presses Countersign (Admin > People > Investors, and To do) |
| Paper records | Date and time | The signing date only |

**Owner forms and the Enrollment Agreement**

| Where | Old | New |
| --- | --- | --- |
| Form D, Lien | register and discharge a lien in my favour. | register a lien in my favour, and discharge it only once the registration of that Vehicle is back in my name or in the name of a person I named in writing. |
| Enrollment Agreement 4.4 | If a charge fails, CarmaCars adds the Late Fee for each Vehicle affected and retries on the Retry Date. If the retry fails, it deducts the unpaid amount from the Owner's revenue. | If an automatic pre-authorized debit of an invoice is returned for insufficient funds, CarmaCars adds the Late Fee to that invoice once and may re-present the debit once, for the original amount, within 30 days. The Late Fee is collected with the Owner's next debit or deducted from the Owner's next payout. |
| 4.5 Set-off (new) | (none; the old 4.5 to 4.8 renumbered) | CarmaCars may deduct any amount the Owner owes under this Agreement from any payout due to the Owner for any Vehicle. |
| 4.6 Arrears (new) | (none) | If an invoice remains unpaid 30 days after a failed re-presentment, CarmaCars may, on written notice, remove the Vehicle from the program and transfer its registration back to the Owner at the Owner's cost. Return of the Vehicle is not withheld for unpaid fees. |
| Retry Date | From the 18th | on or after the 18th, within 30 days of the return (the row sits in Schedule B Part 1 of our agreement, where the Retry Date is defined; the owner's document says Schedule A) |

**Renter side**

| Where | Old | New |
| --- | --- | --- |
| A rental added by staff with the saved card | Charged when staff added it | Charged only when the renter presses "Accept and sign"; until then "Awaiting signature", no charge, car not released |
| Renter email (`renter_rental_added`) | (the rental is ready to sign) | Read and sign your rental agreement; your card is charged when you sign. |
| Amendment refund line | ... refunds [amount] ... to the card ending [last 4] | CarmaCars refunds [amount] (HST included) to the card ending [last 4 digits] within 10 business days after this amendment is signed. |
| Protection sold to renters (site, emails, agreements) | "insurance" or "coverage" bought through us | Protection Plan (coverage option 3, "the CarmaCars Protection Plan"); the provider is never named |

**Partner agreement**: the "Draft for lawyer review. Not yet approved for use." line is gone; sections 3 to 11 are the
approved text word for word (bookings and renters, money with the 20% commission unless the car table says otherwise,
insurance and condition, damage and claims, tolls and tickets, information and non-circumvention, liability, ending the
agreement, general). Sections 1 and 2, the car table, the parties and the signature block are unchanged.

### Section 6 tests

| Test | Result | Evidence |
| --- | --- | --- |
| NSF return: one retry, original amount, Late Fee as a separate invoice line, in the next pre-debit notice | pass | `supabase/tests/33_legal_review.sql` (55 assertions), block "insufficient funds" |
| Non-NSF return (account closed): no retry, invoice paused, Admin alerted (task `owner_debit_returned`), owner emailed | pass | suite 33, block "another return reason"; email `owner_debit_returned` |
| Invoice-page PAD flow: two boxes; unticking the second creates no recurring mandate | pass | e2e `owner.spec.ts` (both boxes, the one-time text) and `legal-admin-redesign.spec.ts` (unticked: no mandate), 375 and 1440 |
| Signed PDF: corporate countersignature with the signing officer; staff only as "Proposed by" or "Added by" | pass | suite 33 (signature records), `web/src/server/signature-lines.ts`, e2e `ops.spec.ts` (the amendment countersigned by Abbas Al-Mashita, Director) |
| Two-owner enrollment: two links, two signature records, effective only after both sign | pass | suite 33, block "co-owner"; e2e `legal-admin-redesign.spec.ts` (the co-owner's own page) |
| Staff-added rental: no card charge until the renter signs | pass | suite 33; e2e `legal-admin-redesign.spec.ts` (no payment after adding, one succeeded payment after Accept and sign) |
| Investment agreement "Awaiting countersignature" until the Admin countersigns | pass | suite 33, block "investment" |
| Partner agreement: sections 3 to 11, no draft banner | pass | `web/src/features/legal-review.test.ts` (word for word) |
| String search: no bare "CarmaCars" payee in PAD, confirmation or Stripe fields; no "insurance" or "coverage" for the Protection Plan | pass | `web/src/features/legal-review.test.ts` (the string search), suite 07 (every billing email has the payee) |

## 2. Settings (0052)

Site settings: mailing address "2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2"; street address "1570 Midland Ave,
Toronto, ON" (no postal code; the help text says it will change). Program settings: signing officer Abbas Al-Mashita,
Director; the standing authorization dated the day the migration runs (a trigger dates it whenever the officer changes).

## 3. Admin access (0054)

`site_settings.admin_allowed_emails = {rent@carmacars.ca}` and `admin_test_emails = {verify-admin@carmacars.ca}` (the
automated test account of the live checks). Triggers on `user_roles` and `users` refuse the Admin role to any other
address, and an Admin's address cannot be changed to another. Admin > Settings > Staff and roles shows the list and who
holds the role; the invitation forms no longer offer Admin. Live, before the change: only rent@carmacars.ca and
verify-admin@carmacars.ca held the Admin role, so nobody lost it.

## 4. A listing without photos (0054)

A car can be submitted and published without photos. Its listing shows a sample photo: one from the library
(Admin > Settings > Sample photos: make and model, then make and body type, then body type) or the built-in picture of
its body type (`web/public/sample-photos/`, made by `web/scripts/gen-sample-photos.mjs`), captioned "Sample photo" on the
site. Staff see "Using sample photos" on the car, in Listings and as a line on To do. The plate check does not apply
while a listing has no real photo; the listing copy is still drafted by the AI. Approved real photos replace the sample
at once.

## 5. The admin portal

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Tasks |
| Bookings | Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews |
| Cars | Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars |
| Owners and partners | Applications, Owners, Partners, Owner forms, Paid and signed |
| Money | Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Tolls and tickets, Insurer invoices, Reconciliation, Expenses |
| People | Renters, Staff, Investors, Portals and view as |
| Settings | All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log |

To do (`/admin`) lists, most urgent first, each with its count and one button: owner applications, booking requests,
changes renters asked for, failed payments and payments to record, agreements waiting for countersignature, tolls,
listings, plates not checked, insurance expiring or missing, cars using sample photos; then today's pickups and returns.
The old dashboard is Today > Overview. One search box on every page finds bookings (CC-1042), plates, VINs, owners,
partners and renters. On a phone the menu folds behind one Menu button that says where you are. Keyboard: g then a
letter (g a Applications, g o Owners), / for search. The assistant portal has the same kind of menu: My work (To do,
Today, My scorecard), then the groups of the function.

## 6. Owner applications

Admin > Owners and partners > Applications: one page, chips New, Waiting on owner, Approved, Declined, All. An
application shows the owner, each car, the uploads, four checks (licence, ownership, insurance, lender) and staff notes.
Approve: the owner is active, each car gets the standard terms, the first and last month's invoices are issued, the owner
gets `owner_application_approved`. Ask for something: tick what is needed, an optional message; the owner gets
`owner_application_info_requested` and a task on their portal's home; their answer brings the application back as New
with a task for an Admin. Decline: the reason the owner reads, one email per car. Live: OA-1001 (Mahad's) and OA-1002 show
as New; nobody was emailed by the migration.

## 7. The guides keep up by themselves (0055)

After every successful production deploy the deploy job starts `guides.yml` with `auto`:

1. A one-minute job compares the deployed commit with the commit of the last finished run (`guide_upkeep_runs`) and stops
   when nothing under `web/src` or `docs/guides/src` changed.
2. Otherwise the screenshots are taken on a local stack of the commit and compared with the live guide's (0049); changed
   ones replace the old ones.
3. Every section whose screenshot changed, or that names a button no screen shows (`web/scripts/guide-labels.mjs`, also
   a unit test on the committed guides), or whose menu paths do not match the menu, is sent to
   `/api/jobs/guide-rewrite` with facts read from the code (`web/scripts/portal-facts.mjs`: the menu, the labels of the
   screens the section shows, the closest labels to each missing one). Workers AI (`@cf/meta/llama-3.3-70b-instruct-fp8-fast`,
   temperature 0.1) rewrites it. The checks (every screenshot line kept, every button named exists, no em dash, the brand
   spelled CarmaCars, a sensible length, no task heading lost, the text renders) decide: published at once, with the old
   text kept, or kept as a suggestion under To review. An Admin's unpublished draft is never overwritten. At most 15
   sections a run.
4. The PDFs of the guides that changed are printed again, and the run is recorded with its commit.

Admin > Settings > Guides shows "Changed automatically on <date>" for each guide and section, the last runs, and Revert
on each changed section (the old text comes back, published, as a new version).

The guides were rewritten for this release (the seven groups, To do, search, Applications, sample photos, Admin access,
the debit rules, Form C on screen, two owners, the Protection Plan, Accept and sign, the countersignature, the
assistant's menu); 0055 publishes the 33 changed chapters where the live text is still ours (with the screenshots the
upkeep replaced kept), and keeps them as suggestions where an Admin edited a chapter. The Markdown export now writes menu
paths as **Group** > **Page** (the old export dropped them, so live chapters showed "›*Owners").

## Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`): every migration, every test | 3573 passed, 0 failed (new suites 00, 33, 34, 35) |
| Unit (`npm run test:unit`) | 114 passed (new: the legal review strings, the guide label check, the facts, the rewrite checks) |
| End to end, 375 and 1440 (`playwright test`) | see the deploy record below; new spec `legal-admin-redesign.spec.ts` (14 tests) |
| Emails (`emails/check.mjs`) | all 15 checks passed |
| Text check, link check, copy lint | passed |
| Crawl as every role | see below |
