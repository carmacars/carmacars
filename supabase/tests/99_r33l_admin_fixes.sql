-- 99: migration 0780 (release 33, part L): the identity review counts what it approves, duplicate expired requests are linked to the
-- newest and hidden from Requests, an owner invoice paid outside the platform sends no email unless asked, and the Drive API key
-- never reaches the audit log or the settings read in full. Fixtures start with "rl"; every address is example.test.
select test.suite('99 r33 admin fixes (0780)');
grant usage on schema test to service_role;

select test.mk_user('rl_admin', 'admin');
select test.mk_user('rl_cs', 'va', 'cs');
select test.mk_owner('rl_o');
select test.mk_vehicle('RLA', 'rl_o');
select test.mk_vehicle('RLB', 'rl_o');
select test.mk_renter('rl_r');
select test.mk_renter('rl_r2');
create function test.rll(p_days integer, p_hour text default '10:00') returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' ' || p_hour $$;

-- ================================================================ 1. the identity review
select test.mk_booking('RL-1', 'RLA', 'rl_r', test.rll(20), test.rll(22), 'confirmed');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
values (test.id('booking:RL-1'), test.id('driver:rl_r'), 'renter', 'Rl R', date '1990-05-05', 'L9', 'G', date '2031-01-01', 36, '26_plus');
select app.register_verification_upload(test.id('booking:RL-1'), test.id('rl_cs'), k, test.id('driver:rl_r'), 'renters/rl/1-' || k || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity')
  from unnest(array['licence_front', 'licence_back', 'selfie']) k;
-- the selfie's file was purged: it cannot be looked at, so it is not counted, not listed and not approved
update documents set purged_at = now() where storage_path = 'renters/rl/1-selfie.jpg';
-- a waiting image of a driver no longer on the booking on the booking: counted, listed (under Other documents) and approved
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
values (test.id('booking:RL-1'), test.id('driver:rl_r2'), 'additional', 'Rl Two', date '1991-06-06', 'L8', 'G', date '2031-01-01', 35, '26_plus');
select app.register_verification_upload(test.id('booking:RL-1'), test.id('rl_cs'), 'licence_front', test.id('driver:rl_r2'), 'renters/rl/1-other.jpg', repeat('d', 64), 'image/jpeg', null, 'identity');
delete from booking_drivers where booking_id = test.id('booking:RL-1') and driver_id = test.id('driver:rl_r2');
select test.eq('review: the counted items are the two of the driver that can be looked at, plus the one of a driver no longer on the booking', (select count(*) from app.doc_review_pending(test.id('booking:RL-1'))), 3::bigint);
select test.eq('review: the read lists the same three as waiting uploads (the purged one is not listed)',
  (select count(*) from jsonb_array_elements(app.doc_review_read(test.id('rl_cs'), jsonb_build_object('booking', 'RL-1')) -> 'uploads') x where x ->> 'status' = 'submitted'), 3::bigint);
create table test.rl_appr as select (x ->> 'approved') || '/' || jsonb_array_length(x -> 'refused') as r
  from app.door(test.id('rl_cs'), 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'RL-1')) x;
select test.eq('review: approve all approves exactly the counted ones (3) and refuses none', (select r from test.rl_appr), '3/0');
select test.eq('review: nothing counted is left waiting, and the purged image is untouched',
  (select count(*) from app.doc_review_pending(test.id('booking:RL-1'))) || '/' || (select status from verification_uploads u join documents d on d.id = u.document_id where d.storage_path = 'renters/rl/1-selfie.jpg'), '0/submitted');

-- ================================================================ 2. duplicate expired requests
select test.mk_booking('RL-D1', 'RLA', 'rl_r2', test.rll(30), test.rll(33), 'expired');
select test.mk_booking('RL-D2', 'RLA', 'rl_r2', test.rll(31), test.rll(34), 'expired');
select test.mk_booking('RL-D3', 'RLA', 'rl_r2', test.rll(32), test.rll(35), 'expired');
select test.mk_booking('RL-E1', 'RLB', 'rl_r2', test.rll(40), test.rll(42), 'expired');
update bookings set created_at = now() - interval '5 days', superseded_by = null where booking_number = 'RL-D1';
update bookings set created_at = now() - interval '3 days', superseded_by = null where booking_number = 'RL-D2';
update bookings set created_at = now() - interval '1 day', superseded_by = null where booking_number = 'RL-D3';
-- an expiry (the status written) links the older ones to the newest
update bookings set status = 'expired' where booking_number = 'RL-D3';
select test.eq('duplicates: the older two expired requests are linked to the newest, which stays',
  (select string_agg(booking_number || '>' || coalesce((select k.booking_number from bookings k where k.id = b.superseded_by), '-'), ',' order by booking_number)
     from bookings b where booking_number in ('RL-D1', 'RL-D2', 'RL-D3')), 'RL-D1>RL-D3,RL-D2>RL-D3,RL-D3>-');
select test.eq('duplicates: another car, or other dates, is not a duplicate', (select superseded_by is null from bookings where booking_number = 'RL-E1'), true);
select test.mk_booking('RL-F1', 'RLA', 'rl_r2', test.rll(60), test.rll(62), 'expired');
select test.eq('duplicates: the same renter and car for other dates is kept (no overlap)', (select superseded_by is null from bookings where booking_number = 'RL-F1'), true);
select test.eq('duplicates: the Requests read leaves the linked ones out', (
  select count(*) from jsonb_array_elements(app.admin_requests(test.id('rl_admin'), '{}'::jsonb)) x where x ->> 'booking_number' in ('RL-D1', 'RL-D2')), 0::bigint);
select test.eq('duplicates: each link is in the audit log', (select count(distinct entity_id) from audit_log where action = 'booking_duplicate_archived' and after ->> 'newer_booking_number' = 'RL-D3'), 2::bigint);
select test.eq('duplicates: no lead is made for a linked offer (0741)', (
  select app.expired_offers_to_leads(now() + interval '30 days') >= 0) and (select count(*) from leads where source = 'expired_offer' and payload ->> 'booking_id' in (test.id('booking:RL-D1')::text, test.id('booking:RL-D2')::text)) = 0, true);

-- ================================================================ 3. paid outside the platform
select app.owner_invoice_draft_save(test.id('rl_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:RLA'), 'kind', 'custom', 'title', 'Tracker bill',
  'lines', '[{"description": "Tracker", "quantity": 1, "unit_amount_cents": 10000, "hst": true}]'::jsonb)) is not null as made;
create table test.rl_inv as select id, invoice_number from owner_invoices where title = 'Tracker bill';
select app.owner_invoice_issue(test.id('rl_admin'), jsonb_build_object('id', (select id from test.rl_inv), 'quiet', true));
select app.record_manual_payment(test.id('rl_admin'), jsonb_build_object('invoice', (select id::text from test.rl_inv), 'method', 'cash', 'receipt', false, 'received_on', app.today()));
select test.eq('paid outside: issued quietly and paid, no invoice email and no receipt email',
  (select status from owner_invoices where id = (select id from test.rl_inv)) || '/'
  || (select count(*) from app_events where payload ->> 'owner_invoice_id' = (select id::text from test.rl_inv) and code in ('owner_invoice_issued', 'owner_payment_recorded', 'owner_payment_received')),
  'paid/0');
select app.owner_invoice_draft_save(test.id('rl_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:RLA'), 'kind', 'custom', 'title', 'Tracker bill 2',
  'lines', '[{"description": "Tracker", "quantity": 1, "unit_amount_cents": 10000, "hst": true}]'::jsonb)) is not null as made;
create table test.rl_inv2 as select id from owner_invoices where title = 'Tracker bill 2';
select app.owner_invoice_issue(test.id('rl_admin'), jsonb_build_object('id', (select id from test.rl_inv2), 'quiet', true));
select app.record_manual_payment(test.id('rl_admin'), jsonb_build_object('invoice', (select id::text from test.rl_inv2), 'method', 'cash', 'received_on', app.today()));
select test.eq('paid outside: without the option the receipt is still sent (the earlier behaviour)',
  (select count(*) from app_events where payload ->> 'owner_invoice_id' = (select id::text from test.rl_inv2) and code = 'owner_payment_recorded'), 1::bigint);

-- ================================================================ 4. the Drive API key
update program_settings set google_drive_api_key = 'AIzaExampleKeyForTestsOnly_0123456789' where id = (select id from app.settings());
select test.eq('key: the audit log has no key, only that it changed',
  (select count(*) from audit_log where entity_table = 'program_settings' and (before::text like '%AIzaExample%' or after::text like '%AIzaExample%')), 0::bigint);
select test.eq('key: the change itself is logged', (select count(*)  from audit_log where entity_table = 'program_settings' and after ->> 'google_drive_api_key' = '[hidden]') >= 1, true);
select app.admin_save(test.id('rl_admin'), 'program_settings', jsonb_build_object('values', jsonb_build_object('turnaround_buffer_minutes', 150)));
select test.eq('key: a new dated row copies it and logs no key',
  (select count(*) from audit_log where entity_table = 'program_settings' and (before::text like '%AIzaExample%' or after::text like '%AIzaExample%')), 0::bigint);
select test.eq('key: the settings read gives the last 4 only',
  (select (x -> 'program' ? 'google_drive_api_key')::text || '/' || (x -> 'program' ->> 'google_drive_api_key_set') || '/' || (x -> 'program' ->> 'google_drive_api_key_last4') || '/' || (x::text like '%AIzaExample%')
     from (select app.admin_settings() x) y), 'false/true/6789/false');
select test.eq('key: the server still reads it whole', app.drive_import_key(), 'AIzaExampleKeyForTestsOnly_0123456789');
update program_settings set google_drive_api_key = null;
select test.eq('key: cleared, the read says not set', (select app.admin_settings() -> 'program' ->> 'google_drive_api_key_set'), 'false');
