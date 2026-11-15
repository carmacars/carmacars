# The connector accepts a licence from outside Ontario on one booking (Release 48: 3013)

Migration `3013_r48_connector_licence_let_go.sql`.

The Admin's **Let it go** (a main driver keeps a licence from outside Ontario, international or another province, on one booking) had no connector tool.

- `licence_let_go {booking, reason}`: an Admin only, previewed then confirmed like every write; it runs `app.primary_swap_decide` (override) as the key's Admin. The booking history says "Main driver kept with a licence from outside Ontario: <reason> (connector)", and every call is in `api_calls`. Refused when the booking has no main driver waiting on an Ontario licence.
- `change_booking`'s description says it takes a booking partly paid (3011).
- Tests: `supabase/tests/99_r48_plan_edit_licence.sql`, `web/src/features/api-access/tools.test.ts`.

## Guides

- `admin/requests-offers-and-bookings`: the connector's `change_booking` and `licence_let_go`.
