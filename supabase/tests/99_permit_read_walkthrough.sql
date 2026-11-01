-- 99: the ownership permit read from a photo (0290) and the rental walkthrough (0291). Fixtures start with "pw"; a
-- synthetic VIN with a valid check digit; example.test addresses; no real plate, permit or person.
select test.suite('99 permit read and walkthrough');
select test.mk_user('pw_admin', 'admin');
select test.mk_user('pw_fleet', 'va', 'fleet');
select test.mk_user('pw_fin', 'va', 'finance');
select test.mk_owner('pw_o');
select test.mk_vehicle('PWA', 'pw_o');
select test.mk_vehicle('PWB', 'pw_o');
select test.mk_vehicle('PWC', 'pw_o');
select test.mk_renter('pw_r');
select test.mk_renter('pw_x');

-- ================================================================ 1. the permit read: who, the settings, the count
-- the gate is asked on a day of its own (no AI used that day by other suites), with the vision model on
create function test.pw_now() returns timestamptz language sql as $$ select timestamp '2031-06-17 12:00' at time zone 'America/Toronto' $$;
-- (program_settings may hold rows for later dates: every row is set, then put back)
create temp table pw_vis as select id, ai_vision_enabled v, ai_vision_permit_enabled pv from program_settings;
update program_settings set ai_vision_enabled = true, ai_vision_permit_enabled = true where id is not null;
create temp table pw_us as select service, enabled, included from usage_services where service = 'workers_ai';
update usage_services set enabled = true, included = greatest(coalesce(included, 0), 10000) where service = 'workers_ai';
select test.ok('on by default, ten reads a day for an owner', (select ai_vision_permit_enabled and ai_vision_permit_daily_per_person = 10 from app.settings()));
select test.eq('an Admin may read a permit, as staff', (select (g ->> 'allowed') || '/' || (g ->> 'staff') from (select app.permit_read_gate(test.id('pw_admin'), test.pw_now()) g) x), 'true/true');
select test.eq('fleet may read a permit', (select (g ->> 'allowed') || coalesce(' ' || (g ->> 'reason'), '') from (select app.permit_read_gate(test.id('pw_fleet'), test.pw_now()) g) x), 'true');
select test.eq('an owner may read a permit, not as staff', (select (g ->> 'allowed') || '/' || (g ->> 'staff') || '/' || (g ->> 'owner') from (select app.permit_read_gate(test.id('pw_o'), test.pw_now()) g) x), 'true/false/true');
select test.throws('nobody signed in: refused', $$select app.permit_read_gate(null)$$, '%Sign in%');
select test.ok('the gate names the model', (app.permit_read_gate(test.id('pw_admin'), test.pw_now()) ->> 'model') is not null);

select app.permit_read_record(test.id('pw_o'), jsonb_build_object('model', 'fake-vision-v1', 'ok', true, 'neurons', 120, 'duration_ms', 900, 'fields_read', 9));
select test.ok('a read is recorded: the neurons in provider_calls', exists (select 1 from provider_calls c where c.purpose = 'permit_read' and c.units = 120 and c.unit = 'neurons'));
select test.eq('a read is recorded: who and how many fields, never the values', (select r.fields_read::text || '/' || r.staff::text from permit_reads r where r.user_id = test.id('pw_o')), '9/false');
select test.ok('permit_reads keeps no plate, VIN or permit number', not exists (select 1 from information_schema.columns where table_name = 'permit_reads' and column_name in ('plate', 'vin', 'permit_number', 'value', 'data')));
select test.eq('the readers'' share of the allowance, with its own label', app.ai_tier('permit_read') || '/' || app.ai_feature_label('permit_read'), 'live/Ownership permit reader');

insert into permit_reads (user_id, staff, ok, fields_read, created_at) select test.id('pw_o'), false, true, 9, test.pw_now() - interval '1 hour' from generate_series(1, 10);
select test.eq('an owner after ten reads today: refused, in words', (select (g ->> 'allowed') || '/' || (g ->> 'reason' like '%for today%')::text from (select app.permit_read_gate(test.id('pw_o'), test.pw_now()) g) x), 'false/true');
insert into permit_reads (user_id, staff, ok, fields_read, created_at) select test.id('pw_fleet'), true, true, 9, test.pw_now() - interval '1 hour' from generate_series(1, 12);
select test.eq('staff are not counted against the owner''s number', app.permit_read_gate(test.id('pw_fleet'), test.pw_now()) ->> 'allowed', 'true');
select test.eq('yesterday''s reads do not count', (select app.permit_read_gate(test.id('pw_o'), test.pw_now() + interval '1 day') ->> 'allowed'), 'true');
update program_settings set ai_vision_permit_enabled = false where id is not null;
select test.eq('turned off in Program settings: refused, type the details', (select (g ->> 'allowed') || '/' || (g ->> 'reason' like '%off in Program settings%')::text from (select app.permit_read_gate(test.id('pw_admin'), test.pw_now()) g) x), 'false/true');
update program_settings p set ai_vision_permit_enabled = x.pv, ai_vision_enabled = x.v from pw_vis x where p.id = x.id;
update usage_services u set enabled = x.enabled, included = x.included from pw_us x where u.service = x.service;
select test.ok('the gate and the record are server only', not has_function_privilege('authenticated', 'public.server_permit_read_gate(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.server_permit_read_record(uuid, jsonb)', 'execute') and has_function_privilege('service_role', 'public.server_permit_read_gate(uuid)', 'execute'));

-- ================================================================ 1. the permit number and sticker saved with the new car
create temp table pw_add as select app.staff_add_owner_car(test.id('pw_fleet'), jsonb_build_object('owner_id', test.id('owner:pw_o'),
  'vehicle', jsonb_build_object('vin', '3FAKEPRM5RT000042', 'year', 2024, 'make', 'Toyota', 'model', 'Corolla', 'plate', 'ZZZZ999', 'title_status', 'owned_outright',
    'management_mode', 'managed', 'colour', 'Grey', 'permit_number', 'x1234567', 'sticker_expires_on', '2027-11-30'))) r;
grant all on pw_add to public;
select test.eq('a car added for an owner keeps the permit number (upper case) and the sticker expiry',
  (select v.permit_number || '|' || v.sticker_expires_on from vehicles v where v.id = (select (r ->> 'vehicle_id')::uuid from pw_add)), 'X1234567|2027-11-30');
select test.throws('a permit number that is not one: refused', $$select app.staff_add_owner_car(test.id('pw_fleet'), jsonb_build_object('owner_id', test.id('owner:pw_o'),
  'vehicle', jsonb_build_object('plate', 'ZZZZ998', 'year', 2022, 'make', 'Honda', 'model', 'Civic', 'title_status', 'owned_outright', 'management_mode', 'managed', 'permit_number', '#!')))$$, '%permit number%');
select test.throws('a sticker more than a year ago: refused', $$select app.staff_add_owner_car(test.id('pw_fleet'), jsonb_build_object('owner_id', test.id('owner:pw_o'),
  'vehicle', jsonb_build_object('plate', 'ZZZZ997', 'year', 2022, 'make', 'Honda', 'model', 'Civic', 'title_status', 'owned_outright', 'management_mode', 'managed', 'sticker_expires_on', '2020-01-01')))$$, '%sticker%');
select test.lives('a car without the permit fields is added as before', $$select app.staff_add_owner_car(test.id('pw_fleet'), jsonb_build_object('owner_id', test.id('owner:pw_o'),
  'vehicle', jsonb_build_object('plate', 'ZZZZ996', 'year', 2022, 'make', 'Honda', 'model', 'Civic', 'title_status', 'owned_outright', 'management_mode', 'managed')))$$);

-- ================================================================ 2. the walkthrough
create function test.pw_at(p text) returns timestamptz language sql as $$ select p::timestamp at time zone 'America/Toronto' $$;
select test.mk_booking('CC-PW1', 'PWA', 'pw_r', '2027-04-11 10:00', '2027-04-14 10:00', 'confirmed');
select test.mk_booking('CC-PW2', 'PWB', 'pw_r', '2027-04-01 10:00', '2027-04-20 10:00', 'on_rent');
select test.mk_booking('CC-PW3', 'PWC', 'pw_r', '2027-03-01 10:00', '2027-03-04 10:00', 'closed');
select test.mk_booking('CC-PW4', 'PWC', 'pw_x', '2027-05-01 10:00', '2027-05-04 10:00', 'cancelled');
update bookings set deposit_cents = 50000 where booking_number = 'CC-PW1';

create function test.pw_step(p_number text, p_key text, p_now timestamptz default now()) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(app.rental_walkthrough(test.id('booking:' || p_number), p_now) -> 'steps') x where x ->> 'key' = p_key $$;
select test.ok('on by default', (select field_renter_walkthrough from app.settings()));
select test.eq('a confirmed booking two weeks out: before pickup, 13 steps, 6 to read',
  (select (w ->> 'stage') || '/' || (w ->> 'total') || '/' || (w ->> 'of') from (select app.rental_walkthrough(test.id('booking:CC-PW1'), test.pw_at('2027-03-28 12:00')) w) x), 'before/13/6');
select test.eq('paid (confirmed), the deposit hold still to come', (test.pw_step('CC-PW1', 'pay') ->> 'done') || '/' || (test.pw_step('CC-PW1', 'deposit') ->> 'done') || '/' || (test.pw_step('CC-PW1', 'deposit') ->> 'needed'), 'true/false/true');
select test.eq('the walk-around is a task: not done before the check-out', test.pw_step('CC-PW1', 'inspect') ->> 'kind' || '/' || (test.pw_step('CC-PW1', 'inspect') ->> 'done'), 'task/false');
select test.eq('the pickup day: at pickup', app.rental_walkthrough(test.id('booking:CC-PW1'), test.pw_at('2027-04-11 07:00')) ->> 'stage', 'pickup');

select test.eq('Got it: what to bring is read', (select x ->> 'done' from jsonb_array_elements(app.rental_walkthrough_ack(test.id('booking:CC-PW1'), test.id('pw_r'), 'bring') -> 'steps') x where x ->> 'key' = 'bring'), 'true');
select test.lives('Got it twice: no error, one row', $$select app.rental_walkthrough_ack(test.id('booking:CC-PW1'), test.id('pw_r'), 'bring')$$);
select test.eq('one row per step', (select count(*) from booking_walkthrough_steps where booking_id = test.id('booking:CC-PW1')), 1::bigint);
select test.throws('another person cannot mark a step', $$select app.rental_walkthrough_ack(test.id('booking:CC-PW1'), test.id('pw_x'), 'meet')$$, '%renter of the booking%');
select test.throws('a task cannot be marked read (the walk-around)', $$select app.rental_walkthrough_ack(test.id('booking:CC-PW1'), test.id('pw_r'), 'inspect')$$, '%Unknown step%');
select test.eq('the renter reads it through the server function', public.server_my_walkthrough(test.id('booking:CC-PW1'), test.id('pw_r')) ->> 'read', '1');
select test.throws('another person cannot read it', $$select public.server_my_walkthrough(test.id('booking:CC-PW1'), test.id('pw_x'))$$, '%renter of the booking%');

select test.eq('on the road, mid-trip', app.rental_walkthrough(test.id('booking:CC-PW2'), test.pw_at('2027-04-10 12:00')) ->> 'stage', 'road');
select test.eq('the last day: the return', app.rental_walkthrough(test.id('booking:CC-PW2'), test.pw_at('2027-04-19 18:00')) ->> 'stage', 'return');
select test.eq('closed: the return, the check-in done and the deposit back', (select (w ->> 'stage') || '/' || (test.pw_step('CC-PW3', 'checkin') ->> 'done') || '/' || (test.pw_step('CC-PW3', 'deposit_back') ->> 'done')
  from (select app.rental_walkthrough(test.id('booking:CC-PW3')) w) x), 'return/true/true');
select test.eq('a cancelled booking has no walkthrough', app.rental_walkthrough(test.id('booking:CC-PW4')) ->> 'enabled', 'false');
select test.throws('nothing is marked on a cancelled booking', $$select app.rental_walkthrough_ack(test.id('booking:CC-PW4'), test.id('pw_x'), 'bring')$$, '%not going ahead%');
update program_settings set field_renter_walkthrough = false where id = (app.settings()).id;
select test.eq('turned off in Program settings: none', app.rental_walkthrough(test.id('booking:CC-PW1')) ->> 'enabled', 'false');
update program_settings set field_renter_walkthrough = true where id = (app.settings()).id;

-- the field job shows how much the renter read
select test.mk_user('pw_field', 'field');
insert into field_jobs (id, kind, booking_id, vehicle_id, assigned_to, scheduled_at, place)
values (test.id('job:pw1'), 'handover', test.id('booking:CC-PW1'), test.id('vehicle:PWA'), test.id('pw_field'), now() + interval '2 hours', '1 Example St');
select test.eq('the field job: the renter read 1 of 6', (select (j #>> '{walkthrough,read}') || '/' || (j #>> '{walkthrough,of}')
  from (select app.field_read(test.id('pw_field'), 'job', jsonb_build_object('id', test.id('job:pw1'))) j) x), '1/6');
select test.ok('the walkthrough functions are server only', not has_function_privilege('authenticated', 'public.server_my_walkthrough(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_my_walkthrough_ack(uuid, uuid, text)', 'execute'));
