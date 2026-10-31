-- 99: choices drive charges (migration 0250, Release 24). A fee set by hand is priced only while the choice that makes
-- its line is chosen: no delivery fee with the car at our location, no Protection Plan without option 3, no young driver
-- fee for a renter of 30, no winter tire without the winter tire; and a fee set by hand on a booking is deleted when its
-- choice goes. Fixtures start with "r24c".
select test.suite('99 choices drive charges');

select test.mk_user('r24c_admin', 'admin');
select test.mk_renter('r24c_rita');
select test.mk_renter('r24c_young');
update renters set date_of_birth = (now() - interval '22 years')::date where id = test.id('renter:r24c_young');
update drivers set date_of_birth = (now() - interval '22 years')::date where renter_id = test.id('renter:r24c_young');

create temp table s99c as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s99c(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s99c where k = p_k $$;
insert into s99c select 'car', app.vehicle_add(test.id('r24c_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1TXCXMM0000000C01',
  'plate', 'TXCD01', 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
create or replace function test.s99cp(p jsonb, p_renter text default 'r24c_rita') returns jsonb language sql as $$
  select app.door(test.id('r24c_admin'), 'aal2', 'ops_read', 'offer_preview', jsonb_build_object(
    'vehicle_id', test.s99c('car') ->> 'vehicle_id', 'renter_id', test.id('renter:' || p_renter),
    'pickup_at', date_trunc('hour', now()) + interval '10 days', 'return_at', date_trunc('hour', now()) + interval '12 days',
    'source', 'phone', 'coverage_option', 1, 'rental_pay_method', 'card', 'deposit_pay_method', 'card', 'fee_reason', 'test',
    'pickup_location', jsonb_build_object('kind', 'our_location'), 'return_location', jsonb_build_object('kind', 'our_location')) || p) $$;
create or replace function test.s99cl(q jsonb) returns text language sql stable as $$
  select coalesce(string_agg(l ->> 'charge_type' || '=' || (l ->> 'amount_cents'), ' ' order by l ->> 'charge_type'), '')
    from jsonb_array_elements(q #> '{booking,lines}') l where l ->> 'stage' = 'booking' $$;

-- ================================================================ 1. an offer: no choice, no charge
insert into s99c select 'plain', test.s99cp('{}');
insert into s99c select 'orphans', test.s99cp('{"line_overrides": {"delivery": 5000, "pickup": 4000, "coverage_sold": 3000, "winter_tire": 2000, "baby_seat": 1000, "young_driver_21_25": 1500, "additional_driver": 900}}');
select test.ok('the offer prices', (test.s99c('plain') ->> 'ok')::boolean, test.s99c('plain') ->> 'error');
select test.eq('fees set by hand for choices not chosen make no line (our location both ways, option 1, no add-on, a renter of 26 or more)',
  test.s99cl(test.s99c('orphans')), test.s99cl(test.s99c('plain')));
select test.eq('and the total is the rate sheet''s', (test.s99c('orphans') #>> '{booking,total_due_at_booking_cents}'), (test.s99c('plain') #>> '{booking,total_due_at_booking_cents}'));

-- ================================================================ 2. the choice chosen: the fee set by hand is priced as before
insert into s99c select 'delivered', test.s99cp('{"pickup_location": {"kind": "delivery", "address": "1 Test Street, Toronto", "distance_km": 12}, "line_overrides": {"delivery": 5000, "pickup": 4000}}');
select test.eq('a delivery: the delivery fee set by hand is the line; the collection fee (return at our location) is not',
  test.s99cl(test.s99c('delivered')), 'delivery=5000 rental_charge=20000');
insert into s99c select 'collected', test.s99cp('{"return_location": {"kind": "delivery", "address": "1 Test Street, Toronto"}, "line_overrides": {"pickup": 4000}}');
select test.eq('a collection with no distance yet (no fee priced): the fee typed by hand still makes the line',
  test.s99cl(test.s99c('collected')), 'pickup=4000 rental_charge=20000');
insert into s99c select 'zero', test.s99cp('{"pickup_location": {"kind": "delivery", "address": "1 Test Street, Toronto", "distance_km": 12}, "line_overrides": {"delivery": 0}}');
select test.ok('a delivery fee set to 0 by hand keeps its line at 0 (the screen knows it is set by hand)',
  test.s99cl(test.s99c('zero')) like '%delivery=0%', test.s99cl(test.s99c('zero')));
insert into s99c select 'plan', test.s99cp('{"coverage_option": 3, "line_overrides": {"coverage_sold": 3000}}');
select test.ok('option 3: the Protection Plan price set by hand is priced', test.s99cl(test.s99c('plan')) like '%coverage_sold=3000%', test.s99cl(test.s99c('plan')));

-- ================================================================ 3. the drivers: a young driver fee follows the age
insert into s99c select 'young_hand', test.s99cp('{"line_overrides": {"young_driver_21_25": 1500, "young_driver_18_20": 900}}', 'r24c_young');
select test.ok('a renter of 22 with a young driver fee set by hand: that fee, not the other band''s',
  test.s99cl(test.s99c('young_hand')) like '%young_driver_21_25=1500%' and test.s99cl(test.s99c('young_hand')) not like '%young_driver_18_20%', test.s99cl(test.s99c('young_hand')));
select test.eq('line_overrides_live: an additional driver fee only with an additional driver',
  app.line_overrides_live('{"line_overrides": {"additional_driver": 900, "custom_x": 1}, "drivers": [{"role": "renter", "age_band": "26_plus"}]}'), '{"custom_x": 1}'::jsonb);
select test.eq('line_overrides_live: an age not known keeps a young driver fee typed by hand',
  app.line_overrides_live('{"line_overrides": {"young_driver_18_20": 900}, "drivers": [{"role": "renter", "age_band": "26_plus", "assumed": true}]}'), '{"young_driver_18_20": 900}'::jsonb);
select test.eq('line_overrides_live: a spec that does not say keeps everything',
  app.line_overrides_live('{"line_overrides": {"delivery": 1, "coverage_sold": 2}}'), '{"delivery": 1, "coverage_sold": 2}'::jsonb);

-- ================================================================ 4. a booking: the fee set by hand goes with its choice
insert into s99c select 'made', app.door(test.id('r24c_admin'), 'aal2', 'ops_do', 'offer_create', jsonb_build_object(
  'vehicle_id', test.s99c('car') ->> 'vehicle_id', 'renter_id', test.id('renter:r24c_rita'),
  'pickup_at', date_trunc('hour', now()) + interval '20 days', 'return_at', date_trunc('hour', now()) + interval '22 days',
  'source', 'phone', 'coverage_option', 3, 'rental_pay_method', 'card', 'deposit_pay_method', 'card', 'notify', false, 'draft', true,
  'pickup_location', jsonb_build_object('kind', 'delivery', 'address', '1 Test Street, Toronto', 'distance_km', 12),
  'return_location', jsonb_build_object('kind', 'our_location'),
  'line_overrides', jsonb_build_object('delivery', 6100, 'coverage_sold', 3300), 'fee_reason', 'test'));
create or replace function test.s99cb() returns uuid language sql stable as $$ select (test.s99c('made') ->> 'booking_id')::uuid $$;
select test.eq('the offer keeps both fees set by hand', (select string_agg(line_key || '=' || total_cents, ' ' order by line_key) from booking_line_overrides where booking_id = test.s99cb()),
  'coverage_sold=3300 delivery=6100');
update bookings set pickup_method = 'collected', pickup_location_kind = 'our_location' where id = test.s99cb();
select test.eq('the car handed over at our location: the delivery fee set by hand is deleted, the Protection Plan''s kept',
  (select string_agg(line_key, ' ') from booking_line_overrides where booking_id = test.s99cb()), 'coverage_sold');
update bookings set coverage_option = 1 where id = test.s99cb();
select test.eq('option 1: the Protection Plan price set by hand is deleted', (select count(*) from booking_line_overrides where booking_id = test.s99cb()), 0::bigint);
select test.ok('the booking repriced has neither line',
  not exists (select 1 from jsonb_array_elements((app.price_lines(app.booking_price_spec(test.s99cb()))) -> 'lines') l where l ->> 'charge_type' in ('delivery', 'coverage_sold')));
