# A payment plan's first payment confirms the booking, and no plan shows a $0.00 payment (Release 48: 3010, 3019)

Migrations `3010_r48_plan_first_instalment.sql` and `3019_r48_guides_merged.sql`.

A booking on a weekly, every 2 weeks or monthly plan stayed "waiting for payment" with its first payment paid (a live booking every 2 weeks at $925): the confirmation after a pay link or a card charge (`app.confirm_when_paid`), after a payment recorded by hand (`app.confirm_offline_booking`) and CarmaCars' countersignature (`app.complete_signature_request`) all waited for the whole total.

- `app.booking_plan_first_paid(booking)`: on a plan of more than one payment, the first one is paid. The three steps above then go ahead as for a booking paid in full; the rest is collected by the plan.
- `app.booking_pay_schedule`: a payment of $0 (a fixed amount that covers the total before the last period) is folded into the one before it, with its period: $1,850 at $925 every 2 weeks is exactly 2 payments, the second running to the return.
- The bookings already stuck that way (waiting for payment, approved, the first payment paid) are confirmed by the migration.
- 3019: each helper of release 48 published its guide chapters from its own copy of the content; every chapter release 48 changed is published once more from the merged content (`supabase/seed/3019_gen_guides.mjs`).
- Test: `supabase/tests/99_r48_plan_edit_licence.sql`.

## Guides

- `admin/requests-offers-and-bookings`: a payment of $0 is never shown; a plan's first payment confirms the booking.
