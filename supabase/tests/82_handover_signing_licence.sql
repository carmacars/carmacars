-- 82: check-out and check-in by any staff, the return settlement, signing on the spot and the licence (migration 0130,
-- docs/changes/2026-10-24-handover-signing-licence.md). Uses the request helpers of 06 (test.rq_new, test.b) and the
-- operations helpers of 09 (test.op_confirm, test.op_photos, test.op_deposit_payment). Fixtures start with "ho".
select test.suite('82 handover, signing on the spot, licence');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.eq('settings: the licence switch, the selfie, the return charges and the refill price are on by default',
  (select string_agg(column_default, '/' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('booking_licence_selfie_required')), 'true');
-- helpers.sql turned three of them off for the earlier suites; this suite turns them on
update program_settings set booking_licence_required = true, booking_return_auto_charges = true, statement_fuel_cents_per_eighth = 1000;

select test.mk_user('ho_admin', 'admin');
select test.mk_user('ho_cs', 'va', 'cs');
select test.mk_user('ho_sales', 'va', 'sales');
select test.mk_user('ho_fleet', 'va', 'fleet');
select test.mk_user('ho_fin', 'va', 'finance');
select test.mk_user('ho_field', 'field', null, 'driver');
select test.mk_user('ho_field2', 'field', null, 'driver');
select test.mk_owner('ho_o');
select test.mk_vehicle('HOV', 'ho_o');
select test.mk_vehicle('HOW', 'ho_o');
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area) values (test.id('vehicle:HOW'), 'ho-test', 'Handover test car', 'published', 'Leslieville');
select test.mk_renter('ho_r');
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (test.id('trk:HOV'), 'HO-TRK-1', test.id('vehicle:HOV'), 'installed', now(), now());
insert into tracker_status (tracker_device_id, reported_at, speed_kmh, ignition_on) values (test.id('trk:HOV'), now(), 0, false);

-- ---------------------------------------------------------------- 1. the licence before the offer is accepted
create function test.ho_req(p_key text, p_email text, p_name text, p_days integer, p_drivers jsonb default '[]') returns jsonb language sql stable as $$
  select jsonb_build_object(
    'request_key', 'ho-key-' || p_key, 'vehicle_id', test.id('vehicle:HOW'),
    'pickup_at', date_trunc('day', now() + make_interval(days => p_days)) + interval '15 hours',
    'return_at', date_trunc('day', now() + make_interval(days => p_days + 3)) + interval '15 hours',
    'booking_type', 'standard', 'coverage_option', 2,
    'renter', jsonb_build_object('full_name', p_name, 'date_of_birth', '1990-05-05', 'email', p_email, 'mobile', '416-555-0142', 'licence_class', 'G', 'licence_issuer', 'ON'),
    'additional_drivers', p_drivers,
    'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 't', 'text', 'I agree.'),
                                   'privacy', jsonb_build_object('accepted', true, 'version', 'p', 'text', 'I agree.')))
$$;
create table test.ho (k text primary key, v uuid);
grant select on test.ho to authenticated, service_role;
insert into test.ho select 'a', (app.submit_booking_request(test.ho_req('a', 'ana.ho@example.test', 'Ana Licence', 40,
  '[{"full_name": "Dee Driver", "date_of_birth": "1988-02-02", "email": "dee.ho@example.test", "licence_class": "G"}]')) ->> 'booking_id')::uuid;
create function test.hob(p text) returns uuid language sql stable as $$ select v from test.ho where k = p $$;
create function test.hou(p text) returns uuid language sql stable security definer as $$
  select r.user_id from public.bookings b join public.renters r on r.id = b.renter_id where b.id = test.hob(p) $$;
create function test.hod(p text, p_role text default 'renter') returns uuid language sql stable security definer as $$
  select driver_id from public.booking_drivers where booking_id = test.hob(p) and role = p_role limit 1 $$;
create function test.ho_up(p text, p_kind text, p_driver uuid, p_by uuid) returns uuid language sql as $$
  select app.register_verification_upload(test.hob(p), p_by, p_kind, p_driver, 'renters/ho/' || p || '-' || p_kind || '-' || gen_random_uuid() || '.jpg',
                                          repeat('e', 64), 'image/jpeg', null, 'identity') $$;

select test.eq('licence: the request is missing it (front, back, selfie, expiry)',
  array_to_string(app.licence_gate(test.hob('a')), ', '), 'licence front, licence back, selfie with the licence, licence expiry date');
select app.send_offer(test.hob('a'), test.id('ho_cs'));
select test.throws('licence: the renter cannot accept the offer without it',
  $$select public.renter_approve_offer(test.hob('a'), 1, test.hou('a'))$$, 'Upload the driver''s licence before accepting the offer');
select test.throws('licence: nor staff on the renter''s word',
  $$select app.approve_offer(test.hob('a'), 1, test.id('ho_cs'))$$, 'Upload the driver''s licence');
select test.lives('licence: the images are uploaded while the request or the offer is open',
  $$select test.ho_up('a', 'licence_front', test.hod('a'), test.hou('a')); select test.ho_up('a', 'licence_back', test.hod('a'), test.hou('a'));
    select test.ho_up('a', 'selfie', test.hod('a'), test.hou('a'))$$);
select test.throws('licence: the coverage proof still waits for the approved offer',
  $$select app.register_verification_upload(test.hob('a'), test.hou('a'), 'coverage_proof', null, 'x/y.pdf', repeat('e', 64), 'application/pdf', '{"coverage_option": 2}', 'documents')$$,
  'once the offer is approved');
select test.eq('licence: only the expiry date is missing now', array_to_string(app.licence_gate(test.hob('a')), ', '), 'licence expiry date');
select public.renter_save_details(test.hou('a'), jsonb_build_object('licence_number', 'A1234-12345-12345', 'licence_issuer', 'ON', 'licence_class', 'G',
  'licence_expiry', (now() + interval '3 years')::date), test.hob('a'));
select test.lives('licence: with it on file the offer is accepted', $$select public.renter_approve_offer(test.hob('a'), 1, test.hou('a'))$$);
select test.eq('licence: the booking waits for payment, the payment facts say nothing is missing',
  (select status::text from bookings where id = test.hob('a')) || '/' || (public.server_booking_payment_facts(test.hob('a')) ->> 'licence_missing'), 'pending_payment/[]');
select test.eq('licence: the renter''s page reads each image''s state',
  (select d -> 'licence' ->> 'licence_front' || '/' || (d -> 'licence' ->> 'complete') from jsonb_array_elements(public.server_licence_state(test.hob('a'), test.hou('a')) -> 'drivers') d
    where d ->> 'role' = 'renter'), 'submitted/true');
select test.eq('licence: the additional driver''s is not asked of the renter', (select (d -> 'licence' ->> 'complete') from jsonb_array_elements(public.server_licence_state(test.hob('a'), test.hou('a')) -> 'drivers') d
    where d ->> 'role' = 'additional'), 'false');

-- approved by staff, then reused on the next booking of the same driver
select app.review_verification_upload(u.id, test.id('ho_cs'), true, null) from verification_uploads u where u.booking_id = test.hob('a') and u.driver_id = test.hod('a') and u.status = 'submitted';
insert into test.ho select 'b', (app.submit_booking_request(test.ho_req('b', 'ana.ho@example.test', 'Ana Licence', 80)) ->> 'booking_id')::uuid;
create temp table ho_gate_b as select app.licence_gate(test.hob('b')) as m;
select test.eq('licence: the next request of the same renter reuses it, verified, with nothing missing',
  (select array_to_string(m, ', ') from ho_gate_b) || '/' || (select count(*) from verification_uploads where booking_id = test.hob('b') and status = 'approved')
    || '/' || (select (identity_verified_on is not null)::text from booking_drivers where booking_id = test.hob('b') and role = 'renter')
    || '/' || (select count(*) from booking_events where booking_id = test.hob('b') and kind = 'licence_reused'), '/3/true/1');
select test.eq('licence: the files are kept until this rental''s retention',
  (select bool_and(d.purge_after >= (select return_at from bookings where id = test.hob('b'))) from documents d
    join verification_uploads u on u.document_id = d.id where u.booking_id = test.hob('b')), true);
update drivers set licence_expiry = (select app.local_date(return_at) from bookings where id = test.hob('b')) - 1 where id = test.hod('a');
update booking_drivers set licence_expiry = null where driver_id = test.hod('a');
insert into test.ho select 'c', (app.submit_booking_request(test.ho_req('c', 'ana.ho@example.test', 'Ana Licence', 120)) ->> 'booking_id')::uuid;
create temp table ho_gate_c as select app.licence_gate(test.hob('c')) as m;
select test.eq('licence: a licence that expires before the return is not reused',
  (select count(*) from verification_uploads where booking_id = test.hob('c'))::text || '/' || ((select array_to_string(m, ', ') from ho_gate_c) like '%valid after the return date%'), '0/true');
update drivers set licence_expiry = (now() + interval '3 years')::date where id = test.hod('a');

set session_replication_role = replica;
update bookings set added_by_staff = true where id = test.hob('c');
set session_replication_role = origin;
select test.eq('licence: a rental added by hand is not an offer accepted: not asked', cardinality(app.licence_gate(test.hob('c'))), 0);
set session_replication_role = replica;
update bookings set added_by_staff = false where id = test.hob('c');
set session_replication_role = origin;
update program_settings set booking_licence_required = false;
select test.eq('licence: the switch off asks nothing', cardinality(app.licence_gate(test.hob('c'))), 0);
update program_settings set booking_licence_required = true;

-- ---------------------------------------------------------------- 2. signing on the spot
select public.renter_open_agreement(test.hob('a'), test.hou('a'), 'rental-test', repeat('a', 64), 'bookings/ho-a/x.pdf');
create function test.ho_signer(p text, p_role text) returns uuid language sql stable security definer as $$
  select g.id from rental_agreement_signers g join rental_agreements a on a.id = g.agreement_id
   where a.booking_id = test.hob(p) and a.status in ('open', 'signed', 'completed') and g.signer_role = p_role limit 1 $$;
create function test.ho_consents() returns jsonb language sql immutable as $$
  select '[{"code":"tracking_disabling","version":"v","text":"t"},{"code":"identity_verification","version":"v","text":"t"},{"code":"electronic_signature","version":"v","text":"t"},{"code":"card_authorization","version":"v","text":"t"}]'::jsonb $$;
create temp table ho_link as select public.door(test.id('ho_cs'), null, 'ops_do', 'signing_link_send', jsonb_build_object('booking', test.hob('a'), 'channel', 'email')) ->> 'sent' as e,
  public.door(test.id('ho_cs'), null, 'ops_do', 'signing_link_send', jsonb_build_object('booking', test.hob('a'), 'channel', 'text')) ->> 'status' as t;
select test.eq('link: staff email the renter the signing link (the "Sign your rental agreement" email again) or text it',
  (select e || '/' || t from ho_link) || '/' || (select count(*) from phone_outbox where booking_id = test.hob('a') and body like '%/account/bookings/%/sign'), 'true/queued/1');
select test.eq('in person: the hand-over screen lists the renter and the additional driver, unsigned',
  (select string_agg(s ->> 'role' || ':' || coalesce(s ->> 'signed_at', '-'), ',' order by s ->> 'role')
     from jsonb_array_elements(public.door(test.id('ho_sales'), null, 'ops_read', 'in_person_signing', jsonb_build_object('booking', test.hob('a'))) -> 'signers') s),
  'additional_driver:-,renter:-');
select test.throws('in person: Finance does not collect signatures',
  format($$select public.door(%L, null, 'ops_read', 'in_person_signing', jsonb_build_object('booking', %L))$$, test.id('ho_fin'), test.hob('a')), 'Not permitted');
select test.throws('in person: the name and the original licence are confirmed first',
  format($$select public.door(%L, null, 'ops_do', 'sign_in_person', jsonb_build_object('booking', %L, 'signer', %L, 'typed_name', 'Ana Licence', 'sha', %L,
    'consent_text', 'I sign.', 'consents', test.ho_consents(), 'identity', jsonb_build_object('name_confirmed', true)))$$,
    test.id('ho_sales'), test.hob('a'), test.ho_signer('a', 'renter'), repeat('a', 64)), 'original licence');
select test.lives('in person: Sales collects the renter''s signature on their device',
  format($$select public.door(%L, null, 'ops_do', 'sign_in_person', jsonb_build_object('booking', %L, 'signer', %L, 'typed_name', 'Ana Licence', 'sha', %L,
    'consent_text', 'I sign.', 'consents', test.ho_consents(), 'device', 'Front desk iPad', 'ip', '203.0.113.9', 'user_agent', 'test',
    'identity', jsonb_build_object('name_confirmed', true, 'licence_seen', true)))$$,
    test.id('ho_sales'), test.hob('a'), test.ho_signer('a', 'renter'), repeat('a', 64)));
select test.eq('in person: the same signature record as remote signing, noting who collected it and on which device',
  (select s.signer_role || '/' || s.method || '/' || (s.collected_in_person_by = test.id('ho_sales'))::text || '/' || s.collected_device || '/' || (s.identity_check ->> 'licence_seen')
     from signature_records s join rental_agreement_signers g on g.signature_record_id = s.id where g.id = test.ho_signer('a', 'renter'))
  || '/' || (select status from rental_agreements where booking_id = test.hob('a') and status <> 'voided' order by opened_at desc limit 1)
  || '/' || (select count(*) from booking_events where booking_id = test.hob('a') and kind = 'signed_in_person'),
  'renter/typed/true/Front desk iPad/true/signed/1');
select test.eq('in person: the signed copy''s record page says so',
  (select x ->> 'line' like 'signed in person on a CarmaCars device, collected by Ho Sales; device Front desk iPad%' from jsonb_array_elements(
     public.server_in_person_lines((select signature_request_id from rental_agreements where booking_id = test.hob('a') order by opened_at desc limit 1))) x), true);
select test.lives('in person: the additional driver signs the same way',
  format($$select public.door(%L, null, 'ops_do', 'sign_in_person', jsonb_build_object('booking', %L, 'signer', %L, 'typed_name', 'Dee Driver', 'sha', %L,
    'consent_text', 'I accept.', 'consents', '[]'::jsonb, 'identity', jsonb_build_object('name_confirmed', true, 'licence_seen', true)))$$,
    test.id('ho_cs'), test.hob('a'), test.ho_signer('a', 'additional_driver'), repeat('a', 64)));
select test.eq('in person: the driver''s acceptance is recorded on the booking',
  (select (accepted_at is not null)::text from booking_drivers where booking_id = test.hob('a') and role = 'additional'), 'true');
select test.lives('licence: the additional driver uploads theirs on their own link',
  $$select public.server_driver_register_upload(test.ho_signer('a', 'additional_driver'), 'licence_front', 'drivers/ho/f.jpg', repeat('f', 64), 'image/jpeg')$$);
select test.eq('licence: their link page reads it', (public.server_driver_licence_state(test.ho_signer('a', 'additional_driver')) -> 'licence' ->> 'licence_front'), 'submitted');

-- ---------------------------------------------------------------- 3. check-out by Sales, check-in late by an Admin
create function test.ho_local(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:00') $$;
select test.rq_new('hoA', 'ho_r', 'HOV', test.ho_local(interval '3 hours'), test.ho_local(interval '2 days 3 hours'));
select test.op_confirm('hoA', 'ho_r');
select app.record_deposit_taken(test.b('hoA'), test.op_deposit_payment('hoA'), test.id('ho_fin'));
create temp table ho_fj as select (public.door(test.id('ho_fleet'), null, 'va_do', 'field_job_create', jsonb_build_object('booking', test.b('hoA'), 'kind', 'handover',
  'vehicle', test.id('vehicle:HOV'), 'scheduled_at', now() + interval '3 hours', 'assigned_to', test.id('ho_field'))) ->> 'id')::uuid as id;

select test.eq('today: the staff Today list reads the check-outs and check-ins; Finance gets none',
  jsonb_typeof(public.door(test.id('ho_sales'), null, 'ops_read', 'handovers_today', '{}'::jsonb)) || '/' || public.door(test.id('ho_fin'), null, 'ops_read', 'handovers_today', '{}'::jsonb)::text, 'array/[]');
select test.throws('check-out: Finance does not check cars out',
  format($$select public.door(%L, null, 'ops_do', 'handover_open', jsonb_build_object('booking', %L, 'kind', 'pickup'))$$, test.id('ho_fin'), test.b('hoA')), 'check a car out or in');
select test.throws('check-out: a confirmed booking is not checked in',
  format($$select public.door(%L, null, 'ops_do', 'handover_open', jsonb_build_object('booking', %L, 'kind', 'return'))$$, test.id('ho_sales'), test.b('hoA')), 'checked in while it is on rent');
create temp table ho_job as select (public.door(test.id('ho_sales'), null, 'ops_do', 'handover_open', jsonb_build_object('booking', test.b('hoA'), 'kind', 'pickup')) ->> 'job')::uuid as id;
select test.eq('check-out: Sales takes the field job of the booking, started now, and the history says so',
  (select (j.id = (select id from ho_fj))::text || '/' || (j.assigned_to = test.id('ho_sales'))::text || '/' || j.status from field_jobs j where j.id = (select id from ho_job))
  || '/' || (select count(*) from booking_events where booking_id = test.b('hoA') and kind = 'handover_taken'), 'true/true/in_progress/1');
select test.eq('check-out: Sales reads the checklist of the field portal (ready check, 19 shots)',
  (select (j -> 'ready' ->> 'identity') || '/' || jsonb_array_length(j -> 'shots') || '/' || (j ->> 'report_kind')
     from public.door(test.id('ho_sales'), null, 'field_read', 'job', jsonb_build_object('id', (select id from ho_job))) j), 'true/19/pickup');
select test.eq('check-out: the guided shots name the plate and the fuel gauge',
  (select string_agg(guide, ' | ' order by seq) from required_shots where report_kind = 'pickup' and vehicle_class is null and shot in ('rear', 'instrument_cluster')),
  'Rear, the licence plate readable | Ignition on. Odometer, fuel or charge level and warning lights readable');
select test.throws('check-out: the field staff member who lost the job cannot work it',
  format($$select public.door(%L, null, 'field_do', 'save_report', jsonb_build_object('job', %L, 'report', '{}'::jsonb))$$, test.id('ho_field'), (select id from ho_job)), 'not one of yours');
select test.throws('check-out: another assistant cannot work Sales'' job',
  format($$select public.door(%L, null, 'field_do', 'save_report', jsonb_build_object('job', %L, 'report', '{}'::jsonb))$$, test.id('ho_cs'), (select id from ho_job)), 'Only field staff');
create temp table ho_sv as select public.door(test.id('ho_sales'), null, 'field_do', 'save_report', jsonb_build_object('job', (select id from ho_job),
     'report', jsonb_build_object('odometer_km', 20000, 'fuel_pct', 100, 'photos', jsonb_build_array(jsonb_build_object('seq', 1, 'shot', 'front', 'storage_path', 'bookings/ho/pickup/1-front.jpg',
       'latitude', 43.6453, 'longitude', -79.3806, 'device_taken_at', now()))))) r;
select test.eq('check-out: a photo is saved with the place it was taken, and what is still missing is said',
  (select jsonb_array_length(r -> 'problems') > 0 from ho_sv)
  and exists (select 1 from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = test.b('hoA') and p.latitude = 43.6453), true);
create temp table ho_ho as select public.door(test.id('ho_sales'), null, 'field_do', 'complete_handover', jsonb_build_object('job', (select id from ho_job), 'report', jsonb_build_object(
  'odometer_km', 20000, 'fuel_pct', 100, 'keys_count', 2, 'licence_seen', true, 'card_seen', true, 'renter_present', true,
  'renter_signature_ref', 'sig/r', 'staff_signature_ref', 'sig/s', 'photos', test.op_photos('pickup')))) r;
select test.eq('check-out: Sales checks the car out: on rent, km and fuel out recorded, the job done',
  (select r ->> 'booking_status' from ho_ho) || '/' || (select odometer_out_km || ':' || fuel_out_pct || ':' || (handed_over_at is not null) from bookings where id = test.b('hoA'))
  || '/' || (select status from field_jobs where id = (select id from ho_job)), 'on_rent/20000:100:true/done');

-- due back three hours ago; checked in by an Admin with 450 km driven (400 included) and a quarter tank short
set session_replication_role = replica;
update bookings set pickup_at = now() - interval '2 days 3 hours', handed_over_at = now() - interval '2 days 3 hours', return_at = now() - interval '3 hours',
                    km_allowance_total = 400 where id = test.b('hoA');
set session_replication_role = origin;
select test.eq('check-in: the overdue rental reads as late before it is back',
  (select (r ->> 'overdue') || '/' || ((r ->> 'minutes_late')::int >= 179) from app.handover_report(test.b('hoA')) r), 'true/true');
create temp table ho_ret as select (public.door(test.id('ho_admin'), null, 'ops_do', 'handover_open', jsonb_build_object('booking', test.b('hoA'), 'kind', 'return')) ->> 'job')::uuid as id;
select test.eq('check-in: with no return job, one is made for the Admin', (select kind || '/' || (assigned_to = test.id('ho_admin')) from field_jobs where id = (select id from ho_ret)), 'return_check_in/true');
create temp table ho_rt as select public.door(test.id('ho_admin'), null, 'field_do', 'complete_return', jsonb_build_object('job', (select id from ho_ret), 'report', jsonb_build_object(
  'odometer_km', 20450, 'fuel_pct', 75, 'keys_count', 2, 'cleanliness', 'clean', 'renter_present', true, 'renter_signature_ref', 'sig/r2', 'staff_signature_ref', 'sig/s2',
  'photos', test.op_photos('return')))) r;
select test.eq('check-in: returned, with the minutes late against the due-back time',
  (select r ->> 'booking_status' from ho_rt) || '/' || (select (minutes_late between 179 and 181)::text || ':' || extra_days from bookings where id = test.b('hoA')), 'returned/true:1');
select test.eq('check-in: the late, kilometre and fuel charges are in the settlement at once (no Finance step)',
  (select string_agg(assessment_key, ',' order by assessment_key) from booking_line_items where booking_id = test.b('hoA') and voided_at is null and assessment_key is not null and amount_cents > 0),
  'fuel,fuel_service_fee,late_return_extra_days,late_return_fee,mileage_overage');
select test.eq('check-in: the kilometres over at the booking''s rate', test.op_line('hoA', 'mileage_overage') like (50 * 35)::text || '+%', true);
select test.eq('check-in: no receipt yet: two eighths at the refill price, before the markup',
  (select (supporting_refs ->> 'pump_cost_cents') from booking_line_items where booking_id = test.b('hoA') and assessment_key = 'fuel' and voided_at is null), '2000');
select test.eq('check-in: the photo report has both sets, the times, late by, km over and fuel short',
  (select jsonb_array_length(r -> 'reports') || '/' || (r ->> 'km_over') || '/' || (r ->> 'fuel_short_pct') || '/' || ((r ->> 'minutes_late')::int between 179 and 181)
          || '/' || jsonb_array_length(r -> 'reports' -> 0 -> 'photos') || '/' || (r -> 'reports' -> 0 ->> 'odometer_km') || ':' || (r -> 'reports' -> 1 ->> 'odometer_km')
     from public.door(test.id('ho_cs'), null, 'ops_read', 'handover_report', jsonb_build_object('booking', test.b('hoA'))) r), '2/50/25/true/19/20000:20450');
select test.eq('check-in: the renter reads it too, and the email says the lateness, km and fuel',
  (select jsonb_array_length(public.server_renter_handover_report(test.b('hoA'), (select user_id from renters where id = test.id('renter:ho_r'))) -> 'reports'))::text
  || '/' || (app.notification_payload('renter_return_complete', (select e from app_events e where e.code = 'renter_return_complete' and e.entity_id = test.b('hoA') limit 1), '{}'::jsonb) ->> 'return_findings'),
  '2/Returned 3 h late. 50 km over the included distance. Fuel 25% lower than at pickup');
select test.throws('check-in: another renter cannot read it',
  $$select public.server_renter_handover_report(test.b('hoA'), test.hou('a'))$$, null);

-- waived with a reason, and still waived when the assessment runs again
select test.throws('waive: customer service does not waive charges',
  format($$select public.door(%L, null, 'ops_do', 'check_in_waive', jsonb_build_object('booking', %L, 'key', 'late_return_fee', 'reason', 'Traffic on the 401'))$$, test.id('ho_cs'), test.b('hoA')), 'waives a return charge');
select test.throws('waive: the reason is required',
  format($$select public.door(%L, null, 'ops_do', 'check_in_waive', jsonb_build_object('booking', %L, 'key', 'late_return_fee', 'reason', ''))$$, test.id('ho_fin'), test.b('hoA')), 'Say why');
select public.door(test.id('ho_fin'), null, 'ops_do', 'check_in_waive', jsonb_build_object('booking', test.b('hoA'), 'key', 'late_return_fee', 'reason', 'Traffic on the 401, called ahead'));
select app.assess_check_in(test.b('hoA'), '{}'::jsonb, test.id('ho_fin'));
select test.eq('waive: the late fee stays out after the assessment runs again, the reason kept',
  coalesce(test.op_line('hoA', 'late_return_fee'), 'none') || '/' || (select count(*) from check_in_waivers where booking_id = test.b('hoA'))
  || '/' || (select count(*) from booking_events where booking_id = test.b('hoA') and kind = 'check_in_waived')
  || '/' || (select void_reason from booking_line_items where booking_id = test.b('hoA') and assessment_key = 'late_return_fee' order by created_at limit 1),
  'none/1/1/waived: Traffic on the 401, called ahead');

-- an Admin corrects the actual check-in time: lateness and the late lines follow
select test.throws('time: only an Admin corrects the actual times',
  format($$select public.door(%L, null, 'ops_do', 'handover_time_correct', jsonb_build_object('booking', %L, 'which', 'in', 'at', now(), 'reason', 'Keys dropped earlier'))$$, test.id('ho_fleet'), test.b('hoA')), 'Admin');
select public.door(test.id('ho_admin'), null, 'ops_do', 'handover_time_correct', jsonb_build_object('booking', test.b('hoA'), 'which', 'in',
  'at', (select return_at + interval '10 minutes' from bookings where id = test.b('hoA')), 'reason', 'Keys were in the drop box at 10 past'));
select test.eq('time: ten minutes late (inside the grace period): no extra day, the line voided, the history says why',
  (select minutes_late || ':' || extra_days from bookings where id = test.b('hoA')) || '/' || coalesce(test.op_line('hoA', 'late_return_extra_days'), 'none')
  || '/' || (select count(*) from booking_events where booking_id = test.b('hoA') and kind = 'handover_time_corrected' and note like '%drop box%'), '10:0/none/1');

-- ---------------------------------------------------------------- 4. field staff keep their own jobs
select test.rq_new('hoB', 'ho_r', 'HOV', test.ho_local(interval '5 hours'), test.ho_local(interval '3 days'));
select test.op_confirm('hoB', 'ho_r', false);
create temp table ho_fj2 as select (public.door(test.id('ho_fleet'), null, 'va_do', 'field_job_create', jsonb_build_object('booking', test.b('hoB'), 'kind', 'handover',
  'vehicle', test.id('vehicle:HOV'), 'scheduled_at', now() + interval '5 hours', 'assigned_to', test.id('ho_field2'))) ->> 'id')::uuid as id;
select test.throws('field: field staff do not take a job assigned to someone else',
  format($$select public.door(%L, null, 'ops_do', 'handover_open', jsonb_build_object('booking', %L, 'kind', 'pickup'))$$, test.id('ho_field'), test.b('hoB')), 'assigned to someone else');
