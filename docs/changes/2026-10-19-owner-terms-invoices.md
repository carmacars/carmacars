# Owner terms and invoices, cars added for owners (October 19, 2026)

Migration `supabase/migrations/0067_owner_terms_invoices.sql`, tests `supabase/tests/46_owner_terms_invoices.sql` (56
assertions), end to end `web/tests/e2e/owner-terms.spec.ts` (4 tests, 375 and 1440), emails `owner_invoice_issued`,
`owner_invoice_voided`, `owner_schedule_resign`, `owner_car_set_up`. No earlier migration was edited; the functions it
changes are wrapped (renamed with the suffix `_pre_ot`) or replaced with the same signature.

## 1. What the owner asked

> When approving an owner, it automatically invoices them for first and last with $904. Each owner will have different
> amounts for insurance and different management fees. I should be able to adjust that. Some owners pay first and last by
> e-Transfer or cash, so I should be able to record that manually. Under each owner and application there should be a way
> to look at the invoices that have been sent, customize them, and create separate amounts, e.g. registration fees down to
> the exact amount, as well as the first and last we agreed on.

Then, in the same release: Admin and staff (customer service and fleet) add a car for an owner on their behalf, so owners
never have to fill in the application themselves.

## 2. Negotiated terms

| Item | Now |
| --- | --- |
| What can be negotiated | Insurance Fee (monthly), Revenue Share (the management fee), Tracker Fee, Install Fee, the first and last month amount (default 2 x the Insurance Fee, or any exact amount), one-off fees (description, amount, HST) |
| Where | `owner_terms`: a row per owner (the default for their cars) or per car, each with `effective_from` and `effective_to`; rows of one scope never overlap |
| Precedence | `app.owner_terms_resolve(car, day)`, field by field: the car's row, then the owner's row, then the owner's most recent other car's schedule ("Add another car"), then the standard grid and Program settings. The management mode overrides (no share on Self-Managed, no fees on Turo-Only) |
| Into the agreement | Before the Vehicle Schedule is signed, saving a car's terms writes the schedule at once (`vehicle_schedules.first_last_cents`, `one_off_fees` added) and withdraws the owner's open signature requests, so the documents are made again from the records and nobody signs old numbers |
| After it is signed | Saving warns: "Vehicle Schedule VS-... was signed on ... New terms need an updated Vehicle Schedule signed by the owner". One click (`confirm_resign`) creates the new version (`vehicle_term_changes`, awaiting signature) and emails the owner (`owner_schedule_resign`). The owner signs it in the portal (`/owner/sign/schedule/<id>`: typed legal name, the confirmation, the SHA-256 of the text on screen; CarmaCars countersigns under the standing authorization), or an Admin records it signed on paper, or withdraws it. Signed: a new schedule supersedes the old one and `vehicle_fee_history` runs the new terms from their date, so monthly invoices, debits and statements use them |
| Screens | Admin > an owner > Terms tab: the owner's terms (with history) and each car's (what applies and where each value comes from, versions, the update waiting for the owner) |

The older path that issues the first and last month invoice (the owner page's Issue, and signing) now bills the agreed
amount when it is not 2 x the Insurance Fee.

## 3. Approve: "Terms and first invoice"

Approve no longer issues anything by itself. It opens a step per car, pre-filled with the negotiated terms (or the grid),
editable to the cent, and the invoices to make:

| Invoice | Choices |
| --- | --- |
| First and last month | The agreed amount; split into the first and last month lines (the prepaid months come from them when paid) |
| Registration fee | Any exact amount, HST on or off |
| Tracker install | Its own invoice; offered only when Program settings say trackers are available (refused by the database otherwise) |
| Another invoice | A title and a line |

Each one: Send now (issued and emailed), Save as draft (never emailed or debited), or Already paid (issued quietly, then
recorded with 0044's `record_manual_payment`: method e-Transfer, cash, cheque, bank transfer or other, date, reference,
amount; the owner gets the receipt `owner_payment_recorded`, not an invoice email). Nothing is set or sent until the Admin
presses Approve; a refused approval (for example an e-Transfer without its reference) changes nothing. Approve without the
step's values (the database call with no `cars`) sets the terms and makes no invoice.

## 4. Owner invoices

| Item | Now |
| --- | --- |
| Kinds | `upfront`, `monthly`, `tracker_install`, `adjustment` as before, plus `custom` (any amount) and `credit_note` |
| Draft | Line by line: description, quantity (2 decimals), unit amount to the cent, HST on or off per line, a note; the invoice's title, notes and due date (empty: `owner_invoice_due_days` after issue, 7). A draft is never in the owner portal and never debited (`owner_debit_block`: "the invoice is draft") |
| Issue | Draft to issued: the email (`owner_invoice_issued` for a custom invoice or credit note; the upfront and monthly emails as before) |
| Never edited in place | The screens refuse it, and a trigger on `owner_invoice_lines` refuses any change or deletion of a line of an invoice that is not a draft ("Void it with a reason and issue a corrected one") |
| Void | A reason (the owner reads it); a draft, or an issued or failed invoice with nothing paid or deducted. Its scheduled debit is cancelled, a prepaid month it used is released, the upfront link is cleared, the owner is emailed (`owner_invoice_voided`; not for a draft). "Make a corrected invoice" copies the lines into a new draft (`replaces_invoice_id`) |
| Paid invoice | Void the payment first (0044), or issue a credit note (its own number, negative, linked by `credit_for_invoice_id`) |
| Resend | The invoice email again (`email_count`) |
| PDF | `/files/owner_invoice/<id>`: every line with quantity, unit and HST, totals, payments, a void; rendered on each request, never stored. The owner downloads their own issued invoices; Admins and Finance any |
| Where | Admin > Money > Owner invoices (filters Drafts, Open, Partly paid, Paid, Failed, In arrears, Void, and search); the Invoices tab of every owner page and every application page; each invoice's page (`/admin/invoices/INV-...`) with lines, payments and receipts, manual payments, debits, emails, history, and Issue and email, Void, Credit note, Resend email, PDF, Record payment |
| Debits | `owner_debit_kinds` includes `custom` (an issued registration fee is debited like any other issued invoice; Admin can remove it in Program settings). Only issued or failed invoices are ever debited (0037, unchanged, tested). A payment recorded by hand stops the debit for that amount (0044, unchanged, tested) |
| Owner portal | Each invoice shows the exact lines (with quantity and unit when not 1, "no HST" when off), the title, notes, due date, a void with its reason and the invoice that replaces it, and Download PDF |

## 5. Cars added for an owner

`/admin/owners/add-car` (Owners and partners > Add a car for an owner; "Add another car" on an owner's page; Cars > Add a car >
A program owner's car now points here) and `/va/owners/add-car` (customer service and fleet).

- The owner: found by name, email or phone, or a new one (type, name, email, phone, address).
- The car: VIN decode, details, the ownership permit, insurance slip and lender information uploaded (filed as the owner's
  documents); photos optional (the listing's sample photos until real ones).
- Terms and first invoice: the Approve step's values; for another car of the same owner they start from that owner's
  terms (their row, or their other car).
- Who sourced the owner: "Entered for CarmaCars" (default) or "I sourced this owner"; only then is the owner recorded as
  recruited by that staff member (`owners.recruited_by`, `owner_applications.sourced_by`). A staff entry is never the
  owner's own application (`source = 'staff'`).
- The same records as the owner's own application (`app.submit_owner_application`), marked "Entered by staff: <name>",
  audited (`staff_add_owner_car`). The owner's application emails are not sent (their events are closed with a note).
- An Admin's entry is approved at once. An assistant's waits in Applications as New with a task for an Admin, the
  proposal (`owner_applications.plan`) filling the Approve step.
- At approval the owner gets one email, `owner_car_set_up`: "We set up your car: review the details and sign". An owner
  with no sign-in gets one made at that moment and the one-time link to choose a password in the same email (the auth
  adapters' new `accountLink`: Supabase's `admin/generate_link`, nothing sent by Supabase). The owner signs on paper
  instead: no email, and the paper signatures are recorded as in 0044. "Send the set-up email again" on the application.
- The owner reviews and corrects before signing (`/owner/review`): phone, address, and each car's plate, colour,
  odometer, insurer and lender, with the agreed terms shown; a correction withdraws the open signature requests and raises
  a task for staff. Once signed, they message CarmaCars instead.

## 6. Existing data: the invoices already issued at the default

Found on the live database on October 19, 2026 (read only; nothing was changed):

| Invoice | Owner | Application | Status | Amount |
| --- | --- | --- | --- | --- |
| INV-1044 | Mahad Hussain | OA-1001 | issued, unpaid | $1,017.00 (2 x $450.00 + HST) |
| INV-1045 | Celeste Rodriguez | OA-1002 | issued, unpaid | $1,017.00 |
| INV-1046, INV-1047, INV-1048 | Karan vakil | OA-1003 | issued, unpaid | $904.00 each (2 x $400.00 + HST, the 3-car grid) |
| INV-1049, INV-1050, INV-1051 | max gorin | OA-1004 | issued, unpaid | $904.00 each |

They stay as they are. Where an owner agreed another amount: Admin > the owner > Invoices > the invoice > Void ("Make a
corrected invoice" ticked), fix the amount, Save and issue (or record the payment received). The owner is emailed by
those actions, so they are left to the Admin.

## 7. Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `07_notifications.sql` | catalogue 163/4, 73 link paths | 167/4, 76 | the four emails and `owner_review`, `owner_schedule_sign`, `owner_invoices`; the completeness block emits the four |
| `34_admin_redesign.sql` | approve issues 1 invoice | approve with no invoice confirmed issues 0 | Approve no longer invoices by itself |
| `web/tests/e2e/legal-admin-redesign.spec.ts` | Approve approved at once | Approve opens the step; the step's Approve approves | section 3 |
| `web/src/lib/schema-marker.ts` | 0066 | 0067 | the new migration |

## 8. Guides

Admin (Owners and onboarding: Decide on an application, Add a car for an owner, An owner's page, An owner's terms; Owner
money: Owner invoices, Make, edit and issue an invoice, Correct an issued invoice; the menu), Owner (How your fees work,
We set up your car for you, Sign an updated Vehicle Schedule), Assistant (the menu, Add a car for an owner). Exported to
`docs/guides/content`; the migration publishes the 7 changed chapters (`supabase/seed/owner_terms_gen_guides.mjs`).

## 9. Tests and runs

| Check | Result |
| --- | --- |
| Database (`scripts/test.sh`) | all files, 0 failed (`46_owner_terms_invoices.sql` 56) |
| Unit (`npm run test:unit`) | passed |
| End to end, local, 375 and 1440 | `owner-terms.spec.ts` 4 of 4 at both widths; `legal-admin-redesign`, `owner`, `supply-rentals`, `guides-manual`, `debit`, `admin` passed |
| Emails (`emails/check.mjs`) | passed (screenshots are made by CI) |
| Text check, guide labels, lint, types | passed |
| Deploy and verify | see the record below |
