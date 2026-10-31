-- 99: the booking's calendar link (migration 0215). Fixtures start with "bcal".
select test.suite('99 booking calendar');
select test.mk_owner('bcal_owner');
select test.mk_vehicle('bcal_car', 'bcal_owner');
select test.mk_renter('bcal_rita');
select test.mk_booking('BCAL-1', 'bcal_car', 'bcal_rita', '2026-12-01 10:00', '2026-12-03 10:00', 'confirmed', 20000);
select test.mk_booking('BCAL-2', 'bcal_car', 'bcal_rita', '2026-12-10 10:00', '2026-12-12 10:00', 'closed', 20000);
select test.eq('a confirmed booking''s calendar facts by its token',
  public.server_booking_calendar((select calendar_token from bookings where booking_number = 'BCAL-1')) ->> 'number', 'BCAL-1');
select test.ok('none once the booking is over', public.server_booking_calendar((select calendar_token from bookings where booking_number = 'BCAL-2')) is null);
select test.ok('the confirmation email carries the calendar link',
  app.notification_payload('renter_booking_confirmed', jsonb_populate_record(null::app_events, jsonb_build_object('id', 1, 'code', 'renter_booking_confirmed', 'entity', 'booking', 'entity_id', test.id('booking:BCAL-1'), 'payload', jsonb_build_object('booking_id', test.id('booking:BCAL-1')))), '{}'::jsonb) ->> 'calendar_url'
    like '%/api/booking-ics/' || (select calendar_token from bookings where booking_number = 'BCAL-1'));
select test.throws('the calendar function is not for the public', $$set local role anon; select public.server_booking_calendar(gen_random_uuid())$$);
