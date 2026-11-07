-- 99: migration 0700 (release 33, part D): any number of extra photos ordered after the standard shots and put in order by
-- staff; the capture counts what the database counts; the cut-out editor's mask and edit jobs, the version before kept,
-- the plate check carried over only when the car did not move; reframe with studio_v5. Fixtures start with "rlp"; every
-- address is example.test.
select test.suite('99 r33 listing photos (0700)');

create temp table rlp_prev as select listing_plate_check_required as v from app.settings();
update program_settings set listing_plate_check_required = true where id = (select id from app.settings());

select test.mk_user('rlp_admin', 'admin');
select test.mk_user('rlp_renter', 'renter');
select test.mk_owner('rlp_olive');
select test.mk_vehicle('rlp_car', 'rlp_olive');
create temp table rlpi as select (app.start_listing_intake(test.id('rlp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rlp_car'))) ->> 'intake_id')::uuid as i;
create or replace function test.rlp_up(p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rlp_admin'), (select i from rlpi), jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rlp/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000,
          'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;

-- ---------------------------------------------------------------- 2. any number of extras, after the standard shots
create temp table rlpx as select test.rlp_up('rear') as std;
do $$ begin for k in 1..35 loop perform test.rlp_up(case when k % 2 = 0 then 'exterior_more' else 'other' end); end loop; end $$;
select test.eq('more than the old 30 extras are taken', (select count(*)::text from vehicle_photos where vehicle_id = test.id('vehicle:rlp_car') and shot_type in ('other', 'exterior_more')), '35');
select test.ok('every extra after every standard shot', (select min(sort_order) from vehicle_photos where vehicle_id = test.id('vehicle:rlp_car') and shot_type in ('other', 'exterior_more'))
  > (select max(sort_order) from vehicle_photos where vehicle_id = test.id('vehicle:rlp_car') and shot_type not in ('other', 'exterior_more')));
select test.eq('the extras in the order taken, no two at one place', (select count(distinct sort_order)::text from vehicle_photos where vehicle_id = test.id('vehicle:rlp_car') and shot_type in ('other', 'exterior_more')), '35');
select test.eq('the capture counts what the database counts (36 public photos)',
  (select app.listing_capture(test.id('rlp_admin'), (select i from rlpi)) ->> 'counted'), '36');
update vehicle_photos set quality_flags = '["watermark"]'::jsonb where id = (select id from vehicle_photos where vehicle_id = test.id('vehicle:rlp_car') and shot_type = 'other' order by sort_order limit 1);
select test.eq('a photo with a mark on it does not count', (select app.listing_capture(test.id('rlp_admin'), (select i from rlpi)) ->> 'counted'), '35');

-- staff put two extras first
create temp table rlpo as select array_agg(id order by sort_order desc) as ids from (select id, sort_order from vehicle_photos
  where vehicle_id = test.id('vehicle:rlp_car') and shot_type in ('other', 'exterior_more') order by sort_order desc limit 2) q;
select app.listing_photos_order(test.id('rlp_admin'), jsonb_build_object('vehicle', test.id('vehicle:rlp_car'), 'order', to_jsonb((select ids from rlpo))));
select test.eq('the last extra is now the first', (select id::text from vehicle_photos where vehicle_id = test.id('vehicle:rlp_car') and shot_type in ('other', 'exterior_more') order by sort_order limit 1),
  (select ids[1]::text from rlpo));
select test.eq('the others keep their order after them, every place distinct',
  (select count(distinct sort_order)::text from vehicle_photos where vehicle_id = test.id('vehicle:rlp_car') and shot_type in ('other', 'exterior_more')), '35');
select test.throws('a standard shot is not put in order with the extras',
  format('select app.listing_photos_order(%L, jsonb_build_object(''vehicle'', %L::uuid, ''order'', jsonb_build_array(%L)))', test.id('rlp_admin'), test.id('vehicle:rlp_car'), (select std from rlpx)), 'Only this car');
select test.throws('a renter cannot order photos',
  format('select app.listing_photos_order(%L, jsonb_build_object(''vehicle'', %L::uuid, ''order'', ''[]''::jsonb))', test.id('rlp_renter'), test.id('vehicle:rlp_car')), 'Fleet, customer service');

-- ---------------------------------------------------------------- 1. the worker is told the cover; reframe catches studio_v4
update listing_jobs set status = 'succeeded', finished_at = now() where intake_id = (select i from rlpi) and kind = 'process_photo';
insert into vehicle_listings (vehicle_id, status, slug) values (test.id('vehicle:rlp_car'), 'published', 'rlp-car-example')
  on conflict (vehicle_id) do update set status = 'published', slug = coalesce(vehicle_listings.slug, excluded.slug);
update vehicle_photos set preset_version = 'studio_v4', background_status = 'done', status = 'approved', is_public = true, is_cover = true,
       processed_path = 'vehicles/rlp/rear.jpg', plate_status = 'not_visible',
       cutout = '{"auto_mask": "vehicles/rlp/work/m.png", "place": {"width": 1500, "height": 600, "left": 150, "bottom": 250}}'::jsonb
 where id = (select std from rlpx);
select test.ok('on the site before the edit', (select is_public from vehicle_photos where id = (select std from rlpx)));

-- ---------------------------------------------------------------- 3. the cut-out editor
select test.eq('the editor reads the photo with its mask',
  (select app.photo_cutout_context(test.id('rlp_admin'), jsonb_build_object('photo', (select std from rlpx))) ->> 'auto_mask'), 'vehicles/rlp/work/m.png');
select test.throws('an edited cut-out must be the photo''s own work file',
  format('select app.photo_cutout_edit(%L, jsonb_build_object(''photo'', %L::uuid, ''cutout_path'', ''vehicles/other/x.png''))', test.id('rlp_admin'), (select std from rlpx)), 'edited cut-out is missing');
create temp table rlpe as select format('vehicles/%s/work/%s-edit-abc123.png', test.id('vehicle:rlp_car'), (select std from rlpx)) as path;
select test.eq('saved: queued as version 1',
  (select app.photo_cutout_edit(test.id('rlp_admin'), jsonb_build_object('photo', (select std from rlpx), 'cutout_path', (select path from rlpe), 'adjust', jsonb_build_object('dx', 0, 'dy', 0, 'scale', 1))) ->> 'version'), '1');
select test.eq('the version before is kept', (select processed_path from vehicle_photo_versions where photo_id = (select std from rlpx) and version = 0), 'vehicles/rlp/rear.jpg');
select test.ok('the photo stays on the site while it is made', (select is_public and status = 'approved' from vehicle_photos where id = (select std from rlpx)));
select test.throws('one edit at a time',
  format('select app.photo_cutout_edit(%L, jsonb_build_object(''photo'', %L::uuid, ''cutout_path'', %L))', test.id('rlp_admin'), (select std from rlpx), (select path from rlpe)), 'being made now');
select test.ok('the job context names the cover and a new file name',
  (select (app.listing_job_context(j.id) -> 'photo' ->> 'is_cover')::boolean and (app.listing_job_context(j.id) -> 'photo' ->> 'file_base') like '%-v1'
     from listing_jobs j where j.vehicle_photo_id = (select std from rlpx) and j.kind = 'process_photo' and j.status = 'queued'));
-- the car did not move: no plate visible carries over, the photo is back on the site at once
create temp table rlpc as select j.id from app.claim_listing_jobs('rlp-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select std from rlpx);
select app.worker_listing_result((select id from rlpc), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rlp/rear-v1.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_v5', 'edited', true,
  'place', jsonb_build_object('width', 1505, 'height', 602, 'left', 148, 'bottom', 250))));
select test.ok('not moved: no plate visible carried over, approved and on the site',
  (select plate_status = 'not_visible' and status = 'approved' and is_public and processed_path = 'vehicles/rlp/rear-v1.jpg' and cutout ->> 'mask' = (select path from rlpe)
     from vehicle_photos where id = (select std from rlpx)));
-- a covered plate, then an edit that moves the car: asked again, off the site until checked, then back on (0661)
update vehicle_photos set plate_status = 'covered', plate_boxes = '[{"x":0.4,"y":0.6,"w":0.2,"h":0.08}]'::jsonb, plate_style = 'cover' where id = (select std from rlpx);
select app.photo_cutout_edit(test.id('rlp_admin'), jsonb_build_object('photo', (select std from rlpx), 'cutout_path', (select path from rlpe), 'adjust', jsonb_build_object('dx', 0.2)));
create temp table rlpc2 as select j.id from app.claim_listing_jobs('rlp-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select std from rlpx);
select app.worker_listing_result((select id from rlpc2), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rlp/rear-v2.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_v5', 'edited', true,
  'place', jsonb_build_object('width', 1505, 'height', 602, 'left', 508, 'bottom', 250))));
select test.ok('moved: the plate is asked again, nothing carried, off the site',
  (select plate_status = 'unchecked' and plate_carry is null and not is_public and plate_boxes = '[]'::jsonb from vehicle_photos where id = (select std from rlpx)));
update vehicle_photos set plate_status = 'covered', plate_boxes = '[{"x":0.5,"y":0.6,"w":0.2,"h":0.08}]'::jsonb where id = (select std from rlpx);
select test.ok('checked again: back on the site by itself (0661)', (select is_public and status = 'approved' from vehicle_photos where id = (select std from rlpx)));
-- not moved with a covered plate: the cover is carried for the review to put back on
select app.photo_cutout_edit(test.id('rlp_admin'), jsonb_build_object('photo', (select std from rlpx), 'cutout_path', (select path from rlpe)));
create temp table rlpc3 as select j.id from app.claim_listing_jobs('rlp-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select std from rlpx);
select app.worker_listing_result((select id from rlpc3), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rlp/rear-v3.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_v5', 'edited', true,
  'place', jsonb_build_object('width', 1505, 'height', 602, 'left', 508, 'bottom', 250))));
select test.ok('not moved, plate covered: the cover is carried, the new file waits for it off the site',
  (select plate_status = 'unchecked' and plate_carry -> 'boxes' -> 0 ->> 'x' = '0.5' and not is_public from vehicle_photos where id = (select std from rlpx)));
select test.eq('three versions kept', (select count(*)::text from vehicle_photo_versions where photo_id = (select std from rlpx)), '3');
-- an edit that fails for good leaves the photo as it was
update vehicle_photos set plate_status = 'not_visible' where id = (select std from rlpx);
select app.photo_cutout_edit(test.id('rlp_admin'), jsonb_build_object('photo', (select std from rlpx), 'cutout_path', (select path from rlpe)));
update listing_jobs set attempts = max_attempts - 1 where vehicle_photo_id = (select std from rlpx) and status = 'queued';
create temp table rlpc4 as select j.id from app.claim_listing_jobs('rlp-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select std from rlpx);
select app.worker_listing_result((select id from rlpc4), jsonb_build_object('ok', false, 'provider', 'fake', 'error', 'gone', 'retryable', false));
select test.ok('a failed edit: the photo keeps its file and status',
  (select status = 'approved' and processed_path = 'vehicles/rlp/rear-v3.jpg' and background_status <> 'failed' from vehicle_photos where id = (select std from rlpx)));

-- a mask for a photo made before masks were kept: the photo itself is not touched
create temp table rlpm as select id from vehicle_photos where vehicle_id = test.id('vehicle:rlp_car') and shot_type = 'exterior_more' order by sort_order limit 1;
update vehicle_photos set status = 'approved', processed_path = 'vehicles/rlp/x.jpg', background_status = 'done', cutout = null where id = (select id from rlpm);
select test.eq('a mask is asked for', (select app.photo_cutout_mask(test.id('rlp_admin'), jsonb_build_object('photo', (select id from rlpm))) ->> 'queued'), 'true');
create temp table rlpc5 as select j.id from app.claim_listing_jobs('rlp-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select id from rlpm);
select app.worker_listing_result((select id from rlpc5), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object('mask_only', true, 'mask_path', 'vehicles/rlp/work/x-mask.png')));
select test.ok('the mask is stored; the photo kept its file and status',
  (select cutout ->> 'auto_mask' = 'vehicles/rlp/work/x-mask.png' and processed_path = 'vehicles/rlp/x.jpg' and status = 'approved' from vehicle_photos where id = (select id from rlpm)));
select test.eq('the mask job succeeded', (select status from listing_jobs where id = (select id from rlpc5)), 'succeeded');

-- reframe: studio_v4 photos are made again for the lettering; an edited one from its edit
update vehicle_photos set preset_version = 'studio_v4' where id = (select std from rlpx);
select test.ok('reframed with studio_v5', (select (app.listing_photos_reframe(test.id('rlp_admin'), jsonb_build_object('vehicle', test.id('vehicle:rlp_car'))) ->> 'queued')::int >= 1));
select test.eq('an edited photo is made again from its edit',
  (select j.input -> 'edit' ->> 'cutout_path' from listing_jobs j where j.vehicle_photo_id = (select std from rlpx) and j.kind = 'process_photo' and j.status = 'queued'), (select path from rlpe));
select test.ok('the door answers the new calls', (select app.door(test.id('rlp_admin'), 'aal2', 'ops_read', 'photo_cutout_context', jsonb_build_object('photo', (select std from rlpx))) ? 'edit_version'));

update program_settings set listing_plate_check_required = (select v from rlp_prev) where id = (select id from app.settings());
