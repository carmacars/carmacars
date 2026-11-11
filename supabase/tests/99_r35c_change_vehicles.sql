-- 99: the car-change list of a booking (1500). The read used to fail with "b.id is ambiguous" and the list was empty:
-- now the cars open for bookings come back, the booking's own car first, by id or by booking number, for an Admin and
-- for customer service; a renter is refused. Fixtures start with "cvx"; every address is example.test.
select test.suite('99 r35c change vehicles');

select test.mk_user('cvx_admin', 'admin');
select test.mk_user('cvx_cs', 'va', 'cs');
select test.mk_owner('cvx_owner');
select test.mk_vehicle('cvx_a', 'cvx_owner');
select test.mk_vehicle('cvx_b', 'cvx_owner');
select test.mk_renter('cvx_rita');
update vehicles set bookings_enabled = true where id in (test.id('vehicle:cvx_a'), test.id('vehicle:cvx_b'));
select test.mk_booking('CVX-1', 'cvx_b', 'cvx_rita', to_char(now() + interval '5 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '8 days', 'YYYY-MM-DD 10:00'), 'confirmed');

create temp table cvx_r as
  select app.door(test.id('cvx_admin'), 'aal2', 'admin_read', 'change_vehicles', jsonb_build_object('booking', 'CVX-1')) as by_number,
         app.door(test.id('cvx_admin'), 'aal2', 'admin_read', 'change_vehicles', jsonb_build_object('booking', test.id('booking:CVX-1')::text)) as by_id,
         app.door(test.id('cvx_cs'), 'aal2', 'va_read', 'change_vehicles', jsonb_build_object('booking', 'CVX-1')) as by_cs;

select test.ok('the list is no longer empty: both open cars are in it',
  (select (select count(*) from jsonb_array_elements(by_number) x where x ->> 'id' in (test.id('vehicle:cvx_a')::text, test.id('vehicle:cvx_b')::text)) = 2 from cvx_r));
select test.eq('the booking''s own car comes first (by booking number)', (select by_number -> 0 ->> 'id' from cvx_r), test.id('vehicle:cvx_b')::text);
select test.eq('the same list by the booking''s id', (select by_id = by_number from cvx_r), true);
select test.eq('customer service reads the same list', (select by_cs = by_number from cvx_r), true);
select test.ok('no booking given: the open cars still come back (no error)',
  jsonb_array_length(app.door(test.id('cvx_admin'), 'aal2', 'admin_read', 'change_vehicles', '{}'::jsonb)) >= 2);
select test.throws('a renter cannot read it',
  format('select app.door(%L, %L, %L, %L, %L::jsonb)', test.id('cvx_rita'), 'aal2', 'va_read', 'change_vehicles', '{"booking": "CVX-1"}'), 'ermitted');
