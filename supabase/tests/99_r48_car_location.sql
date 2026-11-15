-- 99: migration 3041 (release 48): every staff role sees where the cars are (read only outside Admin and Fleet); each owner
-- sees the location and trips of their own cars only, never a booking or a renter; row level security on the position
-- history; the privacy policy names who sees the location; the lawyer's step on the owner's setup list.
-- Fixtures start with "cl41_"; no real names, plates or places.
select test.suite('99 r48 car location (3041)');

select test.mk_user('cl41_admin', 'admin');
select test.mk_user('cl41_fleet', 'va', 'fleet');
select test.mk_user('cl41_cs', 'va', 'cs');
select test.mk_user('cl41_sales', 'va', 'sales');
select test.mk_user('cl41_fin', 'va', 'finance');
select test.mk_user('cl41_field', 'field');
select test.mk_owner('cl41_ann');
select test.mk_owner('cl41_bo');
select test.mk_vehicle('cl41_a', 'cl41_ann');
select test.mk_vehicle('cl41_b', 'cl41_bo');
select test.mk_vehicle('cl41_none', 'cl41_ann');
select test.mk_renter('cl41_rita');
select test.mk_booking('CL41-1', 'cl41_a', 'cl41_rita', '2026-11-14 10:00', '2026-11-20 10:00', 'on_rent');

insert into tracker_devices (id, serial_number, imei, vehicle_id, status, installed_at, tested_at) values
  (test.id('trk:cl41a'), 'TRK-CL41A', '000000000041001', test.id('vehicle:cl41_a'), 'installed', now() - interval '10 days', now()),
  (test.id('trk:cl41b'), 'TRK-CL41B', '000000000041002', test.id('vehicle:cl41_b'), 'installed', now() - interval '10 days', now());
insert into tracker_status (tracker_device_id, reported_at, latitude, longitude, speed_kmh, ignition_on) values
  (test.id('trk:cl41a'), now() - interval '2 minutes', 43.65, -79.38, 52, true),
  (test.id('trk:cl41b'), now() - interval '3 hours', 43.59, -79.64, 0, false);
insert into tracker_trips (id, vehicle_id, booking_id, started_at, ended_at, start_lat, start_lng, end_lat, end_lng, km, max_speed_kmh) values
  (test.id('trip:cl41a'), test.id('vehicle:cl41_a'), test.id('booking:CL41-1'), now() - interval '5 hours', now() - interval '4 hours', 43.6, -79.4, 43.7, -79.3, 21.5, 88),
  (test.id('trip:cl41b'), test.id('vehicle:cl41_b'), null, now() - interval '6 hours', now() - interval '5 hours', 43.5, -79.6, 43.6, -79.5, 9, 60);
insert into tracker_points (vehicle_id, at, lat_e6, lng_e6) values
  (test.id('vehicle:cl41_a'), now() - interval '270 minutes', 43650000, -79380000),
  (test.id('vehicle:cl41_b'), now() - interval '330 minutes', 43590000, -79640000);

create or replace function test.cl41(p_user text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_read', p_name, p) $$;

-- ---------------------------------------------------------------- 1. every staff role sees the cars, read only outside Admin and Fleet
select test.ok('customer service, Sales, Finance and field staff read the whole map, read only',
  (select bool_and((v ->> 'read_only')::boolean and exists (select 1 from jsonb_array_elements(v -> 'cars') c where (c ->> 'vehicle_id')::uuid = test.id('vehicle:cl41_a') and c -> 'pos' ->> 'lat' is not null)
                   and exists (select 1 from jsonb_array_elements(v -> 'cars') c where (c ->> 'vehicle_id')::uuid = test.id('vehicle:cl41_b')))
     from (select test.cl41(u, 'tracker_fleet') v from unnest(array['cl41_cs', 'cl41_sales', 'cl41_fin', 'cl41_field']) u) q));
select test.ok('a read-only map carries no device serial or IMEI and no tracker waiting to be paired',
  (select not exists (select 1 from jsonb_array_elements(v -> 'cars') c where c -> 'device' ? 'imei' or c -> 'device' ? 'serial') and v -> 'unpaired' = '[]'::jsonb
     from (select test.cl41('cl41_cs', 'tracker_fleet') v) q));
select test.ok('Admin and Fleet keep the full map (not read only, with the devices)',
  not (test.cl41('cl41_admin', 'tracker_fleet') ->> 'read_only')::boolean and not (test.cl41('cl41_fleet', 'tracker_fleet', '{"_va": "fleet"}') ->> 'read_only')::boolean
  and exists (select 1 from jsonb_array_elements(test.cl41('cl41_fleet', 'tracker_fleet', '{"_va": "fleet"}') -> 'cars') c where c #>> '{device,serial}' = 'TRK-CL41A'));
select test.ok('every staff role reads a trip''s route', (select bool_and(test.cl41(u, 'tracker_trip_path', jsonb_build_object('trip', test.id('trip:cl41a'))) ? 'path')
  from unnest(array['cl41_cs', 'cl41_sales', 'cl41_fin', 'cl41_field']) u));
insert into tracker_alerts (kind, vehicle_id, title, detail, at, dedupe_key) values ('speeding', test.id('vehicle:cl41_a'), 'Speeding', 'test', now(), 'cl41-speed')
  on conflict do nothing;
select test.throws('customer service cannot mark an alert as seen (Admin and Fleet only)',
  format($$select app.door(%L, 'aal2', 'ops_do', 'tracker_alert_ack', '{"all": true}')$$, test.id('cl41_cs')), 'Only Admins and fleet staff');
select test.throws('Sales cannot change the trackers', format($$select app.door(%L, 'aal2', 'ops_do', 'tracker_settings_save', '{}')$$, test.id('cl41_sales')), 'Only an Admin');
select test.lives('fleet staff still mark alerts as seen', format($$select app.door(%L, 'aal2', 'ops_do', 'tracker_alert_ack', '{"all": true, "_va": "fleet"}')$$, test.id('cl41_fleet')));

-- one car (the vehicle and booking pages)
select test.ok('one car by vehicle: moving, its position and speed',
  (select (v ->> 'tracker')::boolean and (v #>> '{pos,moving}')::boolean and (v #>> '{pos,lat}')::numeric = 43.65 and (v #>> '{pos,speed}')::numeric = 52
     from (select test.cl41('cl41_sales', 'tracker_car', jsonb_build_object('vehicle', test.id('vehicle:cl41_a'))) v) q));
select test.eq('one car by booking number', test.cl41('cl41_fin', 'tracker_car', '{"booking": "CL41-1"}') ->> 'vehicle_id', test.id('vehicle:cl41_a')::text);
select test.ok('no tracker installed: tracker false and no position ("No tracker yet")',
  (select not (v ->> 'tracker')::boolean and v -> 'pos' = 'null'::jsonb from (select test.cl41('cl41_cs', 'tracker_car', jsonb_build_object('vehicle', test.id('vehicle:cl41_none'))) v) q));
select test.throws('an owner cannot read a staff car view', format($$select test.cl41('cl41_ann', 'tracker_car', '{"vehicle": "%s"}')$$, test.id('vehicle:cl41_a')), 'CarmaCars staff');
select test.throws('an owner cannot read the fleet map', $$select test.cl41('cl41_ann', 'tracker_fleet')$$, 'CarmaCars staff');

-- ---------------------------------------------------------------- 2. owners: their own cars, the location only
create temp table cl41_own as select test.cl41('cl41_ann', 'owner_car_location', jsonb_build_object('vehicle', test.id('vehicle:cl41_a'))) as v;
select test.ok('the owner sees their car''s position and its trips',
  (select (v ->> 'tracker')::boolean and (v #>> '{pos,lat}')::numeric = 43.65 and jsonb_array_length(v -> 'trips') = 1 and (v #>> '{trips,0,km}')::numeric = 21.5
          and (v #>> '{trips,0,from,lat}')::numeric = 43.6 from cl41_own));
select test.ok('during a rental: no booking, no renter, no booking dates anywhere in the answer',
  (select v::text not like '%CL41-1%' and v::text not like '%' || test.id('booking:CL41-1')::text || '%' and v::text not ilike '%rita%'
          and not (v ? 'booking') and not (v -> 'trips' -> 0 ? 'booking_id') from cl41_own));
select test.throws('another owner''s car is refused', format($$select test.cl41('cl41_bo', 'owner_car_location', '{"vehicle": "%s"}')$$, test.id('vehicle:cl41_a')), 'Only the owner of this car');
select test.throws('a staff member is not an owner here', format($$select test.cl41('cl41_cs', 'owner_car_location', '{"vehicle": "%s"}')$$, test.id('vehicle:cl41_a')), 'Only the owner of this car');
select test.ok('the owner''s car with no tracker: "No tracker yet" (tracker false, no trips)',
  (select not (v ->> 'tracker')::boolean and v -> 'trips' = '[]'::jsonb from (select test.cl41('cl41_ann', 'owner_car_location', jsonb_build_object('vehicle', test.id('vehicle:cl41_none'))) v) q));

-- row level security on the position history
select test.login(test.id('cl41_ann'));
select test.eq('owner: sees the position history of their own car only', test.visible($$select * from tracker_points where vehicle_id in ('$$ || test.id('vehicle:cl41_a') || $$', '$$ || test.id('vehicle:cl41_b') || $$')$$), 1::bigint);
select test.eq('owner: still no tracker device rows or trips with their bookings', test.visible('select * from tracker_trips'), 0::bigint);
select test.logout();
select test.login(test.id('cl41_bo'));
select test.eq('the other owner: only theirs', test.visible($$select * from tracker_points where vehicle_id = '$$ || test.id('vehicle:cl41_a') || $$'$$), 0::bigint);
select test.logout();
select test.login(test.id('cl41_cs'));
select test.eq('customer service: the position history of both cars', test.visible($$select * from tracker_points where vehicle_id in ('$$ || test.id('vehicle:cl41_a') || $$', '$$ || test.id('vehicle:cl41_b') || $$')$$), 2::bigint);
select test.logout();
select test.login(test.id('cl41_rita'));
select test.eq('a renter: none', test.visible('select * from tracker_points'), 0::bigint);
select test.logout();

-- ---------------------------------------------------------------- 3. the privacy policy, the lawyer's step
select test.ok('the lawyer''s review is on the owner''s setup list until legal.meta says it was done',
  exists (select 1 from jsonb_array_elements(app.owner_steps()) e where e ->> 'key' = 'tracker_visibility' and e ->> 'step' like 'Lawyer:%'));
insert into site_content_blocks (block_key, page, kind, data) values ('legal.meta', 'legal', 'text', '{"tracker_visibility_reviewed": "2026-11-20"}'::jsonb)
  on conflict (block_key) do update set data = site_content_blocks.data || excluded.data;
select test.ok('reviewed: off the list', not exists (select 1 from jsonb_array_elements(app.owner_steps()) e where e ->> 'key' = 'tracker_visibility'));
select test.ok('the functions are the server''s',
  not has_function_privilege('authenticated', 'app.owner_car_location(uuid, jsonb)', 'execute') and not has_function_privilege('anon', 'app.tracker_car(uuid, jsonb)', 'execute'));
