-- 45: add-ons (migration 0066): the catalogue as seeded (active, the owner's prices), the pricing units (per trip, per
-- day with its most per trip, per hour with a minimum), prices by car class and body type, cars left out (electric),
-- months, notice, stock across overlapping bookings, the request (a chauffeur waits for staff), staff in an offer and
-- in a rental added by hand, after booking from the portal (card, no card, declined, cutoff), staff confirm and
-- remove (refund), the Fleet task, the field handover, prepaid fuel at check-in, the commission and kickback bases
-- unchanged, Owner Revenue unchanged, the company statement's Add-ons line, cancellations (tier, kept after notice),
-- the old extras still working, the doors and privileges. Fixtures start with "ao".
select test.suite('45 add-ons');

select test.mk_user('ao_admin', 'admin');
select test.mk_user('ao_cs', 'va', 'cs');
select test.mk_user('ao_fleet', 'va', 'fleet');
select test.mk_user('ao_sales', 'va', 'sales');
select test.mk_user('ao_field', 'field');
select test.mk_renter('ao_rita');
select test.mk_renter('ao_ron');
select test.mk_owner('ao_olive');
select test.mk_vehicle('ao_prog', 'ao_olive');
update staff_profiles set single_limit_cents = 900000 where user_id in (test.id('ao_cs'), test.id('ao_sales'));

create temp table s43 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s43(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s43 where k = p_k $$;
create or replace function test.s43b(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = coalesce((test.s43(p_k) ->> 'booking_id')::uuid, (test.s43(p_k) ->> 'id')::uuid) $$;
create or replace function test.s43a(p_code text) returns uuid language sql stable as $$ select id from addons where code = p_code $$;
create or replace function test.s43lines(p_booking uuid) returns text language sql stable as $$
  select string_agg(charge_type || '=' || amount_cents || '+' || hst_cents, ' ' order by description)
    from booking_line_items where booking_id = p_booking and voided_at is null and charge_type in ('addon', 'baby_seat', 'winter_tire') $$;
do $$
begin
  insert into s43 select 'std', app.vehicle_add(test.id('ao_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1AXCXMM0000000001', 'plate', 'AOC001',
    'year', 2024, 'make', 'Kia', 'model', 'K5', 'class', 'standard', 'fuel', 'gasoline', 'body_type', 'sedan',
    'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  insert into s43 select 'suv', app.vehicle_add(test.id('ao_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1AXCXMM0000000002', 'plate', 'AOC002',
    'year', 2024, 'make', 'Kia', 'model', 'Sorento', 'class', 'suv', 'fuel', 'gasoline', 'body_type', 'suv',
    'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  insert into s43 select 'van', app.vehicle_add(test.id('ao_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1AXCXMM0000000003', 'plate', 'AOC003',
    'year', 2024, 'make', 'Kia', 'model', 'Carnival', 'class', 'standard', 'fuel', 'gasoline', 'body_type', 'minivan',
    'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  insert into s43 select 'ev', app.vehicle_add(test.id('ao_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1AXCXMM0000000004', 'plate', 'AOC004',
    'year', 2024, 'make', 'Kia', 'model', 'EV6', 'class', 'standard', 'fuel', 'electric', 'body_type', 'suv',
    'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  insert into s43 select 'std2', app.vehicle_add(test.id('ao_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1AXCXMM0000000005', 'plate', 'AOC005',
    'year', 2024, 'make', 'Kia', 'model', 'K5', 'class', 'standard', 'fuel', 'gasoline', 'body_type', 'sedan',
    'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  insert into s43 select 'std3', app.vehicle_add(test.id('ao_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1AXCXMM0000000006', 'plate', 'AOC006',
    'year', 2024, 'make', 'Kia', 'model', 'K5', 'class', 'standard', 'fuel', 'gasoline', 'body_type', 'sedan',
    'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
end $$;
create or replace function test.s43v(p text) returns uuid language sql stable as $$ select (test.s43(p) ->> 'vehicle_id')::uuid $$;
-- a rental added by hand by an Admin, paid another way (confirmed and paid at once)
create or replace function test.s43r(p_vehicle uuid, p_from interval, p_to interval, p jsonb default '{}'::jsonb, p_renter text default 'ao_rita') returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
                            'source', 'phone', 'coverage_option', 1, 'renter_id', test.id('renter:' || p_renter),
                            'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')) || p $$;
create or replace function test.s43req(p_key text, p_vehicle uuid, p_from interval, p_to interval, p_addons jsonb) returns jsonb language sql as $$
  select test.ba_req(p_key, 'ao.' || p_key || '@example.test', 'none', date_trunc('hour', now()) + p_from, date_trunc('hour', now()) + p_to,
                     jsonb_build_object('vehicle_id', p_vehicle, 'addons', p_addons)) $$;
create or replace function test.s43q(p_vehicle uuid, p_from interval, p_to interval, p_addons jsonb, p_channel text default null) returns jsonb language sql as $$
  select app.price_quote(p_vehicle, date_trunc('hour', now()) + p_from, date_trunc('hour', now()) + p_to,
                         jsonb_build_object('addons', p_addons) || case when p_channel is null then '{}'::jsonb else jsonb_build_object('addon_channel', p_channel) end) $$;
create or replace function test.s43ql(q jsonb) returns text language sql immutable as $$
  select string_agg((l ->> 'description') || '=' || (l ->> 'amount_cents'), ' | ' order by o)
    from jsonb_array_elements(q -> 'lines') with ordinality x(l, o) where l ->> 'charge_type' in ('addon', 'baby_seat', 'winter_tire') $$;
create or replace function test.s43qp(q jsonb) returns text language sql immutable as $$
  select string_agg(p ->> 'code', ',' order by o) from jsonb_array_elements(q -> 'problems') with ordinality x(p, o) where p ->> 'code' like 'addon%' $$;

-- ================================================================ 1. the catalogue as seeded
select test.eq('seeded: nine add-ons, every one active with its price (the owner''s change: active, prices set)',
  (select count(*) || '/' || count(*) filter (where active and price_cents is not null) from addons), '9/9');
select test.eq('seeded: the owner''s prices, units, most per trip, minimum hours and stock',
  (select string_agg(code || ':' || pricing_unit || ':' || price_cents || ':' || coalesce(cap_cents::text, '-') || ':' || coalesce(min_hours::integer::text, '-')
                     || ':' || coalesce(stock_count::text, '-') || ':' || lead_time_hours, ' ' order by sort_order) from addons),
  'flowers:per_trip:15000:-:-:-:24 baby_seat:per_day:1500:7500:-:2:0 child_seat:per_day:1500:7500:-:2:0 booster_seat:per_day:1000:5000:-:2:0 '
  || 'chauffeur:per_hour:4500:-:3:-:24 umbrella:per_trip:500:-:-:4:0 phone_charger:per_trip:500:-:-:4:0 full_tank:per_trip:8500:-:-:-:0 winter_tire:per_day:1500:15000:-:-:0');
select test.ok('seeded: HST on for all, every car (no car list), the chauffeur waits for staff and is prepared by Fleet, flowers prepared',
  (select bool_and(hst_applies) and bool_and(cardinality(vehicle_ids) = 0 and cardinality(vehicle_classes) = 0) from addons)
  and (select needs_confirmation and needs_prep from addons where code = 'chauffeur') and (select needs_prep and not needs_confirmation from addons where code = 'flowers'));
select test.ok('seeded: the existing extras are the catalogue''s baby seat and winter tires (same fee codes), not a second copy',
  (select fee_type_code from addons where code = 'baby_seat') = 'baby_seat' and (select fee_type_code from addons where code = 'winter_tire') = 'winter_tire'
  and (select count(*) from addons where name ilike '%baby%') = 1);
select test.ok('seeded: prepaid fuel leaves out electric cars and is marked prepaid fuel',
  (select prepaid_fuel and excluded_fuel_types = '{electric}' from addons where code = 'full_tank'));
select test.eq('money: add-on revenue is CarmaCars'' own, on account 4150 Add-ons (the old extras too)',
  (select string_agg(code || ':' || revenue_class || ':' || gl_account, ' ' order by code) from fee_types where code in ('addon', 'baby_seat', 'winter_tire')),
  'addon:company_only:4150 baby_seat:company_only:4150 winter_tire:company_only:4150');
select test.eq('money: the Schedule of Fees follows the baby seat price from today', (select amount_cents || '/' || cap_cents from public.effective_fee('baby_seat', test.s43v('std'), app.today())), '1500/7500');

-- ================================================================ 2. pricing units
select test.eq('units: per trip, x2', app.addon_item_cents('per_trip', 500, 3, null, null, null, null) * 2, 1000::bigint);
select test.eq('units: per day, 3 days at $15', app.addon_item_cents('per_day', 1500, 3, null, null, 7500, null), 4500::bigint);
select test.eq('units: per day, 6 days at $15 is held at $75 a trip', app.addon_item_cents('per_day', 1500, 6, null, null, 7500, null), 7500::bigint);
select test.eq('units: per day with at most 4 days, a 10-day rental', app.addon_item_cents('per_day', 1000, 10, null, 4, null, null), 4000::bigint);
select test.eq('units: per hour under the minimum is the minimum (2 asked, 3 minimum)', app.addon_item_cents('per_hour', 4500, 1, 2, null, null, 3), 13500::bigint);
select test.eq('units: per hour, 4.5 hours', app.addon_item_cents('per_hour', 4500, 1, 4.5, null, null, 3), 20250::bigint);

select test.eq('quote: flowers, two baby seats and a 4-hour chauffeur for 3 days, as lines (with HST on each)',
  test.s43ql(test.s43q(test.s43v('std'), interval '5 days', interval '8 days',
    '[{"code": "flowers"}, {"code": "baby_seat", "quantity": 2}, {"code": "chauffeur", "hours": 4}]'::jsonb)),
  'Baby seat (rear-facing) x 2, 3 days=9000 | Flowers=15000 | Chauffeur, 4 hours (to be confirmed)=18000');
select test.eq('quote: the HST of the add-on lines (13%)',
  (select string_agg(l ->> 'hst_cents', ',' order by o) from jsonb_array_elements(test.s43q(test.s43v('std'), interval '5 days', interval '8 days',
     '[{"code": "flowers"}, {"code": "umbrella"}]'::jsonb) -> 'lines') with ordinality x(l, o) where l ->> 'charge_type' = 'addon'), '1950,65');
select test.eq('quote: a full tank is $85 on a standard car, $110 on an SUV (by class) and on a minivan (by body type)',
  test.s43ql(test.s43q(test.s43v('std'), interval '5 days', interval '8 days', '[{"code": "full_tank"}]'::jsonb)) || ' / '
  || test.s43ql(test.s43q(test.s43v('suv'), interval '5 days', interval '8 days', '[{"code": "full_tank"}]'::jsonb)) || ' / '
  || test.s43ql(test.s43q(test.s43v('van'), interval '5 days', interval '8 days', '[{"code": "full_tank"}]'::jsonb)),
  'Full tank of gas (prepaid)=8500 / Full tank of gas (prepaid)=11000 / Full tank of gas (prepaid)=11000');
select test.eq('quote: a full tank is not offered for an electric car (a problem the quote names, no line)',
  coalesce(test.s43ql(test.s43q(test.s43v('ev'), interval '5 days', interval '8 days', '[{"code": "full_tank"}]'::jsonb)), 'none') || '/'
  || test.s43qp(test.s43q(test.s43v('ev'), interval '5 days', interval '8 days', '[{"code": "full_tank"}]'::jsonb)), 'none/addon_not_for_car');
select test.ok('catalogue for a car: the electric car is offered no prepaid fuel; the SUV sees $110',
  not exists (select 1 from jsonb_array_elements(public.addons_for_car(test.s43v('ev'))) x where x ->> 'code' = 'full_tank')
  and (select (x ->> 'unit_price_cents')::bigint from jsonb_array_elements(public.addons_for_car(test.s43v('suv'))) x where x ->> 'code' = 'full_tank') = 11000);
select test.eq('quote: too many, and too few chauffeur hours, are problems',
  test.s43qp(test.s43q(test.s43v('std'), interval '5 days', interval '8 days', '[{"code": "baby_seat", "quantity": 3}, {"code": "chauffeur", "hours": 2}]'::jsonb)),
  'addon_too_many,addon_min_hours');
select test.eq('notice: flowers 10 hours before pickup are refused for a renter, accepted from staff',
  coalesce(test.s43qp(test.s43q(test.s43v('std'), interval '10 hours', interval '3 days', '[{"code": "flowers"}]'::jsonb)), 'none') || '/'
  || coalesce(test.s43qp(test.s43q(test.s43v('std'), interval '10 hours', interval '3 days', '[{"code": "flowers"}]'::jsonb, 'staff')), 'none'),
  'addon_notice/none');
select test.eq('notice: the public quote cannot ask for the staff channel',
  (select string_agg(p ->> 'code', ',') from jsonb_array_elements(app.quote_booking(test.s43v('std'), date_trunc('hour', now()) + interval '10 hours',
     date_trunc('hour', now()) + interval '3 days', '{"addons": [{"code": "flowers"}], "addon_channel": "staff"}') -> 'problems') p where p ->> 'code' like 'addon%'), 'addon_notice');
update addons set available_months = '{10, 11, 12, 1, 2, 3, 4}' where code = 'winter_tire';
select test.eq('months: winter tires are offered October to April only',
  (select coalesce(test.s43qp(app.price_quote(test.s43v('std'), app.local_midnight(make_date(extract(year from now())::integer + 1, 1, 10)) + interval '10 hours',
      app.local_midnight(make_date(extract(year from now())::integer + 1, 1, 13)) + interval '10 hours', '{"addons": [{"code": "winter_tire"}]}')), 'offered') || '/'
       || coalesce(test.s43qp(app.price_quote(test.s43v('std'), app.local_midnight(make_date(extract(year from now())::integer + 1, 7, 10)) + interval '10 hours',
      app.local_midnight(make_date(extract(year from now())::integer + 1, 7, 13)) + interval '10 hours', '{"addons": [{"code": "winter_tire"}]}')), 'offered')),
  'offered/addon_not_for_car');
select test.eq('old extras: {"baby_seats": 1} in a quote is the catalogue''s baby seat at its price',
  test.s43ql(app.price_quote(test.s43v('std'), date_trunc('hour', now()) + interval '5 days', date_trunc('hour', now()) + interval '8 days', '{"extras": {"baby_seats": 1}}')),
  'Baby seat (rear-facing), 3 days=4500');
update addons set active = false where code = 'umbrella';
select test.eq('inactive: an add-on turned off is not offered', test.s43qp(test.s43q(test.s43v('std'), interval '5 days', interval '8 days', '[{"code": "umbrella"}]'::jsonb)), 'addon_inactive');
update addons set active = true where code = 'umbrella';

-- ================================================================ 3. a rental added by hand with add-ons; stock across bookings
insert into s43 select 'm1', app.manual_rental_create(test.id('ao_admin'), test.s43r(test.s43v('std'), interval '30 days', interval '33 days',
  '{"addons": [{"code": "baby_seat", "quantity": 2}, {"code": "flowers"}, {"code": "full_tank"}]}'));
select test.eq('manual: the add-on lines are on the rental, priced and paid with it',
  test.s43lines((test.s43b('m1')).id), 'baby_seat=9000+1170 addon=15000+1950 addon=8500+1105');
select test.eq('manual: the total includes them: $300 rental + $325 add-ons + HST',
  (select subtotal_at_booking_cents || '/' || total_due_at_booking_cents || '/' || status from test.s43b('m1')), '62500/70625/confirmed');
select test.eq('manual: each add-on is on the booking with its price snapshot and its line',
  (select string_agg(a.code || ':' || ba.quantity || ':' || ba.unit_price_cents || ':' || ba.status || ':' || ba.added_via || ':' || (ba.line_item_id is not null), ' ' order by a.sort_order)
     from booking_addons ba join addons a on a.id = ba.addon_id where ba.booking_id = (test.s43b('m1')).id),
  'flowers:1:15000:confirmed:manual:true baby_seat:2:1500:confirmed:manual:true full_tank:1:8500:confirmed:manual:true');
select test.eq('manual: the old extras say the same (two baby seats)', (select request_details -> 'extras' ->> 'baby_seats' from test.s43b('m1')), '2');
select test.ok('Fleet task: flowers to get ready, due before pickup by its notice; none for the baby seats',
  (select count(*) = 1 from tasks t where t.booking_id = (test.s43b('m1')).id and t.task_type = 'addon_prep' and t.queue = 'fleet' and t.status = 'open'
      and t.title like 'Get ready: Flowers%' and t.due_at = (test.s43b('m1')).pickup_at - interval '24 hours'));
select test.eq('stock: both baby seats are out for those dates: none left for an overlapping rental',
  test.s43qp(test.s43q(test.s43v('std2'), interval '31 days', interval '32 days', '[{"code": "baby_seat"}]'::jsonb)), 'addon_no_stock');
select test.ok('stock: free again on dates that do not overlap',
  test.s43qp(test.s43q(test.s43v('std2'), interval '40 days', interval '42 days', '[{"code": "baby_seat", "quantity": 2}]'::jsonb)) is null);
select test.throws('stock: a rental over the same dates with a baby seat is refused',
  $$select app.manual_rental_create(test.id('ao_admin'), test.s43r(test.s43v('std2'), interval '31 days', interval '32 days', '{"addons": [{"code": "baby_seat"}]}', 'ao_ron'))$$,
  'none left for these dates');
select test.eq('stock: the catalogue counts what is left for dates (child seats untouched)',
  (select string_agg((x ->> 'code') || '=' || coalesce(x ->> 'available', '-'), ' ' order by x ->> 'code')
     from jsonb_array_elements(app.addons_for_car(test.s43v('std2'), date_trunc('hour', now()) + interval '31 days', date_trunc('hour', now()) + interval '32 days')) x
    where x ->> 'code' in ('baby_seat', 'child_seat', 'flowers')), 'baby_seat=0 child_seat=2 flowers=-');
update addons set stock_count = 3 where code = 'baby_seat';
select test.ok('stock: Fleet adds a seat, and one is free again',
  test.s43qp(test.s43q(test.s43v('std2'), interval '31 days', interval '32 days', '[{"code": "baby_seat"}]'::jsonb)) is null);
update addons set stock_count = 2 where code = 'baby_seat';

-- ================================================================ 4. money: commission base, Owner Revenue, the company statement
select test.eq('commission base: the rental charge after discounts only, never the add-ons ($300 of $625)',
  app.commission_base_cents((test.s43b('m1')).id) || '/' || app.sales_revenue_cents((test.s43b('m1')).id), '30000/30000');
-- a past rental on a program owner's car, with add-ons, against the same rental without
insert into s43 select 'p1', app.manual_rental_create(test.id('ao_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:ao_prog'),
  'pickup_at', app.local_midnight((app.month_start(app.today()) - interval '1 month')::date + 2) + interval '10 hours',
  'return_at', app.local_midnight((app.month_start(app.today()) - interval '1 month')::date + 5) + interval '10 hours',
  'source', 'phone', 'coverage_option', 1, 'past', true, 'renter_id', test.id('renter:ao_rita'),
  'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash'), 'addons', '[{"code": "flowers"}, {"code": "child_seat"}]'::jsonb));
select test.eq('Owner Revenue: the rental charge only; the add-ons ($150 flowers, $45 child seat) are CarmaCars'' own, not in the kickback base',
  (select (owner_revenue_cents = rental_charge_cents)::text || '/' || (kickback_base_cents <= rental_charge_cents)::text || '/' || company_only_cents
     from booking_splits where booking_id = (test.s43b('p1')).id), 'true/true/19500');
select app.build_company_statement((app.month_start(app.today()) - interval '1 month')::date, test.id('ao_admin'));
select test.ok('company statement: Add-ons is its own income line (account 4150), with these add-ons in it',
  (select (r ->> 'cents')::bigint >= 19500 from company_statements cs, jsonb_array_elements(cs.sections) s, jsonb_array_elements(s -> 'rows') r
    where cs.statement_month = (app.month_start(app.today()) - interval '1 month')::date and s ->> 'key' = 'income' and r ->> 'label' = 'Add-ons' and r ->> 'account' = '4150'));
select test.ok('company statement: the add-ons are not in Renter service fees',
  (select (cs_l.company_fees_by_type ->> 'addon')::bigint >= 15000 from company_statement_lines cs_l join company_statements cs on cs.id = cs_l.statement_id
    where cs.statement_month = (app.month_start(app.today()) - interval '1 month')::date and cs_l.level = 'vehicle' and cs_l.vehicle_id = test.id('vehicle:ao_prog')));

-- ================================================================ 5. the request: a chauffeur waits for staff, the offer confirms it
insert into s43 select 'r1', app.submit_booking_request(test.s43req('ao1', test.id('vehicle:BAY'), interval '20 days', interval '22 days', '[{"code": "chauffeur", "hours": 5}, {"code": "umbrella"}]'));
select test.eq('request: the add-ons asked for are on it; the chauffeur waits for confirmation and says so on its line',
  (select string_agg(a.code || ':' || ba.status || ':' || ba.added_via, ' ' order by a.sort_order) from booking_addons ba join addons a on a.id = ba.addon_id
    where ba.booking_id = (test.s43b('r1')).id) || ' | '
  || (select string_agg(description || '=' || amount_cents, ', ' order by amount_cents desc) from booking_line_items
       where booking_id = (test.s43b('r1')).id and charge_type = 'addon' and voided_at is null),
  'chauffeur:pending:request umbrella:confirmed:request | Chauffeur, 5 hours (to be confirmed)=22500, Umbrella=500');
select test.throws('request: flowers asked 10 hours before pickup are refused (24 hours'' notice)',
  $$select app.submit_booking_request(test.s43req('ao2', test.id('vehicle:BAY'), interval '10 hours', interval '2 days', '[{"code": "flowers"}]'))$$, 'notice');
-- staff in the offer: the chauffeur for 6 hours, the umbrella removed, a phone charger added
select app.admin_apply_booking_edit(test.id('ao_cs'), (test.s43b('r1')).id,
  '{"addons": [{"code": "chauffeur", "hours": 6}, {"code": "phone_charger"}]}');
select test.eq('offer: staff change the add-ons; the chauffeur kept by staff is confirmed; the umbrella is gone',
  (select string_agg(a.code || ':' || ba.status || ':' || coalesce(ba.hours::integer::text, '-'), ' ' order by a.sort_order) from booking_addons ba join addons a on a.id = ba.addon_id
    where ba.booking_id = (test.s43b('r1')).id and ba.status in ('pending', 'confirmed')) || ' | ' || test.s43lines((test.s43b('r1')).id),
  'chauffeur:confirmed:6 phone_charger:confirmed:- | addon=27000+3510 addon=500+65');
select test.ok('offer: the preview of the review screen shows the add-ons and rolls back',
  (select (v -> 'booking' -> 'addons') @> '[{"code": "booking_addons_test_never"}]' = false and jsonb_array_length(v -> 'booking' -> 'addons') = 3
     from app.admin_booking_preview(test.id('ao_admin'), (test.s43b('r1')).id, '{"addons": [{"code": "chauffeur", "hours": 6}, {"code": "phone_charger"}, {"code": "umbrella"}]}') v)
  and (select count(*) from booking_addons where booking_id = (test.s43b('r1')).id and status = 'confirmed') = 2);
select test.throws('offer: a renter may not change add-ons through staff''s function',
  format($$select app.booking_addons_set(%L, %L, '[]', 'offer')$$, (test.s43b('r1')).id, test.id('renter:ao_rita')), 'Only staff');
-- a request whose chauffeur is still waiting when the offer goes out: sending the offer confirms it
insert into s43 select 'r2', app.submit_booking_request(test.s43req('ao3', test.id('vehicle:BAY'), interval '50 days', interval '52 days', '[{"code": "chauffeur", "hours": 3}]'));
select app.send_offer((test.s43b('r2')).id, test.id('ao_cs'), null, now() + interval '24 hours');
select test.eq('offer sent: the chauffeur is confirmed with it', (select status from booking_addons where booking_id = (test.s43b('r2')).id), 'confirmed');

-- ================================================================ 6. after booking: the renter portal
insert into s43 select 'c1', app.manual_rental_create(test.id('ao_admin'), test.s43r(test.s43v('std3'), interval '10 days', interval '12 days', '{}', 'ao_ron'));
update bookings set card_on_file_id = test.id('card:ao_ron') where id = (test.s43b('c1')).id;
insert into payment_method_secrets (payment_method_id, processor_customer_id, processor_method_id)
values (test.id('card:ao_ron'), 'cus_ao_ron', 'pm_ao_ron') on conflict do nothing;
insert into s43 select 'buy1', app.booking_addon_buy((test.s43b('c1')).id, test.id('ao_ron'), '{"code": "umbrella"}');
select test.eq('portal: buying an umbrella returns what to charge on the card on file ($5 + HST)',
  (select (v ->> 'amount_cents') || '/' || (v -> 'card' ->> 'method_id') || '/' || (v ->> 'status') from test.s43('buy1') v), '565/pm_ao_ron/confirmed');
select test.eq('portal: nothing is on the booking until it is paid', coalesce(test.s43lines((test.s43b('c1')).id), 'none'), 'none');
select test.eq('portal: a payment of another amount is refused',
  app.booking_addon_paid((test.s43('buy1') ->> 'booking_addon_id')::uuid, test.id('ao_ron'), '{"processor": "stripe", "payment_id": "pi_ao_1"}', 500) ->> 'reason', 'amount_mismatch');
insert into s43 select 'paid1', app.booking_addon_paid((test.s43('buy1') ->> 'booking_addon_id')::uuid, test.id('ao_ron'), '{"processor": "stripe", "payment_id": "pi_ao_1"}', 565);
select test.eq('portal: paid, its own payment and line',
  (test.s43('paid1') ->> 'ok')
  || '/' || test.s43lines((test.s43b('c1')).id)
  || '/' || (select purpose || ':' || amount_cents from payments where booking_id = (test.s43b('c1')).id and purpose = 'addon'), 'true/addon=500+65/addon:565');
select test.eq('portal: paying twice is a replay', app.booking_addon_paid((test.s43('buy1') ->> 'booking_addon_id')::uuid, test.id('ao_ron'), '{"processor": "stripe", "payment_id": "pi_ao_1"}', 565) ->> 'already', 'true');
select test.ok('portal: the booking counts as paid in full, and what was paid includes the add-on',
  app.booking_paid_in_full((test.s43b('c1')).id) and app.booking_paid_cents((test.s43b('c1')).id) = (test.s43b('c1')).total_due_at_booking_cents + 565);
select test.throws('portal: the same add-on twice is refused', format($$select app.booking_addon_buy(%L, %L, '{"code": "umbrella"}')$$, (test.s43b('c1')).id, test.id('ao_ron')), 'already on this booking');
select test.throws('portal: someone else''s booking is refused', format($$select app.booking_addon_buy(%L, %L, '{"code": "booster_seat"}')$$, (test.s43b('c1')).id, test.id('ao_rita')), 'renter of the booking');
insert into s43 select 'buy2', app.booking_addon_buy((test.s43b('c1')).id, test.id('ao_ron'), '{"code": "booster_seat"}');
select app.booking_addon_failed((test.s43('buy2') ->> 'booking_addon_id')::uuid, test.id('ao_ron'), 'Your card was declined');
select test.eq('portal: a declined card leaves nothing on the booking', (select status || ':' || cancel_reason from booking_addons where id = (test.s43('buy2') ->> 'booking_addon_id')::uuid),
  'cancelled:Your card was declined');
insert into s43 select 'buy3', app.booking_addon_buy((test.s43b('c1')).id, test.id('ao_ron'), '{"code": "chauffeur", "hours": 4}');
select test.ok('portal: a chauffeur is asked for, not charged: customer service gets a task to confirm it',
  (test.s43('buy3') ->> 'status') = 'pending'
  and exists (select 1 from tasks where booking_id = (test.s43b('c1')).id and task_type = 'addon_confirm' and queue = 'cs' and status = 'open'));
select test.eq('staff confirm: returns the charge to take now', (select (v ->> 'charge_now') || '/' || (v ->> 'amount_cents')
  from app.booking_addon_confirm(test.id('ao_cs'), (test.s43('buy3') ->> 'booking_addon_id')::uuid, true) v), 'true/20340');
select app.booking_addon_paid((test.s43('buy3') ->> 'booking_addon_id')::uuid, test.id('ao_cs'), '{"processor": "stripe", "payment_id": "pi_ao_3"}', 20340);
select test.ok('staff confirm: the confirm task is done, the Fleet prep task raised once it is paid',
  not exists (select 1 from tasks where booking_id = (test.s43b('c1')).id and task_type = 'addon_confirm' and status = 'open')
  and exists (select 1 from tasks where booking_id = (test.s43b('c1')).id and task_type = 'addon_prep' and title like 'Get ready: Chauffeur (4 hours)%'));
update program_settings set addon_portal_cutoff_hours = 24 * 11;
select test.throws('portal: after the cutoff before pickup, add-ons are added by calling us',
  format($$select app.booking_addon_buy(%L, %L, '{"code": "child_seat"}')$$, (test.s43b('c1')).id, test.id('ao_ron')), 'could be added until');
update program_settings set addon_portal_cutoff_hours = 24;
-- no card on file: the add-on waits unpaid and Finance collects it
insert into s43 select 'c2', app.manual_rental_create(test.id('ao_admin'), test.s43r(test.s43v('suv'), interval '10 days', interval '12 days', '{}', 'ao_rita'));
insert into s43 select 'buy4', app.booking_addon_buy((test.s43b('c2')).id, test.id('ao_rita'), '{"code": "full_tank"}');
select test.eq('portal, no card: the price is $110 on the SUV; there is no card to charge', (select (v ->> 'amount_cents') || '/' || coalesce(v ->> 'card', 'none') from test.s43('buy4') v), '12430/none');
select app.booking_addon_paid((test.s43('buy4') ->> 'booking_addon_id')::uuid, test.id('ao_rita'), null, null);
select test.ok('portal, no card: the line is on the booking unpaid, Finance has a task to collect it',
  exists (select 1 from booking_line_items where booking_id = (test.s43b('c2')).id and charge_type = 'addon' and payment_id is null and voided_at is null)
  and exists (select 1 from tasks where booking_id = (test.s43b('c2')).id and task_type = 'addon_payment' and queue = 'finance' and status = 'open'));
select test.eq('renter''s view: the add-ons, whether they may add more, the card',
  (select jsonb_array_length(v -> 'items') || '/' || (v ->> 'can_add') || '/' || (v -> 'card' ->> 'last4') from app.my_booking_addons((test.s43b('c1')).id, test.id('ao_ron')) v), '2/true/4242');

-- ================================================================ 7. staff remove: unpaid voided, paid refunded; the commission unchanged
select test.throws('remove: a reason is needed', format($$select app.booking_addon_remove(%L, %L, '')$$, test.id('ao_cs'), (test.s43('buy4') ->> 'booking_addon_id')::uuid), 'reason');
select app.booking_addon_remove(test.id('ao_cs'), (test.s43('buy4') ->> 'booking_addon_id')::uuid, 'Renter changed their mind');
select test.ok('remove unpaid: the line is voided, the Finance task cancelled',
  not exists (select 1 from booking_line_items where booking_id = (test.s43b('c2')).id and charge_type = 'addon' and voided_at is null)
  and not exists (select 1 from tasks where booking_id = (test.s43b('c2')).id and task_type = 'addon_payment' and status = 'open'));
insert into s43 select 'rm1', app.booking_addon_remove(test.id('ao_cs'), (test.s43('buy1') ->> 'booking_addon_id')::uuid, 'Not needed');
select test.eq('remove paid: a refund of the add-on awaits approval, allocated to its line',
  (select r.reason || ':' || r.amount_cents || ':' || r.status || ':' || (select count(*) from refund_allocations x where x.refund_id = r.id)
     from refunds r where r.id = (test.s43('rm1') ->> 'refund_id')::uuid),
  'addon_removed:565:pending_approval:1');
update refunds set status = 'approved', approved_by = test.id('ao_admin') where booking_id = (test.s43b('c1')).id and reason = 'addon_removed';
select test.eq('remove paid: the commission base stays the rental charge', app.sales_revenue_cents((test.s43b('c1')).id), (test.s43b('c1')).rental_charge_cents);

-- ================================================================ 8. cancellations
-- flowers (non-refundable once their 24 hours'' notice has started) on a rental: with notice, refunded by the tier;
-- an add-on with a longer notice, kept
insert into s43 select 'x1', app.manual_rental_create(test.id('ao_admin'), test.s43r(test.s43v('std2'), interval '60 hours', interval '108 hours',
  '{"addons": [{"code": "flowers"}, {"code": "umbrella"}]}', 'ao_rita'));
select test.eq('cancel 60 hours before: the tier refunds the add-ons too (flowers'' notice not started)',
  (select (v ->> 'addons_kept_cents') || '/' || ((v ->> 'refund_cents')::bigint = public.calc_bps(app.booking_paid_cents((test.s43b('x1')).id), (v ->> 'refund_bps')::integer))
     from app.preview_cancellation((test.s43b('x1')).id, now(), 'renter_request') v), '0/true');
update addons set lead_time_hours = 72 where code = 'flowers';
select test.eq('cancel within the flowers'' notice: they are kept in full; the tier applies to the rest',
  (select (v ->> 'addons_kept_cents') || '/' || (v ->> 'refund_cents') || '/' || (v ->> 'retained_cents') || '/' || (v -> 'addons_kept' ->> 0)
     from app.preview_cancellation((test.s43b('x1')).id, now(), 'renter_request') v),
  (select '16950/' || public.calc_bps(app.booking_paid_cents((test.s43b('x1')).id) - 16950, (v ->> 'refund_bps')::integer) || '/'
     || (app.booking_paid_cents((test.s43b('x1')).id) - public.calc_bps(app.booking_paid_cents((test.s43b('x1')).id) - 16950, (v ->> 'refund_bps')::integer)) || '/Flowers'
     from app.preview_cancellation((test.s43b('x1')).id, now(), 'renter_request') v));
select test.eq('CarmaCars cancels: everything back, add-ons included',
  (select (v ->> 'addons_kept_cents') || '/' || ((v ->> 'refund_cents')::bigint = app.booking_paid_cents((test.s43b('x1')).id))
     from app.preview_cancellation((test.s43b('x1')).id, now(), 'carmacars_no_vehicle') v), '0/true');
select app.cancel_booking((test.s43b('x1')).id, test.id('ao_admin'), 'renter_request', 'Test', 'email', now());
select test.ok('cancelled: the flowers are kept, their line not in the refund; the prep task cancelled',
  (select kept_on_cancel from booking_addons ba join addons a on a.id = ba.addon_id where ba.booking_id = (test.s43b('x1')).id and a.code = 'flowers')
  and not exists (select 1 from refund_allocations x join refunds r on r.id = x.refund_id join booking_line_items li on li.id = x.line_item_id
                   join booking_addons ba on ba.id = li.booking_addon_id join addons a on a.id = ba.addon_id
                  where r.booking_id = (test.s43b('x1')).id and a.code = 'flowers')
  and exists (select 1 from refund_allocations x join refunds r on r.id = x.refund_id join booking_line_items li on li.id = x.line_item_id
                   join booking_addons ba on ba.id = li.booking_addon_id join addons a on a.id = ba.addon_id
               where r.booking_id = (test.s43b('x1')).id and a.code = 'umbrella')
  and not exists (select 1 from tasks where booking_id = (test.s43b('x1')).id and task_type = 'addon_prep' and status = 'open'));
select test.eq('cancelled: the refund is what the preview said', (select amount_cents from refunds where booking_id = (test.s43b('x1')).id and reason = 'cancellation'),
  (select refund_cents from booking_cancellations where booking_id = (test.s43b('x1')).id));
update addons set lead_time_hours = 24 where code = 'flowers';

-- ================================================================ 9. field staff and prepaid fuel
insert into s43 select 'h1', app.manual_rental_create(test.id('ao_admin'), test.s43r(test.s43v('std3'), interval '20 hours', interval '68 hours',
  '{"addons": [{"code": "baby_seat", "quantity": 2}, {"code": "flowers"}, {"code": "full_tank"}]}', 'ao_rita'));
insert into field_jobs (kind, vehicle_id, booking_id, scheduled_at, assigned_to, status, created_by)
values ('handover', test.s43v('std3'), (test.s43b('h1')).id, (test.s43b('h1')).pickup_at, test.id('ao_field'), 'scheduled', test.id('ao_admin'));
select test.eq('field: the handover lists the add-ons to put in the car, with their notes, and the prepaid fuel',
  (select string_agg((a ->> 'name') || ' x' || (a ->> 'quantity'), ', ' order by a ->> 'name') || ' / ' || (v #>> '{booking,prepaid_fuel}')
     from app.field_read(test.id('ao_field'), 'job', jsonb_build_object('id', (select id from field_jobs where booking_id = (test.s43b('h1')).id))) v,
          jsonb_array_elements(v #> '{booking,addons}') a group by v),
  'Baby seat (rear-facing) x2, Flowers x1, Full tank of gas (prepaid) x1 / true');
select test.ok('field: the prepaid fuel note tells them not to charge fuel',
  (select bool_or(a ->> 'handover_note' like '%Do not charge for fuel%')
     from app.field_read(test.id('ao_field'), 'job', jsonb_build_object('id', (select id from field_jobs where booking_id = (test.s43b('h1')).id))) v,
          jsonb_array_elements(v #> '{booking,addons}') a));
select test.ok('prepaid fuel: known on the booking, so check-in proposes no fuel charge', app.booking_has_prepaid_fuel((test.s43b('m1')).id)
  and not app.booking_has_prepaid_fuel((test.s43b('c1')).id));

-- ================================================================ 10. the doors
select test.eq('door: staff read the catalogue; Admin may edit, Fleet may set stock, customer service neither',
  (select (v ->> 'may_edit') || '/' || (v ->> 'may_stock') || '/' || jsonb_array_length(v -> 'addons') from app.door(test.id('ao_admin'), 'aal2', 'ops_read', 'addons', '{}') v) || ' '
  || (select (v ->> 'may_edit') || '/' || (v ->> 'may_stock') from app.door(test.id('ao_fleet'), 'aal2', 'ops_read', 'addons', '{}') v) || ' '
  || (select (v ->> 'may_edit') || '/' || (v ->> 'may_stock') from app.door(test.id('ao_cs'), 'aal2', 'ops_read', 'addons', '{}') v),
  'true/true/9 false/true false/false');
select test.eq('door: Fleet sets the stock', (app.door(test.id('ao_fleet'), 'aal2', 'ops_do', 'addon_save', jsonb_build_object('id', test.s43a('umbrella'), 'stock_count', 6)) ->> 'stock_count'), '6');
select test.throws('door: Fleet may not change a price', format($$select app.door(%L, 'aal2', 'ops_do', 'addon_save', jsonb_build_object('id', %L, 'price_cents', 1))$$,
  test.id('ao_fleet'), test.s43a('umbrella')), 'stock');
select test.throws('door: customer service may not change an add-on', format($$select app.door(%L, 'aal2', 'ops_do', 'addon_save', jsonb_build_object('id', %L, 'stock_count', 1))$$,
  test.id('ao_cs'), test.s43a('umbrella')), 'Admin');
select test.eq('door: an Admin edits an add-on (price, notice, cars left out)',
  (select (v ->> 'price_cents') || '/' || (v ->> 'lead_time_hours') || '/' || (v -> 'excluded_vehicle_ids' ->> 0 = test.s43v('van')::text)
     from app.door(test.id('ao_admin'), 'aal2', 'ops_do', 'addon_save', jsonb_build_object('id', test.s43a('umbrella'), 'price_cents', 700, 'lead_time_hours', 2,
            'excluded_vehicle_ids', jsonb_build_array(test.s43v('van')))) v), '700/2/true');
select test.ok('door: a car left out is not offered it', not exists (select 1 from jsonb_array_elements(public.addons_for_car(test.s43v('van'))) x where x ->> 'code' = 'umbrella'));
select test.eq('door: an Admin adds a new add-on (off until it has a price)',
  (select (v ->> 'active') || '/' || (v ->> 'pricing_unit') from app.door(test.id('ao_admin'), 'aal2', 'ops_do', 'addon_save', jsonb_build_object('name', 'Ski rack', 'pricing_unit', 'per_day')) v),
  'false/per_day');
select test.throws('door: turning one on needs a price',
  format($$select app.door(%L, 'aal2', 'ops_do', 'addon_save', jsonb_build_object('id', %L, 'active', true))$$, test.id('ao_admin'), (select id from addons where name = 'Ski rack')), 'price');
select test.ok('privileges: the public reads the catalogue for a car; the add-on functions are the server''s',
  has_function_privilege('anon', 'public.addons_for_car(uuid, timestamptz, timestamptz)', 'execute')
  and not has_function_privilege('anon', 'app.booking_addon_buy(uuid, uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_booking_addon_buy(uuid, uuid, jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.server_booking_addon_paid(uuid, uuid, jsonb, bigint)', 'execute'));
select test.ok('row-level security: on, with an Admin policy and an audit trigger, on both tables',
  (select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('addons', 'booking_addons'))
  and (select count(*) from pg_policies where tablename in ('addons', 'booking_addons') and policyname = 'admin_all') = 2
  and (select count(*) from pg_trigger where tgname in ('audit_addons', 'audit_booking_addons')) = 2);
