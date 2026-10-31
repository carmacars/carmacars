-- 99: the non-refundable discount only a week or more before pickup (migration 0241). Fixtures start with "nrw".
select test.suite('99 non-refundable a week ahead');
select test.mk_owner('nrw_owner');
select test.mk_vehicle('nrw_car', 'nrw_owner');
select test.mk_renter('nrw_rita');
select test.mk_booking('NRW-1', 'nrw_car', 'nrw_rita', to_char(now() + interval '3 days', 'YYYY-MM-DD HH24:MI'), to_char(now() + interval '5 days', 'YYYY-MM-DD HH24:MI'), 'requested', 20000);
select test.mk_booking('NRW-2', 'nrw_car', 'nrw_rita', to_char(now() + interval '10 days', 'YYYY-MM-DD HH24:MI'), to_char(now() + interval '12 days', 'YYYY-MM-DD HH24:MI'), 'requested', 20000);
select test.eq('the setting starts at 7 days', (app.settings()).non_refundable_min_days, 7);
select test.throws('pickup in 3 days: non-refundable refused with the reason',
  $$update bookings set booking_type = 'non_refundable' where booking_number = 'NRW-1'$$, 'at least 7 days before pickup');
select test.lives('pickup in 10 days: non-refundable allowed',
  $$update bookings set booking_type = 'non_refundable' where booking_number = 'NRW-2'$$);
select test.throws('moving a non-refundable request inside the week is refused',
  $$update bookings set pickup_at = now() + interval '2 days', return_at = now() + interval '4 days', original_return_at = now() + interval '4 days' where booking_number = 'NRW-2'$$, 'at least 7 days before pickup');
select test.eq('the request form is told the number', (public.site_facts() ->> 'non_refundable_min_days')::int, 7);
