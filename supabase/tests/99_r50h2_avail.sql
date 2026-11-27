-- 99: r50 hotfix2 (5111, 5195, REQ-126): CC-10674. An offer moves to a car whose last rental is still "confirmed" with its
-- pickup never recorded (the 2021 Kia Forte after CC-10602, status cleaning): the car is free, the car changes (Admin and
-- the connector's revise_offer), and the offer is booked. Every refusal names the booking or calendar block in the way.
-- Fixtures start with "av"; every address is example.test.
select test.suite('99 r50 hotfix2: availability names the blocker, an unclosed past trip never blocks');
select app.expire_unpaid(now() + interval '1 year', true);

select test.mk_user('av_admin', 'admin');
select test.mk_owner('av_own');
select test.mk_vehicle('AVA', 'av_own');   -- the car of the offer (the RAV4)
select test.mk_vehicle('AVF', 'av_own');   -- the car it moves to (the Forte)
select test.mk_vehicle('AVB', 'av_own');   -- a car booked over the dates
select test.mk_vehicle('AVC', 'av_own');   -- a car with a calendar block over the dates
select test.mk_renter('av_r');
select test.mk_renter('av_r2');
create function pg_temp.t(p interval) returns text language sql stable as $$ select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
create function pg_temp.bk(p text) returns bookings language sql as $$ select * from bookings where booking_number = p $$;

-- the Forte: in cleaning, its last rental confirmed with the pickup never recorded and the return yesterday (CC-10602)
update vehicles set status = 'cleaning' where id = test.id('vehicle:AVF');
select test.mk_booking('AV-OLD', 'AVF', 'av_r2', pg_temp.t(interval '-4 days'), pg_temp.t(interval '-1 day'), 'confirmed');
-- a confirmed rental over the dates on AVB, and a service block over the dates on AVC
select test.mk_booking('AV-BUSY', 'AVB', 'av_r2', pg_temp.t(interval '3 days'), pg_temp.t(interval '6 days'), 'confirmed');
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, created_by)
values (test.id('vehicle:AVC'), 'service', now() + interval '10 days', now() + interval '12 days', 'Brakes', test.id('av_admin'));

-- CC-10674: a request on AVA, pickup in 20 minutes, a month long, sent as an offer
select test.mk_booking('AV-1', 'AVA', 'av_r', pg_temp.t(interval '20 minutes'), pg_temp.t(interval '31 days 4 hours'), 'requested');
update payments set status = 'cancelled' where booking_id = test.id('booking:AV-1');
select app.send_offer(test.id('booking:AV-1'), test.id('av_admin'));
select test.eq('the offer is out', (pg_temp.bk('AV-1')).status::text, 'offered');

-- ================================================================ 1. the unclosed past trip does not block (5111)
select test.eq('the Forte is free for the offer''s dates although its last rental was never closed',
  app.vehicle_is_available(test.id('vehicle:AVF'), (pg_temp.bk('AV-1')).pickup_at, (pg_temp.bk('AV-1')).return_at, test.id('booking:AV-1')), true);
select test.eq('...and nothing is named as blocking it', app.vehicle_blocker(test.id('vehicle:AVF'), (pg_temp.bk('AV-1')).pickup_at, (pg_temp.bk('AV-1')).return_at, test.id('booking:AV-1')), null);
select test.eq('Change the car lists the Forte (status cleaning)',
  exists (select 1 from jsonb_array_elements(app.car_change_options(test.id('av_admin'), jsonb_build_object('booking', 'AV-1')) -> 'cars') x where x ->> 'vehicle_id' = test.id('vehicle:AVF')::text), true);

-- ================================================================ 2. the refusal names the blocker (5195)
select test.eq('a booked car: the refusal names the booking, its status and dates',
  app.car_change_refusal(pg_temp.bk('AV-1'), test.id('vehicle:AVB')) like 'That car is not free for the whole of these dates: blocked by booking AV-BUSY (confirmed, %', true);
select test.eq('a blocked car: the refusal names the block, its reason and its source',
  app.car_change_refusal(pg_temp.bk('AV-1'), test.id('vehicle:AVC')) like '%blocked by a calendar block (service, added by staff, %', true);
select test.throws('the booking write names the booking in the way',
  $$select test.mk_booking('AV-2', 'AVB', 'av_r', pg_temp.t(interval '20 days'), pg_temp.t(interval '21 days'), 'confirmed');
    update bookings set pickup_at = now() + interval '4 days', return_at = now() + interval '5 days' where id = test.id('booking:AV-2')$$,
  'not available for these dates: blocked by booking AV-BUSY');
select test.throws('sending an offer names the booking in the way',
  $$select test.mk_booking('AV-3', 'AVB', 'av_r', pg_temp.t(interval '4 days'), pg_temp.t(interval '5 days'), 'requested');
    select app.send_offer(test.id('booking:AV-3'), test.id('av_admin'))$$,
  'blocked by booking AV-BUSY');

-- ================================================================ 3. the car changes on the offer, through revise_offer
select test.throws('revise_offer to a booked car is refused with the blocker',
  $$select app.door(test.id('av_admin'), 'aal2', 'ops_do', 'offer_revise', jsonb_build_object('booking', 'AV-1', 'vehicle_id', test.id('vehicle:AVB'), 'notify', false, 'reason', 'Renter wants a smaller car'))$$,
  'blocked by booking AV-BUSY');
select test.eq('revise_offer moves the offer to the Forte: still an offer, a new version on the Forte',
  (select (r ->> 'status') || ':' || ((pg_temp.bk('AV-1')).vehicle_id = test.id('vehicle:AVF')) || ':' || ((pg_temp.bk('AV-1')).current_offer_version > 1)
     from (select app.door(test.id('av_admin'), 'aal2', 'ops_do', 'offer_revise', jsonb_build_object('booking', 'AV-1', 'vehicle_id', test.id('vehicle:AVF'), 'notify', false, 'reason', 'Renter wants a smaller car')) r) z),
  'offered:true:true');
select test.eq('...the version out is the Forte''s, and the renter was not told',
  (select (o.status = 'sent')::text || ':' || not exists (select 1 from notification_outbox n where n.booking_id = test.id('booking:AV-1') and n.code = 'renter_offer_ready' and n.created_at >= now() - interval '1 second' and n.status in ('queued', 'delayed', 'sent'))
     from booking_offers o where o.booking_id = test.id('booking:AV-1') and o.version = (pg_temp.bk('AV-1')).current_offer_version), 'true:true');

-- ================================================================ 4. the offer is put through on the Forte
select test.lives('Renter approved by phone books it on the Forte',
  $$select app.door(test.id('av_admin'), 'aal2', 'admin_do', 'approve_offer_by_phone', jsonb_build_object('booking', test.id('booking:AV-1'), 'expected_version', (pg_temp.bk('AV-1')).current_offer_version, 'override_reason', 'Licence checked at the counter'))$$);
select test.eq('...waiting for payment, and it holds the Forte', (pg_temp.bk('AV-1')).status::text || ':' ||
  app.vehicle_is_available(test.id('vehicle:AVF'), (pg_temp.bk('AV-1')).pickup_at, (pg_temp.bk('AV-1')).return_at, null), 'pending_payment:false');
select test.eq('...and a second booking on the Forte is told which booking holds it',
  app.vehicle_blocker(test.id('vehicle:AVF'), (pg_temp.bk('AV-1')).pickup_at, (pg_temp.bk('AV-1')).return_at, null) like 'booking AV-1 (pending payment, %', true);

-- ================================================================ 5. grants
select test.eq('vehicle_blocker and offer_revise_pre5195 run for the server only',
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('vehicle_blocker', 'offer_revise_pre5195', 'vehicle_status_set', 'detail_done_car_available')
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0);



-- ================================================================ 6. cleaning never stops a rental, and is cleared (5195)
select test.mk_vehicle('AVK', 'av_own');
update vehicles set status = 'cleaning' where id = test.id('vehicle:AVK');
select test.mk_booking('AV-K', 'AVK', 'av_r2', pg_temp.t(interval '-1 hour'), pg_temp.t(interval '2 days'), 'confirmed');
select test.eq('the pickup of a car in cleaning lists no car status problem (CC-10602 could not be handed over)',
  exists (select 1 from jsonb_array_elements(app.handover_blockers(test.id('av_admin'), test.id('booking:AV-K'), 'pickup', '{}'::jsonb)) x where x ->> 'code' = 'vehicle_status'), false);
select test.eq('...and the handover itself takes a car in cleaning', position($q$'ready_to_list', 'cleaning')$q$ in pg_get_functiondef('app.booking_after_status()'::regprocedure)) > 0, true);
select test.mk_vehicle('AVD', 'av_own');
update vehicles set status = 'cleaning' where id = test.id('vehicle:AVD');
insert into field_jobs (vehicle_id, kind, status, scheduled_at) values (test.id('vehicle:AVD'), 'detail', 'scheduled', now());
update field_jobs set status = 'done', completed_at = now() where vehicle_id = test.id('vehicle:AVD') and kind = 'detail';
select test.eq('the detail job marked done puts the car back to available', (select status::text from vehicles where id = test.id('vehicle:AVD')), 'available');

-- ================================================================ 7. set_car_status (the connector, admin_do vehicle_status_set)
update vehicles set status = 'cleaning' where id = test.id('vehicle:AVD');
select test.throws('a reason is needed', $$select app.door(test.id('av_admin'), 'aal2', 'admin_do', 'vehicle_status_set', jsonb_build_object('vehicle_id', test.id('vehicle:AVD'), 'status', 'available'))$$, 'Say why');
select test.throws('only a move the status rules allow', $$select app.door(test.id('av_admin'), 'aal2', 'admin_do', 'vehicle_status_set', jsonb_build_object('vehicle_id', test.id('vehicle:AVD'), 'status', 'on_rent', 'reason', 'Test move'))$$, 'A car goes from cleaning to');
select test.eq('an Admin sets it available',
  app.door(test.id('av_admin'), 'aal2', 'admin_do', 'vehicle_status_set', jsonb_build_object('vehicle_id', test.id('vehicle:AVD'), 'status', 'available', 'reason', 'Cleaned on Nov 26')) ->> 'status', 'available');
select test.eq('...logged with the reason', (select after ->> 'reason' from audit_log where action = 'vehicle_status_set' and entity_id = test.id('vehicle:AVD')::text order by at desc, id desc limit 1), 'Cleaned on Nov 26');
select test.eq('the connector maps set_car_status to it', app.api_action('set_car_status') ->> 'name', 'vehicle_status_set');
