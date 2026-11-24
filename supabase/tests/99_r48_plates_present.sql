-- 99: migration 3040 (release 48): a plate only where the car has one. Whether the car's own photos show a plate at the end
-- a view shows (photo_r48_plate_end), carried in the r48 step's context (plate_end), and the studio views that may carry a
-- blank plate patch or a large blur made again by the fleet job (photo_r48_plate_requeue), once.
-- Fixtures start with "rp40_"; no real names or plates.
select test.suite('99 r48 plates present (3040)');

update program_settings set listing_showroom_ai = true, listing_photo_r48_auto = true, listing_photo_r45_auto = false, listing_photo_r45_batch = 200,
       listing_photo_r45_reserve = 0, listing_showroom_ai_daily = 20000
 where id = (select id from app.settings());

select test.mk_user('rp40_admin', 'admin');
select test.mk_owner('rp40_olive');
select test.mk_vehicle('rp40_a', 'rp40_olive');
select test.mk_vehicle('rp40_b', 'rp40_olive');

create or replace function test.rp40_up(p_intake uuid, p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rp40_admin'), p_intake, jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rp40/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create or replace function test.rp40_row(p_car text, p_shot text) returns vehicle_photos language sql as $$
  select * from vehicle_photos where vehicle_id = test.id('vehicle:' || p_car) and r48 and shot_type = p_shot and replaced_at is null order by created_at desc limit 1 $$;
create or replace function test.rp40_job(p_photo uuid) returns listing_jobs language sql as $$
  select * from listing_jobs where vehicle_photo_id = p_photo and kind = 'photo_r45' order by created_at desc limit 1 $$;

create temp table rp40_i as select
  (app.start_listing_intake(test.id('rp40_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rp40_a'))) ->> 'intake_id')::uuid as a,
  (app.start_listing_intake(test.id('rp40_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rp40_b'))) ->> 'intake_id')::uuid as b;
-- car a: its front photo checked with no plate (an Ontario car without a front plate), its rear with the plate covered
create temp table rp40_p as select test.rp40_up((select a from rp40_i), 'front_left') as fl, test.rp40_up((select a from rp40_i), 'rear') as rear,
  test.rp40_up((select a from rp40_i), 'left') as side;
update vehicle_photos set background_status = 'done', status = 'approved', is_public = true,
       processed_path = coalesce(processed_path, 'vehicles/rp40/' || shot_type || '-' || left(id::text, 6) || '.jpg'),
       plate_status = case shot_type when 'front_left' then 'not_visible' when 'rear' then 'covered' else 'not_visible' end,
       plate_boxes = case shot_type when 'rear' then '[{"x": 0.45, "y": 0.7, "w": 0.1, "h": 0.04}]'::jsonb else '[]'::jsonb end
 where vehicle_id = test.id('vehicle:rp40_a') and replaced_at is null and not r48;
-- car b: a front photo not checked yet
select test.rp40_up((select b from rp40_i), 'front');
update vehicle_photos set background_status = 'done', status = 'approved', processed_path = coalesce(processed_path, 'vehicles/rp40/b-' || left(id::text, 6) || '.jpg')
 where vehicle_id = test.id('vehicle:rp40_b') and replaced_at is null and not r48;
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id in (test.id('vehicle:rp40_a'), test.id('vehicle:rp40_b')) and status in ('queued', 'running');

-- ---------------------------------------------------------------- 1. whether the car has a plate at that end
select test.eq('a front checked with no plate: no front plate (every front view)',
  array[app.photo_r48_plate_end(test.id('vehicle:rp40_a'), 'front_left'), app.photo_r48_plate_end(test.id('vehicle:rp40_a'), 'front')], array['no', 'no']);
select test.eq('a rear with its plate covered: a rear plate (every rear view)',
  array[app.photo_r48_plate_end(test.id('vehicle:rp40_a'), 'rear_left'), app.photo_r48_plate_end(test.id('vehicle:rp40_a'), 'rear')], array['yes', 'yes']);
select test.ok('a side profile or an inside view shows no end; a front not checked yet is not known',
  app.photo_r48_plate_end(test.id('vehicle:rp40_a'), 'left') is null and app.photo_r48_plate_end(test.id('vehicle:rp40_a'), 'dashboard') is null
  and app.photo_r48_plate_end(test.id('vehicle:rp40_b'), 'front') is null and app.photo_r48_plate_end(test.id('vehicle:rp40_b'), 'rear') is null);

-- ---------------------------------------------------------------- 2. the r48 step's context carries it
select app.photo_r48_queue(null, test.id('vehicle:rp40_a'), s, false) from unnest(array['front_left', 'rear', 'left']) s;
select test.eq('the front three-quarter step is told the car has no front plate',
  app.listing_job_context((test.rp40_job((test.rp40_row('rp40_a', 'front_left')).id)).id) #>> '{input,r45,plate_end}', 'no');
select test.eq('the rear step is told the car carries a rear plate',
  app.listing_job_context((test.rp40_job((test.rp40_row('rp40_a', 'rear')).id)).id) #>> '{input,r45,plate_end}', 'yes');
select test.ok('the side profile step: not known (null), the rest of the context kept',
  (select x -> 'input' -> 'r45' ? 'plate_end' and x #>> '{input,r45,plate_end}' is null and x #>> '{input,r45,shot}' = 'left' and x #>> '{input,r45,mode}' = 'r48'
     from (select app.listing_job_context((test.rp40_job((test.rp40_row('rp40_a', 'left')).id)).id) as x) t));

-- ---------------------------------------------------------------- 3. the views made before 3040 are made again, once
-- made before 3040: the three views done; the side profile once with a plain result, the rear with a blurred plate
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id = test.id('vehicle:rp40_a') and kind = 'photo_r45' and status in ('queued', 'running');
update vehicle_photos set r45 = jsonb_build_object('state', 'done', 'tries', 1, 'spec', 'r48.2', 'reasons', '[]'::jsonb), processed_path = 'vehicles/rp40/r48-' || shot_type || '.jpg',
       plate_status = case when shot_type = 'rear' then 'covered' else 'not_visible' end
 where vehicle_id = test.id('vehicle:rp40_a') and r48;
select test.eq('the requeue takes the front and rear views (a blank plate patch or a blur), not a plain side profile', app.photo_r48_plate_requeue(), 2);
select test.ok('they are made again (state redo, no try counted); the side profile stays done',
  (test.rp40_row('rp40_a', 'front_left')).r45 ->> 'state' = 'redo' and ((test.rp40_row('rp40_a', 'front_left')).r45 ->> 'tries')::int = 0
  and (test.rp40_row('rp40_a', 'rear')).r45 ->> 'state' = 'redo' and (test.rp40_row('rp40_a', 'left')).r45 ->> 'state' = 'done'
  and (test.rp40_row('rp40_a', 'front_left')).processed_path = 'vehicles/rp40/r48-front_left.jpg');
update vehicle_photos set plate_status = 'covered' where id = (test.rp40_row('rp40_a', 'left')).id;
select test.eq('a side profile with a blurred plate is made again too', app.photo_r48_plate_requeue(), 1);
select app.photo_r48_queue(null, test.id('vehicle:rp40_a'), 'front_left', false);
select test.ok('the fleet job queues the views made again (a step for the view in redo)', exists (select 1 from listing_jobs j where j.vehicle_photo_id = (test.rp40_row('rp40_a', 'front_left')).id and j.kind = 'photo_r45' and j.status = 'queued'));

-- a view made after 3040 records it and is never taken again
create temp table rp40_j as select (test.rp40_job((test.rp40_row('rp40_a', 'front_left')).id)).id as id;
update listing_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), locked_by = 'rp40', started_at = now() where id = (select id from rp40_j);
select app.worker_listing_result((select id from rp40_j), jsonb_build_object('ok', true, 'provider', 'ai', 'output', jsonb_build_object('processed_path', 'vehicles/rp40/r48-fl-new.jpg',
  'width', 1800, 'height', 1200, 'variants', '[]'::jsonb, 'preset_version', 'gemini_r48', 'flags', '[]'::jsonb,
  'showroom', jsonb_build_object('provider', 'ai', 'mode', 'r48', 'spec', 'r48.2', 'scene', 'showroom_dark'),
  'r45', jsonb_build_object('pass', true, 'spec', 'r48.2', 'generated', true, 'plates', '[]'::jsonb, 'model', 'm', 'view', 'front_left', 'reasons', '[]'::jsonb,
    'gate', jsonb_build_object('pass', true, 'spec', 'r48.3', 'reasons', '[]'::jsonb)))));  -- 3701: passed the studio gate
select test.ok('the new view: done, no plate cover, marked as following 3040',
  (test.rp40_row('rp40_a', 'front_left')).r45 ->> 'state' = 'done' and (test.rp40_row('rp40_a', 'front_left')).r45 ->> 'plate_rule' = '3040'
  and (test.rp40_row('rp40_a', 'front_left')).plate_status = 'not_visible' and (test.rp40_row('rp40_a', 'front_left')).processed_path = 'vehicles/rp40/r48-fl-new.jpg');
select test.eq('a view that follows 3040 is not taken again', app.photo_r48_plate_requeue(), 0);

-- ---------------------------------------------------------------- 4. real studio covers where a sample photo was shown
select test.eq('a car not published: its studio cover is not shown', (select count(*) from jsonb_array_elements(app.site_studio_covers(48)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:rp40_a')), 0::bigint);
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at) values (test.id('vehicle:rp40_a'), 'rp40-a', 'Test car A', 'published', now()) on conflict do nothing;
update vehicle_listings set status = 'published', published_at = coalesce(published_at, now()) where vehicle_id = test.id('vehicle:rp40_a');
select test.ok('a published real car''s checked studio cover (its live render: the front three-quarter here) is shown, with its size',
  exists (select 1 from jsonb_array_elements(public.site_studio_covers(48)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:rp40_a')
            and e ->> 'path' = 'vehicles/rp40/r48-fl-new.jpg' and (e ->> 'width')::int = 1800 and jsonb_typeof(e -> 'variants') = 'array'));
update vehicles set is_sample = true where id = test.id('vehicle:rp40_a');
select test.eq('a sample car''s photo is never one of them', (select count(*) from jsonb_array_elements(app.site_studio_covers(48)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:rp40_a')), 0::bigint);
update vehicles set is_sample = false where id = test.id('vehicle:rp40_a');
update vehicle_photos set status = 'rejected', is_public = false where id = (test.rp40_row('rp40_a', 'front_left')).id;
select test.eq('a cover taken off the site is not shown', (select count(*) from jsonb_array_elements(app.site_studio_covers(48)) e where (e ->> 'vehicle_id')::uuid = test.id('vehicle:rp40_a')), 0::bigint);
select test.ok('the site may read them; the inner function is the server''s',
  has_function_privilege('anon', 'public.site_studio_covers(integer)', 'execute') and not has_function_privilege('anon', 'app.site_studio_covers(integer)', 'execute'));

-- ---------------------------------------------------------------- 5. privileges
select test.ok('the new functions are the server''s only',
  not has_function_privilege('authenticated', 'app.photo_r48_plate_end(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'app.photo_r48_plate_requeue()', 'execute')
  and has_function_privilege('service_role', 'app.photo_r48_plate_requeue()', 'execute'));
