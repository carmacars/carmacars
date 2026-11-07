-- 99: migration 0660: a listing's outside photos framed again when staff ask (studio_v4); a plate suggestion is not kept
-- while its photo is being made again, and the new photo drops the one it had. Fixtures start with "sfp"; every
-- address is example.test.
select test.suite('99 studio framing and plates (0660)');

select test.mk_user('sfp_admin', 'admin');
select test.mk_user('sfp_fin', 'va', 'finance');
select test.mk_owner('sfp_olive');
select test.mk_vehicle('sfp_car', 'sfp_olive');
create temp table s60i as select (app.start_listing_intake(test.id('sfp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:sfp_car'))) ->> 'intake_id')::uuid as i;
create or replace function test.sfp_up(p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('sfp_admin'), (select i from s60i), jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/sfp/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000,
          'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create temp table s60p as select test.sfp_up('front_left') as outside, test.sfp_up('dashboard') as inside;
-- both made once, the outside photo framed the old way, a person checked nothing yet
update listing_jobs set status = 'succeeded', finished_at = now() - interval '1 hour' where intake_id = (select i from s60i) and kind = 'process_photo';
update vehicle_photos set preset_version = 'studio_v3', background_status = 'done', status = 'approved', is_public = true, processed_path = 'vehicles/sfp/fl.jpg',
       plate_status = 'unchecked', plate_boxes = '[]'::jsonb, plate_suggestion = jsonb_build_object('answer', '{}'::jsonb, 'at', (now() - interval '2 hours')::text)
 where id = (select outside from s60p);
update vehicle_photos set preset_version = 'normalize_v1', background_status = 'done', status = 'approved', is_public = true where id = (select inside from s60p);

select test.throws('finance may not frame photos again',
  format($$select app.door(%L, 'aal2', 'ops_do', 'listing_photos_reframe', '{"intake": "%s"}')$$, test.id('sfp_fin'), (select i from s60i)), 'edits listing photos');
select test.eq('an Admin frames the listing''s outside photos again: the one outside photo is queued',
  (select app.door(test.id('sfp_admin'), 'aal2', 'ops_do', 'listing_photos_reframe', jsonb_build_object('intake', (select i from s60i), 'preset', 'studio_v4')) ->> 'queued'), '1');
select test.ok('off the site, its plate to check again, its old suggestion gone',
  (select not is_public and background_status = 'pending' and plate_status = 'unchecked' and plate_suggestion is null from vehicle_photos where id = (select outside from s60p)));
select test.ok('the inside photo is left alone', (select is_public from vehicle_photos where id = (select inside from s60p)));
select test.eq('asked again while it is queued: nothing more',
  (select app.door(test.id('sfp_admin'), 'aal2', 'ops_do', 'listing_photos_reframe', jsonb_build_object('intake', (select i from s60i), 'preset', 'studio_v4')) ->> 'queued'), '0');

-- the review sends the photo as it was to the vision model meanwhile: the answer is not kept
select test.eq('no suggestion kept while the photo is being made',
  (select app.photo_plate_suggestion(test.id('sfp_admin'), jsonb_build_object('photo', (select outside from s60p), 'suggestion', jsonb_build_object('answer', '{}'::jsonb))) ->> 'stored'), 'false');
select test.ok('still none', (select plate_suggestion is null from vehicle_photos where id = (select outside from s60p)));

-- the new photo lands: framed studio_v4; a suggestion stored by then (any way) is dropped
create temp table s60c as select j.id from app.claim_listing_jobs('sfp-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select outside from s60p);
update vehicle_photos set plate_suggestion = '{"answer": {}}'::jsonb where id = (select outside from s60p);
select app.worker_listing_result((select id from s60c), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/sfp/fl.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_v4')));
select test.ok('the new photo drops the suggestion made on the old one', (select plate_suggestion is null and preset_version = 'studio_v4' from vehicle_photos where id = (select outside from s60p)));
select test.eq('a suggestion asked now is kept',
  (select app.photo_plate_suggestion(test.id('sfp_admin'), jsonb_build_object('photo', (select outside from s60p), 'suggestion', jsonb_build_object('answer', '{}'::jsonb))) ->> 'stored'), 'true');
select test.eq('framed with studio_v4 already: nothing to do', (select app.listing_photos_reframe(test.id('sfp_admin'), jsonb_build_object('vehicle', test.id('vehicle:sfp_car'), 'preset', 'studio_v4')) ->> 'queued'), '0');  -- 0700: the default is studio_v5 since
select test.ok('the service role only', not has_function_privilege('authenticated', 'app.listing_photos_reframe(uuid, jsonb)', 'execute')
  and has_function_privilege('service_role', 'app.listing_photos_reframe(uuid, jsonb)', 'execute'));
