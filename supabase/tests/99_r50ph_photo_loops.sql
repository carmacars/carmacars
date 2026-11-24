-- 99: migration 3700 (release 50, photos): a photo step that timed out counts as a try, a refused render keeps its tries,
-- stranded real photos are due again, detail photos are sorted again, and a published car never has an empty gallery.
-- Fixtures start with "rq50p_"; no real names or plates.
select test.suite('99 r50 photo loops (3700)');

create temp table rq50p_prev as select listing_showroom_ai as ai, listing_photo_r48_auto as r48, listing_photo_r45_batch as batch from app.settings();
update program_settings set listing_showroom_ai = true, listing_photo_r48_auto = true, listing_photo_r45_batch = 200
 where id = (select id from app.settings());

select test.mk_user('rq50p_admin', 'admin');
select test.mk_owner('rq50p_olive');
select test.mk_vehicle('rq50p_a', 'rq50p_olive');   -- a real outside photo whose step times out
select test.mk_vehicle('rq50p_b', 'rq50p_olive');   -- only "Other detail" photos (an import the sorter could not read)

create temp table rq50p_i as select
  (app.start_listing_intake(test.id('rq50p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rq50p_a'))) ->> 'intake_id')::uuid as a,
  (app.start_listing_intake(test.id('rq50p_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:rq50p_b'))) ->> 'intake_id')::uuid as b;
create or replace function test.rq50p_up(p_intake uuid, p_shot text) returns uuid language sql as $$
  select (app.record_listing_upload(test.id('rq50p_admin'), p_intake, jsonb_build_object('shot_type', p_shot,
          'original_path', 'vehicles/original/rq50p/' || p_shot || '-' || md5(random()::text) || '.jpg', 'width', 3000, 'height', 2000, 'byte_size', 900000, 'mime_type', 'image/jpeg')) ->> 'photo_id')::uuid $$;
create or replace function test.rq50p_live(p_car text) returns void language sql as $$
  update vehicle_photos set background_status = 'done', status = 'approved', is_public = true, plate_status = 'covered',
         processed_path = coalesce(processed_path, 'vehicles/rq50p/' || p_car || '-' || shot_type || '-' || left(id::text, 6) || '.jpg')
   where vehicle_id = test.id('vehicle:' || p_car) and replaced_at is null;
  update listing_jobs set status = 'succeeded', finished_at = now() where vehicle_id = test.id('vehicle:' || p_car) and status in ('queued', 'running') $$;
-- the worker claimed the step and never answered: the sweep (0024) fails it once its attempts are used
create or replace function test.rq50p_timeout(p_photo uuid) returns void language plpgsql as $$
declare v uuid := (select j.id from listing_jobs j where j.vehicle_photo_id = p_photo and j.kind = 'photo_r45' and j.status in ('queued', 'running') order by j.created_at desc limit 1);
begin
  update listing_jobs set status = 'running', attempts = max_attempts, locked_at = now() - interval '1 hour', locked_by = 'rq50p', started_at = now() where id = v;
  perform app.fail_listing_job(v, 'The worker did not finish within the lock time', false);
end $$;

-- ---------------------------------------------------------------- 1. a timeout counts as a try; three flag the photo
create temp table rq50p_a as select test.rq50p_up((select a from rq50p_i), 'front_left') as fl;
select test.rq50p_live('rq50p_a');
select test.ok('the real photo is queued for its new version', app.photo_r45_queue(null, (select fl from rq50p_a), true));
select test.rq50p_timeout((select fl from rq50p_a));
select test.eq('one timeout: one try, made again later (redo), the reason given',
  (select (r45 ->> 'tries') || '/' || (r45 ->> 'state') || '/' || (r45 -> 'reasons' ->> 0) from vehicle_photos where id = (select fl from rq50p_a)), '1/redo/timed_out');
select test.ok('a timeout of the photo''s step makes it due again (it was stuck as queued before 3700)',
  (select app.photo_r45_due(ph) from vehicle_photos ph where ph.id = (select fl from rq50p_a)));
select app.photo_r45_queue(null, (select fl from rq50p_a), false);
select test.rq50p_timeout((select fl from rq50p_a));
select app.photo_r45_queue(null, (select fl from rq50p_a), false);
select test.rq50p_timeout((select fl from rq50p_a));
select test.eq('the third timeout flags it, on Photo standard with the reason',
  (select (r45 ->> 'tries') || '/' || (r45 ->> 'state') from vehicle_photos where id = (select fl from rq50p_a)), '3/flagged');
select test.ok('a flagged real photo stays on the site as it was (2890)',
  (select is_public and quality_flags ? 'r45_flagged' from vehicle_photos where id = (select fl from rq50p_a)));
select test.ok('a failure the worker reported is not counted twice (only the sweep''s timeout is counted here)',
  position('The worker did not finish' in pg_get_functiondef('app.fail_listing_job(uuid, text, boolean, text, bigint, timestamptz)'::regprocedure)) > 0);

-- ---------------------------------------------------------------- 2. a refused render keeps its tries
select test.ok('photo_r48_queue starts the tries again only for a made or flagged view, or Make again',
  position('in (''redo'', ''done'', ''flagged'')' in pg_get_functiondef('app.photo_r48_queue(uuid, uuid, text, boolean)'::regprocedure)) = 0
  and position('in (''done'', ''flagged'')' in pg_get_functiondef('app.photo_r48_queue(uuid, uuid, text, boolean)'::regprocedure)) > 0);

-- ---------------------------------------------------------------- 3. a stranded real photo is due again
update vehicle_photos set r45 = coalesce(r45, '{}'::jsonb) || jsonb_build_object('state', 'queued', 'spec', app.photo_spec(), 'at', now() - interval '2 hours')
 where id = (select fl from rq50p_a);
update listing_jobs set status = 'failed', finished_at = now() where vehicle_photo_id = (select fl from rq50p_a) and status in ('queued', 'running');
select app.job_photo_r48();
select test.ok('a real photo queued with no step is put back to redo by the job',
  (select r45 ->> 'state' in ('redo', 'queued') and (r45 ->> 'state' = 'queued') = exists (select 1 from listing_jobs j where j.vehicle_photo_id = ph.id and j.kind = 'photo_r45' and j.status = 'queued')
     from vehicle_photos ph where ph.id = (select fl from rq50p_a)));

-- ---------------------------------------------------------------- 4. details sorted again; never an empty gallery
create temp table rq50p_b as select test.rq50p_up((select b from rq50p_i), 'other') as o1, test.rq50p_up((select b from rq50p_i), 'other') as o2;
select test.rq50p_live('rq50p_b');
update vehicle_photos set resort = null where vehicle_id = test.id('vehicle:rq50p_b');
create temp table rq50p_g as select app.public_listing_photos(test.id('vehicle:rq50p_b')) as g;
select test.ok('a car with only detail photos: the gallery is not empty (it was, since 2890)', (select jsonb_array_length(g) > 0 from rq50p_g));
select test.ok('its first photo is a captioned representative photo, the cover',
  (select coalesce((g -> 0 ->> 'sample')::boolean, false) and coalesce((g -> 0 ->> 'is_cover')::boolean, false) from rq50p_g));
select test.eq('then the car''s own photos, never the cover', (select count(*)::text from rq50p_g, jsonb_array_elements(g) e
  where coalesce((e ->> 'real')::boolean, false) and not coalesce((e ->> 'is_cover')::boolean, false)), '2');
select test.eq('only the first photo is the cover', (select count(*)::text from rq50p_g, jsonb_array_elements(g) e where coalesce((e ->> 'is_cover')::boolean, false)), '1');
select test.ok('a car with an outside photo keeps its gallery as before (the real photo first)',
  (select coalesce((g -> 0 ->> 'sample')::boolean, false) = false and jsonb_array_length(g) >= 1 from (select app.public_listing_photos(test.id('vehicle:rq50p_a')) g) x));

select app.job_photo_r48();
select test.eq('the job sorts the detail photos again (2780''s re-sort, gone since 2840)',
  (select count(*)::text from listing_jobs j where j.vehicle_id = test.id('vehicle:rq50p_b') and j.kind = 'photo_resort' and j.status = 'queued'), '2');
select test.ok('the connector counts the detail photos still to sort',
  (select (c ->> 'details_unsorted')::int = 2 and (c ->> 'resorting')::int = 2 from (select app.photo_standard_car(test.id('vehicle:rq50p_b')) c) x));
select app.job_photo_r48();
select test.eq('each detail photo is sorted once per standard', (select count(*)::text from listing_jobs j where j.vehicle_id = test.id('vehicle:rq50p_b') and j.kind = 'photo_resort'), '2');

update program_settings set listing_showroom_ai = p.ai, listing_photo_r48_auto = p.r48, listing_photo_r45_batch = p.batch
  from rq50p_prev p where program_settings.id = (select id from app.settings());
