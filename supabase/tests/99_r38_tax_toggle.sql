-- 99: "Amounts I type: After tax (HST included)" on the price step (owner, Nov 11: "the toggle does nothing"). A total typed
-- after tax is priced to exactly that total, by the offer preview, the offer saved and Add a rental's check. Fixtures "tg".
select test.suite('99 r38 tax toggle');
select test.mk_user('tg_admin', 'admin');
select test.mk_renter('tg_rita');
create temp table s99tt as select null::text as k, null::jsonb as v limit 0;
insert into s99tt select 'car', app.vehicle_add(test.id('tg_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1TGCXMM0000000001',
  'plate', 'TGC001', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create or replace function test.s99tt(p_cents bigint, p_tax text, p_from integer) returns jsonb language sql stable as $$
  select jsonb_build_object('vehicle_id', (select (v ->> 'vehicle_id')::uuid from pg_temp.s99tt where k = 'car'),
    'pickup_at', test.base(4) + make_interval(days => p_from), 'return_at', test.base(4) + make_interval(days => p_from + 3), 'renter_id', test.id('renter:tg_rita'),
    'coverage_option', 1, 'source', 'phone', 'rental_pay_method', 'card', 'deposit_pay_method', 'card', 'payment', jsonb_build_object('mode', 'link'),
    'rental_charge_cents', p_cents, 'price_tax', p_tax, 'price_reason', 'Agreed') $$;

select test.eq('offer preview, $410.19 typed after tax: the total is $410.19 ($363.00 + $47.19 HST)',
  (select x #>> '{booking,total_due_at_booking_cents}' || ' ' || (x #> '{booking,lines}' -> 0 ->> 'amount_cents') || '/' || (x #> '{booking,lines}' -> 0 ->> 'hst_cents')
     from (select app.door(test.id('tg_admin'), 'aal2', 'ops_read', 'offer_preview', test.s99tt(41019, 'included', 10)) x) q
   where x #> '{booking,lines}' -> 0 ->> 'charge_type' = 'rental_charge'), '41019 36300/4719');
select test.eq('offer preview, $1,490.00 typed after tax: the total is $1,490.00',
  (select (x #>> '{booking,total_due_at_booking_cents}')::bigint from (select app.door(test.id('tg_admin'), 'aal2', 'ops_read', 'offer_preview', test.s99tt(149000, 'included', 10)) x) q), 149000::bigint);
select test.eq('offer preview, $410.19 typed before tax: HST goes on top ($463.51)',
  (select (x #>> '{booking,total_due_at_booking_cents}')::bigint from (select app.door(test.id('tg_admin'), 'aal2', 'ops_read', 'offer_preview', test.s99tt(41019, 'plus', 10)) x) q), 46351::bigint);
select test.eq('Add a rental''s check, $410.19 and $1,490.00 typed after tax: exactly those totals',
  (select string_agg(x #>> '{quote,total_due_at_booking_cents}', ' ' order by t) from (select t, app.door(test.id('tg_admin'), 'aal2', 'ops_read', 'manual_rental_quote', test.s99tt(t, 'included', 10)) x
     from unnest(array[41019, 149000]::bigint[]) t) q), '41019 149000');
insert into s99tt select 'made', app.door(test.id('tg_admin'), 'aal2', 'ops_do', 'manual_rental_create', test.s99tt(149000, 'included', 20));
select test.eq('the rental saved by hand after tax keeps the total typed: $1,490.00',
  (select b.total_due_at_booking_cents from bookings b where b.id = (select (v ->> 'booking_id')::uuid from s99tt where k = 'made')), 149000::bigint);
