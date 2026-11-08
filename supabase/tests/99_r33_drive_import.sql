-- 99: migration 0760 (release 33, part J): import listing photos from a Google Drive link. A run walks the folders, each
-- photo goes through the listing upload as a staff upload does, the same Drive file on the same car is never taken twice
-- (and is taken again once its photo was taken off), the same picture is not taken twice, a failure says why, a folder
-- matched to a car is confirmed first, and only Admin, Fleet and customer service import. Fixtures start with "rdi";
-- every address is example.test; the Drive ids are made up.
select test.suite('99 r33 drive import (0760)');

select test.mk_user('rdi_admin', 'admin');
select test.mk_user('rdi_fleet', 'va', 'fleet');
select test.mk_user('rdi_cs', 'va', 'cs');
select test.mk_user('rdi_fin', 'va', 'finance');
select test.mk_user('rdi_renter', 'renter');
select test.mk_owner('rdi_olive');
select test.mk_vehicle('rdi_car', 'rdi_olive');
select test.mk_vehicle('rdi_car2', 'rdi_olive');

-- ---------------------------------------------------------------- 1. who may import
select test.throws('a renter cannot start an import', format('select app.drive_import_start(%L, jsonb_build_object(''root_id'', ''SyntheticRoot0001''))', test.id('rdi_renter')), 'imports listing photos');
select test.throws('finance cannot start an import', format('select app.drive_import_start(%L, jsonb_build_object(''root_id'', ''SyntheticRoot0001''))', test.id('rdi_fin')), 'imports listing photos');
select test.throws('a link that is not a folder is refused', format('select app.drive_import_start(%L, jsonb_build_object(''root_id'', ''x''))', test.id('rdi_admin')), 'not a Google Drive');
select test.ok('the door answers the cars to Admin', jsonb_array_length(app.door(test.id('rdi_admin'), 'aal2', 'ops_read', 'drive_import_cars', '{}'::jsonb)) >= 2);
select test.ok('and to Fleet', jsonb_array_length(app.door(test.id('rdi_fleet'), 'aal2', 'ops_read', 'drive_import_cars', '{}'::jsonb)) >= 2);
select test.throws('and not to a renter', format('select app.door(%L, ''aal2'', ''ops_read'', ''drive_import_cars'', ''{}''::jsonb)', test.id('rdi_renter')));

-- ---------------------------------------------------------------- 2. one car's folder: scan, then import
create temp table rdi_a as select (app.drive_import_start(test.id('rdi_fleet'), jsonb_build_object('root_id', 'SyntheticRoot0001', 'vehicle_id', test.id('vehicle:rdi_car'), 'submit', false)) ->> 'id')::uuid as id;
select test.eq('the same link and car pressed again is the run in progress',
  (select app.drive_import_start(test.id('rdi_fleet'), jsonb_build_object('root_id', 'SyntheticRoot0001', 'vehicle_id', test.id('vehicle:rdi_car'))) ->> 'id'), (select id::text from rdi_a));
select test.eq('a run starts scanning, with the link as its folder', (select status || ':' || (select count(*)::text from drive_import_folders where import_id = rdi_a.id) from drive_imports, rdi_a where drive_imports.id = rdi_a.id), 'scanning:1');

create temp table rdi_c as select app.drive_import_claim('test', 3, 4) as c;
select test.eq('the first claim scans the folder', (select c ->> 'phase' from rdi_c), 'scan');
select app.drive_import_folder_result((select (c -> 'folders' -> 0 ->> 'id')::uuid from rdi_c), jsonb_build_object(
  'ignored', 2, 'title', 'Example car folder',
  'folders', jsonb_build_array(jsonb_build_object('id', 'SyntheticSub00001', 'name', 'Interior')),
  'images', jsonb_build_array(
    jsonb_build_object('id', 'SyntheticImg00001', 'name', 'IMG_1.jpg', 'mime', 'image/jpeg', 'size', 1200000, 'kind', 'jpeg'),
    jsonb_build_object('id', 'SyntheticImg00002', 'name', 'IMG_2.jpg', 'mime', 'image/jpeg', 'size', 1300000, 'kind', 'jpeg'),
    jsonb_build_object('id', 'SyntheticImg00003', 'name', 'huge.jpg', 'mime', 'image/jpeg', 'size', 99000000, 'kind', 'jpeg', 'skip', 'Larger than 15 MB'))));
select test.eq('the link''s own folder takes the name of its page', (select name from drive_import_folders where import_id = (select id from rdi_a) and depth = 0), 'Example car folder');
select test.eq('the root folder is read: 3 photos found, one skipped for its size', (select image_count::text || ':' || other_count::text from drive_import_folders where import_id = (select id from rdi_a) and depth = 0), '3:2');
select test.eq('the subfolder is queued to be read', (select count(*)::text from drive_import_folders where import_id = (select id from rdi_a) and state = 'pending'), '1');
select test.eq('a locked run is not claimed twice', (select app.drive_import_claim('test2') is null), 'true');
select app.drive_import_release((select id from rdi_a), 0);
create temp table rdi_c2 as select app.drive_import_claim('test', 3, 4) as c;
select app.drive_import_folder_result((select (c -> 'folders' -> 0 ->> 'id')::uuid from rdi_c2), jsonb_build_object(
  'images', jsonb_build_array(jsonb_build_object('id', 'SyntheticImg00004', 'name', 'seat.png', 'mime', 'image/png', 'size', 800000, 'kind', 'png'))));
select test.eq('every folder read: a car run goes on to importing', (select status from drive_imports where id = (select id from rdi_a)), 'importing');
select test.eq('its photos are for that car, in order', (select string_agg(f.name, ',' order by fo.path, f.seq) from drive_import_files f join drive_import_folders fo on fo.id = f.folder_id where f.import_id = (select id from rdi_a) and f.state = 'pending' and f.vehicle_id = test.id('vehicle:rdi_car')), 'IMG_1.jpg,IMG_2.jpg,seat.png');

select app.drive_import_release((select id from rdi_a), 0);
create temp table rdi_c3 as select app.drive_import_claim('test', 3, 4) as c;
select test.eq('then the photos', (select c ->> 'phase' from rdi_c3), 'import');
select test.eq('three at a time', (select jsonb_array_length(c -> 'files')::text from rdi_c3), '3');

-- the first photo
create temp table rdi_p1 as select app.drive_import_prepare((select (c -> 'files' -> 0 ->> 'id')::uuid from rdi_c3)) as p;
select test.eq('the car gets its listing', (select (p ->> 'skip') from rdi_p1), 'false');
select test.ok('the listing was started by the person who started the run', exists (select 1 from listing_intakes where id = (select (p ->> 'intake')::uuid from rdi_p1) and started_by = test.id('rdi_fleet')));
create temp table rdi_r1 as select app.drive_import_record((select (c -> 'files' -> 0 ->> 'id')::uuid from rdi_c3), jsonb_build_object('shot_type', 'exterior_more',
  'original_path', 'vehicles/rdi/original/a1.jpg', 'width', 3000, 'height', 2000, 'byte_size', 1200000, 'mime_type', 'image/jpeg', 'sha256', repeat('a', 64))) as r;
select test.ok('the photo is on the car like a staff upload (an extra, ordered after the standard shots)', exists (select 1 from vehicle_photos
  where id = (select (r ->> 'photo_id')::uuid from rdi_r1) and vehicle_id = test.id('vehicle:rdi_car') and shot_type = 'exterior_more' and sort_order >= 100000 and content_sha256 = repeat('a', 64) and uploaded_by = test.id('rdi_fleet')));
select test.eq('the file is done and linked to its photo', (select state || ':' || (photo_id is not null)::text from drive_import_files where id = (select (c -> 'files' -> 0 ->> 'id')::uuid from rdi_c3)), 'done:true');

-- the same picture under another Drive id is not taken twice
create temp table rdi_r2 as select app.drive_import_record((select (c -> 'files' -> 1 ->> 'id')::uuid from rdi_c3), jsonb_build_object('shot_type', 'exterior_more',
  'original_path', 'vehicles/rdi/original/a2.jpg', 'byte_size', 1300000, 'mime_type', 'image/jpeg', 'sha256', repeat('a', 64))) as r;
select test.eq('the same picture is skipped, not added', (select r ->> 'reason' from rdi_r2), 'same_picture');
select test.eq('and says why', (select state || ':' || reason from drive_import_files where id = (select (c -> 'files' -> 1 ->> 'id')::uuid from rdi_c3)), 'skipped:The same photo is already on this car');

-- a shot that does not exist fails with its reason, the run goes on
create temp table rdi_r3 as select app.drive_import_record((select (c -> 'files' -> 2 ->> 'id')::uuid from rdi_c3), jsonb_build_object('shot_type', 'no_such_shot',
  'original_path', 'vehicles/rdi/original/a3.png', 'byte_size', 800000, 'mime_type', 'image/png', 'sha256', repeat('b', 64))) as r;
select test.ok('a photo the listing refuses fails with the reason', (select state = 'failed' and reason like 'Unknown photo%' from drive_import_files where id = (select (c -> 'files' -> 2 ->> 'id')::uuid from rdi_c3)));
select test.eq('no photo was added for it', (select count(*)::text from vehicle_photos where vehicle_id = test.id('vehicle:rdi_car')), '1');

-- a busy Drive: tried again later, up to three times
select app.drive_import_file_fail((select (c -> 'files' -> 2 ->> 'id')::uuid from rdi_c3), 'x', true);
select test.eq('a failed photo stays failed (it is not pending)', (select state from drive_import_files where id = (select (c -> 'files' -> 2 ->> 'id')::uuid from rdi_c3)), 'failed');

-- finish: no photos pending, the totals
select app.drive_import_release((select id from rdi_a), 0);
create temp table rdi_c4 as select app.drive_import_claim('test') as c;
select test.eq('nothing left: the run is finished', (select c ->> 'phase' from rdi_c4), 'done');
select test.eq('the totals say what happened', (select (totals ->> 'imported') || '/' || (totals ->> 'skipped') || '/' || (totals ->> 'failed') from drive_imports where id = (select id from rdi_a)), '1/2/1');
select test.eq('the run is done', (select status from drive_imports where id = (select id from rdi_a)), 'done');
select test.ok('no submit was asked: the listing is not submitted', (select submitted_at is null from listing_intakes where vehicle_id = test.id('vehicle:rdi_car') and state not in ('published', 'cancelled')));

-- ---------------------------------------------------------------- 3. idempotent: the same Drive file on the same car again
create temp table rdi_b as select (app.drive_import_start(test.id('rdi_admin'), jsonb_build_object('root_id', 'SyntheticRoot0001', 'vehicle_id', test.id('vehicle:rdi_car'), 'submit', false)) ->> 'id')::uuid as id;
select test.ok('a second run starts after the first is done', (select id from rdi_b) <> (select id from rdi_a));
select app.drive_import_folder_result((select id from drive_import_folders where import_id = (select id from rdi_b)), jsonb_build_object(
  'images', jsonb_build_array(jsonb_build_object('id', 'SyntheticImg00001', 'name', 'IMG_1.jpg', 'mime', 'image/jpeg', 'size', 1200000, 'kind', 'jpeg'),
                              jsonb_build_object('id', 'SyntheticImg00005', 'name', 'IMG_5.jpg', 'mime', 'image/jpeg', 'size', 900000, 'kind', 'jpeg'))));
select test.eq('the second run is importing', (select status from drive_imports where id = (select id from rdi_b)), 'importing');
create temp table rdi_pb as select app.drive_import_prepare(f.id) as p, f.drive_id from drive_import_files f where f.import_id = (select id from rdi_b) order by f.seq;
select test.eq('the file already imported is skipped before it is downloaded', (select p ->> 'reason' from rdi_pb where drive_id = 'SyntheticImg00001'), 'duplicate');
select test.eq('the new file is to do', (select p ->> 'skip' from rdi_pb where drive_id = 'SyntheticImg00005'), 'false');
select test.eq('so nothing was duplicated', (select count(*)::text from vehicle_photos where vehicle_id = test.id('vehicle:rdi_car') and replaced_at is null), '1');

-- the photo is taken off the car: the file can be imported again
update vehicle_photos set status = 'rejected' where vehicle_id = test.id('vehicle:rdi_car');
create temp table rdi_cc as select id from drive_import_files where import_id = (select id from rdi_b) and drive_id = 'SyntheticImg00001';
update drive_imports set status = 'done' where id = (select id from rdi_b);
create temp table rdi_d as select (app.drive_import_start(test.id('rdi_admin'), jsonb_build_object('root_id', 'SyntheticRoot0001', 'vehicle_id', test.id('vehicle:rdi_car'), 'submit', false)) ->> 'id')::uuid as id;
select app.drive_import_folder_result((select id from drive_import_folders where import_id = (select id from rdi_d)), jsonb_build_object(
  'images', jsonb_build_array(jsonb_build_object('id', 'SyntheticImg00001', 'name', 'IMG_1.jpg', 'mime', 'image/jpeg', 'size', 1200000, 'kind', 'jpeg'))));
select test.eq('a photo taken off the car is imported again from the same Drive file', (select app.drive_import_prepare(f.id) ->> 'skip' from drive_import_files f where f.import_id = (select id from rdi_d)), 'false');

update drive_imports set status = 'cancelled' where status in ('scanning', 'importing');

-- ---------------------------------------------------------------- 4. a whole tree: matched to cars, confirmed, then imported
create temp table rdi_e as select (app.drive_import_start(test.id('rdi_cs'), jsonb_build_object('root_id', 'SyntheticTop00001')) ->> 'id')::uuid as id;
select test.eq('without a car it is a bulk run', (select kind from drive_imports where id = (select id from rdi_e)), 'bulk');
create temp table rdi_ec as select app.drive_import_claim('test') as c;
select app.drive_import_folder_result((select (c -> 'folders' -> 0 ->> 'id')::uuid from rdi_ec), jsonb_build_object(
  'folders', jsonb_build_array(jsonb_build_object('id', 'SyntheticMake0001', 'name', 'Mercedes'), jsonb_build_object('id', 'SyntheticMake0002', 'name', 'Toyota')), 'images', '[]'::jsonb));
select app.drive_import_release((select id from rdi_e), 0);
create temp table rdi_ec2 as select app.drive_import_claim('test', 3, 4) as c;
select test.eq('the make folders are read next', (select jsonb_array_length(c -> 'folders')::text from rdi_ec2), '2');
select app.drive_import_folder_result(x.id, jsonb_build_object('folders', jsonb_build_array(jsonb_build_object('id', 'SyntheticCar00001', 'name', '2023 C300 white'), jsonb_build_object('id', 'SyntheticCar00002', 'name', 'empty folder')), 'images', '[]'::jsonb))
  from (select (value ->> 'id')::uuid as id from jsonb_array_elements((select c -> 'folders' from rdi_ec2)) where value ->> 'name' = 'Mercedes') x;
select app.drive_import_folder_result(x.id, jsonb_build_object('images', '[]'::jsonb))
  from (select (value ->> 'id')::uuid as id from jsonb_array_elements((select c -> 'folders' from rdi_ec2)) where value ->> 'name' = 'Toyota') x;
select app.drive_import_release((select id from rdi_e), 0);
create temp table rdi_ec3 as select app.drive_import_claim('test', 3, 4) as c;
select app.drive_import_folder_result((value ->> 'id')::uuid, case when value ->> 'name' = 'empty folder' then jsonb_build_object('images', '[]'::jsonb)
  else jsonb_build_object('images', jsonb_build_array(jsonb_build_object('id', 'SyntheticImg00011', 'name', 'a.jpg', 'mime', 'image/jpeg', 'size', 500000, 'kind', 'jpeg'),
                                                      jsonb_build_object('id', 'SyntheticImg00012', 'name', 'b.jpg', 'mime', 'image/jpeg', 'size', 500000, 'kind', 'jpeg'))) end)
  from jsonb_array_elements((select c -> 'folders' from rdi_ec3));
select test.eq('every folder read, a bulk run waits to be matched', (select status || ':' || (scanned_at is not null)::text from drive_imports where id = (select id from rdi_e)), 'scanning:true');
select app.drive_import_release((select id from rdi_e), 0);
create temp table rdi_em as select app.drive_import_claim('test') as c;
select test.eq('the next claim is the matching', (select c ->> 'phase' from rdi_em), 'match');
select test.eq('with the folders above each folder named', (select (value -> 'ancestors' ->> 0) from jsonb_array_elements((select c -> 'folders' from rdi_em)) where value ->> 'name' = '2023 C300 white'), 'Mercedes');
select app.drive_import_matches((select id from rdi_e), (select jsonb_agg(jsonb_build_object('folder', value ->> 'id', 'vehicle_id', case when value ->> 'name' = '2023 C300 white' then test.id('vehicle:rdi_car2')::text end,
   'score', 90, 'note', 'matched on make, model', 'candidates', '[]'::jsonb, 'ambiguous', false)) from jsonb_array_elements((select c -> 'folders' from rdi_em)) where (value ->> 'images')::integer >= 0));
select test.eq('the run waits for the person', (select status from drive_imports where id = (select id from rdi_e)), 'review');
select test.eq('the proposal is on the folder, included only with photos and a car', (select string_agg(name || '=' || include::text, ',' order by name) from drive_import_folders where import_id = (select id from rdi_e) and depth = 2), '2023 C300 white=true,empty folder=false');
select test.eq('nothing is claimed before it is confirmed', (select app.drive_import_claim('x') is null), 'true');
select test.throws('a renter cannot confirm', format('select app.drive_import_confirm(%L, jsonb_build_object(''import'', %L, ''rows'', ''[]''::jsonb))', test.id('rdi_renter'), (select id from rdi_e)), 'imports listing photos');
-- the person changes the car and confirms
select app.drive_import_confirm(test.id('rdi_cs'), jsonb_build_object('import', (select id from rdi_e), 'submit', false, 'rows',
  (select jsonb_agg(jsonb_build_object('folder', id, 'vehicle', test.id('vehicle:rdi_car')::text, 'include', true)) from drive_import_folders where import_id = (select id from rdi_e) and name = '2023 C300 white')));
select test.eq('confirmed: importing, the photos for the car chosen', (select status from drive_imports where id = (select id from rdi_e)) || ':' || (select count(*)::text from drive_import_files where import_id = (select id from rdi_e) and vehicle_id = test.id('vehicle:rdi_car') and state = 'pending'), 'importing:2');
select test.throws('a run cannot be confirmed twice', format('select app.drive_import_confirm(%L, jsonb_build_object(''import'', %L, ''rows'', ''[]''::jsonb))', test.id('rdi_cs'), (select id from rdi_e)), 'cannot be confirmed');

-- customer service may upload into a listing already started (it cannot start one)
select app.drive_import_release((select id from rdi_e), 0);
create temp table rdi_ei as select app.drive_import_claim('test', 3, 4) as c;
select test.eq('customer service imports into the car whose listing is started', (select app.drive_import_prepare((c -> 'files' -> 0 ->> 'id')::uuid) ->> 'skip' from rdi_ei), 'false');

-- cancel
select app.drive_import_cancel(test.id('rdi_cs'), jsonb_build_object('import', (select id from rdi_e)));
select test.eq('a cancelled run leaves its photos skipped', (select status || ':' || (select count(*)::text from drive_import_files where import_id = rdi_e.id and state = 'skipped' and reason = 'Cancelled') from drive_imports, rdi_e where drive_imports.id = rdi_e.id), 'cancelled:2');
select test.eq('a cancelled run is not claimed', (select app.drive_import_claim('z') is null), 'true');

-- ---------------------------------------------------------------- 5. a private folder, the limits, the page's reads
create temp table rdi_f as select (app.drive_import_start(test.id('rdi_admin'), jsonb_build_object('root_id', 'SyntheticPrivate01')) ->> 'id')::uuid as id;
select app.drive_import_folder_result((select id from drive_import_folders where import_id = (select id from rdi_f)), jsonb_build_object('error', 'The folder is not shared'));
select test.eq('a folder that cannot be read fails the run with the reason', (select status || ':' || error from drive_imports where id = (select id from rdi_f)), 'failed:The folder is not shared');
create temp table rdi_g as select (app.drive_import_start(test.id('rdi_admin'), jsonb_build_object('root_id', 'SyntheticEmpty001', 'vehicle_id', test.id('vehicle:rdi_car2'))) ->> 'id')::uuid as id;
select app.drive_import_folder_result((select id from drive_import_folders where import_id = (select id from rdi_g)), jsonb_build_object('images', '[]'::jsonb, 'ignored', 4));
select test.ok('a folder with no photo fails the run, saying what to check', (select status = 'failed' and error like '%Anyone with the link%' from drive_imports where id = (select id from rdi_g)));
create temp table rdi_h as select (app.drive_import_start(test.id('rdi_admin'), jsonb_build_object('root_id', 'SyntheticMany0001', 'vehicle_id', test.id('vehicle:rdi_car2'))) ->> 'id')::uuid as id;
select app.drive_import_folder_result((select id from drive_import_folders where import_id = (select id from rdi_h)), jsonb_build_object('images',
  (select jsonb_agg(jsonb_build_object('id', 'SyntheticLim' || lpad(n::text, 6, '0'), 'name', n || '.jpg', 'mime', 'image/jpeg', 'size', 1000, 'kind', 'jpeg')) from generate_series(1, 603) n)));
select test.eq('an import takes 600 photos at most, the rest are skipped with the reason', (select count(*) filter (where state = 'pending')::text || '/' || count(*) filter (where state = 'skipped')::text from drive_import_files where import_id = (select id from rdi_h)), '600/3');
select test.eq('the page reads the run and its folders', (select app.drive_import_get(test.id('rdi_fleet'), jsonb_build_object('import', (select id from rdi_h))) -> 'import' ->> 'status'), 'importing');
select test.ok('and the problems with their reasons', (select (app.drive_import_get(test.id('rdi_fleet'), jsonb_build_object('import', (select id from rdi_h))) -> 'problems' -> 0 ->> 'reason') like 'More than 600%'));
select test.ok('the list names the runs of a car', jsonb_array_length(app.drive_import_list(test.id('rdi_admin'), jsonb_build_object('vehicle', test.id('vehicle:rdi_car')))) >= 3);
select test.throws('a renter reads no import', format('select app.drive_import_get(%L, jsonb_build_object(''import'', %L))', test.id('rdi_renter'), (select id from rdi_h)), 'imports listing photos');

-- failed photos can be tried again
update drive_import_files set state = 'failed', reason = 'x' where id = (select id from drive_import_files where import_id = (select id from rdi_h) and state = 'pending' limit 1);
update drive_imports set status = 'done', scanned_at = now() where id = (select id from rdi_h);
select test.eq('Try again puts the failed photos back', (select app.drive_import_retry(test.id('rdi_admin'), jsonb_build_object('import', (select id from rdi_h))) ->> 'retrying'), '1');
select test.eq('and the run is importing again', (select status from drive_imports where id = (select id from rdi_h)), 'importing');

-- the cron tick starts the listing route when an import has work, and not otherwise
select test.eq('the cron gate says so while a run has work', (select app.server_jobs_due() ->> 'drive_import'), 'true');
update drive_imports set status = 'cancelled' where status in ('scanning', 'importing');
select test.ok('and not when none has', coalesce((select app.server_jobs_due() ->> 'drive_import'), 'no') = 'no');

-- the API key setting: empty, then set (a key of the right shape only)
select test.ok('no key is set by default', app.drive_import_key() is null);
select test.throws('a key of the wrong shape is refused', $q$update program_settings set google_drive_api_key = 'not a key!' where id = (select id from app.settings())$q$);
update program_settings set google_drive_api_key = 'AIzaExampleKeyForTestsOnly_0123456789' where id = (select id from app.settings());
select test.eq('the key is read by the server', app.drive_import_key(), 'AIzaExampleKeyForTestsOnly_0123456789');
update program_settings set google_drive_api_key = null where id = (select id from app.settings());
