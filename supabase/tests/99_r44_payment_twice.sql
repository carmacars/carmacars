-- 99: migration 2820 (release 44): the same card payment settled twice (the browser and the webhook at once) is answered as
-- done the second time: nothing recorded twice, nothing refused, so nothing cancels the authorization. Fixtures start with
-- "ptw"; every address is example.test.
select test.suite('99 r44 payment settled twice (2820)');

select test.mk_owner('ptw_owner');
select test.mk_vehicle('PTW1', 'ptw_owner');
select test.mk_renter('ptw_r1', false);
select test.mk_booking('PTW-1', 'PTW1', 'ptw_r1', '2026-12-01 10:00', '2026-12-04 10:00', 'confirmed', 30000);

-- the first settlement recorded the payment and confirmed the booking
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
values (test.id('pay:ptw1'), test.id('booking:PTW-1'), (select renter_id from bookings where id = test.id('booking:PTW-1')),
        'booking_total', 'charge', 'card', 33900, 'succeeded', now());
insert into payment_processor_details (payment_id, processor, processor_payment_id) values (test.id('pay:ptw1'), 'stripe', 'pi_ptw_first');

create temp table ptw_again as select app.record_booking_payment(test.id('booking:PTW-1'), '{"processor": "stripe", "payment_id": "pi_ptw_first"}'::jsonb,
  33900, 1, null, 'evt_ptw_again', null) as r;
select test.ok('the same payment settled again: ok, marked duplicate', (select (r ->> 'ok')::boolean and (r ->> 'duplicate')::boolean from ptw_again));
select test.eq('nothing recorded twice', (select count(*) from payments where booking_id = test.id('booking:PTW-1') and purpose = 'booking_total'), 1::bigint);
select test.eq('the payment stays paid', (select status from payments where id = test.id('pay:ptw1')), 'succeeded');
select test.ok('another payment on the confirmed booking is not taken for the first one',
  coalesce((select (r ->> 'duplicate')::boolean from (select app.record_booking_payment(test.id('booking:PTW-1'), '{"processor": "stripe", "payment_id": "pi_ptw_other"}'::jsonb,
    33900, 1, null, 'evt_ptw_other', null) as r) x), false) = false);
select test.ok('the wrapped function is the server''s only',
  not has_function_privilege('authenticated', 'app.record_booking_payment_pre2820(uuid, jsonb, bigint, integer, jsonb, text, uuid)', 'execute')
  and not has_function_privilege('anon', 'app.record_booking_payment_pre2820(uuid, jsonb, bigint, integer, jsonb, text, uuid)', 'execute'));
