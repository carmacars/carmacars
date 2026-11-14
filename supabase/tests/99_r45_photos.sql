-- 99: migrations 2840 to 2842 (release 45): the listing photo standard r45.1. Every photo made by Gemini from its original
-- (job photo_r45), the photos made by Cloudflare's cut-out made again, missing standard angles generated, plates blurred, the
-- first photo always an outside one, the daily limit high with a reserve, the Admin view and the redo buttons. Fixtures
-- start with "rq45p_"; no real names or plates.
select test.suite('99 r45 photo standard (2840)');

create temp table rq45p_prev as select listing_plate_check_required as plate, listing_showroom_ai as ai, listing_showroom_ai_daily as daily,
  listing_photo_r45_auto as auto, listing_photo_r45_reserve as reserve, listing_photo_r45_batch as batch from app.settings();
update program_settings set listing_plate_check_required = true, listing_showroom_ai = true, listing_photo_r45_auto = true, listing_photo_r45_batch = 200
 where id = (select id from app.settings());

select test.mk_user('rq45p_admin', 'admin');
select test.mk_user('rq45p_fleet', 'va', 'fleet');
select test.mk_user('rq45p_cs', 'va', 'cs');
select test.mk_owner('rq45p_olive');
select test.mk_vehicle('rq45p_a', 'rq45p_olive');   -- photos made with Cloudflare's cut-out before r45
select test.mk_vehicle('rq45p_b', 'rq45p_olive');   -- one inside photo only

select test.eq('the standard is the web''s R45_SPEC', app.photo_spec(), 'r45.1');
select test.ok('the daily Gemini limit is the paid tier''s (2000 by default), a reserve kept for new uploads',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_showroom_ai_daily') = '2000'
  and (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_photo_r45_reserve') = '50');
select test.ok('no Cloudflare in the listing pipeline: transformations off, the r44 upgrade (from the cut-out) off, by default',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_cf_transformations') = 'false'
  and (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_photo_spec_auto') = 'false');

create temp table rq45p_i as select
  (app.start_listing_intake(test.id('rq45p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rq45p_a'))) ->> 'intake_id')::uuid as a,
  (app.start_listing_intake(test.id('rq45p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rq45p_b'))) ->> 'intake_id')::uuid as b;
create or replace function test.rq45p_up(p_intake uuid, p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rq45p_admin'), p_intake, jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rq45p/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
-- the photos as Cloudflare's cut-out made them (r44 and before), on the site
create or replace function test.rq45p_live(p_car text) returns void language sql as $$
  update vehicle_photos set background_status = 'done', status = 'approved', is_public = true, plate_status = 'covered', plate_style = 'carma',
         preset_version = case when shot_type in ('dashboard', 'front_seats', 'rear_seats', 'trunk') then 'windows_replace_v1' else 'studio_showroom_v2' end,
         cutout = jsonb_build_object('auto_mask', 'vehicles/rq45p/work/' || id || '-mask.png'),
         processed_path = coalesce(processed_path, 'vehicles/rq45p/' || p_car || '-' || shot_type || '-' || left(id::text, 6) || '.jpg')
   where vehicle_id = test.id('vehicle:' || p_car) and replaced_at is null;
  update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id = test.id('vehicle:' || p_car) and status in ('queued', 'running') $$;
create or replace function test.rq45p_job(p_photo uuid) returns listing_jobs language sql as $$
  select * from listing_jobs where vehicle_photo_id = p_photo and kind = 'photo_r45' order by created_at desc limit 1 $$;
create or replace function test.rq45p_answer(p_photo uuid, p jsonb) returns jsonb language plpgsql as $$
declare v uuid := (test.rq45p_job(p_photo)).id;
begin
  update listing_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), locked_by = 'rq45p', started_at = now() where id = v;
  return app.worker_listing_result(v, p);
end $$;
create or replace function test.rq45p_made(p_path text, p_plates jsonb default '[]'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('ok', true, 'provider', 'ai', 'output', jsonb_build_object('processed_path', p_path, 'width', 1800, 'height', 1200,
    'variants', jsonb_build_array(jsonb_build_object('width', 480, 'format', 'jpg', 'path', replace(p_path, '.jpg', '-480.jpg'))), 'preset_version', 'gemini_r45', 'flags', '[]'::jsonb,
    'showroom', jsonb_build_object('provider', 'ai', 'model', 'gemini-2.5-flash-image', 'mode', 'edit', 'spec', 'r45.1'),
    'r45', jsonb_build_object('pass', true, 'spec', 'r45.1', 'plates', p_plates, 'model', 'gemini-2.5-flash-image', 'check_model', 'gemini:gemini-2.5-flash', 'view', 'front_left', 'reasons', '[]'::jsonb))) $$;
create or replace function test.rq45p_refused(p_why text) returns jsonb language sql as $$
  select jsonb_build_object('ok', true, 'provider', 'gemini', 'output', jsonb_build_object('r45', jsonb_build_object('pass', false, 'spec', 'r45.1', 'why', p_why,
    'reasons', jsonb_build_array('original_background')))) $$;

-- ---------------------------------------------------------------- 1. the order: the front three-quarter first, inside last
select test.eq('the order of the shots: the standard set first, as r45.ts STANDARD_ANGLES', (select string_agg(s, ',' order by app.photo_rank(s), s) from unnest(array['trunk', 'dashboard', 'rear', 'front_left', 'front_seats', 'rear_left', 'left', 'rear_seats', 'other', 'front', 'right']) s),
  'front_left,front,left,rear_left,rear,right,dashboard,front_seats,rear_seats,trunk,other');
select test.eq('ranks as web/src/lib/photo-order.ts', (select string_agg(app.photo_rank(s)::text, ',') from unnest(array['front_left', 'front', 'left', 'rear_left', 'rear', 'front_right', 'right', 'rear_right', 'exterior_more', 'dashboard', 'trunk', 'other', null]) s), '0,1,2,3,4,5,6,7,8,20,23,30,30');

-- ---------------------------------------------------------------- 2. the photos made by Cloudflare are made again from the original
create temp table rq45p_ap as select test.rq45p_up((select a from rq45p_i), 'front_left') as fl, test.rq45p_up((select a from rq45p_i), 'rear') as rear,
  test.rq45p_up((select a from rq45p_i), 'dashboard') as dash;
select test.rq45p_live('rq45p_a');
select test.eq('every photo made by Cloudflare is due (outside and inside)', (select count(*)::text from vehicle_photos ph where ph.vehicle_id = test.id('vehicle:rq45p_a') and app.photo_r45_due(ph)), '3');
select test.eq('the car''s missing standard angles', (select string_agg(m, ',') from app.photo_r45_missing(test.id('vehicle:rq45p_a')) m), 'front,left,rear_left,front_seats,rear_seats,trunk');

select app.job_photo_r45();
select test.eq('the job takes the car: 3 photos made again, 6 angles generated',
  (select count(*) filter (where not ph.ai_generated) || '/' || count(*) filter (where ph.ai_generated) from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id
    where j.vehicle_id = test.id('vehicle:rq45p_a') and j.kind = 'photo_r45' and j.status = 'queued'), '3/6');
select test.ok('each real photo: job photo_r45, from its original (no cut-out, no Cloudflare step)',
  (select count(*) = 3 and bool_and(j.input #>> '{r45,mode}' = 'edit') and bool_and(not (j.input ? 'edit')) and bool_and(not (j.input ? 'engine'))
     from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id where j.vehicle_id = test.id('vehicle:rq45p_a') and j.kind = 'photo_r45' and j.status = 'queued' and not ph.ai_generated));
select test.ok('no Cloudflare path is left: nothing queued for the car uses a cut-out or the composite',
  not exists (select 1 from listing_jobs j where j.vehicle_id = test.id('vehicle:rq45p_a') and j.status = 'queued' and (j.kind = 'process_photo' or j.input ? 'edit' or j.input ? 'auto_mask')));
select test.ok('each generated view: marked ai_generated, off the site, made from the car''s own originals, the car named',
  (select count(*) = 6 and bool_and(not ph.is_public) and bool_and(ph.original_path like 'vehicles/original/rq45p/%') and bool_and(j.input #>> '{r45,mode}' = 'generate')
          and bool_and(jsonb_array_length(j.input #> '{r45,sources}') between 1 and 3) and bool_and(j.input #>> '{r45,car,make}' is not null)
     from vehicle_photos ph join listing_jobs j on j.vehicle_photo_id = ph.id and j.kind = 'photo_r45' where ph.vehicle_id = test.id('vehicle:rq45p_a') and ph.ai_generated));
select test.eq('an outside view is made from outside photos first', (select (j.input #>> '{r45,sources,0}') like '%front_left%' from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id
   where ph.vehicle_id = test.id('vehicle:rq45p_a') and ph.ai_generated and ph.shot_type = 'front')::text, 'true');
select app.job_photo_r45();
select test.eq('the job again: nothing new for the car (each photo once, cached)', (select count(*)::text from listing_jobs j where j.vehicle_id = test.id('vehicle:rq45p_a') and j.kind = 'photo_r45'), '9');

-- made and passed: on the site, the plate blurred (never drawn), the version before kept
select test.rq45p_answer((select fl from rq45p_ap), test.rq45p_made('vehicles/rq45p/a-fl-r45.jpg', '[{"x":0.4,"y":0.7,"w":0.12,"h":0.05}]'));
select test.ok('done: the new file on the site, r45.1, the plate blurred, approved and public',
  (select processed_path = 'vehicles/rq45p/a-fl-r45.jpg' and r45 ->> 'state' = 'done' and r45 ->> 'spec' = 'r45.1' and plate_status = 'covered' and plate_style = 'blur'
          and plate_auto ->> 'decision' = 'blurred' and is_public and status = 'approved' and cutout is null from vehicle_photos where id = (select fl from rq45p_ap)));
select test.ok('the Cloudflare version is kept as the version before', exists (select 1 from vehicle_photo_versions where photo_id = (select fl from rq45p_ap) and reason = 'r45' and preset_version = 'studio_showroom_v2'));
select test.ok('no plate check is queued again (no CARMA plate drawn on it)', not exists (select 1 from listing_jobs where vehicle_photo_id = (select fl from rq45p_ap) and kind = 'plate_auto' and status = 'queued'));
select test.eq('a photo at r45.1 is never due again unless asked', (select app.photo_r45_due(ph)::text from vehicle_photos ph where id = (select fl from rq45p_ap)), 'false');

-- refused by the check: tried again twice, then off the site and flagged, never published
select test.rq45p_answer((select rear from rq45p_ap), test.rq45p_refused('the check refused it: original_background'));
select test.ok('refused once: queued again, the try counted', (select r45 ->> 'state' = 'queued' and (r45 ->> 'tries')::int = 1 from vehicle_photos where id = (select rear from rq45p_ap))
  and (test.rq45p_job((select rear from rq45p_ap))).status = 'queued');
select test.rq45p_answer((select rear from rq45p_ap), test.rq45p_refused('the check refused it: warped'));
select test.rq45p_answer((select rear from rq45p_ap), test.rq45p_refused('the check refused it: text_elsewhere'));
select test.ok('refused three times: flagged and off the site, no job left',
  (select r45 ->> 'state' = 'flagged' and (r45 ->> 'tries')::int = 3 and not is_public and quality_flags ? 'r45_flagged' from vehicle_photos where id = (select rear from rq45p_ap))
  and not exists (select 1 from listing_jobs where vehicle_photo_id = (select rear from rq45p_ap) and kind = 'photo_r45' and status = 'queued'));
select test.ok('a flagged real angle counts as missing (a view is generated for it)', exists (select 1 from app.photo_r45_missing(test.id('vehicle:rq45p_a')) m where m = 'rear'));

-- Gemini's daily limit: waits for tomorrow, no try counted
select test.rq45p_answer((select dash from rq45p_ap), jsonb_build_object('ok', true, 'provider', 'gemini', 'output', jsonb_build_object('r45', jsonb_build_object('pass', false, 'wait', 'limit', 'why', 'limit'))));
select test.ok('limit: queued again after midnight, no try counted',
  (select status = 'queued' and next_attempt_at >= app.local_midnight(app.local_date(now()) + 1) from listing_jobs where id = (test.rq45p_job((select dash from rq45p_ap))).id)
  and (select coalesce((r45 ->> 'tries')::int, 0) = 0 from vehicle_photos where id = (select dash from rq45p_ap)));

-- a generated view made: approved, on the site, marked; a real photo of the angle later replaces it
create temp table rq45p_gen as select id from vehicle_photos where vehicle_id = test.id('vehicle:rq45p_a') and ai_generated and shot_type = 'front';
select test.rq45p_answer((select id from rq45p_gen), test.rq45p_made('vehicles/rq45p/a-front-gen.jpg'));
select test.ok('a generated view: approved, public, marked ai_generated', (select status = 'approved' and is_public and ai_generated and r45 ->> 'state' = 'done' and (r45 ->> 'generated')::boolean
   from vehicle_photos where id = (select id from rq45p_gen)));
select test.rq45p_up((select a from rq45p_i), 'front');
select test.ok('a real photo of the angle replaces the generated view', (select replaced_at is not null and not is_public from vehicle_photos where id = (select id from rq45p_gen)));

-- ---------------------------------------------------------------- 3. the first photo is always an outside one
create temp table rq45p_bp as select test.rq45p_up((select b from rq45p_i), 'dashboard') as dash;
select test.rq45p_live('rq45p_b');
select test.eq('flagged in Admin: the first photo would be an inside one', app.vehicle_primary_state(test.id('vehicle:rq45p_b')), 'not_exterior');
select test.eq('the site shows no photo rather than an inside one first', jsonb_array_length(app.public_listing_photos(test.id('vehicle:rq45p_b')))::text, '0');
select test.ok('the cards and feeds get no inside cover', (app.cover_photo(test.id('vehicle:rq45p_b'))).id is null);
select test.ok('the car with photos keeps them, the front three-quarter first', (select app.public_listing_photos(test.id('vehicle:rq45p_a')) -> 0 ->> 'shot') = 'front_left'
  and (select (app.cover_photo(test.id('vehicle:rq45p_a'))).shot_type) = 'front_left');
select test.throws('a listing is never published with an inside photo first',
  format('insert into vehicle_listings (vehicle_id, status, slug) values (%L, %L, %L)', test.id('vehicle:rq45p_b'), 'published', 'rq45p-b-example'), '%first photo would be an inside one%');
-- the job generates the missing front three-quarter of that car (from its own inside photo, the only one it has); the other
-- cars' steps of this run are taken as done so the queue has room
update listing_jobs set status = 'succeeded', finished_at = now() where kind = 'photo_r45' and status = 'queued' and vehicle_id <> test.id('vehicle:rq45p_b');
select app.job_photo_r45();
create temp table rq45p_bfl as select id from vehicle_photos where vehicle_id = test.id('vehicle:rq45p_b') and ai_generated and shot_type = 'front_left' and replaced_at is null;
select test.eq('its front three-quarter is generated', (select count(*)::text from rq45p_bfl), '1');
select test.rq45p_answer((select id from rq45p_bfl), test.rq45p_made('vehicles/rq45p/b-fl-gen.jpg'));
select test.eq('then the generated front three-quarter is the first photo', app.public_listing_photos(test.id('vehicle:rq45p_b')) -> 0 ->> 'shot', 'front_left');
select test.eq('and the flag clears', app.vehicle_primary_state(test.id('vehicle:rq45p_b')), 'exterior');

-- ---------------------------------------------------------------- 4. the daily limit
create temp table rq45p_used as select count(*)::int as n from provider_calls c where c.purpose = 'listing_showroom' and c.created_at >= app.local_midnight(app.local_date(now()));
update program_settings set listing_showroom_ai_daily = (select n from rq45p_used) + 5, listing_photo_r45_reserve = 2 where id = (select id from app.settings());
select test.eq('Gemini left today: the limit less the reserve less today''s calls', app.photo_gemini_left(2)::text, '3');
update program_settings set listing_showroom_ai_daily = (select n from rq45p_used) + 2 where id = (select id from app.settings());
select test.eq('at the reserve the job queues nothing for the fleet (the reserve is for new uploads)', app.job_photo_r45(), 'full or waiting for Gemini');
update program_settings set listing_showroom_ai_daily = 2000, listing_photo_r45_reserve = 50 where id = (select id from app.settings());

-- ---------------------------------------------------------------- 5. Admin: the view and the redo buttons
select test.throws('customer service does not redo every car''s photos', format('select app.photo_r45_redo(%L, %L)', test.id('rq45p_cs'), jsonb_build_object('all', true)), '%Admin or fleet%');
create temp table rq45p_view as select app.photo_r45_fleet_read(test.id('rq45p_fleet')) as v;
select test.ok('the view: per car, photos at the standard out of all, generated, flagged, last run',
  (select (c ->> 'at_standard')::int >= 1 and (c ->> 'total')::int >= 4 and (c ->> 'flagged')::int = 1 and c ? 'generated' and c ->> 'last_run' is not null
     from rq45p_view, jsonb_array_elements(v -> 'cars') c where c ->> 'id' = test.id('vehicle:rq45p_a')::text));
create temp table rq45p_redo as select app.photo_r45_redo(test.id('rq45p_fleet'), jsonb_build_object('vehicle', test.id('vehicle:rq45p_b'))) as r;
select test.ok('Redo this car now: its photo at the standard made again, ahead of the fleet',
  (select (r ->> 'queued')::int + (r ->> 'generating')::int >= 1 from rq45p_redo) and (select r45 ->> 'state' from vehicle_photos where id = (select id from rq45p_bfl)) = 'queued'
  and (test.rq45p_job((select id from rq45p_bfl))).next_attempt_at <= now());
create temp table rq45p_all as select app.photo_showroom(test.id('rq45p_admin'), jsonb_build_object('action', 'gemini', 'all', true)) as r;
select test.ok('Redo every car (the old button too) marks every photo to be made again at r45.1',
  (select (r ->> 'waiting')::int >= 1 from rq45p_all)
  and not exists (select 1 from vehicle_photos ph where ph.vehicle_id = test.id('vehicle:rq45p_a') and app.photo_r45_applies(ph) and ph.r45 ->> 'state' = 'done'));

update program_settings set listing_plate_check_required = p.plate, listing_showroom_ai = p.ai, listing_showroom_ai_daily = p.daily, listing_photo_r45_auto = p.auto,
       listing_photo_r45_reserve = p.reserve, listing_photo_r45_batch = p.batch
  from rq45p_prev p where program_settings.id = (select id from app.settings());
