-- 3291 (release 48, operations screens): the host earnings calculator, conservative and seasonal.
-- The owner (Nov 20): the calculator on List your car is too optimistic. Make its numbers conservative and seasonal (GTA
-- demand: summer busiest, winter slow, the shoulder months slowest) and say clearly it is a rough estimate, not a promise.
-- Before: 18 rented days a month from the start, at the full listed daily rate, and a year as twelve of that month.
--   1. Program settings, editable by an Admin (Settings > Program), read by the page through owner_calc_data:
--        owner_calc_base_days     the rented days of an average month the calculator starts from (12: about 40% of a month)
--        owner_calc_season        the factor of each month against that average month (jan .. dec), the calculator's own
--                                 curve: summer 1.10 to 1.30, winter 0.75 to 0.85, the shoulder months 0.65 to 0.85
--        owner_calc_discount_pct  what comes off the listed daily rate on a rented day (weekly and monthly rates, promo
--                                 codes, offers): 15 by default
--      The curve is the calculator's own, apart from the owner forecast's occupancy_season (3081): that one is blended
--      with each car's real history; this one speaks to someone with no car on the program yet, so it leans low.
--   2. app.owner_calc_data returns them ('season', 'base_days', 'discount_pct') with what it returned before.
-- The page works the months out in the browser (web/src/features/owner/earnings.ts): a month's days are the days chosen
-- times the month's factor, a year is the twelve months added up, never twelve of the best month.
-- SCHEMA_MARKER 3291. docs/changes/2026-11-20-r48-ops-screens.md.
set local check_function_bodies = off;

alter table program_settings
  add column if not exists owner_calc_base_days integer not null default 12 check (owner_calc_base_days between 1 and 28),
  add column if not exists owner_calc_discount_pct integer not null default 15 check (owner_calc_discount_pct between 0 and 60),
  add column if not exists owner_calc_season jsonb not null
    default '{"jan": 0.75, "feb": 0.75, "mar": 0.70, "apr": 0.65, "may": 0.85, "jun": 1.10, "jul": 1.30, "aug": 1.30, "sep": 0.85, "oct": 0.70, "nov": 0.65, "dec": 0.85}'::jsonb
    check (app.occupancy_season_ok(owner_calc_season));
comment on column program_settings.owner_calc_base_days is 'The earnings calculator on List your car (3291): the rented days of an average month it starts from. Kept low on purpose: a new car takes time to fill.';
comment on column program_settings.owner_calc_discount_pct is 'The earnings calculator on List your car (3291): the percent that comes off the listed daily rate on a rented day (weekly and monthly rates, promo codes, offers).';
comment on column program_settings.owner_calc_season is 'The earnings calculator on List your car (3291): the factor of each month (jan .. dec) against an average month: summer busiest, winter slow, the shoulder months slowest.';

alter function app.owner_calc_data() rename to owner_calc_data_pre3291;
create function app.owner_calc_data() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.owner_calc_data_pre3291() || jsonb_build_object('season', s.owner_calc_season, 'base_days', s.owner_calc_base_days, 'discount_pct', s.owner_calc_discount_pct)
    from app.settings() s
$$;
revoke all on function app.owner_calc_data() from public;
grant execute on function app.owner_calc_data() to anon, authenticated, service_role;
revoke all on function app.owner_calc_data_pre3291() from public, anon, authenticated;
grant execute on function app.owner_calc_data_pre3291() to service_role;
