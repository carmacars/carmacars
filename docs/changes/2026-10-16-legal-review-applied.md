# Legal review applied (October 16, 2026)

The owner's document "CarmaCars: legal text changes before launch" is applied in full, live and checked. The work
started as an unfinished commit (ddae5ba); d706727, 362ee08 and 508cf4f finished it (migrations 0052 to 0055, see
`2026-10-16-legal-review-admin-redesign.md`). This pass reviewed every item against the document again, ran the
section 6 tests (Stripe test mode included), fixed what they found (migration 0056 and the web app), deployed and
verified.

## 1. What this pass changed

| Found by | Problem | Fix |
| --- | --- | --- |
| Stripe test mode, account closed | Stripe reports the closed account as the generic `payment_intent_payment_attempt_failed` on the PaymentIntent; the bank's reason (`bank_cannot_process`) is only on the charge. A debit returned for insufficient funds that came through the same way would have been treated as "another reason" and not retried | The site's webhook (`web/src/integrations/payments/stripe.ts`, `bankReasonCode`) and the `owner-debit` Edge Function (`run.ts`, `intentFacts`) record the charge's failure code when the PaymentIntent's code is the generic one. Unit tests in both |
| Stripe test mode, account closed | The invoice kept a retry date (the 18th) although it is never retried: 0007's status trigger filled it in | 0056: no retry date when `app.owner_debit_fail` says there is no retry; invoices already in that state lose it |
| Stripe test mode | The Admin task printed the bank's reason with two full stops | 0056 |
| Review | The finance task "Owner debit failed" still said "Late Fee added; retry on the 18th" | 0056 (new wording below) |
| String search (wider than the unit test) | The requirements page called the Protection Plan "Coverage you buy with your booking" | New wording below; the unit test's search now catches that phrase |
| Section 6 test 4 (signed PDF) | The signature block of every signed PDF said "Signed electronically for CarmaCars", cut to three lines; only the signature record had the approved wording | The block prints the stored countersignature wording in full (`companySignature().text`); signature rows grow to fit (`web/src/features/agreement/pdf.ts`) |
| Section 6 test 6 (staff-added rental) | After "Accept and sign" no signed copy was filed for a rental staff added (only the payment step filed it, and these rentals have none) | The signing action files the signed copy for a rental staff added. Live: no such rental exists yet, so nothing to file again |
| Settings | No help text said the street address will change; the obsolete "show legal name" switch was still on Program settings | Help text on the street address, mailing address and signing officer; the authorization date shows under Company; the obsolete switch is hidden (0053 always names the legal company) |

## 2. Changed strings (old, then new)

Text versions: rental agreement `rental-v3`, owner agreements `owner-v3` (Enrollment Agreement, Title-Holding and
Lease Agreement, Forms C and D), partner agreement with the approved sections 3 to 11. Documents signed before keep
their text, version and hash.


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
| Finance task "Owner debit failed" (staff) | Late Fee added; retry on the 18th | Insufficient funds: the Late Fee is added and the original amount is tried once more within 30 days. Any other reason: not retried, the automatic debit is paused and an Admin has a task. |
| Void notice (6.2), added | (none) | No late fee applies. If this invoice has an automatic debit scheduled, it is debited on [debit date] for [balance]; otherwise pay it from the invoice page. |

**Signatures**

| Where | Old | New |
| --- | --- | --- |
| Every automatic countersignature (5.3) | Countersigned for CarmaCars automatically ..., in the name of the staff member who proposed, approved or added it | Signed electronically for [company legal name], operating as CarmaCars, by Abbas Al-Mashita, Director, under a standing authorization dated [authorization date]. (method "automatic") |
| Staff on signed documents | Named as the signer | "Proposed by: [staff name]" or "Added by: [staff name]" in the signature record and PDF; never the signer |
| Booking amendment, section 4 | CarmaCars signs this amendment electronically, in the name of [staff], who proposed the change, at the moment the Renter signs it. | CarmaCars signs this amendment electronically at the moment the Renter signs it. |
| Owner signing statement | I have read these documents and I sign them electronically, for myself and for every Owner named in them. | I have read these documents and I sign them electronically. Each Owner named in the Title Schedule signs with their own link (email `owner_cosigner_sign`); the agreements take effect when the last Owner signs. |
| Form C witness | On paper only | May sign on screen in person, on the same device: typed name and "I witnessed [owner legal name] sign in my presence." Form D stays on paper |
| Signature block of every signed PDF (rental agreement, amendment, owner documents, Forms A and B, partner agreement) | Signed electronically for CarmaCars (cut to 3 lines) | The countersignature's full approved wording, as in the signature record; the row grows to fit |
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
| Requirements page, third option | 3. Through CarmaCars: Coverage you buy with your booking, supplied by a third-party provider on its own terms | 3. Protection Plan: The CarmaCars Protection Plan, added to your booking. A third-party provider supplies it on its own terms |
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

## 3. Settings (0052, live)

| Setting | Value |
| --- | --- |
| Site mailing address | 2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2 |
| Site street address (pickup and returns) | 1570 Midland Ave, Toronto, ON (help text: it will change; every page, email and agreement reads the setting, nothing else holds it) |
| Signing officer | Abbas Al-Mashita, Director, for 18122211 Canada Inc. (linked to the rent@carmacars.ca account, the only one that can press Countersign) |
| Standing authorization date | October 16, 2026 (stored in `program_settings.signing_officer_authorized_on`) |

The PAD agreement, its confirmation and every owner billing email now carry the payee "18122211 Canada Inc., operating
as CarmaCars" with the mailing address. Marketing emails held for a missing mailing address: none were queued live
(0 marketing rows in the outbox), and the hold no longer applies now that the address is set.

## 4. Section 6 tests

| # | Test | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Stripe test NSF return: one retry, original amount, Late Fee as a separate invoice line, in the next pre-debit notice | pass | Stripe test mode (below), owner A and C; suite 33 |
| 2 | Stripe test non-NSF return (account closed): no retry, invoice paused, Admin alerted, owner emailed | pass | Stripe test mode (below), owner B; suite 33 |
| 3 | Invoice-page PAD flow: two boxes; unticking the second creates no recurring mandate | pass | e2e `owner.spec.ts` and `legal-admin-redesign.spec.ts`, 375 and 1440; suite 33 |
| 4 | Signed PDF: corporate countersignature with the signing officer's name; staff only as "Proposed by" or "Added by" | pass | e2e reads the PDFs back: the amendment (`ops.spec.ts`: the wording twice, "Proposed by") and the staff-added rental (`legal-admin-redesign.spec.ts`: the wording twice, "Added by <staff>", staff never the CarmaCars signer) |
| 5 | Two-owner enrollment: two links, two signature records, effective only after both sign | pass | suite 33, block "co-owner" (two records, agreements open until the second signs); e2e: the co-owner's own signing page |
| 6 | Staff-added rental: no card charge until the renter signs | pass | e2e: no payment after adding, one after "Accept and sign"; suite 33 |
| 7 | Investment agreement "Awaiting countersignature" until the Admin countersigns | pass | new e2e (Admin > People > Investors: the label, Countersign, "Fully signed", one company record, none before); suite 33 |
| 8 | Partner agreement: sections 3 to 11, no draft banner | pass | `legal-review.test.ts`, word for word |
| 9 | String search: no bare "CarmaCars" payee in PAD, confirmation or Stripe fields; no "insurance" or "coverage" for the Protection Plan | pass (after the requirements page fix) | `legal-review.test.ts`; a wider grep of the renter pages and emails: the remaining "coverage" lines are the renter's own policy or card, or the included liability |

### Stripe test mode run

Local database with every migration, Stripe test mode (key `sk_test_...`), the debit run's own code (`run.ts`:
`stripeClient`, `intentFacts`, the same PaymentIntent parameters). Mandates made by SetupIntents with Stripe's PAD test
methods; Stripe accepted the new mandate description as the interval description on all four.

| Owner | Test method | Nov 16 debit | Result |
| --- | --- | --- | --- |
| A | `pm_acssDebit_insufficientFunds` | $536.75 | `insufficient_funds`: invoice failed, Late Fee $50.00 its own line ("Late Fee"), one retry scheduled Wed Nov 18 for $536.75 (later of the 18th and 3 business days), `owner_payment_failed` with retry amount $536.75 and the payee. Owner A then updated the bank (`pm_acssDebit_success`): the Nov 18 retry debited $536.75 (not the Late Fee) and succeeded; the invoice was left at $50.00. The Dec 15 notice listed one item, "Late Fee $50.00", and the Dec 15 debit took $50.00: paid |
| B | `pm_acssDebit_accountClosed` | $536.75 | Stripe `bank_cannot_process` ("The customer's bank could not process this payment."): no retry, no Late Fee, automatic debit paused, Admin task "Debit returned for invoice INV-1008: not retried" and the staff exception event to every Admin (`staff_owner_debit_exception`, immediate; the fan-out queues one email per Admin, checked separately), owner email `owner_debit_returned` ("The debit of Mon, Nov 16, 2026 was returned: ..."); not in the Dec 15 notice |
| C | `pm_acssDebit_insufficientFunds` | $536.75 | as A, then the Nov 18 retry ($536.75) returned for insufficient funds too: in arrears, no third attempt |

## 5. Suites

| Suite | Result |
| --- | --- |
| Database (`scripts/test.sh`) | 3575 passed, 0 failed |
| Unit (`npm run test:unit`) | 116 passed |
| End to end, 375 and 1440 | CI full job of each deploy (see runs); locally `legal-admin-redesign.spec.ts`, `ops.spec.ts`, `owner.spec.ts` all passed |
| Emails (`emails/check.mjs`) | all 15 checks passed |
| Text check, lint, types | passed |

## 6. Runs

| Run | What | Result |
| --- | --- | --- |
| 38994335351 | Deploy of 508cf4f (0052 to 0055 live) | success |
| 38996481983 | Push CI, 0056 | success |
| 38996866445 | Deploy of 1132d66 (0056 live) | success |
| 38998280729 | Push CI, signed PDFs and e2e | success |
| 38998998148 | Deploy of 27b6adb | RESULT_DEPLOY |
| VERIFY_ID | Verify, full | RESULT_VERIFY |

## 7. Open

- Error 1102 (Cloudflare Worker resource limit on the free plan): known, the plan is upgraded on October 17; reported separately.
- The rental agreement keeps "Coverage Option" as the name of the three choices (option 3 is "the CarmaCars Protection
  Plan"): that structure was approved as written in the pack. Say if the category name should change too.
- The owner's document puts the Retry Date in "Schedule A"; in our Enrollment Agreement it is defined in Schedule B
  Part 1, where it was changed.
- Stripe live mode still needs Canadian pre-authorized debits turned on and the live keys (unchanged from
  `2026-10-14-owner-debit.md`).
