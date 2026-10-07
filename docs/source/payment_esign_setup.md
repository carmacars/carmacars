# CarmaCars Payment and E-Signature Setup

2026-10-06 · Abbas

## 1. Recommendation

Use **Stripe** for payments: it alone covers card holds, saved cards, Canadian pre-authorized debit, licence-plus-selfie identity checks and third-party payouts in one account, at about $640 a month more than Helcim. Use **Dropbox Sign Standard** for signatures: it alone has unlimited signature requests at a flat price, which decides it at about 155 requests a month.

Assumed monthly volume: 50 bookings at $700 including HST ($35,000); 20 vehicles debited $536.75 each; 50 identity checks; 155 signature requests (agreement, pickup report and return report per booking, plus owner and staff documents). Prices are CAD unless marked.

## 2. Payment processors

| | Stripe | Helcim | Square |
| --- | --- | --- | --- |
| Online card rate | [2.9% + $0.30](https://stripe.com/en-ca/pricing); +0.8% international | [Interchange + 0.50% + $0.25](https://legal.helcim.com/ca/fee-disclosures/); Visa consumer example 2.00% + $0.25 | [2.8% + $0.30](https://squareup.com/ca/en/pricing); +1.5% international |
| Deposit hold | [7 days online; 5 days on Visa when the merchant starts it](https://docs.stripe.com/payments/place-a-hold-on-a-payment-method) | [7 days](https://learn.helcim.com/docs/capture-credit-card-pre-authorizations) | [7 days online, 36 hours in person](https://developer.squareup.com/docs/payments-api/take-payments/card-payments/delayed-capture) |
| Extended hold, vehicle rental | [30 days; needs interchange-plus pricing, on request](https://docs.stripe.com/payments/extended-authorization.md?platform=web&ui=stripe-hosted) | None found | None |
| Saved card, later charges | [Yes](https://docs.stripe.com/payments/save-and-reuse.md?payment-ui=embedded-components), same rate | [Yes](https://www.helcim.com/credit-card-vault/) (unverified: page not opened) | [Yes, with signed authorization](https://squareup.com/help/ca/en/article/5770-save-cards-on-file-with-square); 3.3% + $0.15 |
| Pre-authorized debit | [1% + $0.40, cap $5](https://stripe.com/en-ca/pricing); $5 per failure; [hosted agreement](https://docs.stripe.com/payments/acss-debit) | [0.5% + $0.25, cap $6](https://www.helcim.com/eft-payments-pad/); $5 per return | [No: US only](https://developer.squareup.com/docs/payments-api/take-payments/ach-payments) |
| Paying third parties | [Connect: $2 per active account a month + 0.25% + $0.25 per payout](https://stripe.com/en-ca/connect/pricing) | None found | None found |
| Identity check | [$2.00](https://stripe.com/en-ca/pricing); [selfie match, Canadian ID](https://docs.stripe.com/identity/verification-checks.md?type=selfie) | None found | None found |
| Monthly fee | $0 | $0 | $0 |
| Cost at assumed volume | **About $1,410** | About $770 | About $995 |

- Stripe: cards $1,030, invoicing (0.4%) $183, debits $100, identity $100.
- Helcim: cards $712.50 at its Visa consumer example, debits $58.68. Square: cards only.
- "None found": not listed on the provider's pricing or feature pages. Not a confirmed no.

## 3. E-signature services

| | Dropbox Sign Standard | Signority Standard Team | DocuSign Standard |
| --- | --- | --- | --- |
| Price, two senders | [US$25 per user a month, two-user minimum; or US$420 a year](https://sign.dropbox.com/info/pricing) | [$28 a month, unlimited users](https://www.signority.com/pricing/) | [$30 per user a month, billed annually](https://ecom.docusign.com/plans-and-pricing/esignature); currency unverified |
| Included volume | Unlimited | 10 packages a month, then $2.80 each | 100 envelopes per user a year |
| Cost at 155 requests | **US$50** | $434 | Not workable: 200 a year against 1,860 |
| Upload a PDF, place signature boxes | [Yes](https://help.dropbox.com/share/how-to-send-a-dropbox-sign-signature-request) | Yes | Yes |
| Fillable fields survive upload | Not stated; test in the trial | [Yes, imported when "Import PDF Fields" is on](https://esigndocs.filecloud.com/sending-documents/advanced-sending-options/how-to-import-pdf-form-fields-as-tags) | [Converted to DocuSign fields](https://developers.docusign.com/docs/esign-rest-api/esign101/concepts/tabs/pdf-transform/) (partly verified) |
| Reusable templates | 15 | Yes | Yes |
| Audit trail | [Time-stamped](https://sign.dropbox.com/features); method and IP unverified | [Actions, time stamps, user ID, IP](https://www.signority.com/privacy-security/) | Unverified |
| Witness | No witness role; add the witness as a signer, [in order](https://help.dropbox.com/view-edit/change-signing-order-dropbox-sign) | [Witness role](https://www.signority.com/help/documents-with-witness-signers/) | Business Pro only, $45 |
| Signing on a phone | Yes, including in person | [In person, on a host device](https://esigndocs.filecloud.com/sending-documents/advanced-sending-options/advanced-recipient-settings/in-person-signing) | Yes, including in person |
| Data stored | Location not stated; region choice on Premium only | Montreal | [Canada region, by sign-up location](https://www.docusign.com/privacy/data-residency) |

If Canadian storage or a true witness role is required, use Signority for agreements only (about $154 a month) and sign condition reports on paper.

## 4. Stripe configuration

1. **Account.** Legal name 18122211 Canada Inc., trading name CarmaCars, category vehicle rental. Two admin logins and one Finance login, each with two-step sign-in.
2. **Products.** One per charge in the renter spec's catalogue and per owner Fee; price typed per invoice.
3. **HST.** One [tax rate](https://docs.stripe.com/billing/taxes/tax-rates): "HST 13%, Ontario, exclusive", applied per line. None on deposits, toll and ticket amounts, deductible, loss of use, interest or owner Late Fees.
4. **Booking payment.** One invoice per booking, paid on the hosted page. Confirm the booking only when it shows Paid.
5. **Card on File.** In invoice settings turn on ["Save customer payment information"](https://docs.stripe.com/invoicing/hosted-invoice-page). Stripe then shows the renter a tick-box; no saved card, no confirmed booking. Consent 4 of the agreement is the written authorization.
6. **Deposit, 7 days or less.** Payments, Create payment, saved card, More options, "Capture funds later". The hold lasts 7 days, or as little as 4 days 18 hours on Visa. If it would lapse before the return time, capture it.
7. **Check-in.** Capture what is owed plus any hold-back in one capture; the rest is released. Cancel the payment to release everything.
8. **Deposit, over 7 days, or an extension past 7 days.** Charge it, or capture the hold, and refund the balance. [Stripe keeps its fee on a refund](https://docs.stripe.com/refunds): $14.80 on $500, $29.30 on $1,000, $72.80 on $2,500.
9. **Later charges.** Email the statement and record, then invoice and charge the saved card. On a decline add the $40 line; retry after 1, 3 and 7 days.
10. **Refunds.** Refund the tier percentage within 2 business days; cards show it in 5 to 10.
11. **Owner debits.** One customer per Owner, one invoice per vehicle on the 15th. The Owner approves Stripe's debit agreement on the hosted page of the first fee invoice; later invoices charge automatically. Results take up to 5 business days.
12. **Payouts.** At launch pay Owners (10th) and investors (15th) by bank transfer from the business account. Connect needs code and a Stripe account per payee; adopt it with the platform.
13. **Receipts.** Settings, Business, Customer emails: turn on [Successful payments and Refunds](https://docs.stripe.com/receipts).
14. **Disputes.** $15 each. Answer in the Dashboard with the signed agreement, consents, Condition Report, Tracker data and statement. Withhold the disputed Owner Revenue. Debit disputes cannot be contested.
15. **Identity.** Create a [document check](https://docs.stripe.com/identity/verify-identity-documents.md?platform=no-code&type=dashboard) and send the link (valid 48 hours). The selfie option in the Dashboard is unverified. On failure, use staff review (procedure 2).

## 5. Dropbox Sign setup

Build each template from the blank PDF: place signature, initial, tick-box and date fields once, turn on signer order, and type the deal details into sender fields when sending.

| Template | Signer order |
| --- | --- |
| Rental Agreement (Parts 1 to 3, 5, 6) | Renter, each Additional Driver, CarmaCars |
| Condition Report, pickup and return (Part 4) | Renter, Field staff, in person |
| Enrollment Agreement with Vehicle Schedule | Owner (three initials), CarmaCars |
| Title-Holding and Lease Agreement with Schedule 1 | Owner, CarmaCars |
| Forms A, B and E | Owner, CarmaCars |
| Form C (witnessed) | Owner, Witness |
| Form D (witnessed) | Owner, Witness 1, Witness 2, CarmaCars, Witness |
| Additional Vehicle Schedule | Owner, CarmaCars |
| Investment Agreement with Schedules A to D | Investor (initials), CarmaCars |
| VA Contractor Agreement | Contractor, CarmaCars |
| Field Staff Agreement | Employee, CarmaCars |
| Shareholder Agreement | Abbas, his witness, Mahad, his witness, both holding companies, the corporation |

1. **Witness.** Add each witness as a signer directly after the person witnessed, with name, signature and date fields. Get the witness's name and email first. The witness must be physically present.
2. **Limit.** 12 of the 15 templates allowed.
3. **Filing.** Download each signed PDF with its audit trail. Renter documents: booking folder. Owner documents: Owner folder. Investor, staff and shareholder documents: Admin-only folder.

## 6. Chart of accounts

| No. | Account | Type | Posts here |
| --- | --- | --- | --- |
| 1010 | Operating bank | Asset | Stripe and Turo payouts, e-Transfers, transfers out |
| 1020 | Stripe clearing | Asset | Charges, refunds and fees until paid out |
| 1200 | Owner receivables | Asset | Unpaid Fees and Late Fees, Owner costs paid, shortfalls, negative balances |
| 1210 | Renter receivables | Asset | Unpaid Charges, collection costs |
| 2100 | Renter deposits held | Liability | Charged or captured deposits until applied or refunded. Uncaptured holds are not booked |
| 2110 | Collected for Owners | Liability | Owner Revenue less Revenue Share: rental charge, extra days, mileage overage, rental part of retained cancellations, Turo net |
| 2120 | Prepaid last month's Insurance Fee | Liability | Held until the exit month |
| 2130 | Referral kickbacks payable | Liability | 20% kickbacks until paid |
| 2140 | Claim funds held | Liability | Per claim: insurer payments, renter deductible, loss of use, total-loss settlements |
| 2150 | Pass-through clearing | Liability | Tolls, tickets, fines, towing, impound, key cost, Damage under $2,500 |
| 2200 | HST collected | Liability | HST on renter invoices and owner Fees |
| 2210 | HST paid | Asset | HST on costs and on payouts to HST-registered Owners |
| 2300 | Investor capital | Per accountant | Invested Amounts |
| 4000 | Revenue Share | Revenue | Vehicle Schedule share; 10% on shareholder-owned cars; share of Turo net |
| 4010 | Owner fee revenue | Revenue | Insurance, Tracker and Install Fees |
| 4020 | Owner Late Fees | Revenue | $50 per missed payment |
| 4100 | Renter service fees | Revenue | Delivery, pickup, young and additional driver, winter tire, baby seat, late return fee, fuel, cleaning, pet, smoking |
| 4110 | Coverage sold | Revenue | Option 3 |
| 4120 | Administration fees | Revenue | $15 toll, $40 ticket, $75 and $50 administration, $50 key, $40 declined payment |
| 4130 | Interest | Revenue | 1.5% a month on overdue Charges |
| 4140 | Claim surplus | Revenue | Balance after repair and claim costs; 10% on shareholder-owned cars |
| 5000 | Processing fees | Expense | Stripe fees, dispute fees, fees kept on refunded deposits |
| 5010 | Investor returns | Per accountant | Monthly Returns |

## 7. Monthly close

1. **1st.** Send the franchisor fleet report (procedure 20).
2. **1st.** Match last month's Stripe payouts to the bank and the Bookings log.
3. **1st.** List rentals ended last month, collected, net of refunds and chargebacks. Per vehicle compute kickback, Owner Revenue and Revenue Share. Add Turo payouts.
4. **1st.** Reconcile 2100, 2140 and 2150 to open bookings and claims. Release deposits past 7 business days and hold-backs past 30 days.
5. **1st.** Add 1.5% interest to overdue Charges. Compute investor Returns.
6. **By the 9th.** Draft one statement per Owner. Admin approves the run.
7. **10th.** Deduct only unpaid Fees and Late Fees, Owner costs, refund or chargeback shares and agreed amounts. Pay by bank transfer. Send T26 with the statement. Send Field staff kickbacks to payroll.
8. **15th.** Issue one invoice per vehicle: Insurance Fee, Tracker Fee, HST, pro-rated in enrollment and exit months. Skip Turo-Only cars and cars owned personally by Abbas or Mahad. Send T24.
9. **15th.** Pay investor Returns by bank transfer.
10. **15th to 18th.** On a failed debit add the $50 Late Fee and send T25.
11. **18th.** Retry Fees plus Late Fee. On failure: vehicle in arrears, tell Admin, block new bookings on a Self-managed car.
12. **To the 25th.** Check daily for late debit failures.

## 8. When the platform goes live

| Launch | Platform |
| --- | --- |
| Invoices built by hand | Checkout created from the booking; lines, HST and split written to the booking record |
| Holds from the Dashboard | Holds by code, requesting the 30-day extended hold; expiry stored on the Deposit |
| Debit approved on the first invoice | Debit agreement collected at enrollment, in CarmaCars' wording |
| Identity links sent by staff | Check inside the booking flow; result written to the renter record |
| Bank transfers | Stripe Connect payouts, if worth the fee |
| Templates filled by staff | Agreements generated and sent by the platform |

Customers, saved cards, debit agreements and the chart of accounts carry over.

## Sources

Opened 2026-10-06.

- Stripe: [pricing](https://stripe.com/en-ca/pricing), [Connect](https://stripe.com/en-ca/connect/pricing), [holds](https://docs.stripe.com/payments/place-a-hold-on-a-payment-method), [extended holds](https://docs.stripe.com/payments/extended-authorization.md?platform=web&ui=stripe-hosted), [saved cards](https://docs.stripe.com/payments/save-and-reuse.md?payment-ui=embedded-components), [debits](https://docs.stripe.com/payments/acss-debit), [invoices](https://docs.stripe.com/invoicing/hosted-invoice-page), [tax](https://docs.stripe.com/billing/taxes/tax-rates), [refunds](https://docs.stripe.com/refunds), [receipts](https://docs.stripe.com/receipts), [selfie check](https://docs.stripe.com/identity/verification-checks.md?type=selfie), [Dashboard check](https://docs.stripe.com/identity/verify-identity-documents.md?platform=no-code&type=dashboard)
- Helcim: [pricing](https://www.helcim.com/pricing/), [Canadian fees](https://legal.helcim.com/ca/fee-disclosures/), [debits](https://www.helcim.com/eft-payments-pad/), [holds](https://learn.helcim.com/docs/capture-credit-card-pre-authorizations)
- Square: [pricing](https://squareup.com/ca/en/pricing), [holds](https://developer.squareup.com/docs/payments-api/take-payments/card-payments/delayed-capture), [bank debits](https://developer.squareup.com/docs/payments-api/take-payments/ach-payments), [card on file](https://squareup.com/help/ca/en/article/5770-save-cards-on-file-with-square)
- Dropbox Sign: [pricing](https://sign.dropbox.com/info/pricing), [features](https://sign.dropbox.com/features), [sending](https://help.dropbox.com/share/how-to-send-a-dropbox-sign-signature-request), [signer order](https://help.dropbox.com/view-edit/change-signing-order-dropbox-sign)
- Signority: [pricing](https://www.signority.com/pricing/), [security](https://www.signority.com/privacy-security/), [field import](https://esigndocs.filecloud.com/sending-documents/advanced-sending-options/how-to-import-pdf-form-fields-as-tags), [witness](https://www.signority.com/help/documents-with-witness-signers/), [in person](https://esigndocs.filecloud.com/sending-documents/advanced-sending-options/advanced-recipient-settings/in-person-signing)
- DocuSign: [pricing](https://ecom.docusign.com/plans-and-pricing/esignature), [data residency](https://www.docusign.com/privacy/data-residency), [PDF fields](https://developers.docusign.com/docs/esign-rest-api/esign101/concepts/tabs/pdf-transform/)
- Would not load: DocuSign's Canadian pricing page and two support articles; Adobe's Canadian prices, so Adobe was left out.

---

Tab: Review notes

# Review notes

| For | Question |
| --- | --- |
| Accountant | Must 18122211 Canada Inc. register for HST before the first booking on October 15, or only once it passes the small-supplier threshold? Invoices need the number. |
| Accountant | How are Owner payouts reported: full rental charge as revenue with payouts as a cost, or only the Revenue Share with the rest held for Owners (2110)? |
| Accountant | Should money collected for Owners, prepaid last months and claim funds sit in a separate bank account? |
| Accountant | Are investor capital and Returns (2300, 5010) debt and interest, or equity and distributions? |
| Lawyer | The Enrollment Agreement has no pre-authorized debit wording. Is Stripe's hosted debit agreement enough, including for a Late Fee retry? |
| Lawyer | Is a witness who signs electronically as an ordinary signer enough for Forms C and D and the Shareholder Agreement? |
| Lawyer | May renter and Owner documents be stored outside Canada, and must the privacy notice say so? |
