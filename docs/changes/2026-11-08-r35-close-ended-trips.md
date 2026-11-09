# Close ended trips, deposits, return charges and the late return (Release 35, part K: 1063)

Migration `1063_r35k_ended_trips_money.sql` (no applied migration edited: `public.calc_late_return` and `app.past_trips_allowed`
replaced; `app.handover_override` and `public.server_hiring_apply` wrapped; `app.set_assessed_line`, `app.booking_app_before`,
`app.guard_deposit_release` and the late return's callers patched). Tests: `supabase/tests/99_r35k_staff_onboarding.sql` (sections 10 to 13),
`01_rules.sql` and `09_operations.sql` (the late return's new figures), `web/src/features/past-trips/ended.test.ts`.

| Item | What changed |
| --- | --- |
| Close ended trips | Admin > Bookings (banner and page), Fleet and Finance (`/staff/past-trips`): every booking past its return and not closed: never picked up in the system, on rent, or returned and not closed (`ended_trips`). Rows ticked in bulk: returned on time, late at a time (0910's `past_trip_close`), or a no-show (Admin or customer service, `cancel_booking`) |
| Deposit decision | Release in full, deduct the balance owed, or deduct the late fee (`trip_close_decisions`), waiting for an Admin's Release (an Admin To do, `trip_close_release`), which runs the usual settlement (`deposit_settle_screen`, then the money steps). Nothing is released or refunded by itself |
| Deposit not taken | "Admin: deposit not taken, waive it because" in Record a past trip and on Close ended trips (`app.k_waive_deposit`). 0019's rule stands: no car goes without the deposit or this waiver |
| Hold expired | Mark settled (released by expiry) on the booking's Money tab (Admin, Finance, Fleet; `deposit_expired_settle`): settled, no money moves; Close ended trips does it by itself for returned trips |
| Return lines | An Admin changes the amount (lower) or waives any renter line not on a statement and not paid (`line_adjust`), with the reason, audited and in the booking history; the next assessment keeps the decision |
| Late return | The owner's rule: whole days late are extra days at the booking's full daily cost (`app.booking_daily_cost_cents`: the rental per day after discounts plus per-day and per-trip fees, never delivery, pickup or an add-on item), and only the started hours after them get the hourly late fee (capped per day as before, the grace on that remainder). 1 day 1 hour late: 1 extra day and 1 hour. A return late by hours only is still a late return |

## Guides

- `admin/requests-offers-and-bookings`: Close ended trips, return charges.
- `va/fleet`: Close ended trips.
- `va/finance`: Close ended trips.
