-- 99: release 44, part A (migration 2792). Which cars are free for a pickup and a return: available or not with the
-- reason, the next free start for the same length, available first; for Admins, customer service, Sales and fleet only;
-- no renter named.
select test.suite('99 r44 availability a');

select test.mk_user('r44av_sales', 'va', 'sales');
select test.mk_user('r44av_fin', 'va', 'finance');
select test.mk_owner('r44av_owner');
select test.mk_vehicle('r44av_free', 'r44av_owner');
select test.mk_vehicle('r44av_booked', 'r44av_owner');
select test.mk_vehicle('r44av_shop', 'r44av_owner');
select test.mk_renter('r44av_renter');
select test.mk_booking('R44AV-1', 'r44av_booked', 'r44av_renter', '2027-03-02 10:00', '2027-03-06 10:00', 'confirmed');
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note)
values (test.id('vehicle:r44av_shop'), 'repair', '2027-03-01 09:00 America/Toronto', '2027-03-03 17:00 America/Toronto', 'brakes');

create or replace function pg_temp.av(p_user text) returns jsonb language sql as $$
  select app.fleet_availability(test.id(p_user), '{"from": "2027-03-03 10:00 America/Toronto", "to": "2027-03-05 10:00 America/Toronto"}')
$$;
create or replace function pg_temp.car(p_label text) returns jsonb language sql as $$
  select c from jsonb_array_elements(pg_temp.av('r44av_sales') -> 'cars') c where (c ->> 'id')::uuid = test.id('vehicle:' || p_label)
$$;

select test.eq('a free car is Available, from the pickup asked', (pg_temp.car('r44av_free') ->> 'available')::boolean, true);
select test.eq('a booked car is Not available: Booked, with its booking number and no renter',
  (pg_temp.car('r44av_booked') ->> 'available') || '/' || (pg_temp.car('r44av_booked') #>> '{reasons,0,label}') || ' ' || (pg_temp.car('r44av_booked') #>> '{reasons,0,booking}')
    || '/' || (position('renter' in lower(pg_temp.car('r44av_booked')::text)) = 0)::text,
  'false/Booked R44AV-1/true');
select test.ok('the booked car''s next free start is after its return (and the turnaround), for the same two days',
  (pg_temp.car('r44av_booked') ->> 'next_free')::timestamptz >= '2027-03-06 10:00 America/Toronto'::timestamptz);
select test.eq('a car in the shop is Not available: Maintenance: repair', (pg_temp.car('r44av_shop') ->> 'available') || '/' || (pg_temp.car('r44av_shop') #>> '{reasons,0,label}'), 'false/Maintenance: repair');
select test.ok('the shop car is free again once the repair ends', (pg_temp.car('r44av_shop') ->> 'next_free')::timestamptz >= '2027-03-03 17:00 America/Toronto'::timestamptz);
select test.ok('available cars come first',
  (select bool_and(not ((c ->> 'available')::boolean and prev_taken)) from (
     select c, coalesce(bool_or(not (c ->> 'available')::boolean) over (order by n rows between unbounded preceding and 1 preceding), false) as prev_taken
       from jsonb_array_elements(pg_temp.av('r44av_sales') -> 'cars') with ordinality x(c, n)) y));
select test.eq('the class filter keeps the class asked',
  (select count(*) from jsonb_array_elements(app.fleet_availability(test.id('r44av_sales'), '{"from": "2027-03-03 10:00 America/Toronto", "to": "2027-03-05 10:00 America/Toronto", "class": "exotic"}') -> 'cars') c
    where (c ->> 'id')::uuid in (test.id('vehicle:r44av_free'), test.id('vehicle:r44av_booked'))), 0::bigint);
select test.throws('finance does not book cars', $$select pg_temp.av('r44av_fin')$$, '%customer service, Sales%');
select test.throws('a return before the pickup is refused',
  $$select app.fleet_availability(test.id('r44av_sales'), '{"from": "2027-03-05 10:00", "to": "2027-03-03 10:00"}')$$, '%after the pickup%');
select test.eq('Sales reads it through the door',
  jsonb_typeof(app.door(test.id('r44av_sales'), 'aal1', 'va_read', 'fleet_availability', '{"from": "2027-03-03 10:00 America/Toronto", "to": "2027-03-05 10:00 America/Toronto", "_va": "sales"}') -> 'cars'), 'array');
