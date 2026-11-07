-- 99: the driver's licence reader (migration 0602, docs/changes/2026-11-07-licence-reader.md): each read recorded, the
-- checks (expiry, class, age, the driver's name and date of birth, the Ontario number, front and back, the photo), the
-- driver's empty fields filled, automatic approval when every check passes (off by default), and the main driver's
-- Ontario licence: the swap to additional driver, the pickup blocked, a new main driver, an Admin's undo and override.
-- Fixtures start with "lic"; fake people, fake numbers, example.test only.
select test.suite('99 licence reader');
select test.mk_user('lic_admin', 'admin');
select test.mk_user('lic_sales', 'va', 'sales');
select test.mk_owner('lic_olga');
select test.mk_vehicle('LICCAR', 'lic_olga');
select test.mk_vehicle('LICCAR2', 'lic_olga');
select test.mk_renter('lic_rita');
select test.mk_renter('lic_quinn');
select test.mk_booking('LIC-1', 'LICCAR', 'lic_rita', '2031-03-02 10:00', '2031-03-05 10:00', 'confirmed');
select test.mk_booking('LIC-2', 'LICCAR2', 'lic_quinn', '2031-04-02 10:00', '2031-04-05 10:00', 'confirmed');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:LIC-1'), test.id('driver:lic_rita'), 'renter', 'Lic Rita', date '1990-05-05', 40, '26_plus'),
       (test.id('booking:LIC-2'), test.id('driver:lic_quinn'), 'renter', 'Lic Quinn', date '1990-05-05', 41, '26_plus');
update drivers set licence_number = null, licence_class = null, licence_issuer = null, licence_expiry = null where id = test.id('driver:lic_rita');

create or replace function test.lic_read(p_booking text, p_driver text, p jsonb) returns jsonb language sql as $$
  select app.licence_read_record(jsonb_build_object('booking_id', test.id('booking:' || p_booking), 'driver_id', test.id('driver:' || p_driver)) || p) $$;
create or replace function test.lic_check(p_booking text, p_driver text, p_key text) returns text language sql stable as $$
  select (c ->> 'ok') || coalesce(': ' || (c ->> 'detail'), '') from jsonb_array_elements(app.licence_checks(test.id('booking:' || p_booking), test.id('driver:' || p_driver))) c
   where c ->> 'key' = p_key $$;

-- ================================================================ the Ontario number (pure)
select test.eq('Ontario: a letter and 14 digits, the family name''s letter, the date of birth last (month + 50 too)',
  app.ontario_licence_check('R1234-56789-00505', 'Rita', date '1990-05-05')::text || ' ' || app.ontario_licence_check('R1234-56789-05505', 'Rita', date '1990-05-05')::text
  || ' ' || app.ontario_licence_check('X1234-56789-00506', 'Rita', date '1990-05-05')::text || ' ' || app.ontario_licence_check('R1234-5678-00505', 'Rita', date '1990-05-05')::text,
  '{"birth": true, "format": true, "letter": true} {"birth": true, "format": true, "letter": true} {"birth": false, "format": true, "letter": false} {"birth": null, "format": false, "letter": null}');

-- ================================================================ a good Ontario licence: every check passes
create temp table lic_r1 as select test.lic_read('LIC-1', 'lic_rita', '{"side": "licence_back", "source": "barcode", "quality": "ok", "first_name": "Lr", "last_name": "Rita",
  "full_name": "Lic Rita", "date_of_birth": "1990-05-05", "licence_number": "R1234-56789-00505", "licence_class": "G", "issued_on": "2024-05-05",
  "expires_on": "2032-05-05", "issuer": "ON", "country": "CAN"}'::jsonb) r;
select test.ok('the back''s barcode: every check passes', (select (r ->> 'all_pass')::boolean from lic_r1), (select r::text from lic_r1));
select test.eq('the driver''s empty licence fields are filled from the read',
  (select licence_number || '/' || licence_class || '/' || licence_issuer || '/' || licence_expiry from drivers where id = test.id('driver:lic_rita')), 'R1234-56789-00505/G/ON/2032-05-05');
select test.eq('it never names another driver''s fields', (select licence_number from drivers where id = test.id('driver:lic_quinn')), (select 'L' || upper(substr(md5('lic_quinn'), 1, 14))));

-- ================================================================ each flag
select test.lic_read('LIC-1', 'lic_rita', '{"side": "licence_front", "source": "vision", "quality": "blurry", "model": "fake"}'::jsonb);
select test.eq('a blurry front: flagged, the renter was asked to take it again', test.lic_check('LIC-1', 'lic_rita', 'photo'), 'false: The front is blurry: the renter was asked to take it again');
select test.lic_read('LIC-1', 'lic_rita', '{"side": "licence_front", "source": "vision", "quality": "ok", "last_name": "Rita", "date_of_birth": "1990-05-05",
  "licence_number": "R1234-56789-00599", "expires_on": "2031-03-03", "issuer": "ON", "model": "fake"}'::jsonb);
select test.eq('front and back not the same licence', test.lic_check('LIC-1', 'lic_rita', 'front_back'), 'false');
update licence_reads set expires_on = '2031-03-03' where driver_id = test.id('driver:lic_rita') and source = 'barcode';
select test.eq('expires before the return', test.lic_check('LIC-1', 'lic_rita', 'expiry'), 'false: Expires Mon, Mar 3, 2031, before the return Wed, Mar 5, 2031');
update licence_reads set expires_on = '2031-01-01' where driver_id = test.id('driver:lic_rita') and source = 'barcode';
select test.eq('expired', test.lic_check('LIC-1', 'lic_rita', 'expiry'), 'false: Expired on Wed, Jan 1, 2031');
update licence_reads set licence_class = 'G1' where driver_id = test.id('driver:lic_rita') and source = 'barcode';
select test.eq('a class not accepted', test.lic_check('LIC-1', 'lic_rita', 'class'), 'false: Class G1 (accepted: G, G2)');
update licence_reads set date_of_birth = '2015-05-05' where driver_id = test.id('driver:lic_rita') and source = 'barcode';
select test.ok('under the minimum age at pickup', test.lic_check('LIC-1', 'lic_rita', 'age') like 'false: 15 at pickup');
select test.ok('the date of birth is not the driver''s', test.lic_check('LIC-1', 'lic_rita', 'match') like 'false: Licence %, booking Sat, May 5, 1990');
update licence_reads set date_of_birth = '1990-05-05', last_name = 'Someone' where driver_id = test.id('driver:lic_rita') and source = 'barcode';
select test.eq('the name is not the driver''s', test.lic_check('LIC-1', 'lic_rita', 'match'), 'false: Licence Lic Rita, booking Lic Rita');
update licence_reads set last_name = 'Rita', licence_number = 'R1234-56789-00506' where driver_id = test.id('driver:lic_rita') and source = 'barcode';
select test.eq('the Ontario number does not carry the date of birth', test.lic_check('LIC-1', 'lic_rita', 'ontario_number'), 'false: The last six digits are not the date of birth');

-- ================================================================ automatic approval: off by default
select test.eq('off by default', (select licence_auto_approve::text || '/' || licence_primary_ontario::text from app.settings()), 'false/true');
select test.throws('only an Admin turns it on', format($$select app.door(%L, 'aal2', 'ops_do', 'licence_settings', '{"auto_approve": true}')$$, test.id('lic_sales')), '');

-- an Admin turns it on: both sides read sharp and whole and every check passing, the photos are approved in their name
select test.mk_renter('lic_vera');
select test.mk_vehicle('LICCAR4', 'lic_olga');
select test.mk_booking('LIC-4', 'LICCAR4', 'lic_vera', '2031-06-02 10:00', '2031-06-05 10:00', 'confirmed');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:LIC-4'), test.id('driver:lic_vera'), 'renter', 'Lic Vera', date '1990-05-05', 41, '26_plus');
insert into documents (id, kind, title, storage_bucket, storage_path, mime_type, retention, booking_id)
values (test.id('doc:lic4f'), 'id_front', 'Licence front', 'identity', 'lic/4f.jpg', 'image/jpeg', 'id_face_90d', test.id('booking:LIC-4')),
       (test.id('doc:lic4b'), 'id_back', 'Licence back', 'identity', 'lic/4b.jpg', 'image/jpeg', 'id_face_90d', test.id('booking:LIC-4'));
insert into verification_uploads (booking_id, driver_id, kind, document_id)
values (test.id('booking:LIC-4'), test.id('driver:lic_vera'), 'licence_front', test.id('doc:lic4f')), (test.id('booking:LIC-4'), test.id('driver:lic_vera'), 'licence_back', test.id('doc:lic4b'));
select app.door(test.id('lic_admin'), 'aal2', 'admin_do', 'licence_settings', '{"auto_approve": true}');
select test.lic_read('LIC-4', 'lic_vera', '{"side": "licence_back", "source": "barcode", "quality": "ok", "last_name": "Vera", "full_name": "Lic Vera", "date_of_birth": "1990-05-05",
  "licence_number": "V1234-56789-00505", "licence_class": "G", "expires_on": "2033-05-05", "issuer": "ON"}'::jsonb);
select test.eq('one side read: nothing approved yet', (select count(*) from verification_uploads where booking_id = test.id('booking:LIC-4') and status = 'approved'), 0::bigint);
select test.lic_read('LIC-4', 'lic_vera', '{"side": "licence_front", "source": "vision", "quality": "ok", "last_name": "Vera", "date_of_birth": "1990-05-05", "issuer": "ON", "model": "fake"}'::jsonb);
select test.eq('both sides read and every check passing: approved automatically, in the Admin''s name',
  (select count(*) || '/' || bool_and(reviewed_by = test.id('lic_admin'))::text from verification_uploads where booking_id = test.id('booking:LIC-4') and status = 'approved'), '2/true');
select app.door(test.id('lic_admin'), 'aal2', 'admin_do', 'licence_settings', '{"auto_approve": false}');

-- ================================================================ the main driver's Ontario licence
select test.lic_read('LIC-2', 'lic_quinn', '{"side": "licence_back", "source": "barcode", "quality": "ok", "last_name": "Quinn", "date_of_birth": "1990-05-05",
  "licence_number": "Q1234567", "licence_class": "D", "expires_on": "2033-01-01", "issuer": "NY", "country": "USA"}'::jsonb);
select test.eq('a main driver with a New York licence becomes an additional driver (the upload and checks kept)',
  (select role from booking_drivers where booking_id = test.id('booking:LIC-2') and driver_id = test.id('driver:lic_quinn')) || '/' || app.primary_ontario_needed(test.id('booking:LIC-2'))::text
  || '/' || (select count(*) from licence_reads where booking_id = test.id('booking:LIC-2'))::text, 'additional/true/1');
select test.eq('the booking says so', (app.booking_readiness(test.id('booking:LIC-2')) ->> 'primary_ontario_needed') || '/' || (app.booking_readiness(test.id('booking:LIC-2')) ->> 'ready_for_handover'), 'true/false');
update booking_drivers set identity_verified_on = date '2031-03-01' where booking_id = test.id('booking:LIC-2');
select test.throws('pickup is blocked until it is met', $$update bookings set status = 'on_rent' where id = test.id('booking:LIC-2')$$, 'Primary driver: Ontario licence needed');
select test.eq('the check line', test.lic_check('LIC-2', 'lic_quinn', 'ontario_primary'), 'false: Issued by NY');
-- the renter adds a main driver
select test.throws('the new main driver needs a date of birth', format($$select public.renter_primary_driver_add(%L, %L, '{"full_name": "Ona Main", "email": "ona@example.test"}')$$,
  test.id('booking:LIC-2'), test.id('lic_quinn')), 'date of birth');
create temp table lic_add as select public.renter_primary_driver_add(test.id('booking:LIC-2'), test.id('lic_quinn'),
  '{"full_name": "Ona Main", "email": "ona@example.test", "mobile": "+16475550111", "date_of_birth": "1992-02-02"}') r;
select test.eq('the new main driver is on the booking as the main driver; the first stays as an additional driver',
  (select string_agg(full_name || ':' || role, ',' order by role desc) from booking_drivers where booking_id = test.id('booking:LIC-2')), 'Ona Main:renter,Lic Quinn:additional');
select test.ok('still needed until their Ontario licence is read', app.primary_ontario_needed(test.id('booking:LIC-2')));
select app.licence_read_record(jsonb_build_object('booking_id', test.id('booking:LIC-2'), 'driver_id', (select (r ->> 'driver_id')::uuid from lic_add),
  'side', 'licence_back', 'source', 'barcode', 'quality', 'ok', 'last_name', 'Main', 'date_of_birth', '1992-02-02', 'licence_number', 'M1234-56789-20202',
  'licence_class', 'G', 'expires_on', '2033-02-02', 'issuer', 'ON'));
select test.eq('the new main driver''s Ontario licence settles it: pickup can go ahead',
  app.primary_ontario_needed(test.id('booking:LIC-2'))::text || '/' || (select state from booking_primary_swaps where booking_id = test.id('booking:LIC-2')), 'false/resolved');

-- the agreement opened after the swap: the account holder signs as the renter, the new main driver on their own link as
-- the primary driver, nobody twice
insert into documents (id, kind, title, storage_bucket, storage_path, mime_type, retention, booking_id)
values (test.id('doc:lic-ag'), 'rental_agreement', 'Rental agreement', 'agreements', 'lic/ag.pdf', 'application/pdf', 'records_7y', test.id('booking:LIC-2'));
insert into signature_requests (id, document_id, provider, provider_envelope, status) values (test.id('sr:lic'), test.id('doc:lic-ag'), 'builtin', 'lic', 'sent');
insert into rental_agreements (id, booking_id, agreement_number, template_version, document_id, document_sha256, signature_request_id, countersigner_name)
values (test.id('ag:lic'), test.id('booking:LIC-2'), 'RA-LIC-2', 't', test.id('doc:lic-ag'), repeat('0', 64), test.id('sr:lic'), 'Staff');
insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, signer_name)
select test.id('ag:lic'), 'renter', d.id, d.driver_id, d.full_name from booking_drivers d where d.booking_id = test.id('booking:LIC-2') and d.role = 'renter';
insert into rental_agreement_signers (agreement_id, signer_role, booking_driver_id, driver_id, signer_name)
select test.id('ag:lic'), 'additional_driver', d.id, d.driver_id, d.full_name from booking_drivers d where d.booking_id = test.id('booking:LIC-2') and d.role = 'additional';
select test.eq('the agreement: the account holder signs as the renter, the new main driver as the primary driver, nobody twice',
  (select string_agg(signer_role || ':' || coalesce((select full_name from drivers where id = x.driver_id), '?') || ':' || is_primary_driver::text, ',' order by signer_role desc)
     from rental_agreement_signers x where agreement_id = test.id('ag:lic')), 'renter:Lic Quinn:false,additional_driver:Ona Main:true');
-- what the renter sees, and confirms
select test.eq('the renter sees the licence read for them to confirm',
  (select (d ->> 'read') || '/' || coalesce(d ->> 'confirmed_at', 'none') from jsonb_array_elements(public.renter_licence_read(test.id('booking:LIC-1'), test.id('lic_rita')) -> 'drivers') d), 'true/none');
select public.renter_licence_confirm(test.id('booking:LIC-1'), test.id('lic_rita'), test.id('driver:lic_rita'));
select test.ok('confirmed', (select licence_read_confirmed_at is not null from drivers where id = test.id('driver:lic_rita')));
select test.throws('only the booking''s renter', format($$select public.renter_licence_read(%L, %L)$$, test.id('booking:LIC-1'), test.id('lic_quinn')), 'Not permitted');

-- an Admin: undo, or let it go with a reason
select test.mk_renter('lic_ursa');
select test.mk_vehicle('LICCAR3', 'lic_olga');
select test.mk_booking('LIC-3', 'LICCAR3', 'lic_ursa', '2031-05-02 10:00', '2031-05-05 10:00', 'confirmed');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
values (test.id('booking:LIC-3'), test.id('driver:lic_ursa'), 'renter', 'Lic Ursa', date '1990-05-05', 41, '26_plus');
select test.lic_read('LIC-3', 'lic_ursa', '{"side": "licence_back", "source": "barcode", "quality": "ok", "last_name": "Ursa", "date_of_birth": "1990-05-05", "issuer": "QC"}'::jsonb);
select test.throws('only an Admin decides', format($$select app.door(%L, 'aal2', 'ops_do', 'primary_swap_decide', %L)$$, test.id('lic_sales'),
  jsonb_build_object('booking', test.id('booking:LIC-3'), 'action', 'undo')), '');
select test.throws('letting it go needs a reason', format($$select app.door(%L, 'aal2', 'admin_do', 'primary_swap_decide', %L)$$, test.id('lic_admin'),
  jsonb_build_object('booking', test.id('booking:LIC-3'), 'action', 'override')), 'Say why');
select app.door(test.id('lic_admin'), 'aal2', 'admin_do', 'primary_swap_decide', jsonb_build_object('booking', test.id('booking:LIC-3'), 'action', 'override', 'reason', 'Moving to Ontario, licence exchange booked'));
select test.eq('overridden: the main driver back, pickup free, never moved again by a later read',
  (select role from booking_drivers where booking_id = test.id('booking:LIC-3') and driver_id = test.id('driver:lic_ursa')) || '/' || app.primary_ontario_needed(test.id('booking:LIC-3'))::text, 'renter/false');
select test.lic_read('LIC-3', 'lic_ursa', '{"side": "licence_front", "source": "vision", "quality": "ok", "last_name": "Ursa", "issuer": "QC"}'::jsonb);
select test.eq('a later read leaves the decision', (select role from booking_drivers where booking_id = test.id('booking:LIC-3') and driver_id = test.id('driver:lic_ursa')), 'renter');

-- ================================================================ staff only, the image's retention
select test.ok('signed-in users reach the reads only through the admin policy', (select count(*) = 1 from pg_policies where tablename = 'licence_reads'));
select test.ok('the server''s door is the service key''s', not has_function_privilege('authenticated', 'public.server_licence_read_record(jsonb)', 'execute'));
insert into documents (id, kind, title, storage_bucket, storage_path, mime_type, retention, booking_id)
values (test.id('doc:lic'), 'id_back', 'Licence back', 'identity', 'lic/back.jpg', 'image/jpeg', 'id_face_90d', test.id('booking:LIC-1'));
update licence_reads set document_id = test.id('doc:lic') where booking_id = test.id('booking:LIC-1') and source = 'barcode';
update documents set purged_at = now(), storage_path = null where id = test.id('doc:lic');
select test.eq('the read goes with its image', (select count(*) from licence_reads where document_id = test.id('doc:lic')), 0::bigint);
select test.ok('the audit log never has the number', not exists (select 1 from audit_log where entity_table = 'licence_reads' and (coalesce(before::text, '') || coalesce(after::text, '')) like '%R1234-56789%'));
