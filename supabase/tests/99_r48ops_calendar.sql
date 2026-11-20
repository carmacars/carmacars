-- 99: release 48, operations screens (3290, 3291). The fleet calendar's fast read gives every role exactly what the read
-- it replaces gave, plus the end-of-trip fields; the earnings calculator's conservative, seasonal settings.
-- docs/changes/2026-11-20-r48-ops-screens.md. Fixtures start with "oc" and use example.test only.
select test.suite('99 r48 ops: calendar read and calculator settings');

select test.mk_user('oc_admin', 'admin');
select test.mk_user('oc_fleet', 'va', 'fleet');
select test.mk_user('oc_cs', 'va', 'cs');
select test.mk_user('oc_sales', 'va', 'sales');
select test.mk_user('oc_fin', 'va', 'finance');
select test.mk_owner('oc_olga');
select test.mk_owner('oc_omar');
select test.mk_vehicle('oc_a', 'oc_olga');
select test.mk_vehicle('oc_b', 'oc_olga');
select test.mk_vehicle('oc_c', 'oc_omar');
select test.mk_renter('oc_rita_renter');
select test.mk_renter('oc_ravi_renter');
update vehicles set turnaround_block_minutes = 120 where id = test.id('vehicle:oc_a');

create or replace function pg_temp.at(p interval) returns text language sql stable as $$ select to_char((date_trunc('hour', now()) + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
-- car A: a finished trip (came back late), a trip out now, a confirmed one that clashes with a request, and an offer
select test.mk_booking('OC-DONE', 'oc_a', 'oc_rita_renter', pg_temp.at(interval '-6 days'), pg_temp.at(interval '-3 days'), 'closed', null, 'standard', null, null, pg_temp.at(interval '-3 days' + interval '95 minutes'));
select test.mk_booking('OC-OUT', 'oc_a', 'oc_ravi_renter', pg_temp.at(interval '-1 day'), pg_temp.at(interval '2 days'), 'on_rent');
select test.mk_booking('OC-NEXT', 'oc_a', 'oc_rita_renter', pg_temp.at(interval '4 days'), pg_temp.at(interval '6 days'), 'confirmed');
select test.mk_booking('OC-REQ', 'oc_a', 'oc_ravi_renter', pg_temp.at(interval '5 days'), pg_temp.at(interval '7 days'), 'requested');
select test.mk_booking('OC-OFF', 'oc_b', 'oc_rita_renter', pg_temp.at(interval '3 days'), pg_temp.at(interval '5 days'), 'offered');
select test.mk_booking('OC-PH', 'oc_b', 'oc_ravi_renter', pg_temp.at(interval '8 days'), pg_temp.at(interval '9 days'), 'confirmed');
update bookings set is_placeholder = true, placeholder_reason = 'Insurer hold', blocks_calendar = false,
  blocks_calendar_changed_by = test.id('oc_admin'), blocks_calendar_changed_at = now(), blocks_calendar_reason = 'Insurer hold' where booking_number = 'OC-PH';
update bookings set offer_expires_at = now() + interval '5 hours' where booking_number = 'OC-OFF';
update bookings set notes = 'Call before delivery' where booking_number = 'OC-NEXT';
-- a service block over the confirmed trip, the cleaning block of the finished trip, a return job, a move, a Turo trip
insert into vehicle_calendar_blocks (id, vehicle_id, reason, starts_at, ends_at, note)
values (test.id('oc_block'), test.id('vehicle:oc_a'), 'service', date_trunc('hour', now()) + interval '5 days', date_trunc('hour', now()) + interval '5 days 4 hours', 'Brakes');
insert into vehicle_calendar_blocks (id, vehicle_id, reason, starts_at, ends_at, note, booking_id, source)
select test.id('oc_clean'), b.vehicle_id, 'cleaning', b.checked_in_at, b.checked_in_at + interval '2 hours', 'Cleaning after booking ' || b.booking_number, b.id, 'turnaround'
  from bookings b where b.booking_number = 'OC-DONE'
on conflict do nothing;
insert into field_jobs (id, kind, booking_id, vehicle_id, scheduled_at, status, completed_at, instructions, assigned_to)
select test.id('oc_job'), 'return_check_in', b.id, b.vehicle_id, b.return_at, 'done', b.checked_in_at + interval '20 minutes', 'Check the spare key', null
  from bookings b where b.booking_number = 'OC-DONE';
insert into field_jobs (id, kind, booking_id, vehicle_id, scheduled_at, status)
select test.id('oc_job2'), 'return_check_in', b.id, b.vehicle_id, b.return_at, 'scheduled' from bookings b where b.booking_number = 'OC-OUT';
insert into vehicle_clean_checks (vehicle_id, booking_id, moment, clean, checked_by, checked_at)
select b.vehicle_id, b.id, 'after_return', true, test.id('oc_fleet'), b.checked_in_at + interval '70 minutes' from bookings b where b.booking_number = 'OC-DONE';
insert into vehicle_moves (vehicle_id, staff_user_id, purpose, from_place, to_place, started_at, ended_at)
values (test.id('vehicle:oc_c'), test.id('oc_fleet'), 'service', 'Yard', 'Shop', now() - interval '2 hours', now() - interval '1 hour');

-- the two reads, as one role: everything the old read gave, entry for entry (the new fields set aside, clashes in order)
create or replace function pg_temp.norm(j jsonb) returns table (vid text, veh jsonb, eid text, ent jsonb) language sql as $$
  select v ->> 'id', v - 'entries', (e ->> 'type') || (e ->> 'id'),
         (e - 'returned_at' - 'for_booking' - 'done_at' - 'job' - 'cleaned_at' - 'clash')
           || jsonb_build_object('clash', (select coalesce(jsonb_agg(x order by x), '[]'::jsonb) from jsonb_array_elements_text(e -> 'clash') x))
    from jsonb_array_elements(j -> 'vehicles') v left join lateral jsonb_array_elements(v -> 'entries') e on true
$$;
create or replace function pg_temp.same(p_user uuid, p_from timestamptz, p_to timestamptz, p_vehicle uuid default null) returns text language plpgsql as $$
declare o jsonb; n jsonb; d bigint; rows bigint;
begin
  perform set_config('request.jwt.claim.sub', p_user::text, false);
  o := app.admin_calendar_pre3290(p_from, p_to, p_vehicle);
  n := app.admin_calendar(p_from, p_to, p_vehicle);
  perform set_config('request.jwt.claim.sub', '', false);
  select count(*) into rows from pg_temp.norm(n);
  select count(*) into d from ((select * from pg_temp.norm(o) except select * from pg_temp.norm(n)) union all (select * from pg_temp.norm(n) except select * from pg_temp.norm(o))) x;
  return case when d = 0 and rows > 0 and (select jsonb_agg(v ->> 'id') from jsonb_array_elements(o -> 'vehicles') v) is not distinct from (select jsonb_agg(v ->> 'id') from jsonb_array_elements(n -> 'vehicles') v)
              then 'same' else format('%s differences in %s rows', d, rows) end;
end $$;
select test.eq('calendar: an Admin reads what the old read gave', pg_temp.same(test.id('oc_admin'), now() - interval '8 days', now() + interval '12 days'), 'same');
select test.eq('calendar: Fleet reads what the old read gave', pg_temp.same(test.id('oc_fleet'), now() - interval '8 days', now() + interval '12 days'), 'same');
select test.eq('calendar: customer service reads what the old read gave', pg_temp.same(test.id('oc_cs'), now() - interval '8 days', now() + interval '12 days'), 'same');
select test.eq('calendar: Sales reads what the old read gave (first names, no notes, no jobs)', pg_temp.same(test.id('oc_sales'), now() - interval '8 days', now() + interval '12 days'), 'same');
select test.eq('calendar: Finance reads what the old read gave', pg_temp.same(test.id('oc_fin'), now() - interval '8 days', now() + interval '12 days'), 'same');
select test.eq('calendar: one car, one day', pg_temp.same(test.id('oc_admin'), now() + interval '5 days', now() + interval '6 days', test.id('vehicle:oc_a')), 'same');
select test.eq('calendar: an owner reads only their own cars, as before', pg_temp.same(test.id('oc_olga'), now() - interval '8 days', now() + interval '12 days'), 'same');

-- what each role is and is not given, said outright (not only "as before")
create temp table oc as select null::text as k, null::jsonb as j limit 0;
create or replace function pg_temp.cal(p_label text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform set_config('request.jwt.claim.sub', test.id(p_label)::text, false);
  v := app.admin_calendar(now() - interval '8 days', now() + interval '12 days');
  perform set_config('request.jwt.claim.sub', '', false);
  return v;
end $$;
insert into oc values ('admin', pg_temp.cal('oc_admin')), ('sales', pg_temp.cal('oc_sales')), ('owner', pg_temp.cal('oc_olga')), ('nobody', app.admin_calendar(now() - interval '8 days', now() + interval '12 days'));
create or replace function pg_temp.e(p_k text, p_number text) returns jsonb language sql stable as $$
  select e from oc, jsonb_array_elements(oc.j -> 'vehicles') v, jsonb_array_elements(v -> 'entries') e where oc.k = p_k and e ->> 'booking_number' = p_number and e ->> 'type' = 'booking' limit 1 $$;
create or replace function pg_temp.ents(p_k text, p_type text) returns setof jsonb language sql stable as $$
  select e from oc, jsonb_array_elements(oc.j -> 'vehicles') v, jsonb_array_elements(v -> 'entries') e where oc.k = p_k and e ->> 'type' = p_type $$;
select test.eq('calendar: nobody signed in reads no car', (select jsonb_array_length(j -> 'vehicles') from oc where k = 'nobody'), 0);
select test.eq('calendar: an Admin has the full name and the note', (select (x ->> 'renter') || '/' || (x ->> 'note') from pg_temp.e('admin', 'OC-NEXT') x), 'Oc Rita Renter/Call before delivery');
select test.eq('calendar: Sales has the first name only and no note', (select (x ->> 'renter') || '/' || coalesce(x ->> 'note', 'none') from pg_temp.e('sales', 'OC-NEXT') x), 'Oc/none');
select test.eq('calendar: Sales reads no field job and no car move', (select count(*) from pg_temp.ents('sales', 'field_job')) + (select count(*) from pg_temp.ents('sales', 'vehicle_move')), 0::bigint);
select test.ok('calendar: an Admin reads the field jobs and the move', (select count(*) from pg_temp.ents('admin', 'field_job')) >= 2 and (select count(*) from pg_temp.ents('admin', 'vehicle_move')) = 1);
select test.ok('calendar: an owner reads their cars only', (select bool_and(v ->> 'id' in (test.id('vehicle:oc_a')::text, test.id('vehicle:oc_b')::text)) and count(*) = 2
  from oc, jsonb_array_elements(oc.j -> 'vehicles') v where oc.k = 'owner'));
select test.eq('calendar: the request clashes with the confirmed trip, the service block and the cleaning after that trip, in order',
  (select x -> 'clash' from pg_temp.e('admin', 'OC-REQ') x), '["OC-NEXT", "Service", "Cleaning"]'::jsonb);
select test.eq('calendar: the placeholder is marked and clashes with nothing', (select (x ->> 'placeholder') || '/' || jsonb_array_length(x -> 'clash') from pg_temp.e('admin', 'OC-PH') x), 'true/0');
select test.eq('calendar: an open offer carries when its hold ends', (select (x ->> 'hold_until')::timestamptz from pg_temp.e('admin', 'OC-OFF') x), (select offer_expires_at from bookings where booking_number = 'OC-OFF'));

-- the end of a trip: the return is a check-out with the time the car actually came back; the cleaning is a job of its own
select test.eq('return: the booking carries when the car actually came back', (select (x ->> 'returned_at')::timestamptz from pg_temp.e('admin', 'OC-DONE') x),
  (select checked_in_at from bookings where booking_number = 'OC-DONE'));
select test.ok('return: later than it was due', (select (x ->> 'returned_at')::timestamptz > (x ->> 'ends_at')::timestamptz from pg_temp.e('admin', 'OC-DONE') x));
select test.eq('return: a trip still out has no return time', (select x ->> 'returned_at' from pg_temp.e('admin', 'OC-OUT') x), null);
select test.eq('return job: named for its booking, with when it was done', (select (x ->> 'for_booking') || '/' || (x ->> 'detail') || '/' || ((x ->> 'done_at') is not null) from pg_temp.ents('admin', 'field_job') x where x ->> 'id' = test.id('oc_job')::text),
  'OC-DONE/return_check_in/true');
select test.eq('cleaning: the block a trip leaves is the Post-trip cleaning job of that booking, done at its clean check',
  (select (x ->> 'job') || '/' || (x ->> 'for_booking') || '/' || ((x ->> 'done_at')::timestamptz = (select min(checked_at) from vehicle_clean_checks where booking_id = test.id('booking:OC-DONE')))
     from pg_temp.ents('admin', 'block') x where x ->> 'reason' = 'cleaning' and x ->> 'for_booking' = 'OC-DONE'), 'post_trip_cleaning/OC-DONE/true');
select test.eq('cleaning: any other block is not a job', (select x ->> 'job' from pg_temp.ents('admin', 'block') x where x ->> 'id' = test.id('oc_block')::text), null);
select test.eq('cleaning: the booking carries its clean check too', (select ((x ->> 'cleaned_at') is not null)::text from pg_temp.e('admin', 'OC-DONE') x), 'true');

-- the read is one set-based query: the indexes it leans on exist
select test.eq('calendar: indexes for the dates asked', (select count(*) from pg_indexes where schemaname = 'public'
  and indexname in ('bookings_return_at_idx', 'field_jobs_scheduled_at_idx', 'field_jobs_completed_at_idx', 'turo_trips_ends_at_idx')), 4::bigint);
select test.ok('calendar: the read is for the server only', not has_function_privilege('anon', 'app.admin_calendar(timestamptz, timestamptz, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'app.admin_calendar(timestamptz, timestamptz, uuid)', 'execute')
  and has_function_privilege('service_role', 'app.admin_calendar(timestamptz, timestamptz, uuid)', 'execute'));

-- ================================================================ 3291: the earnings calculator, conservative and seasonal
select test.ok('calculator: the page is given the season, the starting days and the discount, with what it had',
  (select public.owner_calc_data() ?& array['classes', 'models', 'rules', 'fees', 'year', 'season', 'base_days', 'discount_pct']));
select test.eq('calculator: 12 rented days in an average month from the start, 15% off the listed rate',
  (select (d ->> 'base_days') || '/' || (d ->> 'discount_pct') from public.owner_calc_data() d), '12/15');
select test.ok('calculator: summer busiest, winter slow, the shoulder months slowest',
  (select least((s ->> 'jun')::numeric, (s ->> 'jul')::numeric, (s ->> 'aug')::numeric) > greatest((s ->> 'dec')::numeric, (s ->> 'jan')::numeric, (s ->> 'feb')::numeric)
      and greatest((s ->> 'mar')::numeric, (s ->> 'apr')::numeric, (s ->> 'oct')::numeric, (s ->> 'nov')::numeric) <= least((s ->> 'dec')::numeric, (s ->> 'jan')::numeric, (s ->> 'feb')::numeric)
      and (select avg((v #>> '{}')::numeric) from jsonb_each(s) x(k, v)) < 1
     from (select public.owner_calc_data() -> 'season' as s) q));
select test.throws('calculator: a season missing a month is refused',
  $$update program_settings set owner_calc_season = '{"jan": 1}'::jsonb where id = (select id from app.settings())$$, 'owner_calc_season');
select test.throws('calculator: more than 28 days is refused',
  $$update program_settings set owner_calc_base_days = 31 where id = (select id from app.settings())$$, 'owner_calc_base_days');
update program_settings set owner_calc_base_days = 9, owner_calc_discount_pct = 20 where id = (select id from app.settings());
select test.eq('calculator: an Admin''s numbers reach the page', (select (d ->> 'base_days') || '/' || (d ->> 'discount_pct') from public.owner_calc_data() d), '9/20');
update program_settings set owner_calc_base_days = 12, owner_calc_discount_pct = 15 where id = (select id from app.settings());
select test.ok('calculator: a visitor reads it, as before', has_function_privilege('anon', 'public.owner_calc_data()', 'execute'));
