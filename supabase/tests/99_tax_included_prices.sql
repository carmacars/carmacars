-- 99: amounts typed after tax (migration 0175). Add a rental's check prices the rental charge typed (plus tax or tax
-- included) exactly as the booking is saved, the rate sheet stays beside it, and a visitor's quote never takes the
-- staff-only options. Fixtures start with "ti".
select test.suite('99 tax included prices');

select test.mk_user('ti_admin', 'admin');
select test.mk_renter('ti_rita');

create temp table s99t as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s99t(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s99t where k = p_k $$;
create or replace function test.s99b(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = (test.s99t(p_k) ->> 'booking_id')::uuid $$;
do $$
declare i integer;
begin
  for i in 1 .. 4 loop
    insert into s99t select 'car' || i, app.vehicle_add(test.id('ti_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1TXCXMM00000000' || lpad(i::text, 2, '0'),
      'plate', 'TXC00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create or replace function test.s99v(p text) returns uuid language sql stable as $$ select (test.s99t(p) ->> 'vehicle_id')::uuid $$;
create or replace function test.s99r(p_vehicle uuid, p jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', date_trunc('hour', now()) + interval '10 days', 'return_at', date_trunc('hour', now()) + interval '12 days',
                            'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:ti_rita'), 'sales_choice', 'for_carmacars',
                            'payment', jsonb_build_object('mode', 'link')) || p $$;
create or replace function test.s99q(p jsonb) returns jsonb language sql as $$
  select app.door(test.id('ti_admin'), 'aal2', 'ops_read', 'manual_rental_quote', p) $$;
create or replace function test.s99line(q jsonb, p_type text) returns text language sql stable as $$
  select l ->> 'amount_cents' || '/' || (l ->> 'hst_cents') from jsonb_array_elements(q #> '{quote,lines}') l where l ->> 'charge_type' = p_type limit 1 $$;

-- ================================================================ 1. tax included: $270 rental + $50 Protection Plan = $320.00
insert into s99t select 'q_inc', test.s99q(test.s99r(test.s99v('car1'), '{"rental_charge_cents": 27000, "price_tax": "included", "coverage_option": 3, "line_overrides": {"coverage_sold": 4425}}'));
select test.eq('the check prices the rental charge typed tax included: $238.94 before tax and $31.06 HST ($270.00 exactly)',
  test.s99line(test.s99t('q_inc'), 'rental_charge'), '23894/3106');
select test.eq('the Protection Plan typed $44.25 before tax ($50.00 after tax): $5.75 HST', test.s99line(test.s99t('q_inc'), 'coverage_sold'), '4425/575');
select test.eq('the check''s total is the $320.00 typed', (test.s99t('q_inc') #>> '{quote,total_due_at_booking_cents}')::bigint, 32000::bigint);
select test.eq('the rental charge line names the choice', (select l ->> 'description' from jsonb_array_elements(test.s99t('q_inc') #> '{quote,lines}') l where l ->> 'charge_type' = 'rental_charge'),
  'Rental charge ($270.00 tax included)');
select test.eq('the rate sheet stays the rate sheet''s ($200.00 for two days)', (test.s99t('q_inc') ->> 'rate_sheet_cents')::bigint, 20000::bigint);
insert into s99t select 'c_inc', app.door(test.id('ti_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s99r(test.s99v('car1'), '{"rental_charge_cents": 27000, "price_tax": "included", "coverage_option": 3, "line_overrides": {"coverage_sold": 4425}, "price_reason": "Paid $320 cash", "fee_reason": "Paid $320 cash"}'));
select test.eq('the booking saved is the total the check showed: $320.00 ($283.19 + $36.81 HST)',
  (select subtotal_at_booking_cents || '/' || hst_at_booking_cents || '/' || total_due_at_booking_cents from test.s99b('c_inc')), '28319/3681/32000');

-- ================================================================ 2. plus tax: the check follows the rental charge typed
insert into s99t select 'q_plus', test.s99q(test.s99r(test.s99v('car2'), '{"rental_charge_cents": 21000, "price_tax": "plus"}'));
select test.eq('plus tax: $210.00 with $27.30 HST on top, the total $237.30 (not the rate sheet''s $226.00)',
  test.s99line(test.s99t('q_plus'), 'rental_charge') || ' ' || (test.s99t('q_plus') #>> '{quote,total_due_at_booking_cents}'), '21000/2730 23730');
insert into s99t select 'c_plus', app.door(test.id('ti_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s99r(test.s99v('car2'), '{"rental_charge_cents": 21000, "price_tax": "plus", "price_reason": "Agreed"}'));
select test.eq('plus tax: the booking saved has the same total', (test.s99b('c_plus')).total_due_at_booking_cents, 23730::bigint);

-- ================================================================ 3. a line that follows the rental charge (non-refundable discount)
insert into s99t select 'q_nr', test.s99q(test.s99r(test.s99v('car3'), '{"rental_charge_cents": 30000, "price_tax": "included", "booking_type": "non_refundable"}'));
insert into s99t select 'c_nr', app.door(test.id('ti_admin'), 'aal2', 'ops_do', 'manual_rental_create',
  test.s99r(test.s99v('car3'), '{"rental_charge_cents": 30000, "price_tax": "included", "booking_type": "non_refundable", "price_reason": "Agreed"}'));
select test.eq('non-refundable: the discount is worked out on the rental charge typed, in the check as in the booking saved',
  (test.s99t('q_nr') #>> '{quote,total_due_at_booking_cents}')::bigint, (test.s99b('c_nr')).total_due_at_booking_cents);

-- ================================================================ 4. nothing typed, and a visitor's quote
insert into s99t select 'q_none', test.s99q(test.s99r(test.s99v('car4')));
select test.eq('nothing typed: the rate sheet ($200.00 + $26.00 HST)', test.s99line(test.s99t('q_none'), 'rental_charge') || ' ' || (test.s99t('q_none') ->> 'rate_sheet_cents'), '20000/2600 20000');
select set_config('app.staff_pricing', '', false);
select test.eq('a visitor''s quote never takes the staff-only rental charge',
  (app.price_quote(test.s99v('car4'), date_trunc('hour', now()) + interval '10 days', date_trunc('hour', now()) + interval '12 days',
     '{"staff_rental_charge_cents": 100, "staff_price_tax": "plus"}'::jsonb) ->> 'rental_charge_cents')::bigint, 20000::bigint);
