-- 99: release 48 part 2 money fixes (migrations 3051, 3052, 3054; docs/changes/2026-11-15-r48-money-fixes.md): a payment
-- covers every line up to the total and confirms the booking; a deposit by e-Transfer or cash is doubled; top-ups and
-- overpaid deposits; a deposit change reaches every record; a void resets the deposit; the repair of CC-10478.
-- Fixtures start with "x51"; addresses are example.test.
select test.suite('99 r48 money fixes');
select test.mk_user('x51_admin', 'admin');
select test.mk_owner('x51_o');
select test.mk_vehicle('X51A', 'x51_o');
select test.mk_vehicle('X51B', 'x51_o');
select test.mk_vehicle('X51C', 'x51_o');
select test.mk_vehicle('X51D', 'x51_o');
select test.mk_renter('x51_r');

-- a booking whose lines are not paid yet: the rental, short notice, a young driver fee and the Protection Plan
create function test.x51_unpaid(p_number text, p_vehicle text, p_status booking_status, p_day integer) returns uuid
language plpgsql as $$
declare v uuid;
begin
  v := test.mk_booking(p_number, p_vehicle, 'x51_r', to_char(now() at time zone 'America/Toronto' + make_interval(days => p_day), 'YYYY-MM-DD 10:00'),
    to_char(now() at time zone 'America/Toronto' + make_interval(days => p_day + 1), 'YYYY-MM-DD 10:00'), p_status, 6000);
  perform test.mk_line(p_number, 'lead_time', 500);
  perform test.mk_line(p_number, 'young_driver_21_25', 4000);
  perform test.mk_line(p_number, 'coverage_sold', 3000);
  perform app.sync_booking_price(v);
  update booking_line_items set payment_id = null where booking_id = v;
  delete from payments where booking_id = v;
  update bookings set rental_pay_method = 'e_transfer', deposit_pay_method = 'e_transfer', deposit_cents = 30000 where id = v;
  return v;
end $$;
create function test.x51_open(p_number text) returns bigint language sql as $$
  select app.booking_part_open(test.id('booking:' || p_number), 'rental') + app.booking_part_open(test.id('booking:' || p_number), 'fees') $$;

-- ================================================================ A. a payment covers every line up to the total
select test.x51_unpaid('CC-X511', 'X51A', 'pending_payment', 20);
select test.ok('the fees part is open before the payment', app.booking_part_open(test.id('booking:CC-X511'), 'fees') > 0);
select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X511', 'covers', 'rental', 'method', 'e_transfer',
  'amount_cents', (select total_due_at_booking_cents from bookings where booking_number = 'CC-X511'), 'reference', 'X51PAYA'));
select test.eq('the whole total recorded for the rental: nothing open', test.x51_open('CC-X511'), 0::bigint);
select test.eq('every line is paid, the fees included', (select count(*) from booking_line_items where booking_id = test.id('booking:CC-X511') and payment_id is null and voided_at is null), 0::bigint);
select test.eq('paid in full: the booking is confirmed', (select status::text from bookings where booking_number = 'CC-X511'), 'confirmed');

-- a part paid, then the rest: confirmed only when the total is in
select test.x51_unpaid('CC-X512', 'X51B', 'pending_payment', 20);
select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X512', 'covers', 'fees', 'method', 'cash', 'amount_cents', 5000));
select test.eq('a part of the total: still waiting for payment', (select status::text from bookings where booking_number = 'CC-X512'), 'pending_payment');
select test.ok('a part of the total: the rest is open', test.x51_open('CC-X512') > 0);
select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X512', 'covers', 'rental', 'method', 'cash', 'amount_cents', test.x51_open('CC-X512')));
select test.eq('paid >= total: confirmed', (select status::text from bookings where booking_number = 'CC-X512'), 'confirmed');
select test.eq('paid >= total: every line tied', (select count(*) from booking_line_items where booking_id = test.id('booking:CC-X512') and payment_id is null and voided_at is null), 0::bigint);

-- a booking stuck that way before 3051 (a payment of the rental part, the fee lines untied) is repaired
select test.x51_unpaid('CC-X513', 'X51C', 'pending_payment', 20);
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
select test.id('x51:stuckpay'), b.id, b.renter_id, 'booking_total', 'charge', 'e_transfer', b.total_due_at_booking_cents, 'succeeded', now(), test.id('x51_admin') from bookings b where booking_number = 'CC-X513';
insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, recorded_by, covers)
select test.id('x51:stuckpay'), 'booking', b.id, b.renter_id, 'e_transfer', b.total_due_at_booking_cents, app.today(), 'X51STUCK', test.id('x51_admin'), 'rental' from bookings b where booking_number = 'CC-X513';
update booking_line_items set payment_id = test.id('x51:stuckpay') where booking_id = test.id('booking:CC-X513') and charge_type in ('rental_charge', 'lead_time');
select test.ok('the repair finds the stuck booking', app.repair_payment_allocation(test.id('booking:CC-X513')) = 1);
select test.eq('repaired: lines paid and confirmed', (select status::text || '/' || (select count(*) from booking_line_items l where l.booking_id = b.id and l.payment_id is null and l.voided_at is null) from bookings b where booking_number = 'CC-X513'), 'confirmed/0');
select test.eq('the repair runs again without change', app.repair_payment_allocation(test.id('booking:CC-X513')), 0);

-- ================================================================ B. the deposit doubled for e-Transfer and cash
select test.eq('a credit card: the deposit', (select app.deposit_for_method(b, 'card') from bookings b where booking_number = 'CC-X511'), 30000::bigint);
select test.eq('e-Transfer: twice the deposit', (select app.deposit_for_method(b, 'e_transfer') from bookings b where booking_number = 'CC-X511'), 60000::bigint);
select test.eq('cash: twice the deposit', (select app.deposit_for_method(b, 'cash') from bookings b where booking_number = 'CC-X511'), 60000::bigint);
update program_settings set offline_deposit_multiplier = 1.5;
select test.eq('the multiplier is a Program setting', (select app.deposit_for_method(b, 'cash') from bookings b where booking_number = 'CC-X511'), 45000::bigint);
update program_settings set offline_deposit_double = false;
select test.eq('off: the deposit as it is', (select app.deposit_for_method(b, 'cash') from bookings b where booking_number = 'CC-X511'), 30000::bigint);
update program_settings set offline_deposit_double = true, offline_deposit_multiplier = 2;
select test.eq('the pay page and the offer read both amounts', (select (s ->> 'card_cents') || '/' || (s ->> 'offline_cents') from public.server_booking_deposit_options(test.id('booking:CC-X511')) s), '30000/60000');
select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X511', 'covers', 'deposit', 'method', 'e_transfer', 'reference', 'X51DEP1'));
select test.eq('record_payment with no amount takes the doubled deposit', (select amount_cents || '/' || status from deposits where booking_id = test.id('booking:CC-X511')), '60000/captured');
select test.eq('the Money tab shows it taken in full', (select (app.booking_money(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X511')) -> 'deposit_state' ->> 'owed_cents')), '0');

-- ================================================================ C. a top-up, and a deposit over the amount
select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X512', 'covers', 'deposit', 'method', 'cash', 'amount_cents', 20000));
select test.eq('a part of the deposit: still owed', (select s ->> 'owed_cents' from app.deposit_state(test.id('booking:CC-X512')) s), '40000');
select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X512', 'covers', 'deposit', 'method', 'cash'));
select test.eq('a top-up with no amount takes the rest', (select amount_cents::text from deposits where booking_id = test.id('booking:CC-X512')), '60000');
select test.throws('taken in full: no amount, nothing to take', $$select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X512', 'covers', 'deposit', 'method', 'cash'))$$, 'already been taken in full');
select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X512', 'covers', 'deposit', 'method', 'e_transfer', 'amount_cents', 1500, 'reference', 'X51OVER'));
select test.eq('over the deposit: held and to be returned with it', (select (s ->> 'over_cents') || '/' || (s ->> 'taken_cents') from app.deposit_state(test.id('booking:CC-X512')) s), '1500/61500');
select test.eq('the deposit given back is all that was taken', (select captured_cents::text from deposits where booking_id = test.id('booking:CC-X512')), '61500');

-- ================================================================ D. a deposit change reaches every record
select test.x51_unpaid('CC-X514', 'X51D', 'confirmed', 30);
insert into deposits (booking_id, amount_cents, method, status) values (test.id('booking:CC-X514'), 30000, 'card_hold', 'pending');
select app.booking_staff_edit(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X514', 'changes', jsonb_build_object('deposit_cents', 60000), 'reason', 'Raised for this renter'));
select test.eq('the booking deposit changed', (select deposit_cents::text from bookings where booking_number = 'CC-X514'), '60000');
select test.eq('the deposit not taken yet follows', (select amount_cents::text from deposits where booking_id = test.id('booking:CC-X514')), '60000');
select test.eq('the Money tab collects the new amount', (select app.booking_money(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X514')) ->> 'deposit_cents'), '60000');

-- raised while waiting for payment, with the offer out
select test.mk_booking('CC-X515', 'X51D', 'x51_r', to_char(now() at time zone 'America/Toronto' + interval '40 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '41 days', 'YYYY-MM-DD 10:00'), 'pending_payment', 6000);
update bookings set deposit_cents = 30000 where booking_number = 'CC-X515';
select app.booking_staff_edit(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X515', 'changes', jsonb_build_object('deposit_cents', 50000), 'reason', 'A higher deposit'));
select test.eq('the deposit is raised while waiting for payment', (select deposit_cents::text || '/' || status from bookings where booking_number = 'CC-X515'), '50000/pending_payment');
select test.throws('only an Admin raises it', $$select app.booking_deposit_raise(test.id('x51_r'), jsonb_build_object('booking', 'CC-X515', 'changes', jsonb_build_object('deposit_cents', 70000), 'reason', 'Mine'))$$);

-- ================================================================ E. a void resets the deposit everywhere
select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X514', 'covers', 'deposit', 'method', 'cash', 'amount_cents', 30000));
select app.void_manual_payment(test.id('x51_admin'), (select id from manual_payments where booking_id = test.id('booking:CC-X514') and covers = 'deposit' and voided_at is null), 'Recorded twice by mistake');
select test.eq('voided: the deposit is not taken', (select status || '/' || captured_cents from deposits where booking_id = test.id('booking:CC-X514')), 'pending/0');
select test.eq('voided: the amount owed is the deposit again', (select amount_cents::text from deposits where booking_id = test.id('booking:CC-X514')), '60000');
select test.lives('voided: the deposit can be recorded again', $$select app.record_booking_payment(test.id('x51_admin'), jsonb_build_object('booking', 'CC-X514', 'covers', 'deposit', 'method', 'cash'))$$);
select test.eq('recorded again: collected in full', (select status || '/' || amount_cents from deposits where booking_id = test.id('booking:CC-X514')), 'captured/120000');
select test.ok('the void is in the deposit history', exists (select 1 from deposit_events e join deposits d on d.id = e.deposit_id where d.booking_id = test.id('booking:CC-X514') and e.kind = 'voided'));

-- ================================================================ G. the repair of CC-10478
select test.mk_booking('CC-10478', 'X51A', 'x51_r', to_char(now() at time zone 'America/Toronto' - interval '1 day', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '1 day', 'YYYY-MM-DD 10:00'), 'on_rent', 6000);
select test.mk_line('CC-10478', 'lead_time', 500);
select test.mk_line('CC-10478', 'young_driver_21_25', 4000);
select test.mk_line('CC-10478', 'coverage_sold', 3000);
select app.sync_booking_price(test.id('booking:CC-10478'));
update booking_line_items set payment_id = null where booking_id = test.id('booking:CC-10478');
delete from payments where booking_id = test.id('booking:CC-10478');
update bookings set deposit_cents = 60000, rental_pay_method = 'e_transfer', deposit_pay_method = 'e_transfer' where booking_number = 'CC-10478';
-- as it was: the whole total recorded for the rental (its lines tied, the fee lines not), a $300 deposit voided
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
select test.id('x51:478pay'), b.id, b.renter_id, 'booking_total', 'charge', 'e_transfer', b.total_due_at_booking_cents, 'succeeded', now(), test.id('x51_admin') from bookings b where booking_number = 'CC-10478';
insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, recorded_by, covers)
select test.id('x51:478pay'), 'booking', b.id, b.renter_id, 'e_transfer', b.total_due_at_booking_cents, date '2026-11-15', 'C1AqmwK7G9Hu', test.id('x51_admin'), 'rental' from bookings b where booking_number = 'CC-10478';
update booking_line_items set payment_id = test.id('x51:478pay') where booking_id = test.id('booking:CC-10478') and charge_type in ('rental_charge', 'lead_time');
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
select test.id('x51:478dep'), b.id, b.renter_id, 'deposit', 'charge', 'e_transfer', 30000, 'cancelled', now(), test.id('x51_admin') from bookings b where booking_number = 'CC-10478';
insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, recorded_by, covers, voided_at, voided_by, void_reason)
select test.id('x51:478dep'), 'booking', b.id, b.renter_id, 'e_transfer', 30000, date '2026-11-15', 'C1AqmwK7G9Hu', test.id('x51_admin'), 'deposit', now(), test.id('x51_admin'), 'Recorded as a partial deposit'
  from bookings b where booking_number = 'CC-10478';
insert into deposits (booking_id, amount_cents, method, paid_method, status, hold_payment_id, taken_at, captured_cents)
values (test.id('booking:CC-10478'), 30000, 'offline', 'e_transfer', 'captured', test.id('x51:478dep'), now(), 30000);
create temp table x51_r1 as select app.repair_cc10478() r;
create temp table x51_r2 as select app.repair_cc10478() r;
select test.eq('CC-10478: nothing open', (select r ->> 'open_cents' from x51_r1), '0');
select test.eq('CC-10478: deposit $600 collected by e-Transfer', (select (r -> 'deposit' ->> 'status') || '/' || (r -> 'deposit' ->> 'amount_cents') || '/' || (r -> 'deposit' ->> 'paid_method') from x51_r1), 'captured/60000/e_transfer');
select test.eq('CC-10478: $13.27 as a tip', (select r ->> 'tips_cents' from x51_r1), '1327');
select test.eq('CC-10478: every fee line paid', (select count(*) from booking_line_items where booking_id = test.id('booking:CC-10478') and payment_id is null and voided_at is null), 0::bigint);
select test.eq('CC-10478: stays on rent', (select status::text from bookings where booking_number = 'CC-10478'), 'on_rent');
select test.eq('CC-10478: the deposit owed by e-Transfer is $600, nothing over', (select (s ->> 'required_cents') || '/' || (s ->> 'owed_cents') || '/' || (s ->> 'over_cents') from app.deposit_state(test.id('booking:CC-10478')) s), '60000/0/0');
select test.eq('CC-10478: the repair runs twice without change', (select r::text from x51_r2), (select r::text from x51_r1));
select test.eq('CC-10478: one deposit and one tip recorded, not two', (select count(*) from manual_payments where booking_id = test.id('booking:CC-10478') and voided_at is null and covers in ('deposit', 'tip')), 2::bigint);
