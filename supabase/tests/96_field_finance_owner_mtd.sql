-- 96: field handover without the office, field jobs made from bookings, the identity review in one step, Payments for
-- Admin and Finance, the owner's month to date (migration 0151, docs/changes/2026-10-24-field-finance-owner-mtd.md).
-- Fixtures start with "fq".
select test.suite('96 field, finance, owner month to date');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.eq('settings: field jobs from bookings, least busy, e-Transfer and cash, the tracker override are on by default',
  (select string_agg(column_name || '=' || column_default, ' ' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('field_jobs_auto', 'field_jobs_auto_assign', 'field_offline_deposit_methods', 'field_tracker_override')),
  'field_jobs_auto=false field_jobs_auto_assign=''least_busy''::text field_offline_deposit_methods=ARRAY[''e_transfer''::text, ''cash''::text] field_tracker_override=true');
-- helpers.sql set field jobs off for the earlier suites (the migration's default is on); this suite turns them on
update program_settings set field_jobs_auto = true, field_offline_deposit_methods = array['e_transfer', 'cash'], field_tracker_override = true;
-- only this suite's field staff are active while it runs (put back at the end)
create table test.ff_inactive as select user_id from staff_profiles where staff_type = 'field' and is_active;
update staff_profiles set is_active = false where staff_type = 'field';

select test.mk_user('fq_admin', 'admin');
select test.mk_user('fq_cs', 'va', 'cs');
select test.mk_user('fq_fin', 'va', 'finance');
select test.mk_user('fq_fleet', 'va', 'fleet');
select test.mk_user('fq_field_a', 'field', null, 'driver');
select test.mk_user('fq_field_b', 'field', null, 'driver');
select test.mk_user('fq_detailer', 'field', null, 'detailer');
update staff_profiles set single_limit_cents = 50000 where user_id = test.id('fq_fin');
select test.mk_owner('fq_o');
select test.mk_vehicle('FFA', 'fq_o');
select test.mk_vehicle('FFB', 'fq_o');
select test.mk_vehicle('FFC', 'fq_o');
select test.mk_vehicle('FFD', 'fq_o');
select test.mk_vehicle('FFE', 'fq_o');
select test.mk_renter('fq_r');
-- a Toronto wall-clock time p_days from today at p_hour (the jobs of one day are counted by the Toronto day)
create function test.ffl(p_days integer, p_hour text default '10:00') returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' ' || p_hour $$;
create function test.ff_photos() returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('seq', r.seq, 'shot', r.shot, 'storage_path', 'bookings/ff/' || r.seq || '-' || r.shot || '.jpg', 'width', 2400, 'height', 1600) order by r.seq)
    from app.required_shots_for('pickup', 'premium') r $$;
create function test.ffb(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.ffj(p text, p_kinds text[]) returns field_jobs language sql stable as $$
  select * from field_jobs where booking_id = test.ffb(p) and kind = any (p_kinds) and status <> 'cancelled' order by created_at desc limit 1 $$;

-- ================================================================ 1. field jobs made from bookings
select test.mk_booking('FF-1', 'FFA', 'fq_r', test.ffl(1, '09:00'), test.ffl(4, '09:00'), 'confirmed');
select test.eq('auto: a confirmed booking gets its handover and return jobs, made from the booking',
  (select string_agg(kind || ':' || auto_created, ',' order by kind) from field_jobs where booking_id = test.ffb('FF-1')), 'handover:true,return_check_in:true');
select test.eq('auto: at the booking''s times', (select (test.ffj('FF-1', '{handover}')).scheduled_at = b.pickup_at and (test.ffj('FF-1', '{return_check_in}')).scheduled_at = b.return_at from bookings b where b.id = test.ffb('FF-1')), true);
select test.eq('auto: our location when the booking names no address (never "none")',
  (test.ffj('FF-1', '{handover}')).place, coalesce(nullif(btrim((app.settings()).company_address), ''), 'Our location'));
select test.eq('auto: given to the least busy field staff member who drives (never the detailer)',
  (select u.full_name from users u where u.id = (test.ffj('FF-1', '{handover}')).assigned_to), 'Fq Field A');
select test.mk_booking('FF-2', 'FFB', 'fq_r', test.ffl(1, '10:00'), test.ffl(3, '10:00'), 'confirmed');
select test.eq('auto: the next one that day goes to the other, less busy',
  (select u.full_name from users u where u.id = (test.ffj('FF-2', '{handover}')).assigned_to), 'Fq Field B');
select test.eq('auto: Fleet''s "schedule the handover" task is closed once someone has both jobs',
  (select count(*) from tasks where booking_id = test.ffb('FF-1') and task_type = 'schedule_handover' and status in ('open', 'in_progress', 'waiting')), 0::bigint);

update bookings set pickup_at = pickup_at + interval '30 minutes' where id = test.ffb('FF-1');
select test.eq('auto: the booking moves, the job moves', (select (test.ffj('FF-1', '{handover}')).scheduled_at = pickup_at from bookings where id = test.ffb('FF-1')), true);
update field_jobs set scheduled_at = scheduled_at + interval '2 hours' where id = (test.ffj('FF-1', '{return_check_in}')).id;
update bookings set return_at = return_at - interval '1 hour', original_return_at = original_return_at - interval '1 hour' where id = test.ffb('FF-1');
select test.eq('auto: a time Fleet changed by hand stays as Fleet set it',
  (select (test.ffj('FF-1', '{return_check_in}')).scheduled_at = return_at + interval '3 hours' from bookings where id = test.ffb('FF-1')), true);
select test.eq('auto: no second job when the booking changes again', (select count(*) from field_jobs where booking_id = test.ffb('FF-1')), 2::bigint);

select test.mk_booking('FF-3', 'FFC', 'fq_r', test.ffl(2), test.ffl(5), 'confirmed');
update bookings set pickup_method = 'delivered', pickup_location_kind = 'delivery', pickup_place = '100 Queen St W, Toronto, ON' where id = test.ffb('FF-3');
select test.eq('auto: a delivery is one delivery job, at the renter''s address, with someone on it',
  (select count(*) || ':' || min(place) || ':' || (min(assigned_to::text) is not null) from field_jobs where booking_id = test.ffb('FF-3') and kind in ('handover', 'delivery') and status <> 'cancelled'),
  '1:100 Queen St W, Toronto, ON:true');
update vehicles set owner_pickup_address = '9 Owner Rd, Mississauga, ON' where id = test.id('vehicle:FFD');
select test.mk_booking('FF-6', 'FFD', 'fq_r', test.ffl(6), test.ffl(8), 'confirmed');
update bookings set pickup_location_kind = 'owner_location', return_location_kind = 'airport', return_airport_id = (select id from airports where code = 'YYZ') where id = test.ffb('FF-6');
-- a delivery job as 0020 makes it at confirmation (no place, nobody): the next sync fills both in
delete from field_jobs where booking_id = test.ffb('FF-3') and kind = 'return_check_in';
insert into field_jobs (kind, booking_id, vehicle_id, scheduled_at, instructions, auto_created) values ('pickup_from_renter', test.ffb('FF-3'), test.id('vehicle:FFC'), now() + interval '5 days', 'Collect the car', true);
update bookings set return_method = 'picked_up', return_location_kind = 'delivery', return_place = '7 Bay St, Toronto, ON' where id = test.ffb('FF-3');
select test.eq('auto: a pickup job 0020 made without a place or a person gets both',
  (select count(*) || ':' || min(place) || ':' || bool_and(assigned_to is not null) from field_jobs where booking_id = test.ffb('FF-3') and kind in ('return_check_in', 'pickup_from_renter') and status <> 'cancelled'),
  '1:7 Bay St, Toronto, ON:true');
select test.eq('auto: the owner''s location and the airport by name',
  (test.ffj('FF-6', '{handover}')).place || ' / ' || (test.ffj('FF-6', '{return_check_in}')).place, '9 Owner Rd, Mississauga, ON / Toronto Pearson International Airport');
update field_jobs set status = 'cancelled', cancel_reason = 'The owner hands it over' where id = (test.ffj('FF-6', '{handover}')).id;
update bookings set pickup_at = pickup_at + interval '1 hour' where id = test.ffb('FF-6');
select test.eq('auto: a job Fleet cancelled is not made again when the booking changes',
  (select count(*) filter (where status <> 'cancelled') || '/' || count(*) from field_jobs where booking_id = test.ffb('FF-6') and kind in ('handover', 'delivery')), '0/1');
update program_settings set field_jobs_auto = false;
select test.mk_booking('FF-7', 'FFE', 'fq_r', test.ffl(4), test.ffl(5), 'confirmed');
select test.eq('auto: off, no job (Fleet schedules from the board)', (select count(*) from field_jobs where booking_id = test.ffb('FF-7')), 0::bigint);
select test.eq('board: the place of a handover with no job is filled in, never empty',
  (select u ->> 'place' from jsonb_array_elements(app.door(test.id('fq_fleet'), 'aal2', 'va_read', 'fleet_board', '{}') -> 'unscheduled') u where u ->> 'booking_number' = 'FF-7' and u ->> 'leg' = 'handover'),
  coalesce(nullif(btrim((app.settings()).company_address), ''), 'Our location'));
update program_settings set field_jobs_auto = true;

-- ================================================================ 2. the ready check resolved on the spot
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
values (test.ffb('FF-1'), test.id('driver:fq_r'), 'renter', 'Fq R', date '1990-05-05', null, 'G', null, 36, '26_plus');
insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (test.ffb('FF-1'), 2, 'confirmed', 'Bank', '4242', now());
update bookings set coverage_option = 2, coverage_confirmed_at = now(), blocks_calendar = true where id = test.ffb('FF-1');
create table test.ffjob as select (test.ffj('FF-1', '{handover}')).id as id;
create function test.ffjid() returns uuid language sql stable as $$ select id from test.ffjob $$;
select app.door(test.id('fq_field_a'), 'aal2', 'field_do', 'acknowledge', jsonb_build_object('job', test.ffjid()));
select app.door(test.id('fq_field_a'), 'aal2', 'field_do', 'start', jsonb_build_object('job', test.ffjid()));
select test.eq('job read: the facts to resolve the ready check (the driver and the state of their licence, the deposit and its ways)',
  (select (x #>> '{resolve,drivers,0,name}') || '/' || (x #>> '{resolve,drivers,0,verified}') || '/' || (x #>> '{resolve,deposit_cents}') || '/' || (x #> '{resolve,deposit_methods}')::text
     || '/' || (x #>> '{ready,identity}') || '/' || coalesce(x #>> '{tracker,override}', 'none')
     from app.door(test.id('fq_field_a'), 'aal2', 'field_read', 'job', jsonb_build_object('id', test.ffjid())) x),
  'Fq R/false/100000/["e_transfer", "cash"]/false/none');

-- the licence, in person
select test.throws('identity: only field staff (customer service cannot use the field step)',
  format($$select app.door(%L, 'aal2', 'field_do', 'identity_in_person', jsonb_build_object('job', %L, 'driver', %L))$$, test.id('fq_cs'), test.ffjid(), test.id('driver:fq_r')), 'Only field staff');
select test.throws('identity: only on one''s own job', format($$select app.door(%L, 'aal2', 'field_do', 'identity_in_person', jsonb_build_object('job', %L, 'driver', %L))$$,
  test.id('fq_field_b'), test.ffjid(), test.id('driver:fq_r')), 'not one of yours');
select test.throws('identity: each check confirmed',
  format($$select app.door(%L, 'aal2', 'field_do', 'identity_in_person', jsonb_build_object('job', %L, 'driver', %L, 'checks', '{"name": true, "photo": true}'::jsonb))$$,
    test.id('fq_field_a'), test.ffjid(), test.id('driver:fq_r')), 'Confirm each check');
create function test.ffchecks(p_expiry text default null) returns jsonb language sql stable as $$
  select jsonb_build_object('job', test.ffjid(), 'driver', test.id('driver:fq_r'), 'checks', '{"name": true, "photo": true, "expiry": true, "class": true}'::jsonb,
                            'licence_number', 'f1234-56789-01234', 'licence_expiry', p_expiry) $$;
select test.throws('identity: the expiry read from the card when the booking has none (the driver''s file has one: 2030)',
  format($$update drivers set licence_expiry = null where id = %L; select app.door(%L, 'aal2', 'field_do', 'identity_in_person', test.ffchecks())$$, test.id('driver:fq_r'), test.id('fq_field_a')), 'expiry date');
select test.throws('identity: the photos first', format($$select app.door(%L, 'aal2', 'field_do', 'identity_in_person', test.ffchecks('2031-06-30'))$$, test.id('fq_field_a')), 'Photograph the licence front');
select app.door(test.id('fq_field_a'), 'aal2', 'ops_do', 'staff_licence_register', jsonb_build_object('booking', test.ffb('FF-1'), 'driver', test.id('driver:fq_r'), 'kind', k,
  'path', 'staff/ff/' || k || '.jpg', 'sha256', repeat('f', 64), 'mime', 'image/jpeg')) from unnest(array['licence_front', 'licence_back', 'selfie']) k;
select test.throws('identity: a licence that expires before the return stops the car', format($$select app.door(%L, 'aal2', 'field_do', 'identity_in_person', test.ffchecks(%L))$$,
  test.id('fq_field_a'), app.today()::text), 'expires before the return date');
select test.lives('identity: photographed and every check confirmed: approved', format($$select app.door(%L, 'aal2', 'field_do', 'identity_in_person', test.ffchecks('2031-06-30'))$$, test.id('fq_field_a')));
select test.eq('identity: the driver is verified, the uploads approved by the field staff member, the number and expiry kept',
  (select (identity_verified_on is not null) || '/' || licence_number || '/' || licence_expiry from booking_drivers where booking_id = test.ffb('FF-1') and role = 'renter') || '/' ||
  (select count(*) || ':' || bool_and(reviewed_by = test.id('fq_field_a')) from verification_uploads where booking_id = test.ffb('FF-1') and status = 'approved'),
  'true/F1234-56789-01234/2031-06-30/3:true');
select test.eq('identity: recorded as an in-person check, in the history and the resolutions',
  (select (iv.checks ->> 'in_person') from identity_verifications iv join booking_drivers bd on bd.identity_verification_id = iv.id where bd.booking_id = test.ffb('FF-1')) || '/' ||
  (select count(*) from booking_events where booking_id = test.ffb('FF-1') and note like '%checked in person at the check-out%') || '/' ||
  (select count(*) from handover_resolutions where booking_id = test.ffb('FF-1') and kind = 'identity_in_person' and created_by = test.id('fq_field_a')), 'true/1/1');
select test.eq('identity: the acting-as setting does not outlive the step', coalesce(current_setting('app.field_as_cs', true), ''), '');
select test.eq('identity: the ready check says so', (select x #>> '{ready,identity}' from app.door(test.id('fq_field_a'), 'aal2', 'field_read', 'job', jsonb_build_object('id', test.ffjid())) x), 'true');

-- the deposit
update program_settings set field_offline_deposit_methods = array['e_transfer'];
select test.throws('deposit: cash only when the setting allows it', format($$select app.door(%L, 'aal2', 'field_do', 'deposit_offline', jsonb_build_object('job', %L, 'method', 'cash'))$$,
  test.id('fq_field_a'), test.ffjid()), 'by card on the renter''s phone or by e-Transfer');
select test.throws('deposit: an e-Transfer needs its reference', format($$select app.door(%L, 'aal2', 'field_do', 'deposit_offline', jsonb_build_object('job', %L, 'method', 'e_transfer'))$$,
  test.id('fq_field_a'), test.ffjid()), 'reference');
select test.lives('deposit: by e-Transfer at the check-out', format($$select app.door(%L, 'aal2', 'field_do', 'deposit_offline', jsonb_build_object('job', %L, 'method', 'e_transfer', 'reference', 'CAffX9'))$$,
  test.id('fq_field_a'), test.ffjid()));
select test.eq('deposit: taken, recorded by the field staff member, in the resolutions',
  (select status || '/' || paid_method from deposits where booking_id = test.ffb('FF-1')) || '/' ||
  (select count(*) from payments where booking_id = test.ffb('FF-1') and purpose = 'deposit' and method = 'e_transfer' and created_by = test.id('fq_field_a')) || '/' ||
  (select count(*) from handover_resolutions where booking_id = test.ffb('FF-1') and kind = 'deposit_offline'), 'captured/e_transfer/1/1');
select test.eq('deposit: the field staff member gains no payment rights outside the step', app.booking_payment_allowed(test.id('fq_field_a'), 100) is not null, true);
update program_settings set field_offline_deposit_methods = array['e_transfer', 'cash'];

-- the tracker
select test.throws('tracker: the reason is required', format($$select app.door(%L, 'aal2', 'field_do', 'tracker_override', jsonb_build_object('job', %L, 'reason', 'no'))$$,
  test.id('fq_field_a'), test.ffjid()), 'at least 10');
update program_settings set field_tracker_override = false;
select test.throws('tracker: off in the settings', format($$select app.door(%L, 'aal2', 'field_do', 'tracker_override', jsonb_build_object('job', %L, 'reason', 'Underground garage, no signal'))$$,
  test.id('fq_field_a'), test.ffjid()), 'turned off');
update program_settings set field_tracker_override = true;
select test.lives('tracker: released with a reason', format($$select app.door(%L, 'aal2', 'field_do', 'tracker_override', jsonb_build_object('job', %L, 'reason', 'Underground garage, no signal'))$$,
  test.id('fq_field_a'), test.ffjid()));
select test.eq('tracker: an Admin is told at once (an urgent Admin task)',
  (select queue || '/' || priority || '/' || escalated from tasks where booking_id = test.ffb('FF-1') and task_type = 'tracker_override'), 'admin/high/true');
select test.eq('tracker: the job read shows the override', (select x #>> '{tracker,override,reason}' from app.door(test.id('fq_field_a'), 'aal2', 'field_read', 'job', jsonb_build_object('id', test.ffjid())) x),
  'Underground garage, no signal');
insert into field_jobs (kind, booking_id, vehicle_id, assigned_to, scheduled_at, place) values ('handover', test.ffb('FF-1'), test.id('vehicle:FFA'), test.id('fq_field_b'), now() + interval '2 hours', 'Our location');
select test.lives('tracker: the handover completes', format($$select app.door(%L, 'aal2', 'field_do', 'complete_handover', jsonb_build_object('job', %L, 'report',
  jsonb_build_object('odometer_km', 21000, 'fuel_pct', 100, 'keys_count', 2, 'renter_present', true, 'licence_seen', true, 'card_seen', true,
    'renter_signature_ref', 'sig/r', 'staff_signature_ref', 'sig/s', 'photos', test.ff_photos(), 'tracker_reporting', true)))$$, test.id('fq_field_a'), test.ffjid()));
select test.eq('handed over: another open handover job of the booking is cancelled, its person told',
  (select count(*) filter (where status = 'cancelled' and cancel_reason = 'Handed over on another job') from field_jobs where booking_id = test.ffb('FF-1') and kind = 'handover'), 1::bigint);
select test.eq('tracker: on rent, and the report keeps what the tracker said (not reporting)',
  (select status::text from bookings where id = test.ffb('FF-1')) || '/' || (select tracker_reporting from condition_reports where booking_id = test.ffb('FF-1') and kind = 'pickup'), 'on_rent/false');

-- cash, and the paper copy, on a rental added by hand
update bookings set added_by_staff = true, added_mode = 'future', blocks_calendar = true where id = test.ffb('FF-2');
update field_jobs set assigned_to = test.id('fq_field_a') where id = (test.ffj('FF-2', '{handover}')).id;
create table test.ffjob2 as select (test.ffj('FF-2', '{handover}')).id as id;
select test.lives('cash: a deposit in cash at the check-out', format($$select app.door(%L, 'aal2', 'field_do', 'deposit_offline', jsonb_build_object('job', %L, 'method', 'cash'))$$,
  test.id('fq_field_a'), (select id from test.ffjob2)));
select test.eq('cash: Finance gets a task to collect it', (select queue || '/' || task_type from tasks where booking_id = test.ffb('FF-2') and task_type = 'field_cash_handin'), 'finance/field_cash_handin');
select test.eq('paper: the rental waits for the renter''s signature', app.booking_awaiting_signature(test.ffb('FF-2')), true);
select app.open_rental_agreement(test.ffb('FF-2'), test.id('fq_admin'), 'v2-test', repeat('a', 64), 'bookings/ff/ra.pdf');
select test.throws('paper: the scan is stored where paper copies are', format($$select app.door(%L, 'aal2', 'field_do', 'paper_signed', jsonb_build_object('job', %L, 'scan', jsonb_build_object('path', 'x/y.pdf', 'sha256', repeat('b', 64))))$$,
  test.id('fq_field_a'), (select id from test.ffjob2)), 'scan');
select test.lives('paper: field staff record the signed paper copy from the phone', format($$select app.door(%L, 'aal2', 'field_do', 'paper_signed', jsonb_build_object('job', %L,
  'scan', jsonb_build_object('path', 'paper/rental_agreement/2026/ff.pdf', 'sha256', repeat('b', 64), 'mime', 'application/pdf')))$$, test.id('fq_field_a'), (select id from test.ffjob2)));
select test.eq('paper: the agreement counts as signed, recorded as paper, in the resolutions',
  app.booking_awaiting_signature(test.ffb('FF-2')) || '/' || (select count(*) from paper_signatures where target_id = test.ffb('FF-2') and doc_type = 'rental_agreement') || '/' ||
  (select count(*) from handover_resolutions where booking_id = test.ffb('FF-2') and kind = 'paper_signed'), 'false/1/1');
select test.throws('paper: once signed there is nothing to scan', format($$select app.door(%L, 'aal2', 'field_do', 'paper_signed', jsonb_build_object('job', %L,
  'scan', jsonb_build_object('path', 'paper/rental_agreement/2026/ff2.pdf', 'sha256', repeat('c', 64))))$$, test.id('fq_field_a'), (select id from test.ffjob2)), 'already signed');
select test.eq('paper: no customer service rights left over', app.user_va_has(test.id('fq_field_a'), 'cs'), false);
select test.throws('resolutions are kept as recorded', $$delete from handover_resolutions$$, 'kept as it was recorded');

-- ================================================================ 3. the identity review in one step
select test.mk_booking('FF-5', 'FFE', 'fq_r', test.ffl(20), test.ffl(22), 'confirmed');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
values (test.ffb('FF-5'), test.id('driver:fq_r'), 'renter', 'Fq R', date '1990-05-05', 'L9', 'G', date '2031-01-01', 36, '26_plus');
select app.register_verification_upload(test.ffb('FF-5'), test.id('fq_cs'), k, test.id('driver:fq_r'), 'renters/ff/5-' || k || '.jpg', repeat('e', 64), 'image/jpeg', null, 'identity')
  from unnest(array['licence_front', 'licence_back', 'selfie']) k;
select test.throws('approve all: an Admin or customer service', format($$select app.door(%L, 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'FF-5'))$$, test.id('fq_field_a')), 'Only an Admin or customer service');
select test.eq('approve all: one step approves the three images, the driver is verified',
  (select (x ->> 'approved') || '/' || jsonb_array_length(x -> 'refused') || '/' || (x #>> '{readiness,all_drivers_verified}')
     from app.door(test.id('fq_cs'), 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'FF-5')) x), '3/0/true');
select test.eq('approve all: nothing waiting, nothing done the second time',
  (app.door(test.id('fq_cs'), 'aal2', 'ops_do', 'doc_review_approve_all', jsonb_build_object('booking', 'FF-5')) ->> 'approved'), '0');

-- ================================================================ 4. payments
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by, card_brand, card_last4) values
  (test.ffb('FF-5'), test.id('renter:fq_r'), 'booking_total', 'charge', 'card', 50000, 'succeeded', timestamptz '2025-12-03 10:00-05', null, 'visa', '4242'),
  (test.ffb('FF-5'), test.id('renter:fq_r'), 'deposit', 'charge', 'cash', 100000, 'succeeded', timestamptz '2025-12-03 12:00-05', test.id('fq_field_a'), null, null),
  (test.ffb('FF-5'), test.id('renter:fq_r'), 'booking_total', 'charge', 'e_transfer', 20000, 'succeeded', timestamptz '2025-12-03 13:00-05', test.id('fq_fin'), null, null),
  (test.ffb('FF-5'), test.id('renter:fq_r'), 'deposit', 'refund', 'cash', 30000, 'succeeded', timestamptz '2025-12-03 17:00-05', test.id('fq_fin'), null, null),
  (test.ffb('FF-5'), test.id('renter:fq_r'), 'deposit', 'hold', 'card', 80000, 'authorized', timestamptz '2025-12-04 09:00-05', null, 'visa', '4242'),
  (test.ffb('FF-5'), test.id('renter:fq_r'), 'booking_total', 'charge', 'platform_payout', 12345, 'succeeded', timestamptz '2025-12-04 11:00-05', test.id('fq_fin'), null, null);
create function test.ffled(p jsonb) returns jsonb language sql as $$ select app.door(test.id('fq_fin'), 'aal2', 'ops_read', 'payments_ledger', p) $$;
select test.throws('payments: an Admin or Finance', format($$select app.door(%L, 'aal2', 'ops_read', 'payments_ledger', '{}')$$, test.id('fq_cs')), 'Admin or Finance');
select test.throws('payments: three months at a time', $$select test.ffled('{"from": "2025-01-01", "to": "2025-12-31"}')$$, 'three months');
select test.eq('payments: every payment of the day, in time order, with friendly words',
  (select string_agg((r ->> 'channel_label') || ' ' || (r ->> 'direction') || ' ' || (r ->> 'amount_cents'), ', ' order by r ->> 'at') from jsonb_array_elements(test.ffled('{"from": "2025-12-03"}') -> 'rows') r),
  'Card in 50000, Cash in 100000, e-Transfer in 20000, Cash out 30000');
select test.eq('payments: a card reads as its brand and last four, a refund as a refund',
  (select string_agg((r ->> 'how') || ' / ' || (r ->> 'what'), '; ' order by r ->> 'at') from jsonb_array_elements(test.ffled('{"from": "2025-12-03", "methods": ["card"]}') -> 'rows') r),
  'Card Visa ending 4242 / Payment: Rental');
select test.eq('payments: the day''s totals by method', (test.ffled('{"from": "2025-12-03"}') #> '{totals,cash}')::text, '{"in": 100000, "out": 30000, "count": 2}');
select test.eq('payments: a hold is listed but is not money in; a platform payout is its own method',
  (select (x #>> '{totals,card,in}') || '/' || (x #>> '{totals,card,count}') || '/' || (x #>> '{totals,platform_payout,in}') from test.ffled('{"from": "2025-12-04"}') x), '0/0/12345');
select test.eq('cash drawer: expected is the cash in less the cash given back',
  (select d ->> 'cash_expected_cents' from jsonb_array_elements(test.ffled('{"from": "2025-12-03"}') -> 'days') d), '70000');
select test.throws('cash drawer: customer service does not count it', format($$select app.door(%L, 'aal2', 'ops_do', 'cash_drawer_count', '{"day": "2025-12-03", "counted_cents": 1}')$$, test.id('fq_cs')), 'Admin or Finance');
select app.door(test.id('fq_fin'), 'aal2', 'ops_do', 'cash_drawer_count', '{"day": "2025-12-03", "counted_cents": 69500, "note": "one bill short"}');
select test.eq('cash drawer: the count against the expected, and who counted',
  (select (d ->> 'cash_counted_cents') || '/' || (d ->> 'cash_difference_cents') || '/' || (d ->> 'cash_counted_by') from jsonb_array_elements(test.ffled('{"from": "2025-12-03"}') -> 'days') d), '69500/-500/Fq Fin');

-- refunds requested anywhere reach Finance with the policy maths
insert into booking_cancellations (booking_id, booked_at, received_at, start_at, channel, cancelled_by, reason, tier, refund_bps, total_paid_cents, refund_cents, retained_cents)
values (test.ffb('FF-5'), now() - interval '5 days', now(), now() + interval '20 days', 'portal', 'renter', 'renter_request', 'more_than_7_days', 9500, 25199, 23939, 1260);
-- (the cancellation table's own trigger works the tier and the refund out from the dates)
insert into refunds (id, booking_id, reason, refund_bps, amount_cents, requested_by)
select test.id('refund:ff1'), test.ffb('FF-5'), 'cancellation', refund_bps, refund_cents, test.id('fq_cs') from booking_cancellations where booking_id = test.ffb('FF-5');
insert into refunds (id, booking_id, reason, refund_bps, amount_cents, requested_by) values (test.id('refund:ff2'), test.ffb('FF-5'), 'goodwill', null, 15000, test.id('fq_cs'));
select test.eq('refunds: both in Finance''s queue, with the policy maths; the cancellation within the limit, goodwill an Admin''s',
  (select string_agg((r ->> 'reason') || ':' || coalesce(r #>> '{maths,tier}', '-') || ':' || coalesce(r #>> '{maths,kept_cents}', '-') || ':' || (r ->> 'can_approve') || ':' || (r ->> 'can_decline'), ', ' order by r ->> 'reason')
     from jsonb_array_elements(test.ffled('{}') -> 'refunds') r where r ->> 'booking_number' = 'FF-5'),
  (select format('cancellation:%s:%s:true:true, goodwill:%s:%s:false:true', tier, retained_cents, tier, retained_cents) from booking_cancellations where booking_id = test.ffb('FF-5')));
select test.lives('refunds: Finance approves the one the table decides', format($$select app.door(%L, 'aal2', 'ops_do', 'refund_decide', jsonb_build_object('id', %L, 'approve', true))$$, test.id('fq_fin'), test.id('refund:ff1')));
select test.eq('refunds: approved by Finance', (select status || '/' || (approved_by = test.id('fq_fin')) from refunds where id = test.id('refund:ff1')), 'approved/true');
select test.throws('refunds: goodwill above the table needs an Admin', format($$select app.door(%L, 'aal2', 'ops_do', 'refund_decide', jsonb_build_object('id', %L, 'approve', true))$$, test.id('fq_fin'), test.id('refund:ff2')), 'Admin');
select test.throws('refunds: declining needs the reason', format($$select app.door(%L, 'aal2', 'ops_do', 'refund_decide', jsonb_build_object('id', %L, 'approve', false))$$, test.id('fq_fin'), test.id('refund:ff2')), 'reason');
select app.door(test.id('fq_fin'), 'aal2', 'ops_do', 'refund_decide', jsonb_build_object('id', test.id('refund:ff2'), 'approve', false, 'reason', 'Outside the policy'));
select test.eq('refunds: declined, with the reason kept', (select status || '/' || (note like '%Declined: Outside the policy%') from refunds where id = test.id('refund:ff2')), 'rejected/true');
select test.throws('refunds: decided once', format($$select app.door(%L, 'aal2', 'ops_do', 'refund_decide', jsonb_build_object('id', %L, 'approve', true))$$, test.id('fq_admin'), test.id('refund:ff2')), 'not waiting');

-- ================================================================ 5. the owner's month to date
create table test.ffseq as select last_value from pg_sequences where sequencename = 'owner_statement_number_seq';
create table test.ffmtd as select public.owner_portal_month_to_date(test.id('fq_o')) x;
select test.eq('month to date: provisional, worked out, the month of today',
  (select (x ->> 'final') || '/' || (x ->> 'provisional') || '/' || (x -> 'totals' is not null and jsonb_typeof(x -> 'totals') = 'object') || '/' || (x ->> 'month') from test.ffmtd),
  'false/true/true/' || app.month_start(app.today())::text);
select test.eq('month to date: the expected payout and the cars', (select jsonb_typeof(x #> '{totals,payout_cents}') || '/' || (jsonb_array_length(x -> 'vehicles') >= 1) from test.ffmtd), 'number/true');
select test.eq('month to date: the bookings still under way are listed', (select count(*) from test.ffmtd, jsonb_array_elements(x -> 'in_progress') b where b ->> 'booking_number' like 'FF-%') >= 1, true);
select test.eq('month to date: nothing kept (no statement, no number used)',
  (select count(*) from owner_statements where owner_id = test.id('owner:fq_o')) || '/' ||
  ((select last_value from pg_sequences where sequencename = 'owner_statement_number_seq') is not distinct from (select last_value from test.ffseq)), '0/true');
select test.throws('month to date: owners only', format($$select public.owner_portal_month_to_date(%L)$$, test.id('fq_cs')), 'owner');
insert into owner_statements (owner_id, statement_month, payout_date, status, approved_by, approved_at, payout_cents)
values (test.id('owner:fq_o'), date '2026-09-01', app.payout_date(date '2026-09-01'), 'approved', test.id('fq_admin'), now(), 4321);
select test.eq('month to date: an approved month is the final statement',
  (select (x ->> 'final') || '/' || (x ->> 'payout_cents') from (select public.owner_portal_month_to_date(test.id('fq_o'), date '2026-09-01') x) y), 'true/4321');

-- ================================================================ privileges, and the field staff put back
set role anon;
select test.throws('anon: no door', $$select app.door(null, 'aal1', 'ops_read', 'payments_ledger', '{}')$$, null);
reset role;
set role authenticated;
select test.throws('authenticated: the month to date is the server''s call only', $$select public.owner_portal_month_to_date(gen_random_uuid())$$, null);
reset role;
update staff_profiles set is_active = true where user_id in (select user_id from test.ff_inactive);
update program_settings set field_jobs_auto = false;
