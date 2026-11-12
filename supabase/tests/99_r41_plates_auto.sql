-- 99: migration 2530: the licence plate on every listing photo is checked by itself. A processed public photo whose plate
-- is not checked is queued (plate_auto, the lowest priority); the worker's answer covers it, marks it "No plate visible" or
-- leaves it for a person, only while the photo is still the file it saw; a person undoes it in one click; "Cover the
-- plate" saves the CARMA plate. Fixtures start with "rpa"; addresses example.test.
select test.suite('99 r41 plates checked by themselves (2530)');

create temp table rpa_prev as select listing_plate_check_required as plate, plate_auto_enabled as auto from app.settings();
update program_settings set listing_plate_check_required = true, plate_auto_enabled = true where id = (select id from app.settings());

select test.mk_user('rpa_admin', 'admin');
select test.mk_user('rpa_fleet', 'va', 'fleet');
select test.mk_user('rpa_renter_user', 'renter');
select test.mk_owner('rpa_olive');
select test.mk_vehicle('rpa_car', 'rpa_olive');
create temp table rpai as select (app.start_listing_intake(test.id('rpa_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rpa_car'))) ->> 'intake_id')::uuid as i;
create or replace function test.rpa_up(p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rpa_admin'), (select i from rpai), jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rpa/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000,
          'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create temp table rpap as select test.rpa_up('front_left') as fl, test.rpa_up('dashboard') as dash, test.rpa_up('rear') as rear, test.rpa_up('odometer') as odo;
-- processed, as the worker leaves them (no process step in the way)
create or replace function test.rpa_processed(p_photo uuid, p_name text) returns void language sql as $$
  update vehicle_photos set status = 'processed', processed_path = 'vehicles/' || vehicle_id || '/' || p_name || '.jpg',
         variants = jsonb_build_array(jsonb_build_object('width', 1024, 'format', 'jpg', 'path', 'vehicles/' || vehicle_id || '/' || p_name || '-1024.jpg'))
   where id = p_photo $$;
create or replace function test.rpa_job(p_photo uuid) returns listing_jobs language sql as $$
  select * from listing_jobs where vehicle_photo_id = p_photo and kind = 'plate_auto' order by created_at desc limit 1 $$;
select test.rpa_processed((select fl from rpap), 'front-left');
select test.rpa_processed((select dash from rpap), 'dashboard');
select test.rpa_processed((select rear from rpap), 'rear');
select test.rpa_processed((select odo from rpap), 'odometer');

-- ---------------------------------------------------------------- 1. queued
select test.ok('a processed outside photo whose plate is not checked is queued for the check', (test.rpa_job((select fl from rpap))).status = 'queued');
select test.eq('the job knows the file, the smaller size to show the model, the end of the car and the thresholds',
  (select concat_ws('/', input #>> '{plate,source}' like '%front-left.jpg', input #>> '{plate,detect_path}' like '%front-left-1024.jpg', input #>> '{plate,end}',
                    input #>> '{plate,inside}', input #>> '{plate,cover_min}', input #>> '{plate,clear_min}') from (select (test.rpa_job((select fl from rpap))).input) x),
  't/t/front/false/55/85');
select test.eq('an inside shot is queued as one', (test.rpa_job((select dash from rpap))).input #>> '{plate,inside}', 'true');
select test.ok('a shot never published (the odometer) is not', (test.rpa_job((select odo from rpap))).id is null);
select test.eq('queuing again adds nothing (one open job a photo)', app.plate_auto_queue(null, test.id('vehicle:rpa_car')), 0);
select test.ok('the check comes after every other step',
  (select position('when ''plate_auto'' then 4' in prosrc) > 0 from pg_proc where oid = 'app.worker_claim_listing_jobs(text, integer, timestamptz)'::regprocedure));
select test.ok('the review says the check runs and how many photos wait for it',
  (select (r ->> 'auto')::boolean and (r ->> 'auto_waiting')::integer >= 3 from (select app.listing_plates(test.id('rpa_admin'), test.id('vehicle:rpa_car')) r) x));

-- ---------------------------------------------------------------- 2. the worker's decisions
create temp table rpa_cover as select app.plate_auto_apply(jsonb_build_object('photo_id', (select fl from rpap), 'path', (select processed_path from vehicle_photos where id = (select fl from rpap)),
  'decision', 'covered', 'confidence', 88, 'model', '@cf/test/vision', 'boxes', '[{"x": 0.4, "y": 0.6, "w": 0.2, "h": 0.08}]'::jsonb,
  'processed_path', 'vehicles/' || test.id('vehicle:rpa_car') || '/front-left-aabc123.jpg', 'variants', '[]'::jsonb,
  'uncovered_path', 'vehicles/' || test.id('vehicle:rpa_car') || '/uncovered/x.jpg', 'width', 3000, 'height', 2000, 'byte_size', 800000)) r;
update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_photo_id = (select fl from rpap) and kind = 'plate_auto';
select test.eq('a plate found: covered with the CARMA plate, by itself, the uncovered file kept privately',
  (select concat_ws('/', plate_status, plate_style, plate_checked_by is null, plate_auto ->> 'who', plate_auto ->> 'confidence', uncovered_path like '%/uncovered/x.jpg',
                    plate_auto ->> 'prev_path' like '%front-left.jpg') from vehicle_photos where id = (select fl from rpap)), 'covered/carma/t/auto/88/t/t');
select test.ok('the files it replaced are handed back to be taken off the public bucket',
  (select (r ->> 'applied')::boolean and r -> 'previous' ? ('vehicles/' || test.id('vehicle:rpa_car') || '/front-left.jpg')
          and r -> 'previous' ? ('vehicles/' || test.id('vehicle:rpa_car') || '/front-left-1024.jpg') from rpa_cover));
select test.ok('its sizes are made again from the covered file',
  exists (select 1 from listing_jobs where vehicle_photo_id = (select fl from rpap) and kind = 'resize' and status = 'queued'));
select test.eq('a late answer for a file that changed changes nothing',
  app.plate_auto_apply(jsonb_build_object('photo_id', (select rear from rpap), 'path', 'vehicles/old.jpg', 'decision', 'not_visible', 'confidence', 99)) ->> 'reason', 'changed');
select app.plate_auto_apply(jsonb_build_object('photo_id', (select dash from rpap), 'path', (select processed_path from vehicle_photos where id = (select dash from rpap)),
  'decision', 'not_visible', 'confidence', 92, 'model', '@cf/test/vision'));
select test.eq('an inside shot with no plate: "No plate visible" by itself',
  (select plate_status || '/' || (plate_auto ->> 'decision') from vehicle_photos where id = (select dash from rpap)), 'not_visible/not_visible');
select app.plate_auto_apply(jsonb_build_object('photo_id', (select rear from rpap), 'path', (select processed_path from vehicle_photos where id = (select rear from rpap)),
  'decision', 'unsure', 'confidence', 40, 'model', '@cf/test/vision'));
select test.eq('unsure: left for a person, the answer kept', (select plate_status || '/' || (plate_auto ->> 'decision') from vehicle_photos where id = (select rear from rpap)), 'unchecked/unsure');
update listing_jobs set status = 'cancelled' where vehicle_photo_id = (select rear from rpap) and kind = 'plate_auto';
select test.eq('an unsure photo is not asked again for the same file', app.plate_auto_queue((select rear from rpap)), 0);
select test.throws('a cover outside the photo is refused',
  format($q$select app.plate_auto_apply(jsonb_build_object('photo_id', %L::uuid, 'path', (select processed_path from vehicle_photos where id = %L::uuid), 'decision', 'covered',
    'boxes', '[{"x": 0.9, "y": 0.6, "w": 0.2, "h": 0.08}]'::jsonb, 'processed_path', 'vehicles/' || %L || '/x.jpg'))$q$, (select rear from rpap), (select rear from rpap), test.id('vehicle:rpa_car')),
  'outside the photo');
select test.throws('a cover file of another car is refused',
  format($q$select app.plate_auto_apply(jsonb_build_object('photo_id', %L::uuid, 'path', (select processed_path from vehicle_photos where id = %L::uuid), 'decision', 'covered',
    'boxes', '[{"x": 0.4, "y": 0.6, "w": 0.2, "h": 0.08}]'::jsonb, 'processed_path', 'vehicles/someone-else/x.jpg'))$q$, (select rear from rpap), (select rear from rpap)),
  'not this car');

-- the day's AI share used: the job waits an hour, its attempt given back
update listing_jobs set status = 'running', attempts = 1, locked_at = now(), locked_by = 'rpa' where id = (test.rpa_job((select dash from rpap))).id and status = 'queued';
update vehicle_photos set plate_status = 'unchecked', plate_auto = null where id = (select dash from rpap);
select app.worker_listing_result((test.rpa_job((select dash from rpap))).id, '{"ok": true, "provider": "carmacars", "output": {"plate_auto": {"decision": "deferred"}}}'::jsonb);
select test.eq('a check the model could not be asked for waits an hour without using an attempt',
  (select concat_ws('/', status, attempts, next_attempt_at > now() + interval '50 minutes') from listing_jobs where id = (test.rpa_job((select dash from rpap))).id), 'queued/0/t');

-- ---------------------------------------------------------------- 3. a person undoes it
select test.throws('a renter cannot undo a plate decision',
  format($q$select app.photo_plate_auto_undo(%L, jsonb_build_object('photo', %L::uuid))$q$, test.id('rpa_renter_user'), (select fl from rpap)), 'Fleet, customer service or an Admin');
select test.throws('a cover is undone only with the photo as it was put back',
  format($q$select app.photo_plate_auto_undo(%L, jsonb_build_object('photo', %L::uuid))$q$, test.id('rpa_fleet'), (select fl from rpap)), 'not this car');
create temp table rpa_undo as select app.photo_plate_auto_undo(test.id('rpa_fleet'), jsonb_build_object('photo', (select fl from rpap), 'to', 'unchecked',
  'processed_path', 'vehicles/' || test.id('vehicle:rpa_car') || '/front-left-u000001.jpg')) r;
select test.eq('undo: the uncovered file back, not checked, marked undone',
  (select concat_ws('/', plate_status, processed_path like '%front-left-u000001.jpg', plate_boxes::text, plate_auto ->> 'undone', plate_auto ->> 'path' = processed_path)
     from vehicle_photos where id = (select fl from rpap)), 'unchecked/t/[]/true/t');
select test.ok('the covered file is handed back to be removed', (select r -> 'previous' ? ('vehicles/' || test.id('vehicle:rpa_car') || '/front-left-aabc123.jpg') from rpa_undo));
select test.ok('an undone photo is not checked by itself again for the same file', (test.rpa_job((select fl from rpap))).status <> 'queued');
select test.throws('and cannot be undone twice',
  format($q$select app.photo_plate_auto_undo(%L, jsonb_build_object('photo', %L::uuid))$q$, test.id('rpa_fleet'), (select fl from rpap)), 'not checked automatically');
select test.ok('an undo is audited', exists (select 1 from audit_log where action = 'photo_plate_auto_undo' and entity_id = (select fl from rpap)::text));
select app.plate_auto_apply(jsonb_build_object('photo_id', (select dash from rpap), 'path', (select processed_path from vehicle_photos where id = (select dash from rpap)),
  'decision', 'not_visible', 'confidence', 92));
select app.photo_plate_auto_undo(test.id('rpa_admin'), jsonb_build_object('photo', (select dash from rpap)));
select test.eq('an automatic "No plate visible" undone: not checked', (select plate_status from vehicle_photos where id = (select dash from rpap)), 'unchecked');
select test.ok('the door takes the undo for staff', (select position('photo_plate_auto_undo' in prosrc) > 0 from pg_proc where oid = 'app.door(uuid, text, text, text, jsonb)'::regprocedure));

-- ---------------------------------------------------------------- 4. "Cover the plate" with the CARMA plate saves
select app.photo_plate_record(test.id('rpa_fleet'), jsonb_build_object('photo', (select fl from rpap), 'status', 'covered', 'style', 'carma',
  'boxes', '[{"x": 0.4, "y": 0.6, "w": 0.2, "h": 0.08}]'::jsonb, 'processed_path', 'vehicles/' || test.id('vehicle:rpa_car') || '/front-left-c111111.jpg', 'variants', '[]'::jsonb));
select test.eq('a person covers the plate with the CARMA plate (refused before: "Choose cover, pixelate or blur")',
  (select concat_ws('/', plate_status, plate_style, plate_checked_by = test.id('rpa_fleet')) from vehicle_photos where id = (select fl from rpap)), 'covered/carma/t');
select test.throws('another style is still refused',
  format($q$select app.photo_plate_record(%L, jsonb_build_object('photo', %L::uuid, 'status', 'covered', 'style', 'paint', 'boxes', '[{"x": 0.4, "y": 0.6, "w": 0.2, "h": 0.08}]'::jsonb,
    'processed_path', 'vehicles/' || %L || '/x.jpg'))$q$, test.id('rpa_fleet'), (select fl from rpap), test.id('vehicle:rpa_car')), 'Choose cover');

-- ---------------------------------------------------------------- 5. off
update program_settings set plate_auto_enabled = false where id = (select id from app.settings());
update listing_jobs set status = 'cancelled' where vehicle_id = test.id('vehicle:rpa_car') and kind = 'plate_auto' and status in ('queued', 'running');
select test.eq('with the check off nothing is queued', app.plate_auto_queue(null, test.id('vehicle:rpa_car')), 0);

update program_settings set listing_plate_check_required = (select plate from rpa_prev), plate_auto_enabled = (select auto from rpa_prev) where id = (select id from app.settings());
