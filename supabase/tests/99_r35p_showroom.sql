-- 99: migration 0990 (release 35, part P): the showroom scene of the listing photos. The settings (on by default), a new
-- photo takes its car's scene, the job context names it, the result keeps how it was made; apply, redo and undo with the
-- version before kept; every car at once (Admin, fleet); the image model's gate (off, the daily limit, a quota answer) and
-- its record. Fixtures start with "rsp"; every address is example.test.
select test.suite('99 r35p showroom (0990)');

create temp table rsp_prev as select listing_plate_check_required as plate, listing_showroom as sr, listing_showroom_ai as ai, listing_showroom_ai_daily as daily from app.settings();
update program_settings set listing_plate_check_required = true, listing_showroom = true, listing_showroom_ai = true where id = (select id from app.settings());

select test.mk_user('rsp_admin', 'admin');
select test.mk_user('rsp_cs', 'va', 'cs');
select test.mk_user('rsp_fleet', 'va', 'fleet');
select test.mk_user('rsp_renter', 'renter');
select test.mk_owner('rsp_olive');
select test.mk_vehicle('rsp_car', 'rsp_olive');
select test.mk_vehicle('rsp_old', 'rsp_olive');

-- ---------------------------------------------------------------- settings
select test.ok('showroom on by default, the image model on, a sensible model and daily limit',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_showroom') = 'true'
  and (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_showroom_ai') = 'true'
  and (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_showroom_ai_model') like '%gemini-2.5-flash-image%'
  and (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'listing_showroom_ai_daily') = '25');
select test.throws('the model name is checked', $$update program_settings set listing_showroom_ai_model = 'bad name; drop' where id = (select id from app.settings())$$, 'check');

-- ---------------------------------------------------------------- a new photo takes the scene
create temp table rspi as select (app.start_listing_intake(test.id('rsp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rsp_car'))) ->> 'intake_id')::uuid as i;
create temp table rspi2 as select (app.start_listing_intake(test.id('rsp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rsp_old'))) ->> 'intake_id')::uuid as i;
create or replace function test.rsp_up(p_intake uuid, p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rsp_admin'), p_intake, jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rsp/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000,
          'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create temp table rspp as select test.rsp_up((select i from rspi), 'front_left') as cover, test.rsp_up((select i from rspi), 'rear') as rear;
select test.eq('a car with no photo yet: the showroom (Program settings)', (select scene from vehicle_photos where id = (select cover from rspp)), 'showroom');
select test.eq('the next photo of the car: the same room', (select scene from vehicle_photos where id = (select rear from rspp)), 'showroom');
-- a car whose photos were made before 0990 (scene empty: the black studio) keeps the studio for its new photos
create temp table rspo as select test.rsp_up((select i from rspi2), 'front_left') as a;
update vehicle_photos set scene = null where id = (select a from rspo);
insert into rspo select test.rsp_up((select i from rspi2), 'rear');
select test.eq('a car on the black studio: its new photo matches it', (select scene from vehicle_photos where vehicle_id = test.id('vehicle:rsp_old') and shot_type = 'rear'), 'studio');

-- ---------------------------------------------------------------- the job context and the result
-- the photos' jobs (queued when a listing is submitted; here directly)
select app.enqueue_listing_job((select i from rspi), 'process_photo', (select cover from rspp));
select app.enqueue_listing_job((select i from rspi2), 'process_photo', (select a from rspo limit 1));
select test.eq('the worker is told the scene',
  (select app.listing_job_context(j.id) -> 'photo' ->> 'scene' from listing_jobs j where j.vehicle_photo_id = (select cover from rspp) and j.kind = 'process_photo' limit 1), 'showroom');
select test.eq('a photo made before 0990 is the studio to the worker',
  (select app.listing_job_context(j.id) -> 'photo' ->> 'scene' from listing_jobs j where j.vehicle_photo_id = (select a from rspo limit 1) and j.kind = 'process_photo' limit 1), 'studio');
create temp table rspc as select j.id from app.claim_listing_jobs('rsp-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select cover from rspp);
select app.worker_listing_result((select id from rspc), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rsp/cover.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_showroom_v1', 'lettered', true,
  'mask_path', 'vehicles/rsp/work/cover-mask.png', 'place', jsonb_build_object('width', 1500, 'height', 600, 'left', 150, 'bottom', 250),
  'showroom', jsonb_build_object('provider', 'local', 'note', 'Made with the free showroom: the image model''s free use is used up for now. Redo it later.', 'reason', 'quota'))));
select test.ok('how it was made is kept for staff (the free showroom and why)',
  (select showroom ->> 'provider' = 'local' and showroom ->> 'reason' = 'quota' and showroom ->> 'note' like 'Made with the free showroom%' and preset_version = 'studio_showroom_v1'
     from vehicle_photos where id = (select cover from rspp)));

-- ---------------------------------------------------------------- apply, redo, undo
-- the old car: its photos approved on the black studio, on the site, plates checked
insert into vehicle_listings (vehicle_id, status, slug) values (test.id('vehicle:rsp_old'), 'published', 'rsp-old-example')
  on conflict (vehicle_id) do update set status = 'published', slug = coalesce(vehicle_listings.slug, excluded.slug);
update listing_jobs set status = 'succeeded', finished_at = now() where intake_id = (select i from rspi2) and kind = 'process_photo';
update vehicle_photos set scene = 'studio', preset_version = 'studio_v5', background_status = 'done', status = 'approved', is_public = true,
       processed_path = 'vehicles/rsp/old-' || shot_type || '.jpg', plate_status = 'not_visible',
       cutout = jsonb_build_object('auto_mask', 'vehicles/rsp/work/old-' || shot_type || '-mask.png', 'place', jsonb_build_object('width', 1500, 'height', 600, 'left', 150, 'bottom', 250))
 where vehicle_id = test.id('vehicle:rsp_old');
create temp table rspf as select id from vehicle_photos where vehicle_id = test.id('vehicle:rsp_old') and shot_type = 'front_left';
select test.throws('a renter cannot', format('select app.photo_showroom(%L, jsonb_build_object(''vehicle'', %L::uuid))', test.id('rsp_renter'), test.id('vehicle:rsp_old')), 'Fleet, customer service');
select test.eq('apply: every outside photo of the car is queued', (select app.photo_showroom(test.id('rsp_cs'), jsonb_build_object('action', 'apply', 'vehicle', test.id('vehicle:rsp_old'))) ->> 'queued'), '2');
select test.ok('the version before is kept (reason showroom), a new file name, the scene set, still on the site while made',
  (select v.processed_path = 'vehicles/rsp/old-front_left.jpg' and ph.edit_version = 1 and ph.scene = 'showroom' and ph.is_public
     from vehicle_photos ph join vehicle_photo_versions v on v.photo_id = ph.id and v.reason = 'showroom' where ph.id = (select id from rspf)));
select test.eq('made from the kept cut-out (no new background removal)',
  (select j.input -> 'edit' ->> 'cutout_path' from listing_jobs j where j.vehicle_photo_id = (select id from rspf) and j.kind = 'process_photo' and j.status = 'queued'), 'vehicles/rsp/work/old-front_left-mask.png');
select test.ok('the job names the showroom and the new file', (select app.listing_job_context(j.id) -> 'photo' ->> 'scene' = 'showroom' and app.listing_job_context(j.id) -> 'photo' ->> 'file_base' like '%-v1'
  from listing_jobs j where j.vehicle_photo_id = (select id from rspf) and j.kind = 'process_photo' and j.status = 'queued'));
select test.throws('one at a time', format('select app.photo_showroom(%L, jsonb_build_object(''action'', ''redo'', ''photo'', %L::uuid))', test.id('rsp_admin'), (select id from rspf)), 'being made now');
-- made where the car was: the plate check carries over (0700), back on the site
create temp table rspc2 as select j.id from app.claim_listing_jobs('rsp-w', 100, array['process_photo']) j where j.vehicle_photo_id = (select id from rspf);
select app.worker_listing_result((select id from rspc2), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rsp/old-front_left-v1.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_showroom_v1', 'edited', true,
  'place', jsonb_build_object('width', 1500, 'height', 600, 'left', 150, 'bottom', 250), 'showroom', jsonb_build_object('provider', 'local'))));
select test.ok('in the showroom, the plate check carried over, on the site',
  (select processed_path = 'vehicles/rsp/old-front_left-v1.jpg' and plate_status = 'not_visible' and is_public and status = 'approved' and showroom ->> 'provider' = 'local'
     from vehicle_photos where id = (select id from rspf)));
select app.listing_photos_reframe(test.id('rsp_admin'), jsonb_build_object('vehicle', test.id('vehicle:rsp_old')));
select test.eq('reframe leaves a showroom photo with the newest preset alone',
  (select count(*)::text from listing_jobs j where j.vehicle_photo_id = (select id from rspf) and j.kind = 'process_photo' and j.status = 'queued'), '0');
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_photo_id in (select id from vehicle_photos where vehicle_id = test.id('vehicle:rsp_old')) and status in ('queued', 'running');
-- redo: made again, the showroom version kept as showroom_redo
select test.eq('redo one photo', (select app.photo_showroom(test.id('rsp_cs'), jsonb_build_object('action', 'redo', 'photo', (select id from rspf))) ->> 'queued'), '1');
select test.ok('redo keeps the showroom version under its own reason', exists (select 1 from vehicle_photo_versions where photo_id = (select id from rspf) and reason = 'showroom_redo' and processed_path = 'vehicles/rsp/old-front_left-v1.jpg'));
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_photo_id = (select id from rspf) and status in ('queued', 'running');
-- undo: the version before the showroom, as it was, on the site again
select test.eq('back to the original: restored', (select app.photo_showroom(test.id('rsp_cs'), jsonb_build_object('action', 'undo', 'photo', (select id from rspf))) ->> 'restored'), 'true');
select test.ok('the black studio file, its plate check, on the site, scene studio',
  (select processed_path = 'vehicles/rsp/old-front_left.jpg' and preset_version = 'studio_v5' and plate_status = 'not_visible' and is_public and scene = 'studio' and showroom is null
     from vehicle_photos where id = (select id from rspf)));
-- undo of a photo made in the showroom from the start: made again on the black studio
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_photo_id = (select rear from rspp) and status in ('queued', 'running');
update vehicle_photos set processed_path = 'vehicles/rsp/rear.jpg', status = 'processed', background_status = 'done', preset_version = 'studio_showroom_v1' where id = (select rear from rspp);
select test.eq('no version before: made again', (select app.photo_showroom(test.id('rsp_admin'), jsonb_build_object('action', 'undo', 'photo', (select rear from rspp))) ->> 'queued'), '1');
select test.eq('on the black studio', (select app.listing_job_context(j.id) -> 'photo' ->> 'scene' from listing_jobs j where j.vehicle_photo_id = (select rear from rspp) and j.kind = 'process_photo' and j.status = 'queued'), 'studio');
select test.throws('an inside photo is not put in the showroom',
  format('select app.photo_showroom(%L, jsonb_build_object(''action'', ''redo'', ''photo'', %L::uuid))', test.id('rsp_admin'), test.rsp_up((select i from rspi), 'dashboard')), 'Only an outside photo');

-- every car at once: Admin or fleet, not customer service
select test.throws('every car: not customer service', format('select app.photo_showroom(%L, ''{"all": true}''::jsonb)', test.id('rsp_cs')), 'An Admin or fleet');
select test.ok('every car: fleet may', (select (app.photo_showroom(test.id('rsp_fleet'), '{"all": true}'::jsonb) ->> 'queued')::int >= 1));
select test.ok('every car: the old car is in the showroom again', (select scene = 'showroom' from vehicle_photos where id = (select id from rspf)));
select test.ok('the door answers photo_showroom', (select app.door(test.id('rsp_admin'), 'aal2', 'ops_do', 'photo_showroom', jsonb_build_object('action', 'apply', 'vehicle', test.id('vehicle:rsp_car'))) ? 'queued'));

-- ---------------------------------------------------------------- the image model's gate
delete from provider_calls where purpose = 'listing_showroom';
update program_settings set listing_showroom_ai = false where id = (select id from app.settings());
select test.eq('switched off: not asked', (select app.showroom_ai_gate('{}'::jsonb) ->> 'reason'), 'off');
update program_settings set listing_showroom_ai = true, listing_showroom_ai_daily = 2 where id = (select id from app.settings());
create temp table rspg as select app.showroom_ai_gate(jsonb_build_object('photo_id', (select id from rspf))) as g;
select test.ok('allowed: the model and a call counted before it is made',
  (select (g ->> 'allowed')::boolean and g ->> 'model' = (select listing_showroom_ai_model from app.settings())
     and exists (select 1 from provider_calls c where c.id = (g ->> 'call_id')::uuid and c.purpose = 'listing_showroom' and c.unit = 'requests' and c.cost_microusd = 0
                   and c.vehicle_id = test.id('vehicle:rsp_old')) from rspg));
select test.eq('the answer is recorded', (select app.showroom_ai_record(jsonb_build_object('call_id', g ->> 'call_id', 'ok', true, 'duration_ms', 900)) ->> 'ok' from rspg), 'true');
select test.ok('recorded ok', (select ok and duration_ms = 900 from provider_calls where id = (select (g ->> 'call_id')::uuid from rspg)));
select test.ok('the second call of the day', (select (app.showroom_ai_gate('{}'::jsonb) ->> 'allowed')::boolean));
select test.eq('the daily limit is a hard stop', (select app.showroom_ai_gate('{}'::jsonb) ->> 'reason'), 'limit');
update program_settings set listing_showroom_ai_daily = 50 where id = (select id from app.settings());
update provider_calls set ok = false, error = 'quota: Quota exceeded' where purpose = 'listing_showroom' and ok is false and error = 'started';
select test.eq('a quota answer stops it for the hour', (select app.showroom_ai_gate('{}'::jsonb) ->> 'reason'), 'quota');
select test.ok('the server functions are the service role''s only',
  not has_function_privilege('authenticated', 'public.server_showroom_ai_gate(jsonb)', 'execute') and has_function_privilege('service_role', 'public.server_showroom_ai_gate(jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.photo_showroom(uuid, jsonb)', 'execute'));

-- ---------------------------------------------------------------- 1030: "every car" carries the plate cover by itself
-- two checked, covered photos on the site; every car at once; the worker makes them again: one with the car where it was (the
-- cover is carried), one with the car moved (asked again, as today). The list the listings page works through holds the first only.
select test.mk_vehicle('rsp_bulk', 'rsp_olive');
create temp table rspi3 as select (app.start_listing_intake(test.id('rsp_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rsp_bulk'))) ->> 'intake_id')::uuid as i;
create temp table rspb as select test.rsp_up((select i from rspi3), 'front_left') as stay, test.rsp_up((select i from rspi3), 'rear') as moved;
update listing_jobs set status = 'succeeded', finished_at = now() where intake_id = (select i from rspi3) and kind = 'process_photo';
update vehicle_photos set scene = 'studio', preset_version = 'studio_v5', background_status = 'done', status = 'approved', is_public = true,
       processed_path = 'vehicles/rsp/bulk-' || shot_type || '.jpg', plate_status = 'covered', plate_style = 'cover',
       plate_boxes = '[{"x":0.4,"y":0.7,"w":0.1,"h":0.05}]'::jsonb,
       cutout = jsonb_build_object('auto_mask', 'vehicles/rsp/work/bulk-' || shot_type || '-mask.png', 'place', jsonb_build_object('width', 1500, 'height', 600, 'left', 150, 'bottom', 250))
 where vehicle_id = test.id('vehicle:rsp_bulk');
select test.ok('every car: the photos of the car are queued', (select (app.photo_showroom(test.id('rsp_fleet'), '{"all": true}'::jsonb) ->> 'queued')::int >= 2));
create temp table rspc3 as select j.id, j.vehicle_photo_id as photo from app.claim_listing_jobs('rsp-w3', 500, array['process_photo']) j
 where j.vehicle_photo_id in (select stay from rspb union select moved from rspb);
select test.eq('both photos were made again', (select count(*)::text from rspc3), '2');
select app.worker_listing_result((select id from rspc3 where photo = (select stay from rspb)), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rsp/bulk-front_left-v1.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_showroom_v1', 'edited', true,
  'place', jsonb_build_object('width', 1500, 'height', 600, 'left', 150, 'bottom', 250), 'showroom', jsonb_build_object('provider', 'local'))));
select app.worker_listing_result((select id from rspc3 where photo = (select moved from rspb)), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rsp/bulk-rear-v1.jpg', 'width', 1800, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'studio_showroom_v1', 'edited', true,
  'place', jsonb_build_object('width', 1500, 'height', 600, 'left', 700, 'bottom', 100), 'showroom', jsonb_build_object('provider', 'local'))));
select test.ok('same framing: the cover waits to be carried (boxes and style kept), off the site until drawn',
  (select plate_status = 'unchecked' and not is_public and plate_carry -> 'boxes' -> 0 ->> 'x' = '0.4' and plate_carry ->> 'style' = 'cover'
     from vehicle_photos where id = (select stay from rspb)));
select test.ok('moved: no cover carried, asked for a plate check as today',
  (select plate_status = 'unchecked' and not is_public and plate_carry is null from vehicle_photos where id = (select moved from rspb)));
select test.ok('the bulk action reads the carried covers of every car: the same-framing photo is listed, the moved one is not',
  (select (app.door(test.id('rsp_fleet'), 'aal2', 'ops_read', 'showroom_carry_pending', '{}'::jsonb) -> 'photos') @> jsonb_build_array(jsonb_build_object('id', (select stay from rspb)))
     and not (app.door(test.id('rsp_fleet'), 'aal2', 'ops_read', 'showroom_carry_pending', '{}'::jsonb) -> 'photos') @> jsonb_build_array(jsonb_build_object('id', (select moved from rspb)))));
select test.ok('the listed photo has what the cover needs', (select p ->> 'processed_path' = 'vehicles/rsp/bulk-front_left-v1.jpg' and p ->> 'plate_status' = 'unchecked' and p -> 'plate_carry' ? 'boxes'
  from jsonb_array_elements(app.showroom_carry_pending(test.id('rsp_admin'), '{}'::jsonb) -> 'photos') p where p ->> 'id' = (select stay::text from rspb)));
select test.throws('a renter cannot read it', format('select app.showroom_carry_pending(%L, ''{}''::jsonb)', test.id('rsp_renter')), 'Fleet, customer service');
-- the cover drawn and saved (the plate decision recorded): the photo leaves the list and goes back on the site
update vehicle_photos set plate_status = 'covered', plate_boxes = plate_carry -> 'boxes' where id = (select stay from rspb);
select test.ok('covered: no longer waiting, the carried cover is used once',
  (select plate_carry is null from vehicle_photos where id = (select stay from rspb))
  and not (app.showroom_carry_pending(test.id('rsp_admin'), '{}'::jsonb) -> 'photos') @> jsonb_build_array(jsonb_build_object('id', (select stay from rspb))));
select test.ok('the list is the service role''s: not open to a signed-in client directly',
  not has_function_privilege('authenticated', 'app.showroom_carry_pending(uuid, jsonb)', 'execute'));

update program_settings set listing_plate_check_required = (select plate from rsp_prev), listing_showroom = (select sr from rsp_prev),
       listing_showroom_ai = (select ai from rsp_prev), listing_showroom_ai_daily = (select daily from rsp_prev) where id = (select id from app.settings());
