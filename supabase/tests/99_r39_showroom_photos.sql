-- 99: the photographed showroom rooms and the deploy's self-QA (2400). Fixtures start with "sq".
select test.suite('99 r39 showroom photos and self-QA');
select test.mk_user('r39sq_admin', 'admin');
select test.mk_user('sq_fleet', 'va', 'fleet');
select test.mk_owner('sq_o');
select test.mk_vehicle('sqY', 'sq_o');
select test.mk_vehicle('sqZ', 'sq_o');

-- ---------------------------------------------------------------- 1. the rooms: licences for commercial use only
select test.throws('a share-alike photo is refused',
  $$insert into showroom_backgrounds (slug, title, storage_path, source_url, author, licence) values ('sa-room', 'Room', 'site/backdrop/photos/sa-room.jpg', 'https://commons.wikimedia.org/wiki/File:A.jpg', 'Someone', 'CC BY-SA 4.0')$$);
select test.throws('a non-commercial photo is refused',
  $$insert into showroom_backgrounds (slug, title, storage_path, source_url, author, licence) values ('nc-room', 'Room', 'site/backdrop/photos/nc-room.jpg', 'https://commons.wikimedia.org/wiki/File:B.jpg', 'Someone', 'CC BY-NC 2.0')$$);
select test.throws('a file outside the rooms'' folder is refused',
  $$insert into showroom_backgrounds (slug, title, storage_path, source_url, author, licence) values ('x-room', 'Room', 'vehicles/x.jpg', 'https://commons.wikimedia.org/wiki/File:C.jpg', 'Someone', 'CC0')$$);
insert into showroom_backgrounds (slug, title, storage_path, source_url, author, licence, floor_line, reflect, sort) values
  ('room-a', 'Room A', 'site/backdrop/photos/room-a.jpg', 'https://commons.wikimedia.org/wiki/File:Room_A.jpg', 'Author A', 'CC0', 0.8, 0.1, 10),
  ('room-b', 'Room B', 'site/backdrop/photos/room-b.jpg', 'https://commons.wikimedia.org/wiki/File:Room_B.jpg', 'Author B', 'CC BY 4.0', 0.84, 0.14, 20);
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', test.id('r39sq_admin'), 'role', 'authenticated')::text, false);
select test.eq('Admins read the rooms', test.visible($q$select 1 from showroom_backgrounds$q$), 2::bigint);
select set_config('request.jwt.claims', json_build_object('sub', test.id('sq_fleet'), 'role', 'authenticated')::text, false);
select test.eq('staff other than Admins do not see them', test.visible($q$select 1 from showroom_backgrounds$q$), 0::bigint);
select test.eq('nor the self-QA runs', test.visible($q$select 1 from site_selfqa_runs$q$), 0::bigint);
reset role;
select set_config('request.jwt.claims', '', false);

-- ---------------------------------------------------------------- 2. the job context: one room per car, the settings
select test.ok('a car gets one of the active rooms',
  (app.showroom_background_for(test.id('vehicle:sqY')) ->> 'slug') in ('room-a', 'room-b'));
select test.eq('the same room every time (every angle of the car)',
  app.showroom_background_for(test.id('vehicle:sqY')), app.showroom_background_for(test.id('vehicle:sqY')));
update program_settings set listing_showroom_photo_bg = false;
select test.ok('off in Program settings: no room (the drawn one)', app.showroom_background_for(test.id('vehicle:sqY')) is null);
update program_settings set listing_showroom_photo_bg = true;
update showroom_backgrounds set active = false;
select test.ok('no active room: the drawn one', app.showroom_background_for(test.id('vehicle:sqY')) is null);
update showroom_backgrounds set active = true;
select test.throws('the car width is held to 0.5 to 0.85', $$update program_settings set listing_showroom_car_width = 0.95$$);
select test.throws('the quality floor is 0 to 1', $$update program_settings set listing_cutout_min_quality = 1.5$$);

insert into vin_decodes (vin, provider, ok, raw, year, make, model) select upper(vin), 'fake', true, '{}', 2023, 'Mercedes-Benz', 'EQE' from vehicles where id = test.id('vehicle:sqY');
create temp table sq_s as select app.start_listing_intake(test.id('r39sq_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:sqY'), 'colour', 'Black')) r;
create function test.sq_i() returns uuid language sql as $$ select ((select r from sq_s) ->> 'intake_id')::uuid $$;
select app.record_listing_upload(test.id('r39sq_admin'), test.sq_i(), jsonb_build_object('shot_type', s.code, 'original_path', 'o/' || s.code || '.jpg'))
  from listing_shot_types s where s.required and s.is_active order by s.seq;
select app.submit_listing_intake(test.id('r39sq_admin'), test.sq_i());
create temp table sq_j as select id, vehicle_photo_id from listing_jobs where intake_id = test.sq_i() and kind = 'process_photo' order by id limit 2;
select test.eq('every photo job of the car carries the same room',
  (select count(distinct app.listing_job_context(id) -> 'background' ->> 'slug') from sq_j), 1::bigint);
select test.eq('and the car width and quality floor of Program settings',
  (select app.listing_job_context(id) -> 'cutout' ->> 'min_quality' from sq_j limit 1), '0.60');

-- ---------------------------------------------------------------- 3. the result keeps the mask's score and the room
update listing_jobs set status = 'running', attempts = 1, locked_at = now(), locked_by = 'sq-w' where id in (select id from sq_j);
select app.worker_listing_result((select id from sq_j order by id limit 1), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/sq/a.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_showroom_v2',
  'showroom', jsonb_build_object('provider', 'local', 'note', null, 'reason', null, 'mask_quality', 0.93, 'background', 'room-a'))));
select test.ok('a composite keeps its mask''s score and its room',
  (select (showroom ->> 'mask_quality')::numeric = 0.93 and showroom ->> 'background' = 'room-a' from vehicle_photos where id = (select vehicle_photo_id from sq_j order by id limit 1)));
select app.worker_listing_result((select id from sq_j order by id desc limit 1), jsonb_build_object('ok', true, 'provider', 'fake:fallback', 'output', jsonb_build_object(
  'processed_path', 'vehicles/sq/b.jpg', 'used_original', true, 'preset_version', 'original', 'flags', '["background_not_replaced"]'::jsonb,
  'showroom', jsonb_build_object('provider', 'local', 'reason', 'low_mask', 'note', 'The real photo is used', 'mask_quality', 0.31, 'used_original', true))));
select test.ok('a poor cut-out: the real photo, noted with the score',
  (select (showroom ->> 'used_original')::boolean and showroom ->> 'reason' = 'low_mask' and (showroom ->> 'mask_quality')::numeric = 0.31
     from vehicle_photos where id = (select vehicle_photo_id from sq_j order by id desc limit 1)));

-- ---------------------------------------------------------------- 4. the deploy's self-QA
-- a published car with an uploaded photo but none public (on the stand-in), and a published car whose cover came from a poor cut-out
insert into vehicle_listings (vehicle_id, slug, status) values (test.id('vehicle:sqY'), 'sq-standin-car', 'published')
  on conflict (vehicle_id) do update set slug = excluded.slug, status = excluded.status;
update vehicle_photos set is_public = false where vehicle_id = test.id('vehicle:sqY');
insert into vehicle_listings (vehicle_id, slug, status) values (test.id('vehicle:sqZ'), 'sq-lowmask-car', 'published')
  on conflict (vehicle_id) do update set slug = excluded.slug, status = excluded.status;
insert into vehicle_photos (vehicle_id, angle, original_path, processed_path, status, is_cover, is_public, showroom, plate_status)
  values (test.id('vehicle:sqZ'), 'front_left', 'o/z.jpg', 'vehicles/sqz/c.jpg', 'approved', true, true, '{"provider": "local", "mask_quality": 0.4}', 'not_visible');
select test.eq('the database''s findings: the stand-in car and the poor cover',
  (select string_agg(e ->> 'check', ',' order by e ->> 'check') from jsonb_array_elements(app.selfqa_db_findings('{}')) e
    where e ->> 'detail' like '%sq-%'), 'low_mask_cover,standin_with_photo');
create temp table sq_r as select app.server_site_selfqa(jsonb_build_object('sha', 'abc1234def', 'base', 'https://carmacars.ca', 'ms', 41000,
  'fails', '[]'::jsonb, 'warns', jsonb_build_array(jsonb_build_object('check', 'sitemap_empty', 'detail', '/sitemap-cars.xml has no addresses')))) r;
select test.eq('warnings only: the run is "warn"', (select r ->> 'status' from sq_r), 'warn');
select test.ok('the run is saved with the script''s and the database''s lines',
  (select jsonb_array_length(warns) >= 3 and fails = '[]'::jsonb and sha = 'abc1234def' from site_selfqa_runs where id = (select (r ->> 'id')::bigint from sq_r)));
select test.ok('the Admins get the staff alert site_selfqa',
  exists (select 1 from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'site_selfqa'));
create temp table sq_f as select app.server_site_selfqa(jsonb_build_object('sha', 'abc1234def', 'fails', jsonb_build_array(jsonb_build_object('check', 'http_5xx', 'detail', '/cars answered 503')))) r;
select test.eq('a failing page: the run is "fail"', (select r ->> 'status' from sq_f), 'fail');
update vehicle_listings set status = 'paused' where vehicle_id in (test.id('vehicle:sqY'), test.id('vehicle:sqZ'));
-- cars of other suites may be listed too (stand-ins, low cut-outs), so: no finding of this suite's cars, and "pass" when the database has none at all
select test.ok('nothing wrong: "pass", no alert line',
  (select r ->> 'status' = case when jsonb_array_length(r -> 'db') > 0 then 'warn' else 'pass' end
      and not exists (select 1 from jsonb_array_elements(r -> 'db') e where e ->> 'detail' like '%sq-%')
     from (select app.server_site_selfqa('{"sha": "fff0000"}') r) x));
create temp table sq_g as select app.server_site_selfqa('{"sha": "zz", "base": "javascript:x", "fails": "x"}') r;
select test.eq('garbage in the report is cleaned (no sha, no address)',
  (select coalesce(sha, '-') || coalesce(base, '-') from site_selfqa_runs where id = (select (r ->> 'id')::bigint from sq_g)), '--');
select test.ok('only the deploy (service role) sends it',
  not has_function_privilege('authenticated', 'public.server_site_selfqa(jsonb)', 'execute') and not has_function_privilege('anon', 'public.server_site_selfqa(jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.server_site_selfqa(jsonb)', 'execute'));
