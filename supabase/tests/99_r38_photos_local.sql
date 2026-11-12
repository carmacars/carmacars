-- 99: "Process photos without the resize service" (2372): Admin only; failed and stuck photo steps are queued again with
-- local_only, a failed listing goes back to processing photos. Fixtures start with "pl".
select test.suite('99 r38 photos without the resize service');
select test.mk_user('pl_admin', 'admin');
select test.mk_user('pl_fleet', 'va', 'fleet');
select test.mk_owner('pl_o');
select test.mk_vehicle('plY', 'pl_o');
insert into vin_decodes (vin, provider, ok, raw, year, make, model) select upper(vin), 'fake', true, '{}', 2023, 'Mercedes-Benz', 'EQE' from vehicles where id = test.id('vehicle:plY');
create temp table pl_s as select app.start_listing_intake(test.id('pl_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:plY'), 'colour', 'Black')) r;
create function test.pl_i() returns uuid language sql as $$ select ((select r from pl_s) ->> 'intake_id')::uuid $$;
select app.record_listing_upload(test.id('pl_admin'), test.pl_i(), jsonb_build_object('shot_type', s.code, 'original_path', 'o/' || s.code || '.jpg'))
  from listing_shot_types s where s.required and s.is_active order by s.seq;
select app.submit_listing_intake(test.id('pl_admin'), test.pl_i());
-- the image service refused: one step failed (the listing failed), one stuck retrying, one running for an hour
update listing_jobs set status = 'failed', attempts = max_attempts, error = 'quota: Image transformations are rate limited or over the month''s allowance', finished_at = now()
 where id = (select id from listing_jobs where intake_id = test.pl_i() and kind = 'process_photo' order by id limit 1);
update listing_jobs set attempts = 2, error = 'quota: rate limited', next_attempt_at = now() + interval '1 hour'
 where id = (select id from listing_jobs where intake_id = test.pl_i() and kind = 'process_photo' and status = 'queued' order by id limit 1);
update listing_jobs set status = 'running', attempts = 1, locked_at = now() - interval '1 hour', locked_by = 'gone'
 where id = (select id from listing_jobs where intake_id = test.pl_i() and kind = 'process_photo' and status = 'queued' and attempts = 0 order by id limit 1);
update listing_intakes set state = 'failed', failed_at = now(), reason = 'A photo step failed' where id = test.pl_i();

select test.throws('only an Admin runs it', $$select app.door(test.id('pl_fleet'), 'aal2', 'admin_do', 'listing_photos_reprocess_local', '{}')$$);
create temp table pl_r as select app.door(test.id('pl_admin'), 'aal2', 'admin_do', 'listing_photos_reprocess_local', '{}') r;
select test.eq('the three steps of the one listing are queued again', (select (r ->> 'steps') || '/' || (r ->> 'listings') from pl_r), '3/1');
select test.eq('each of them now runs without the service, from its first attempt, at once',
  (select count(*) from listing_jobs where intake_id = test.pl_i() and status = 'queued' and attempts = 0 and (input ->> 'local_only')::boolean and next_attempt_at <= now() and error is null), 3::bigint);
select test.eq('the failed listing is back to processing its photos', (select state from listing_intakes where id = test.pl_i()), 'processing_photos');
select test.ok('steps not stuck are left as they were', not exists (select 1 from listing_jobs where intake_id = test.pl_i() and status = 'queued' and attempts = 0 and input ? 'local_only' is false and kind = 'decode_vin' and error is not null));
select test.ok('it is in the audit log', exists (select 1 from audit_log where action = 'listing_photos_reprocess_local' and actor_user_id = test.id('pl_admin')));
