-- 5141 (R50 hotfix 2, docs/changes/2026-11-27-r50-hotfix2-ops.md): the owner earnings calculator (List your car and the
-- application) by the owner's rule, not by the listed rate.
-- What went wrong (the owner, Nov 27): a 2015 Acura RDX showed as Premium at a high daily rate and earned more than a 2025
-- Honda CR-V. The class came from the make alone (Acura: premium) whatever the car's age, the rate from the premium rate
-- card or the site's premium cars, and the month was that rate times the days, so an old car of a premium make beat a new
-- car people want more.
-- The owner's rule: at 80% occupancy a typical car makes about $1,200 a month for its owner, never under $800, and more
-- for a newer car or one in higher demand. So the calculator now starts from that month (web/src/features/owner/earnings.ts,
-- monthlyAt): typical x the age factor x the class's demand factor, at least the floor; then the days slider (starting at
-- the occupancy), the owner's share against the typical share (70%) and the season move it. A premium or luxury make older
-- than owner_calc_premium_max_age years is priced as the car under the make: its body (an SUV is an SUV) or standard.
-- Program settings (Admin > Settings > Program), read by the page through owner_calc_data ('target'):
--   owner_calc_typical_cents      120000  the owner's month at the occupancy for a typical car
--   owner_calc_floor_cents         80000  never under this at the occupancy
--   owner_calc_occupancy_pct          80  the occupancy that month is at, and where the days slider starts
--   owner_calc_typical_age             5  the age of the typical car, in years
--   owner_calc_age_step_pct            5  each year newer adds this percent, each year older takes it off (0.5x to 1.3x)
--   owner_calc_premium_max_age         8  a premium or luxury make older than this is priced as the car under the make
--   owner_calc_class_factor              demand by class (standard 1.0)
-- owner_calc_base_days (3291) no longer sets the calculator: the occupancy does. No applied migration is edited.
-- SCHEMA_MARKER 5141.
set local check_function_bodies = off;

alter table program_settings
  add column if not exists owner_calc_typical_cents integer not null default 120000 check (owner_calc_typical_cents between 10000 and 2000000),
  add column if not exists owner_calc_floor_cents integer not null default 80000 check (owner_calc_floor_cents between 0 and 2000000),
  add column if not exists owner_calc_occupancy_pct integer not null default 80 check (owner_calc_occupancy_pct between 10 and 95),
  add column if not exists owner_calc_typical_age integer not null default 5 check (owner_calc_typical_age between 0 and 30),
  add column if not exists owner_calc_age_step_pct integer not null default 5 check (owner_calc_age_step_pct between 0 and 20),
  add column if not exists owner_calc_premium_max_age integer not null default 8 check (owner_calc_premium_max_age between 1 and 40),
  add column if not exists owner_calc_class_factor jsonb not null
    default '{"economy": 0.9, "standard": 1.0, "sedan": 1.0, "coupe": 1.05, "van": 1.05, "pickup": 1.05, "suv": 1.1, "premium": 1.15, "convertible": 1.2, "luxury": 1.3, "exotic": 1.8}'::jsonb
    check (jsonb_typeof(owner_calc_class_factor) = 'object');
comment on column program_settings.owner_calc_typical_cents is 'Earnings calculator (5141): what a typical car makes for its owner in a month at the occupancy below (the owner: about $1,200).';
comment on column program_settings.owner_calc_floor_cents is 'Earnings calculator (5141): the least a car is shown to make in a month at the occupancy (the owner: never under $800).';
comment on column program_settings.owner_calc_occupancy_pct is 'Earnings calculator (5141): the occupancy the typical month is at, and where the days slider starts (80% is 24 days).';
comment on column program_settings.owner_calc_typical_age is 'Earnings calculator (5141): the age in years of the typical car.';
comment on column program_settings.owner_calc_age_step_pct is 'Earnings calculator (5141): each year newer than the typical car adds this percent, each year older takes it off (between 0.5x and 1.3x).';
comment on column program_settings.owner_calc_premium_max_age is 'Earnings calculator (5141): a premium or luxury make older than this many years is priced as the car under the make (its body, else standard).';
comment on column program_settings.owner_calc_class_factor is 'Earnings calculator (5141): renter demand by class against a standard car (1.0).';
comment on column program_settings.owner_calc_base_days is 'No longer used by the calculator (5141): the days slider starts at owner_calc_occupancy_pct.';

alter function app.owner_calc_data() rename to owner_calc_data_pre5141;
create function app.owner_calc_data() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.owner_calc_data_pre5141() || jsonb_build_object('target', jsonb_build_object(
           'typical_cents', s.owner_calc_typical_cents, 'floor_cents', s.owner_calc_floor_cents, 'occupancy_pct', s.owner_calc_occupancy_pct,
           'typical_age', s.owner_calc_typical_age, 'age_step_pct', s.owner_calc_age_step_pct, 'premium_max_age', s.owner_calc_premium_max_age,
           'class_factor', s.owner_calc_class_factor))
    from app.settings() s
$$;
comment on function app.owner_calc_data() is '5141: the calculator''s numbers (3291 and before) and its target month (the owner''s rule).';
revoke all on function app.owner_calc_data() from public;
grant execute on function app.owner_calc_data() to anon, authenticated, service_role;
revoke all on function app.owner_calc_data_pre5141() from public, anon, authenticated;
grant execute on function app.owner_calc_data_pre5141() to service_role;
