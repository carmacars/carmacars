-- 99: migration 2781 (release 44): a cancelled or no-show booking is on the owner's statement only for the rental charge
-- actually kept. A cancellation with nothing paid has no line (it put $409.50 on a statement before); a kept cancellation
-- charge is a line for the amount kept. Fixtures start with "ocx"; every address is example.test.
select test.suite('99 r44 cancelled bookings on owner statements (2781)');

select test.mk_user('ocx_admin', 'admin');
select test.mk_owner('ocx_olga');
select test.mk_vehicle('OCX1', 'ocx_olga');
select test.mk_renter('ocx_r1', false); select test.mk_renter('ocx_r2', false); select test.mk_renter('ocx_r3', false); select test.mk_renter('ocx_r4', false);

-- C1: cancelled, its $409.50 rental charge never paid (the card failed), nothing refunded
select test.mk_booking('OCX-C1', 'OCX1', 'ocx_r1', '2026-10-24 10:00', '2026-10-27 10:00', 'cancelled', 0, 'standard', null, '2026-10-10 10:00');
select test.mk_line('OCX-C1', 'rental_charge', 40950, false);
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason, channel, total_paid_cents)
values (test.id('booking:OCX-C1'), timestamp '2026-10-20 15:00' at time zone 'America/Toronto', 'renter', 'renter_request', 'email', 0);
-- C2: cancelled, $400 + HST paid, 75% refunded: a $100 cancellation charge kept
select test.mk_booking('OCX-C2', 'OCX1', 'ocx_r2', '2026-10-25 10:00', '2026-10-29 10:00', 'cancelled', 40000, 'standard', null, '2026-10-10 10:00');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason, channel, total_paid_cents)
values (test.id('booking:OCX-C2'), timestamp '2026-10-21 15:00' at time zone 'America/Toronto', 'renter', 'renter_request', 'email', 45200);
insert into refunds (id, booking_id, payment_id, reason, refund_bps, amount_cents, status, requested_by, approved_by, paid_at)
values (test.id('refund:OCX-C2'), test.id('booking:OCX-C2'), test.id('payment:OCX-C2'), 'cancellation', 7500, 33900, 'paid',
        test.id('ocx_admin'), test.id('ocx_admin'), timestamptz '2026-10-22 15:00+00');
select app.allocate_refund(test.id('refund:OCX-C2'));
-- C3: a no-show, paid in full and nothing refunded: kept in full
select test.mk_booking('OCX-C3', 'OCX1', 'ocx_r3', '2026-10-26 10:00', '2026-10-28 10:00', 'no_show', 20000, 'standard', null, '2026-10-10 10:00');
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason, channel, total_paid_cents)
values (test.id('booking:OCX-C3'), timestamp '2026-10-26 12:00' at time zone 'America/Toronto', 'carmacars', 'no_show', 'system', 22600);
-- R4: an ordinary closed rental: unchanged
select test.mk_booking('OCX-R4', 'OCX1', 'ocx_r4', '2026-10-20 10:00', '2026-10-23 10:00', 'closed', 30000);

select app.build_owner_statement(test.id('owner:ocx_olga'), date '2026-10-01');
create temp view ocx_st as select * from owner_statements where owner_id = test.id('owner:ocx_olga') and status <> 'void';
create function pg_temp.line(p_booking text) returns owner_statement_lines language sql as $$
  select l.* from owner_statement_lines l join ocx_st s on s.id = l.owner_statement_id
   where s.statement_month = date '2026-10-01' and l.line_type = 'rental' and l.booking_id = test.id('booking:' || p_booking) $$;
create function pg_temp.split(p_booking text) returns booking_splits language sql as $$ select * from booking_splits where booking_id = test.id('booking:' || p_booking) $$;

select test.ok('the unpaid cancellation has a split with Owner Revenue (what used to reach the statement)', (pg_temp.split('OCX-C1')).owner_revenue_cents > 0);
select test.ok('cancelled with nothing collected: no line on the statement', (pg_temp.line('OCX-C1')).booking_id is null);
select test.eq('cancelled with a kept cancellation charge: a line for the $100 kept (before HST)', (pg_temp.line('OCX-C2')).rental_charge_cents, 10000::bigint);
select test.ok('its Owner Revenue and payout are the kept part, never more than the split',
  (pg_temp.line('OCX-C2')).owner_revenue_cents between 1 and (pg_temp.split('OCX-C2')).owner_revenue_cents
  and (pg_temp.line('OCX-C2')).amount_cents = (pg_temp.line('OCX-C2')).owner_revenue_cents - (pg_temp.line('OCX-C2')).revenue_share_cents);
select test.eq('a no-show paid in full and kept: the whole payout', (pg_temp.line('OCX-C3')).amount_cents, (pg_temp.split('OCX-C3')).owner_payout_cents);
select test.eq('an ordinary closed rental: unchanged', (pg_temp.line('OCX-R4')).amount_cents, (pg_temp.split('OCX-R4')).owner_payout_cents);
select test.ok('the statement total has no revenue from the unpaid cancellation',
  (select coalesce(sum(l.owner_revenue_cents), 0) from owner_statement_lines l join ocx_st s on s.id = l.owner_statement_id
    where s.statement_month = date '2026-10-01' and l.line_type = 'rental')
  = (pg_temp.line('OCX-C2')).owner_revenue_cents + (pg_temp.line('OCX-C3')).owner_revenue_cents + (pg_temp.line('OCX-R4')).owner_revenue_cents);

-- the card is charged later: the next build counts it
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
select test.id('payment:OCX-C1:late'), b.id, b.renter_id, 'booking_total', 'charge', 'card', 46274, 'succeeded', now() from bookings b where b.id = test.id('booking:OCX-C1');
update booking_line_items set payment_id = test.id('payment:OCX-C1:late') where booking_id = test.id('booking:OCX-C1');
select app.compute_booking_split(test.id('booking:OCX-C1'));
select app.build_owner_statement(test.id('owner:ocx_olga'), date '2026-10-01');
select test.eq('collected later: the cancellation charge kept is on the statement then', (pg_temp.line('OCX-C1')).rental_charge_cents, 40950::bigint);

-- hidden from the owner (2480) stays off as before
update bookings set owner_revenue_excluded = true where id = test.id('booking:OCX-C3');
select app.compute_booking_split(test.id('booking:OCX-C3'));
select app.build_owner_statement(test.id('owner:ocx_olga'), date '2026-10-01');
select test.ok('a booking kept off the owner''s revenue stays off', (pg_temp.line('OCX-C3')).booking_id is null);

select test.ok('server only', not has_function_privilege('authenticated', 'app.owner_period_rentals(uuid, uuid, date)', 'execute')
  and not has_function_privilege('anon', 'app.owner_period_rentals_pre2781(uuid, uuid, date)', 'execute'));
