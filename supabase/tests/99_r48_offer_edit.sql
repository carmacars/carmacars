-- Release 48 (owner): an offer that is out is edited in place (no withdraw first), and what is saved stays saved: the
-- booking and the offer version sent both carry the edit, with or without telling the renter, and a later edit of
-- something else keeps it (a price typed by hand is not put back to the rate sheet). Fixtures start with "oe".
select test.suite('99 r48 offer edits persist');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.mk_user('oe_admin', 'admin');
select test.mk_user('oe_cs', 'va', 'cs');
select test.mk_owner('oe_o');
select test.mk_vehicle('OEV', 'oe_o');
select test.mk_vehicle('OEW', 'oe_o');
select test.mk_renter('oe_r');
select test.mk_booking('OE-1', 'OEV', 'oe_r', to_char(app.today() + 10, 'YYYY-MM-DD') || ' 10:00', to_char(app.today() + 13, 'YYYY-MM-DD') || ' 10:00', 'requested', 30000);
update bookings set requested_at = now() - interval '1 hour' where booking_number = 'OE-1';
create function test.oe_b() returns text language sql stable as $$
  select concat_ws('|', status, current_offer_version, case when vehicle_id = test.id('vehicle:OEW') then 'OEW' when vehicle_id = test.id('vehicle:OEV') then 'OEV' end, rental_charge_cents, deposit_cents, to_char(return_at, 'YYYY-MM-DD HH24:MI'))
    from bookings b where id = test.id('booking:OE-1') $$;
create function test.oe_o(p_v integer) returns text language sql stable as $$
  select concat_ws('|', o.status, o.rental_charge_cents, o.deposit_cents, o.total_cents = b.total_due_at_booking_cents)
    from booking_offers o join bookings b on b.id = o.booking_id where o.booking_id = test.id('booking:OE-1') and o.version = p_v $$;
create function test.oe_revise(p_by text, p jsonb) returns jsonb language sql as $$
  select app.door(test.id(p_by), 'aal2', 'ops_do', 'offer_revise', jsonb_build_object('booking', test.id('booking:OE-1')) || p) $$;

select test.eq('customer service sends version 1', (app.door(test.id('oe_cs'), 'aal2', 'va_do', 'send_offer', jsonb_build_object('booking', test.id('booking:OE-1'), 'sales_choice', 'for_carmacars')) ->> 'version'), '1');

-- 1. the price, the deposit, the return, the car and the place (a delivery), saved without telling the renter
select test.eq('edit while out, not told: version 2', (test.oe_revise('oe_admin', jsonb_build_object('expected_version', 1, 'notify', false,
  'places', jsonb_build_object('pickup_location', jsonb_build_object('kind', 'delivery', 'address', '1 Test Lane, Toronto', 'distance_km', 10), 'return_location', jsonb_build_object('kind', 'our_location')),
  'changes', jsonb_build_object('rental_charge_cents', 32100, 'price_tax', 'plus', 'price_reason', 'Agreed on the phone', 'deposit_cents', 35000,
                                'vehicle_id', test.id('vehicle:OEW'), 'return_at', (app.today() + 14)::text || ' 10:00 America/Toronto'))) ->> 'version'), '2');
select test.eq('the booking keeps every edit, and is out again', test.oe_b(),
  'offered|2|OEW|32100|35000|' || to_char(((app.today() + 14)::text || ' 10:00 America/Toronto')::timestamptz, 'YYYY-MM-DD HH24:MI'));
select test.eq('the version sent carries the edit and the booking total', test.oe_o(2), 'sent|32100|35000|t');
select test.eq('the version before is superseded, never withdrawn', (select status::text from booking_offers where booking_id = test.id('booking:OE-1') and version = 1), 'superseded');

-- 2. a later edit of the deposit only, told: the price typed by hand, the car and the return stay as saved
select test.eq('second edit, told: version 3', (test.oe_revise('oe_admin', jsonb_build_object('expected_version', 2, 'notify', true, 'channels', jsonb_build_object('email', true),
  'changes', jsonb_build_object('deposit_cents', 36000))) ->> 'version'), '3');
select test.eq('the second edit keeps the first', test.oe_b(),
  'offered|3|OEW|32100|36000|' || to_char(((app.today() + 14)::text || ' 10:00 America/Toronto')::timestamptz, 'YYYY-MM-DD HH24:MI'));
select test.eq('version 3 carries both edits', test.oe_o(3), 'sent|32100|36000|t');

-- 3. customer service edits a fee-free field (the internal note and the message): nothing else moves
select test.eq('customer service edits in place: version 4', (test.oe_revise('oe_cs', jsonb_build_object('expected_version', 3, 'notify', false, 'changes', '{}'::jsonb,
  'internal_note', 'Called the renter', 'message', 'Same offer, a new note')) ->> 'version'), '4');
select test.eq('the edits stay after customer service saves', test.oe_b(),
  'offered|4|OEW|32100|36000|' || to_char(((app.today() + 14)::text || ' 10:00 America/Toronto')::timestamptz, 'YYYY-MM-DD HH24:MI'));
select test.eq('the note is kept', (select notes from bookings where id = test.id('booking:OE-1')), 'Called the renter');

-- 4. a stale screen (the version it showed is old) is refused with the reason, never applied in silence
do $$
begin
  perform test.oe_revise('oe_admin', jsonb_build_object('expected_version', 2, 'changes', jsonb_build_object('deposit_cents', 10000)));
  perform test.ok('a stale edit is refused', false, 'it was applied');
exception when others then
  perform test.ok('a stale edit is refused', sqlerrm <> '', sqlerrm);
end $$;
select test.eq('and changes nothing', test.oe_b(),
  'offered|4|OEW|32100|36000|' || to_char(((app.today() + 14)::text || ' 10:00 America/Toronto')::timestamptz, 'YYYY-MM-DD HH24:MI'));
select test.eq('no version was ever withdrawn', (select count(*) from booking_offers where booking_id = test.id('booking:OE-1') and status = 'withdrawn'), 0::bigint);

-- 5. 2940: a fee changed from the Money tab while the offer is out, no withdraw first: changed in place, sent again
select test.eq('a fee on the Money tab: the next version goes out', (app.door(test.id('oe_admin'), 'aal2', 'ops_do', 'booking_fees_change',
  jsonb_build_object('booking', 'OE-1', 'lines', jsonb_build_object('delivery', 2000), 'reason', 'Agreed', 'notify', false)) ->> 'offer_version'), '5');
select test.eq('the fee is on the booking and the offer is out again', (select status::text || '|' || (select amount_cents from booking_line_items li where li.booking_id = b.id and li.stage = 'booking' and li.charge_type = 'delivery' and li.voided_at is null)
  from bookings b where id = test.id('booking:OE-1')), 'offered|2000');
select test.eq('the version sent carries the fee and the total', (select (o.line_items::text like '%"amount_cents": 2000%') and o.total_cents = b.total_due_at_booking_cents
  from booking_offers o join bookings b on b.id = o.booking_id where o.booking_id = test.id('booking:OE-1') and o.version = 5), true);
select test.eq('the other edits stay', test.oe_b(),
  'offered|5|OEW|32100|36000|' || to_char(((app.today() + 14)::text || ' 10:00 America/Toronto')::timestamptz, 'YYYY-MM-DD HH24:MI'));
select test.eq('a charge of its own while out: version 6', (app.door(test.id('oe_admin'), 'aal2', 'ops_do', 'booking_custom_fee',
  jsonb_build_object('booking', 'OE-1', 'label', 'Car wash', 'amount_cents', 2500, 'hst', true, 'notify', false)) ->> 'offer_version'), '6');
select test.eq('the charge is in the version sent', (select line_items::text like '%Car wash%' from booking_offers where booking_id = test.id('booking:OE-1') and version = 6), true);
select test.eq('still never withdrawn', (select count(*) from booking_offers where booking_id = test.id('booking:OE-1') and status = 'withdrawn'), 0::bigint);
