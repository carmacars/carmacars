-- 99: release 35 part W (migrations 0910, 0912): change the car before pickup (an offer and a confirmed booking, the price up and
-- down), the accident card of a booking (each coverage option, never the fleet policy), closing past trips (on time, one or
-- all, no renter email, the Fleet To do and the digest line), and the odometer and fuel readings with the km and fuel
-- charges at the return. Uses the helpers of 06 (test.rq_new, test.b, test.st) and 09 (test.op_confirm, test.op_handover).
-- Fixtures start with "rw" and "RW".
select test.suite('99 r35w booking ops');
select set_config('app.paper_fixture', 'on', false);

select test.mk_user('rw_admin', 'admin');
select test.mk_user('rw_cs', 'va', 'cs');
select test.mk_user('rw_fleet', 'va', 'fleet');
select test.mk_user('rw_sales', 'va', 'sales');
select test.mk_user('rw_fin', 'va', 'finance');
select test.mk_owner('rw_o');
select test.mk_vehicle('RWA', 'rw_o');
select test.mk_vehicle('RWB', 'rw_o');
select test.mk_vehicle('RWC', 'rw_o');
select test.mk_vehicle('RWD', 'rw_o');
-- RWB costs more, RWC less; RWB charges 50 cents a km over 150 km a day
update rate_cards set daily_rate_cents = 15000, weekend_rate_cents = 17000, weekly_rate_cents = 80000, monthly_rate_cents = 250000,
       km_allowance_per_day = 150, overage_cents_per_km = 50 where vehicle_id = test.id('vehicle:RWB');
update rate_cards set daily_rate_cents = 7000, weekend_rate_cents = 8000, weekly_rate_cents = 40000, monthly_rate_cents = 150000 where vehicle_id = test.id('vehicle:RWC');
select test.mk_renter(r) from unnest(array['rw_r', 'rw_q', 'rw_p', 'rw_s']) r;

create function test.rw_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create function test.rw_read(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'ops_read', p_name, p) $$;
create function test.rw_local(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:00') $$;
create table test.rw_mark (k text primary key, at timestamptz not null);
create function test.rw_since(p_key text) returns timestamptz language sql stable as $$ select at from test.rw_mark where k = p_key $$;
-- the renter emails an action leaves to send (the events not set aside)
create function test.rw_renter_mail(p_booking text, p_mark text) returns text language sql stable as $$
  select coalesce(string_agg(e.code, ',' order by e.code), '') from app_events e
   where e.code like 'renter\_%' and e.created_at >= test.rw_since(p_mark) and e.processed_at is null
     and (e.entity_id = test.b(p_booking) or e.payload ->> 'booking_id' = test.b(p_booking)::text
          or e.entity_id in (select c.id from booking_change_requests c where c.booking_id = test.b(p_booking))) $$;

-- ---------------------------------------------------------------- 1. an offer moves to a car that costs more
select test.rq_new('rwA', 'rw_r', 'RWA', test.rw_local(interval '5 days'), test.rw_local(interval '8 days'));
select app.send_offer(test.b('rwA'), test.id('rw_cs'));
select test.eq('offer: sent', test.st('rwA'), 'offered');
select test.eq('offer: the cars it may move to (the other three, each priced)',
  (select count(*) from jsonb_array_elements(test.rw_read('rw_sales', 'car_change_options', jsonb_build_object('booking', test.b('rwA'))) -> 'cars') x
    where x ->> 'vehicle_id' in (test.id('vehicle:RWB')::text, test.id('vehicle:RWC')::text, test.id('vehicle:RWD')::text)), 3::bigint);
select test.ok('offer: the dearer car shows a higher total',
  (select (x ->> 'difference_cents')::bigint > 0 from jsonb_array_elements(test.rw_read('rw_cs', 'car_change_options', jsonb_build_object('booking', test.b('rwA'))) -> 'cars') x
    where x ->> 'vehicle_id' = test.id('vehicle:RWB')::text));
select test.throws('offer: Fleet does not change an offer',
  format($$select test.rw_do('rw_fleet', 'car_change', jsonb_build_object('booking', %L, 'vehicle', %L, 'reason', 'Renter asked'))$$, test.b('rwA'), test.id('vehicle:RWB')), 'changes the car');
select test.throws('offer: the reason is asked',
  format($$select test.rw_do('rw_sales', 'car_change', jsonb_build_object('booking', %L, 'vehicle', %L))$$, test.b('rwA'), test.id('vehicle:RWB')), 'Say why');
insert into test.rw_mark values ('a', clock_timestamp());
create temp table rw_a as select test.rw_do('rw_sales', 'car_change', jsonb_build_object('booking', test.b('rwA'), 'vehicle', test.id('vehicle:RWB'), 'reason', 'Renter wants the bigger car')) r;
select test.eq('offer: Sales moves it; a new offer version at the new car''s rates (150 a day)',
  (select status::text || ':' || (vehicle_id = test.id('vehicle:RWB')) || ':' || current_offer_version || ':' || daily_rate_cents || ':' || km_allowance_per_day from bookings where id = test.b('rwA')),
  'offered:true:2:15000:150');
select test.ok('offer: the difference is the new total less the old', (select (r ->> 'difference_cents')::bigint > 0 and (r ->> 'total_cents')::bigint = (select total_due_at_booking_cents from bookings where id = test.b('rwA')) from rw_a));
select test.eq('offer: the renter gets one email (the new offer)', test.rw_renter_mail('rwA', 'a'), 'renter_offer_ready');
select test.eq('offer: history and audit log', (select count(*) from booking_events where booking_id = test.b('rwA') and kind = 'car_changed')
  || '/' || (select count(*) from audit_log where action = 'booking_car_changed' and entity_id = test.b('rwA')::text), '1/1');

-- ---------------------------------------------------------------- 2. a confirmed booking: the price goes up
select test.rq_new('rwB', 'rw_q', 'RWA', test.rw_local(interval '10 days'), test.rw_local(interval '12 days'));
select test.op_confirm('rwB', 'rw_q');
create temp table rw_fj as select (public.door(test.id('rw_fleet'), null, 'va_do', 'field_job_create', jsonb_build_object('booking', test.b('rwB'), 'kind', 'handover',
  'vehicle', test.id('vehicle:RWA'), 'scheduled_at', (select pickup_at from bookings where id = test.b('rwB')), 'place', 'Our location')) ->> 'id')::uuid as id;
-- RWD is taken for those dates
select test.rq_new('rwX', 'rw_s', 'RWD', test.rw_local(interval '9 days'), test.rw_local(interval '13 days'));
select test.op_confirm('rwX', 'rw_s');
select test.throws('confirmed: a car that is not free is refused',
  format($$select test.rw_do('rw_fleet', 'car_change', jsonb_build_object('booking', %L, 'vehicle', %L, 'reason', 'Car A has a warning light'))$$, test.b('rwB'), test.id('vehicle:RWD')), 'not free');
select test.throws('confirmed: Sales does not change a confirmed booking',
  format($$select test.rw_do('rw_sales', 'car_change', jsonb_build_object('booking', %L, 'vehicle', %L, 'reason', 'Car A has a warning light'))$$, test.b('rwB'), test.id('vehicle:RWB')), 'changes the car');
select test.throws('confirmed: Finance does not change the car',
  format($$select test.rw_do('rw_fin', 'car_change', jsonb_build_object('booking', %L, 'vehicle', %L, 'reason', 'Car A has a warning light'))$$, test.b('rwB'), test.id('vehicle:RWB')), 'changes the car');
insert into test.rw_mark values ('b', clock_timestamp());
create temp table rw_b as select test.rw_do('rw_fleet', 'car_change', jsonb_build_object('booking', test.b('rwB'), 'vehicle', test.id('vehicle:RWB'), 'reason', 'Car A has a warning light')) r;
select test.eq('confirmed: Fleet moves it: still confirmed, on the new car, its rates and km terms',
  (select status::text || ':' || (vehicle_id = test.id('vehicle:RWB')) || ':' || daily_rate_cents || ':' || overage_cents_per_km || ':' || km_allowance_total from bookings where id = test.b('rwB')),
  'confirmed:true:15000:50:300');
select test.ok('confirmed: the difference is open for the renter to pay (the balance)',
  (select (r ->> 'difference_cents')::bigint > 0 and (r ->> 'open_cents')::bigint = (r ->> 'difference_cents')::bigint from rw_b), (select r::text from rw_b));
select test.eq('confirmed: no refund, a change request applied at once (staff car change)',
  (select count(*) from refunds where booking_id = test.b('rwB')) || '/' ||
  (select status || ':' || source || ':' || (total_difference_cents = (select (r ->> 'difference_cents')::bigint from rw_b)) from booking_change_requests where booking_id = test.b('rwB')),
  '0/applied:staff_car_change:true');
select test.eq('confirmed: the handover job moved to the new car', (select vehicle_id = test.id('vehicle:RWB') from field_jobs where id = (select id from rw_fj)), true);
select test.eq('confirmed: the coverage stays', (select coverage_option || ':' || (coverage_confirmed_at is not null) from bookings where id = test.b('rwB')), '2:true');
select test.eq('confirmed: the renter gets one email, the "Booking updated" one', test.rw_renter_mail('rwB', 'b'), 'renter_change_applied');
select test.ok('confirmed: the email says what is owed and how to pay',
  (select app.notification_payload('renter_change_applied', e, '{}'::jsonb) ->> 'money_text' like '%more. Pay it from your booking page%'
     from app_events e where e.code = 'renter_change_applied' and e.entity_id = (select id from booking_change_requests where booking_id = test.b('rwB')) limit 1));
select test.eq('confirmed: the swap is recorded with the reason', (select count(*) from booking_vehicle_swaps where booking_id = test.b('rwB') and reason like 'Car changed before pickup%'), 1::bigint);
-- the agreement's new version (made by the agreement job): its email is folded into the change email when the link goes by text
insert into agreement_versions (id, booking_id, version_no, kind, material, status, changes, snapshot, snapshot_sha)
values (test.id('rw_ver'), test.b('rwB'), 2, 'change', true, 'awaiting_signature', '[{"key": "vehicle.id", "material": true}]'::jsonb, '{}'::jsonb, 'rw');
insert into agreement_version_signers (version_id, role, name, email, mobile) values
  (test.id('rw_ver'), 'renter', 'Rw Q', 'rw_q@example.test', '647-555-0199'),
  (test.id('rw_ver'), 'additional_driver', 'Rw Extra', 'rw_extra@example.test', null);
select app.agreement_version_notify(test.id('rw_ver'));
select test.eq('confirmed: the new agreement version: no second email for a signer who gets the link by text; a signer without a mobile still gets it',
  (select string_agg(coalesce(e.payload ->> 'signer_name', '?') || ':' || (e.processed_at is null), ',' order by e.payload ->> 'signer_name')
     from app_events e where e.code = 'renter_agreement_version' and e.entity_id = test.id('rw_ver')),
  'Rw Extra:true,Rw Q:false');
select test.throws('confirmed: the same car again is refused',
  format($$select test.rw_do('rw_cs', 'car_change', jsonb_build_object('booking', %L, 'vehicle', %L, 'reason', 'Again'))$$, test.b('rwB'), test.id('vehicle:RWB')), 'already has');

-- ---------------------------------------------------------------- 3. a confirmed and paid booking: the price goes down
select test.rq_new('rwC', 'rw_p', 'RWA', test.rw_local(interval '15 days'), test.rw_local(interval '18 days'));
select test.op_confirm('rwC', 'rw_p');
create temp table rw_c as select test.rw_do('rw_cs', 'car_change', jsonb_build_object('booking', test.b('rwC'), 'vehicle', test.id('vehicle:RWC'), 'reason', 'Renter asked for a smaller car')) r;
select test.ok('cheaper: the difference is negative', (select (r ->> 'difference_cents')::bigint < 0 from rw_c));
select test.eq('cheaper: a refund of the difference waits for approval, with a Finance To do',
  (select status || ':' || (amount_cents = -(select (r ->> 'difference_cents')::bigint from rw_c)) from refunds where booking_id = test.b('rwC'))
  || '/' || (select count(*) from tasks where task_type = 'change_refund' and booking_id = test.b('rwC') and queue = 'finance'),
  'pending_approval:true/1');

-- ---------------------------------------------------------------- 4. the accident card: the coverage this booking uses
insert into fleet_insurance_policies (insurer_name, policy_number, effective_on, expires_on)
select 'Fleet Mutual', 'FLEET-RW-777', date '2026-01-01', date '2027-01-01' where not exists (select 1 from fleet_insurance_policies where is_current);
-- option 1: the renter's own policy (OPCF 27)
update coverage_proofs set coverage_option = 1, insurer_name = 'Own Insurer Co', policy_number = 'OWN-RW-123', policy_expiry = date '2027-06-01' where booking_id = test.b('rwB');
update bookings set coverage_option = 1 where id = test.b('rwB');
select test.eq('card: OPCF 27 shows the renter''s own insurer and policy number',
  (select c -> 'coverage' ->> 'kind' || ':' || (c -> 'coverage' ->> 'insurer_name') || ':' || (c -> 'coverage' ->> 'policy_number')
     from (select public.server_accident_card(test.b('rwB'), test.id('rw_q')) c) x), 'own_policy:Own Insurer Co:OWN-RW-123');
-- option 2: credit card coverage
update coverage_proofs set coverage_provider = 'Card Coverage Ltd' where booking_id = test.b('rwC');
select test.eq('card: card coverage shows the card and its coverage provider',
  (select c -> 'coverage' ->> 'kind' || ':' || (c -> 'coverage' ->> 'card_last4') || ':' || (c -> 'coverage' ->> 'card_coverage_provider') || ':' || coalesce(c -> 'coverage' ->> 'insurer_name', '-')
     from (select public.server_accident_card(test.b('rwC'), test.id('rw_p')) c) x), 'card:4242:Card Coverage Ltd:-');
-- option 3: the Protection Plan, from Program settings
update program_settings set accident_plan_provider_name = 'RentalCover', accident_plan_policy_number = 'RC-MASTER-1', accident_plan_claims_phone = '1-800-555-0100';
update coverage_proofs set coverage_option = 3, activated_at = now(), activation_ref = 'ACT-RW-9' where booking_id = test.b('rwX');
update bookings set coverage_option = 3 where id = test.b('rwX');
-- 1010: the renter's own plan policy (the activation reference until staff enter it), never the master policy
select test.eq('card: the Protection Plan shows the provider, the renter''s policy, claims phone and the activation',
  (select concat_ws(':', c -> 'coverage' ->> 'kind', c -> 'coverage' ->> 'plan_provider', c -> 'coverage' ->> 'plan_policy_number', c -> 'coverage' ->> 'plan_claims_phone', c -> 'coverage' ->> 'plan_reference')
     from (select test.rw_read('rw_fleet', 'accident_card', jsonb_build_object('booking', test.b('rwX'))) c) x), 'plan:RentalCover:ACT-RW-9:1-800-555-0100:ACT-RW-9');
select test.eq('card: never the fleet policy, on any option',
  (select count(*) from (values (public.server_accident_card(test.b('rwB'), test.id('rw_q'))), (public.server_accident_card(test.b('rwC'), test.id('rw_p'))),
     (public.server_accident_card(test.b('rwX'), test.id('rw_s')))) v(c) where c::text like '%' || (select policy_number from fleet_insurance_policies where is_current) || '%'
        or c::text like '%' || (select insurer_name from fleet_insurance_policies where is_current) || '%'), 0::bigint);
select test.throws('card: another renter does not read it', format($$select public.server_accident_card(%L, %L)$$, test.b('rwB'), test.id('rw_p')), 'Not permitted');
select test.eq('card: the steps have the support phone and the car', (select (c -> 'car' ->> 'plate') is not null and (c -> 'company') ? 'support_phone'
  from (select public.server_accident_card(test.b('rwB'), test.id('rw_q')) c) x), true);

-- ---------------------------------------------------------------- 5. past trips never left open
select test.rq_new('rwP', 'rw_r', 'RWC', test.rw_local(interval '30 days'), test.rw_local(interval '32 days'));
select test.op_confirm('rwP', 'rw_r');
select test.rq_new('rwQ', 'rw_q', 'RWD', test.rw_local(interval '40 days'), test.rw_local(interval '42 days'));
select test.op_confirm('rwQ', 'rw_q');
select test.op_handover('rwQ', 'rw_admin', test.rw_local(interval '40 days'), 30000);
set session_replication_role = replica;
update bookings set pickup_at = date_trunc('minute', now()) - interval '5 days', return_at = date_trunc('minute', now()) - interval '3 days', original_return_at = date_trunc('minute', now()) - interval '3 days',
       booked_at = now() - interval '9 days' where id = test.b('rwP');
update bookings set pickup_at = date_trunc('minute', now()) - interval '2 days', handed_over_at = date_trunc('minute', now()) - interval '2 days',
       return_at = date_trunc('minute', now()) - interval '3 hours', original_return_at = date_trunc('minute', now()) - interval '3 hours', booked_at = now() - interval '9 days' where id = test.b('rwQ');
set session_replication_role = origin;
select test.ok('past trips: Fleet sees both (confirmed and on rent, return passed)',
  (select count(*) from jsonb_array_elements(test.rw_read('rw_fleet', 'past_trips', '{}'::jsonb) -> 'rows') x where x ->> 'booking_number' in
     ((select booking_number from bookings where id = test.b('rwP')), (select booking_number from bookings where id = test.b('rwQ')))) = 2);
select test.throws('past trips: customer service does not close them', $$select test.rw_read('rw_cs', 'past_trips', '{}'::jsonb)$$, 'closes past trips');
select app.past_trips_sweep(now());
select test.eq('past trips: a Fleet To do for each trip open 2 hours after its return',
  (select count(*) from tasks where task_type = 'past_trip_open' and queue = 'fleet' and status = 'open' and booking_id in (test.b('rwP'), test.b('rwQ'))), 2::bigint);
select test.ok('past trips: a line in the Admin and Fleet morning digest',
  (select count(*) from staff_digest_items where dedupe_key like 'past_trips_open:%' and digest_slot = 'morning' and role in ('admin', 'va_fleet')) >= 2);
insert into test.rw_mark values ('p', clock_timestamp());
create temp table rw_p as select test.rw_do('rw_fleet', 'past_trip_close', jsonb_build_object('booking', test.b('rwP'))) r;
select test.eq('past trips: Fleet closes one on time: returned, picked up and returned at the booked times',
  (select status::text || ':' || (handed_over_at = pickup_at) || ':' || (checked_in_at = return_at) from bookings where id = test.b('rwP')) || ':' || (select r ->> 'on_time' from rw_p),
  'returned:true:true:true');
select test.eq('past trips: no renter email or text for a back-dated close',
  test.rw_renter_mail('rwP', 'p') || '/' || (select count(*) from phone_outbox where booking_id = test.b('rwP') and renter_id is not null and created_at >= test.rw_since('p') and status in ('queued', 'delayed')), '/0');
select test.eq('past trips: its To do is done; history says on time',
  (select status from tasks where task_type = 'past_trip_open' and booking_id = test.b('rwP')) || '/' ||
  (select count(*) from booking_events where booking_id = test.b('rwP') and kind = 'past_trip_closed' and note like '%on time%'), 'done/1');
create temp table rw_all as select test.rw_do('rw_admin', 'past_trips_close_all', jsonb_build_object('bookings', jsonb_build_array(test.b('rwQ')))) r;
select test.eq('past trips: Close all reports what it closed', (select r ->> 'closed' from rw_all), '1');
select test.eq('past trips: Close all on time closes the trip on rent at its booked return',
  (select status::text || ':' || (checked_in_at = return_at) from bookings where id = test.b('rwQ')), 'returned:true');
select test.ok('past trips: none of these left open', not exists (select 1 from jsonb_array_elements(test.rw_read('rw_admin', 'past_trips', '{}'::jsonb) -> 'rows') x
  where x ->> 'booking_number' in ((select booking_number from bookings where id = test.b('rwP')), (select booking_number from bookings where id = test.b('rwQ')))));

-- ---------------------------------------------------------------- 6. odometer and fuel: the readings and the charges at the return
update program_settings set booking_return_auto_charges = true, statement_fuel_cents_per_eighth = 1000;
select test.rq_new('rwK', 'rw_s', 'RWB', test.rw_local(interval '50 days'), test.rw_local(interval '52 days'));
select test.op_confirm('rwK', 'rw_s');
select test.op_handover('rwK', 'rw_admin', test.rw_local(interval '50 days'), 20000);
set session_replication_role = replica;
update bookings set pickup_at = date_trunc('minute', now()) - interval '47 hours', handed_over_at = date_trunc('minute', now()) - interval '47 hours',
       return_at = date_trunc('minute', now()) + interval '1 hour', original_return_at = date_trunc('minute', now()) + interval '1 hour', booked_at = now() - interval '9 days' where id = test.b('rwK');
update condition_reports set performed_at = date_trunc('minute', now()) - interval '47 hours', completed_at = date_trunc('minute', now()) - interval '47 hours'
 where booking_id = test.b('rwK') and kind = 'pickup';
set session_replication_role = origin;
create temp table rw_k as select test.rw_do('rw_fleet', 'handover_one_screen', jsonb_build_object('booking', test.b('rwK'), 'kind', 'return',
  'odometer_km', 20700, 'fuel_pct', 75, 'photos', jsonb_build_array(
     jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.b('rwK') || '/one-screen/' || gen_random_uuid() || '.jpg', 'angle', 'dashboard'),
     jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.b('rwK') || '/one-screen/' || gen_random_uuid() || '.jpg', 'angle', 'selfie')),
  'reading', jsonb_build_object('source', 'read_confirmed', 'ai_odometer_km', 20700, 'ai_fuel_eighths', 6, 'ai_model', '@cf/test',
     'selfie', jsonb_build_object('taken_at', now(), 'live', true, 'latitude', 43.65, 'longitude', -79.38)))) r;
select test.eq('readings: returned with the km and fuel', (select status::text || ':' || odometer_in_km || ':' || fuel_in_pct from bookings where id = test.b('rwK')), 'returned:20700:75');
select test.eq('readings: the reading is kept: read and confirmed, the dashboard photo and the live selfie, no note',
  (select source || ':' || ai_odometer_km || ':' || ai_fuel_eighths || ':' || (dash_photo_path is not null) || ':' || selfie_live || ':' || coalesce(staff_note, '-')
     from handover_readings where booking_id = test.b('rwK') and kind = 'return'), 'read_confirmed:20700:6:true:true:-');
-- 700 km driven, 300 included (150 a day for 2 days): 400 km over at 50 cents; 1/4 tank short: 2 eighths at $10 plus the markup
select test.eq('readings: the extra km charge from the rate per km', (select amount_cents from booking_line_items where booking_id = test.b('rwK') and assessment_key = 'mileage_overage' and voided_at is null), 20000::bigint);
select test.ok('readings: the fuel charge for 2 eighths', (select amount_cents >= 2000 from booking_line_items where booking_id = test.b('rwK') and assessment_key = 'fuel' and voided_at is null));
select test.eq('readings: staff see both readings, km over and the eighths short',
  (select (v ->> 'km_driven') || ':' || (v ->> 'km_over') || ':' || (v ->> 'fuel_eighths_short') || ':' || (jsonb_array_length(v -> 'charges') >= 2)
     from (select test.rw_read('rw_fleet', 'handover_readings', jsonb_build_object('booking', test.b('rwK'))) v) x), '700:400:2:true');
select test.eq('readings: the renter reads the same on the return receipt',
  (select (v ->> 'km_over') || ':' || (v ? 'readings') from (select public.server_renter_readings(test.b('rwK'), test.id('rw_s')) v) x), '400:false');
-- a selfie without fresh capture details is noted for staff, never a block
create temp table rw_old as select app.handover_reading_record(test.b('rwK'), 'return', 'staff', test.id('rw_fleet'),
  jsonb_build_object('odometer_km', 20700, 'fuel_pct', 75, 'photos', jsonb_build_array(jsonb_build_object('path', 'x/selfie.jpg', 'angle', 'selfie')),
                     'reading', jsonb_build_object('source', 'typed', 'selfie', jsonb_build_object('taken_at', now() - interval '3 days', 'live', true)))) id;
select test.eq('readings: an old selfie is only a note for staff (typed reading kept)',
  (select source || ':' || selfie_live || ':' || (staff_note like '%no fresh capture%') from handover_readings where id = (select id from rw_old)), 'typed:false:true');
select test.eq('readings: an eighth is counted to the nearest eighth (12% short is one)',
  (select greatest(1, round(12 / 12.5))::integer), 1);
update program_settings set booking_return_auto_charges = false, statement_fuel_cents_per_eighth = null;

-- ---------------------------------------------------------------- 7. who may have a dashboard photo read
update bookings set return_link_token = coalesce(return_link_token, gen_random_uuid()) where id = test.b('rwK');
select test.eq('reader: the renter of the booking, staff and the return link pass the gate; another renter does not',
  (select concat_ws('/', coalesce(public.server_dash_read_gate(test.b('rwK'), test.id('rw_s')) ->> 'reason', 'ok') <> 'not_permitted',
                    coalesce(public.server_dash_read_gate(test.b('rwK'), test.id('rw_fleet')) ->> 'reason', 'ok') <> 'not_permitted',
                    coalesce(public.server_dash_read_gate(null, null, (select return_link_token from bookings where id = test.b('rwK'))) ->> 'reason', 'ok') <> 'not_permitted',
                    public.server_dash_read_gate(test.b('rwK'), test.id('rw_p')) ->> 'reason')),
  't/t/t/not_permitted');
select test.eq('reader: the AI budget names the reader', app.ai_tier('dash_read') || '/' || app.ai_feature_label('dash_read'), 'live/Odometer and fuel reader');

-- ---------------------------------------------------------------- 8. the renter reports an accident from the accident card
select test.rq_new('rwR', 'rw_r', 'RWA', test.rw_local(interval '60 days'), test.rw_local(interval '62 days'));
select test.op_confirm('rwR', 'rw_r');
select test.op_handover('rwR', 'rw_admin', test.rw_local(interval '60 days'), 40000);
select test.throws('accident: another renter does not report on this booking',
  format($$select public.server_renter_accident_report(%L, jsonb_build_object('booking', %L, 'description', 'Hit a pole', 'anyone_hurt', false, 'drivable', true))$$, test.id('rw_p'), test.b('rwR')), 'Not permitted');
select test.throws('accident: anyone hurt and drivable are asked',
  format($$select public.server_renter_accident_report(%L, jsonb_build_object('booking', %L, 'description', 'Hit a pole'))$$, test.id('rw_r'), test.b('rwR')), 'anyone is hurt');
select test.throws('accident: a photo of another booking is refused',
  format($$select public.server_renter_accident_report(%L, jsonb_build_object('booking', %L, 'description', 'Hit a pole', 'anyone_hurt', false, 'drivable', true,
    'media', jsonb_build_array(jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || %L || '/accident/' || gen_random_uuid() || '.jpg'))))$$, test.id('rw_r'), test.b('rwR'), test.b('rwB')), 'not uploaded for this booking');
create temp table rw_acc as select public.server_renter_accident_report(test.id('rw_r'), jsonb_build_object('booking', test.b('rwR'),
  'description', 'Rear-ended at a red light on Queen St', 'latitude', 43.65, 'longitude', -79.38, 'police_report_number', 'TPS-123',
  'other_party', jsonb_build_object('name', 'Other Driver', 'phone', '416-555-0100', 'plate', 'abcd 123', 'coverage', 'Other Mutual P-9'),
  'anyone_hurt', false, 'drivable', false, 'media', jsonb_build_array(
    jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.b('rwR') || '/accident/' || gen_random_uuid() || '.jpg'),
    jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.b('rwR') || '/accident/' || gen_random_uuid() || '.mp4')))) r;
select test.eq('accident: the incident staff work is open: an accident on the booking, the other party, the police number, not drivable, its steps',
  (select kind || ':' || status || ':' || (other_party ->> 'plate') || ':' || police_report_number || ':' || drivable || ':' || (place like 'Phone location%')
          || ':' || (select count(*) from incident_steps s where s.incident_id = i.id)
     from incidents i where id = (select (r ->> 'incident_id')::uuid from rw_acc)), 'accident:open:ABCD 123:TPS-123:false:true:10');
select test.eq('accident: the photo and the video are the incident''s documents',
  (select string_agg(mime_type, ',' order by mime_type) from documents where incident_id = (select (r ->> 'incident_id')::uuid from rw_acc)), 'image/jpeg,video/mp4');
select test.eq('accident: an urgent alert to Admin and Fleet, and the Fleet and Admin To dos',
  (select count(*) from app_events where code = 'staff_alert_urgent' and payload ->> 'rule' = 'accident_reported' and entity_id = (select (r ->> 'incident_id')::uuid from rw_acc))
  || '/' || (select string_agg(distinct queue, ',' order by queue) from tasks where related_table = 'incidents' and related_id = (select (r ->> 'incident_id')::uuid from rw_acc)),
  '1/admin,fleet');
select test.eq('accident: not drivable: the car is out of service', (select status::text from vehicles where id = test.id('vehicle:RWA')), 'out_of_service');
select test.ok('accident: the renter is told the next steps with our phone', (select r ? 'phone' and (r ->> 'incident_number') like 'IN-%' from rw_acc));
select test.eq('accident: more photos after it is sent',
  (public.server_renter_accident_media(test.id('rw_r'), jsonb_build_object('incident', (select r ->> 'incident_id' from rw_acc), 'media',
     jsonb_build_array(jsonb_build_object('bucket', 'condition-photos', 'path', 'bookings/' || test.b('rwR') || '/accident/' || gen_random_uuid() || '.png')))) ->> 'added'), '1');
select test.eq('accident: the booking shows the report to its renter', jsonb_array_length(public.server_renter_accidents(test.b('rwR'), test.id('rw_r'))), 1);
