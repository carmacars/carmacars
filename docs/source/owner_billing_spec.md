# CarmaCars Owner Billing Specification

2026-10-06

## 1. Charges to owners

Amounts come from each vehicle's signed Vehicle Schedule, never from a tier. Upfront, CarmaCars bills only the $100 Install Fee and first and last month's Insurance Fee. Onboarding costs are not billed by CarmaCars: the Owner pays ServiceOntario, the safety inspection, the appraisal and other third parties directly. The estimates (Lease, existing corporation $50; Lease, new Owner Corporation $570; Co-Registrant $250; Transfer $250, or $260 with lien) are for information and may vary.

| Charge | Amount source | Billed | HST added | Payment method |
| --- | --- | --- | --- | --- |
| Install Fee | $100 per vehicle | Before the Enrollment Date | Yes | Card or e-Transfer |
| First and last month's Insurance Fee | 2 × monthly Insurance Fee | Before the Enrollment Date | Yes | Card or e-Transfer |
| Insurance Fee | Vehicle Schedule | 15th, monthly | Yes | Pre-authorized debit |
| Tracker Fee | Vehicle Schedule | 15th, monthly | Yes | Pre-authorized debit |
| Late Fee | $50 per vehicle per automatic debit returned for insufficient funds | Its own invoice line, when the bank returns the debit | No | Listed in the next pre-debit notice and collected with the next scheduled debit (or deducted from the next payout when attempts per invoice is 1); never added to the retry |
| Owner costs CarmaCars paid | Actual cost: plate renewal, Owner Booking tolls and tickets, lender handover costs | Next statement | As on the receipt | Deducted from payout |

| Standard grid (default only) | Insurance Fee | Revenue Share | Tracker Fee |
| --- | --- | --- | --- |
| 1 to 2 vehicles | $450 | 35% | $25 |
| 3 to 9 vehicles | $400 | 30% | $20 |
| 10 or more | $350 | 25% | $15 |

- One agreement per Owner covers all their vehicles, signed through an electronic signature service. Each vehicle has its own invoice and debit, so a failure, its Late Fee and any deduction attach to that vehicle.
- Fees run from the Enrollment Date to the Exit Date, rented or not. On a total loss they stop on the date of the Insurer's decision.
- Fee period: the charge on the 15th covers that calendar month. Enrollment and exit months are pro-rated by day. The prepaid first month pays the enrollment month; the unused part is credited to the next charge.
- Fee changes need 30 days' written notice; Revenue Share changes need a new signed Vehicle Schedule.

## 2. Owner Revenue and payouts

| Item | Rule |
| --- | --- |
| Owner Revenue, per booking | Rental Charge (time-based, including extra days after a late return, before tax, after discounts) + mileage overage fees − any Referral Kickback, whether an Owner or field staff earned it |
| Company only | Every other renter charge: late return fee, delivery and pickup, fuel, cleaning, young driver, coverage sold, toll and ticket admin. Processing fees are a company cost |
| Revenue Share | Vehicle Schedule % × Owner Revenue, kept by CarmaCars. The Owner is paid the rest |
| When a rental counts | Once collected, net of refunds and chargebacks, in the month the rental ends. Each renewal is its own rental. Rental Charge kept on a cancelled booking counts in the month of cancellation |
| Payout | 10th of each month, for the previous month, with the statement |
| Deductions allowed | Unpaid Fees and Late Fees; Owner costs CarmaCars paid or was billed, including a claim shortfall; the Owner's share of a refund or chargeback, on the next statement; amounts the Owner agreed to in writing. Nothing else |
| Negative balance | Carried forward as a debt payable on demand |
| HST on payout | Added only when the Owner's HST number is on file |
| Payment method | Bank transfer to the Owner's account on file |

## 3. The four cases

| | Managed | Self-managed | Turo-only | Shareholder-owned |
| --- | --- | --- | --- | --- |
| Registration to CarmaCars, Fleet Policy, Tracker | Yes | Yes | No. Owner keeps registration and own insurance | Yes |
| Upfront charges | All in section 1 | All in section 1 | None | None; registration costs are paid directly |
| Insurance Fee, Tracker Fee, Late Fee | Yes | Yes | No | No |
| Rentals run by | CarmaCars | Owner, on CarmaCars' booking system | CarmaCars, on its Turo account | CarmaCars |
| Rental money collected by | CarmaCars | CarmaCars, through its own checkout | Turo, which pays CarmaCars | CarmaCars |
| Split applies to | Owner Revenue | Owner Revenue; no Revenue Share | Turo's payout for trip price and distance fees, after Turo's standard fees; delivery and extras stay with CarmaCars | Owner Revenue |
| CarmaCars keeps / Owner is paid | Revenue Share % / the rest | 0% / 100% of Owner Revenue, on the 10th | Same Revenue Share % / the rest | 10% / 90% |
| Referral Kickback deducted | Yes | No | No | Yes |
| Deducted from payout | Section 2 list | Section 2 list | Owner costs, refund share | Owner costs |
| Claims | Section 7, no split | Section 7, no split | Turo's terms. Damage payments pass to the Owner | 90/10 on profit and on shortfall |

In every case the Owner keeps live location, but the Owner's lock, alarm and shut-off controls are blocked during a rental CarmaCars manages. Self-managed example: a $1,000 Rental Charge with a $150 delivery fee pays the Owner $1,000 on the 10th, and CarmaCars keeps the $150.

## 4. Fees are billed separately on the 15th

Charge Fees by pre-authorized debit on the 15th and pay revenue in full on the 10th, without netting.

| Reason | Detail |
| --- | --- |
| The agreements say so | Deduction from revenue is only the fallback after a failed retry |
| Fees are due with or without revenue | New and idle vehicles have no payout to net against |
| Cleaner books | Fee invoices (company revenue, with HST) stay separate from Owner payouts |

## 5. Monthly owner statement

Issued on the 10th, one per Owner, with a block per vehicle.

| Block | Line | Shows |
| --- | --- | --- |
| Header | Owner, month, statement number, payout date | |
| Vehicle | Each rental ended | Booking number, dates, Rental Charge, mileage overage, refunds and chargebacks, Referral Kickback, Owner Revenue |
| Vehicle | Each Turo trip | Dates, Turo gross, Turo fees, net |
| Vehicle | Owner Revenue, Revenue Share, net earnings | Total, % and amount kept, the difference |
| Vehicle | Unpaid Fees and Late Fees deducted | Invoice number, Fee, HST, Late Fee |
| Vehicle | Owner costs deducted | Item, date, receipt |
| Vehicle | Earlier refund or chargeback | Booking number, Owner's share |
| Vehicle | Vehicle payable | Net earnings − deductions |
| Owner | Referral Kickbacks earned | Booking number, Rental Charge, amount |
| Owner | Arrears moved from another vehicle | From, to, amount |
| Owner | HST on payout; balance brought forward | |
| Owner | Payout, or balance owing | |
| Information | Fees billed this month | Per vehicle: amount, HST, paid, failed or deducted |
| Information | Prepaid last month's Insurance Fee held | Per vehicle |
| Information | Open claims | Vehicle, status |

## 6. Missed payments

| When | Event | Action |
| --- | --- | --- |
| 15th | Debit returned for insufficient funds | Add the $50 Late Fee to that vehicle's invoice as its own line. Notify the Owner |
| 15th | Debit returned for any other reason (for example the account is closed) | No retry and no Late Fee. The invoice's automatic debit is paused, an Admin is alerted, and the Owner is emailed to pay from the invoice page or update the bank account |
| The later of the 18th and 3 business days after the return, never more than 30 days after the original debit | Retry once, the original invoice amount only (never the Late Fee) | If it fails, the vehicle is in arrears and a Self-managed vehicle is not enabled for new bookings |
| Next 10th | Payout run | Deduct the unpaid Fees and Late Fee from that vehicle's revenue |
| Same 10th | Balance still left | Debt payable on demand. Deduct it from the Owner's other vehicles |
| 30 days after the failed retry | Still unpaid | CarmaCars may remove the vehicle immediately. The Owner pays the transfer-back fees |

A vehicle's return is never delayed because money is owed.

## 7. Claims

Third-party Owner agreements have no claim profit split. Claim money pays the repair and claim costs, and any balance belongs to CarmaCars. Claim money sits in a per-claim ledger, not on the Owner's account.

| Case | Money in | Money out | Owner's account |
| --- | --- | --- | --- |
| Damage under $2,500 | Renter pays actual cost | Approved shop | No entry |
| Damage of $2,500 or more | Insurer's payment; renter's $2,500 | Approved shop; any policy deductible; towing, storage, appraisal | No entry |
| Shortfall | | If claim money does not cover the repair and claim costs, the Owner pays the shortfall, unless CarmaCars caused it | Billed as an Owner cost, with receipts |
| Owner Booking damage | On a claim, the Owner pays the $2,500 deductible | Under $2,500: the Owner repairs it at their own cost. On a claim: as above | $2,500 charged on a claim |
| Total loss or unrecovered theft | Settlement, held for the Owner | Lender first, then amounts the Owner owes CarmaCars | Balance paid within 10 business days of cleared funds |

| A third-party Owner receives | Does not receive |
| --- | --- |
| The vehicle repaired at an approved shop; on a total loss, the settlement balance | Insurer money on a repair, the renter's $2,500 or at-cost payment, or money left over (CarmaCars keeps these); downtime pay, a Fee credit, or compensation for lost value |

**Shareholder vehicles.** Claim Profit = money received from the insurer and renter − repair cost − any policy deductible − claim costs. Calculated per claim once all money is in. Profit and shortfall both split 90/10. Payment needs both Principals' approval.

| Example | Amount |
| --- | --- |
| Insurer pays | $7,500 |
| Renter pays deductible | $2,500 |
| Repair at approved shop | −$8,200 |
| Towing and appraisal | −$300 |
| Claim Profit | $1,500 |
| Owning shareholder, 90% | $1,350 |
| Company, 10% | $150 |

## 8. Referral Kickback

| Item | Rule |
| --- | --- |
| Amount | 20% of the Rental Charge. Not on mileage overage, company-only fees or tax |
| Earned on | The first rental only of a renter new to CarmaCars, linked to the referrer before booking. First rental = the first completed booking with its extensions |
| Not earned on | Renewals, cancelled bookings, bookings of the referring Owner's own vehicles, Self-managed rentals, Owner Bookings, Turo trips |
| Who bears it | The booked vehicle: deducted before Owner Revenue, even on another Owner's vehicle |
| Paid | With the referring Owner's next payout. Reversed if the rental is refunded or charged back |
| Staff referrals | In-person staff earn the same 20%. It is deducted the same way, before Owner Revenue. Virtual assistants earn none |
| On statements | Referrer: "Referral Kickbacks earned" line. Vehicle owner: "Referral Kickback" column on that rental |

## 9. Exit

| Item | Rule |
| --- | --- |
| Notice | 30 days, either party. Exit Date = end of notice or, if later, of a rental in progress |
| Final month's Fees | Insurance Fee comes from the prepaid last month, pro-rated to the Exit Date, and the unused part is refunded. Tracker Fee is billed pro-rated |
| Final statement | Paid on the first 10th after the month of the Exit Date |
| Transfer-back fees (registry charges and required safety inspection only) | Under 6 months on the Fleet Policy: Owner pays. After 6 months: CarmaCars pays. Owner default: Owner pays, always. Insurer declines after registration: CarmaCars pays, unless the Owner failed to disclose something |
| Buyout | Only if the Owner offers in writing and CarmaCars chooses to buy. Price = Canadian Black Book average trade-in value on the offer date × 1.10, plus any sales tax. Closes within 30 days; any lender is paid first |

## 10. Worked month: November 2026

One Owner, one agreement, two Managed vehicles at $450, 35% and $25, not HST-registered. B2 came back 3 hours late: one extra day at $100 is Owner Revenue, and the $75 late return fee is company only.

| Booking | Rental Charge | Mileage overage | Referral Kickback | Owner Revenue | Company only |
| --- | --- | --- | --- | --- | --- |
| A1 | $900 | $60 | | $960 | Delivery $150 |
| A2, renter referred by another Owner | $1,000 | | −$200 | $800 | Cleaning $50 |
| B1 | $700 | | | $700 | |
| B2 | $1,200 + $100 extra day | $100 | | $1,400 | Late return fee $75 |

Fees billed November 15, per vehicle: $450 + $25 + HST $61.75 = $536.75. Vehicle A's debit clears. Vehicle B's is returned for insufficient funds, a $50 Late Fee is added as its own line (the invoice now owes $586.75), and the retry of the original $536.75 fails on November 18.

| Line | Vehicle A | Vehicle B |
| --- | --- | --- |
| Owner Revenue | $1,760.00 | $2,100.00 |
| Revenue Share, 35% | −$616.00 | −$735.00 |
| Net earnings | $1,144.00 | $1,365.00 |
| Unpaid Fees deducted | | −$536.75 |
| Late Fee deducted | | −$50.00 |
| Vehicle payable | $1,144.00 | $778.25 |

| Owner total | Amount |
| --- | --- |
| Referral Kickbacks earned | $0.00 |
| Payout on December 10 | $1,922.25 |

CarmaCars keeps $1,351 Revenue Share and $275 company-only fees, and pays the other Owner's $200 kickback.

## 11. Data fields

| Record | Fields |
| --- | --- |
| Owner | Legal name, type, contact, agreement number, signature record, HST number, payout account, debit authorization, card on file, referral code, balance carried forward |
| Vehicle | VIN, plate, Owner, Management Mode, Onboarding Method, Insurance Fee, Tracker Fee, Revenue Share %, schedule number, Enrollment Date, Exit Date, onboarding estimate (information only), prepaid last month, shareholder flag, status |
| Rental | Vehicle, renter, referrer, start, end, Rental Charge, mileage overage, each company-only fee, tax, collected, refunds, chargebacks, Referral Kickback, Owner Revenue, statement month |
| Vehicle month | Fee invoice, HST, debit status, retry date, Late Fee, Owner Revenue, Revenue Share, deductions, payable |
| Claim | Vehicle, booking, insurer payment, renter payment, repair cost, policy deductible, claim costs, result |
| Statement | Number, month, kickbacks earned, payout amount, date, reference |

---

*Second tab: Review notes*

# Review notes

For the accountant or lawyer.

| Topic | Question | Default drafted | For |
| --- | --- | --- | --- |
| HST on Fees | The Enrollment Agreement says HST is extra. Are Insurance, Tracker and Install Fees taxable, or partly an exempt insurance supply? Late Fees and Referral Kickbacks? | 13% added to the three Fees; none on Late Fees or kickbacks | Accountant |
| HST on Revenue Share and payouts | Is the payout a taxable supply by the Owner to CarmaCars? | 13% added only for Owners with an HST number | Accountant |
| Owner income and tax slips | Are payouts the Owner's rental income? Is a slip needed for payouts or kickbacks, or withholding for a non-resident Owner? | No slip, no withholding | Accountant |
| Holding Owner funds | Collected revenue, prepaid last months and total-loss settlements sit in CarmaCars' account. Is a trust account required? | One operating account, tracked per Owner | Lawyer |
| Charging for insurance access | May CarmaCars charge Owners a monthly fee for a place on its fleet policy without acting as an insurer or broker? Do the insurer and franchisor allow it? | Charged as written | Lawyer |
| Claim money on third-party vehicles | The Title Agreement leaves a vehicle's proceeds with the Owner. May CarmaCars keep money left over after a repair while a shortfall stays with the Owner? | Kept by CarmaCars | Lawyer |
| Tax at the registry | Is tax on appraised value payable when registration moves to a bare trustee, and again on transfer back? | Owner pays at the counter | Accountant |
