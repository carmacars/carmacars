-- 99: release 50 return gate (migration 4730; live incident CC-10597). An approved licence covers every booking of the
-- driver; the return is never blocked by documents in review or a pickup never recorded. Fixtures start with "rg".
select test.suite('99 r50 return gate');

select test.mk_user('rg_admin', 'admin');
select test.mk_user('rg_fleet', 'va', 'fleet');
select test.mk_owner('rg_o');
select test.mk_vehicle('RGV', 'rg_o');
select test.mk_vehicle('RGW', 'rg_o');
select test.mk_vehicle('RGX', 'rg_o');
select test.mk_renter('rg_r');
select test.mk_renter('rg_s');
update renters set identity_status = 'pending' where id in (test.id('renter:rg_r'), test.id('renter:rg_s'));
update drivers set identity_status = 'pending' where id in (test.id('driver:rg_r'), test.id('driver:rg_s'));
create function test.rg_t(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
create function test.rg_driver(p_number text, p_renter text) returns void language sql as $$
  insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
  values (test.id('booking:' || p_number), test.id('driver:' || p_renter), 'renter', 'Rg Renter', date '1990-05-05', 36, '26_plus') $$;
create function test.rg_docs(p_number text, p_renter text, p_set text, p_status text default 'submitted') returns void language sql as $$
  insert into documents (id, kind, storage_bucket, storage_path, booking_id)
  select test.id('doc:' || p_set || k), case k when 'licence_front' then 'id_front' when 'licence_back' then 'id_back' else 'face_photo' end::document_kind,
         'documents', 'rg/' || p_set || k || '.jpg', test.id('booking:' || p_number)
    from unnest(array['licence_front', 'licence_back', 'selfie']) k
  on conflict (id) do nothing;
  insert into verification_uploads (booking_id, driver_id, kind, document_id, status)
  select test.id('booking:' || p_number), test.id('driver:' || p_renter), k, test.id('doc:' || p_set || k), p_status
    from unnest(array['licence_front', 'licence_back', 'selfie']) k $$;

-- ---------------------------------------------------------------- 1. approve on booking A, booking B shows approved
-- A expired (the renter's first try), B confirmed: the licence set was copied to B while still in review.
select test.mk_booking('RG-A', 'RGV', 'rg_r', test.rg_t(interval '2 days'), test.rg_t(interval '4 days'), 'expired');
select test.mk_booking('RG-B', 'RGW', 'rg_r', test.rg_t(interval '3 days'), test.rg_t(interval '5 days'), 'confirmed');
select test.rg_driver('RG-A', 'rg_r');
select test.rg_driver('RG-B', 'rg_r');
select test.rg_docs('RG-A', 'rg_r', 'a');
select test.rg_docs('RG-B', 'rg_r', 'a');
select test.eq('before: booking B reads the licence in review',
  app.booking_readiness(test.id('booking:RG-B')) ->> 'identity_state', 'in_review');
update verification_uploads set status = 'approved', reviewed_by = test.id('rg_fleet'), reviewed_at = now()
 where booking_id = test.id('booking:RG-A');
select test.eq('approved on A: the same photos on B are approved too',
  (select string_agg(status, ',' order by kind) from verification_uploads where booking_id = test.id('booking:RG-B')), 'approved,approved,approved');
select test.ok('approved on A: booking B''s driver is verified',
  (select identity_verified_on is not null from booking_drivers where booking_id = test.id('booking:RG-B') and role = 'renter'));
select test.eq('approved on A: booking B reads verified and asks for no licence',
  (app.booking_readiness(test.id('booking:RG-B')) ->> 'identity_state') || '/'
  || (select count(*) from jsonb_array_elements_text(app.licence_status(test.id('booking:RG-B'), test.id('driver:rg_r')) -> 'missing') m where m like '%licence%' or m like '%selfie%'),
  'verified/0');
-- a later booking with no uploads of its own: covered by the driver's approved set while the licence is valid
select test.mk_booking('RG-B2', 'RGX', 'rg_r', test.rg_t(interval '10 days'), test.rg_t(interval '12 days'), 'confirmed');
select test.rg_driver('RG-B2', 'rg_r');
select app.booking_driver_verify_sync(test.id('booking:RG-B2'));
select test.eq('a new booking of the same driver is verified from the approved set',
  app.booking_readiness(test.id('booking:RG-B2')) ->> 'identity_state', 'verified');
update drivers set licence_expiry = (now() + interval '11 days')::date where id = test.id('driver:rg_r');
update booking_drivers set identity_verified_on = null where booking_id = test.id('booking:RG-B2');
select app.booking_driver_verify_sync(test.id('booking:RG-B2'));
select test.ok('but not past the licence''s expiry',
  (select identity_verified_on is null from booking_drivers where booking_id = test.id('booking:RG-B2')));
update drivers set licence_expiry = date '2030-01-01' where id = test.id('driver:rg_r');

-- ---------------------------------------------------------------- 2. return with docs in review and no recorded pickup
select test.mk_booking('RG-C', 'RGX', 'rg_s', test.rg_t(- interval '1 day'), test.rg_t(interval '1 day'), 'confirmed');
select test.rg_driver('RG-C', 'rg_s');
select test.rg_docs('RG-C', 'rg_s', 'c');
create function test.rg_photo(p text) returns jsonb language sql stable as $$
  select jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.id('booking:' || p) || '/return-claim/' || gen_random_uuid() || '.jpg') $$;
select test.ok('the link page lets the renter report it', (public.server_return_claim_read((select return_link_token from bookings where id = test.id('booking:RG-C'))) ->> 'can_report')::boolean);
create temp table rg_c as select public.server_return_claim_submit((select return_link_token from bookings where id = test.id('booking:RG-C')),
  jsonb_build_object('returned_at', now() - interval '10 minutes', 'odometer_km', 30500, 'fuel_pct', 75,
                     'photos', jsonb_build_array(test.rg_photo('RG-C'), test.rg_photo('RG-C'), test.rg_photo('RG-C'))),
  (select user_id from renters where id = test.id('renter:rg_s'))) r;
select test.ok('the return is taken (not refused for documents, deposit, coverage or agreement)', (select r ->> 'status' from rg_c) in ('completed', 'pending'), (select r::text from rg_c));
select test.eq('the pickup is recorded at the booked time',
  (select handed_over_at = pickup_at from bookings where id = test.id('booking:RG-C')), true);
select test.eq('the trip is completed with the renter''s readings',
  (select r ->> 'status' from rg_c) || '/' || (select status::text from bookings where id = test.id('booking:RG-C')), 'completed/returned');
select test.ok('the pickup is marked not recorded at the time (audited override, used)',
  exists (select 1 from booking_overrides where booking_id = test.id('booking:RG-C') and action = 'pickup' and status = 'used' and payload ->> 'source' = 'renter_return')
  and exists (select 1 from condition_reports where booking_id = test.id('booking:RG-C') and kind = 'pickup' and (recorded_now ->> 'not_recorded_at_the_time')::boolean));
select test.ok('Fleet has the To do with what is still owed',
  exists (select 1 from tasks where booking_id = test.id('booking:RG-C') and task_type = 'pickup_not_recorded' and queue = 'fleet'
           and detail like '%licence and selfie are not reviewed%' and detail like '%deposit%'));
select test.ok('Fleet has the To do to review the documents', exists (select 1 from tasks where booking_id = test.id('booking:RG-C') and task_type = 'docs_review_after_return'));
select test.ok('Admin and Fleet are alerted', exists (select 1 from app_events where entity_id = test.id('booking:RG-C') and code like 'staff_alert_%' and payload ->> 'rule' = 'pickup_not_recorded'));
select test.ok('the booking''s history says so', exists (select 1 from booking_events where booking_id = test.id('booking:RG-C') and note like 'Pickup not recorded at the time%'));

-- ---------------------------------------------------------------- 3. staff one tap, and its limits
select test.mk_booking('RG-D', 'RGV', 'rg_s', test.rg_t(- interval '2 hours'), test.rg_t(interval '2 days'), 'confirmed');
select test.rg_driver('RG-D', 'rg_s');
select test.eq('staff: record pickup at the booked time in one tap',
  public.door(test.id('rg_fleet'), null, 'ops_do', 'pickup_record_booked_time', jsonb_build_object('booking', 'RG-D')) ->> 'booking_status', 'on_rent');
select test.ok('staff: at the booked time', (select handed_over_at = pickup_at from bookings where id = test.id('booking:RG-D')));
select test.eq('staff: a second tap changes nothing',
  public.door(test.id('rg_fleet'), null, 'ops_do', 'pickup_record_booked_time', jsonb_build_object('booking', 'RG-D')) ->> 'status', 'skipped');
select test.mk_booking('RG-E', 'RGW', 'rg_s', test.rg_t(interval '20 days'), test.rg_t(interval '22 days'), 'confirmed');
select test.throws('staff: not before the booked pickup time',
  $$select public.door(test.id('rg_fleet'), null, 'ops_do', 'pickup_record_booked_time', jsonb_build_object('booking', 'RG-E'))$$, 'once that time has passed');
select test.throws('a renter cannot record it from the staff door',
  $$select public.door((select user_id from renters where id = test.id('renter:rg_s')), null, 'ops_do', 'pickup_record_booked_time', jsonb_build_object('booking', 'RG-E'))$$);
select test.ok('privileges: only the database calls the pickup function',
  not has_function_privilege('authenticated', 'app.pickup_record_booked_time(uuid, uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public.server_return_claim_submit(uuid, jsonb, uuid)', 'execute'));
