-- 99: what a booking still needs from the renter (migration 1203): the items by status of the booking, each with its
-- status (missing, review, rejected with the reason, done) and one action; the renter's reads carry it and only for
-- their own booking; the reminders' "Still missing" names the same items. Fixtures "hv"; example.test only.
select test.suite('99 r35h still needed');

select test.mk_user('hv_admin', 'admin');
select test.mk_owner('hv_o');
select test.mk_vehicle('HVA', 'hv_o');
select test.mk_vehicle('HVB', 'hv_o');
select test.mk_renter('hv_rita');
select test.mk_renter('hv_ivan');
update renters set address_line1 = null where id = test.id('renter:hv_rita');
update renters set address_line1 = '1 Example St' where id = test.id('renter:hv_ivan');

create or replace function test.hv_items(p_number text) returns text language sql stable as $$
  select string_agg(split_part(i ->> 'key', ':', 1) || '=' || (i ->> 'status'), ' ' order by n)
    from jsonb_array_elements(app.renter_still_needed(test.id('booking:' || p_number)) -> 'items') with ordinality x(i, n) $$;

-- a confirmed booking: two drivers, card coverage, a deposit not held yet
select test.mk_booking('CC-HV1', 'HVA', 'hv_rita', to_char(now() at time zone 'America/Toronto' + interval '9 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '12 days', 'YYYY-MM-DD 10:00'), 'confirmed');
update bookings set coverage_option = 2 where id = test.id('booking:CC-HV1');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:CC-HV1'), test.id('driver:hv_rita'), 'renter', 'Hv Rita', date '1990-05-05', 36, '26_plus'),
       (test.id('booking:CC-HV1'), test.id('driver:hv_ivan'), 'additional', 'Hv Ivan', date '1990-05-05', 36, '26_plus');

select test.eq('confirmed, nothing sent: the details, the signature and payment done, each driver''s licence and selfie, the second driver''s acceptance, coverage and the deposit',
  test.hv_items('CC-HV1'),
  'dob=done address=missing signature=done payment=done licence=missing selfie=missing licence=missing selfie=missing accept=missing coverage=missing deposit=review');
select test.eq('an item has its one action', (select i -> 'action' from jsonb_array_elements(app.renter_still_needed(test.id('booking:CC-HV1')) -> 'items') i where i ->> 'key' = 'coverage'),
  '{"label": "Send it", "path": "verify"}'::jsonb);
select test.eq('a done item has none', (select i -> 'action' from jsonb_array_elements(app.renter_still_needed(test.id('booking:CC-HV1')) -> 'items') i where i ->> 'key' = 'dob'), 'null'::jsonb);
select test.eq('the count: done of total, not complete', (select (s ->> 'done') || '/' || (s ->> 'total') || '/' || (s ->> 'complete') from app.renter_still_needed(test.id('booking:CC-HV1')) s), '3/11/false');

-- uploads: submitted is under review, rejected says why, approved is done
insert into documents (id, kind, storage_bucket, storage_path, booking_id) values
  (test.id('doc:hv_f'), 'id_front', 'documents', 'hv/f.jpg', test.id('booking:CC-HV1')), (test.id('doc:hv_b'), 'id_back', 'documents', 'hv/b.jpg', test.id('booking:CC-HV1')),
  (test.id('doc:hv_s'), 'face_photo', 'documents', 'hv/s.jpg', test.id('booking:CC-HV1')), (test.id('doc:hv_c'), 'coverage_proof', 'documents', 'hv/c.pdf', test.id('booking:CC-HV1'));
insert into verification_uploads (booking_id, driver_id, kind, document_id, status, reject_reason, reviewed_by, reviewed_at) values
  (test.id('booking:CC-HV1'), test.id('driver:hv_rita'), 'licence_front', test.id('doc:hv_f'), 'submitted', null, null, null),
  (test.id('booking:CC-HV1'), test.id('driver:hv_rita'), 'licence_back', test.id('doc:hv_b'), 'submitted', null, null, null),
  (test.id('booking:CC-HV1'), test.id('driver:hv_rita'), 'selfie', test.id('doc:hv_s'), 'rejected', 'The licence is not readable in the photo', test.id('hv_admin'), now()),
  (test.id('booking:CC-HV1'), null, 'coverage_proof', test.id('doc:hv_c'), 'approved', null, test.id('hv_admin'), now());
select test.eq('the renter''s licence under review, their selfie rejected, coverage done',
  (select string_agg(i ->> 'status', ' ' order by n) from jsonb_array_elements(app.renter_still_needed(test.id('booking:CC-HV1')) -> 'items') with ordinality x(i, n)
    where i ->> 'key' in ('licence:' || test.id('driver:hv_rita'), 'selfie:' || test.id('driver:hv_rita'), 'coverage')), 'review rejected done');
select test.eq('a rejected item says why and offers to send it again',
  (select (i ->> 'reason') || '/' || (i #>> '{action,label}') from jsonb_array_elements(app.renter_still_needed(test.id('booking:CC-HV1')) -> 'items') i
    where i ->> 'key' = 'selfie:' || test.id('driver:hv_rita')), 'The licence is not readable in the photo/Take it again');
update booking_drivers set identity_method = 'staff_review', identity_verified_on = current_date where booking_id = test.id('booking:CC-HV1') and driver_id = test.id('driver:hv_rita');
select test.eq('a driver verified by staff: licence and selfie done', (select string_agg(i ->> 'status', ' ') from jsonb_array_elements(app.renter_still_needed(test.id('booking:CC-HV1')) -> 'items') i
    where i ->> 'key' in ('licence:' || test.id('driver:hv_rita'), 'selfie:' || test.id('driver:hv_rita'))), 'done done');

-- the Protection Plan needs no proof
select test.mk_booking('CC-HV2', 'HVB', 'hv_ivan', to_char(now() at time zone 'America/Toronto' + interval '20 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '22 days', 'YYYY-MM-DD 10:00'), 'confirmed');
update bookings set coverage_option = 3 where id = test.id('booking:CC-HV2');
select test.ok('the Protection Plan: no proof of coverage to send', test.hv_items('CC-HV2') not like '%coverage=%');
select test.ok('the address on file is done', test.hv_items('CC-HV2') like '%address=done%');

-- a closed booking needs nothing
select test.mk_booking('CC-HV3', 'HVB', 'hv_ivan', '2026-01-10 10:00', '2026-01-12 10:00', 'closed');
select test.eq('closed: nothing to show', (select (s ->> 'total') || '/' || (s ->> 'complete') from app.renter_still_needed(test.id('booking:CC-HV3')) s), '0/true');

-- the renter's reads carry it, for their own booking only
select test.ok('the renter''s own booking read carries it',
  (select (public.my_booking('CC-HV1') -> 'still_needed' ->> 'total') is not null from (select set_config('request.jwt.claims', jsonb_build_object('sub', test.id('hv_rita'), 'role', 'authenticated')::text, true)) c));
select test.eq('another renter gets nothing', (select app.my_still_needed(test.id('booking:CC-HV1'))
  from (select set_config('request.jwt.claims', jsonb_build_object('sub', test.id('hv_ivan'), 'role', 'authenticated')::text, true)) c), null::jsonb);
select set_config('request.jwt.claims', '', true);

-- the reminders name the same items
select test.ok('"Still missing" lists the items not done, as the checklist names them',
  (select x ->> 'needed_items' like '%your home address%' and x ->> 'needed_items' like '%a selfie of Hv Ivan%' and x ->> 'needed_items' not like '%date of birth%'
     from app.ntf_booking(test.id('booking:CC-HV1')) x));
