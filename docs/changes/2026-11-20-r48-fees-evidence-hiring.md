# Evidence for every fee, return charges, the dispute kit, the hiring funnel, owner use, data checks, agreement first (Release 48 part FE: 3190 to 3199)

Migrations `3190_r48fe_return_charges_evidence.sql`, `3191_r48fe_hiring_onboarding.sql`, `3192_r48fe_dispute_kit.sql`, `3193_r48fe_connector.sql`,
`3194_r48fe_guides_academy.sql` (generated guides block: `supabase/seed/3194_gen_guides.mjs`), `3195_r48fe_owner_use.sql`,
`3196_r48fe_staff_agreement_needs.sql`, `3197_r48fe_data_checks.sql`, `3198_r48fe_order_terms_install.sql`, `3199_r48fe_notifications.sql`
(catalogue block: `supabase/seed/3199_gen_catalogue.mjs`). Schema marker 3199. Built on r48-mr.
The owner's wording: `almash/work/hotfix-notes/owner-backlog-2026-11-20.md`, 10:32 to 10:47, and the coordinator's later items of Nov 20.

## 1. Agreement charges (3190)

- Rental agreement **10.6 Non-return** ($1,000 + recovery costs: tow, impound, storage, investigator or repossession; the daily rate,
  per-day fees and late fees run until recovery), **10.7 Improper return** ($250 + costs: wrong place, keys not returned, unlocked or
  unsecured, unagreed drop), **10.8 Theft recovery** ($1,500 + costs; the deductible rules still apply), **11.6 Tires and roadside**
  (actual cost + $50 admin; not for a mechanical fault that is not the renter's). Fee Schedule lines; new text version
  `rental-v3-6a79e5ecb2`; updated agreements apply without re-signing (amend_without_signature, and the "terms updated" pop-up, item 9).
  The site's "roadside assistance included" wording is unchanged.
- Program settings `non_return_fee_cents`, `improper_return_fee_cents`, `theft_recovery_fee_cents`, `roadside_admin_fee_cents`; fee
  types `non_return_fee`, `improper_return_fee`, `theft_recovery_fee`, `roadside_admin_fee` (company_only, HST) and `tire_cost`
  (pass-through, like `roadside_callout` and `recovery_cost`).
- `app.return_charge_add` (Admin, Finance, Fleet; ops_do `return_charge_add`; connector `add_return_charge`); the Money tab's **Add a
  return charge**. A non-return or theft incident opens a Fleet To do (`return_charge_due`).

## 2. Evidence for every fee (3190)

- **Registry** `fee_evidence_rules`: per fee type, `requires` (blocks), `gathers` (dispute pack), `sources`, `captured_by` (field,
  fleet, finance) and `capture` (the words of the To do). Late: return time (+ Tracker at return, notices); km/fuel: readings + pickup
  and return photos; toll: the 407 line; ticket: the notice PDF; speeding: the Tracker speed series; smoking/cleaning: 3 guided photos +
  description; damage: close-ups; non-return: final notice with its deadline passed + Tracker; improper: photos or Tracker at return +
  a note; theft: police report/incident + Tracker; tires/roadside: invoice; add-ons, young driver, delivery: the booking record.
- `booking_line_items.evidence_status` (ok, needs_evidence, overridden, not_required) kept by a trigger on every line, so every
  entry point is covered (Checklist/assess_check_in, deposit review, change_booking_fees, toll_read_auto_charge, booking_return_auto_charges,
  speeding, return charges). Evidence arriving later (photos, documents, toll notices, attached evidence) re-checks the booking.
- Missing evidence: a To do (`fee_evidence_needed`; Field's go to the fleet queue titled "Field:") with exactly what to capture; the
  line stays off every statement (`app.issue_booking_statement` replaced; `app.charge_after_rental` wrapped to issue nothing when only
  held fees are new). `app.fee_evidence_attach` (Money tab **Attach evidence**, upload via `server/actions/fee-evidence.ts`; connector
  `attach_fee_evidence`) and `app.fee_evidence_override` (Admin, reason; connector `override_fee_evidence`). Evidence completed after the
  Check-out statement gives Finance `fee_evidence_ready`. The renter's extra-charge email goes only once the fee is on a statement.
- **Return not clean**: the Checklist's Cleanliness evidence step (6 guided shots `clean_*`, 3 required; description; optional video
  up to 40 MB via `/api/field/upload`), enforced by `app.complete_return` after its own checks. Renter self-check-out confirmed by staff
  and Admin record-past-return: the fee stays "needs evidence" with a To do until the photos and description are attached.
- Fixed: the Checklist saved `needs_cleaning`/`pet_hair`, which the database refused; now `cleaning`/`pet` (old values mapped).

## 3. Dispute kit (3192, `web/src/server/agreements/dispute-pack.ts`)

- Per extra charge: clause and signed agreement version (SHA-256; certificate in the pack), the pre-billing notice with delivery
  (status, sent time, provider id), receipts, attached evidence and staff notes, Tracker (speed series, route sketch, return location).
- Cover letter per reason (`features/disputes/letters.ts`, tests per reason code): fraudulent, unrecognized, product_not_received,
  credit_not_processed, duplicate, subscription_canceled, general; reason-specific Stripe fields staged.
- Signing proof plus identity checks (ID, selfie match score), staff notes, renter replies, earlier trips by person or card.
- Photos compressed to fit 4.5 MB (`features/disputes/compress.ts`), never dropped.
- Variants `dispute_packs.variant`: card, etransfer_cash, insurer, small_claims (not staged in Stripe). Auto-built on the Stripe
  dispute webhook (0154 trigger); `dispute_deadline` staff alerts at 5, 2 and 1 days (hourly task hygiene job).

## 4. Hiring and onboarding funnel (3191)

- **Yes, put me in Sales**: `/careers/sales-yes/<token>` (`server_hiring_sales_offer/_yes`): the Sales application from the existing
  one, the AI interview link at once. The referral email (`applicant_referred`) button says so.
- One-time re-send (`hiring_resends`): referred applicants without a Sales application and invited Sales applicants who never
  finished, deduped by email, 6 per 15-minute hiring run (email; applicants have no push).
- **Audit of the 79 to 87 declines**: passing also required the AI's recommendation not "decline" (and "sales" for a Sales applicant
  meant decline), every answer averaging 7 with none under 5 (2695). For Sales the score at the bar (80) decides; still required: no
  knock-out, English not basic, no answer under 4. Other roles keep 2695. Sales declines of the last 30 days that pass now are reopened
  for the auto-decider (hired, onboarding email). 79 stays under the bar.
- Academy nudges (staff alert `academy_nudge`) on day 1, 2 and 4 of no progress; Sales academy counts (Hiring > Pipeline, connector).
- Sales WhatsApp group for anyone who passed a Sales path; member tag "Name - Position" with Copy and steps; "I joined" needs "I set my
  member tag". Empty `whatsapp_team_group_url` / `whatsapp_sales_group_url`: urgent Admin To do and a red box on Hiring.

## 5. Owner use (3195)

- Bug: Karan's Sonata ('onboarding') could not be booked. Every status still in the program is allowed; out of service, retired, or a
  renter's confirmed booking on the dates say why (`app.owner_booking_blocked`).
- "Who's driving?" Me or Someone else (`app.owner_book_for`): the other person is the main driver (Ontario licence rule applies), signs
  with their own link (a primary-driver signer added when the agreement opens); the owner signs too and confirms responsibility
  (`owner_use_ack_at`). Enrollment agreement 9.3 and flat-rate 7.3. Owner bookings stay out of revenue and never block renters.
  Not built: billing owner-use damage/tolls to the owner automatically beyond today's paths (claims, owner invoices, tolls matched to
  the owner).

## 6. Staff agreement needs (3196) and data checks (3197)

- Jamal: the agreement job recorded "licence number missing" and sent nothing. `app.staff_agreement_needs` names what the person gives
  (licence, address) and what CarmaCars sets; the sign pages show it with the inputs; saving sends the agreement at once
  (`sendStaffAgreementNow`). Sign pages route a person to the one their role opens.
- In-person staff with a non-Ontario home address are flagged and asked to confirm (`home_address_outside_ok_at`).
- **Data checks**: registry `data_checks` (one row and one `app.dc_*` function each): staff agreement (blocking), staff licence
  number/expiry (expired: blocking), address outside Ontario/Canada (It's correct + reason), pay details, phone, WhatsApp tag, owner
  phone, renter phone, renter licence expiry, renter licence name vs profile. Pop-up on every staff, owner and renter page
  (`features/data-checks`); warnings dismissed for 24 h; Admin lists per person on Settings > Staff, Owners, Renters with Send reminder.
  Staff licences carry no name on record, so the name check is renters' only.

## 7. Agreement first (3198)

- Order: agreement, academy, WhatsApp, approval (`agreement_locked`, `staff_onboarding_state`, `staff_waiting_on`, `staff_welcome`,
  `requireStaff`). Staff who passed the academy and have not signed are only asked to sign.

## 8. Staff agreement clauses: FOR LAWYER REVIEW

- VA/contractor agreement: confidentiality widened (customer data, pricing, owners, suppliers, systems, business methods); 6.4
  non-competition for contractors only (12 months, GTA, car rental and owner-program businesses); data returned or deleted within 7 days.
- Field staff (employees): confidentiality widened, non-solicitation of customers, owners and staff for 12 months, data deletion;
  **no non-compete** (ESA s. 67.2). Version `person-599a40d532`.

## 9. Updated documents pop-up and install fee (3198)

- The existing gate (0721) is used: versions published for the rental, owner and staff agreements with "What changed"; Accept records
  version, time, IP, device (terms_acceptances, audit_log); **I do not accept** is recorded (`terms_declines`) and keeps the portal
  closed with contact details; `/api/terms` (GET, POST) for the app; Admin > Settings > Terms counts accepted, declined, waiting.
- Install Fee $150: `install_fee_cents` (current settings), `tracker_product_install_cents`, defaults of new owner terms and Vehicle
  Schedules; enrollment agreement Fee Schedule and owner billing spec. Signed schedules keep theirs. The guide PDFs were not re-rendered.

## 10. Notifications (3199) and the definition of done

- Branded emails (CarmaCars): `renter_data_check`, `owner_data_check`, `staff_data_check` (Send reminder). Staff alerts (push and
  in-app, in each person's alert settings): `academy_nudge`, `dispute_deadline`, `data_check_reminder`, `terms_declined` (Admins),
  `fee_evidence_needed` (Admins, Fleet and Finance on duty). Renters get `renter_extra_charge` (existing branded email) once a return
  charge or held fee is on a statement; applicants get `applicant_referred` and `applicant_ai_interview` (existing).
- Not done here, said plainly: the e2e spec `web/tests/e2e/r48fe-data-checks.spec.ts` (data check pop-up with the email queued, the
  Sales one click, owner use for someone else, screenshots at 320/375/768/1280/1440 with long names) is written but was not run: the
  shared machine had 1 GB of memory free and a load of 11, too little for a Next build and the local stack. It runs in the release CI.
  Texts: the renter's and the owner's data check reminder (`sms_templates`); the staff alerts stay push and in-app. The guide PDFs were not re-rendered.

## Tests

- `supabase/tests/99_r48fe_fees_evidence_hiring.sql` (118 assertions): every item above.
- Unit: `features/fee-evidence/model.test.ts`, `features/disputes/letters.test.ts` (each reason code), `features/disputes/compress.test.ts`,
  `features/data-checks/model.test.ts`, `features/academy/gate.test.ts` (new order).
- Base tests updated for the new behaviour: `03_flows` (tire_cost pass-through), `09_operations` (dirty returns carry guided photos),
  `97_deposit_guard` and `99_r33h_finishing` (charge_after_rental wrapped; the toll carries its notice), `11`, `16`, `09` and
  `12` (Install Fee $150), `07_notifications` (the three data check emails), `71_text_alerts` (two texts), `99_r35g_*`, `99_r35k_staff_onboarding`,
  `99_r38_release_fixes` (agreement first; "I joined" ticks the member tag), `99_r43_stricter_ai` (now a Customer Service role:
  Sales is judged by the score at the bar).
- Fixed in review: 3190's statement gate kept 0195's rule that a return recorded "details to follow" can be billed before review.

## Guides

- `admin/hiring`
- `admin/people-and-access`
- `admin/requests-offers-and-bookings`
- `field/a-return`
- `field/start-here`
- `owner/bookings-and-your-own-use`
- `va/finance`
- `va/fleet`
- `va/start-here`
- `va/your-workday`

Published by 3194 (generated by `supabase/seed/3194_gen_guides.mjs`).
