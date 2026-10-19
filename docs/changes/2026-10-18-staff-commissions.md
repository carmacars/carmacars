# Staff commissions (October 18, 2026)

Migration `0058_staff_commissions.sql`; tests `supabase/tests/37_staff_commissions.sql` (78 assertions); end to end
`web/tests/e2e/staff-commissions.spec.ts` (phone 375 and desktop 1440). No applied migration was edited. The owner's
decisions as finally given (the rates and the owner treatment were corrected twice during the work; this record follows
the last instructions).

## 1. Who sourced a rental

| What | How |
| --- | --- |
| The choice | Every rental, quote and offer a staff member enters asks "I sourced this client" or "Entered for CarmaCars" (`bookings.sales_choice`, `sales_sourced`). Required from staff at the door (`app.ops58`); an Admin's rental without it is entered for CarmaCars |
| Who is credited | 0057's `sales_staff_id` (the person who created the quote or added the rental, or sent the first offer of a website request). Only a sourced booking earns a commission |
| Website requests | Earn nothing by themselves. "I sourced this client" on the offer of a website request is a claim (`sales_claim_by`): Admin To do, "Sourcing claims", "Credit them" or "Not theirs" with a reason (`app.sales_claim_decide`) |
| Field staff referrals | A booking made with a field staff member's referral code credits them as its source (`sales_source = referral`). The referral fee is the same commission (section 3) |
| Admin changes | `app.sales_reassign` changes the person and whether they sourced it, with a reason, kept in the booking's history and the audit log |

## 2. Add a rental, quotes and prices typed by hand

- **Add a rental** for every assistant function (customer service, finance, fleet, sales) and field staff
  (`app.manual_rental_role`). Limits: the rate sheet or a price typed with its reason; the promo codes and payment ways of
  Program settings; never over a clash, never a past rental, a payment received within the single limit; the Deposit
  stays an Admin's. Field staff: the renter's details typed (no renter search; an existing renter is found by email),
  a payment link or the saved card only (they take no payment, Field Staff Agreement 6.1). Pages: `/va/bookings/new`,
  `/field/rentals/new`.
- **Quotes** for every assistant function (`app.staff_quote_create`; `/va/quotes/new`), with a price and its reason.
- **Offers**: an assistant may type the rental charge with its reason on the review screen (`app.va_guard_booking_edit`,
  `app.adjust_booking`). A typed price stays while the car, dates and rate type stay; changing one goes back to the rate sheet.
- **Recorded beside it**: `rate_sheet_rental_cents`, `custom_price_reason`, who and when. **Flags** (`price_flags`), never
  blocking: under `custom_price_floor_daily_cents` a day (no floor by default) or more than `custom_price_max_discount_bps`
  under the rate sheet (20% by default; the owner gave no number, so 20% was chosen). Shown on the booking and in Admin
  To do, "Prices to review", "Mark reviewed" (`app.price_review`).
- The commission is on the rental charge actually charged.

## 3. The commission

| Rule | Implementation |
| --- | --- |
| Rate outside Sales | Customer service, finance, fleet and field staff: `staff_commission_bps`, 10% (field referral fee included) |
| Rate in Sales | Tiers on the rental days of the completed, paid, sourced rentals ending in the calendar month: under 50 days `sales_tier_low_bps` 10%, from `sales_tier_mid_days` (50) `sales_tier_mid_bps` 15%, from `sales_tier_high_days` (100, also the month's target) `sales_tier_high_bps` 20%. The month's tier applies to all of that month's rentals |
| A person's own rate | An Admin may set a flat rate for one person (`staff_profiles.commission_bps`, "Commission rate" on their Sales page, audited) |
| Base | `app.commission_base_cents`: the booked revenue of My sales (rental charge before tax, after discounts, net of refunds and cancellations) |
| Earned | Completed (returned or closed) and paid in full (`app.booking_paid_in_full`: every charge to the renter covered by a successful payment, no unpaid statement), no open dispute |
| None | Cancelled, no-show, refunded to zero, charged back (dispute lost), Owner Booking, own rental (renter or a driver is the staff member by account, email or phone), household rental (the renter at the staff member's home postal code and address, set by an Admin, "Home address"; or an Admin's reversal with a reason) |
| Statuses | `staff_commissions`: accruing (not earned yet), pending approval, approved, paid, reversed, void; clawback rows (negative) and adjustments after a payment |
| Recalculation | `app.commission_retier` on every change of a person's month; once more after the month ends (`app.job_commission_month`, pg_cron `carmacars-commission-month`, which also raises an Admin task) |
| Refunds and chargebacks | Before payment: the amount changes (an approved one goes back for approval) or the commission is reversed. After payment: a clawback of the difference, approved, taken off the next payment. A refund that drops a Sales month under a tier claws back the difference on every paid commission of that month |

Pending amounts show the current tier and the days so far; My sales and the scorecard show "N of 100 rental days" with a
progress bar and "rises to 15% at 50 days / 20% at 100 days".

## 4. Approval and payment

Admin > Money > Staff commissions (`/admin/money/commissions`, and two To do lines): by person (the month, not earned
yet, pending approval, approved, paid), **Approve** one commission or everything of a person that may be approved (a
Sales month only after it ends, when its tier is final), **Record a payment** (e-Transfer, bank transfer, Wise, cash,
another way, or the monthly pay statement; reference, date, note; the net of approved commissions and clawbacks must be
above zero), **Reverse** with a reason, Payments made, Prices to review, Sourcing claims. Nothing is paid automatically.
Emails `staff_commission_approved` and `staff_commission_paid` (and the portal notice) go to the staff member only, at
their own address; tests use their own example.test accounts and the verification accounts stay on the suppression list.

## 5. What the owner statement does now

The existing code (0007, 0016, 0025) already deducted the 20% **field staff** Referral Kickback (first rental of a new
renter referred by field staff) from Owner Revenue, as Enrollment Agreement 8.3 said. Now:

| Car | Treatment |
| --- | --- |
| Program owner's car | Owner Revenue = Rental Charge + mileage overage, less every kickback on the booking: an Owner's Referral Kickback (20%, unchanged) and every staff commission (Sales tier or 10%, field referral fees included), as expenses of the booking **before** the Revenue Share. `booking_splits.kickback_cents` carries the whole deduction (every total and check unchanged); `booking_splits.staff_commission_cents` and `owner_statement_lines.staff_commission_cents` hold the staff part. The owner portal statement and its PDF print "Referral Kickback" and "Staff commission" as separate lines; the statement email reads "Kickbacks and staff commissions deducted" and now prints the amount (0023 printed $0.00 there and counted the rentals at Owner Revenue; fixed in the email's values) |
| Partner's car | Nothing deducted from the partner's share: CarmaCars pays it from its own commission |
| CarmaCars-owned car | A CarmaCars expense; nothing deducted |
| Field staff referral | The 20% field staff Referral Kickback is no longer taken; the 10% staff commission replaces it (deducted as above). Splits not yet on a statement were recomputed; statements already issued are not rewritten |
| A change after a statement | A refund, or the Sales tier recalculated at month end: the Owner's share of the change goes on the next statement as its own line (`owner_deductions` or `owner_credits` of kind `staff_commission_adjustment`) |

Test `02_owner_month.sql` (the worked owner month) now shows booking C2 with a $54.00 staff commission instead of the
$108.00 field staff kickback: Vehicle 1 Owner Revenue $1,796.00, payable $1,047.40, the payout $1,399.15 (was $1,364.05).

## 6. Agreements (for the lawyer)

**Approved by the lawyer on 2026-10-19.** Every change below: the VA agreement, the Field Staff Agreement (7.5 included) and the Enrollment
Agreement's kickback wording (8.1, 8.3, 8.5).

| Document | Change | Version |
| --- | --- | --- |
| Enrollment Agreement (`docs/source/v2_enrollment.md`) | 8.1: Owner Revenue is less every kickback, "each Referral Kickback and each Staff Commission". 8.3: a Referral Kickback is an Owner's referral; a **Staff Commission** (the commission CarmaCars pays a staff member, field staff included, who sourced or referred the booking, at the rates CarmaCars sets) is a kickback; "Every kickback is deducted from that booking before Owner Revenue is calculated" kept. 8.5: the statement lists each Staff Commission; a change after a statement is adjusted on the next | `owner-v3-6cbe11b26f` (was `owner-v3-16beb87986`); signed documents keep theirs |
| VA agreement (`docs/source/va_agreement.md`) | 3.2: the Rate and the commission are the whole payment. New **3.4 Commission**: what sourced means, the Sales tiers and the 10% rate, the Rental Charge, earned when completed and paid in full, none on cancelled, refunded, unpaid or charged-back rentals, own or household rentals, or bookings made after the agreement ends; Admin approval before payment; reversal from the next payment. 6.2: no commission other than 3.4 | person agreements `person-fd48fc2310` |
| Field Staff Agreement (`docs/source/field_staff_agreement.md`) | Section 7 rewritten: 10% of the Rental Charge of each rental sourced (marked or by referral code), the same rules, approval, paid on the next Pay Date; 7.5 a commission refunded after payment was not earned and may be deducted from a later commission as far as the ESA allows. 9.4 "commissions earned" | the same |
| Specifications | `operating_procedures.md`, `owner_billing_spec.md`, `renter_billing_spec.md`, `payment_esign_setup.md`: the kickback lines | |

## 7. Guides

`docs/guides/src/guides/va.py`, `field.py`, `admin.py`, exported to `docs/guides/content`; the VA, field and admin PDFs
rebuilt; 0058 publishes the 13 changed or new chapters on the live guides where the text is still ours (generated by
`supabase/seed/0058_gen_guides.mjs`, base commit `fa97fc9`), and keeps them as suggestions where an Admin edited a
chapter. VA: the menu with My sales and Rentals for every function, a new Commissions chapter, My sales with the tiers,
Add a rental with a typed price and the choice. Field: Add a rental, Commissions, Referrals. Admin: To do lines, Money >
Staff commissions, the booking's credit (sourced, claims, typed prices), a staff member's Sales page, Program settings.
`docs/guides/portal-facts.md` and `web/scripts/portal-facts.mjs` updated; the guide label check passes.

## 8. Tests

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | 3732 passed, 0 failed (new suite 37, 78 assertions; 02, 04, 05, 07, 08, 18, 20, 30, 34 and 36 updated for the new rules: the field referral as a 10% commission, the choice at the door, prices typed by every staff member, Finance and Fleet adding rentals and quotes, My sales for everyone, To do's four new lines, the history kind `custom_price`, the two emails and links, the cron job) |
| Unit (`npm run test:unit`) | 117 passed (the generated agreements, the legal review strings) |
| End to end, 375 and 1440 | `staff-commissions.spec.ts` 4 of 4 locally (typed price and "I sourced this client"; "Entered for CarmaCars"; field staff; completed and paid, pending, approved, paid by hand, refund reversal; the flagged price reviewed; the Sales target on My sales and the scorecard); the affected specs (sales-tracking, supply-rentals, gaps, staff, admin, legal-admin-redesign) 55 passed, 3 skipped by design |
| Emails (`emails/check.mjs`) | all checks passed (2 new emails, 152 in the catalogue) |
| Text check, lint, types, guide labels, 0058 catalogue and guides blocks | passed |

## 9. Deploy and checks

| What | Run | Result |
| --- | --- | --- |
| Push CI (fast gates) | 39193850143, 39197264309, 39200715492 | Green, except 39197264309: test 20's scorecard failed in the first hours of a Toronto Monday (it fails on the previous commit too); the test now keeps its tasks inside the week |
| Deploy with the full suite | 39194242545 | Failed in end to end: `pipeline.spec.ts` found two refunds to issue (the new spec left an approved one in the shared database); the spec now records its refund as paid |
| Deploy with the full suite | 39197282819 | Full suite green (199 passed, 15 skipped by design); not deployed (the fast job's test 20 above) |
| Deploy with the full suite | 39200727700 | Fast and full green (198 end to end passed); migration 0058 applied (history 58); the Worker build first stopped on a database statement timeout while prerendering `/book/toyota-corolla` (57014), the deploy job run again: deployed, carmacars.ca, /cars and photos answer 200 |
| Guides after the deploy (auto) | 39204484011 | Green: 21 screenshots, 2 sections rewritten automatically (owner/home-and-your-vehicles, field/report-rentals-referrals-and-profile; the 0058 text kept for the one-click revert), PDFs of the owner and field guides |
| verify, full | 39207830795 | Green: every check passed |
| verify, full, before it | 39204570682, 39206601310 | Failed on sign-in, sign-up and reset steps while the Worker answered Error 1102 (`503 exceeded resource limits`; the first ran beside the guides run) and one Turnstile bot check; no failure on a page this work changed |

**Error 1102 (separate).** Cloudflare stopped 262 requests in 24 hours with Error 1102 (52 in the hour of the first
verification). It caused the two failed verifications. Workers Paid removes the limit.

## 10. What still needs the owner

- **The lawyer**: VA agreement 3.4 and 3.2 and 6.2; Field Staff Agreement section 7 (especially 7.5, a deduction from
  wages under the ESA); Enrollment Agreement 8.1, 8.3 and 8.5. Owners who signed the earlier version (`owner-v3-16beb87986`)
  agreed to deductions of Referral Kickbacks only: ask the lawyer whether deducting Sales and other staff commissions from
  their Owner Revenue needs them to sign the new version first. The code deducts it for every program owner's car now.
  **Approved by the lawyer on 2026-10-19.** (the clauses and the kickback wording as written).
- Program settings, if other values are wanted: the 20% discount limit that flags a typed price (no number was given),
  the price floor (none), the rates and tiers.
- Staff home addresses (a staff member's Sales page, "Home address") if the automatic household check should apply;
  otherwise reverse a household rental's commission by hand.
- Admin > Settings > Guides: three chapters got the 0058 text as a suggestion because their live text had changed since
  the last release (admin/owner-money with the Staff commissions task, admin/settings, field/my-jobs): accept the
  suggestion. Sections "To review" after the upkeep run: va/shared-tools, va/finance, va/fleet, admin/owner-money,
  admin/settings, owner/notices-profile-and-leaving, investor/statements, investor/profile-and-notices.
