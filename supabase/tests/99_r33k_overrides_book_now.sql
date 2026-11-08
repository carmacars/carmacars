-- 99: release 33 part K (migration 0770, docs/changes/2026-11-07-r33-overrides-book-now.md): the Admin override on a
-- pickup or a return recorded by hand (staff ask, an Admin approves in one tap), a past trip recorded in one step, and
-- an offer booked at once (Book it now). Uses the helpers of 06 (test.rq_new, test.b), 09 (test.op_confirm,
-- test.op_deposit_payment) and 82 (test.ho_local). Fixtures start with "rk" and "RK".
select test.suite('99 r33k overrides and book now');
select set_config('app.paper_fixture', 'on', false);

select test.mk_user('rk_admin', 'admin');
select test.mk_user('rk_fleet', 'va', 'fleet');
select test.mk_user('rk_cs', 'va', 'cs');
select test.mk_user('rk_fin', 'va', 'finance');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('rk_cs'), test.id('rk_fin'));
select test.mk_owner('rk_o');
select test.mk_vehicle('RKV', 'rk_o');
select test.mk_vehicle('RKW', 'rk_o');
select test.mk_renter('rk_r');
select test.mk_renter('rk_q');
create function test.rk_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'ops_do', p_name, p) $$;
create function test.rk_view(p_user text, p_key text) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'ops_read', 'handover_blockers', jsonb_build_object('booking', test.b(p_key))) $$;
create function test.rk_codes(p jsonb) returns text language sql immutable as $$
  select coalesce(string_agg(x ->> 'code', ',' order by x ->> 'code'), '') from jsonb_array_elements(p -> 'blockers') x $$;

-- ---------------------------------------------------------------- 1. the pickup: Fleet asks, an Admin approves
select test.rq_new('rkA', 'rk_r', 'RKV', test.ho_local(interval '3 hours'), test.ho_local(interval '2 days 3 hours'));
select test.op_confirm('rkA', 'rk_r');
select test.throws('pickup: without the deposit Fleet is refused as before',
  format($$select test.rk_do('rk_fleet', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'Phone died at the lot'))$$, test.b('rkA')), 'deposit is not taken');
select test.ok('pickup: the booking page lists what blocks it (the deposit, the renter''s signature on the report)',
  test.rk_codes(test.rk_view('rk_fleet', 'rkA')) like '%deposit%report_signature%' and (test.rk_view('rk_fleet', 'rkA') ->> 'kind') = 'pickup'
  and not (test.rk_view('rk_fleet', 'rkA') ->> 'admin')::boolean, test.rk_view('rk_fleet', 'rkA')::text);
select test.throws('pickup: the reason is asked',
  format($$select test.rk_do('rk_fleet', 'handover_override', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'no'))$$, test.b('rkA')), 'Say why');
select test.throws('pickup: Finance does not ask',
  format($$select test.rk_do('rk_fin', 'handover_override', jsonb_build_object('booking', %L, 'kind', 'pickup', 'reason', 'Renter at the lot'))$$, test.b('rkA')), 'check-in or check-out');
create temp table rk_q1 as select test.rk_do('rk_fleet', 'handover_override', jsonb_build_object('booking', test.b('rkA'), 'kind', 'pickup',
  'reason', 'Renter at the lot, deposit by e-Transfer tonight', 'at', now() - interval '20 minutes', 'odometer_km', 20000, 'fuel_pct', 90)) r;
select test.eq('pickup: Fleet''s request waits for an Admin; the booking does not move',
  (select r ->> 'status' from rk_q1) || '/' || test.st('rkA'), 'requested/confirmed');
select test.eq('pickup: an Admin has a To do and an alert; the history says who asked',
  (select count(*) || ':' || min(queue) from tasks where task_type = 'override_approve' and related_id = (select (r ->> 'id')::uuid from rk_q1) and status = 'open')
  || '/' || (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'override_requested' and entity_id = (select (r ->> 'id')::uuid from rk_q1))
  || '/' || (select count(*) from booking_events where booking_id = test.b('rkA') and kind = 'handover_override' and note like '%asked an Admin%'),
  '1:admin/1/1');
select test.eq('pickup: the request is on the booking page', jsonb_array_length(test.rk_view('rk_admin', 'rkA') -> 'requests'), 1);
select test.throws('pickup: Fleet does not approve its own request',
  format($$select test.rk_do('rk_fleet', 'override_decide', jsonb_build_object('id', %L, 'decision', 'approve'))$$, (select r ->> 'id' from rk_q1)), 'An Admin approves');
select test.eq('pickup: no override applies outside its transaction', app.override_skips(test.b('rkA'), 'deposit'), false);
create temp table rk_a1 as select test.rk_do('rk_admin', 'override_decide', jsonb_build_object('id', (select r ->> 'id' from rk_q1), 'decision', 'approve')) r;
select test.eq('pickup: approved in one tap: on rent at the time Fleet entered, with their km; the deposit is not waived (still to collect)',
  (select r ->> 'status' from rk_a1) || '/' || (select status::text || ':' || odometer_out_km || ':' || (abs(extract(epoch from handed_over_at - (now() - interval '20 minutes'))) < 5) || ':' || (deposit_waived_at is null)
     from bookings where id = test.b('rkA')),
  'recorded/on_rent:20000:true:true');
select test.eq('pickup: the override is used, with its checks; the To do closed; history, audit log and an alert to Admins',
  (select status || ':' || (checks @> array['deposit', 'report_signature']) from booking_overrides where id = (select (r ->> 'id')::uuid from rk_q1))
  || '/' || (select status from tasks where task_type = 'override_approve' and related_id = (select (r ->> 'id')::uuid from rk_q1))
  || '/' || (select count(*) from booking_events where booking_id = test.b('rkA') and kind = 'handover_override' and note like 'Pickup recorded with an Admin override%asked by%')
  || '/' || (select count(*) from audit_log where action = 'booking_override_used' and entity_id = test.b('rkA')::text)
  || '/' || (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'override_used' and entity_id = (select (r ->> 'id')::uuid from rk_q1)),
  'used:true/done/1/1/1');
select test.throws('pickup: a used override is spent',
  format($$select test.rk_do('rk_admin', 'override_decide', jsonb_build_object('id', %L, 'decision', 'approve'))$$, (select r ->> 'id' from rk_q1)), 'already used');
-- the override never passes another booking, nor after it is used
select set_config('app.booking_override', (select r ->> 'id' from rk_q1), false);
select test.eq('scope: a used override passes nothing, even with its id set', app.override_skips(test.b('rkA'), 'deposit'), false);
select set_config('app.booking_override', '', false);

-- ---------------------------------------------------------------- 2. the return: the odometer below pickup, an Admin at once
select test.throws('return: an odometer below pickup is refused as before',
  format($$select test.rk_do('rk_admin', 'handover_record_now', jsonb_build_object('booking', %L, 'kind', 'return', 'reason', 'Keys in the drop box', 'odometer_km', 19000))$$, test.b('rkA')), 'lower than at pickup');
create temp table rk_r1 as select test.rk_do('rk_admin', 'handover_override', jsonb_build_object('booking', test.b('rkA'), 'kind', 'return',
  'reason', 'Odometer typed wrong at pickup', 'at', now() - interval '5 minutes', 'odometer_km', 19000)) r;
select test.eq('return: an Admin overrides and records at once: returned, the deposit can be settled',
  (select r ->> 'status' from rk_r1) || '/' || test.st('rkA') || '/' || (select odometer_in_km from bookings where id = test.b('rkA'))
  || '/' || (select checks::text from booking_overrides where booking_id = test.b('rkA') and action = 'return'),
  'recorded/returned/19000/{odometer}');

-- ---------------------------------------------------------------- 3. a past trip (the real case: a trip that was never recorded)
select test.rq_new('rkB', 'rk_q', 'RKW', test.ho_local(interval '3 hours'), test.ho_local(interval '3 days 3 hours'));
select test.op_confirm('rkB', 'rk_q');
set session_replication_role = replica;
update bookings set pickup_at = now() - interval '7 days', return_at = now() - interval '4 days', booked_at = now() - interval '9 days' where id = test.b('rkB');
update vehicles set status = 'available' where id = test.id('vehicle:RKW');
set session_replication_role = origin;
select test.eq('past trip: offered on the booking page', (test.rk_view('rk_cs', 'rkB') ->> 'past_trip')::boolean, true);
select test.throws('past trip: the return is after the pickup',
  format($$select test.rk_do('rk_admin', 'handover_override', jsonb_build_object('booking', %L, 'kind', 'past_trip', 'reason', 'Trip never recorded', 'pickup_at', now() - interval '2 days', 'return_at', now() - interval '3 days'))$$, test.b('rkB')), 'after the pickup');
select test.throws('past trip: both times in the past',
  format($$select test.rk_do('rk_admin', 'handover_override', jsonb_build_object('booking', %L, 'kind', 'past_trip', 'reason', 'Trip never recorded', 'pickup_at', now() - interval '2 days', 'return_at', now() + interval '3 days'))$$, test.b('rkB')), 'both times in the past');
-- customer service asks; an Admin declines: nothing moves
create temp table rk_q2 as select test.rk_do('rk_cs', 'handover_override', jsonb_build_object('booking', test.b('rkB'), 'kind', 'past_trip', 'reason', 'Trip happened, never recorded',
  'pickup_at', now() - interval '7 days', 'return_at', now() - interval '4 days')) r;
select test.lives('past trip: an Admin declines', format($$select test.rk_do('rk_admin', 'override_decide', jsonb_build_object('id', %L, 'decision', 'decline', 'note', 'Check the dates'))$$, (select r ->> 'id' from rk_q2)));
select test.eq('past trip: declined, nothing moved, the To do closed',
  (select status from booking_overrides where id = (select (r ->> 'id')::uuid from rk_q2)) || '/' || test.st('rkB')
  || '/' || (select status from tasks where task_type = 'override_approve' and related_id = (select (r ->> 'id')::uuid from rk_q2)), 'declined/confirmed/done');
update vehicles set status = 'cleaning' where id = test.id('vehicle:RKW');
create temp table rk_p1 as select test.rk_do('rk_admin', 'handover_override', jsonb_build_object('booking', test.b('rkB'), 'kind', 'past_trip', 'reason', 'Trip Oct 31 to Nov 3 never recorded',
  'pickup_at', now() - interval '7 days', 'return_at', now() - interval '4 days 1 hour', 'odometer_out_km', 30000, 'odometer_in_km', 30600)) r;
select test.eq('past trip: one step: returned with both times and the km; the car''s status now is left alone (cleaning, so not available, was overridden)',
  (select r ->> 'booking_status' from rk_p1) || '/' || (select (abs(extract(epoch from handed_over_at - (now() - interval '7 days'))) < 5)::text || ':' || (abs(extract(epoch from checked_in_at - (now() - interval '4 days 1 hour'))) < 5) || ':' || odometer_out_km || ':' || odometer_in_km from bookings where id = test.b('rkB'))
  || '/' || (select status::text from vehicles where id = test.id('vehicle:RKW'))
  || '/' || (select checks @> array['vehicle_status', 'deposit'] from booking_overrides where booking_id = test.b('rkB') and status = 'used'),
  'returned/true:true:30000:30600/cleaning/true');
select test.eq('past trip: the "rental started" email of a trip long over is not sent',
  (select count(*) from notification_outbox where booking_id = test.b('rkB') and code = 'renter_rental_started' and status in ('queued', 'delayed')), 0::bigint);

-- ---------------------------------------------------------------- 4. Book it now
do $$
begin
  insert into test.rq_ids select 'rkcar', (app.vehicle_add(test.id('rk_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1XFCXMM0000009881',
    'plate', 'RK881', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000))) ->> 'vehicle_id')::uuid;
end $$;
create function test.rk_offer(p_user text, p_email text, p_from interval, p_book boolean) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'ops_do', 'offer_create', jsonb_build_object('vehicle_id', test.b('rkcar'),
    'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_from + interval '3 days',
    'renter', jsonb_build_object('full_name', 'Rhea Book', 'email', p_email, 'mobile', '(289) 555-0' || (700 + extract(day from p_from)::int), 'date_of_birth', '1990-05-06'),
    'coverage_option', 1, 'sales_choice', 'sourced', 'channels', jsonb_build_object('email', true, 'text', false), 'notify', true, 'book_now', p_book)) $$;
create temp table rk_o1 as select test.rk_offer('rk_admin', 'rhea.book@example.test', interval '6 days', true) r;
select test.eq('book now (Admin): the offer is the approved version at once; waiting for payment; the history says so',
  (select r #>> '{book_now,status}' from rk_o1) || '/' || (select status::text || ':' || (offer_approved_version = current_offer_version) || ':' || (offer_approved_by = test.id('rk_admin'))
     from bookings where id = (select (r ->> 'booking_id')::uuid from rk_o1))
  || '/' || (select count(*) from booking_events where booking_id = (select (r ->> 'booking_id')::uuid from rk_o1) and kind = 'offer_booked_now' and note like 'Booked now by%'),
  'approved/pending_payment:true:true/1');
select test.ok('book now (Admin): the renter''s user comes back for the Sign and pay link', (select r #>> '{book_now,renter_user_id}' from rk_o1) is not null);
select test.eq('book now (Admin): the "approve your offer" email is skipped (the Sign and pay link is the one link)',
  (select count(*) from notification_outbox where booking_id = (select (r ->> 'booking_id')::uuid from rk_o1) and code = 'renter_offer_ready' and status in ('queued', 'delayed')), 0::bigint);
-- the car is held as for an approved offer: another offer for overlapping dates is refused
select test.throws('book now: the car is held for the booked dates',
  $$select test.rk_offer('rk_cs', 'rhea.two@example.test', interval '7 days', true)$$, 'not available');
create temp table rk_o3 as select test.rk_offer('rk_cs', 'rhea.three@example.test', interval '20 days', true) r;
select test.eq('book now (customer service): the offer goes out and waits for an Admin; a To do and an alert',
  (select r #>> '{book_now,status}' from rk_o3) || '/' || (select count(*) from tasks where task_type = 'override_approve' and booking_id = (select (r ->> 'booking_id')::uuid from rk_o3) and status = 'open')
  || '/' || (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'override_requested' and entity_id = (select (r #>> '{book_now,id}')::uuid from rk_o3)),
  'requested/1/1');
create temp table rk_a3 as select test.rk_do('rk_admin', 'override_decide', jsonb_build_object('id', (select r #>> '{book_now,id}' from rk_o3), 'decision', 'approve')) r;
select test.eq('book now (customer service): an Admin approves in one tap: waiting for payment, the To do closed',
  (select r ->> 'status' from rk_a3) || '/' || (select status::text from bookings where id = (select (r ->> 'booking_id')::uuid from rk_o3))
  || '/' || (select status from tasks where task_type = 'override_approve' and booking_id = (select (r ->> 'booking_id')::uuid from rk_o3)), 'approved/pending_payment/done');
select test.throws('book now: Finance does not book offers',
  format($$select app.offer_book_now(%L, %L)$$, test.id('rk_fin'), (select r ->> 'booking_id' from rk_o3)), 'books an offer');
create temp table rk_o4 as select test.rk_offer('rk_cs', 'rhea.four@example.test', interval '40 days', false) r;
select test.eq('book now: without the flag the offer is sent as before',
  (select status::text from bookings where id = (select (r ->> 'booking_id')::uuid from rk_o4)) || '/' || (select (r ? 'book_now')::text from rk_o4), 'offered/false');

-- ---------------------------------------------------------------- 5. payment due: an Admin starts the trip anyway
insert into test.rq_ids select 'rkD', (r ->> 'booking_id')::uuid from rk_o1;
select test.ok('payment due: listed as a blocker of the pickup', test.rk_codes(test.rk_view('rk_admin', 'rkD')) like '%payment%');
create temp table rk_d1 as select test.rk_do('rk_admin', 'handover_override', jsonb_build_object('booking', test.b('rkD'), 'kind', 'pickup', 'reason', 'Renter paying cash at the counter')) r;
select test.eq('payment due: confirmed by the override, then on rent; the history says the payment is still due',
  (select r ->> 'booking_status' from rk_d1) || '/' || (select count(*) from booking_events where booking_id = test.b('rkD') and kind = 'confirmed' and note like '%payment is still due%'),
  'on_rent/1');
