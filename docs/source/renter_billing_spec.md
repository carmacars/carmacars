# CarmaCars Renter Billing Specification

2026-10-06

## 1. Charge catalogue

All amounts are before HST (13%). Change: D = admin default, V = per vehicle, B = per booking. Refund "Tiers" = section 5.

| Charge | Default amount | Change | Charged | HST | Refund | Belongs to |
| --- | --- | --- | --- | --- | --- | --- |
| Rental charge, daily rate | Set per vehicle | V, B | Booking | Yes | Tiers | Owner Revenue |
| Rental charge, weekend rate | Set per vehicle | V, B | Booking | Yes | Tiers | Owner Revenue |
| Rental charge, weekly rate | Set per vehicle | V, B | Booking | Yes | Tiers | Owner Revenue |
| Rental charge, monthly rate (30 days) | Set per vehicle | V, B | Booking | Yes | Tiers | Owner Revenue |
| Non-refundable discount | −10% of rental charge | Fixed | Booking | Lowers the taxed amount | None | Lowers Owner Revenue |
| Deposit | $500 economy and standard; $1,000 premium and SUV; $2,500 luxury and exotic | D, V, B | Pickup | No | Yes, less Charges | Not revenue |
| Delivery | $75 to $200 by vehicle | V, B | Booking | Yes | Tiers | Company |
| Pickup | $75 to $200 by vehicle | V, B | Booking | Yes | Tiers | Company |
| Young driver, 18 to 20 | $35 per day, max $350 per rental, per driver | D, B | Booking | Yes | Tiers | Company |
| Young driver, 21 to 25 | $20 per day, max $200 per rental, per driver | D, B | Booking | Yes | Tiers | Company |
| Additional driver | $10 per day, max $70 per rental, per driver | D, B | Booking | Yes | Tiers | Company* |
| Winter tire | $15 per day, max $150 per rental | D, B | Booking | Yes | Tiers | Company* |
| Baby seat | $12 per day, max $70 per rental, per seat | D, B | Booking | Yes | Tiers | Company* |
| Coverage sold (Option 3) | [●] (price not set) | D, V, B | Booking | Yes | Tiers | Company |
| Mileage overage | $0.35 per km; $0.75 to $1.50 luxury and exotic | D, V, B | Check-in | Yes | No | Owner Revenue |
| Late return | Once over 30 minutes late: $25 per started hour from the return time, max 1.5 × daily rate per 24 hours, plus the rental charge for each extra billable day | D, B | Check-in | Yes | No | Fee: Company. Extra days: Owner Revenue |
| Fuel or recharging | Pump price + 25%, or $10 per 10% of battery; plus $25 service fee | D, B | Check-in | Yes | No | Company |
| Cleaning | $75; $250 heavy soiling or odour | D, B | Check-in | Yes | No | Company |
| Pet cleaning | $150 | D, B | Check-in | Yes | No | Company |
| Smoking | $300 | D, B | Check-in | Yes | No | Company |
| Lost key or fob | Replacement cost + $50 | D, B | After return | Yes | No | Cost: pass-through. $50: Company* |
| Tolls | Amount + $15 per toll invoice | D, B | After return | Fee only | No | Amount: pass-through. Fee: Company |
| Tickets, fines, towing and impound | Amount + $40 per item | D, B | After return | Fee only | No | Amount: pass-through. Fee: Company |
| Administration | $75 per fleet policy Damage claim; $50 per other chargeable matter, including Damage under $2,500 | D, B | After return | Yes | No | Company* |
| Declined payment | $40 | D, B | On decline | Yes | No | Company* |
| Damage under $2,500 | Actual cost: repair estimate or invoice, towing, storage, loss of use; plus the $50 administration fee | Fixed | After return | As invoiced | No | Pass-through (repair) |
| Deductible | $2,500 per incident when Damage cost is $2,500 or more and a fleet policy claim is made | Fixed | After return | No | No | Claim funds |
| Loss of use | Daily rate per day out of service, max 30 days; part of Damage cost | Fixed | After return | No | No | Claim funds |
| Interest | 1.5% per month (19.56% per year) on overdue Charges | D | Monthly | No | No | Company* |

- Company* = company only; not classified in the Master Spec.
- Claim funds pay the repair first. Any surplus is company only, or 90% owner and 10% company on a shareholder-owned car.
- Per-day fees use billable days (section 2).
- Damage of $2,500 or more bills the deductible only. Loss of use is not added on top.

## 2. Rate selection

Fixed thresholds, with Friday and Saturday as weekend days. A booking uses the rates stored on it.

| Step | Rule |
| --- | --- |
| Billable days | Hours from pickup time to return time ÷ 24, rounded up. Minimum 1, maximum 30 |
| 1 to 6 days | Each day that starts on a Friday or Saturday is charged the weekend rate; other days the daily rate. Total capped at the weekly rate |
| 7 to 29 days | Weekly rate ÷ 7 × days. Total capped at the monthly rate |
| 30 days | Monthly rate |
| Over 30 days | Not allowed in one transaction. The renter renews with a new booking and agreement, priced on its own length |
| Rounding | To the cent, half up |

Examples: daily $100, weekend $120, weekly $560, monthly $1,800.

| Booking | Days | Calculation | Rental charge |
| --- | --- | --- | --- |
| Thursday 10:00 to Sunday 10:00 | 3 | $100 + $120 + $120 | $340 |
| Monday 09:00 to Sunday 09:00 | 6 | 4 × $100 + 2 × $120 = $640, capped | $560 |
| 10 days | 10 | $560 ÷ 7 × 10 | $800 |
| 45 days wanted | 30, then 15 | $1,800, then a renewal at $560 ÷ 7 × 15 = $1,200 | $3,000 over two transactions |

## 3. Deposit

| Rule | Value |
| --- | --- |
| Method, 7 days or less | Card hold (authorized, not captured) |
| Method, over 7 days | Charged, then refunded |
| Taken | At pickup, before handover |
| Applied to | Any Charges, before the Card on File is charged. It does not cap what the renter owes |
| Release | Balance within 7 business days after Check-in |
| Hold-back | The amount reasonably expected for a pending claim, toll or ticket, for up to 30 days after Check-in, then applied or released |
| Hold expiry | A hold lapses after about 7 days. At Check-in, capture what is owed or held back and release the rest |
| Extension past 7 days in total | Capture the hold. It becomes a charged deposit |
| Renewal | The deposit carries to the new transaction |

## 4. Payment timeline

| Stage | What happens |
| --- | --- |
| Booking | Charge rental charge less any discount, delivery, pickup, young driver, additional driver, winter tire, baby seat, coverage and HST. The agreement is signed through an electronic signature service. The booking is confirmed only when payment succeeds |
| Pickup | Take the deposit. Release the vehicle only after identity and coverage are confirmed |
| During rental | Charge extensions before the return time |
| Check-in | Assess mileage overage, late return, fuel or recharging, cleaning, pet cleaning, smoking, lost key. Record Damage |
| Within 48 hours | Report to the renter any Damage not visible at return |
| Within 7 business days | Email an itemized statement. Take Charges from the deposit, then the Card on File. Release the balance |
| Up to 30 days | Apply or release any held-back amount |
| Any time after | Bill tolls, tickets, Damage and the deductible to the Card on File, each with a statement and its supporting record |

## 5. Cancellation and refunds

Notice runs from when the cancellation is received to the pickup time. The first row that fits applies.

| Cancellation received | Refund |
| --- | --- |
| Within 24 hours of booking and 48 hours or more before start | 95% |
| 48 hours or more before start | 75% |
| 24 hours or more, but less than 48 hours, before start | 50% |
| Less than 24 hours before start, or after start, including a no-show | None |

| Rule | Value |
| --- | --- |
| Percentage applies to | The total paid at booking, HST included. Refunds are paid within 10 business days. Any deposit already taken is returned in full |
| Non-refundable booking | 10% off the rental charge only, not fees. Never refunded |
| CarmaCars cancels, or a driver cannot be verified | 100% refund, including non-refundable bookings |
| False documents, or no coverage at pickup | A cancellation by the renter at that time |
| Retained amount | Split across the booking's lines in proportion. The rental charge part is Owner Revenue. No kickback |

Examples: rental charge $600 + HST $78 = $678 paid.

| Case | Tier | Refund | Retained |
| --- | --- | --- | --- |
| Booked 10 days ahead, cancelled 5 hours after booking | 95% | $644.10 | $33.90 |
| Cancelled 3 days before start | 75% | $508.50 | $169.50 |
| Booked 30 hours before start, cancelled 1 hour later | 50% | $339.00 | $339.00 |

## 6. Extensions, early returns, renewals

| Event | Rule |
| --- | --- |
| Extension | Valid only when confirmed in writing and paid before the return time. Total length stays at 30 days or less. Recompute the rental charge for the new total length at the booking's stored rates and charge the difference, plus per-day fees up to their caps and HST |
| Mileage allowance | Vehicle allowance per day × billable days |
| Early return | No refund. An unused extension is an early return |
| Renewal | New booking and agreement made before the current rental ends, linked to the earlier one, at current rates. Per-rental fee caps restart. CarmaCars may refuse |
| Breakdown, not the renter's fault | Replacement vehicle, or refund of unused days |
| Rental ended by accident, theft or breach | No refund |

## 7. Failed payments, chargebacks, later charges

| Event | Rule |
| --- | --- |
| Payment fails at booking | Booking not confirmed. No fee |
| Card on File declined | $40 fee once per charge, with retries after 1, 3 and 7 days. Ask the renter to pay another way |
| Unpaid 24 hours after request, during a rental | Alert an admin, who may end the rental |
| Overdue | Interest compounds monthly from 7 days after the statement. Collection and legal costs are billed at cost |
| Charges after return | Allowed until all Charges are paid. Each needs an emailed itemized statement with its supporting record |
| Chargeback | Contest with the signed agreement, consents, Condition Report, Tracker data and statement. The amount stays owed. Owner Revenue in dispute is withheld from the payout, and reversed if the dispute is lost |

## 8. Splitting a booking

| Step | Formula |
| --- | --- |
| 1. Kickbacks | The Referral Kickback: 20% × rental charge, after discount and before HST, when an owner referred the renter and this is the renter's first rental; an owner earns none on a booking of their own vehicle. Plus every Staff Commission on the booking (0058): the commission of the staff member who sourced or referred it (field staff 10%, other staff 10%, Sales by monthly tier). All deducted before Owner Revenue on an owner's car; never on a cancelled booking |
| 2. Owner Revenue | Rental charge, including late-return extra days, + mileage overage − kickback |
| 3. Company share | Owner Revenue × the vehicle's company share (10% on a shareholder-owned car; 0% when the owner manages rentals; CarmaCars still collects the money through its checkout) |
| 4. Owner payout | Owner Revenue − company share, paid on the 10th of the month |

First rental = the renter's first completed booking, with its extensions, not renewals or cancelled bookings.

| Referred $1,000 rental | Kickback | Owner Revenue | Company | Owner |
| --- | --- | --- | --- | --- |
| Third-party car, 25% company share | $200 | $800 | $200 | $600 |
| Shareholder-owned car, 90/10 | $200 | $800 | $80 | $720 |

## 9. Owner rentals

| Item | Rule |
| --- | --- |
| Rental charge, Schedule fees, deposit, coverage | None |
| Owner damages the car | Under $2,500: the owner repairs it at their own cost. Fleet policy claim made: $2,500 deductible billed to the owner |
| Tolls and tickets | Billed at cost, no administration fee |
| Split | No Owner Revenue, kickback or payout |

## 10. Data fields

| Group | Fields |
| --- | --- |
| Booking | id, agreement number, renewal of, type (standard, non-refundable, owner), status, vehicle, renter, additional drivers with birth dates, booked at, start, end, Check-in time, billable days |
| Price snapshot | daily, weekend, weekly and monthly rates; rate applied; periods; rental charge; discount; km allowance; overage rate; every fee rate and cap; deductible |
| Line items | charge type, quantity, unit amount, amount, HST flag, HST amount, belongs to, stage, payment id, override by and reason |
| Deposit | amount, method, hold id, taken at, expires at, applied, held back and reason, released at |
| Payments | processor id, kind (charge, hold, capture, refund), amount, status, decline count, dispute status, statement sent at |
| Cancellation | received at, cancelled by, tier, refund percent, refund amount, retained amount |
| Check-in | odometer out and in, fuel or charge out and in, minutes late, Condition Report ids |
| Damage | incident id, Damage cost, claim made, deductible billed, loss-of-use days |
| Split | referrer, referrer type, first rental flag, kickback, Owner Revenue, company share percent, company share, owner payout, payout month |

---

Tab: Review notes

# Review notes

| For | Check |
| --- | --- |
| Accountant | Whether HST applies as drafted. Added: coverage sold, late return, smoking, lost key, both administration fees, declined payment. Fee only: tolls, tickets. As invoiced: Damage. None: deductible, loss of use |
| Accountant | Whether coverage sold is insurance (HST exempt, Ontario retail sales tax may apply) or a taxable waiver |
| Accountant | Whether fees charged for a breach, and amounts kept on cancellation, already include HST. The agreement states all fees are before HST |
| Accountant | HST on deposits: none when taken; treatment when a deposit is applied to a Charge |
| Accountant | HST returned on each refund tier, and the credit note required |
| Accountant | Tax reporting for kickbacks paid to owners and commissions paid to staff |
| Lawyer | Consumer Protection Act limits on fixed fees, the kept share on cancellation, and non-refundable bookings |
| Lawyer | Whether $300 smoking, 1.5 × daily rate late return and $40 declined payment stand as cost estimates |
| Lawyer | Card network rules on charging Damage and other amounts after return without a new consent |
| Lawyer | Whether selling coverage needs an insurance licence |
| Lawyer | Keeping part of a deposit for 30 days when a card hold lapses after about 7 days |
