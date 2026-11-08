-- 99: the location of a clock in and out (migration 0881, release 35, part T). Fixtures "r35l"; example.test only.
select test.suite('99 r35t clock in and out location');
grant usage on schema test to service_role;
select test.mk_user('r35l_fleet', 'va', 'fleet');
select test.mk_user('r35l_cs', 'va', 'cs');
select test.mk_user('r35l_a', 'field');
select test.mk_user('r35l_b', 'field');
create function test.r35l(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'ops_do', p_name, p) $$;
update program_settings set company_latitude = 43.700000, company_longitude = -79.400000;

-- at the lot (about 55 m away)
select test.eq('at the lot: clocks in with the place kept, no flag', (select (x -> 'loc' -> 'in' ->> 'flag') is null and (x -> 'loc' -> 'in' ->> 'distance_m')::int < 500 and (x -> 'loc' -> 'in' ->> 'lat')::numeric = 43.7005
  from (select test.r35l('r35l_a', 'field_clock_in', jsonb_build_object('lat', 43.7005, 'lng', -79.4, 'accuracy', 12.4, 'located_at', now())) x) q), true);
select test.eq('the accuracy is kept in whole metres', (select in_accuracy_m from field_shifts where staff_id = test.id('r35l_a') and ended_at is null), 12);
-- away from the lot
select test.throws('far from the lot without a reason: refused with the distance', $$select test.r35l('r35l_b', 'field_clock_in', jsonb_build_object('lat', 43.8, 'lng', -79.4, 'accuracy', 10))$$, 'from the lot');
select test.eq('far with a reason: clocks in, flagged far', (select x -> 'loc' -> 'in' ->> 'flag' from (select test.r35l('r35l_b', 'field_clock_in', jsonb_build_object('lat', 43.8, 'lng', -79.4, 'accuracy', 10, 'location_reason', 'At the airport lot')) x) q), 'far');
select test.eq('the flag is in the log', (select count(*) from audit_log where action = 'field_clock_in_flagged' and entity_id = (select id::text from field_shifts where staff_id = test.id('r35l_b'))), 1::bigint);
-- no location
select test.throws('location refused, no reason: refused', $$select test.r35l('r35l_a', 'field_clock_out', jsonb_build_object('note', 'x'))$$, 'location is needed');
select test.eq('location refused with a reason: clocks out, flagged', (select (x -> 'loc' -> 'out' ->> 'flag') || '/' || (x -> 'loc' -> 'out' ->> 'reason') from (select test.r35l('r35l_a', 'field_clock_out', jsonb_build_object('location_reason', 'Phone location is off')) x) q), 'no_location/Phone location is off');
select test.eq('one closed shift for the first person', (select count(*) from field_shifts where staff_id = test.id('r35l_a') and ended_at is not null), 1::bigint);
-- the lot's location not set: a place, no distance, no far flag
update program_settings set company_latitude = null, company_longitude = null;
select test.eq('the lot''s location unset: the clock out has a place and no flag', (select (x -> 'loc' -> 'out' ->> 'flag') is null and (x -> 'loc' -> 'out' ->> 'lat') is not null
  from (select test.r35l('r35l_b', 'field_clock_out', jsonb_build_object('lat', 43.8, 'lng', -79.4)) x) q), true);
-- who reads it
select test.eq('Fleet reads the hours with where each shift started', (select count(*) from jsonb_array_elements(public.door(test.id('r35l_fleet'), null, 'ops_read', 'field_pay', '{}') -> 'shifts') s
  where s -> 'loc' -> 'in' ->> 'flag' = 'far'), 1::bigint);
select test.eq('the person reads their own recent shifts with the place', (select count(*) from jsonb_array_elements(public.door(test.id('r35l_b'), null, 'ops_read', 'field_hours', '{}') -> 'recent') s
  where s -> 'loc' -> 'in' ->> 'flag' = 'far'), 1::bigint);
set role authenticated;
select set_config('request.jwt.claim.sub', test.id('r35l_b')::text, false);
select test.eq('rls: a person reads only their own shifts', (select count(*) from field_shifts where staff_id <> test.id('r35l_b')), 0::bigint);
select set_config('request.jwt.claim.sub', test.id('r35l_cs')::text, false);
select test.eq('rls: customer service reads none', (select count(*) from field_shifts), 0::bigint);
reset role;
