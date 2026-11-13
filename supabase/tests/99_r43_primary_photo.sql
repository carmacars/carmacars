-- 99: migration 2690 (release 43): the first photo of every car is its exterior front three-quarter. The rank, the order of
-- the site's photo list and of the car's cover, is_cover following the rule by itself, the flag "primary photo is not
-- exterior" in Admin > Cars, and "Redo photos with Gemini" (photo_showroom action gemini: the job carries engine gemini).
-- Fixtures start with "rq43p_"; every address is example.test.
select test.suite('99 r43 primary photo (2690)');

create temp table rq43p_prev as select listing_plate_check_required as plate, listing_showroom_ai as ai from app.settings();
update program_settings set listing_plate_check_required = true, listing_showroom_ai = true where id = (select id from app.settings());

select test.mk_user('rq43p_admin', 'admin');
select test.mk_user('rq43p_cs', 'va', 'cs');
select test.mk_user('rq43p_renter', 'renter');
select test.mk_owner('rq43p_olive');
select test.mk_vehicle('rq43p_a', 'rq43p_olive');   -- inside photo first and marked cover, the standard angle last
select test.mk_vehicle('rq43p_b', 'rq43p_olive');   -- no standard angle: the best other outside photo
select test.mk_vehicle('rq43p_c', 'rq43p_olive');   -- inside photos only
select test.mk_vehicle('rq43p_d', 'rq43p_olive');   -- the standard angle is not on the site yet
select test.mk_vehicle('rq43p_g', 'rq43p_olive');   -- Redo with Gemini

-- ---------------------------------------------------------------- 1. the rank
select test.eq('the standard angle first, the outside shots next, anything inside after them, a made cover before all',
  (select string_agg(app.photo_rank(s)::text, ',') from unnest(array['front_left', 'front_right', 'front', 'rear_left', 'rear_right', 'left', 'right', 'rear', 'exterior_more',
     'dashboard', 'front_seats', 'rear_seats', 'trunk', 'wheel', 'other', 'odometer', 'cover_flyer', 'cover_model']) s),
  '0,1,2,3,4,5,6,7,8,20,20,20,20,20,20,20,-1,-1');
select test.eq('an unknown or empty shot is not an outside one', (select app.photo_rank(null) + app.photo_rank('nothing')), 40);

create or replace function test.rq43p_photo(p_car text, p_shot text, p_sort integer, p_cover boolean default false, p_live boolean default true) returns uuid language sql as $$
  insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, plate_status, sort_order, is_cover, width, height, background_status)
  values (test.id('vehicle:' || p_car), case when p_shot in ('dashboard', 'front_seats') then p_shot else p_shot end, p_shot, 'vehicles/original/rq43p/' || p_car || '-' || p_shot || '.jpg',
          'vehicles/rq43p/' || p_car || '-' || p_shot || '.jpg', case when p_live then 'approved' else 'processed' end, p_live, 'not_visible', p_sort, p_cover, 1800, 1200, 'done')
  returning id $$;
create or replace function test.rq43p_shots(p_car text) returns text language sql stable as $$
  select string_agg(e ->> 'shot', ',' order by k) from jsonb_array_elements(app.public_listing_photos(test.id('vehicle:' || p_car))) with ordinality t(e, k) $$;
create or replace function test.rq43p_covers(p_car text) returns text language sql stable as $$
  select coalesce(string_agg(shot_type, ',' order by shot_type), '') from vehicle_photos where vehicle_id = test.id('vehicle:' || p_car) and is_cover $$;
insert into vehicle_listings (vehicle_id, status, slug) select test.id('vehicle:rq43p_' || c), 'published', 'rq43p-' || c || '-example' from unnest(array['a', 'b', 'c', 'd']) c
  on conflict (vehicle_id) do update set status = 'published', slug = coalesce(vehicle_listings.slug, excluded.slug);

-- ---------------------------------------------------------------- 2. an inside photo marked cover and first is not first any more
select test.rq43p_photo('rq43p_a', 'dashboard', 0, true);
select test.rq43p_photo('rq43p_a', 'front_seats', 1);
select test.rq43p_photo('rq43p_a', 'rear', 2);
create temp table rq43p_afl as select test.rq43p_photo('rq43p_a', 'front_left', 3) as id;
select test.eq('the site lists the standard angle first, the other outside shots, then the inside',
  test.rq43p_shots('rq43p_a'), 'front_left,rear,dashboard,front_seats');
select test.eq('the cover mark moved to the standard angle (the only one)', test.rq43p_covers('rq43p_a'), 'front_left');
select test.eq('the car''s cover photo is the standard angle', (select shot_type from app.cover_photo(test.id('vehicle:rq43p_a'))), 'front_left');
select test.eq('the card and the car page row show the standard angle as the cover', (app.public_listing_row(test.id('vehicle:rq43p_a')) #>> '{cover,path}'), 'vehicles/rq43p/rq43p_a-front_left.jpg');
select test.eq('the cards'' photo (the fleet list) is the standard angle', (app.row_car_photos(array[test.id('vehicle:rq43p_a')]) -> test.id('vehicle:rq43p_a')::text ->> 'path'), 'vehicles/rq43p/rq43p_a-front_left.jpg');
select test.eq('state: exterior', app.vehicle_primary_state(test.id('vehicle:rq43p_a')), 'exterior');
-- staff mark an inside photo cover by hand: the rule puts it back
update vehicle_photos set is_cover = true where vehicle_id = test.id('vehicle:rq43p_a') and shot_type = 'front_seats';
select test.eq('an inside photo marked cover by hand does not stay cover', test.rq43p_covers('rq43p_a'), 'front_left');
update vehicle_photos set sort_order = -5 where vehicle_id = test.id('vehicle:rq43p_a') and shot_type = 'front_seats';
select test.eq('nor first by its order', test.rq43p_shots('rq43p_a'), 'front_left,rear,front_seats,dashboard');
-- the standard angle is replaced: the next best outside photo is first and cover; back when the new one arrives
update vehicle_photos set replaced_at = now() where id = (select id from rq43p_afl);
select test.eq('the standard angle replaced: the rear is first and cover', test.rq43p_shots('rq43p_a') || '/' || test.rq43p_covers('rq43p_a'), 'rear,front_seats,dashboard/rear');
insert into rq43p_afl select test.rq43p_photo('rq43p_a', 'front_left', 9);
select test.eq('the new standard angle is first and cover again', test.rq43p_shots('rq43p_a') || '/' || test.rq43p_covers('rq43p_a'), 'front_left,rear,front_seats,dashboard/front_left');

-- ---------------------------------------------------------------- 3. no standard angle: the best other outside photo
select test.rq43p_photo('rq43p_b', 'dashboard', 0, true);
select test.rq43p_photo('rq43p_b', 'rear', 1);
select test.rq43p_photo('rq43p_b', 'left', 2);
select test.eq('left (5) comes before rear (7), the inside after', test.rq43p_shots('rq43p_b'), 'left,rear,dashboard');
select test.eq('and is the cover', test.rq43p_covers('rq43p_b'), 'left');
select test.eq('state: exterior', app.vehicle_primary_state(test.id('vehicle:rq43p_b')), 'exterior');

-- ---------------------------------------------------------------- 4. inside photos only: kept as they are, and flagged
select test.rq43p_photo('rq43p_c', 'dashboard', 1);
select test.rq43p_photo('rq43p_c', 'front_seats', 0, true);
select test.eq('with no outside photo the order of the car stays', test.rq43p_shots('rq43p_c'), 'front_seats,dashboard');
select test.eq('its cover mark is left alone', test.rq43p_covers('rq43p_c'), 'front_seats');
select test.eq('state: not_exterior', app.vehicle_primary_state(test.id('vehicle:rq43p_c')), 'not_exterior');
select test.eq('a car with no photo: none', app.vehicle_primary_state(test.id('vehicle:rq43p_g')), 'none');
select test.ok('Admin > Cars carries the flag for the car with inside photos only, and not for the others',
  (select bool_and(coalesce((e ->> 'primary_not_exterior')::boolean, false) = (e ->> 'id' = test.id('vehicle:rq43p_c')::text))
     from jsonb_array_elements(app.admin_read(test.id('rq43p_admin'), 'vehicles')) e where e ->> 'id' in (select test.id('vehicle:rq43p_' || c)::text from unnest(array['a', 'b', 'c', 'g']) c)));
select test.ok('every row of the list carries the state', (select bool_and(e ? 'primary_photo' and e ? 'primary_not_exterior') from jsonb_array_elements(app.admin_read(test.id('rq43p_admin'), 'vehicles')) e));
select test.ok('the rows keep the fields the page reads (seats_missing, name)', (select bool_and(e ? 'seats_missing' and e ? 'name') from jsonb_array_elements(app.admin_read(test.id('rq43p_admin'), 'vehicles')) e));

-- ---------------------------------------------------------------- 5. the standard angle is not on the site yet: the inside photo shows, flagged
select test.rq43p_photo('rq43p_d', 'dashboard', 0, true);
create temp table rq43p_dfl as select test.rq43p_photo('rq43p_d', 'front_left', 1, false, false) as id;
select test.eq('the standard angle not on the site yet: the site shows the inside photo (nothing else to show)', test.rq43p_shots('rq43p_d'), 'dashboard');
select test.eq('state: not_exterior (staff see it)', app.vehicle_primary_state(test.id('vehicle:rq43p_d')), 'not_exterior');
select test.eq('the cover mark is on the standard angle already (its model name is lettered when it is made)', test.rq43p_covers('rq43p_d'), 'front_left');
update vehicle_photos set status = 'approved', is_public = true where id = (select id from rq43p_dfl);
select test.eq('approved and on the site: it is first', test.rq43p_shots('rq43p_d'), 'front_left,dashboard');
select test.eq('state: exterior', app.vehicle_primary_state(test.id('vehicle:rq43p_d')), 'exterior');
select test.eq('the car page row shows it as the cover', app.public_listing_row(test.id('vehicle:rq43p_d')) #>> '{cover,path}', 'vehicles/rq43p/rq43p_d-front_left.jpg');

-- ---------------------------------------------------------------- 6. nothing for the public to call
select test.ok('the new functions are not executable by anon or authenticated',
  not has_function_privilege('anon', 'app.photo_rank(text)', 'execute') and not has_function_privilege('authenticated', 'app.primary_photo(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'app.vehicle_primary_state(uuid)', 'execute') and not has_function_privilege('anon', 'app.vehicle_photos_primary_sync()', 'execute')
  and not has_function_privilege('public', 'app.vehicle_photos_primary_sync()', 'execute') and has_function_privilege('service_role', 'app.vehicle_primary_state(uuid)', 'execute'));
select test.ok('admin_read keeps its grants (service_role only)', has_function_privilege('service_role', 'app.admin_read(uuid, text, jsonb)', 'execute') and not has_function_privilege('authenticated', 'app.admin_read(uuid, text, jsonb)', 'execute'));

-- ---------------------------------------------------------------- 7. Redo photos with Gemini
create temp table rq43p_i as select (app.start_listing_intake(test.id('rq43p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rq43p_g'))) ->> 'intake_id')::uuid as i;
create or replace function test.rq43p_up(p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rq43p_admin'), (select i from rq43p_i), jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rq43p/g-' || p_shot || '.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create temp table rq43p_gp as select test.rq43p_up('front_left') as fl, test.rq43p_up('rear') as rear, test.rq43p_up('dashboard') as dash;
update vehicle_photos set scene = 'showroom', background_status = 'done', status = 'approved', is_public = true, plate_status = 'not_visible',
       processed_path = 'vehicles/rq43p/g-' || shot_type || '.jpg', preset_version = 'studio_showroom_v2',
       cutout = jsonb_build_object('auto_mask', 'vehicles/rq43p/work/g-' || shot_type || '-mask.png')
 where vehicle_id = test.id('vehicle:rq43p_g');
update listing_jobs set status = 'succeeded', finished_at = now() where intake_id = (select i from rq43p_i) and status in ('queued', 'running');

select test.throws('a renter cannot', format('select app.photo_showroom(%L, jsonb_build_object(''action'', ''gemini'', ''vehicle'', %L::uuid))', test.id('rq43p_renter'), test.id('vehicle:rq43p_g')), 'Fleet, customer service');
update program_settings set listing_showroom_ai = false where id = (select id from app.settings());
select test.throws('Gemini switched off: refused at once, nothing queued', format('select app.photo_showroom(%L, jsonb_build_object(''action'', ''gemini'', ''vehicle'', %L::uuid))', test.id('rq43p_admin'), test.id('vehicle:rq43p_g')), 'Gemini is switched off');
select test.eq('nothing was queued', (select count(*)::text from listing_jobs where intake_id = (select i from rq43p_i) and status = 'queued'), '0');
update program_settings set listing_showroom_ai = true where id = (select id from app.settings());

select test.eq('Redo with Gemini: both outside photos of the car are queued, the dashboard is not',
  (select app.photo_showroom(test.id('rq43p_cs'), jsonb_build_object('action', 'gemini', 'vehicle', test.id('vehicle:rq43p_g'))) ->> 'queued'), '2');
select test.ok('each job carries engine gemini and is made from the kept cut-out',
  (select count(*) = 2 and bool_and(j.input ->> 'engine' = 'gemini') and bool_and(j.input -> 'edit' ->> 'cutout_path' like 'vehicles/rq43p/work/g-%-mask.png')
     from listing_jobs j where j.intake_id = (select i from rq43p_i) and j.kind = 'process_photo' and j.status = 'queued'));
select test.eq('the dashboard has no job', (select count(*)::text from listing_jobs where vehicle_photo_id = (select dash from rq43p_gp) and status = 'queued'), '0');
select test.ok('the job context still tells the worker the showroom scene and the new file',
  (select app.listing_job_context(j.id) -> 'photo' ->> 'scene' = 'showroom' and app.listing_job_context(j.id) ->> 'kind' = 'process_photo' and (app.listing_job_context(j.id) -> 'input' ->> 'engine') = 'gemini'
     from listing_jobs j where j.vehicle_photo_id = (select fl from rq43p_gp) and j.kind = 'process_photo' and j.status = 'queued'));
select test.ok('the version before is kept and the originals are untouched',
  (select v.processed_path = 'vehicles/rq43p/g-front_left.jpg' and ph.original_path = 'vehicles/original/rq43p/g-front_left.jpg' and ph.processed_path = 'vehicles/rq43p/g-front_left.jpg'
     from vehicle_photos ph join vehicle_photo_versions v on v.photo_id = ph.id and v.reason = 'showroom_redo' where ph.id = (select fl from rq43p_gp)));
select test.eq('the photo stays on the site while it is made (the old file, not an original)',
  (select is_public::text || '/' || processed_path from vehicle_photos where id = (select fl from rq43p_gp)), 'true/vehicles/rq43p/g-front_left.jpg');
select test.eq('asked again while they are being made: nothing more is queued',
  (select app.photo_showroom(test.id('rq43p_admin'), jsonb_build_object('action', 'gemini', 'vehicle', test.id('vehicle:rq43p_g'))) ->> 'queued'), '0');
-- the plain Redo of one photo does not force Gemini
update listing_jobs set status = 'succeeded', finished_at = now() where intake_id = (select i from rq43p_i) and status in ('queued', 'running');
select app.photo_showroom(test.id('rq43p_admin'), jsonb_build_object('action', 'redo', 'photo', (select rear from rq43p_gp)));
select test.ok('Redo (the free showroom first, the image model on top) has no engine', (select not (j.input ? 'engine') from listing_jobs j where j.vehicle_photo_id = (select rear from rq43p_gp) and j.status = 'queued' and j.kind = 'process_photo'));
update listing_jobs set status = 'succeeded', finished_at = now() where intake_id = (select i from rq43p_i) and status in ('queued', 'running');
select test.eq('Gemini on one photo', (select app.photo_showroom(test.id('rq43p_admin'), jsonb_build_object('action', 'gemini', 'photo', (select rear from rq43p_gp))) ->> 'queued'), '1');
select test.throws('an unknown action is still refused', format('select app.photo_showroom(%L, jsonb_build_object(''action'', ''cloudflare'', ''vehicle'', %L::uuid))', test.id('rq43p_admin'), test.id('vehicle:rq43p_g')), 'Unknown showroom action');

update program_settings set listing_plate_check_required = (select plate from rq43p_prev), listing_showroom_ai = (select ai from rq43p_prev) where id = (select id from app.settings());
