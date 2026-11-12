-- 99: the studio framing and the marks on listing photos (migration 0567): the job's context says whether a photo is
-- flagged "watermark"; the result clears the flag only when the worker says the mark is gone; the photos framed the old
-- way on a car not yet published are processed again once, off the site and with their plate checked again.
-- Fixtures start with "sfm"; every address is example.test.
select test.suite('99 studio framing and marks');

select test.mk_user('sfm_admin', 'admin');
select test.mk_owner('sfm_olive');
select test.mk_vehicle('sfm_car', 'sfm_olive');
create temp table s99sf as select (app.start_listing_intake(test.id('sfm_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:sfm_car'))) ->> 'intake_id')::uuid as i;
create or replace function test.sfm_up(p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('sfm_admin'), (select i from s99sf), jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/sfm/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000,
          'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create temp table s99ph as select test.sfm_up('other') as kept, test.sfm_up('trunk') as cleared, test.sfm_up('front_left') as outside;
update vehicle_photos set quality_flags = '["watermark"]'::jsonb where id in (select kept from s99ph union select cleared from s99ph);
select app.enqueue_listing_job((select i from s99sf), 'process_photo', x) from (select kept x from s99ph union all select cleared from s99ph union all select outside from s99ph) q;

select test.eq('the job of a flagged photo says so; the others do not',
  (select string_agg(format('%s=%s', p.shot_type, app.listing_job_context(j.id) #>> '{photo,watermark}'), ',' order by p.shot_type)
     from listing_jobs j join vehicle_photos p on p.id = j.vehicle_photo_id where j.kind = 'process_photo' and j.intake_id = (select i from s99sf)),
  'front_left=false,other=true,trunk=true');

create temp table s99cl as select j.id, j.vehicle_photo_id from app.claim_listing_jobs('sfm-w', 5000, array['process_photo']) j
  where j.vehicle_photo_id in (select kept from s99ph union select cleared from s99ph union select outside from s99ph);  -- jobs queued by other suites are claimed too (and left)
select app.worker_listing_result(c.id, jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
         'processed_path', 'vehicles/sfm/' || c.vehicle_photo_id || '.jpg', 'width', 1600, 'height', 1200, 'flags', '[]'::jsonb,
         'preset_version', case when c.vehicle_photo_id = (select outside from s99ph) then 'studio_v3' else 'normalize_v1' end,
         'watermark_removed', c.vehicle_photo_id = (select cleared from s99ph))))
  from s99cl c;
select test.ok('the mark not removed: still flagged and off the site, even though the result''s flags were empty',
  (select quality_flags ? 'watermark' and not is_public from vehicle_photos where id = (select kept from s99ph)));
select test.ok('the mark removed: the flag is gone', (select not quality_flags ? 'watermark' from vehicle_photos where id = (select cleared from s99ph)));
select test.ok('a photo never flagged is not flagged by its result', (select not quality_flags ? 'watermark' from vehicle_photos where id = (select outside from s99ph)));

-- ================================================================ processed again
-- the outside photo framed the old way, its plate not covered, on a car not yet published
insert into vehicle_listings (vehicle_id, status) values (test.id('vehicle:sfm_car'), 'draft') on conflict (vehicle_id) do update set status = 'draft';
update vehicle_photos set preset_version = 'studio_v2', background_status = 'done', status = 'approved', is_public = true,
       plate_status = 'unchecked', plate_boxes = '[]'::jsonb where id = (select outside from s99ph);
select test.ok('queued once', app.studio_v3_requeue() >= 1);
select test.ok('off the site, the background to do again', (select not is_public and background_status = 'pending' and plate_status = 'unchecked' from vehicle_photos where id = (select outside from s99ph)));
select test.eq('one job queued for it', (select count(*) from listing_jobs where vehicle_photo_id = (select outside from s99ph) and kind = 'process_photo' and status = 'queued'), 1::bigint);
select app.studio_v3_requeue();
select test.eq('run again: nothing more for it (idempotent)', (select count(*) from listing_jobs where vehicle_photo_id = (select outside from s99ph) and kind = 'process_photo' and status = 'queued'), 1::bigint);
-- a photo whose plate a person covered is left alone (its boxes would not fit a new framing)
update listing_jobs set status = 'succeeded' where vehicle_photo_id = (select outside from s99ph) and status = 'queued';
update vehicle_photos set preset_version = 'studio_v2', background_status = 'done', plate_status = 'covered' where id = (select outside from s99ph);
select app.studio_v3_requeue();
select test.eq('a covered plate on a car not named: not queued', (select count(*) from listing_jobs where vehicle_photo_id = (select outside from s99ph) and status = 'queued'), 0::bigint);
select test.ok('the service role only', not has_function_privilege('authenticated', 'app.studio_v3_requeue()', 'execute')
  and not has_function_privilege('anon', 'public.server_photo_mark_gate()', 'execute') and has_function_privilege('service_role', 'public.server_photo_mark_record(jsonb)', 'execute'));

-- ================================================================ 0568: the light touch-up
select test.mk_user('sfm_fin', 'va', 'finance');
create temp table s99en as select test.sfm_up('dashboard') as ph;
select app.enqueue_listing_job((select i from s99sf), 'process_photo', (select ph from s99en));
create temp table s99ej as select id from listing_jobs where vehicle_photo_id = (select ph from s99en) and kind = 'process_photo' and status = 'queued';
select test.ok('on by default: the job says touch it up', (select (app.listing_job_context(id) #>> '{photo,enhance}')::boolean from s99ej));
update program_settings set listing_photo_enhance = false;
select test.ok('the Admin setting off: not touched up', (select not (app.listing_job_context(id) #>> '{photo,enhance}')::boolean from s99ej));
update program_settings set listing_photo_enhance = true;
update vehicle_photos set enhance_off = true where id = (select ph from s99en);
select test.ok('the photo''s "Use original colours": not touched up', (select not (app.listing_job_context(id) #>> '{photo,enhance}')::boolean from s99ej));
update vehicle_photos set enhance_off = false where id = (select ph from s99en);
select app.claim_listing_jobs('sfm-e', 5000, array['process_photo']);
select app.worker_listing_result((select id from s99ej), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/sfm/dash.jpg', 'width', 1600, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'normalize_v1',
  'enhance', jsonb_build_object('version', 'enhance_v1', 'brightness', 1.02, 'contrast', 1.04, 'gamma', 1.01, 'saturation', 1.06, 'sharpen', 1))));
select test.eq('the values used are kept on the photo', (select enhance ->> 'saturation' from vehicle_photos where id = (select ph from s99en)), '1.06');
select test.throws('finance may not switch a photo''s touch-up',
  format($$select app.door(%L, 'aal2', 'ops_do', 'photo_enhance_set', '{"photo": "%s", "off": true}')$$, test.id('sfm_fin'), (select ph from s99en)), 'edits listing photos');
select test.eq('an Admin switches it off: the photo is made again',
  (select app.door(test.id('sfm_admin'), 'aal2', 'ops_do', 'photo_enhance_set', jsonb_build_object('photo', (select ph from s99en), 'off', true)) ->> 'queued'), 'true');
select test.ok('switched off, off the site, a job queued', (select enhance_off and not is_public from vehicle_photos where id = (select ph from s99en))
  and exists (select 1 from listing_jobs where vehicle_photo_id = (select ph from s99en) and kind = 'process_photo' and status = 'queued'));
select test.eq('the same switch again changes nothing',
  (select app.door(test.id('sfm_admin'), 'aal2', 'ops_do', 'photo_enhance_set', jsonb_build_object('photo', (select ph from s99en), 'off', true)) ->> 'queued'), 'false');
