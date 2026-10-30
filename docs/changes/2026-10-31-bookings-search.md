# Bookings search (0200)

Release 21, item 1. Migration `supabase/migrations/0200_bookings_search.sql` (SCHEMA_MARKER `0206`, the release).
Tests: `supabase/tests/99_bookings_search.sql`, `web/tests/e2e/release-21a.spec.ts`.

- `app.bookings_search` (staff door `ops_read` `bookings_search`): a booking by its number (CC-1042, cc1042 or 1042),
  the renter's or a driver's name, an email, a phone number in any format, a plate (spaces and dashes ignored) or a car
  code. Each row says what matched. Newest pickup first, 50 by default (up to 200), an optional status.
- Admin > Bookings: the search box uses it (the status filters still apply). Staff portal: **Rentals > Find a booking**
  (`/staff/bookings`).
- Staff (not Admins): 3 characters at least, no email address in the results, every search logged in `data_access_log`
  as Find a renter is.

## Guides

- `admin/requests-offers-and-bookings`: Find a booking.
- `va/shared-tools`: Find a booking.
