-- 99: R51 cleaning only when the return report says so (migration 5303, REQ-133; docs/changes/2026-11-27-r51-staff.md).
-- A return with a clean report leaves the car available; a report that says cleaning puts it in cleaning, before or after
-- the return; the detail job then closes it (5195). Fixtures "rc51".
select test.suite('99 r51 return clean: available after a return unless the report says cleaning');

select test.mk_user('rc51_admin', 'admin');
select test.mk_owner('rc51_own');
select test.mk_vehicle('RC51A', 'rc51_own');
select test.mk_vehicle('RC51B', 'rc51_own');
select test.mk_vehicle('RC51C', 'rc51_own');
select test.mk_renter('rc51_r');
create function pg_temp.out(p_number text, p_car text) returns void language plpgsql as $$
begin
  update vehicles set status = 'on_rent' where id = test.id('vehicle:' || p_car);
  perform test.mk_booking(p_number, p_car, 'rc51_r', (now() - interval '3 days')::text, (now() + interval '1 hour')::text, 'on_rent');
end $$;
create function pg_temp.back(p_number text) returns void language sql as
$$ update bookings set status = 'returned', checked_in_at = now() where booking_number = $1 $$;
create function pg_temp.report(p_number text, p_car text, p_clean text) returns void language sql as $$
  insert into condition_reports (vehicle_id, booking_id, kind, performed_by_role, cleanliness, odometer_km, fuel_pct)
  values (test.id('vehicle:' || p_car), test.id('booking:' || p_number), 'return', 'staff', p_clean, 42000, 90) $$;
create function pg_temp.st(p_car text) returns text language sql as $$ select status::text from vehicles where id = test.id('vehicle:' || p_car) $$;

-- a clean report, then the return: available at once
select pg_temp.out('RC51-1', 'RC51A');
select test.eq('out: on rent', pg_temp.st('RC51A'), 'on_rent');
select pg_temp.report('RC51-1', 'RC51A', 'clean');
select pg_temp.back('RC51-1');
select test.eq('a clean return: available, no cleaning step', pg_temp.st('RC51A'), 'available');

-- a return needs its report (the check-out rule); the report changed afterwards to say cleaning moves the car
select pg_temp.out('RC51-2', 'RC51B');
select pg_temp.report('RC51-2', 'RC51B', 'clean');
select pg_temp.back('RC51-2');
select test.eq('returned clean: available', pg_temp.st('RC51B'), 'available');
update condition_reports set cleanliness = 'heavy' where booking_id = test.id('booking:RC51-2') and kind = 'return';
select test.eq('the report then says it needs cleaning: cleaning', pg_temp.st('RC51B'), 'cleaning');

-- a report that says cleaning, then the return: cleaning
select pg_temp.out('RC51-3', 'RC51C');
select pg_temp.report('RC51-3', 'RC51C', 'pet');
select pg_temp.back('RC51-3');
select test.eq('a return whose report says cleaning: cleaning', pg_temp.st('RC51C'), 'cleaning');
select test.eq('the rule reads the latest return report', app.return_needs_cleaning(test.id('booking:RC51-3')), true);
select test.eq('a clean report needs no cleaning', app.return_needs_cleaning(test.id('booking:RC51-1')), false);
select test.eq('the status rules allow on rent to available', (select count(*) from status_transitions where entity = 'vehicle' and from_status = 'on_rent' and to_status = 'available'), 1::bigint);
