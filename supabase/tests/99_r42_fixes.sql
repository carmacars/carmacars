-- 99: release 42 (migration 2610)
-- 1. A booking left out of the owner's revenue (2480) that starts counting sends the owner its new booking notice once.
-- 2. The card that covers a rental: a card of another network is refused before the booking is confirmed.
-- Fixtures start with "r42".
select test.suite('99 r42 fixes: the owner notice when a booking starts counting; the coverage card network');

select test.mk_user('r42_admin', 'admin');
select test.mk_owner('r42_owen');
select test.mk_vehicle('R421', 'r42_owen');
select test.mk_renter('r42_r1', false); select test.mk_renter('r42_r2', false); select test.mk_renter('r42_r3', false); select test.mk_renter('r42_r4', false);
insert into insurers (id, name) values (test.id('insurer:r42'), 'R42 Example Insurance');
create temp table r42_prev as select owner_hide_insurance_only as io from app.settings();
update program_settings set owner_hide_insurance_only = true where id = (select id from app.settings());

create function pg_temp.b(p text) returns bookings language sql as $$ select * from bookings where id = test.id('booking:' || p) $$;
create function pg_temp.n(p text) returns bigint language sql as $$
  select count(*) from app_events where code = 'owner_new_booking' and entity = 'booking' and entity_id = test.id('booking:' || p) $$;

-- A: an insurer rental off the calendar, confirmed (its original notice was dropped by 0156)
select test.mk_booking('R42-A', 'R421', 'r42_r1', '2031-05-02 10:00', '2031-05-05 10:00', 'confirmed', 0);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:r42'), blocks_calendar = false,
       blocks_calendar_changed_by = test.id('r42_admin'), blocks_calendar_reason = 'Insurer rental, dates not final' where id = test.id('booking:R42-A');
select test.ok('A: it does not count and no owner notice exists', not app.booking_counts_for_owner(pg_temp.b('R42-A')) and pg_temp.n('R42-A') = 0);
update bookings set blocks_calendar = true, blocks_calendar_reason = 'Dates are final' where id = test.id('booking:R42-A');
select test.ok('A: it counts now', app.booking_counts_for_owner(pg_temp.b('R42-A')));
select test.eq('A: the owner gets the new booking notice, once', pg_temp.n('R42-A'), 1::bigint);
select test.eq('A: with the counted key', (select dedupe_key from app_events where code = 'owner_new_booking' and entity_id = test.id('booking:R42-A')),
  'owner_new_booking:' || test.id('booking:R42-A') || ':counted');
update bookings set blocks_calendar = false, blocks_calendar_reason = 'Dates moved again' where id = test.id('booking:R42-A');
update bookings set blocks_calendar = true, blocks_calendar_reason = 'Dates are final again' where id = test.id('booking:R42-A');
select test.eq('A: off and on again sends no second notice', pg_temp.n('R42-A'), 1::bigint);

-- B: the owner was told when it first counted: switching it off and on sends nothing more
select test.mk_booking('R42-B', 'R421', 'r42_r2', '2031-05-06 10:00', '2031-05-08 10:00', 'confirmed', 0);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:r42') where id = test.id('booking:R42-B');
insert into app_events (code, entity, entity_id, payload, dedupe_key, processed_at) values
  ('owner_new_booking', 'booking', test.id('booking:R42-B'), '{}'::jsonb, 'owner_new_booking:' || test.id('booking:R42-B') || ':confirmed', now());
update bookings set blocks_calendar = false, blocks_calendar_changed_by = test.id('r42_admin'), blocks_calendar_reason = 'Dates not final' where id = test.id('booking:R42-B');
update bookings set blocks_calendar = true, blocks_calendar_reason = 'Dates are final' where id = test.id('booking:R42-B');
select test.eq('B: the owner already had the notice: no second one', pg_temp.n('R42-B'), 1::bigint);

-- C: an insurance replacement hidden from the owner, then shown
select test.mk_booking('R42-C', 'R421', 'r42_r3', '2031-05-10 10:00', '2031-05-12 10:00', 'confirmed', 0);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:r42'), owner_visibility = 'until_statement' where id = test.id('booking:R42-C');
select test.ok('C: hidden, it does not count', not app.booking_counts_for_owner(pg_temp.b('R42-C')));
update bookings set owner_visibility = 'shown' where id = test.id('booking:R42-C');
select test.eq('C: shown to the owner, the notice is sent', pg_temp.n('R42-C'), 1::bigint);

-- D: a cancelled booking that starts counting sends nothing
select test.mk_booking('R42-D', 'R421', 'r42_r4', '2031-05-14 10:00', '2031-05-16 10:00', 'cancelled', 0);
update bookings set bill_to = 'insurer', insurer_id = test.id('insurer:r42'), blocks_calendar = false,
       blocks_calendar_changed_by = test.id('r42_admin'), blocks_calendar_reason = 'Dates not final' where id = test.id('booking:R42-D');
update bookings set blocks_calendar = true, blocks_calendar_reason = 'Dates are final' where id = test.id('booking:R42-D');
select test.eq('D: a cancelled booking sends no notice', pg_temp.n('R42-D'), 0::bigint);

-- the coverage card network
select test.eq('brand keys', app.card_brand_key('American Express') || '/' || app.card_brand_key('amex') || '/' || app.card_brand_key(' MasterCard ') || '/' || app.card_brand_key('Visa') || '/' || coalesce(app.card_brand_key(''), 'null'),
  'amex/amex/mastercard/visa/null');
select test.eq('no card rule on a booking without card coverage', public.server_coverage_card_network(test.id('booking:R42-A')) ->> 'required', 'false');

select test.mk_booking('R42-E', 'R421', 'r42_r1', '2031-06-02 10:00', '2031-06-05 10:00', 'pending_payment', 0);
update bookings set coverage_option = 2 where id = test.id('booking:R42-E');
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, card_brand, card_last4, processed_at)
values (test.id('booking:R42-E'), (select renter_id from bookings where id = test.id('booking:R42-E')), 'booking_total', 'charge', 'card', 1000, 'succeeded', 'visa', '4242', now());
select test.eq('the coverage card is a Visa', public.server_coverage_card_network(test.id('booking:R42-E')) ->> 'brand', 'visa');
select test.ok('a Mastercard is refused with the plain message, before anything else',
  (select r ->> 'ok' = 'false' and r ->> 'reason' = 'card_network_mismatch' and r ->> 'message' like 'Pay with the card that covers this rental (Visa)%'
     from (select app.record_booking_payment(test.id('booking:R42-E'), '{"processor":"stripe","payment_id":"pi_r42"}'::jsonb, 1000, 1,
                    '{"brand":"mastercard","last4":"4444","is_credit":true}'::jsonb, 'evt_r42', test.id('r42_admin')) as r) x));

update program_settings set owner_hide_insurance_only = (select io from r42_prev) where id = (select id from app.settings());
