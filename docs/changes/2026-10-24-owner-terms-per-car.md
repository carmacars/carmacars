# Owner terms per car (October 24, 2026)

Migration `supabase/migrations/0135_owner_terms_per_car.sql`, tests `supabase/tests/85_owner_terms_per_car.sql` (39
assertions after the follow-up, see section 9), end to end `web/tests/e2e/owner-terms-per-car.spec.ts` (2 tests, 375 and 1440) and the changed
`owner-terms.spec.ts`, unit `web/src/features/owner-billing/terms-shared.test.ts`, the email `owner_fee_change_notice`
(lower amounts and the management fee). No earlier migration was edited; the functions it changes are wrapped (renamed
with the suffix `_pre0135`).

## 1. What the owner asked

> When a car owner applies or they're registered, is there an easy way to set the percentage for host management fee
> and set their monthly insurance amount per car?

Each owner has terms agreed per car: Insurance Fee ($ a month), Tracker Fee ($ a month), management fee (Revenue Share,
%), Install Fee, Management Mode and Onboarding Method. They live on each car's Vehicle Schedule; the terms in force over
time live in `vehicle_fee_history`, which invoices, debits and the split read.

## 2. One terms editor per car

| Where | What |
| --- | --- |
| Admin > an owner (Overview, at the top, and the Terms tab) | Cars and terms: one row per car with its Insurance Fee and Tracker Fee a month, management fee, Install Fee, mode and since when they apply, its state (Not approved yet, VS-... not signed yet, Signed VS-... with the date, Shareholder) and any change coming. Edit turns the row into fields; Review shows each value before and after and what happens, nothing saved; Confirm applies it. History: every period of terms and every change with its notice |
| Admin > a car > Records | The same editor for that car (it replaces "Fee change notice", which covered the two fees only) |
| Approve (Terms and first invoice) and Add a car for an owner | Already filled in per car from the car's negotiated row, then the owner's terms, then their other car, then the grid and Program settings (0067's `owner_terms_resolve`); now with "Use these terms for every car" when an application has several cars. A car's row edited in the table before approval is what the Approve step starts from |

The per-car form of the Terms tab (and its warning and one-click updated schedule) is replaced by the table. The owner
Overview keeps "Set the terms" for a car whose terms are open (it creates the Vehicle Schedule with the method, the
owner's lien and special terms); the amounts are then edited in the table. The Terms tab keeps the owner's default terms
(for cars whose terms are set later) and each car's first and last month invoice.

## 3. The rules (`app.car_terms_change`)

| The car | A value changes | What happens |
| --- | --- | --- |
| Not approved yet | any | Kept as the car's negotiated row; the Approve step starts from it |
| Approved, Vehicle Schedule not signed | any fee, the Install Fee | Written into the unsigned schedule at once (0067's `owner_terms_save`); the owner's open signature requests are withdrawn so the documents are made again with these numbers. No notice, no new version |
| Approved, not signed, terms open (intake, terms set) | Management Mode, Onboarding Method | Through 0022's `set_vehicle_terms` (schedule, car and onboarding plan); a Self-Managed car has no management fee, a Turo-Only car no fees |
| Signed and enrolled | lower Insurance Fee, Tracker Fee or management fee | In force from today or the date chosen (never earlier); a `decrease` change, fee history source `owner_benefit`; the owner is emailed the written notice. No notice period: it only lowers what the owner pays or what CarmaCars keeps. A lower management fee does this only while Program settings "Lower management % without owner signature" (`owner_lower_share_without_signature`, default on) is on; off, it is an updated Vehicle Schedule the owner signs, in force from the date once signed |
| Signed and enrolled | higher Insurance Fee or Tracker Fee | Written notice of `fee_change_notice_days` (30), Enrollment Agreement 4.8: a `fee_notice` change and its dated fee history row; the reason is required (the owner reads it) |
| Signed and enrolled | higher management fee | The same notice, extended to the management fee, and an updated Vehicle Schedule for the owner to sign (4.8: "a Revenue Share changes only in writing signed by both parties"), through 0067's signing in the portal or on paper and CarmaCars' countersignature. It applies from the notice date once signed, or from the day signed when that is later (never back-dated). Higher fees in the same change apply from the date by the notice either way; the signed schedule then takes their place |
| Signed, not enrolled yet | lower | An updated Vehicle Schedule issued at once by CarmaCars (enrollment opens the fee terms from the current schedule) |
| Signed, not enrolled yet | higher | An updated Vehicle Schedule for the owner to sign, from the day signed |
| Signed | Install Fee, Management Mode, Onboarding Method | Refused with the reason: the Install Fee is billed once before enrollment (change the invoice), the mode is the schedule's |

One change at a time per car: a change that has not started yet, or an updated schedule waiting for the owner, must be
cancelled (or signed) first. `app.car_terms_cancel` cancels a lower or higher amount whose date is still ahead (its dated
terms are removed and the terms before it run on) and withdraws a waiting schedule (0067's `schedule_change_admin`).
A shareholder-owned, company or partner car has fixed terms and is refused.

## 3b. The car page's old "Fee change notice" (a crash on main)

On main, Admin > a car > Records > Fee change notice failed with `invalid input syntax for type uuid`: 0030's
`admin_act` (`0030_admin_portal.sql` lines 878 to 881) stored the jsonb that `app.give_fee_change_notice` (0022) returns
in a uuid variable, so no Admin could give a fee notice. In this branch the button is replaced by the terms editor, and
the action itself (`admin_do` `fee_change_notice`, for any caller left) is routed to `app.car_terms_change` with the same
rules: a higher fee by written notice from the date given (30 days at the earliest), a lower one from that date or today.
Tested in `85_owner_terms_per_car.sql` section 10.

## 4. The written notice

- Email `owner_fee_change_notice`: one per part of a change (the lower amounts from their date, the higher ones from the
  notice date). Its lines now include the management fee; `is_decrease` (new) says "Lower amounts: no notice period is
  needed" and leaves out the exit sentence; `is_share_change` is true for a higher management fee (sign the updated
  schedule). A higher management fee also sends `owner_schedule_resign` (the link to sign). The catalogue row is
  regenerated (`supabase/seed/0135_gen.mjs`).
- Document: `/files/terms_notice/<change>`, a PDF (`app.pdf_facts` kind `terms_notice`) with the owner, the car, the date
  of notice and the effective date, before and after, the clause it relies on, the reason and CarmaCars' signature line
  (and the owner's signature once they sign). The owner downloads their own; Admins and Finance any (`app.file_access`).

## 5. Which terms apply to which car, and from when

- Admin: the table's Since column, the change coming in the row, and History (periods from fee history with why: the
  Vehicle Schedule, a written notice, lowered; before signing, the car's negotiated rows).
- Owner portal: Vehicles has "Your terms, car by car" (Insurance fee and Tracker fee a month, Revenue Share, since, what
  is coming, the link to sign); each car's Terms card has the terms in force, what is coming and History with Download the
  notice. The owner portal's vehicles now show the terms in force (`owner_portal_vehicles` reads fee history), so a lower
  amount shows the day it starts, not only the signed schedule's numbers.

## 6. Statements and billing by effective date (checked)

| Item | Before | Now |
| --- | --- | --- |
| Monthly owner invoice (`generate_owner_invoice`, 0029 and 0046) | The whole month at the terms in force on the billing day: a change on the 15th waited for the next month | When fee history has more than one rate inside the days billed, the Insurance Fee and Tracker Fee lines are billed per day at each rate ("14 days at $450.00, 17 days at $300.00"); a prepaid month applied never exceeds the Insurance Fee billed. One rate: unchanged |
| Revenue Share of a rental (bookings 0011, 0016; split 0007; manual rentals 0025; Turo trips 0033) | The share in force on the day the rental is booked (or the trip ends, for Turo), stored on the booking | Unchanged and tested: a confirmed booking's split never changes (`booking_before_write`). A change of the management fee applies to rentals booked from its date |
| Owner statements | Read the split stored on each rental and the invoices | Unchanged |

## 7. Decisions

- A lower management fee applies without the owner's signature: CarmaCars gives up part of what it keeps, by written
  notice it signs. A higher one always waits for the owner's signature. This is the Program setting "Lower management %
  without owner signature" (Admin > Settings > Program, Owners and fleet), on by default. **Lawyer approved (October 25, 2026): the setting stays on.** For the record: clause 4.8
  of the Enrollment Agreement says "A Revenue Share changes only in writing signed by both parties", which on its words
  covers a lower share too. If the lawyer reads it that way, turn the setting off: a lower share then waits for the
  owner's signature like a higher one (lower Insurance and Tracker Fees still apply by notice, which 4.8 allows).
- Lower amounts and Fee notices change the dated terms, not the signed schedule (as 0022's fee notice always did); the
  notice is the written record. Only a higher management fee (or any change before enrollment) makes a new schedule
  version.
- A cancelled change does not email the owner; tell them if the notice was already sent.

## 8. Existing assertions changed

| File | Was | Now | Why |
| --- | --- | --- | --- |
| `web/tests/e2e/owner-terms.spec.ts` test 3 | The Terms tab's per-car form: $410.00 on a signed car, the warning, one click for the updated schedule | The terms table: $460.00 (higher) on a signed car not enrolled: the review, the reason, the updated schedule; the owner signs $460.00 | The per-car form is replaced by the table; a lower amount no longer needs the owner's signature |
| `web/src/lib/schema-marker.ts` | 0131 | 0135 | the new migration |

## Guides

- `admin/owners-and-onboarding`: An owner's terms, car by car (the table, Review, the rules, History, Cancel), An owner's
  page (Cars and terms), Decide on an application (Use these terms for every car), Add a car for an owner.
- `owner/fees-payments-and-payouts`: How your fees work (your terms car by car, notices, lower and higher amounts, a
  month billed per day at each amount).

Exported to `docs/guides/content`; the migration publishes the 2 changed chapters (`supabase/seed/0135_gen.mjs`).

## 9. Tests and runs

| Check | Result |
| --- | --- |
| Database (`scripts/test.sh`) | ALL TESTS PASSED (`85_owner_terms_per_car.sql` 44: the fee change notice action and the setting added) |
| Unit (`npm run test:unit`) | 543 passed |
| Types, lint, text check, guide labels, `check-change-guides`, `0135_gen.mjs --check` | passed |
| End to end, local, 375 and 1440 | `owner-terms-per-car.spec.ts` 2 of 2 at both widths; `owner-terms.spec.ts` 4 of 4 at both widths (one run each; under a machine load of 20 to 30 some reruns timed out at different steps); `owner.spec.ts`: the owner billing test needs "Set terms (standard grid)" on the owner Overview, kept after the first run removed it; `admin.spec.ts` and the owner sign-in refusal timed out under load (sign-in page), not rerun after the last build (the disk was full) |
| Emails (`emails/check.mjs`) | passed except the screenshots, made by CI |

## 10. Not done

- Changing the Management Mode of a signed car (a new schedule and onboarding plan); the editor says so.
- An email to the owner when a change that was noticed is cancelled.
