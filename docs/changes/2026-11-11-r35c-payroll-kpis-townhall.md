# Payroll, role KPIs, staff schedules, the townhall deck, lead intent, Search Console on the investor deck and fixes (Release 35, part C: 1500 to 1599)

Branch `r35-c`. No applied migration is edited.

## Fixes

| Item | What changed |
| --- | --- |
| Car change list (item 7) | `1500_r35c_change_vehicles_fix.sql`: `app.ops40` 'change_vehicles' read failed with `column reference "b.id" is ambiguous` (the query's alias `b` clashed with the function's variable `b bookings`), so the list was always empty. The booking is now read into the variable first and the query has no alias `b`. Test: `supabase/tests/99_r35c_change_vehicles.sql` |
