-- 3081 (release 48, part O): the owner's monthly occupancy forecast.
-- The owner (Nov 15): a GTA seasonal occupancy curve (12 monthly factors with sensible defaults, editable by Admin in
-- Settings); each car's forecast blends the curve with the car's own actual occupancy once it has 3 or more months of
-- history, its own actuals weighing more as months accrue; bookings hidden from the owner are left out of the actuals; the
-- owner statement says whether next month is projected higher or lower than this month, by how much, and why (the season);
-- the owner portal and the Admin view of an owner show the next 12 months per car: projected occupancy and owner revenue.
--   1. Program settings occupancy_season (jan .. dec: the factor of each month against an average month; the defaults
--      follow the GTA's rental year: a quiet January and February, March Break, a summer peak, holiday travel in December)
--      and occupancy_base_pct (an average month's occupancy for a car with no history of its own, 60 by default).
--      The curve of a month = occupancy_base_pct x its factor (at most 100%).
--   2. A car's actual occupancy of a month (app.car_month_occupancy_bps): the share of the month covered by its confirmed,
--      on-rent, returned or closed bookings that its owner sees (app.booking_visible_to_owner: a booking hidden from the owner,
--      an insurer replacement hidden from them or one never shown, is not counted), no test, placeholder or owner's-own trip.
--   3. The blend (app.car_occupancy_forecast): the history is the car's full months on the program before the month the
--      forecast starts (at most 24). Fewer than 3: the curve alone. From 3: the car's own level (each month's actual divided
--      by its factor, averaged) times the month's factor, weighted n / (n + 3) against the curve (3 months: half, 6: two
--      thirds, 12: four fifths, 24: eight ninths), so a car's own actuals weigh more as months accrue and the season stays.
--   4. Projected owner revenue = projected occupancy x the days of the month x the car's owner revenue a booked day: from
--      its own statements of the last 12 months (owner payout of the bookings the owner sees, over their days) once it has
--      some, else its daily rate less the Revenue Share of its terms (before fees; an estimate, never billed).
--   5. app.owner_occupancy_forecast(owner): the cars of an owner, 12 months each; ops_read owner_forecast {owner_id} for the
--      owner themself and an Admin. app.owner_statement_forecast(statement): the statement's line (next month against the
--      statement's month, the owner's cars together), in the owner portal's statement, the Admin's and the PDF.
-- SCHEMA_MARKER 3081. docs/changes/2026-11-15-r48o-cutouts-forecast.md.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the curve
create function app.occupancy_season_ok(p jsonb) returns boolean language sql immutable parallel safe as $$
  select jsonb_typeof(p) = 'object'
     and (select bool_and(coalesce(jsonb_typeof(p -> m) = 'number' and (p ->> m)::numeric between 0.1 and 2.5, false))
            from unnest(array['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec']) m)
$$;
alter table program_settings add column if not exists occupancy_season jsonb not null
  default '{"jan": 0.80, "feb": 0.80, "mar": 0.95, "apr": 0.90, "may": 1.00, "jun": 1.10, "jul": 1.25, "aug": 1.25, "sep": 1.00, "oct": 1.00, "nov": 0.90, "dec": 1.05}'::jsonb
  check (app.occupancy_season_ok(occupancy_season));
alter table program_settings add column if not exists occupancy_base_pct integer not null default 60 check (occupancy_base_pct between 5 and 100);
comment on column program_settings.occupancy_season is 'Owner forecast (3081): the GTA seasonal curve, the factor of each month (jan .. dec) against an average month (1.00); every car''s forecast starts from it.';
comment on column program_settings.occupancy_base_pct is 'Owner forecast (3081): the occupancy of an average month (percent) for a car with no history of its own; a month''s curve is this times its factor.';

create function app.occupancy_month_key(p_month date) returns text language sql immutable parallel safe as $$
  select (array['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'])[extract(month from p_month)::integer]
$$;
create function app.occupancy_factor(p_month date) returns numeric
language sql stable security definer set search_path = public, app as $$
  select coalesce(((app.settings()).occupancy_season ->> app.occupancy_month_key(p_month))::numeric, 1)
$$;
-- the curve of a month, in basis points
create function app.occupancy_curve_bps(p_month date) returns integer
language sql stable security definer set search_path = public, app as $$
  select least(10000, round(coalesce((app.settings()).occupancy_base_pct, 60) * 100 * app.occupancy_factor(p_month)))::integer
$$;
-- why a month is busier or quieter (the season), for the statement's line
create function app.occupancy_season_reason(p_month date) returns text language sql immutable parallel safe as $$
  select (array['after the holidays, the quietest stretch of winter', 'winter stays quiet', 'March Break travel', 'spring picks up slowly',
                'the Victoria Day long weekend and spring travel', 'summer travel starts', 'peak summer travel', 'peak summer travel',
                'back to school, so travel eases', 'Thanksgiving and fall drives', 'the quiet weeks before the holidays',
                'holiday travel and visiting family'])[extract(month from p_month)::integer]
$$;

-- ================================================================ 2. a car's actual occupancy of a month
create function app.car_month_occupancy_bps(p_vehicle uuid, p_month date) returns integer
language sql stable security definer set search_path = public, app as $$
  with m as (select (p_month::timestamp at time zone 'America/Toronto') as a, ((p_month + interval '1 month')::timestamp at time zone 'America/Toronto') as z)
  select least(10000, round(10000 * coalesce(sum(extract(epoch from (least(b.return_at, m.z) - greatest(b.pickup_at, m.a)))), 0) / extract(epoch from (m.z - m.a))))::integer
    from m left join bookings b on b.vehicle_id = p_vehicle and b.status in ('confirmed', 'on_rent', 'returned', 'closed')
     and b.pickup_at < m.z and b.return_at > m.a and not b.is_test and not b.is_placeholder and b.booking_type <> 'owner'
     and app.booking_visible_to_owner(b)
   group by m.a, m.z
$$;
comment on function app.car_month_occupancy_bps(uuid, date) is 'Owner forecast (3081): the share (basis points) of a month covered by the car''s confirmed, on-rent, returned or closed bookings its owner sees (hidden ones, tests, placeholders and the owner''s own trips left out).';

-- the month a car's program starts (its enrollment, else its first booking it counts, else when it was added)
create function app.car_program_start(p_vehicle uuid) returns date
language sql stable security definer set search_path = public, app as $$
  select coalesce(v.enrollment_date, (select app.local_date(min(b.pickup_at)) from bookings b where b.vehicle_id = v.id and not b.is_test), app.local_date(v.created_at))
    from vehicles v where v.id = p_vehicle
$$;

-- ================================================================ 3. and 4. the blend and the revenue
-- the owner revenue a booked day: the car's own statements of the 12 months before p_month, else its rate less the Revenue Share
create function app.car_owner_day_cents(p_vehicle uuid, p_month date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with own as (
    select sum(s.owner_payout_cents) as cents, sum(b.billable_days) as days
      from booking_splits s join bookings b on b.id = s.booking_id
     where s.vehicle_id = p_vehicle and s.status <> 'reversed' and s.payout_month >= (p_month - interval '12 months')::date and s.payout_month < p_month
       and not b.is_test and b.booking_type <> 'owner' and app.booking_visible_to_owner(b)),
  rate as (
    select r.daily_rate_cents * (10000 - coalesce((app.vehicle_terms(p_vehicle, p_month)).revenue_share_bps, 0)) / 10000 as cents
      from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
     order by r.effective_from desc limit 1)
  select case when coalesce((select days from own), 0) > 0 and coalesce((select cents from own), 0) > 0
              then jsonb_build_object('cents', round((select cents from own)::numeric / (select days from own))::bigint, 'from', 'statements')
              else jsonb_build_object('cents', coalesce((select cents from rate), 0)::bigint, 'from', 'rate') end
$$;

create function app.car_occupancy_forecast(p_vehicle uuid, p_from date default null, p_months integer default 12) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_from date := date_trunc('month', coalesce(p_from, (date_trunc('month', app.local_date(now())) + interval '1 month')::date))::date;
  v_start date := app.car_program_start(p_vehicle);
  v_first date; v_n integer := 0; v_level numeric := null; v_w numeric := 0; v_day jsonb; v_hist jsonb;
  v_out jsonb := '[]'::jsonb; m date; v_curve integer; v_own integer; v_bps integer;
begin
  if v_start is null then return null; end if;
  -- full months on the program before the forecast starts (the month after the start month, the newest 24)
  v_first := greatest((date_trunc('month', v_start) + interval '1 month')::date, (v_from - interval '24 months')::date);
  select count(*), avg(h.bps / (app.occupancy_factor(h.month) * 10000)),
         coalesce(jsonb_agg(jsonb_build_object('month', h.month, 'occupancy_bps', h.bps) order by h.month), '[]'::jsonb)
    into v_n, v_level, v_hist
    from (select g::date as month, app.car_month_occupancy_bps(p_vehicle, g::date) as bps
            from generate_series(v_first, (v_from - interval '1 month')::date, interval '1 month') g) h;
  if v_n >= 3 then v_w := v_n::numeric / (v_n + 3); end if;
  v_day := app.car_owner_day_cents(p_vehicle, v_from);
  for i in 0 .. greatest(least(coalesce(p_months, 12), 24), 1) - 1 loop
    m := (v_from + make_interval(months => i))::date;
    v_curve := app.occupancy_curve_bps(m);
    v_own := case when v_n >= 3 then least(10000, round(v_level * app.occupancy_factor(m) * 10000))::integer end;
    v_bps := case when v_n >= 3 then round((1 - v_w) * v_curve + v_w * v_own)::integer else v_curve end;
    v_out := v_out || jsonb_build_object('month', m, 'curve_bps', v_curve, 'own_bps', v_own, 'occupancy_bps', v_bps,
      'days', extract(day from (m + interval '1 month' - interval '1 day'))::integer,
      'revenue_cents', round(v_bps / 10000.0 * extract(day from (m + interval '1 month' - interval '1 day')) * (v_day ->> 'cents')::bigint)::bigint);
  end loop;
  return jsonb_build_object('vehicle_id', p_vehicle, 'name', app.vehicle_name(p_vehicle), 'from', v_from, 'history_months', v_n,
    'own_weight', round(v_w, 3), 'own_level_bps', case when v_n >= 3 then round(v_level * 10000)::integer end,
    'day_cents', (v_day ->> 'cents')::bigint, 'day_from', v_day ->> 'from', 'history', v_hist, 'months', v_out);
end $$;

-- ================================================================ 5. an owner's cars, the statement's line, the doors
create function app.owner_forecast_cars(p_owner uuid) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select v.id from vehicles v
   where v.owner_id = p_owner and not coalesce(v.is_sample, false) and v.retired_at is null
     and v.status::text not in ('declined', 'exited', 'total_loss', 'onboarding')
   order by v.created_at, v.id
$$;

create function app.owner_occupancy_forecast(p_owner uuid, p_from date default null, p_months integer default 12) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('owner_id', p_owner, 'base_pct', (app.settings()).occupancy_base_pct, 'season', (app.settings()).occupancy_season,
    'cars', coalesce((select jsonb_agg(app.car_occupancy_forecast(c, p_from, p_months)) from app.owner_forecast_cars(p_owner) c), '[]'::jsonb))
$$;

-- the statement's line: the month after the statement's month against the statement's month, the owner's cars together
create function app.owner_statement_forecast(p_statement uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s owner_statements; v_cars jsonb; v_this integer; v_next integer; v_tc bigint; v_nc bigint; v_d integer; v_dc bigint;
  m0 date; m1 date; v_dir text; v_text text; mon text; mon0 text;
begin
  select * into s from owner_statements where id = p_statement;
  if s.id is null then return null; end if;
  m0 := s.statement_month; m1 := (m0 + interval '1 month')::date;
  select coalesce(jsonb_agg(app.car_occupancy_forecast(c, m0, 2)), '[]'::jsonb) into v_cars from app.owner_forecast_cars(s.owner_id) c;
  if jsonb_array_length(v_cars) = 0 then return null; end if;
  select round(avg((x -> 'months' -> 0 ->> 'occupancy_bps')::integer)), round(avg((x -> 'months' -> 1 ->> 'occupancy_bps')::integer)),
         sum((x -> 'months' -> 0 ->> 'revenue_cents')::bigint), sum((x -> 'months' -> 1 ->> 'revenue_cents')::bigint)
    into v_this, v_next, v_tc, v_nc from jsonb_array_elements(v_cars) x;
  v_d := round((v_next - v_this) / 100.0); v_dc := v_nc - v_tc;
  v_dir := case when v_d > 0 then 'higher' when v_d < 0 then 'lower' else 'same' end;
  mon := trim(to_char(m1, 'FMMonth')); mon0 := trim(to_char(m0, 'FMMonth'));
  v_text := case v_dir
    when 'same' then format('Forecast: next month (%s) is projected about the same as %s, about %s%% occupancy.', mon, mon0, round(v_next / 100.0))
    else format('Forecast: next month (%s) is projected %s than %s: about %s%% occupancy against %s%% (%s %s point%s), about %s %s in owner revenue. Why: the season; %s is %s in the GTA (%s).',
      mon, v_dir, mon0, round(v_next / 100.0), round(v_this / 100.0), abs(v_d), case when v_d > 0 then 'more' else 'fewer' end, case when abs(v_d) = 1 then '' else 's' end,
      to_char(abs(v_dc) / 100.0, 'FM$999,999,990'), case when v_dc >= 0 then 'more' else 'less' end,
      mon, case when v_d > 0 then 'busier' else 'quieter' end, app.occupancy_season_reason(m1)) end;
  return jsonb_build_object('this_month', m0, 'next_month', m1, 'this_bps', v_this, 'next_bps', v_next, 'diff_points', v_d,
    'this_cents', v_tc, 'next_cents', v_nc, 'diff_cents', v_dc, 'direction', v_dir, 'reason', app.occupancy_season_reason(m1), 'text', v_text);
end $$;

alter function app.owner_portal_statement(uuid, uuid) rename to owner_portal_statement_pre3081;
create function app.owner_portal_statement(p_by uuid, p_statement uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x.r is null or jsonb_typeof(x.r) <> 'object' then x.r else x.r || jsonb_build_object('forecast', app.owner_statement_forecast(p_statement)) end
    from (select app.owner_portal_statement_pre3081(p_by, p_statement) as r) x
$$;
select pg_temp.copy_grants('app.owner_portal_statement(uuid, uuid)'::regprocedure, 'app.owner_portal_statement_pre3081(uuid, uuid)'::regprocedure);

alter function app.owner_statement_breakdown(uuid, uuid) rename to owner_statement_breakdown_pre3081;
create function app.owner_statement_breakdown(p_statement uuid, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when x.r is null or jsonb_typeof(x.r) <> 'object' then x.r else x.r || jsonb_build_object('forecast', app.owner_statement_forecast(p_statement)) end
    from (select app.owner_statement_breakdown_pre3081(p_statement, p_by) as r) x
$$;
select pg_temp.copy_grants('app.owner_statement_breakdown(uuid, uuid)'::regprocedure, 'app.owner_statement_breakdown_pre3081(uuid, uuid)'::regprocedure);

-- ops_read owner_forecast {owner_id}: the owner themself (their own cars) and an Admin
create function app.owner_forecast_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
begin
  if v_owner is null or not exists (select 1 from owners o where o.id = v_owner) then raise exception 'Unknown owner' using errcode = 'P0002'; end if;
  if not (app.user_is_admin(p_by) or app.user_is_owner_of(p_by, v_owner)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return app.owner_occupancy_forecast(v_owner, null, 12);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3081;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'owner_forecast' then
    perform app.door_begin(p_user, p_aal);
    return app.owner_forecast_read(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre3081(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3081(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['occupancy_season_ok', 'occupancy_month_key', 'occupancy_factor', 'occupancy_curve_bps', 'occupancy_season_reason',
       'car_month_occupancy_bps', 'car_program_start', 'car_owner_day_cents', 'car_occupancy_forecast', 'owner_forecast_cars', 'owner_occupancy_forecast',
       'owner_statement_forecast', 'owner_forecast_read', 'owner_portal_statement_pre3081', 'owner_statement_breakdown_pre3081', 'door_pre3081'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the check constraint calls occupancy_season_ok as whoever writes Program settings
grant execute on function app.occupancy_season_ok(jsonb) to authenticated;
