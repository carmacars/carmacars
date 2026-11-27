-- R50 hotfix 2 (5141): the earnings calculator's rule comes from Program settings through owner_calc_data: the typical month
-- ($1,200) at 80% occupancy, the $800 floor, the age step, the age past which a premium make is not priced as premium, and
-- the demand by class; an Admin's change reaches the page. The maths is in web/src/features/owner/earnings.test.ts.
select test.suite('99 r50h2 owner calc');
select test.eq('calc: the owner''s rule by default (typical, floor, occupancy, age, step, premium age, SUV and economy demand)',
  (select concat_ws('/', t ->> 'typical_cents', t ->> 'floor_cents', t ->> 'occupancy_pct', t ->> 'typical_age', t ->> 'age_step_pct', t ->> 'premium_max_age',
                    t -> 'class_factor' ->> 'suv', t -> 'class_factor' ->> 'economy') from (select public.owner_calc_data() -> 'target' t) x),
  '120000/80000/80/5/5/8/1.1/0.9');
select test.eq('calc: what it returned before is still there (classes, rules, season, fees)',
  (select (d ? 'classes') and (d ? 'rules') and (d ? 'season') and (d ? 'fees') from (select public.owner_calc_data() d) x), true);
update program_settings set owner_calc_typical_cents = 110000, owner_calc_floor_cents = 75000 where id = (select id from app.settings());
select test.eq('calc: an Admin''s change reaches the page', (select (t ->> 'typical_cents') || '/' || (t ->> 'floor_cents') from (select public.owner_calc_data() -> 'target' t) x), '110000/75000');
select test.throws('calc: the occupancy stays a real occupancy', format('update program_settings set owner_calc_occupancy_pct = 100 where id = %L', (select id from app.settings())), 'owner_calc_occupancy_pct');
select test.ok('calc: a visitor reads it (the page has no sign-in)', has_function_privilege('anon', 'public.owner_calc_data()', 'execute'));
select test.ok('calc: the inner function is not served to browsers', not has_function_privilege('anon', 'app.owner_calc_data_pre5141()', 'execute'));
