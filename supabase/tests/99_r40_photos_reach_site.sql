-- 99: migration 2450: the real photos reach the car pages. The worker's job context is read once (fast), local photo work
-- is never held by the day's photo budget, a live listing's finished photos are approved (the plate rule still keeps a photo
-- private until its plate is checked), the cover falls back to any approved public photo, "Process photos without the
-- resize service" takes every stuck step of every listing not cancelled. Fixtures start with "rph"; addresses example.test.
select test.suite('99 r40 photos reach the site (2450)');

create temp table rph_prev as select listing_plate_check_required as plate, photo_daily_budget_microusd as budget, listing_cf_transformations as cf from app.settings();
update program_settings set listing_plate_check_required = true, listing_cf_transformations = false where id = (select id from app.settings());

select test.mk_user('rph_admin', 'admin');
select test.mk_user('rph_fleet', 'va', 'fleet');
select test.mk_owner('rph_olive');
select test.mk_vehicle('rph_car', 'rph_olive');
create temp table rphi as select (app.start_listing_intake(test.id('rph_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rph_car'))) ->> 'intake_id')::uuid as i;
create or replace function test.rph_up(p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rph_admin'), (select i from rphi), jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rph/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 6000, 'height', 4000,
          'byte_size', 9000000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create temp table rphp as select test.rph_up('front_left') as fl, test.rph_up('other') as detail, test.rph_up('rear') as rear;
select app.submit_listing_intake(test.id('rph_admin'), (select i from rphi));
create or replace function test.rph_job(p_photo uuid, p_kind text default 'process_photo') returns uuid language sql as $$
  select id from listing_jobs where vehicle_photo_id = p_photo and kind = p_kind order by created_at desc limit 1 $$;

-- ---------------------------------------------------------------- 1. the job context: every layer's fields, read once
create temp table rph_ctx as select clock_timestamp() as t0, app.listing_job_context(test.rph_job((select fl from rphp))) as c, clock_timestamp() as t1;
select test.ok('the context of a photo job is read in well under a second (it took over 20 s with seven SQL wrappers)',
  (select t1 - t0 < interval '1 second' from rph_ctx));
select test.eq('the photo carries the model, the cover, the scene, no mark, the touch-up',
  (select concat_ws('/', (c #>> '{photo,model}' = (select model from vehicles where id = test.id('vehicle:rph_car')))::text, c #>> '{photo,is_cover}',
                    (c #>> '{photo,scene}' = (select coalesce(scene, 'studio') from vehicle_photos where id = (select fl from rphp)))::text,
                    c #>> '{photo,watermark}', c #>> '{photo,enhance}', c #>> '{photo,width}') from rph_ctx), 'true/true/true/false/true/6000');
select test.ok('the file name and the 2400 room and cut-out settings are there',
  (select c #>> '{photo,file_base}' like '%front-left-%' and c ? 'background' and c #>> '{cutout,min_quality}' = '0.60' from rph_ctx));
create temp table rph_scene as select scene from vehicle_photos where id = (select fl from rphp);
update vehicle_photos set edit_version = 2, quality_flags = '["watermark"]'::jsonb, scene = 'showroom' where id = (select fl from rphp);
select test.eq('an edited photo''s file name gets its version; a flagged mark and the showroom are passed on',
  (select concat_ws('/', right(c #>> '{photo,file_base}', 3), c #>> '{photo,watermark}', c #>> '{photo,scene}') from (select app.listing_job_context(test.rph_job((select fl from rphp))) c) x), '-v2/true/showroom');
update vehicle_photos set edit_version = 0, quality_flags = '[]'::jsonb, scene = (select scene from rph_scene) where id = (select fl from rphp);
select test.ok('a job without a photo (the copy) keeps its context',
  (select (app.listing_job_context(id) ->> 'kind') = 'draft_copy' from listing_jobs where kind = 'draft_copy' limit 1) is not false);

-- ---------------------------------------------------------------- 2. the claim: local photo work is never held by the budget
-- the other suites' due jobs wait while this one claims (restored below)
create temp table rph_others as select id, next_attempt_at from listing_jobs where status = 'queued' and intake_id <> (select i from rphi);
update listing_jobs set next_attempt_at = now() + interval '100 years' where id in (select id from rph_others);
update program_settings set photo_daily_budget_microusd = 0 where id = (select id from app.settings());
update listing_jobs set input = input || '{"local_only": true}'::jsonb where id = test.rph_job((select detail from rphp));
select app.enqueue_listing_job((select i from rphi), 'resize', (select rear from rphp), '{}'::jsonb);
create temp table rph_claim as select app.worker_claim_listing_jobs('rph-w', 50) c;
create temp table rph_claimed as select (e ->> 'id')::uuid as id from rph_claim, jsonb_array_elements(c -> 'jobs') e;
select test.ok('the budget is spent: the claim says photos are held', (select (c #>> '{held,photos}')::boolean from rph_claim));
select test.ok('a photo step that needs the image service waits', test.rph_job((select fl from rphp)) not in (select id from rph_claimed));
select test.ok('a step queued with local_only is claimed', test.rph_job((select detail from rphp)) in (select id from rph_claimed));
select test.ok('the sizes (made in the Worker) are claimed', test.rph_job((select rear from rphp), 'resize') in (select id from rph_claimed));
update program_settings set photo_daily_budget_microusd = (select budget from rph_prev) where id = (select id from app.settings());
-- a step whose worker stopped and that used its attempts is left to the sweep
update listing_jobs set status = 'running', attempts = max_attempts, locked_at = now() - interval '2 hours' where id = test.rph_job((select fl from rphp));
select test.ok('a stopped step with no attempts left is not claimed again',
  not exists (select 1 from jsonb_array_elements(app.worker_claim_listing_jobs('rph-w2', 50) -> 'jobs') e where (e ->> 'id')::uuid = test.rph_job((select fl from rphp))));
update listing_jobs set next_attempt_at = o.next_attempt_at from rph_others o where listing_jobs.id = o.id;

-- ---------------------------------------------------------------- 3. a live listing's finished photos are approved
insert into vehicle_listings (vehicle_id, status, slug) values (test.id('vehicle:rph_car'), 'published', 'rph-car-example')
  on conflict (vehicle_id) do update set status = 'published', slug = coalesce(vehicle_listings.slug, excluded.slug);
-- the intake still running: its photos wait for it (an intake approves its own photos when its last step is done, 0022)
select app.worker_listing_result(test.rph_job((select detail from rphp)), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object(
  'processed_path', 'vehicles/rph/detail.jpg', 'width', 1600, 'height', 1200, 'flags', '[]'::jsonb, 'preset_version', 'normalize_v1')));
select test.eq('a photo of an intake still running stays processed', (select status from vehicle_photos where id = (select detail from rphp)), 'processed');
-- published while its import was still running (Publish now, 0070): the photos finished later go on the site
update listing_intakes set state = 'published' where id = (select i from rphi);
select app.worker_listing_result(test.rph_job((select rear from rphp), 'resize'), jsonb_build_object('ok', true, 'provider', 'fake', 'output', jsonb_build_object('variants', '[]'::jsonb)));
select test.eq('the intake is published: its processed photos are approved',
  (select status from vehicle_photos where id = (select detail from rphp)), 'approved');
select test.ok('its plate not checked: still off the site (0070)', (select not is_public from vehicle_photos where id = (select detail from rphp)));
update vehicle_photos set plate_status = 'not_visible' where id = (select detail from rphp);
select test.ok('marked "no plate visible": on the site', (select is_public from vehicle_photos where id = (select detail from rphp)));
select test.ok('the site shows it, not the samples',
  exists (select 1 from jsonb_array_elements(app.public_listing_photos(test.id('vehicle:rph_car'))) e where e ->> 'path' = 'vehicles/rph/detail.jpg'));
update vehicle_photos set quality_flags = '["watermark"]'::jsonb where id = (select detail from rphp);
select test.ok('a photo flagged for a mark is still kept off the site (0566)', (select not is_public from vehicle_photos where id = (select detail from rphp)));
update vehicle_photos set quality_flags = '[]'::jsonb, is_public = true where id = (select detail from rphp);

-- ---------------------------------------------------------------- 4. the cover: the marked one when public, else an approved public photo
select test.eq('the front-left photo is not approved yet: the detail photo is the cover, not a sample',
  (select (r #>> '{cover,path}') || '/' || (r ->> 'sample_photos') from (select app.public_listing_row(test.id('vehicle:rph_car')) r) x), 'vehicles/rph/detail.jpg/false');
update vehicle_photos set status = 'approved', processed_path = 'vehicles/rph/fl.jpg', plate_status = 'covered', is_public = true where id = (select fl from rphp);
select test.eq('the front-left photo approved and its plate covered: it is the cover',
  (select r #>> '{cover,path}' from (select app.public_listing_row(test.id('vehicle:rph_car')) r) x), 'vehicles/rph/fl.jpg');
select test.ok('the review no longer names each of the 14 shots, and has a cover',
  not exists (select 1 from unnest(app.listing_photo_problems(test.id('vehicle:rph_car'))) x where x like '% photo is not processed and approved' or x = 'No cover photo'));

-- ---------------------------------------------------------------- 5. "Process photos without the resize service": every stuck step
update listing_jobs set status = 'failed', error = 'The worker did not finish within the lock time', finished_at = now(), locked_at = null
 where id = test.rph_job((select fl from rphp));
update listing_intakes set state = 'published' where id = (select i from rphi);
select test.throws('only an Admin presses it', $$select app.listing_photos_reprocess_local(test.id('rph_fleet'))$$);
create temp table rph_rq as select app.listing_photos_reprocess_local(test.id('rph_admin')) r;
select test.ok('a published listing''s failed step is queued again, made here',
  (select status = 'queued' and attempts = 0 and (input ->> 'local_only')::boolean and error is null from listing_jobs where id = test.rph_job((select fl from rphp))));
select test.ok('one open step per photo (never two)',
  (select count(*) = 1 from listing_jobs where vehicle_photo_id = (select fl from rphp) and kind = 'process_photo' and status in ('queued', 'running')));
select test.ok('it is written in the audit log', exists (select 1 from audit_log where action = 'listing_photos_reprocess_local' and actor_user_id = test.id('rph_admin')));
update listing_jobs set status = 'failed', attempts = 3 where id = test.rph_job((select fl from rphp));
update vehicle_photos set replaced_at = now(), is_cover = false where id = (select fl from rphp);
select app.listing_photos_requeue_local(test.id('vehicle:rph_car'));
select test.ok('a step of a photo replaced since is not queued again',
  (select status = 'failed' and attempts = 3 from listing_jobs where id = test.rph_job((select fl from rphp))));

update program_settings set listing_plate_check_required = (select plate from rph_prev), listing_cf_transformations = (select cf from rph_prev) where id = (select id from app.settings());
