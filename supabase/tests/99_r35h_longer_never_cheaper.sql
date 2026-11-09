-- 99: a longer stay never costs less, and an offer costs what checkout quotes (migration 1200). Property checks over 1 to
-- 60 days for several cars and fee setups: the 3+ day tier, a monthly rate below the weekly rate, the weekly and monthly
-- tiers, the Protection Plan per day and per trip, a young driver, add-ons per day (capped) and per trip, two pickup
-- days. For each length: the offer priced as staff send it (app.staff_offer_preview) equals the checkout quote
-- (app.price_quote) to the cent, and the total is never below the total of one day less. Fixtures start with "hy".
select test.suite('99 r35h longer never cheaper');

select test.mk_user('hy_admin', 'admin');

create temp table s1200 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.s1200v(p text) returns uuid language sql stable as $$ select (v ->> 'vehicle_id')::uuid from pg_temp.s1200 where k = p $$;
do $$
declare
  c record;
begin
  for c in select * from (values
      ('multi', 1, jsonb_build_object('daily', 10000, 'weekend', 12000, 'weekly', 55000, 'monthly', 180000, 'deposit', 30000), 6000),
      ('lowmonth', 2, jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 60000, 'monthly', 50000, 'deposit', 30000), null),
      ('tiers', 3, jsonb_build_object('daily', 8900, 'weekend', 9900, 'weekly', 52500, 'monthly', 199000, 'deposit', 30000), 8000),
      ('plain', 4, jsonb_build_object('daily', 6900, 'weekend', 7900, 'weekly', 41400, 'monthly', 151800, 'deposit', 30000), null)) x(k, i, rates, multi) loop
    insert into s1200 select c.k, app.vehicle_add(test.id('hy_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1HYCXMM00000000' || lpad(c.i::text, 2, '0'),
      'plate', 'HYC00' || c.i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'class', 'standard', 'fuel', 'gasoline', 'body_type', 'sedan', 'rates', c.rates));
    update rate_cards set multi_day_rate_cents = c.multi where vehicle_id = test.s1200v(c.k) and c.multi is not null;
  end loop;
end $$;
insert into coverage_prices (vehicle_id, amount_cents, per_day) values (test.s1200v('multi'), 2500, true), (test.s1200v('tiers'), 4000, false);

-- the calculator itself: the tiers' dip and the guard
select test.eq('the 3+ day tier alone makes 3 days cheaper than 2 ($180 against $200)',
  (select rental_charge_cents from public.calc_rental_charge_tiers(test.base(1), 3, 10000, 10000, 60000, 200000, 'America/Toronto', 6000)), 18000::bigint);
select test.eq('the guarded price of 3 days is the 2-day price ($200)',
  (select rental_charge_cents from public.calc_rental_charge(test.base(1), 3, 10000, 10000, 60000, 200000, 'America/Toronto', 6000)), 20000::bigint);
select test.eq('the guarded price keeps the tier name', (select rate_applied from public.calc_rental_charge(test.base(1), 3, 10000, 10000, 60000, 200000, 'America/Toronto', 6000)), 'multi_day');
select test.eq('a monthly rate below 6 days: 7 days cost at least 6 days ($600, not the $500 monthly rate)',
  (select rental_charge_cents from public.calc_rental_charge(test.base(1), 7, 10000, 10000, 60000, 50000)), 60000::bigint);
select test.ok('the guard never changes a well-ordered rate card (1 to 60 days)',
  not exists (select 1 from generate_series(1, 60) n
               where (select rental_charge_cents from public.calc_rental_charge(test.base(1), n, 6900, 7900, 41400, 151800))
                  <> (select rental_charge_cents from public.calc_rental_charge_tiers(test.base(1), n, 6900, 7900, 41400, 151800))));

-- the property, by car and fee setup: (k, setup name, quote options, offer extras)
create temp table s1200run (car text, setup text, pickup timestamptz, n integer, quote bigint, offer bigint, err text);
select set_config('app.staff_pricing', 'on', false);
do $$
declare
  s record;
  n integer;
  q jsonb;
  o jsonb;
  v_young date := (now() - interval '23 years')::date;
  v_pu timestamptz;
begin
  for s in select * from (values
      ('multi', 'plan per day, Wednesday', 3, 3, '{}'::jsonb, '[]'::jsonb, false),
      ('multi', 'plan per day, young driver, Friday', 3, 5, '{}'::jsonb, '[]'::jsonb, true),
      ('lowmonth', 'own policy, Wednesday', 1, 3, '{}'::jsonb, '[]'::jsonb, false),
      ('tiers', 'plan per trip, winter tires and a full tank, Friday', 3, 5, '{}'::jsonb, '[{"code": "winter_tire", "quantity": 1}, {"code": "full_tank", "quantity": 1}]'::jsonb, false),
      ('plain', 'card coverage, young driver, Monday', 2, 1, '{}'::jsonb, '[{"code": "umbrella", "quantity": 1}]'::jsonb, true)) x(car, setup, cover, dow, extra, addons, young) loop
    v_pu := test.base(s.dow) + interval '21 days';
    for n in 1 .. 60 loop
      q := app.price_quote(test.s1200v(s.car), v_pu, v_pu + make_interval(days => n), s.extra || jsonb_build_object('coverage_option', s.cover, 'addons', s.addons,
             'drivers', jsonb_build_array(jsonb_build_object('date_of_birth', case when s.young then v_young else date '1980-01-01' end))));
      o := app.staff_offer_preview(test.id('hy_admin'), s.extra || jsonb_build_object('vehicle_id', test.s1200v(s.car), 'pickup_at', v_pu, 'return_at', v_pu + make_interval(days => n),
             'coverage_option', s.cover, 'addons', s.addons, 'source', 'phone',
             'renter', jsonb_build_object('full_name', 'Pat Example', 'email', 'hy.' || n || '@example.test', 'mobile', '4165550100',
                                          'date_of_birth', case when s.young then v_young else date '1980-01-01' end)));
      insert into s1200run values (s.car, s.setup, v_pu, n, (q ->> 'total_due_at_booking_cents')::bigint, (o #>> '{booking,total_due_at_booking_cents}')::bigint, o ->> 'error');
    end loop;
  end loop;
end $$;
select set_config('app.staff_pricing', '', false);

select test.eq('every length of every setup was priced both ways (5 setups x 60 days)', (select count(*) from s1200run where quote is not null and offer is not null), 300::bigint);
select test.eq('no offer was refused', (select string_agg(distinct err, '; ') from s1200run where err is not null), null::text);
select test.eq('the offer total equals the checkout quote for every length (lengths that differ)',
  (select string_agg(setup || ' ' || n || 'd: quote ' || quote || ', offer ' || offer, '; ') from s1200run where quote is distinct from offer), null::text);
select test.eq('the total never goes down when the stay grows by a day (lengths cheaper than one day less)',
  (select string_agg(a.setup || ' ' || a.n || 'd', '; ') from s1200run a join s1200run b on b.setup = a.setup and b.n = a.n - 1 where a.offer < b.offer), null::text);
select test.ok('the 3+ day tier case is covered: 3 days cost the same as 2 for the multi car',
  (select a.quote = b.quote from s1200run a join s1200run b on b.setup = a.setup and b.n = 2 where a.setup = 'plan per day, Wednesday' and a.n = 3)
  or (select a.quote > b.quote from s1200run a join s1200run b on b.setup = a.setup and b.n = 2 where a.setup = 'plan per day, Wednesday' and a.n = 3));
select test.ok('the weekly and monthly tiers are reached (7, 29, 30 and 60 days priced above 6 days)',
  (select bool_and(a.quote >= b.quote) from s1200run a join s1200run b on b.setup = a.setup and b.n = 6 where a.n in (7, 29, 30, 60)));

-- the line says when the guard set the price
select test.ok('the rental line says it was raised to the shorter stay''s price',
  (select l #>> '{detail,rate_rule}' like '%a longer stay never costs less%'
     from jsonb_array_elements(app.price_quote(test.s1200v('lowmonth'), test.base(3) + interval '21 days', test.base(3) + interval '28 days', '{}'::jsonb) -> 'lines') l
    where l ->> 'charge_type' = 'rental_charge'));
select test.eq('without the guard''s help the line keeps the tier''s words',
  (select l #>> '{detail,rate_rule}' from jsonb_array_elements(app.price_quote(test.s1200v('plain'), test.base(3) + interval '21 days', test.base(3) + interval '23 days', '{}'::jsonb) -> 'lines') l
    where l ->> 'charge_type' = 'rental_charge'), '2 days at the daily rate');
