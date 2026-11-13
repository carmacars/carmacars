# Booking totals, insurer paperwork, after-trip agreements, real money only (Release 44, part B)

Branch `r44-b`. Migrations 2810 to 2815 and 2819. DB tests: `supabase/tests/99_r44b_live_fixes.sql`. Unit tests:
`web/src/features/blindspot/fill.test.ts`, `web/src/features/documents/invoice-blocks.test.ts`,
`web/src/features/money/money-panels.test.ts`, `web/src/features/agreement/after-trip.test.ts`.

Bugs found in live use on November 13, 2026, and the r44 queue.

## What changed

| Part | Root cause | Fix |
| --- | --- | --- |
| Change amount on a line (2810) | `app.line_adjust` changed the line only; the booking's total stayed, so the fees part (total less rental) grew by the change with its HST: a $10.83 "rental due" on a hand-set booking | Every change of a line at booking moves the subtotal, HST, total, renter's share and rental charge by the line's change (`app.booking_totals_shift`). An Admin sets a total cleanly: **Change the total** on the Money tab (`booking_total_set`), the rental charge line takes the difference (tax included) |
| Insurer agreement (2811) | The Blind Spot form derived box 35 and box 14 from the booking's own monthly or weekly rate | The form's facts carry the insurer's share as its invoice computes it (`app.booking_insurer_share`): box 35 is the days at the insurer's daily rate, the totals are the invoice's to the cent (`layout.ts`, `insurerRental`) |
| After-trip agreement (2812, 2819) | No agreement was opened for a returned or closed booking, and the version job only re-renders an existing one | An Admin's **Make the agreements again** or **Prepare the agreement** on Sign on this device opens it (as staff: the renter may have no account), signed as a rental added by hand is and countersigned at once; blanks print blank |
| Insurer invoices (2811, emails) | The PDF had no cheque section; an e-Transfer address, a fee name or the email layout could carry the CarmaCars name; the footer read the facts' `final` | A Cheque section (payable to the legal entity, mailed to the company address, quoting invoice and claim); the name is taken out of every insurer PDF and the Blind Spot emails have their own header, footer and contact line; the footer follows the invoice's status |
| Protection Plan, unknown value (2813) | The setting was off by default; the protection change on a booking asked only for a price, so the booking's guard refused the save later | On by default; `app.protection_block` asks `app.rentalcover_allowed` first; priced as any car (quote, else the Fees price) |
| Payment records (2810, UI) | A failed card attempt always offered "Paid another way"; a deposit row marked captured with no money read "Charged" | The failed attempts list says Settled, Nothing owing, or offers the record button; a deposit with no money recorded reads Not collected; Data Health (Finance) lists **Deposit without money** |
| AI auto-reply (2814) | A staff reply to "Name <address>", or to the customer's booking or account, was not found; the live chat's assistant never asked | Matched by address, renter, account and booking; a staff message in the chat hands it to the person |
| Sales keeps the customer (2814) | 2750 opened the booking page, its email thread and activity, but not the staff window rule used by chats, calls and lists | `app.va_sees_renter` counts the closer |
| Instant book | Only on the booking page | **Take instant booking away** on the Admin renter page |
| Renter check-out and problem reports | The returned-car routes refused an `Origin: null` (in-app browsers, the text message link) and compared hosts with www.; the Worker's guard allows both | `foreignOrigin` takes Sec-Fetch-Site and follows the guard's rule; every route passes it; the returned-car routes use it |
| Insurer invoice email (2811) | The email went to the insurer's billing address only, and was refused without one, although the screen promised the adjuster | The adjuster's email on the booking, else the billing email; Send by email and Mark sent on the booking's insurer card |
| Past handovers (2815) | A rental recorded after the fact had no way to get its check-in or check-out report | `app.handover_missing` (list), `app.handover_open` makes a "details later" report for a past stage, `handover_missing_assign`; **Missing check-in and check-out** on field Today, Fleet and Admin Field jobs |

## Guides

No guide change in this part.
