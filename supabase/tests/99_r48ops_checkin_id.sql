-- 99: release 48, operations screens (3292, 3293): the pickup identity check. The photos taken at the pickup are kept with
-- the booking's licence documents and never touch the identity check on file; the check compares the licence and the
-- card shown with what is on file, flags Fleet and Admin on a mismatch, marks the booking and goes into the dispute pack.
-- docs/changes/2026-11-20-r48-ops-screens.md. Fixtures start with "ci" and use example.test only.
select test.suite('99 r48 ops: the pickup identity check');

select test.mk_user('ci_admin', 'admin');
select test.mk_user('ci_field', 'field');
select test.mk_user('ci_cs', 'va', 'cs');
select test.mk_user('ci_fin', 'va', 'finance');
select test.mk_owner('ci_olga');
select test.mk_vehicle('ci_car', 'ci_olga');
select test.mk_renter('ci_rita');
select test.mk_renter('ci_other');
select test.mk_booking('CI-1', 'ci_car', 'ci_rita', to_char(now() at time zone 'America/Toronto' + interval '2 hours', 'YYYY-MM-DD HH24:MI'), to_char(now() at time zone 'America/Toronto' + interval '3 days', 'YYYY-MM-DD HH24:MI'), 'confirmed');
select test.mk_booking('CI-2', 'ci_car', 'ci_other', to_char(now() at time zone 'America/Toronto' + interval '20 days', 'YYYY-MM-DD HH24:MI'), to_char(now() at time zone 'America/Toronto' + interval '22 days', 'YYYY-MM-DD HH24:MI'), 'requested');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry)
select b.id, test.id('driver:ci_rita'), 'renter', 'Ci Rita', date '1990-05-05', 'L1234', 'G', 'ON', date '2030-01-01' from bookings b where b.booking_number = 'CI-1'
on conflict do nothing;
-- the renter's identity is verified, with an approved licence front on file
insert into documents (id, kind, title, storage_bucket, storage_path, mime_type, retention, renter_id, booking_id)
values (test.id('ci_doc'), 'id_front', 'Licence, front: Ci Rita', 'identity', 'ci/front.jpg', 'image/jpeg', 'id_face_90d', test.id('renter:ci_rita'), test.id('booking:CI-1'));
insert into verification_uploads (id, booking_id, driver_id, kind, document_id, status, reviewed_by, reviewed_at)
values (test.id('ci_up'), test.id('booking:CI-1'), test.id('driver:ci_rita'), 'licence_front', test.id('ci_doc'), 'approved', test.id('ci_admin'), now());
update booking_drivers set identity_verified_on = current_date, identity_method = 'staff_review' where booking_id = test.id('booking:CI-1') and driver_id = test.id('driver:ci_rita');

create temp table ci as select null::text as k, null::uuid as id limit 0;
create or replace function pg_temp.photo(p_by text, p_booking text, p_side text, p_path text) returns uuid language sql as $$
  select public.server_checkin_id_photo(test.id(p_by), jsonb_build_object('booking', test.id('booking:' || p_booking), 'side', p_side, 'path', p_path, 'mime', 'image/jpeg', 'sha256', repeat('a', 64)))
$$;

-- who may add it, and when
select test.throws('ID photo: not someone else''s renter', $$select pg_temp.photo('ci_other', 'CI-1', 'front', 'ci/x.jpg')$$, 'Only the staff handing the car over');
select test.throws('ID photo: not office staff who do not hand cars over', $$select pg_temp.photo('ci_fin', 'CI-1', 'front', 'ci/x.jpg')$$, 'Only the staff handing the car over');
select test.throws('ID photo: front, back or selfie only', $$select pg_temp.photo('ci_field', 'CI-1', 'card', 'ci/x.jpg')$$, 'front or the back');
select test.throws('ID photo: at the pickup, not on a request', $$select pg_temp.photo('ci_other', 'CI-2', 'front', 'ci/x.jpg')$$, 'taken at the pickup');
select test.throws('ID photo: needs its file', $$select pg_temp.photo('ci_field', 'CI-1', 'front', '')$$, 'key of its file');

-- field staff take the front; the renter adds the back from the self check-in
insert into ci select 'front', pg_temp.photo('ci_field', 'CI-1', 'front', 'checkin/ci/front-1.jpg');
insert into ci select 'back', pg_temp.photo('ci_rita', 'CI-1', 'back', 'checkin/ci/back-1.jpg');
select test.eq('ID photo: kept as a record of its own kind, for the renter of the booking',
  (select string_agg(u.kind || '/' || u.status || '/' || (u.driver_id = test.id('driver:ci_rita')), ', ' order by u.kind) from verification_uploads u where u.id in (select id from ci)),
  'licence_back_pickup/at_pickup/true, licence_front_pickup/at_pickup/true');
select test.eq('ID photo: stored with the ID images (private bucket, purged with them)',
  (select d.kind || '/' || d.storage_bucket || '/' || d.retention || '/' || (d.purge_after > now() + interval '80 days') || '/' || d.title
     from documents d join verification_uploads u on u.document_id = d.id where u.id = (select id from ci where k = 'front')),
  'id_front/identity/id_face_90d/true/Licence at pickup, front: Ci Rita');

-- it never touches the identity check: the approved licence stays approved, the driver stays verified, nothing waits
select test.eq('ID photo: the approved licence on file stays approved', (select status from verification_uploads where id = test.id('ci_up')), 'approved');
select test.ok('ID photo: the driver stays verified', (select identity_verified_on is not null from booking_drivers where booking_id = test.id('booking:CI-1') and driver_id = test.id('driver:ci_rita')));
select test.eq('ID photo: nothing waits for review', (select count(*) from app.doc_review_pending(test.id('booking:CI-1'))), 0::bigint);
select test.eq('ID photo: no identity check was opened or reset',
  (select count(*) from identity_verifications where booking_id = test.id('booking:CI-1') and status = 'pending'), 0::bigint);

-- a retake replaces the earlier pickup photo of that side, nothing else
insert into ci select 'front2', pg_temp.photo('ci_field', 'CI-1', 'front', 'checkin/ci/front-2.jpg');
select test.eq('ID photo: a retake replaces the earlier pickup photo',
  (select string_agg(u.status, ',' order by u.uploaded_at, u.id) from verification_uploads u where u.booking_id = test.id('booking:CI-1') and u.kind = 'licence_front_pickup'), 'replaced,at_pickup');
select test.eq('ID photo: the approved licence is still there after a retake', (select status from verification_uploads where id = test.id('ci_up')), 'approved');
select test.throws('ID photo: a record is never a review status', $$update verification_uploads set status = 'submitted' where kind = 'licence_front_pickup' and status = 'at_pickup'$$, 'verification_uploads_pickup_status');
select test.throws('ID photo: a licence upload is never "at pickup"', format($$update verification_uploads set status = 'at_pickup' where id = %L$$, test.id('ci_up')), 'verification_uploads');

-- where staff review IDs: listed with the booking's uploads, and opened with View (logged)
select test.eq('review: an Admin sees the pickup photos with the licence',
  (select string_agg(u ->> 'kind', ',' order by u ->> 'kind') from jsonb_array_elements(app.door(test.id('ci_admin'), 'aal2', 'ops_read', 'doc_review', jsonb_build_object('booking', test.id('booking:CI-1'))) -> 'uploads') u),
  'licence_back_pickup,licence_front,licence_front_pickup');
select test.eq('review: customer service too', (select count(*) from jsonb_array_elements(app.door(test.id('ci_cs'), 'aal2', 'ops_read', 'doc_review', jsonb_build_object('booking', test.id('booking:CI-1'))) -> 'uploads') u where u ->> 'status' = 'at_pickup'), 2::bigint);
select test.eq('review: View opens the file for the reviewer',
  (select v ->> 'path' from app.door(test.id('ci_admin'), 'aal2', 'ops_read', 'doc_view', jsonb_build_object('upload', (select id from ci where k = 'front2'))) v), 'checkin/ci/front-2.jpg');
select test.ok('review: the view is logged', exists (select 1 from audit_log where action = 'document_view' and actor_user_id = test.id('ci_admin') and after ->> 'kind' = 'licence_front_pickup'));
select test.throws('review: Finance may not view it', format($$select app.door(%L, 'aal2', 'ops_read', 'doc_view', jsonb_build_object('upload', %L::uuid))$$, test.id('ci_fin'), (select id from ci where k = 'front2')), 'review');

-- the dispute pack carries them with the licence images
insert into dispute_packs (booking_id, status) values (test.id('booking:CI-1'), 'queued');
select test.eq('dispute pack: the pickup photos are with the licence images',
  (select string_agg((l ->> 'kind') || ':' || (l ->> 'status'), ', ' order by l ->> 'kind')
     from jsonb_array_elements(public.server_dispute_evidence((select id from dispute_packs where booking_id = test.id('booking:CI-1'))) -> 'licence') l),
  'licence_back_pickup:taken at pickup, licence_front:approved, licence_front_pickup:taken at pickup');
select test.ok('server only', not has_function_privilege('anon', 'public.server_checkin_id_photo(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_checkin_id_photo(uuid, jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.server_checkin_id_photo(uuid, jsonb)', 'execute'));

-- ================================================================ the check (3293)
insert into payment_methods (id, renter_id, card_brand, card_last4, cardholder_name) values (test.id('ci_card'), test.id('renter:ci_rita'), 'visa', '4242', 'Ci Rita');
update bookings set card_on_file_id = test.id('ci_card') where id = test.id('booking:CI-1');
create or replace function pg_temp.chk(p_by text, p jsonb) returns jsonb language sql as $$
  select public.server_pickup_identity_record(test.id(p_by), jsonb_build_object('booking', test.id('booking:CI-1')) || p)
$$;
select test.throws('check: not someone else''s renter', $$select pg_temp.chk('ci_other', '{}')$$, 'Only the staff handing the car over');
select test.throws('check: not Finance', $$select pg_temp.chk('ci_fin', '{}')$$, 'Only the staff handing the car over');

-- everything agrees: a match, no flag
create temp table ck as select 'ok'::text as k, pg_temp.chk('ci_field', jsonb_build_object('id_upload', (select id from ci where k = 'front2'),
  'read', jsonb_build_object('name', 'RITA, CI', 'number', 'l-1234', 'expiry', '2030-01-01'), 'face', 'same', 'card', jsonb_build_object('last4', 'yes', 'name', 'yes'))) as v;
select test.eq('check: everything agrees', (select (v ->> 'outcome') || ' ' || (v -> 'results')::text from ck where k = 'ok'),
  'match {"face": "match", "name": "match", "expiry": "match", "number": "match", "card_name": "match", "card_last4": "match"}');
select test.eq('check: a match raises nothing', (select count(*) from tasks where booking_id = test.id('booking:CI-1') and task_type like 'pickup%'), 0::bigint);
select test.ok('check: a match leaves the booking unmarked', not app.pickup_identity_marked(test.id('booking:CI-1')));
select test.eq('check: only the last four digits are kept', (select card_last4 from pickup_identity_checks where id = (select (v ->> 'id')::uuid from ck where k = 'ok')), '4242');
select test.throws('check: never a card number', $$update pickup_identity_checks set card_last4 = '4242424242424242'$$, 'pickup_identity_checks_last4');

-- nothing could be read and the face is unsure: unclear, no flag, nothing stopped
insert into ck select 'unsure', pg_temp.chk('ci_rita', jsonb_build_object('face', 'unsure', 'card', jsonb_build_object('last4', 'no')));
select test.eq('check: unsure is not a mismatch (and a renter cannot answer for the card)', (select (v ->> 'outcome') || ' ' || (v #>> '{results,card_last4}') from ck where k = 'unsure'), 'unclear not_checked');
select test.eq('check: unsure raises nothing', (select count(*) from tasks where booking_id = test.id('booking:CI-1') and task_type like 'pickup%'), 0::bigint);

-- a different person: the name, the number and the face differ, the licence expired
insert into ck select 'bad', pg_temp.chk('ci_field', jsonb_build_object('read', jsonb_build_object('name', 'Sam Other', 'number', 'Z9999', 'expiry', '2020-02-02'), 'face', 'different'));
select test.eq('check: a mismatch on each thing compared', (select (v ->> 'outcome') || ' ' || jsonb_array_length(v -> 'mismatches') || ' ' || (v #>> '{results,card_name}') from ck where k = 'bad'), 'mismatch 5 mismatch');
select test.eq('check: Fleet and Admin are told at once, urgently',
  (select string_agg(queue || ':' || priority || ':' || title, ', ' order by queue) from tasks where booking_id = test.id('booking:CI-1') and task_type = 'pickup_identity'),
  'admin:urgent:Possible wrong person at pickup: CI-1, fleet:urgent:Possible wrong person at pickup: CI-1');
select test.ok('check: the booking is marked', app.pickup_identity_marked(test.id('booking:CI-1')));
select test.ok('check: the staff alert went out', exists (select 1 from app_events e where e.payload ->> 'rule' = 'pickup_wrong_person'));
select test.eq('check: it never stops the pickup (the booking and the driver are as they were)',
  (select b.status::text || '/' || (d.identity_verified_on is not null) from bookings b join booking_drivers d on d.booking_id = b.id where b.id = test.id('booking:CI-1')), 'confirmed/true');
select test.eq('check: a second mismatch does not pile up To do''s',
  (select count(*) from (select pg_temp.chk('ci_field', '{"face": "different"}')) x, tasks t where t.booking_id = test.id('booking:CI-1') and t.task_type = 'pickup_identity'), 2::bigint);

-- the card: not the last four on file; and on a card-coverage rental a card in another name is a coverage problem
update bookings set coverage_option = 2 where id = test.id('booking:CI-1');
insert into ck select 'card', pg_temp.chk('ci_field', jsonb_build_object('card', jsonb_build_object('last4', 'no', 'name', 'no')));
select test.eq('check: the card shown is not the card on file', (select (v #>> '{results,card_last4}') || ' ' || (v #>> '{results,card_name}') || ' ' || (v ->> 'coverage_problem') from ck where k = 'card'), 'mismatch mismatch true');
select test.eq('check: raised as a coverage problem', (select count(*) from tasks where booking_id = test.id('booking:CI-1') and task_type = 'pickup_card_coverage' and queue = 'admin' and priority = 'urgent'), 1::bigint);

-- what the screens show
select test.eq('view: staff see the card on file and the mark',
  (select (v #>> '{card,brand}') || ' ' || (v #>> '{card,last4}') || ' ' || (v #>> '{card,name}') || ' ' || (v ->> 'marked') || ' ' || (v #>> '{last,outcome}') || ' ' || (v ->> 'booking_name' is not null)
     from public.server_pickup_identity_view(test.id('ci_field'), test.id('booking:CI-1')) v), 'visa 4242 Ci Rita true mismatch true');
select test.eq('view: the pickup photo beside the licence on file',
  (select (d #>> '{on_file,0,kind}') || ' ' || jsonb_array_length(d -> 'at_pickup') from jsonb_array_elements(public.server_pickup_identity_view(test.id('ci_admin'), test.id('booking:CI-1')) -> 'drivers') d limit 1), 'licence_front 2');
select test.eq('view: the renter sees no card, no reasons and no mark',
  (select (v -> 'card')::text || ' ' || (v #>> '{last,mismatches}') || ' ' || (v ->> 'marked') from public.server_pickup_identity_view(test.id('ci_rita'), test.id('booking:CI-1')) v), 'null [] false');
select test.ok('view: nobody else', public.server_pickup_identity_view(test.id('ci_other'), test.id('booking:CI-1')) is null and public.server_pickup_identity_view(test.id('ci_fin'), test.id('booking:CI-1')) is null);
select test.eq('source: the face on file, for the server', (select v ->> 'path' from public.server_pickup_identity_source(test.id('ci_field'), test.id('booking:CI-1'), test.id('driver:ci_rita')) v), 'ci/front.jpg');
select test.ok('source: not for someone else', public.server_pickup_identity_source(test.id('ci_other'), test.id('booking:CI-1'), test.id('driver:ci_rita')) is null);

-- the mark goes when Fleet and Admin have dealt with it
update tasks set status = 'done', completed_at = now() where booking_id = test.id('booking:CI-1') and task_type like 'pickup%';
select test.ok('mark: gone once the To do''s are done', not app.pickup_identity_marked(test.id('booking:CI-1')));

-- evidence
select test.eq('dispute pack: every check, with its outcome',
  (select string_agg(c ->> 'outcome', ',' order by c ->> 'at') from jsonb_array_elements(public.server_dispute_evidence((select id from dispute_packs where booking_id = test.id('booking:CI-1'))) -> 'pickup_identity') c),
  'match,unclear,mismatch,mismatch,mismatch');
select test.ok('checks: RLS on, and the functions are for the server only', (select relrowsecurity from pg_class where relname = 'pickup_identity_checks')
  and not has_function_privilege('authenticated', 'public.server_pickup_identity_record(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.server_pickup_identity_view(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_pickup_identity_source(uuid, uuid, uuid)', 'execute'));
