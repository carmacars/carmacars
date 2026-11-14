-- 99: migration 2780 (release 44): the listing photo standard. Photos made under an older standard are made again with Gemini
-- (no more "nothing to redo"), detail photos are sorted again so a car's outside photos filed as details become its primary
-- photo, a Gemini limit waits instead of failing, blurred interiors are made again sharp. Fixtures start with "rq44p_";
-- every address is example.test. Since 2842 the buttons are the r45 redo (99_r45_photos): this file tests 2780's layer
-- (app.photo_showroom_pre2842), still there underneath.
select test.suite('99 r44 photo standard (2780)');

create temp table rq44p_prev as select listing_plate_check_required as plate, listing_showroom_ai as ai, listing_showroom_ai_daily as daily,
  listing_photo_spec_auto as auto from app.settings();
update program_settings set listing_plate_check_required = true, listing_showroom_ai = true, listing_showroom_ai_daily = 100, listing_photo_spec_auto = true
 where id = (select id from app.settings());

select test.mk_user('rq44p_admin', 'admin');
select test.mk_user('rq44p_cs', 'va', 'cs');
select test.mk_owner('rq44p_olive');
select test.mk_vehicle('rq44p_g', 'rq44p_olive');   -- outside photos made under the old standard
select test.mk_vehicle('rq44p_h', 'rq44p_olive');   -- its outside photos were filed as details: flagged, "nothing to redo" before

select test.eq('the standard is the web''s PHOTO_SPEC (r45.1 since 2840)', app.photo_spec(), 'r45.1');

create temp table rq44p_i as select
  (app.start_listing_intake(test.id('rq44p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rq44p_g'))) ->> 'intake_id')::uuid as g,
  (app.start_listing_intake(test.id('rq44p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rq44p_h'))) ->> 'intake_id')::uuid as h;
create or replace function test.rq44p_up(p_intake uuid, p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rq44p_admin'), p_intake, jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rq44p/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create or replace function test.rq44p_live(p_car text) returns void language sql as $$
  update vehicle_photos set background_status = 'done', status = 'approved', is_public = true, plate_status = 'not_visible',
         processed_path = coalesce(processed_path, 'vehicles/rq44p/' || p_car || '-' || shot_type || '-' || left(id::text, 6) || '.jpg')
   where vehicle_id = test.id('vehicle:' || p_car) and replaced_at is null;
  update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id = test.id('vehicle:' || p_car) and status in ('queued', 'running') $$;
create or replace function test.rq44p_job(p_photo uuid, p_kind text) returns listing_jobs language sql as $$
  select * from listing_jobs where vehicle_photo_id = p_photo and kind = p_kind order by created_at desc limit 1 $$;
-- the worker claimed the job, then answers (as server_listing_claim and server_listing_result do)
create or replace function test.rq44p_answer(p_photo uuid, p_kind text, p jsonb) returns jsonb language plpgsql as $$
declare v uuid := (test.rq44p_job(p_photo, p_kind)).id;
begin
  update listing_jobs set status = 'running', attempts = attempts + 1, locked_at = now(), locked_by = 'rq44p', started_at = now() where id = v;
  return app.worker_listing_result(v, p);
end $$;

-- ---------------------------------------------------------------- 1. a car's photos under the old standard
create temp table rq44p_gp as select test.rq44p_up((select g from rq44p_i), 'front_left') as fl, test.rq44p_up((select g from rq44p_i), 'rear') as rear,
  test.rq44p_up((select g from rq44p_i), 'dashboard') as dash;
select test.rq44p_live('rq44p_g');
update vehicle_photos set scene = 'showroom', preset_version = 'studio_showroom_v2', showroom = jsonb_build_object('provider', 'ai'),
       cutout = jsonb_build_object('auto_mask', 'vehicles/rq44p/work/' || id || '-mask.png')
 where vehicle_id = test.id('vehicle:rq44p_g') and shot_type <> 'dashboard';
select test.eq('both outside photos are due under the new standard (the dashboard is not)',
  (select count(*)::text from app.photo_spec_due(test.id('vehicle:rq44p_g'))), '2');
select test.eq('the standard angle is first in the queue', (select shot_type from app.photo_spec_due(test.id('vehicle:rq44p_g')) limit 1), 'front_left');

select test.eq('Redo with Gemini on the car queues them', (app.photo_showroom_pre2842(test.id('rq44p_cs'), jsonb_build_object('action', 'gemini', 'vehicle', test.id('vehicle:rq44p_g'))) ->> 'queued'), '2');
select test.ok('each job: Gemini only, the segmenter''s own mask scored again (auto_mask), the standard noted on the photo',
  (select count(*) = 2 and bool_and(j.input ->> 'engine' = 'gemini') and bool_and((j.input ->> 'auto_mask')::boolean) and bool_and(ph.photo_spec_tried = 'r45.1')
     from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id where j.vehicle_id = test.id('vehicle:rq44p_g') and j.kind = 'process_photo' and j.status = 'queued'));

-- the worker made the standard angle: the standard is stored with how it was made
select test.rq44p_answer((select fl from rq44p_gp), 'process_photo', jsonb_build_object('ok', true, 'provider', 'ai',
  'output', jsonb_build_object('processed_path', 'vehicles/rq44p/g-fl-new.jpg', 'width', 1800, 'height', 1200, 'preset_version', 'studio_showroom_v2', 'flags', '[]'::jsonb,
    'showroom', jsonb_build_object('provider', 'ai', 'model', 'gemini-2.5-flash-image', 'note', null, 'reason', null, 'mode', 'swap', 'spec', 'r45.1'))));
select test.eq('the photo records the standard and the mode', (select showroom ->> 'spec' || '/' || (showroom ->> 'mode') || '/' || (showroom ->> 'provider') from vehicle_photos where id = (select fl from rq44p_gp)), 'r45.1/swap/ai');
select test.eq('a photo made under the standard is no longer due', (select count(*)::text from app.photo_spec_due(test.id('vehicle:rq44p_g')) d where d.id = (select fl from rq44p_gp)), '0');

-- Gemini's daily limit: the step waits for tomorrow instead of failing for good
select test.rq44p_answer((select rear from rq44p_gp), 'process_photo', jsonb_build_object('ok', false, 'provider', 'gemini', 'retryable', false,
  'error', 'Redo with Gemini: Gemini did not make it (today''s image model limit). The photo was not changed.', 'output', jsonb_build_object('gemini_wait', 'limit')));
select test.ok('limit: queued again after midnight (Toronto), its attempts back to 0, the reason kept',
  (select status = 'queued' and attempts = 0 and next_attempt_at >= app.local_midnight(app.local_date(now()) + 1) and error like 'Waiting for Gemini (limit)%'
     from listing_jobs where id = (test.rq44p_job((select rear from rq44p_gp), 'process_photo')).id));
select test.rq44p_answer((select rear from rq44p_gp), 'process_photo', jsonb_build_object('ok', false, 'provider', 'gemini', 'retryable', false,
  'error', 'Redo with Gemini: Gemini did not make it (blocked). The photo was not changed.'));
select test.eq('a refusal stays failed (a person looks)', (test.rq44p_job((select rear from rq44p_gp), 'process_photo')).status, 'failed');
select test.eq('and the photo is still on the site as it was', (select is_public::text from vehicle_photos where id = (select rear from rq44p_gp)), 'true');

-- ---------------------------------------------------------------- 2. outside photos filed as details: sorted again
create temp table rq44p_hp as select test.rq44p_up((select h from rq44p_i), 'other') as o1, test.rq44p_up((select h from rq44p_i), 'other') as o2,
  test.rq44p_up((select h from rq44p_i), 'other') as o3, test.rq44p_up((select h from rq44p_i), 'dashboard') as dash;
select test.rq44p_live('rq44p_h');
select test.eq('flagged: the first photo is not an outside one', app.vehicle_primary_state(test.id('vehicle:rq44p_h')), 'not_exterior');
create temp table rq44p_hr as select app.photo_showroom_pre2842(test.id('rq44p_cs'), jsonb_build_object('action', 'gemini', 'vehicle', test.id('vehicle:rq44p_h'))) as r;
select test.eq('Redo with Gemini: no outside photo to make, but the three detail photos are sorted again (not "nothing to redo")',
  (select (r ->> 'queued') || '/' || (r ->> 'resorting') from rq44p_hr), '0/3');
select test.ok('each sort job knows its photo and original',
  (select count(*) = 3 and bool_and(j.input #>> '{resort,photo_id}' = j.vehicle_photo_id::text) and bool_and(j.input #>> '{resort,source}' like 'vehicles/original/rq44p/other-%')
     from listing_jobs j where j.vehicle_id = test.id('vehicle:rq44p_h') and j.kind = 'photo_resort' and j.status = 'queued'));
select test.eq('asked again: nothing more (each photo sorted once a standard)',
  (app.photo_showroom_pre2842(test.id('rq44p_admin'), jsonb_build_object('action', 'gemini', 'vehicle', test.id('vehicle:rq44p_h'))) ->> 'resorting'), '0');

-- the model sees the front three-quarter: filed as the standard angle and made in the showroom (the usual step, no engine)
select test.rq44p_answer((select o1 from rq44p_hp), 'photo_resort', '{"ok": true, "provider": "gemini:gemini-2.0-flash", "output": {"resort": {"decision": "sorted", "shot": "front_left", "exterior": true}}}'::jsonb);
select test.eq('filed as front_left, in the showroom, the sort recorded',
  (select shot_type || '/' || angle || '/' || scene || '/' || (resort ->> 'filed_as') from vehicle_photos where id = (select o1 from rq44p_hp)), 'front_left/front_left/showroom/front_left');
select test.ok('a process step is queued for it (Gemini on top, not Gemini only)',
  (select status = 'queued' and not (input ? 'engine') and input ->> 'scene' = 'showroom' from listing_jobs where id = (test.rq44p_job((select o1 from rq44p_hp), 'process_photo')).id));
-- a second front three-quarter: an extra outside photo; the dashboard answer and an unsure answer stay details
select test.rq44p_answer((select o2 from rq44p_hp), 'photo_resort', '{"ok": true, "provider": "m", "output": {"resort": {"decision": "sorted", "shot": "front_left", "exterior": true}}}'::jsonb);
select test.eq('the standard angle is taken: an extra outside photo', (select shot_type from vehicle_photos where id = (select o2 from rq44p_hp)), 'exterior_more');
select test.rq44p_answer((select o3 from rq44p_hp), 'photo_resort', '{"ok": true, "provider": "m", "output": {"resort": {"decision": "sorted", "shot": "exterior_other", "exterior": false}}}'::jsonb);
select test.eq('a body detail (exterior_other) stays a detail, kept as taken', (select shot_type || '/' || (resort ->> 'decision') || '/' || (resort ->> 'shot') from vehicle_photos where id = (select o3 from rq44p_hp)), 'other/sorted/exterior_other');
-- once made and on the site, the car's first photo is the standard angle and the flag is gone
update vehicle_photos set status = 'approved', is_public = true, background_status = 'done', processed_path = 'vehicles/rq44p/h-fl.jpg', plate_status = 'not_visible'
 where id = (select o1 from rq44p_hp);
select test.eq('the car''s first photo is the outside front three-quarter', (select shot_type from app.cover_photo(test.id('vehicle:rq44p_h'))), 'front_left');
select test.eq('the flag is gone', app.vehicle_primary_state(test.id('vehicle:rq44p_h')), 'exterior');

-- the model may not be asked now: again in an hour
create temp table rq44p_d as select test.rq44p_up((select h from rq44p_i), 'other') as o4;
select test.rq44p_live('rq44p_h');
select app.photo_resort_queue(test.id('rq44p_admin'), (select o4 from rq44p_d));
select test.rq44p_answer((select o4 from rq44p_d), 'photo_resort', '{"ok": true, "provider": "carmacars", "output": {"resort": {"photo_id": "x", "decision": "deferred"}}}'::jsonb);
select test.ok('deferred: queued again in about an hour, the photo unchanged',
  (select j.status = 'queued' and j.next_attempt_at > now() + interval '50 minutes' and ph.shot_type = 'other'
     from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id where j.id = (test.rq44p_job((select o4 from rq44p_d), 'photo_resort')).id));
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id = test.id('vehicle:rq44p_h') and status in ('queued', 'running');

-- ---------------------------------------------------------------- 3. a photo added outside a listing is no longer skipped
create temp table rq44p_n as select test.rq44p_up((select g from rq44p_i), 'left') as l;
select test.rq44p_live('rq44p_g');
update vehicle_photos set intake_id = null, scene = 'showroom', cutout = jsonb_build_object('mask', 'vehicles/rq44p/work/edited.png') where id = (select l from rq44p_n);
create temp table rq44p_nr as select app.photo_showroom_pre2842(test.id('rq44p_admin'), jsonb_build_object('action', 'gemini', 'vehicle', test.id('vehicle:rq44p_g'))) as r;
select test.ok('Redo with Gemini adopts the car''s listing for the photo', (select (r ->> 'adopted')::int >= 1 from rq44p_nr)
  and (select intake_id is not null from vehicle_photos where id = (select l from rq44p_n)));
select test.ok('and queues it with Gemini (a staff-edited mask is not re-scored)',
  (select status = 'queued' and input ->> 'engine' = 'gemini' and not (input ? 'auto_mask') from listing_jobs where id = (test.rq44p_job((select l from rq44p_n), 'process_photo')).id));
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id = test.id('vehicle:rq44p_g') and status in ('queued', 'running');

-- ---------------------------------------------------------------- 4. every car, and the job
select test.throws('every car at once: not customer service', format('select app.photo_showroom_pre2842(%L, jsonb_build_object(''action'', ''gemini'', ''all'', true))', test.id('rq44p_cs')), 'An Admin or fleet');
select test.throws('Apply stays Apply-only for every car (other actions unchanged)', format('select app.photo_showroom(%L, jsonb_build_object(''action'', ''redo'', ''all'', true))', test.id('rq44p_admin')), 'Apply only');
update vehicle_photos set photo_spec_tried = null where vehicle_id = test.id('vehicle:rq44p_g');
create temp table rq44p_all as select app.photo_showroom_pre2842(test.id('rq44p_admin'), jsonb_build_object('action', 'gemini', 'all', true, 'limit', 1)) as r;
select test.eq('every car, within a limit: one photo queued, the standard angle first', (select r ->> 'queued' from rq44p_all), '1');
select test.ok('it says what is left', (select (r ? 'waiting') and (r ? 'left_today') and r ->> 'spec' = 'r45.1' from rq44p_all));
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id in (test.id('vehicle:rq44p_g'), test.id('vehicle:rq44p_h')) and status in ('queued', 'running');
-- the day's Gemini calls used up: nothing queued
update program_settings set listing_showroom_ai_daily = 0 where id = (select id from app.settings());
select test.eq('no Gemini call left today: nothing queued', (app.photo_showroom_pre2842(test.id('rq44p_admin'), jsonb_build_object('action', 'gemini', 'all', true)) ->> 'queued'), '0');
update program_settings set listing_showroom_ai_daily = 100 where id = (select id from app.settings());

-- start the job from a clean queue: Gemini steps queued by hand above (or by other test files of this run) are not the job's
update listing_jobs set status = 'succeeded', finished_at = now() where kind = 'process_photo' and status = 'queued' and input ->> 'engine' = 'gemini';
-- a blurred interior (before r44) is made again sharp by the job
update vehicle_photos set preset_version = 'windows_blur_v1' where id = (select dash from rq44p_gp);
select test.ok('the job runs and reports', app.job_photo_spec() like '% photo(s) queued, % sorting, % made sharp, % waiting');
select test.ok('the blurred interior is queued again (a plain step, no Gemini)',
  (select status = 'queued' and input ->> 'sharp' = 'r45.1' and not (input ? 'engine') from listing_jobs where id = (test.rq44p_job((select dash from rq44p_gp), 'process_photo')).id));
select test.ok('the job only takes photos that stay on the site while made, once a standard',
  not exists (select 1 from listing_jobs j join vehicle_photos ph on ph.id = j.vehicle_photo_id
               where j.kind = 'process_photo' and j.status = 'queued' and j.input ->> 'engine' = 'gemini' and coalesce(ph.cutout ->> 'mask', ph.cutout ->> 'auto_mask') is null));
update program_settings set listing_photo_spec_auto = false where id = (select id from app.settings());
select test.eq('switched off in Program settings', app.job_photo_spec(), 'off');

-- ---------------------------------------------------------------- 5. nothing for the public to call
select test.ok('the new functions are for the server only',
  not has_function_privilege('authenticated', 'app.photo_spec_upgrade(uuid, integer, boolean)', 'execute') and not has_function_privilege('anon', 'app.job_photo_spec()', 'execute')
  and not has_function_privilege('authenticated', 'app.photo_resort_queue(uuid, uuid)', 'execute') and has_function_privilege('service_role', 'app.photo_spec_upgrade(uuid, integer, boolean)', 'execute'));
select test.ok('photo_showroom and worker_listing_result keep their grants',
  has_function_privilege('service_role', 'app.photo_showroom(uuid, jsonb)', 'execute') and not has_function_privilege('authenticated', 'app.photo_showroom(uuid, jsonb)', 'execute')
  and has_function_privilege('service_role', 'app.worker_listing_result(uuid, jsonb)', 'execute') and not has_function_privilege('anon', 'app.worker_listing_result(uuid, jsonb)', 'execute'));

update program_settings set listing_plate_check_required = (select plate from rq44p_prev), listing_showroom_ai = (select ai from rq44p_prev),
       listing_showroom_ai_daily = (select daily from rq44p_prev), listing_photo_spec_auto = (select auto from rq44p_prev) where id = (select id from app.settings());
