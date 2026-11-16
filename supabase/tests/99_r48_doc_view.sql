-- 99: a reviewed renter document stays viewable to the staff who review it (migration 3071,
-- docs/changes/2026-11-15-r48-reviewed-documents.md). Admin and customer service view every kind at any status, Sales the
-- licence and the selfie; owners and other staff are refused; each view is in the audit log; a purged document answers
-- "removed on" and is still listed by the review reads. Fixtures start with "dv".
select test.suite('99 r48 reviewed documents view');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('dv_admin', 'admin');
select test.mk_user('dv_cs', 'va', 'cs');
select test.mk_user('dv_sales', 'va', 'sales');
select test.mk_user('dv_fleet', 'va', 'fleet');
select test.mk_owner('dv_o');
select test.mk_vehicle('DVA', 'dv_o');
select test.mk_renter('dv_r');
create function test.dvb() returns uuid language sql stable as $$ select test.id('booking:DV-1') $$;
select test.mk_booking('DV-1', 'DVA', 'dv_r', to_char((now() at time zone 'America/Toronto')::date + 3, 'YYYY-MM-DD') || ' 10:00',
  to_char((now() at time zone 'America/Toronto')::date + 5, 'YYYY-MM-DD') || ' 10:00', 'confirmed');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
values (test.dvb(), test.id('driver:dv_r'), 'renter', 'Dv R', date '1990-05-05', 'L1', 'G', date '2031-01-01', 36, '26_plus');
update bookings set coverage_option = 1 where id = test.dvb();
create table test.dvup as
  select k.kind, app.register_verification_upload(test.dvb(), test.id('dv_cs'), k.kind, test.id('driver:dv_r'),
           'renters/dv/' || k.kind || '-' || gen_random_uuid() || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity') as id
    from unnest(array['licence_front', 'licence_back', 'selfie']) k(kind);
select app.register_verification_upload(test.dvb(), test.id('dv_cs'), 'coverage_proof', null, 'renters/dv/p1.pdf', md5('dv-p1'), 'application/pdf',
  jsonb_build_object('coverage_option', 1, 'insurer_name', 'Maple Mutual', 'policy_number', 'MM-7', 'policy_expiry', app.today() + 60));
create function test.dvup(p_kind text) returns uuid language sql stable as $$
  select coalesce((select id from test.dvup where kind = p_kind), (select id from verification_uploads where booking_id = test.dvb() and kind = p_kind)) $$;
create function test.dv_view(p_user text, p_kind text, p_call text default 'ops_read') returns jsonb language sql as $$
  select app.door(test.id(p_user), 'aal2', p_call, 'doc_view', jsonb_build_object('upload', test.dvup(p_kind))) $$;

-- approve the front, reject the selfie (the review as it happens), the back stays waiting
select app.review_verification_upload(test.dvup('licence_front'), test.id('dv_admin'), true, null);
select app.review_verification_upload(test.dvup('selfie'), test.id('dv_admin'), false, 'The face is not visible');

-- ================================================================ 1. who views
select test.eq('Admin views an approved licence: the file to sign, its type',
  (select (x ->> 'status') || '/' || (x ->> 'mime_type') || '/' || (x ->> 'bucket' is not null) || '/' || (x ->> 'path' like 'renters/dv/licence_front-%') from test.dv_view('dv_admin', 'licence_front') x),
  'approved/image/jpeg/true/true');
select test.eq('customer service views a rejected selfie', (select x ->> 'status' from test.dv_view('dv_cs', 'selfie') x), 'rejected');
select test.eq('customer service views a page of the proof of coverage (pink slip, OPCF 27)', (select x ->> 'mime_type' from test.dv_view('dv_cs', 'coverage_proof') x), 'application/pdf');
select test.eq('Sales view the licence and the selfie, from the office''s and the assistants'' screens',
  (select (test.dv_view('dv_sales', 'licence_front') ->> 'status') || '/' || (test.dv_view('dv_sales', 'selfie', 'va_read') ->> 'status')), 'approved/rejected');
select test.throws('fleet staff are refused', $$select test.dv_view('dv_fleet', 'licence_front')$$, 'Only the staff who review');
select test.throws('the car''s owner is refused (owners never see renter documents)', $$select test.dv_view('dv_o', 'licence_front')$$, null);
select test.throws('an unknown document', $$select app.door(test.id('dv_admin'), 'aal2', 'ops_read', 'doc_view', '{"upload": "00000000-0000-0000-0000-000000000000"}')$$, 'Document not found');

-- ================================================================ 2. every view is logged
select test.eq('audit log: one line per view, naming the document, the booking, the kind and the status',
  (select count(*) || '/' || bool_and(a.after ->> 'booking' = 'DV-1') || '/' || bool_and(a.entity_table = 'documents')
     from audit_log a where a.action = 'document_view' and a.actor_user_id = test.id('dv_admin')), '1/true/true');
select test.eq('data access log: the view is an opening of the renter''s data',
  (select count(*) from data_access_log where user_id = test.id('dv_cs') and reason like 'viewed selfie (rejected), booking DV-1'), 1::bigint);
select test.eq('a refused view writes nothing', (select count(*) from audit_log where action = 'document_view' and actor_user_id = test.id('dv_fleet')), 0::bigint);

-- ================================================================ 3. after the 90-day purge
update documents set purged_at = now() - interval '1 day'
 where id = (select document_id from verification_uploads where id = test.dvup('licence_front'));
select test.eq('a purged document answers the day it was removed, and no file',
  (select (x ->> 'removed_on' = app.local_date(now() - interval '1 day')::text) || '/' || (x ? 'bucket') || '/' || (x ? 'path') from test.dv_view('dv_admin', 'licence_front') x), 'true/false/false');
select test.eq('the review read still lists it, with purged_at and no file',
  (select (u ->> 'purged_at' is not null) || '/' || (u ? 'bucket') || '/' || (u ->> 'status')
     from jsonb_array_elements(app.door(test.id('dv_admin'), 'aal2', 'ops_read', 'doc_review', '{"booking": "DV-1"}') -> 'uploads') u
    where u ->> 'id' = test.dvup('licence_front')::text), 'true/false/approved');
select test.eq('the review read lists each document once (three live, one purged)',
  (select count(*) || '/' || count(distinct u ->> 'id') from jsonb_array_elements(app.door(test.id('dv_admin'), 'aal2', 'ops_read', 'doc_review', '{"booking": "DV-1"}') -> 'uploads') u), '3/3');
select test.eq('Sales'' read lists the purged licence too', (select count(*) from jsonb_array_elements(app.door(test.id('dv_sales'), 'aal2', 'ops_read', 'doc_review', '{"booking": "DV-1"}') -> 'uploads') u
    where u ->> 'purged_at' is not null), 1::bigint);

-- ================================================================ 4. the server's call only
reset role;
set role authenticated;
select test.throws('authenticated: doc_view is the server''s call only', format($$select app.doc_view(%L, jsonb_build_object('upload', %L))$$, test.id('dv_admin'), test.dvup('selfie')), null);
select test.throws('authenticated: nor the rule', format($$select app.doc_view_can(%L, %L)$$, test.id('dv_admin'), test.dvup('selfie')), null);
reset role;
