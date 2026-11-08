-- 99: migration 0661: an outside photo of a published listing made again by "Frame the outside photos again" goes back
-- on the site by itself once its plate is checked; a photo nobody approved and nobody asked to frame again does not.
-- Fixtures start with "rbs"; every address is example.test.
select test.suite('99 reframed photos back on the site (0661)');

-- the plate check before publishing on (Program settings; on in production)
create temp table rbs_prev as select listing_plate_check_required as v from app.settings();
update program_settings set listing_plate_check_required = true where id = (select id from app.settings());

select test.mk_user('rbs_admin', 'admin');
select test.mk_owner('rbs_olive');
select test.mk_vehicle('rbs_car', 'rbs_olive');
create temp table rbsi as select (app.start_listing_intake(test.id('rbs_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rbs_car'))) ->> 'intake_id')::uuid as i;
create or replace function test.rbs_up(p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rbs_admin'), (select i from rbsi), jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rbs/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000,
          'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create temp table rbsp as select test.rbs_up('rear') as old_one, test.rbs_up('front') as never_approved;
update listing_jobs set status = 'succeeded', finished_at = now() - interval '1 hour' where intake_id = (select i from rbsi) and kind = 'process_photo';
-- the car is on the site; the rear photo approved and public with its plate covered, framed the old way
insert into vehicle_listings (vehicle_id, status, slug) values (test.id('vehicle:rbs_car'), 'published', 'rbs-car-example')
  on conflict (vehicle_id) do update set status = 'published', slug = coalesce(vehicle_listings.slug, excluded.slug);
update vehicle_photos set preset_version = 'studio_v3', background_status = 'done', status = 'approved', is_public = true,
       processed_path = 'vehicles/rbs/rear.jpg', plate_status = 'covered'
 where id = (select old_one from rbsp);
update vehicle_photos set preset_version = 'studio_v4', background_status = 'done', status = 'processed', is_public = false,
       processed_path = 'vehicles/rbs/front.jpg', plate_status = 'unchecked'
 where id = (select never_approved from rbsp);

select test.eq('framed again: the rear photo is queued',
  (select app.listing_photos_reframe(test.id('rbs_admin'), jsonb_build_object('intake', (select i from rbsi), 'preset', 'studio_v4')) ->> 'queued'), '1');  -- 0700: the default is studio_v5 since
select test.ok('marked as made again, off the site meanwhile',
  (select reframed_at is not null and not is_public from vehicle_photos where id = (select old_one from rbsp)));

-- the new photo lands (processed, not approved), then a person covers its plate
create temp table rbsc as select j.id from app.claim_listing_jobs('rbs-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select old_one from rbsp);
select app.worker_listing_result((select id from rbsc), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rbs/rear.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_v4')));
select test.ok('still off the site before the plate check', (select not is_public from vehicle_photos where id = (select old_one from rbsp)));
update vehicle_photos set plate_status = 'covered', plate_boxes = '[{"x":0.4,"y":0.6,"w":0.2,"h":0.08}]'::jsonb where id = (select old_one from rbsp);
select test.ok('plate covered: approved and back on the site',
  (select status = 'approved' and is_public from vehicle_photos where id = (select old_one from rbsp)));

-- a photo nobody approved and nobody asked to frame again keeps waiting for the review
update vehicle_photos set plate_status = 'not_visible' where id = (select never_approved from rbsp);
select test.ok('a photo never approved stays off the site after its plate check',
  (select status = 'processed' and not is_public from vehicle_photos where id = (select never_approved from rbsp)));

update program_settings set listing_plate_check_required = (select v from rbs_prev) where id = (select id from app.settings());
