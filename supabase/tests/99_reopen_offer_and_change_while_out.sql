-- 99: Reopen on an expired offer sends a new, re-priced offer; staff change the return of a trip that is still out
-- after its return time (0502). Fixtures start with "rx" and use example.test only.
select test.suite('99 reopen offer and change while out');
select test.mk_user('rx_admin', 'admin');
select test.mk_owner('rx_olive');
select test.mk_renter('rx_rita');
select test.mk_renter('rx_ivan');
select test.mk_vehicle('rx_a', 'rx_olive');
select test.mk_vehicle('rx_b', 'rx_olive');
create or replace function test.rxt(p_shift interval) returns text language sql stable as $$
  select to_char((now() + p_shift) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')
$$;

-- ================================================================ 1. Reopen sends a new offer
create temp table rx_ids (k text primary key, id uuid);
grant all on rx_ids to public;
insert into rx_ids select 'x', app.request_booking(test.id('renter:rx_rita'), test.id('vehicle:rx_a'), now() + interval '30 days', now() + interval '33 days',
  'standard', null, 'phone', test.id('rx_admin'), null, null, 'collected', 'returned', null, null);
select app.send_offer((select id from rx_ids where k = 'x'), test.id('rx_admin'), 'Here is your offer', now() + interval '1 hour');
select test.eq('1 the offer expires', app.expire_offers(now() + interval '2 hours'), 1);
select test.eq('1 the request is expired', (select status::text from bookings where id = (select id from rx_ids where k = 'x')), 'expired');
select app.reopen_expired_offer((select id from rx_ids where k = 'x'), test.id('rx_admin'), 'Customer called back');
select test.eq('1 Reopen sends version 2 at once: the booking is offered with a fresh expiry, the old offer stays expired (history kept)',
  (select b.status || '/' || b.current_offer_version || '/' || (b.offer_expires_at > now() + interval '1 hour')
          || '/' || (select string_agg(o.version || ':' || o.status, ' ' order by o.version) from booking_offers o where o.booking_id = b.id)
     from bookings b where b.id = (select id from rx_ids where k = 'x')),
  'offered/2/true/1:expired 2:sent');
select test.eq('1 the history says reopened', (select count(*) from booking_events where booking_id = (select id from rx_ids where k = 'x') and kind = 'reopened'), 1::bigint);
-- a pickup that has passed: reopened as a request for staff to edit, no offer
insert into rx_ids select 'y', app.request_booking(test.id('renter:rx_ivan'), test.id('vehicle:rx_b'), now() + interval '30 days', now() + interval '33 days',
  'standard', null, 'phone', test.id('rx_admin'), null, null, 'collected', 'returned', null, null);
select app.send_offer((select id from rx_ids where k = 'y'), test.id('rx_admin'), 'Offer', now() + interval '1 hour');
select app.expire_offers(now() + interval '2 hours');
update bookings set pickup_at = now() - interval '1 day', return_at = now() + interval '2 days' where id = (select id from rx_ids where k = 'y');
select test.eq('1 a pickup in the past: no new offer',
  coalesce(app.reopen_expired_offer((select id from rx_ids where k = 'y'), test.id('rx_admin'))::text, 'none'), 'none');
select test.eq('1 a pickup in the past: reopened to requested', (select status::text from bookings where id = (select id from rx_ids where k = 'y')), 'requested');

-- ================================================================ 2. staff change the return while the guest has the car
select test.mk_vehicle('rx_c', 'rx_olive');
select test.mk_booking('RX-OUT', 'rx_c', 'rx_rita', test.rxt('-2 days'), test.rxt('-3 hours'), 'on_rent');
select test.eq('2 preview: a later return on a trip still out after its return time is allowed',
  (app.preview_booking_change(test.id('booking:RX-OUT'), jsonb_build_object('return_at', now() + interval '1 day')) ->> 'ok'), 'true');
select test.eq('2 the pickup of a trip under way stays fixed',
  (app.preview_booking_change(test.id('booking:RX-OUT'), jsonb_build_object('pickup_at', now() - interval '1 day', 'return_at', now() + interval '1 day')) ->> 'ok'), 'false');
select test.eq('2 the added time is priced on top of what was charged',
  ((app.preview_booking_change(test.id('booking:RX-OUT'), jsonb_build_object('return_at', now() + interval '1 day')) ->> 'difference_cents')::bigint > 0)::text, 'true');
select test.eq('2 staff propose it (Propose a change) on that trip',
  (app.propose_booking_change(test.id('rx_admin'), jsonb_build_object('booking', 'RX-OUT', 'return_at', now() + interval '1 day', 'note', 'The guest still has the car'))
     ->> 'status'), 'proposed');
-- once the car is checked in, the trip is no longer out: a change is refused
select test.mk_vehicle('rx_d', 'rx_olive');
select test.mk_booking('RX-DONE', 'rx_d', 'rx_ivan', test.rxt('-2 days'), test.rxt('-3 hours'), 'on_rent');
update bookings set checked_in_at = now() - interval '1 hour' where booking_number = 'RX-DONE';
select test.eq('2 a trip with its return recorded is not changed this way',
  (app.preview_booking_change(test.id('booking:RX-DONE'), jsonb_build_object('return_at', now() + interval '1 day')) ->> 'ok'), 'false');
