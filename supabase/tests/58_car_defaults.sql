-- 58: standard settings for every car that is entered (migration 0087). The fleet number (the real cars' own range,
-- never twice, samples untouched, never public), the complete rate card from the class defaults when no rates are
-- typed (the derived rates, kilometres, extra kilometre rate, deposit, delivery and pickup), a rate card typed in the
-- same step replacing it and keeping the defaulted fees, young drivers by class (every class by default), add-ons,
-- winter tires and the Protection Plan following the car, the setting that turns the rate card off, and the backfill
-- of the cars on file (only what is empty; young drivers on unless a person switched them off). Fixtures start "cd".
select test.suite('58 car defaults');

select test.mk_user('cd_admin', 'admin');
select test.mk_user('cd_fleet', 'va', 'fleet');
select test.mk_owner('cd_olive');

create temp table s58 (k text primary key, r jsonb);
grant all on s58 to public;
create function test.s58(p_k text) returns jsonb language sql stable as $$ select r from s58 where k = p_k $$;
create function test.s58v(p_k text) returns uuid language sql stable as $$ select (r ->> 'vehicle_id')::uuid from s58 where k = p_k $$;
create function test.s58rc(p_k text) returns rate_cards language sql stable as $$
  select * from rate_cards r where r.vehicle_id = test.s58v(p_k) and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now()) $$;

-- ================================================================ 1. a company car with no rates typed
insert into s58 select 'plain', app.vehicle_add(test.id('cd_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1CD58AA0000000001', 'plate', 'CDP001',
  'year', 2022, 'make', 'Toyota', 'model', 'Corolla', 'class', 'economy'));
select test.ok('fleet number: given at once, in the real cars'' range (Program settings)',
  (select v.fleet_number from vehicles v where v.id = test.s58v('plain'))
    ~ ('^' || (select fleet_number_prefix from program_settings order by effective_from desc limit 1) || '[0-9]+$')
  and (select regexp_replace(v.fleet_number, '\D', '', 'g')::integer from vehicles v where v.id = test.s58v('plain'))
      >= (select fleet_number_first from program_settings order by effective_from desc limit 1));
select test.eq('fleet number: marked as set automatically', (select auto_defaults ? 'fleet_number' from vehicles where id = test.s58v('plain')), true);
select test.eq('rate card: daily from the suggestion, weekend, weekly and monthly by the rate form''s rule',
  (select format('%s %s %s %s', (rc).weekend_rate_cents = (rc).daily_rate_cents, (rc).weekly_rate_cents = 6 * (rc).daily_rate_cents,
                 (rc).monthly_rate_cents = 22 * (rc).daily_rate_cents, (rc).daily_rate_cents = (app.listing_default_daily(test.s58v('plain')) ->> 'daily_cents')::bigint)
     from (select test.s58rc('plain') rc) x), 't t t t');
select test.eq('rate card: kilometres, extra km, deposit by class, delivery and pickup at the class delivery default',
  (select format('%s %s %s %s %s', (rc).km_allowance_per_day = (select default_km_allowance_per_day from program_settings order by effective_from desc limit 1),
                 (rc).overage_cents_per_km = (select amount_cents from app.class_fee_default('mileage_overage', 'economy')),
                 (rc).deposit_cents = (select amount_cents from app.class_fee_default('deposit', 'economy')),
                 (rc).delivery_fee_cents = (select coalesce(amount_cents, min_cents) from app.class_fee_default('delivery', 'economy')),
                 (rc).pickup_fee_cents = (rc).delivery_fee_cents)
     from (select test.s58rc('plain') rc) x), 't t t t t');
select test.ok('rate card: delivery within its Fee defaults range', (select (test.s58rc('plain')).delivery_fee_cents between min_cents and max_cents from app.class_fee_default('delivery', 'economy')));
select test.eq('rate card: every value marked as set automatically',
  (select string_agg(k, ',' order by k) from jsonb_object_keys((test.s58rc('plain')).auto_defaults) k), 'daily,delivery,deposit,km_per_day,monthly,overage,pickup,weekend,weekly');
select test.eq('young drivers: allowed (every class by default)', (select allows_18_to_20 from vehicles where id = test.s58v('plain')), true);
select test.ok('the add path says what was set', test.s58('plain') -> 'after_add' -> 'defaults' -> 'rate_card' ? 'daily');

-- ================================================================ 2. the next car: the next number; never public
insert into s58 select 'second', app.vehicle_add(test.id('cd_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1CD58AB0000000001', 'plate', 'CDP002',
  'year', 2021, 'make', 'Honda', 'model', 'Civic', 'class', 'standard'));
select test.ok('fleet number: the next car gets a higher number',
  (select regexp_replace(fleet_number, '\D', '', 'g')::bigint from vehicles where id = test.s58v('second'))
  > (select regexp_replace(fleet_number, '\D', '', 'g')::bigint from vehicles where id = test.s58v('plain')));
select test.ok('fleet number: never on the public listing row', not coalesce(app.public_listing_row(test.s58v('plain')) ? 'fleet_number', false));
select test.ok('fleet number: a number a person gave is kept, and the sequence skips it',
  (select app.next_fleet_number() is distinct from (select fleet_number from vehicles where id = test.s58v('second'))));

-- ================================================================ 3. rates typed in the same step
insert into s58 select 'typed', app.vehicle_add(test.id('cd_admin'), jsonb_build_object('supply_type', 'program_owner', 'owner_id', test.id('owner:cd_olive'),
  'vin', '1CD58AC0000000001', 'plate', 'CDT001', 'year', 2023, 'make', 'Mazda', 'model', 'CX-5', 'title_status', 'owned_outright', 'management_mode', 'managed',
  'rates', jsonb_build_object('daily', 8000, 'deposit', 75000)));
select test.eq('typed: one rate card, the person''s daily rate and deposit kept',
  (select format('%s %s %s', count(*), max(daily_rate_cents), max(deposit_cents)) from rate_cards where vehicle_id = test.s58v('typed')), '1 8000 75000');
select test.eq('typed: delivery and pickup from the class default, not $0',
  (select (test.s58rc('typed')).delivery_fee_cents = coalesce(d.amount_cents, d.min_cents) and (test.s58rc('typed')).pickup_fee_cents = coalesce(d.amount_cents, d.min_cents)
     from app.class_fee_default('delivery', (select class::text from vehicles where id = test.s58v('typed'))) d), true);
select test.eq('typed: what the person typed is not marked; what was defaulted is',
  (select format('%s %s %s', (test.s58rc('typed')).auto_defaults ? 'daily', (test.s58rc('typed')).auto_defaults ? 'deposit', (test.s58rc('typed')).auto_defaults ? 'delivery')), 'f f t');
insert into s58 select 'staff', app.staff_add_owner_car(test.id('cd_fleet'), jsonb_build_object('owner_id', test.id('owner:cd_olive'),
  'vehicle', jsonb_build_object('vin', '1CD58AD0000000001', 'plate', 'CDS001', 'year', 2020, 'make', 'Kia', 'model', 'Soul', 'title_status', 'owned_outright', 'management_mode', 'managed'),
  'rates', jsonb_build_object('daily', 5500)));
select test.eq('staff add for an owner: the typed card replaces the one from the defaults (one card) and keeps the defaulted delivery',
  (select format('%s %s %s', count(*), max(daily_rate_cents), bool_and(delivery_fee_cents > 0)) from rate_cards where vehicle_id = test.s58v('staff')), '1 5500 t');
select test.eq('staff add for an owner: delivery stays marked', (test.s58rc('staff')).auto_defaults ? 'delivery', true);

-- ================================================================ 4. what follows the car: add-ons, winter tires, fuel, the Protection Plan
insert into s58 select 'ev', app.vehicle_add(test.id('cd_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1CD58AE0000000001', 'plate', 'CDE001',
  'year', 2023, 'make', 'Tesla', 'model', 'Model 3', 'class', 'premium', 'fuel', 'electric'));
select test.eq('electric: the fuel kept', (select fuel::text from vehicles where id = test.s58v('ev')), 'electric');
select test.ok('add-ons: every active add-on of its kind, but no prepaid fuel for an electric car',
  not exists (select 1 from jsonb_array_elements(to_jsonb(public.addons_for_car(test.s58v('ev')))) x where x ->> 'code' = 'full_tank')
  and exists (select 1 from jsonb_array_elements(to_jsonb(public.addons_for_car(test.s58v('plain')))) x where x ->> 'code' = 'full_tank'));
select test.ok('winter tires: offered for a January rental',
  exists (select 1 from jsonb_array_elements(to_jsonb(public.addons_for_car(test.s58v('ev'), (date_trunc('year', now()) + interval '1 year 9 days 10 hours'),
                                                                             (date_trunc('year', now()) + interval '1 year 12 days 10 hours')))) x where x ->> 'code' = 'winter_tire'));
select test.ok('Protection Plan: a price through the car''s class', (app.coverage_term(test.s58v('ev'), '26_plus', app.today()) ->> 'amount_cents') is not null);

-- ================================================================ 5. the settings
update program_settings set young_driver_classes = array['economy', 'standard'];
insert into s58 select 'lux', app.vehicle_add(test.id('cd_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1CD58AF0000000001', 'plate', 'CDL001',
  'year', 2023, 'make', 'BMW', 'model', 'X5', 'class', 'luxury'));
select test.eq('young drivers: a class taken out of the setting is not allowed', (select allows_18_to_20 from vehicles where id = test.s58v('lux')), false);
update program_settings set young_driver_classes = array['economy', 'standard', 'premium', 'suv', 'luxury', 'exotic'];
update program_settings set car_defaults_rates_on_add = false;
insert into s58 select 'off', app.vehicle_add(test.id('cd_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1CD58AG0000000001', 'plate', 'CDN001',
  'year', 2022, 'make', 'Nissan', 'model', 'Sentra', 'class', 'economy'));
select test.eq('setting off: no rate card from the defaults', (select count(*) from rate_cards where vehicle_id = test.s58v('off')), 0::bigint);
select test.ok('setting off: still a fleet number', (select fleet_number is not null from vehicles where id = test.s58v('off')));
update program_settings set car_defaults_rates_on_add = true;

-- ================================================================ 6. the cars on file (the backfill)
-- a car as it was on file before 0087 (no audit row of a person's change: the triggers are off for this one update)
set session_replication_role = replica;
update vehicles set fleet_number = null, allows_18_to_20 = false where id = test.s58v('off');
set session_replication_role = origin;
select app.apply_car_defaults(test.s58v('off'), null, '{}'::jsonb, true);
select test.eq('backfill: the empty fleet number, a rate card, young drivers on where nobody switched them off',
  (select format('%s %s %s', v.fleet_number is not null, exists (select 1 from rate_cards r where r.vehicle_id = v.id), v.allows_18_to_20) from vehicles v where v.id = test.s58v('off')),
  't t t');
update vehicles set allows_18_to_20 = false where id = test.s58v('second');
update rate_cards set deposit_cents = 123400 where vehicle_id = test.s58v('second');
select app.apply_car_defaults(test.s58v('second'), null, '{}'::jsonb, true);
select test.eq('backfill: a person''s choices are kept (young drivers switched off, a deposit set)',
  (select format('%s %s', v.allows_18_to_20, (select max(deposit_cents) from rate_cards r where r.vehicle_id = v.id)) from vehicles v where v.id = test.s58v('second')), 'f 123400');

-- ================================================================ 7. sample cars and privileges
select test.ok('a sample car keeps its own number (none given)', not exists (select 1 from vehicles where is_sample and vin like 'SAMPLE%' and auto_defaults ? 'fleet_number'));
select test.throws('the defaults are the server''s: not callable by a signed-in person',
  format($$set local role authenticated; select app.apply_car_defaults(%L)$$, test.s58v('plain')), 'permission denied');
