-- 99: migration 3030 (release 48): photo standard r48.2. Scenes, the job no longer held by steps waiting far ahead, the retry
-- wait that grows and ends, one source of truth for the public photos (gallery, listing row, sitemap), the Admin set of a
-- car, the connector's photo_standard and the marketing set made from the studio set with lifestyle shots.
-- Fixtures start with "rs30_"; no real names or plates.
select test.suite('99 r48 photo studio (3030)');

update program_settings set listing_showroom_ai = true, listing_photo_r48_auto = true, listing_photo_r45_auto = false, listing_photo_r45_batch = 200,
       listing_photo_r45_reserve = 0, listing_showroom_ai_daily = 20000
 where id = (select id from app.settings());
update listing_jobs set status = 'succeeded', finished_at = now() where kind = 'photo_r45' and status in ('queued', 'running');

select test.mk_user('rs30_admin', 'admin');
select test.mk_user('rs30_fleet', 'va', 'fleet');
select test.mk_user('rs30_cs', 'va', 'cs');
select test.mk_owner('rs30_olive');
select test.mk_vehicle('rs30_a', 'rs30_olive');
select test.mk_vehicle('rs30_b', 'rs30_olive');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at) values (test.id('vehicle:rs30_a'), 'rs30-a', 'Test car A', 'published', now());

select test.eq('the standard is r48.2', app.photo_r48_spec(), 'r48.2');
select test.ok('the fleet scene is the dark dealership by default; the run is on',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_photo_scene') like '''showroom_dark''%'
  and (select listing_photo_r48_auto from app.settings()));
select test.eq('a car without its own scene stands in the fleet''s', app.photo_r48_scene_code(test.id('vehicle:rs30_a')), 'showroom_dark');
update vehicles set photo_scene = 'highway' where id = test.id('vehicle:rs30_b');
select test.ok('a car''s own scene: its code and its words from the marketing scenes',
  (select s ->> 'code' = 'highway' and s ->> 'place' like '%highway%' from (select app.photo_r48_scene(test.id('vehicle:rs30_b')) s) t));
update vehicles set photo_scene = 'not_a_scene' where id = test.id('vehicle:rs30_b');
select test.eq('an unknown scene falls back to the dark dealership', app.photo_r48_scene_code(test.id('vehicle:rs30_b')), 'showroom_dark');
update vehicles set photo_scene = null where id = test.id('vehicle:rs30_b');

create or replace function test.rs30_up(p_intake uuid, p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rs30_admin'), p_intake, jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rs30/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create or replace function test.rs30_row(p_car text, p_shot text) returns vehicle_photos language sql as $$
  select * from vehicle_photos where vehicle_id = test.id('vehicle:' || p_car) and r48 and shot_type = p_shot and replaced_at is null order by created_at desc limit 1 $$;
create or replace function test.rs30_job(p_photo uuid) returns listing_jobs language sql as $$
  select * from listing_jobs where vehicle_photo_id = p_photo and kind = 'photo_r45' order by created_at desc limit 1 $$;
create or replace function test.rs30_answer(p_photo uuid, p jsonb) returns jsonb language plpgsql as $$
declare v uuid := (test.rs30_job(p_photo)).id;
begin
  update listing_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), locked_by = 'rs30', started_at = now() where id = v;
  return app.worker_listing_result(v, p);
end $$;
create or replace function test.rs30_made(p_path text) returns jsonb language sql as $$
  select jsonb_build_object('ok', true, 'provider', 'ai', 'output', jsonb_build_object('processed_path', p_path, 'width', 1800, 'height', 1200,
    'variants', '[]'::jsonb, 'preset_version', 'gemini_r48', 'flags', '[]'::jsonb, 'showroom', jsonb_build_object('provider', 'ai', 'mode', 'r48', 'spec', 'r48.2', 'scene', 'showroom_dark'),
    'r45', jsonb_build_object('pass', true, 'spec', 'r48.2', 'generated', true, 'plates', '[]'::jsonb, 'model', 'gemini-2.5-flash-image', 'view', 'front_left', 'reasons', '[]'::jsonb))) $$;

create temp table rs30_i as select
  (app.start_listing_intake(test.id('rs30_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rs30_a'))) ->> 'intake_id')::uuid as a,
  (app.start_listing_intake(test.id('rs30_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rs30_b'))) ->> 'intake_id')::uuid as b;
create temp table rs30_ap as select test.rs30_up((select a from rs30_i), 'front_left') as fl, test.rs30_up((select a from rs30_i), 'rear') as rear;
select test.rs30_up((select b from rs30_i), 'left');
update vehicle_photos set background_status = 'done', status = 'approved', is_public = true, plate_status = 'not_visible',
       processed_path = coalesce(processed_path, 'vehicles/rs30/' || shot_type || '-' || left(id::text, 6) || '.jpg')
 where vehicle_id in (test.id('vehicle:rs30_a'), test.id('vehicle:rs30_b')) and replaced_at is null and not r48;
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id in (test.id('vehicle:rs30_a'), test.id('vehicle:rs30_b')) and status in ('queued', 'running');

-- ---------------------------------------------------------------- 1. the job is not held by steps waiting far ahead
-- a full batch of steps waiting until tomorrow (the live case: 12 steps of one car waiting with no end)
-- these cars are the most viewed here, so the job takes them first
update app.fleet_trend set score = 0 where score > 0;
insert into app.fleet_trend (vehicle_id, score) select test.id('vehicle:' || c), 99999998 from unnest(array['rs30_a', 'rs30_b']) c
  on conflict (vehicle_id) do update set score = excluded.score;
update program_settings set listing_photo_r45_batch = 2 where id = (select id from app.settings());
insert into listing_jobs (intake_id, vehicle_id, kind, status, next_attempt_at, input, max_attempts)
select i, v, 'photo_r45', 'queued', now() + interval '1 day', '{}'::jsonb, 4
  from (values ((select a from rs30_i), test.id('vehicle:rs30_a')), ((select b from rs30_i), test.id('vehicle:rs30_b'))) x(i, v);
select test.eq('steps waiting until tomorrow are not due', app.photo_r48_due(), 0);
create temp table rs30_run as select app.job_photo_r48() as msg;
select test.ok('the job still queues the covers when the batch is full of steps waiting far ahead',
  (test.rs30_row('rs30_a', 'front_left')).id is not null and (test.rs30_row('rs30_b', 'front_left')).id is not null, (select msg from rs30_run));
delete from listing_jobs where kind = 'photo_r45' and next_attempt_at > now() + interval '12 hours' and vehicle_photo_id is null;
update program_settings set listing_photo_r45_batch = 200 where id = (select id from app.settings());

-- ---------------------------------------------------------------- 2. the job context: scene, tries, the plate of the scene
insert into listing_r48_plates (scene, family, path, source) values ('showroom_dark', 'front', 'site/r48/plates/front-dark1.jpg', 'admin'),
  ('highway', 'front', 'site/r48/plates/highway-front-x1.jpg', 'admin')
  on conflict (scene, family) do update set path = excluded.path, source = excluded.source;
create temp table rs30_ctx as select app.listing_job_context((test.rs30_job((test.rs30_row('rs30_a', 'front_left')).id)).id) as x;
select test.ok('the context carries the scene, the tries and the plate of the car''s scene',
  (select x #>> '{input,r45,scene,code}' = 'showroom_dark' and (x #>> '{input,r45,tries}')::int = 0 and x #>> '{input,r45,plate}' = 'site/r48/plates/front-dark1.jpg' from rs30_ctx));
update vehicles set photo_scene = 'highway' where id = test.id('vehicle:rs30_a');
select test.eq('a car in another scene gets that scene''s plate',
  app.listing_job_context((test.rs30_job((test.rs30_row('rs30_a', 'front_left')).id)).id) #>> '{input,r45,plate}', 'site/r48/plates/highway-front-x1.jpg');
update vehicles set photo_scene = null where id = test.id('vehicle:rs30_a');
-- a plate the worker made is kept under its scene, beside the other scenes' plates
select test.rs30_answer((test.rs30_row('rs30_b', 'front_left')).id, jsonb_build_object('ok', true, 'provider', 'gemini', 'output', jsonb_build_object('r45',
  jsonb_build_object('pass', false, 'spec', 'r48.2', 'generated', true, 'wait', 'retry', 'why', 'x',
    'plate_made', jsonb_build_object('family', 'side', 'scene', 'brick_building', 'path', 'site/r48/plates/brick-building-side-ab12.jpg', 'model', 'm')))));
select test.ok('a made plate is kept under its scene', exists (select 1 from listing_r48_plates where scene = 'brick_building' and family = 'side' and source = 'gemini'));

-- ---------------------------------------------------------------- 3. the "retry" wait grows, counts no try, then ends
select test.ok('a failure that is not the photo''s (location, time-out) waits about 10 minutes, no try counted',
  (select j.status = 'queued' and j.next_attempt_at between now() + interval '9 minutes' and now() + interval '11 minutes' from listing_jobs j where j.id = (test.rs30_job((test.rs30_row('rs30_b', 'front_left')).id)).id)
  and coalesce(((test.rs30_row('rs30_b', 'front_left')).r45 ->> 'tries')::int, 0) = 0 and ((test.rs30_row('rs30_b', 'front_left')).r45 ->> 'waits')::int = 1);
select test.rs30_answer((test.rs30_row('rs30_b', 'front_left')).id, jsonb_build_object('ok', true, 'provider', 'gemini', 'output', jsonb_build_object('r45',
  jsonb_build_object('pass', false, 'spec', 'r48.2', 'generated', true, 'wait', 'retry', 'why', 'x'))));
select test.ok('the second wait doubles (about 20 minutes)',
  (select j.next_attempt_at between now() + interval '19 minutes' and now() + interval '21 minutes' from listing_jobs j where j.id = (test.rs30_job((test.rs30_row('rs30_b', 'front_left')).id)).id));
update vehicle_photos set r45 = r45 || '{"waits": 8}'::jsonb where id = (test.rs30_row('rs30_b', 'front_left')).id;
select test.rs30_answer((test.rs30_row('rs30_b', 'front_left')).id, jsonb_build_object('ok', true, 'provider', 'gemini', 'output', jsonb_build_object('r45',
  jsonb_build_object('pass', false, 'spec', 'r48.2', 'generated', true, 'wait', 'retry', 'why', 'x'))));
select test.ok('after eight waits in a row it counts as a try (never stuck)',
  ((test.rs30_row('rs30_b', 'front_left')).r45 ->> 'tries')::int = 1 and ((test.rs30_row('rs30_b', 'front_left')).r45 ->> 'waits')::int = 0);

-- ---------------------------------------------------------------- 4. one source of truth for the public photos
select test.ok('before the studio cover passes, the car''s own photos show',
  exists (select 1 from jsonb_array_elements(app.public_listing_photos(test.id('vehicle:rs30_a'))) e where e ->> 'shot' = 'rear'));
select test.rs30_answer((test.rs30_row('rs30_a', 'front_left')).id, test.rs30_made('vehicles/rs30/a-fl-r48.jpg'));
select app.job_photo_r48();
select test.rs30_answer((test.rs30_row('rs30_a', 'rear')).id, test.rs30_made('vehicles/rs30/a-rear-r48.jpg'));
create temp table rs30_g as select app.public_listing_photos(test.id('vehicle:rs30_a')) as g;
select test.ok('the gallery: the generated set only, in the standard order, the front three-quarter the cover',
  (select g -> 0 ->> 'path' = 'vehicles/rs30/a-fl-r48.jpg' and (g -> 0 ->> 'is_cover')::boolean and jsonb_array_length(g) = 2 and g -> 1 ->> 'path' = 'vehicles/rs30/a-rear-r48.jpg'
          and not (g -> 1 ->> 'is_cover')::boolean and (g -> 1 ->> 'generated')::boolean from rs30_g));
select test.ok('the listing row''s cover is the gallery''s first photo (live row and the cached row)',
  (app.public_listing_row_live(test.id('vehicle:rs30_a')) #>> '{cover,path}') is not distinct from 'vehicles/rs30/a-fl-r48.jpg'
  and (app.public_listing_row(test.id('vehicle:rs30_a')) #>> '{cover,path}') is not distinct from 'vehicles/rs30/a-fl-r48.jpg',
  coalesce(app.public_listing_row_live(test.id('vehicle:rs30_a')) #>> '{cover,path}', 'no row'));
select test.ok('the sitemap''s image tags are the gallery',
  (select images -> 0 ->> 'loc' = 'vehicles/rs30/a-fl-r48.jpg' and jsonb_array_length(images) = 2 from app.public_sitemap_rows() where path = '/cars/rs30-a'),
  (select images::text from app.public_sitemap_rows() where path = '/cars/rs30-a'));
select test.ok('the real photos stay approved and public in their records',
  (select bool_and(is_public and status = 'approved') from vehicle_photos where id in ((select fl from rs30_ap), (select rear from rs30_ap))));

-- ---------------------------------------------------------------- 5. Admin: the set of a car, one angle, the scene
create temp table rs30_set as select app.door(test.id('rs30_fleet'), 'aal2', 'ops_read', 'photo_r48_set', jsonb_build_object('vehicle', test.id('vehicle:rs30_a'))) as s;
select test.ok('the set of a car: nine angles, the generated view beside the originals of each',
  (select jsonb_array_length(s -> 'angles') = 9 and s -> 'angles' -> 0 ->> 'shot' = 'front_left' and s -> 'angles' -> 0 #>> '{generated,path}' = 'vehicles/rs30/a-fl-r48.jpg'
          and jsonb_array_length(s -> 'angles' -> 0 -> 'originals') = 1 and (s ->> 'studio_cover')::boolean from rs30_set));
select app.door(test.id('rs30_fleet'), 'aal2', 'ops_do', 'photo_r48_angle', jsonb_build_object('vehicle', test.id('vehicle:rs30_a'), 'shot', 'rear', 'action', 'hide'));
select test.ok('hide: the generated rear is off the site and out of the gallery',
  not (test.rs30_row('rs30_a', 'rear')).is_public and not exists (select 1 from jsonb_array_elements(app.public_listing_photos(test.id('vehicle:rs30_a'))) e where e ->> 'shot' = 'rear'));
select app.door(test.id('rs30_fleet'), 'aal2', 'ops_do', 'photo_r48_angle', jsonb_build_object('vehicle', test.id('vehicle:rs30_a'), 'shot', 'rear', 'action', 'show'));
select test.ok('show: it is back', (test.rs30_row('rs30_a', 'rear')).is_public);
select app.door(test.id('rs30_fleet'), 'aal2', 'ops_do', 'photo_r48_angle', jsonb_build_object('vehicle', test.id('vehicle:rs30_a'), 'shot', 'rear', 'action', 'redo'));
select test.ok('redo one angle: queued now, the version on the site stays meanwhile',
  (test.rs30_job((test.rs30_row('rs30_a', 'rear')).id)).status = 'queued' and (test.rs30_row('rs30_a', 'rear')).is_public);
create temp table rs30_sc as select app.door(test.id('rs30_fleet'), 'aal2', 'ops_do', 'photo_r48_scene', jsonb_build_object('vehicle', test.id('vehicle:rs30_a'), 'scene', 'highway')) as r;
select test.ok('the car''s scene: saved, its outside views queued again',
  (select r ->> 'scene' = 'highway' from rs30_sc) and (select photo_scene from vehicles where id = test.id('vehicle:rs30_a')) = 'highway');
select test.throws('an unknown scene is refused',
  format($$select app.door(%L, 'aal2', 'ops_do', 'photo_r48_scene', jsonb_build_object('vehicle', %L, 'scene', 'moon'))$$, test.id('rs30_fleet'), test.id('vehicle:rs30_a')), 'Unknown scene%');
select test.throws('customer service does not change the photo standard',
  format($$select app.door(%L, 'aal2', 'ops_do', 'photo_r48_angle', jsonb_build_object('vehicle', %L, 'shot', 'rear', 'action', 'hide'))$$, test.id('rs30_cs'), test.id('vehicle:rs30_a')));
update vehicles set photo_scene = null where id = test.id('vehicle:rs30_a');
create temp table rs30_pl as select app.photo_r48_plates(test.id('rs30_admin'), jsonb_build_object('scene', 'highway', 'family', 'side', 'path', 'site/r48/plates/hw-side-1.jpg')) as x;
select test.ok('the plates per scene: read with the scenes, set per scene',
  (select jsonb_array_length(x -> 'plates') > 0 and jsonb_array_length(x -> 'scenes') > 1 from rs30_pl)
  and exists (select 1 from listing_r48_plates where scene = 'highway' and family = 'side' and source = 'admin'));
select app.photo_r48_plates(test.id('rs30_admin'), jsonb_build_object('scene', 'highway', 'family', 'side', 'clear', true));
select test.ok('cleared per scene: the other scenes keep theirs', not exists (select 1 from listing_r48_plates where scene = 'highway' and family = 'side')
  and exists (select 1 from listing_r48_plates where scene = 'highway' and family = 'front'));
create temp table rs30_fleetv as select app.photo_r45_fleet_read(test.id('rs30_fleet'), '{}'::jsonb) as v;
select test.ok('the fleet''s progress: views, done, the days left at the daily limit, studio covers',
  (select (v #>> '{r48_fleet,views}')::int >= 18 and (v #>> '{r48_fleet,left}')::int >= 1 and (v #>> '{r48_fleet,days}')::int >= 1
          and (v #>> '{r48_fleet,studio_covers}')::int >= 1 and v ->> 'r48_spec' = 'r48.2' from rs30_fleetv));

-- ---------------------------------------------------------------- 6. the connector's photo_standard
create temp table rs30_ps as select app.photo_standard_read(test.id('rs30_admin'), jsonb_build_object('vehicle', test.id('vehicle:rs30_a'))) as x;
select test.ok('photo_standard: spec r48.2, the r48 run, the cover "studio", the AI views counted, the angles still missing',
  (select x ->> 'spec' = 'r48.2' and (x ->> 'auto')::boolean and x -> 'cars' -> 0 ->> 'cover' = 'studio' and (x -> 'cars' -> 0 ->> 'ai_angles')::int = 2
          and jsonb_array_length(x -> 'cars' -> 0 -> 'missing_angles') = 7 and (x #>> '{totals,cover_studio}')::int = 1 and x -> 'cars' -> 0 ->> 'scene' = 'showroom_dark' from rs30_ps),
  (select x::text from rs30_ps));

-- ---------------------------------------------------------------- 7. the marketing set from the studio set
create temp table rs30_mk as select app.marketing_set(test.id('rs30_admin'), jsonb_build_object('vehicle', test.id('vehicle:rs30_a'), 'scene', 'highway')) as r;
select test.ok('the marketing set: the outside views of the studio set (the cover first) and 2 lifestyle shots, every one marked AI',
  (select (r ->> 'studio')::boolean and (r ->> 'queued')::int = 4 from rs30_mk)
  and (select count(*) = 4 and bool_and(ai_generated) and count(*) filter (where lifestyle is not null) = 2 from vehicle_marketing_photos where set_id = (select (r ->> 'set')::uuid from rs30_mk)));
select test.ok('each copy carries the studio photo, the scene and, for a lifestyle shot, its pose and outfit',
  (select bool_and(m.job_input #>> '{marketing,studio,path}' like 'vehicles/rs30/a-%-r48.jpg' and m.job_input #>> '{marketing,scene}' = 'highway')
          and count(*) filter (where m.job_input #>> '{marketing,studio,pose}' is not null and m.job_input #>> '{marketing,studio,outfit}' like '%dress%') >= 1
          and count(*) filter (where (m.job_input #>> '{marketing,studio,cover}')::boolean) = 1
     from vehicle_marketing_photos m where m.set_id = (select (r ->> 'set')::uuid from rs30_mk)));
select test.ok('one marketing step at a time: the cover first',
  (select count(*) = 1 from listing_jobs j where j.vehicle_id = test.id('vehicle:rs30_a') and j.kind = 'marketing_photo' and j.status = 'queued')
  and (select (j.input #>> '{marketing,studio,cover}')::boolean from listing_jobs j where j.vehicle_id = test.id('vehicle:rs30_a') and j.kind = 'marketing_photo' and j.status = 'queued'));
create temp table rs30_m1 as select j.id, j.input #>> '{marketing,id}' as mid from listing_jobs j where j.vehicle_id = test.id('vehicle:rs30_a') and j.kind = 'marketing_photo' and j.status = 'queued';
update listing_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), locked_by = 'rs30', started_at = now() where id = (select id from rs30_m1);
select app.worker_listing_result((select id from rs30_m1), jsonb_build_object('ok', true, 'provider', 'ai', 'output', jsonb_build_object('marketing',
  jsonb_build_object('id', (select mid from rs30_m1), 'status', 'made', 'path', 'vehicles/v/marketing/x.jpg', 'provider', 'ai'))));
select test.ok('a finished step queues the next copy of the set',
  (select status from vehicle_marketing_photos where id = (select mid from rs30_m1)::uuid) = 'made'
  and (select count(*) = 1 from listing_jobs j where j.vehicle_id = test.id('vehicle:rs30_a') and j.kind = 'marketing_photo' and j.status = 'queued' and j.id <> (select id from rs30_m1)));
select test.ok('the set as staff read it: each photo with its lifestyle pose and the AI mark',
  (select count(*) filter (where e ->> 'lifestyle' is not null) = 2 and bool_and((e ->> 'ai_generated')::boolean)
     from jsonb_array_elements(app.marketing_photos(test.id('rs30_admin'), jsonb_build_object('vehicle', test.id('vehicle:rs30_a'))) -> 'photos') e));
update vehicle_marketing_photos set status = 'made', path = coalesce(path, 'vehicles/v/marketing/' || id || '.jpg'), created_at = now() - interval '1 hour' where set_id = (select (r ->> 'set')::uuid from rs30_mk);
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id = test.id('vehicle:rs30_a') and kind = 'marketing_photo' and status in ('queued', 'running');
create temp table rs30_mk0 as select app.marketing_set(test.id('rs30_admin'), jsonb_build_object('vehicle', test.id('vehicle:rs30_a'), 'scene', 'highway', 'lifestyle', 0)) as r;
select test.eq('no lifestyle shot when asked for none', (select count(*) from vehicle_marketing_photos where set_id = (select (r ->> 'set')::uuid from rs30_mk0) and lifestyle is not null), 0::bigint);
