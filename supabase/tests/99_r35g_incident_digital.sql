-- 99: release 35 part G (migration 1150): the digital incident card behind the printed card's one QR code (/incident). The
-- renter and a driver named on the booking in progress see that booking (the coverage option, the drivers, the agreement);
-- another renter and an anonymous visitor see no booking data; a closed booking is not "in progress"; several bookings in
-- progress need a pick. Fixtures start with "gx" and "GX".
select test.suite('99 r35g incident digital');

select test.mk_owner('gx_o');
select test.mk_vehicle('GXA', 'gx_o');
select test.mk_vehicle('GXB', 'gx_o');
select test.mk_vehicle('GXC', 'gx_o');
select test.mk_renter(r) from unnest(array['gx_r', 'gx_d', 'gx_x', 'gx_two']) r;

create function pg_temp.ts(p_offset interval) returns text language sql as
$$ select to_char(date_trunc('hour', now() at time zone 'America/Toronto') + p_offset, 'YYYY-MM-DD HH24:MI') $$;

select test.mk_booking('GX-1', 'GXA', 'gx_r', pg_temp.ts('-1 day'), pg_temp.ts('2 days'), 'on_rent');
select test.mk_booking('GX-2', 'GXB', 'gx_r', pg_temp.ts('-20 days'), pg_temp.ts('-18 days'), 'closed');
select test.mk_booking('GX-3', 'GXB', 'gx_two', pg_temp.ts('-1 day'), pg_temp.ts('1 day'), 'on_rent');
select test.mk_booking('GX-4', 'GXC', 'gx_two', pg_temp.ts('2 hours'), pg_temp.ts('3 days'), 'confirmed');
update bookings set coverage_option = 3 where booking_number = 'GX-1';
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
values (test.id('booking:GX-1'), test.id('driver:gx_r'), 'renter', 'Gx R', date '1990-05-05', 'L1', 'G', date '2030-01-01', 36, '26_plus'),
       (test.id('booking:GX-1'), test.id('driver:gx_d'), 'additional', 'Gx D', date '1990-05-05', 'L2', 'G', date '2030-01-01', 36, '26_plus');
insert into documents (id, kind, title, storage_bucket, storage_path, mime_type, booking_id)
values (test.id('doc:gx1'), 'rental_agreement', 'Signed rental agreement', 'documents', 'bookings/gx1/agreement.pdf', 'application/pdf', test.id('booking:GX-1')),
       (test.id('doc:gx2'), 'rental_agreement', 'Signed rental agreement', 'documents', 'bookings/gx2/agreement.pdf', 'application/pdf', test.id('booking:GX-2'));

-- the renter: the one booking in progress, its card
create temp table gx_r as select public.server_incident_digital(test.id('gx_r'), '{}'::jsonb) d;
select test.eq('renter: one booking in progress (the closed one is not listed)', (select jsonb_array_length(d -> 'bookings') from gx_r), 1);
select test.eq('renter: its card opens at once', (select d -> 'card' ->> 'booking_number' from gx_r), 'GX-1');
select test.eq('renter: the coverage option of the booking (the Protection Plan)', (select d -> 'card' -> 'coverage' ->> 'kind' from gx_r), 'plan');
select test.eq('renter: the two drivers, the renter first', (select d -> 'card' -> 'drivers' -> 0 ->> 'name' || ',' || (d -> 'card' -> 'drivers' -> 1 ->> 'name') from gx_r), 'Gx R,Gx D');
select test.eq('renter: the signed agreement', (select d -> 'card' -> 'contract' ->> 'document_id' from gx_r), test.id('doc:gx1')::text);
select test.eq('renter: as the renter', (select d -> 'card' ->> 'role' from gx_r), 'renter');
select test.eq('renter: the car of the booking', (select d -> 'card' -> 'car' ->> 'vehicle_id' from gx_r), test.id('vehicle:GXA')::text);

-- an additional driver named on the booking, signed in with their own account
create temp table gx_d as select public.server_incident_digital(test.id('gx_d'), '{}'::jsonb) d;
select test.eq('driver: sees the booking they drive', (select d -> 'card' ->> 'booking_number' from gx_d), 'GX-1');
select test.eq('driver: as a driver', (select d -> 'card' ->> 'role' from gx_d), 'driver');
select test.ok('driver: reads the agreement', public.server_incident_document(test.id('gx_d'), test.id('doc:gx1')) ->> 'path' = 'bookings/gx1/agreement.pdf');
select test.lives('driver: reads the accident reports of the booking (Report a problem)', format($$select public.server_renter_accidents(%L, %L)$$, test.id('booking:GX-1'), test.id('gx_d')));

-- another renter: nothing about the booking, even when they name it
create temp table gx_x as select public.server_incident_digital(test.id('gx_x'), jsonb_build_object('booking', 'GX-1')) d;
select test.eq('other renter: no booking listed', (select jsonb_array_length(d -> 'bookings') from gx_x), 0);
select test.ok('other renter: no card, even naming the booking', (select d -> 'card' = 'null'::jsonb or d -> 'card' is null from gx_x));
select test.ok('other renter: only the company block besides', (select d -> 'company' ->> 'trade_name' is not null and d::text not like '%GX-1%' and d::text not like '%Gx R%' from gx_x));
select test.ok('other renter: the agreement is not served', public.server_incident_document(test.id('gx_x'), test.id('doc:gx1')) is null);
select test.throws('other renter: the accident reports of the booking are refused', format($$select public.server_renter_accidents(%L, %L)$$, test.id('booking:GX-1'), test.id('gx_x')), 'Not permitted');
select test.ok('renter: the agreement of a closed booking is not served here', public.server_incident_document(test.id('gx_r'), test.id('doc:gx2')) is null);

-- not signed in: refused (the page signs in first)
select test.throws('anonymous: refused, no booking data', $$select public.server_incident_digital(null, '{}'::jsonb)$$, 'Sign in first');
select test.ok('anonymous: no document', public.server_incident_document(null, test.id('doc:gx1')) is null);

-- two bookings in progress (one on rent, one confirmed with the pickup within 12 hours): a pick, then the chosen one
create temp table gx_two as select public.server_incident_digital(test.id('gx_two'), '{}'::jsonb) d;
select test.eq('two bookings: both listed', (select jsonb_array_length(d -> 'bookings') from gx_two), 2);
select test.ok('two bookings: no card until one is picked', (select d -> 'card' = 'null'::jsonb or d -> 'card' is null from gx_two));
select test.eq('two bookings: the picked one', public.server_incident_digital(test.id('gx_two'), jsonb_build_object('booking', 'gx-4')) -> 'card' ->> 'booking_number', 'GX-4');

-- the service role only
select test.eq('privileges: the browser roles cannot call it',
  has_function_privilege('authenticated', 'public.server_incident_digital(uuid, jsonb)', 'execute') or has_function_privilege('anon', 'public.server_incident_document(uuid, uuid)', 'execute'), false);
