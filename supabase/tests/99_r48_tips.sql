-- 99: tips (migration 3053; docs/changes/2026-11-15-r48-tips.md): staff record cash and e-Transfer tips, the renter adds one
-- by card; the split between the salesperson and the handover, CarmaCars' half on a direct booking, one person doing
-- both, an Admin's split; never a line of the booking. Fixtures start with "x52"; addresses are example.test.
select test.suite('99 r48 tips');
select test.mk_user('x52_admin', 'admin');
select test.mk_user('x52_sales', 'va', 'sales');
select test.mk_user('x52_field', 'field');
select test.mk_owner('x52_o');
select test.mk_vehicle('X52A', 'x52_o');
select test.mk_renter('x52_r');

create function test.x52_booking(p_number text, p_day integer, p_sales text, p_handover text) returns uuid
language plpgsql as $$
declare v uuid;
begin
  v := test.mk_booking(p_number, 'X52A', 'x52_r', to_char(now() at time zone 'America/Toronto' + make_interval(days => p_day), 'YYYY-MM-DD 10:00'),
    to_char(now() at time zone 'America/Toronto' + make_interval(days => p_day + 1), 'YYYY-MM-DD 10:00'), 'confirmed', 10000);
  if p_sales is not null then update bookings set sales_staff_id = test.id(p_sales), sales_source = 'offer', sales_attributed_at = now() where id = v; end if;
  if p_handover is not null then
    perform app.log_booking_event(v, 'adjusted', 'confirmed', 'on_rent', null, 'Picked up', test.id(p_handover), 'staff', null);
  end if;
  return v;
end $$;
create function test.x52_tip(p_number text, p_cents bigint, p_method text default 'cash', p_ref text default null) returns uuid language sql as $$
  select (app.record_booking_payment(test.id('x52_admin'), jsonb_build_object('booking', p_number, 'covers', 'tip', 'method', p_method, 'amount_cents', p_cents, 'reference', p_ref)) ->> 'tip_id')::uuid $$;
create function test.x52_shares(p_tip uuid) returns text language sql as $$
  select string_agg(s.role || ':' || coalesce(u.email, 'carmacars') || ':' || s.amount_cents, ', ' order by s.role, s.amount_cents)
    from tip_shares s left join users u on u.id = s.staff_id where s.tip_id = p_tip $$;

-- the salesperson and another staff member at the handover: 50/50, an odd cent to the salesperson
select test.x52_booking('CC-X521', 10, 'x52_sales', 'x52_field');
create temp table x52_t as select test.x52_tip('CC-X521', 1001) t1;
grant all on x52_t to public;
select test.eq('split 50/50 between the salesperson and the handover', test.x52_shares((select t1 from x52_t)),
  'handover:x52_field@example.test:500, sales:x52_sales@example.test:501');
-- a direct booking (no staff salesperson): CarmaCars keeps that half
select test.x52_booking('CC-X522', 12, null, 'x52_field');
alter table x52_t add column t2 uuid; update x52_t set t2 = test.x52_tip('CC-X522', 2000, 'e_transfer', 'X52REF2');
select test.eq('a direct booking: CarmaCars keeps the salesperson''s half', test.x52_shares((select t2 from x52_t)),
  'company:carmacars:1000, handover:x52_field@example.test:1000');
-- one person did both: all of it
select test.x52_booking('CC-X523', 14, 'x52_sales', 'x52_sales');
alter table x52_t add column t3 uuid; update x52_t set t3 = test.x52_tip('CC-X523', 1500);
select test.eq('one person did both: 100%', test.x52_shares((select t3 from x52_t)), 'both:x52_sales@example.test:1500');
-- no staff handover (a self pickup): CarmaCars keeps that half
select test.x52_booking('CC-X524', 16, 'x52_sales', null);
alter table x52_t add column t4 uuid; update x52_t set t4 = test.x52_tip('CC-X524', 1000);
select test.eq('no staff handover: CarmaCars keeps that half', test.x52_shares((select t4 from x52_t)), 'company:carmacars:500, sales:x52_sales@example.test:500');
-- neither: all to CarmaCars
select test.x52_booking('CC-X525', 18, null, null);
alter table x52_t add column t5 uuid; update x52_t set t5 = test.x52_tip('CC-X525', 800);
select test.eq('neither: all to CarmaCars, as company revenue', (select sum(amount_cents)::text || '/' || count(*) from tip_shares where tip_id = (select t5 from x52_t) and staff_id is null), '800/2');

-- the same e-Transfer twice is one tip
select test.eq('the same reference twice is one tip', (app.record_booking_payment(test.id('x52_admin'), jsonb_build_object('booking', 'CC-X522', 'covers', 'tip', 'method', 'e_transfer', 'amount_cents', 2000, 'reference', 'X52REF2')) ->> 'repeat'), 'true');
select test.throws('a card tip is not recorded by staff', $$select test.x52_tip('CC-X521', 500, 'cheque')$$, 'cash or e-Transfer');
select test.throws('an e-Transfer tip needs its reference', $$select test.x52_tip('CC-X521', 500, 'e_transfer')$$, 'reference');
select test.throws('the renter cannot record one', $$select app.record_tip(test.id('x52_r'), jsonb_build_object('booking', 'CC-X521', 'method', 'cash', 'amount_cents', 500))$$);

-- never a line of the booking: nothing owed changes, no owner revenue
select test.eq('a tip is no line of the booking', (select count(*) from booking_line_items where booking_id = test.id('booking:CC-X521') and charge_type not in ('rental_charge', 'lead_time')), 0::bigint);
select test.eq('a tip is not paid against the rental', (select count(*) from manual_payments where booking_id = test.id('booking:CC-X521') and covers <> 'tip'), 0::bigint);
select test.eq('the payment is a tip', (select string_agg(distinct purpose, ',') from payments where booking_id = test.id('booking:CC-X521') and created_by = test.id('x52_admin')), 'tip');

-- an Admin's split, and back to the rule
select app.tip_split_set(test.id('x52_admin'), jsonb_build_object('tip', (select t1 from x52_t), 'reason', 'The salesperson also delivered the car',
  'shares', jsonb_build_array(jsonb_build_object('staff_id', test.id('x52_sales'), 'amount_cents', 1001))));
select test.eq('an Admin overrides the split', test.x52_shares((select t1 from x52_t)), 'override:x52_sales@example.test:1001');
select test.throws('the shares must add up to the tip', format($$select app.tip_split_set(test.id('x52_admin'), jsonb_build_object('tip', %L, 'reason', 'Wrong sum', 'shares', jsonb_build_array(jsonb_build_object('staff_id', test.id('x52_sales'), 'amount_cents', 900))))$$, (select t1 from x52_t)), 'add up');
select test.throws('only an Admin splits a tip', format($$select app.tip_split_set(test.id('x52_sales'), jsonb_build_object('tip', %L, 'reason', 'Mine', 'shares', jsonb_build_array(jsonb_build_object('staff_id', test.id('x52_sales'), 'amount_cents', 1001))))$$, (select t1 from x52_t)));
select app.tip_split_set(test.id('x52_admin'), jsonb_build_object('tip', (select t1 from x52_t), 'reset', true));
select test.eq('reset: back to the rule', test.x52_shares((select t1 from x52_t)), 'handover:x52_field@example.test:500, sales:x52_sales@example.test:501');

-- each person's share on their pay view; CarmaCars' share in the Admin report
select test.eq('the salesperson''s tips: 501 + 1500 + 500', (app.my_tips(test.id('x52_sales'), '{}') ->> 'total_cents'), '2501');
select test.eq('the handover''s tips: 500 + 1000', (app.my_tips(test.id('x52_field'), '{}') ->> 'total_cents'), '1500');
select test.eq('Admin > Money: CarmaCars'' share', (app.tips_report(test.id('x52_admin'), '{}') ->> 'company_cents'), '2300');
select test.eq('Admin > Money: every tip', (app.tips_report(test.id('x52_admin'), '{}') ->> 'total_cents'), '6301');
select test.throws('the report is for Admins', $$select app.tips_report(test.id('x52_sales'), '{}')$$);
select test.eq('the Money tab lists the booking''s tips with the split', (select jsonb_array_length(app.booking_money(test.id('x52_admin'), jsonb_build_object('booking', 'CC-X521')) -> 'tips')), 1);

-- a void takes the tip and its shares away
select app.void_manual_payment(test.id('x52_admin'), (select id from manual_payments where payment_id = (select payment_id from tips where id = (select t4 from x52_t))), 'Entered on the wrong booking');
select test.eq('voided: the tip is voided', (select status from tips where id = (select t4 from x52_t)), 'voided');
select test.eq('voided: out of the salesperson''s tips', (app.my_tips(test.id('x52_sales'), '{}') ->> 'total_cents'), '2001');

-- the renter's tip by card: the suggestions, the link, paid
select test.eq('10, 15 and 20% of the total', (select string_agg(x ->> 'percent_bps', ',') from jsonb_array_elements(app.tip_options(test.id('booking:CC-X521')) -> 'options') x), '1000,1500,2000');
create temp table x52_q as select public.renter_tip_payreq(test.id('booking:CC-X521'), test.id('x52_r'), 1500, 1500, 'receipt', repeat('a', 64)) q;
grant all on x52_q to public;
select test.throws('only the renter of the booking adds a tip there', $$select public.renter_tip_payreq(test.id('booking:CC-X521'), test.id('x52_sales'), 1500, null, 'receipt', repeat('b', 64))$$, 'renter of the booking');
update payment_requests set processor_intent_id = 'pi_x52' where id = (select (q ->> 'id')::uuid from x52_q);
select public.server_payreq_settle((select (q ->> 'id')::uuid from x52_q), jsonb_build_object('id', 'pi_x52', 'status', 'succeeded', 'amount', 1500, 'card', jsonb_build_object('brand', 'visa', 'last4', '4242', 'funding', 'credit')));
select test.eq('the card tip is paid and split', (select t.status || '/' || t.method || '/' || (select count(*) from tip_shares s where s.tip_id = t.id) from tips t where t.id = (select (q ->> 'tip_id')::uuid from x52_q)), 'paid/card/2');
select test.eq('it shows on the booking''s tips', (app.tip_options(test.id('booking:CC-X521')) ->> 'paid_cents'), '2501');
select test.ok('the rental owes nothing more for it', app.booking_part_open(test.id('booking:CC-X521'), 'rental') + app.booking_part_open(test.id('booking:CC-X521'), 'fees') = 0);
update program_settings set tips_on = false;
select test.throws('tips off: none recorded', $$select test.x52_tip('CC-X521', 500)$$, 'Tips are off');
update program_settings set tips_on = true;
