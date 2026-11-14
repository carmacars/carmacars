-- 99: migration 2891 (release 47): the website's fleet order puts the cars that rent least first, bookings hidden from the
-- owner not counted, and a partner set to "low" after our own cars. Fixtures start with "fo47".
select test.suite('99 r47 fleet occupancy (2891)');
select test.mk_renter('fo47_r');
select test.mk_owner('fo47_o');
select test.mk_vehicle('fo47_a', 'fo47_o');
select test.mk_booking('CC-FO47A', 'fo47_a', 'fo47_r', to_char(app.today() - 10, 'YYYY-MM-DD') || ' 10:00', to_char(app.today() + 5, 'YYYY-MM-DD') || ' 10:00', 'confirmed', 10000);
select test.ok('occupancy: a 15-day booking in the 60-day window is about a quarter', app.fleet_occupancy_bps(test.id('vehicle:fo47_a')) between 2400 and 2600);
update bookings set owner_visibility = 'never' where booking_number = 'CC-FO47A';
select test.eq('occupancy: a booking hidden from the owner does not count', app.fleet_occupancy_bps(test.id('vehicle:fo47_a')), 0);
select test.mk_vehicle('fo47_c', 'fo47_o');
select test.mk_booking('CC-FO47C', 'fo47_c', 'fo47_r', to_char(app.today() + 100, 'YYYY-MM-DD') || ' 10:00', to_char(app.today() + 110, 'YYYY-MM-DD') || ' 10:00', 'confirmed', 10000);
select test.eq('occupancy: a booking outside the last and next 30 days does not count', app.fleet_occupancy_bps(test.id('vehicle:fo47_c')), 0);
select test.ok('on by default', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'fleet_low_occupancy_first') = 'true');
select test.ok('the 01 Motors partner shows after our own cars', not exists (select 1 from partners where business_name ilike '01 motors%' and site_priority <> 'low'));
