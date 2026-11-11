-- 99: release 37 (migration 2300): a request is "not bookable until verified" until the renter's licence is verified;
-- the state is read for the server only. Fixtures start with "r37u"; addresses are example.test.
select test.suite('99 r37 unverified requests (2300)');

select test.mk_owner('r37u_olive');
select test.mk_vehicle('r37u_car', 'r37u_olive');
select test.mk_renter('r37u_vera');
select test.mk_renter('r37u_paul');
select test.mk_booking('R37U-1', 'r37u_car', 'r37u_vera', '2031-03-02 10:00', '2031-03-04 10:00', 'requested');
select test.mk_booking('R37U-2', 'r37u_car', 'r37u_paul', '2031-04-02 10:00', '2031-04-04 10:00', 'requested');

select test.eq('a verified renter''s request is bookable', app.booking_licence_state(test.id('booking:R37U-1')), 'verified');
update booking_drivers set identity_verified_on = null where booking_id = test.id('booking:R37U-2');
update drivers set identity_status = 'pending' where renter_id = test.id('renter:r37u_paul');
update renters set identity_status = 'pending' where id = test.id('renter:r37u_paul');
select test.eq('a licence sent but not checked: pending (not bookable yet)', app.booking_licence_state(test.id('booking:R37U-2')), 'pending');
update drivers set identity_status = 'not_started' where renter_id = test.id('renter:r37u_paul');
update renters set identity_status = 'not_started' where id = test.id('renter:r37u_paul');
select test.eq('no licence: missing', app.booking_licence_state(test.id('booking:R37U-2')), 'missing');
select test.eq('the server reads both by number',
  public.server_booking_licence_state(array['R37U-1', 'R37U-2', 'NOPE']), jsonb_build_object('R37U-1', 'verified', 'R37U-2', 'missing'));
select test.throws('more than 50 numbers are refused', $$select public.server_booking_licence_state(array_fill('x'::text, array[51]))$$, 'At most 50');
select test.ok('renters and the public cannot read it (server only)',
  not has_function_privilege('authenticated', 'public.server_booking_licence_state(text[])', 'execute')
  and not has_function_privilege('anon', 'public.server_booking_licence_state(text[])', 'execute')
  and not has_function_privilege('authenticated', 'app.booking_licence_state(uuid)', 'execute'));
select test.ok('the service role can', has_function_privilege('service_role', 'public.server_booking_licence_state(text[])', 'execute'));
