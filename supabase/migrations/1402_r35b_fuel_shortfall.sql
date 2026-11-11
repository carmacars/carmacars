-- 1402_r35b_fuel_shortfall.sql
-- Release 35 part B, task 3 (docs/changes/2026-11-11-r35-card-pick-opcf-fuel-delivery.md). The owner, November 11, 2026:
-- "Fuel shortfall charged automatically at check-out: tank size x missing fraction (pickup fuel % minus return fuel %) x
-- local pump price x 1.25, plus a $20 refuelling fee. Local pump price per fuel type (regular, premium, diesel) updated
-- weekly; EVs: charge shortfall x battery kWh x $0.40/kWh + fee. The charge is prepared on the deposit review / final
-- statement as a suggested line (staff confirm), never auto-charged to a card."
--
-- 1. Program settings: fuel_price_regular_cents, fuel_price_premium_cents, fuel_price_diesel_cents (cents a litre: 155,
--    185, 170), fuel_prices_updated_on, fuel_price_multiplier (1.25), refuel_fee_cents (2000), ev_charge_kwh_cents (40),
--    fuel_tank_default_litres (65) and ev_battery_default_kwh (75) for a car without its own.
-- 2. The car: vehicles.fuel_tank_litres, battery_kwh and fuel_grade (regular, premium, diesel; empty: diesel for a diesel
--    car, premium for the premium, luxury and exotic classes, else regular), editable on the car (Admin and Fleet).
-- 3. app.fuel_shortfall(booking): the litres (or kWh) missing, the price, the amount and the fee, with how each was found.
-- 4. The return lines (app.assess_check_in, written at the check-in as before, 0130): the fuel line is the formula (a pump
--    receipt Finance enters still wins), the recharging line the kWh formula for an electric car, the refuelling fee the
--    setting. These are lines on the return settlement and the deposit review: Fleet and Finance confirm them there
--    (app.drr_sign, 1010) and Finance bills from the booking's Money; nothing here charges a card.
-- 5. The deposit review's fuel item shows the suggestion with its working (app.drr_facts).
-- 6. Admin > Today: a nudge when the pump prices were not updated for 7 days.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '1402: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists fuel_price_regular_cents numeric(7, 1) not null default 155 check (fuel_price_regular_cents >= 0),
  add column if not exists fuel_price_premium_cents numeric(7, 1) not null default 185 check (fuel_price_premium_cents >= 0),
  add column if not exists fuel_price_diesel_cents numeric(7, 1) not null default 170 check (fuel_price_diesel_cents >= 0),
  add column if not exists fuel_prices_updated_on date not null default app.today(),
  add column if not exists fuel_price_multiplier numeric(4, 2) not null default 1.25 check (fuel_price_multiplier between 1 and 5),
  add column if not exists refuel_fee_cents bigint not null default 2000 check (refuel_fee_cents >= 0),
  add column if not exists ev_charge_kwh_cents numeric(7, 1) not null default 40 check (ev_charge_kwh_cents >= 0),
  add column if not exists fuel_tank_default_litres numeric(5, 1) not null default 65 check (fuel_tank_default_litres > 0),
  add column if not exists ev_battery_default_kwh numeric(5, 1) not null default 75 check (ev_battery_default_kwh > 0);
comment on column program_settings.fuel_price_regular_cents is 'Local pump price of regular gas, cents a litre (155 is $1.55); update weekly (1402)';
comment on column program_settings.fuel_price_premium_cents is 'Local pump price of premium gas, cents a litre (1402)';
comment on column program_settings.fuel_price_diesel_cents is 'Local pump price of diesel, cents a litre (1402)';
comment on column program_settings.fuel_prices_updated_on is 'The day the pump prices were last updated; Admin > Today asks after 7 days (1402)';
comment on column program_settings.fuel_price_multiplier is 'The fuel shortfall is charged at the pump price times this (1.25) (1402)';
comment on column program_settings.refuel_fee_cents is 'The refuelling or recharging fee added to any fuel or charge shortfall (2000 is $20) (1402)';
comment on column program_settings.ev_charge_kwh_cents is 'An electric car''s charge shortfall is charged at this a kWh, cents (40 is $0.40) (1402)';
comment on column program_settings.fuel_tank_default_litres is 'The tank size used for a car without its own (1402)';
comment on column program_settings.ev_battery_default_kwh is 'The battery size used for an electric car without its own (1402)';

-- a price change is dated (unless the date was given)
-- (Settings saves a new dated row, an insert copying the row in force; a migration may update it)
create or replace function app.fuel_prices_dated() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  o program_settings;
begin
  if tg_op = 'UPDATE' then o := old; else select * into o from program_settings x where x.id = (app.settings()).id; end if;
  if o.id is not null and (new.fuel_price_regular_cents, new.fuel_price_premium_cents, new.fuel_price_diesel_cents)
       is distinct from (o.fuel_price_regular_cents, o.fuel_price_premium_cents, o.fuel_price_diesel_cents)
     and new.fuel_prices_updated_on is not distinct from o.fuel_prices_updated_on then
    new.fuel_prices_updated_on := app.today();
  end if;
  return new;
end $$;
drop trigger if exists program_settings_fuel_dated on program_settings;
create trigger program_settings_fuel_dated before insert or update on program_settings for each row execute function app.fuel_prices_dated();

-- ================================================================ 2. the car
alter table vehicles
  add column if not exists fuel_tank_litres numeric(5, 1) check (fuel_tank_litres is null or fuel_tank_litres between 10 and 300),
  add column if not exists battery_kwh numeric(5, 1) check (battery_kwh is null or battery_kwh between 5 and 300),
  add column if not exists fuel_grade text check (fuel_grade is null or fuel_grade in ('regular', 'premium', 'diesel'));
comment on column vehicles.fuel_tank_litres is 'The fuel tank, litres (from the specs, or entered on the car); empty: Program settings fuel_tank_default_litres (1402)';
comment on column vehicles.battery_kwh is 'An electric car''s usable battery, kWh; empty: Program settings ev_battery_default_kwh (1402)';
comment on column vehicles.fuel_grade is 'regular, premium or diesel; empty: diesel for a diesel car, premium for the premium, luxury and exotic classes, else regular (1402)';

create or replace function app.vehicle_fuel_grade(v vehicles) returns text
language sql stable as $$
  select coalesce(v.fuel_grade, case when v.fuel = 'diesel' then 'diesel' when v.class in ('premium', 'luxury', 'exotic') then 'premium' else 'regular' end)
$$;

-- ================================================================ 3. the shortfall
create or replace function app.fuel_shortfall(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  s program_settings := app.settings();
  v_short numeric;
  v_ev boolean;
  v_size numeric;
  v_grade text;
  v_price numeric;
  v_units numeric;
  v_energy bigint;
  v_fee bigint;
  v_prepaid boolean;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  select * into v from vehicles where id = b.vehicle_id;
  v_ev := v.fuel = 'electric';
  v_short := case when b.fuel_out_pct is null or b.fuel_in_pct is null then null else greatest(b.fuel_out_pct - b.fuel_in_pct, 0) end;
  v_prepaid := app.booking_has_prepaid_fuel(p_booking);
  if v_ev then
    v_size := coalesce(v.battery_kwh, s.ev_battery_default_kwh);
    v_price := s.ev_charge_kwh_cents;
  else
    v_size := coalesce(v.fuel_tank_litres, s.fuel_tank_default_litres);
    v_grade := app.vehicle_fuel_grade(v);
    v_price := case v_grade when 'premium' then s.fuel_price_premium_cents when 'diesel' then s.fuel_price_diesel_cents else s.fuel_price_regular_cents end;
  end if;
  v_units := round(v_size * coalesce(v_short, 0) / 100.0, 1);
  v_energy := case when coalesce(v_short, 0) = 0 or v_prepaid then 0
                   when v_ev then round(v_size * v_short / 100.0 * v_price)::bigint
                   else round(v_size * v_short / 100.0 * v_price * s.fuel_price_multiplier)::bigint end;
  v_fee := case when v_energy > 0 then s.refuel_fee_cents else 0 end;
  return jsonb_build_object(
    'kind', case when v_ev then 'charge' else 'fuel' end, 'out_pct', b.fuel_out_pct, 'in_pct', b.fuel_in_pct, 'short_pct', v_short,
    'size', v_size, 'size_source', case when (v_ev and v.battery_kwh is not null) or (not v_ev and v.fuel_tank_litres is not null) then 'car' else 'default' end,
    'unit', case when v_ev then 'kWh' else 'L' end, 'units', v_units, 'grade', v_grade,
    'price_cents', v_price, 'multiplier', case when v_ev then 1 else s.fuel_price_multiplier end, 'prices_updated_on', s.fuel_prices_updated_on,
    'energy_cents', v_energy, 'fee_cents', v_fee, 'total_cents', v_energy + v_fee, 'prepaid', v_prepaid,
    'working', case when v_short is null then 'No pickup or return fuel reading yet.'
                    when v_prepaid then 'Prepaid fuel: no fuel charge.'
                    when v_short = 0 then 'Returned at or above the pickup level: no charge.'
                    when v_ev then format('%s kWh battery x %s%% short = %s kWh x %s = %s, plus the %s recharging fee',
                                          v_size, v_short, v_units, app.money_text(round(v_price)::bigint) || '/kWh', app.money_text(v_energy), app.money_text(v_fee))
                    else format('%s L tank x %s%% short = %s L x %s (%s) x %s = %s, plus the %s refuelling fee',
                                v_size, v_short, v_units, '$' || to_char(v_price / 100.0, 'FM990.00') || '/L', v_grade, s.fuel_price_multiplier, app.money_text(v_energy), app.money_text(v_fee)) end);
end $$;
revoke all on function app.fuel_shortfall(uuid) from public, anon, authenticated;
grant execute on function app.fuel_shortfall(uuid) to service_role;

-- ================================================================ 4. the return lines
select pg_temp.patch_fn('app.assess_check_in(uuid, jsonb, uuid)'::regprocedure,
  $o$  v_short integer; v_units integer; v_pump bigint;$o$,
  $n$  v_short integer; v_units integer; v_pump bigint;
  v_fs jsonb; v_fuel_amt bigint := 0; v_ev_amt bigint := 0; v_fee_amt bigint := 0;$n$);

select pg_temp.patch_fn('app.assess_check_in(uuid, jsonb, uuid)'::regprocedure,
  $o$    v_short := greatest(coalesce(b.fuel_out_pct, 0) - coalesce(b.fuel_in_pct, b.fuel_out_pct, 0), 0);
    v_pump := (f ->> 'pump_cost_cents')::bigint;
    v_units := 0;
    if coalesce((f ->> 'no_fuel_charge')::boolean, false) or v_short = 0 or app.booking_has_prepaid_fuel(p_booking) then
      v_pump := 0;
    elsif v.fuel = 'electric' or f ? 'recharge_units' then
      v_units := coalesce((f ->> 'recharge_units')::integer, ceil(v_short / 10.0)::integer);   -- priced per 10% of battery
      v_pump := 0;
    elsif v_pump is null and (app.settings()).statement_fuel_cents_per_eighth is not null then
      v_pump := greatest(1, round(v_short / 12.5))::integer * (app.settings()).statement_fuel_cents_per_eighth;
    elsif v_pump is null then
      v_pending := v_pending || format('fuel: %s%% short, enter the pump cost from the receipt', v_short);
    end if;
    select * into t from app.booking_fee_term(p_booking, 'fuel');
    if coalesce(v_pump, 0) > 0 and t.percent_bps is null then
      raise exception 'The fuel markup is not set in the fee defaults' using errcode = '23514';
    end if;
    perform app.set_assessed_line(p_booking, 'fuel', 'fuel', 1,
        (select x.fuel_cents from public.calc_fuel_charge(coalesce(v_pump, 0), t.percent_bps, 0) x),
        case when coalesce(v_pump, 0) > 0 then (select x.fuel_cents from public.calc_fuel_charge(v_pump, t.percent_bps, 0) x) else 0 end,
        format('Fuel: %s%% at pickup, %s%% at return; pump cost plus the markup', b.fuel_out_pct, b.fuel_in_pct),
        v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct, 'pump_cost_cents', v_pump,
                                     'receipt_document_id', f ->> 'fuel_receipt_document_id'),
        p_by, null, (f ->> 'fuel_receipt_document_id')::uuid);
    select * into t from app.booking_fee_term(p_booking, 'recharging');
    perform app.set_assessed_line(p_booking, 'recharging', 'recharging', v_units, t.amount_cents, v_units * coalesce(t.amount_cents, 0),
        format('Recharging: %s%% at pickup, %s%% at return', b.fuel_out_pct, b.fuel_in_pct),
        v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct), p_by);
    select * into t from app.booking_fee_term(p_booking, 'fuel_service_fee');
    perform app.set_assessed_line(p_booking, 'fuel_service_fee', 'fuel_service_fee', 1, t.amount_cents,
        case when coalesce(v_pump, 0) > 0 or v_units > 0 then coalesce(t.amount_cents, 0) else 0 end,
        null, v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct), p_by);$o$,
  $n$    -- 1402: tank (or battery) x the missing fraction x the local pump price (x the multiplier for fuel), plus the
    -- refuelling fee; a pump receipt Finance enters still prices the fuel (plus the markup). A suggestion on the return
    -- settlement and the deposit review: staff confirm it there, nothing is charged to a card here.
    v_short := greatest(coalesce(b.fuel_out_pct, 0) - coalesce(b.fuel_in_pct, b.fuel_out_pct, 0), 0);
    v_pump := (f ->> 'pump_cost_cents')::bigint;
    v_fs := app.fuel_shortfall(p_booking);
    if coalesce((f ->> 'no_fuel_charge')::boolean, false) or v_short = 0 or app.booking_has_prepaid_fuel(p_booking) then
      v_pump := null;
    elsif v.fuel = 'electric' then
      v_ev_amt := coalesce((v_fs ->> 'energy_cents')::bigint, 0);
      v_pump := null;
    elsif v_pump is not null then
      select * into t from app.booking_fee_term(p_booking, 'fuel');
      v_fuel_amt := (select x.fuel_cents from public.calc_fuel_charge(v_pump, coalesce(t.percent_bps, 0), 0) x);
    else
      v_fuel_amt := coalesce((v_fs ->> 'energy_cents')::bigint, 0);
    end if;
    if v_fuel_amt > 0 or v_ev_amt > 0 then v_fee_amt := (app.settings()).refuel_fee_cents; end if;
    perform app.set_assessed_line(p_booking, 'fuel', 'fuel', 1, v_fuel_amt, v_fuel_amt,
        case when v_pump is not null then format('Fuel: %s%% at pickup, %s%% at return; pump cost plus the markup', b.fuel_out_pct, b.fuel_in_pct)
             else format('Fuel: %s%% at pickup, %s%% at return; %s', b.fuel_out_pct, b.fuel_in_pct, v_fs ->> 'working') end,
        v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct, 'pump_cost_cents', v_pump, 'shortfall', v_fs,
                                     'receipt_document_id', f ->> 'fuel_receipt_document_id'),
        p_by, null, (f ->> 'fuel_receipt_document_id')::uuid);
    perform app.set_assessed_line(p_booking, 'recharging', 'recharging', 1, v_ev_amt, v_ev_amt,
        format('Recharging: %s%% at pickup, %s%% at return; %s', b.fuel_out_pct, b.fuel_in_pct, v_fs ->> 'working'),
        v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct, 'shortfall', v_fs), p_by);
    perform app.set_assessed_line(p_booking, 'fuel_service_fee', 'fuel_service_fee', 1, v_fee_amt, v_fee_amt,
        case when v_fee_amt > 0 then 'Refuelling fee' end, v_refs || jsonb_build_object('fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct), p_by);$n$);

-- ================================================================ 5. the deposit review's fuel item
alter function app.drr_facts(uuid) rename to drr_facts_pre1402;
create function app.drr_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.drr_facts_pre1402(p_booking);
  fs jsonb;
begin
  if x is null or not (x ? 'fuel') then return x; end if;
  fs := app.fuel_shortfall(p_booking);
  return jsonb_set(x, '{fuel}', (x -> 'fuel') || jsonb_build_object('shortfall', fs, 'suggested_cents', coalesce((fs ->> 'total_cents')::bigint, 0),
    'suggest', case when coalesce((fs ->> 'total_cents')::bigint, 0) > 0 then 'issue' else x #>> '{fuel,suggest}' end));
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.drr_facts(uuid) from public';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    execute format('revoke all on function app.drr_facts(uuid) from %I', g);
    if has_function_privilege(g, 'app.drr_facts_pre1402(uuid)', 'execute') then execute format('grant execute on function app.drr_facts(uuid) to %I', g); end if;
  end loop;
end $$;

-- ================================================================ 6. the car's tank, battery and grade (Admin and Fleet), with the value of 1400
create or replace function app.vehicle_value_fuel(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  s program_settings := app.settings();
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('vehicle_id', v.id, 'black_book_value_cents', v.black_book_value_cents, 'black_book_checked_on', v.black_book_checked_on,
    'estimated_value_cents', v.estimated_value_cents, 'value', app.vehicle_value(v.id), 'coverage_types', to_jsonb(app.vehicle_coverage_types(v.id)),
    'fuel', v.fuel, 'fuel_tank_litres', v.fuel_tank_litres, 'battery_kwh', v.battery_kwh, 'fuel_grade', v.fuel_grade,
    'grade_used', app.vehicle_fuel_grade(v), 'tank_default_litres', s.fuel_tank_default_litres, 'battery_default_kwh', s.ev_battery_default_kwh);
end $$;

create or replace function app.vehicle_value_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_new jsonb;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet')) then raise exception 'Only an Admin or fleet sets a car''s value and fuel' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if nullif(p ->> 'fuel_grade', '') is not null and p ->> 'fuel_grade' not in ('regular', 'premium', 'diesel') then
    raise exception 'The fuel grade is regular, premium or diesel' using errcode = '22023';
  end if;
  update vehicles set
    black_book_value_cents = case when p ? 'black_book_value_cents' then nullif(p ->> 'black_book_value_cents', '')::bigint else black_book_value_cents end,
    black_book_checked_on = case when p ? 'black_book_checked_on' and nullif(p ->> 'black_book_checked_on', '') is not null then (p ->> 'black_book_checked_on')::date
                                 when p ? 'black_book_value_cents' and nullif(p ->> 'black_book_value_cents', '')::bigint is distinct from v.black_book_value_cents then app.today()
                                 else black_book_checked_on end,
    estimated_value_cents = case when p ? 'estimated_value_cents' then nullif(p ->> 'estimated_value_cents', '')::bigint else estimated_value_cents end,
    fuel_tank_litres = case when p ? 'fuel_tank_litres' then nullif(p ->> 'fuel_tank_litres', '')::numeric else fuel_tank_litres end,
    battery_kwh = case when p ? 'battery_kwh' then nullif(p ->> 'battery_kwh', '')::numeric else battery_kwh end,
    fuel_grade = case when p ? 'fuel_grade' then nullif(p ->> 'fuel_grade', '') else fuel_grade end
   where id = v.id;
  v_new := app.vehicle_value_fuel(p_by, p);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'vehicle_value_set', 'vehicles', v.id::text,
          jsonb_build_object('black_book_value_cents', v.black_book_value_cents, 'estimated_value_cents', v.estimated_value_cents,
                             'fuel_tank_litres', v.fuel_tank_litres, 'battery_kwh', v.battery_kwh, 'fuel_grade', v.fuel_grade), v_new);
  return v_new;
end $$;

-- ================================================================ 7. Admin > Today: the pump prices are a week old
alter function app.site_setup_problems() rename to site_setup_problems_pre1402;
create function app.site_setup_problems() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.site_setup_problems_pre1402(), '[]'::jsonb) || case when (app.settings()).fuel_prices_updated_on < app.today() - 7
    then jsonb_build_array(jsonb_build_object('field', 'fuel_prices', 'blocks', null, 'href', '/admin/settings/program',
           'message', format('Update the local pump prices (Settings > Program > Fuel): last updated %s. The fuel shortfall at each return is priced from them',
                             app.fmt_day((app.settings()).fuel_prices_updated_on))))
    else '[]'::jsonb end
$$;
do $$
declare g text;
begin
  execute 'revoke all on function app.site_setup_problems() from public';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    execute format('revoke all on function app.site_setup_problems() from %I', g);
    if has_function_privilege(g, 'app.site_setup_problems_pre1402()', 'execute') then execute format('grant execute on function app.site_setup_problems() to %I', g); end if;
  end loop;
end $$;
