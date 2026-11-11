-- 1200_r35h_longer_never_cheaper.sql
-- Release 35, part H (docs/changes/2026-11-09-r35-offer-pricing-extensions-coverage.md), item 1.
-- The owner: "some of the pricing logic for sending back offers is broken ... lowering the price for increasing the time".
-- The offer (app.staff_offer_create and the review screen, both priced by app.price_lines) and the checkout quote
-- (app.price_quote) price the same car, dates, add-ons, coverage and discounts the same way; what made a longer stay cheaper
-- was the rate tiers themselves, applied to the whole stay:
--   * the 3+ day rate (multi_day_rate_cents, 0093): 2 days at a $100 daily rate are $200, 3 days at a $60 3+ day rate $180;
--   * a monthly rate set below the weekly rate (or below 6 days at the daily rate): 6 days $600, 7 days the monthly cap;
--   * the 30+ day proration of a monthly rate that is low against the shorter tiers.
-- The monotonic guard: public.calc_rental_charge (both forms) never charges N days less than any shorter stay from the same
-- pickup. Inside each tier the charge already grows with the days, so the guard compares N days with the 1 to 6 day prices
-- (the end of every tier that can be undercut) and keeps the highest: N+1 days cost at least what N days cost. Every
-- caller (offers, the checkout quote, Add a rental, booking changes, the rate form's examples, the partner sheet, the
-- calendar) follows. The rental line says when the guard set the price.
-- Promo codes with a minimum length (promo_codes.min_rental_days) are a deliberate step and are not guarded here.
-- No applied migration is edited: the two functions keep their names and arguments; the tier prices move to
-- public.calc_rental_charge_tiers.
set local check_function_bodies = off;

-- the tier price of a stay (0003 and 0093, unchanged): the 7-argument form
alter function public.calc_rental_charge(timestamptz, integer, bigint, bigint, bigint, bigint, text) rename to calc_rental_charge_tiers;

-- the tier price with the 3+ day tier (0093's body, calling the renamed tiers)
create function public.calc_rental_charge_tiers(p_pickup timestamptz, p_days integer, p_daily bigint, p_weekend bigint, p_weekly bigint,
                                                p_monthly bigint, p_tz text, p_multi bigint)
returns table (rate_applied text, daily_days integer, weekend_days integer, rental_charge_cents bigint)
language plpgsql immutable as $$
declare
  r record;
begin
  select * into r from public.calc_rental_charge_tiers(p_pickup, p_days, p_daily, p_weekend, p_weekly, p_monthly, coalesce(p_tz, 'America/Toronto'));
  if p_multi is not null and p_multi > 0 and p_days between 3 and 6 and r.rate_applied = 'daily' then
    return query select 'multi_day'::text, 0, 0, least(p_multi * p_days, r.rental_charge_cents);
    return;
  end if;
  return query select r.rate_applied, r.daily_days, r.weekend_days, r.rental_charge_cents;
end $$;

drop function public.calc_rental_charge(timestamptz, integer, bigint, bigint, bigint, bigint, text, bigint);

-- the guarded price: never less than a shorter stay from the same pickup
create function public.calc_rental_charge(p_pickup timestamptz, p_days integer, p_daily bigint, p_weekend bigint, p_weekly bigint,
                                          p_monthly bigint, p_tz text, p_multi bigint)
returns table (rate_applied text, daily_days integer, weekend_days integer, rental_charge_cents bigint)
language plpgsql immutable as $$
declare
  r record;
  v_floor bigint := 0;
  v_m bigint;
  m integer;
begin
  select * into r from public.calc_rental_charge_tiers(p_pickup, p_days, p_daily, p_weekend, p_weekly, p_monthly, p_tz, p_multi);
  -- within a tier the price grows with the days; only a shorter stay of 1 to 6 days can cost more than a longer one
  for m in 1 .. least(p_days - 1, 6) loop
    select x.rental_charge_cents into v_m from public.calc_rental_charge_tiers(p_pickup, m, p_daily, p_weekend, p_weekly, p_monthly, p_tz, p_multi) x;
    v_floor := greatest(v_floor, v_m);
  end loop;
  return query select r.rate_applied, r.daily_days, r.weekend_days, greatest(r.rental_charge_cents, v_floor);
end $$;
comment on function public.calc_rental_charge(timestamptz, integer, bigint, bigint, bigint, bigint, text, bigint) is
  'The rental charge of a stay by the rate tiers (calc_rental_charge_tiers), never less than a shorter stay from the same pickup (1200: a longer stay never costs less).';

create function public.calc_rental_charge(p_pickup timestamptz, p_days integer, p_daily bigint, p_weekend bigint, p_weekly bigint,
                                          p_monthly bigint, p_tz text default 'America/Toronto')
returns table (rate_applied text, daily_days integer, weekend_days integer, rental_charge_cents bigint)
language sql immutable as $$
  select * from public.calc_rental_charge(p_pickup, p_days, p_daily, p_weekend, p_weekly, p_monthly, coalesce(p_tz, 'America/Toronto'), null::bigint)
$$;

-- the grants of 0093 (every role reads a price)
do $$
declare f text;
begin
  foreach f in array array['public.calc_rental_charge(timestamptz, integer, bigint, bigint, bigint, bigint, text, bigint)',
                           'public.calc_rental_charge(timestamptz, integer, bigint, bigint, bigint, bigint, text)',
                           'public.calc_rental_charge_tiers(timestamptz, integer, bigint, bigint, bigint, bigint, text, bigint)',
                           'public.calc_rental_charge_tiers(timestamptz, integer, bigint, bigint, bigint, bigint, text)'] loop
    execute format('grant execute on function %s to anon, authenticated, service_role', f);
  end loop;
end $$;

-- the rental line says when the guard set the price (the rate sheet's words were the tier's)
alter function app.price_lines(jsonb) rename to price_lines_pre1200;
create function app.price_lines(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.price_lines_pre1200(p);
  v_raw bigint;
  v_days integer := (v ->> 'billable_days')::integer;
  i integer;
begin
  if coalesce(p ->> 'booking_type', 'standard') = 'owner' or v_days is null or v_days < 2 or (v ->> 'rate_sheet_rental_cents') is null then return v; end if;
  select x.rental_charge_cents into v_raw
    from public.calc_rental_charge_tiers((p ->> 'pickup_at')::timestamptz, v_days, coalesce((p ->> 'daily_rate_cents')::bigint, 0),
           coalesce((p ->> 'weekend_rate_cents')::bigint, 0), coalesce((p ->> 'weekly_rate_cents')::bigint, 0), coalesce((p ->> 'monthly_rate_cents')::bigint, 0),
           'America/Toronto', nullif(p ->> 'multi_day_rate_cents', '')::bigint) x;
  if v_raw >= (v ->> 'rate_sheet_rental_cents')::bigint then return v; end if;
  v := v || jsonb_build_object('rate_floor', true, 'rate_tier_cents', v_raw,
    'rate_rule', coalesce(v ->> 'rate_rule', '') || ', raised to the price of a shorter stay (a longer stay never costs less)');
  select x.ord - 1 into i from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)) with ordinality x(value, ord)
   where x.value ->> 'charge_type' = 'rental_charge' and coalesce(x.value #>> '{detail,rate_rule}', '') <> 'rental charge set for this booking' limit 1;
  if i is not null and (v ->> 'rental_charge_cents')::bigint = (v ->> 'rate_sheet_rental_cents')::bigint then
    v := jsonb_set(v, array['lines', i::text, 'detail'], coalesce(v #> array['lines', i::text, 'detail'], '{}'::jsonb)
           || jsonb_build_object('rate_rule', v ->> 'rate_rule', 'rate_floor', true, 'rate_tier_cents', v_raw));
  end if;
  return v;
end $$;
revoke all on function app.price_lines(jsonb) from public, anon, authenticated;
grant execute on function app.price_lines(jsonb) to service_role;
revoke all on function app.price_lines_pre1200(jsonb) from public, anon, authenticated;
grant execute on function app.price_lines_pre1200(jsonb) to service_role;
