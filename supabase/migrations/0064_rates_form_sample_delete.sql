-- 0064_rates_form_sample_delete.sql
-- The owner's bug reports of October 19, 2026 (docs/changes/2026-10-19-rates-form-fix.md):
--   A. Posting a car broke at the price. The rates and the kilometre terms were two forms: the first rate card refused
--      the rates without the kilometres a day ("A first rate card needs the kilometres per day ..."), and the kilometres
--      form sent the car's current rates, which a car without a rate card does not have, so it was refused for rates of
--      zero. Now one step: app.rate_card_check() validates the rates and the kilometre terms together, field by field,
--      fills the kilometres a day (Program settings: default_km_allowance_per_day) and the overage per km (Fee
--      defaults: mileage_overage by class) when they are not given, prices examples with public.calc_rental_charge()
--      (the function every booking is priced with) and suggests rates from similar cars. app.set_rate_card() and
--      app.vehicle_add() use it, for every supply type. Door names: rate_card_form, rate_card_check (reads),
--      rate_card_save (admin_do, and va_do for Fleet).
--   B. Sample cars could not be deleted "because of bookings" that were only requests: a booking that never confirmed
--      and never took money (requested, offered, declined, expired or cancelled before confirmation, with no payment,
--      deposit, refund, split, statement or signed agreement) no longer blocks a delete. It is archived in
--      deleted_booking_requests and removed with the car; the renter stays. Requests whose pickup time passed without
--      an offer expire (the offers-expire job), with a note in the booking history and no email unless
--      stale_request_email_renter is on.
--   C. Add a rental for a car whose listing is not finished (section 8b): staff rent and take payment for a new car at
--      once; the car stays off the public site; no rates means a price typed with its reason; a car not yet on the
--      fleet insurance policy needs an Admin who confirms it is insured.
-- No applied migration is edited.

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists default_km_allowance_per_day integer not null default 200 check (default_km_allowance_per_day between 1 and 5000),
  add column if not exists stale_request_expire boolean not null default true,
  add column if not exists stale_request_email_renter boolean not null default false;
comment on column program_settings.default_km_allowance_per_day is 'Kilometres included a day on a new rate card when staff keep "Use the defaults" (0064). The overage per km comes from Fee defaults (mileage_overage, by class).';
comment on column program_settings.stale_request_expire is 'A booking request whose pickup time passed without an offer expires (0064).';
comment on column program_settings.stale_request_email_renter is 'Email the renter when their request expires because its pickup time passed (0064). Off: a note in the booking history only.';

alter table rate_cards add column if not exists km_uses_defaults boolean not null default false;
comment on column rate_cards.km_uses_defaults is 'The kilometres a day and the overage per km were the defaults when this card was saved (0064).';

-- ================================================================ 2. the defaults and the rate suggestion
-- A fee default by class, for a car or for a class (a car not added yet): the car's own override first, then the
-- class row, then the general row. For the overage of a class with a range but no amount (luxury, exotic) the
-- lowest amount of the range.
create or replace function app.class_fee_default(p_fee text, p_class text, p_vehicle uuid default null)
returns table (amount_cents bigint, min_cents bigint, max_cents bigint)
language plpgsql stable security definer set search_path = public, app as $$
declare
  o vehicle_fee_overrides;
  c fee_defaults;
  g fee_defaults;
begin
  if p_vehicle is not null then
    select * into o from vehicle_fee_overrides x where x.vehicle_id = p_vehicle and x.fee_type_code = p_fee
       and x.effective_from <= app.today() and (x.effective_to is null or x.effective_to > app.today()) order by x.effective_from desc limit 1;
  end if;
  select * into c from fee_defaults d where d.fee_type_code = p_fee and d.vehicle_class::text = p_class
     and d.effective_from <= app.today() and (d.effective_to is null or d.effective_to > app.today()) order by d.effective_from desc limit 1;
  select * into g from fee_defaults d where d.fee_type_code = p_fee and d.vehicle_class is null
     and d.effective_from <= app.today() and (d.effective_to is null or d.effective_to > app.today()) order by d.effective_from desc limit 1;
  return query select coalesce(o.amount_cents, c.amount_cents, c.min_cents, g.amount_cents), coalesce(c.min_cents, g.min_cents), coalesce(c.max_cents, g.max_cents);
end $$;

-- What the rate form starts from. p: class, make, model (for a car not added yet).
create or replace function app.rate_card_defaults(p_vehicle uuid, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  v_class text;
  v_make text;
  v_model text;
  s program_settings := app.settings();
  ov record;
  dep record;
  sug jsonb;
  v_basis text;
  v_n integer;
begin
  if p_vehicle is not null then select * into v from vehicles where id = p_vehicle; end if;
  v_class := coalesce(v.class::text, nullif(p ->> 'class', ''), 'standard');
  v_make := lower(btrim(coalesce(v.make, p ->> 'make', '')));
  v_model := lower(btrim(coalesce(v.model, p ->> 'model', '')));
  select * into ov from app.class_fee_default('mileage_overage', v_class, p_vehicle);
  select * into dep from app.class_fee_default('deposit', v_class, p_vehicle);
  -- similar cars: the same make and model, else the same class (real cars only, rates in force)
  for v_basis in select unnest(array['model', 'class']) loop
    with cur as (
      select r.* from rate_cards r join vehicles x on x.id = r.vehicle_id
       where r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
         and not coalesce(x.is_sample, false) and x.retired_at is null and x.id is distinct from p_vehicle
         and case when v_basis = 'model' then v_make <> '' and lower(x.make) = v_make and lower(x.model) = v_model else x.class::text = v_class end)
    select count(*)::integer,
           jsonb_build_object(
             'daily_cents', (round(percentile_cont(0.5) within group (order by daily_rate_cents) / 100) * 100)::bigint,
             'weekend_cents', (round(percentile_cont(0.5) within group (order by weekend_rate_cents) / 100) * 100)::bigint,
             'weekly_cents', (round(percentile_cont(0.5) within group (order by weekly_rate_cents) / 100) * 100)::bigint,
             'monthly_cents', (round(percentile_cont(0.5) within group (order by monthly_rate_cents) / 100) * 100)::bigint)
      into v_n, sug from cur;
    if v_n > 0 then
      sug := sug || jsonb_build_object('cars', v_n, 'basis', v_basis,
        'text', format('Similar cars (%s %s, %s on file): daily %s, weekend %s, weekly %s, monthly %s.',
          case when v_basis = 'model' then 'same model:' else 'class' end,
          case when v_basis = 'model' then initcap(v_make) || ' ' || initcap(v_model) else v_class end, v_n,
          app.rc_money((sug ->> 'daily_cents')::bigint), app.rc_money((sug ->> 'weekend_cents')::bigint),
          app.rc_money((sug ->> 'weekly_cents')::bigint), app.rc_money((sug ->> 'monthly_cents')::bigint)));
      exit;
    end if;
    sug := null;
  end loop;
  return jsonb_build_object(
    'class', v_class,
    'km_per_day', s.default_km_allowance_per_day,
    'overage_cents', ov.amount_cents, 'overage_min_cents', ov.min_cents, 'overage_max_cents', ov.max_cents,
    'deposit_cents', dep.amount_cents,
    'km_choices', coalesce((select jsonb_agg(k.km_per_day order by k.sort_order, k.km_per_day desc) from km_allowance_choices k where k.is_active), '[]'::jsonb),
    'deposit_tiers', coalesce((select jsonb_agg(jsonb_build_object('amount_cents', t.amount_cents, 'label', t.label) order by t.sort_order, t.amount_cents)
                                 from deposit_tiers t where t.is_active), '[]'::jsonb),
    'suggestion', sug,
    'text', format('Defaults: %s km a day included, then %s a km.', s.default_km_allowance_per_day, app.rc_money(ov.amount_cents, true)));
end $$;

-- Money as the forms show it: $89, $89.50; a per-km amount as $0.35.
create or replace function app.rc_money(p_cents bigint, p_cents_always boolean default false) returns text
language sql immutable as $$
  select case when p_cents is null then 'not set'
              when p_cents % 100 = 0 and not p_cents_always then '$' || to_char(p_cents / 100, 'FM999,999,990')
              else '$' || to_char(p_cents / 100.0, 'FM999,999,990.00') end
$$;

-- ================================================================ 3. one check for the rates and the kilometre terms
-- p (all amounts in cents; empty or null where not typed):
--   daily, weekend, weekly, monthly          the four rates. Daily is needed; an empty weekend rate is the daily rate,
--                                            an empty weekly rate 6 days at the daily rate, an empty monthly rate 22.
--   km_mode                                  'default' (Program settings and Fee defaults) or 'custom'
--   km_per_day, overage                      for 'custom' (empty: the default)
--   deposit, delivery, pickup                empty: the current card's, or the class default (delivery and pickup 0)
--   class, make, model                       for a car not added yet
-- Returns errors by field (empty: it can be saved), the values that would be saved, warnings, the defaults and
-- examples priced with public.calc_rental_charge().
create or replace function app.rate_card_check(p_vehicle uuid, p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  dflt jsonb := app.rate_card_defaults(p_vehicle, p_);
  cur rate_cards;
  err jsonb := '{}'::jsonb;
  warn text[] := '{}';
  derived text[] := '{}';
  k text;
  raw text;
  amt jsonb := '{}'::jsonb;
  v_daily bigint; v_we bigint; v_wk bigint; v_m bigint;
  v_mode text := coalesce(nullif(p_ ->> 'km_mode', ''), 'default');
  v_km integer; v_over bigint; v_dep bigint; v_del bigint; v_pick bigint;
  v_omin bigint := (dflt ->> 'overage_min_cents')::bigint;
  v_omax bigint := (dflt ->> 'overage_max_cents')::bigint;
  ex jsonb := '[]'::jsonb;
  v_fri timestamptz;
  v_mon timestamptz;
  e record;
  c record;
  names constant jsonb := '{"daily": "Daily rate", "weekend": "Weekend rate", "weekly": "Weekly rate", "monthly": "Monthly rate",
                            "km_per_day": "Kilometres included a day", "overage": "Extra kilometre rate", "deposit": "Deposit",
                            "delivery": "Delivery fee", "pickup": "Pickup fee"}';
begin
  if p_vehicle is not null then
    select * into cur from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  end if;
  -- read each amount: whole cents, never text
  foreach k in array array['daily', 'weekend', 'weekly', 'monthly', 'km_per_day', 'overage', 'deposit', 'delivery', 'pickup'] loop
    raw := nullif(btrim(coalesce(p_ ->> k, '')), '');
    if raw is null then continue; end if;
    if raw !~ '^-?\d{1,12}$' then
      err := err || jsonb_build_object(k, case when k = 'km_per_day' then 'Enter a whole number of kilometres, like 200.' else 'Enter an amount in dollars, like 89 or 89.50.' end);
    else
      amt := amt || jsonb_build_object(k, raw::bigint);
    end if;
  end loop;

  -- the rates
  v_daily := (amt ->> 'daily')::bigint;
  if v_daily is null and not err ? 'daily' then err := err || jsonb_build_object('daily', 'Enter the daily rate. It is needed to post the car.');
  elsif v_daily <= 0 then err := err || jsonb_build_object('daily', 'The daily rate must be above zero.');
  end if;
  foreach k in array array['weekend', 'weekly', 'monthly'] loop
    if (amt ->> k)::bigint <= 0 then err := err || jsonb_build_object(k, format('The %s must be above zero, or leave it empty.', lower(names ->> k))); end if;
  end loop;
  v_we := coalesce((amt ->> 'weekend')::bigint, v_daily);
  v_wk := coalesce((amt ->> 'weekly')::bigint, v_daily * 6);
  v_m := coalesce((amt ->> 'monthly')::bigint, v_daily * 22);
  if not amt ? 'weekend' then derived := derived || 'weekend'::text; end if;
  if not amt ? 'weekly' then derived := derived || 'weekly'::text; end if;
  if not amt ? 'monthly' then derived := derived || 'monthly'::text; end if;
  if v_daily > 0 and v_wk > 0 and v_wk > 7 * v_daily then warn := warn || 'The weekly rate is more than 7 days at the daily rate, so a 7-day rental costs more than 6 days.'::text; end if;
  if v_wk > 0 and v_m > 0 and v_m < v_wk then warn := warn || 'The monthly rate is less than the weekly rate.'::text; end if;
  if v_daily > 0 and v_wk > 0 and v_wk < v_daily then warn := warn || 'The weekly rate is less than one day at the daily rate.'::text; end if;

  -- the kilometre terms
  if v_mode not in ('default', 'custom') then err := err || jsonb_build_object('km_mode', 'Choose the defaults or custom kilometres.'); v_mode := 'default'; end if;
  if v_mode = 'default' then
    v_km := (dflt ->> 'km_per_day')::integer;
    v_over := (dflt ->> 'overage_cents')::bigint;
  else
    v_km := coalesce((amt ->> 'km_per_day')::integer, (dflt ->> 'km_per_day')::integer);
    v_over := coalesce((amt ->> 'overage')::bigint, (dflt ->> 'overage_cents')::bigint);
    if (amt ->> 'km_per_day')::bigint < 1 or (amt ->> 'km_per_day')::bigint > 5000 then
      err := err || jsonb_build_object('km_per_day', 'Enter the kilometres included a day, from 1 to 5,000.');
    end if;
    if (amt ->> 'overage')::bigint < 0 then err := err || jsonb_build_object('overage', 'The extra kilometre rate cannot be below $0.'); end if;
  end if;
  if v_over is null and not err ? 'overage' then
    err := err || jsonb_build_object('overage', 'There is no default extra kilometre rate for this class: choose Custom and enter one, or set it in Fee defaults.');
  elsif not err ? 'overage' and v_over is not null and (v_over < coalesce(v_omin, v_over) or v_over > coalesce(v_omax, v_over)) then
    err := err || jsonb_build_object('overage', format('For a %s car the extra kilometre rate is %s to %s a km (Fee defaults).',
                                                       dflt ->> 'class', app.rc_money(v_omin, true), app.rc_money(v_omax, true)));
  end if;

  -- deposit, delivery and pickup
  v_dep := coalesce((amt ->> 'deposit')::bigint, cur.deposit_cents, (dflt ->> 'deposit_cents')::bigint);
  v_del := coalesce((amt ->> 'delivery')::bigint, cur.delivery_fee_cents, 0);
  v_pick := coalesce((amt ->> 'pickup')::bigint, cur.pickup_fee_cents, 0);
  if v_dep is null and not err ? 'deposit' then err := err || jsonb_build_object('deposit', 'Enter the deposit (there is no default for this class).'); end if;
  foreach k in array array['deposit', 'delivery', 'pickup'] loop
    if (amt ->> k)::bigint < 0 then err := err || jsonb_build_object(k, format('The %s cannot be below $0.', lower(names ->> k))); end if;
  end loop;
  for c in select fd.fee_type_code, fd.min_cents, fd.max_cents from fee_defaults fd
            where fd.fee_type_code in ('delivery', 'pickup') and (fd.vehicle_class is null or fd.vehicle_class::text = dflt ->> 'class')
              and (fd.min_cents is not null or fd.max_cents is not null)
              and fd.effective_from <= app.today() and (fd.effective_to is null or fd.effective_to > app.today()) loop
    k := c.fee_type_code;
    if not err ? k and coalesce(case k when 'delivery' then v_del else v_pick end, 0) > 0
       and (case k when 'delivery' then v_del else v_pick end < coalesce(c.min_cents, 0) or case k when 'delivery' then v_del else v_pick end > coalesce(c.max_cents, 9e15::bigint)) then
      err := err || jsonb_build_object(k, format('The %s is outside the range in Fee defaults: %s to %s, or $0 when not offered.', lower(names ->> k), app.rc_money(c.min_cents), app.rc_money(c.max_cents)));
    end if;
  end loop;

  -- examples, priced as bookings are (public.calc_rental_charge), when the rates can be used
  if not (err ?| array['daily', 'weekend', 'weekly', 'monthly']) and v_daily > 0 then
    v_fri := ((date_trunc('week', (now() at time zone 'America/Toronto')) + interval '4 days 10 hours') at time zone 'America/Toronto');
    if v_fri < now() then v_fri := v_fri + interval '7 days'; end if;
    v_mon := v_fri + interval '3 days';
    for e in select * from (values
        (1, 'friday_sunday', 'Friday 10 am to Sunday 10 am', v_fri, 2),
        (2, 'monday_thursday', 'Monday 10 am to Thursday 10 am', v_mon, 3),
        (3, 'friday_monday', 'Friday 10 am to Monday 10 am', v_fri, 3),
        (4, 'week', '7 days', v_mon, 7),
        (5, 'two_weeks', '14 days', v_mon, 14),
        (6, 'month', '30 days', v_mon, 30)) x(n, code, label, pickup, days) order by n loop
      select * into c from public.calc_rental_charge(e.pickup, e.days, v_daily, v_we, v_wk, v_m);
      ex := ex || jsonb_build_object('code', e.code, 'label', e.label, 'days', e.days, 'rate_applied', c.rate_applied,
        'daily_days', c.daily_days, 'weekend_days', c.weekend_days, 'cents', c.rental_charge_cents, 'km_included', v_km * e.days,
        'text', format('%s: %s before tax%s, %s km included.', e.label, app.rc_money(c.rental_charge_cents),
          case when c.rate_applied = 'daily' then
                 case when c.rental_charge_cents < c.daily_days * v_daily + c.weekend_days * v_we then format(' (capped at the weekly rate; %s weekday and %s weekend days)', c.daily_days, c.weekend_days)
                      when c.weekend_days = 0 then format(' (%s days at the daily rate)', c.daily_days)
                      when c.daily_days = 0 then format(' (%s days at the weekend rate)', c.weekend_days)
                      else format(' (%s at the weekend rate, %s at the daily rate)', c.weekend_days, c.daily_days) end
               when c.rate_applied = 'weekly' then case when c.rental_charge_cents = v_m then ' (capped at the monthly rate)' else format(' (the weekly rate for %s days)', e.days) end
               else ' (the monthly rate)' end,
          to_char(v_km * e.days, 'FM999,999')));
    end loop;
  end if;

  return jsonb_build_object(
    'ok', err = '{}'::jsonb,
    'errors', err,
    'messages', (select coalesce(jsonb_agg(format('%s: %s', coalesce(names ->> x.key, x.key), x.value #>> '{}') order by x.key), '[]'::jsonb) from jsonb_each(err) x),
    'warnings', to_jsonb(warn),
    'derived', to_jsonb(derived),
    'values', jsonb_build_object('daily', v_daily, 'weekend', v_we, 'weekly', v_wk, 'monthly', v_m, 'km_mode', v_mode,
      'km_per_day', v_km, 'overage', v_over, 'deposit', v_dep, 'delivery', v_del, 'pickup', v_pick,
      'km_uses_defaults', v_km = (dflt ->> 'km_per_day')::integer and v_over = (dflt ->> 'overage_cents')::bigint),
    'defaults', dflt,
    'examples', ex,
    'km_text', case when v_km is not null and v_over is not null
                    then format('%s km included a day, then %s for each extra km.', v_km, app.rc_money(v_over, true)) end);
end $$;

-- ================================================================ 4. set_rate_card: the same check, nothing circular
-- Same arguments as 0020. What is not given in p_other is the current card's (kilometres, overage, deposit,
-- delivery, pickup); for a first card the defaults (section 2), never a refusal for kilometres. p_other may carry
-- km_mode 'default' to take the defaults. Every problem is named by field.
create or replace function app.set_rate_card(p_vehicle uuid, p_daily_cents bigint, p_weekend_cents bigint, p_weekly_cents bigint,
    p_monthly_cents bigint, p_effective_from timestamptz default now(), p_by uuid default null, p_other jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  ot jsonb := coalesce(p_other, '{}'::jsonb);
  v vehicles;
  cur rate_cards;
  v_from timestamptz := coalesce(p_effective_from, now());
  v_next timestamptz;
  v_by_owner boolean := false;
  chk jsonb;
  val jsonb;
  v_id uuid;
  v_mode text;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then raise exception 'Vehicle % not found', p_vehicle; end if;
  if p_by is not null then
    v_by_owner := v.management_mode = 'self_managed' and exists (select 1 from owners o where o.id = v.owner_id and o.user_id = p_by);
    if not (app.user_runs_fleet(p_by) or v_by_owner) then
      raise exception 'Rates are set by an Admin (entered by Fleet), or by the Owner of a Self-Managed vehicle' using errcode = '42501';
    end if;
  end if;
  select * into cur from rate_cards r
   where r.vehicle_id = p_vehicle and r.effective_from <= v_from and (r.effective_to is null or r.effective_to > v_from);
  -- kilometres: given, else the current card's (custom), else the defaults
  v_mode := coalesce(nullif(ot ->> 'km_mode', ''),
                     case when ot ? 'km_allowance_per_day' or ot ? 'overage_cents_per_km' or cur.id is not null then 'custom' else 'default' end);
  chk := app.rate_card_check(p_vehicle, jsonb_build_object(
    'daily', p_daily_cents, 'weekend', p_weekend_cents, 'weekly', p_weekly_cents, 'monthly', p_monthly_cents,
    'km_mode', v_mode,
    'km_per_day', coalesce(ot ->> 'km_allowance_per_day', cur.km_allowance_per_day::text),
    'overage', coalesce(ot ->> 'overage_cents_per_km', cur.overage_cents_per_km::text),
    'deposit', ot ->> 'deposit_cents', 'delivery', ot ->> 'delivery_fee_cents', 'pickup', ot ->> 'pickup_fee_cents'));
  if not (chk ->> 'ok')::boolean then
    raise exception 'Check the rates. %', (select string_agg(m #>> '{}', '. ') from jsonb_array_elements(chk -> 'messages') m) using errcode = '22023';
  end if;
  val := chk -> 'values';
  if cur.id is not null and cur.effective_from = v_from then
    raise exception 'A rate card already starts at that moment: choose a later time' using errcode = '23505';
  end if;
  select min(r.effective_from) into v_next from rate_cards r where r.vehicle_id = p_vehicle and r.effective_from > v_from;
  if cur.id is not null then
    update rate_cards set effective_to = v_from where id = cur.id;
  end if;
  insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day,
                          overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from, effective_to, set_by, set_by_owner,
                          km_uses_defaults)
  values (p_vehicle, (val ->> 'daily')::bigint, (val ->> 'weekend')::bigint, (val ->> 'weekly')::bigint, (val ->> 'monthly')::bigint,
          (val ->> 'km_per_day')::integer, (val ->> 'overage')::integer, (val ->> 'deposit')::bigint, (val ->> 'delivery')::bigint,
          (val ->> 'pickup')::bigint, v_from, v_next, p_by, v_by_owner, coalesce((val ->> 'km_uses_defaults')::boolean, false))
  returning id into v_id;
  return v_id;
end $$;

-- The rate form's save (one step): rates, kilometres, deposit, delivery and pickup. p: vehicle, the fields of
-- app.rate_card_check() and effective_from.
create or replace function app.rate_card_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_vehicle uuid := nullif(p_ ->> 'vehicle', '')::uuid;
  chk jsonb;
  val jsonb;
  v_id uuid;
begin
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  chk := app.rate_card_check(v_vehicle, p_);
  if not (chk ->> 'ok')::boolean then
    raise exception 'Check the rates. %', (select string_agg(m #>> '{}', '. ') from jsonb_array_elements(chk -> 'messages') m) using errcode = '22023';
  end if;
  val := chk -> 'values';
  v_id := app.set_rate_card(v_vehicle, (val ->> 'daily')::bigint, (val ->> 'weekend')::bigint, (val ->> 'weekly')::bigint, (val ->> 'monthly')::bigint,
            coalesce(nullif(p_ ->> 'effective_from', '')::timestamptz, now()), p_by,
            jsonb_build_object('km_mode', val ->> 'km_mode', 'km_allowance_per_day', val ->> 'km_per_day', 'overage_cents_per_km', val ->> 'overage',
                               'deposit_cents', val ->> 'deposit', 'delivery_fee_cents', val ->> 'delivery', 'pickup_fee_cents', val ->> 'pickup'));
  return jsonb_build_object('id', v_id, 'card', (select to_jsonb(r) from rate_cards r where r.id = v_id), 'examples', chk -> 'examples');
end $$;

-- ================================================================ 5. Add a car: the rates in the same step, for every supply type
-- app.vehicle_add() of 0046, word for word, except the rates: p.rates {daily, weekend, weekly, monthly, km_mode,
-- km_per_day, overage, deposit, delivery, pickup} (cents) are checked with app.rate_card_check() before anything is
-- written, and saved with app.set_rate_card() for a program owner's car too. No rates: the car is added without a
-- rate card, as before.
create or replace function app.vehicle_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text := coalesce(nullif(p ->> 'supply_type', ''), 'program_owner');
  v_vin text := app.clean_vin(p ->> 'vin');
  v_plate text := nullif(upper(regexp_replace(coalesce(p ->> 'plate', ''), '\s', '', 'g')), '');
  x vehicles;
  pr partners;
  d vin_decodes;
  v_id uuid := gen_random_uuid();
  v_res jsonb;
  r jsonb := coalesce(p -> 'rates', '{}'::jsonb);
  v_has_rates boolean;
  chk jsonb;
  v_year smallint; v_make text; v_model text;
begin
  perform app.assert_admin(p_by);
  if v_type not in ('program_owner', 'company', 'partner') then raise exception 'Choose who supplies the car' using errcode = '22023'; end if;
  if v_vin is null then raise exception 'Enter the 17-character VIN' using errcode = '22023'; end if;
  -- the rates are checked first, so a car is never added half way
  v_has_rates := exists (select 1 from jsonb_each_text(r) e where e.key in ('daily', 'weekend', 'weekly', 'monthly') and nullif(btrim(e.value), '') is not null);
  if v_has_rates then
    chk := app.rate_card_check(null, r || jsonb_build_object('class', coalesce(nullif(p ->> 'class', ''), 'standard'), 'make', p ->> 'make', 'model', p ->> 'model'));
    if not (chk ->> 'ok')::boolean then
      raise exception 'Check the rates. %', (select string_agg(m #>> '{}', '. ') from jsonb_array_elements(chk -> 'messages') m) using errcode = '22023';
    end if;
  end if;
  -- the duplicate check, the same for the three kinds: one VIN once in the fleet; a plate on another active car is named
  select * into x from vehicles where upper(vin) = v_vin;
  if x.id is not null then
    raise exception 'This VIN is already in the fleet: % (%)%', app.vehicle_name(x.id), lower(app.supply_label(x.supply_type)),
      case when x.retired_at is not null then '. It is retired: restore it instead of adding it again' else '' end using errcode = '23505';
  end if;
  if v_plate is not null then
    select * into x from vehicles where app.norm_plate(plate) = app.norm_plate(v_plate) and retired_at is null
       and status not in ('exited', 'total_loss', 'declined') limit 1;
    if x.id is not null then
      raise exception 'Plate % is on another car in the fleet: % (%)', v_plate, app.vehicle_name(x.id), lower(app.supply_label(x.supply_type)) using errcode = '23505';
    end if;
  end if;

  if v_type = 'program_owner' then
    if nullif(p ->> 'owner_id', '') is null or (select kind from owners where id = (p ->> 'owner_id')::uuid) is distinct from 'program' then
      raise exception 'Choose the owner (an owner in the owner program)' using errcode = '22023';
    end if;
    v_res := app.add_owner_vehicle((p ->> 'owner_id')::uuid, p - 'supply_type' - 'owner_id' - 'rates', p_by, null);
    update vehicles set added_by = p_by where id = (v_res ->> 'vehicle_id')::uuid;
    if v_has_rates then perform app.vehicle_add_rates((v_res ->> 'vehicle_id')::uuid, p_by, r); end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'vehicle_add', 'vehicles', v_res ->> 'vehicle_id', jsonb_build_object('supply_type', v_type, 'owner_id', p ->> 'owner_id', 'vin', v_vin, 'rates', v_has_rates));
    return v_res || jsonb_build_object('supply_type', v_type, 'rates_set', v_has_rates);
  end if;

  if v_type = 'partner' then
    select * into pr from partners where id = nullif(p ->> 'partner_id', '')::uuid;
    if pr.id is null then raise exception 'Choose the partner rental company' using errcode = '22023'; end if;
    if pr.status = 'ended' then raise exception 'The partnership with % has ended', pr.business_name using errcode = '23514'; end if;
  end if;
  select * into d from vin_decodes z where z.vin = v_vin and z.ok order by z.decoded_at desc limit 1;
  v_year := coalesce(nullif(p ->> 'year', '')::smallint, d.year);
  v_make := coalesce(nullif(btrim(p ->> 'make'), ''), d.make);
  v_model := coalesce(nullif(btrim(p ->> 'model'), ''), d.model);
  if v_year is null or v_make is null or v_model is null then
    raise exception 'Enter the year, make and model' using errcode = '22023';
  end if;
  insert into vehicles (id, owner_id, supply_type, partner_id, commission_bps, year, make, model, trim, colour, fuel, vin, plate, odometer_km, class,
                        status, management_mode, enrollment_date, home_location, body_type, allows_18_to_20, title_brand_clear, added_by)
  values (v_id, case when v_type = 'company' then app.company_owner_id() else pr.owner_id end, v_type, pr.id,
          case when v_type = 'partner' then nullif(p ->> 'commission_bps', '')::integer end,
          v_year, v_make, v_model, coalesce(nullif(btrim(p ->> 'trim'), ''), d.trim), nullif(btrim(p ->> 'colour'), ''),
          coalesce(nullif(p ->> 'fuel', '')::fuel_type, d.fuel, 'gasoline'), v_vin, v_plate, nullif(p ->> 'odometer_km', '')::integer,
          coalesce(nullif(p ->> 'class', '')::vehicle_class, 'standard'), 'available', 'managed', app.today(),
          nullif(btrim(p ->> 'home_location'), ''), coalesce(nullif(btrim(p ->> 'body_type'), ''), d.body_class),
          coalesce((p ->> 'allows_18_to_20')::boolean, false), true, p_by);
  if v_has_rates then perform app.vehicle_add_rates(v_id, p_by, r); end if;
  perform app.ensure_listing(v_id);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'vehicle_add', 'vehicles', v_id::text, jsonb_build_object('supply_type', v_type, 'partner_id', pr.id, 'vin', v_vin, 'plate', v_plate, 'rates', v_has_rates));
  return jsonb_build_object('vehicle_id', v_id, 'supply_type', v_type, 'name', app.vehicle_name(v_id), 'rates_set', v_has_rates,
                            'similar', (select count(*) from listing_similarity_flags f where f.vehicle_id = v_id and f.status = 'open'));
end $$;

create or replace function app.vehicle_add_rates(p_vehicle uuid, p_by uuid, r jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
begin
  return (app.rate_card_save(p_by, r || jsonb_build_object('vehicle', p_vehicle)) ->> 'id')::uuid;
end $$;

-- ================================================================ 6. delete a car: requests that never took money do not block it
-- A booking that never confirmed and never took money: requested, offered, tentative, declined, expired, or
-- cancelled before it was confirmed; no payment, deposit taken, refund, split, statement or signed agreement.
create or replace function app.booking_never_confirmed(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((
    select b.status::text in ('requested', 'offered', 'tentative', 'declined', 'expired', 'cancelled')
       and b.confirmed_at is null
       and not exists (select 1 from payments x where x.booking_id = b.id)
       and not exists (select 1 from deposits x where x.booking_id = b.id and x.status not in ('pending', 'failed'))
       and not exists (select 1 from refunds x where x.booking_id = b.id)
       and not exists (select 1 from booking_splits x where x.booking_id = b.id)
       and not exists (select 1 from booking_statements x where x.booking_id = b.id)
       and not exists (select 1 from rental_agreements x where x.booking_id = b.id and (x.renter_signed_at is not null or x.status in ('signed', 'completed')))
       and not exists (select 1 from booking_vehicle_swaps x where x.booking_id = b.id)
      from bookings b where b.id = p_booking), false)
$$;

-- The bookings that go with the car on a delete, in words for the confirmation.
create or replace function app.vehicle_delete_removes(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status::text,
           'renter', r.legal_name, 'pickup_at', b.pickup_at,
           'text', format('%s, %s, %s, pickup %s', b.booking_number, replace(b.status::text, '_', ' '), coalesce(r.legal_name, 'renter'),
                          to_char(b.pickup_at at time zone 'America/Toronto', 'Mon DD, YYYY')))
           order by b.pickup_at, b.booking_number), '[]'::jsonb)
    from bookings b left join renters r on r.id = b.renter_id
   where b.vehicle_id = p_vehicle and app.booking_never_confirmed(b.id)
$$;

-- 0046's rule, with the bookings counted only when they confirmed or took money, named by number.
create or replace function app.vehicle_delete_blockers(p_vehicle uuid) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  b text[] := '{}';
  n bigint;
  v_nums text;
  t record;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return array['Vehicle not found']; end if;
  select count(*), string_agg(x.booking_number, ', ' order by x.booking_number) into n, v_nums
    from (select bk.booking_number from bookings bk where bk.vehicle_id = v.id and not app.booking_never_confirmed(bk.id) order by bk.booking_number limit 1000) x;
  if n > 0 then b := b || format('%s confirmed or paid booking%s (%s)', n, case when n = 1 then '' else 's' end,
                                 case when n > 5 then split_part(v_nums, ', ', 1) || ', ' || split_part(v_nums, ', ', 2) || ' and ' || (n - 2) || ' more' else v_nums end); end if;
  select count(*) into n from booking_vehicle_swaps where from_vehicle_id = v.id or to_vehicle_id = v.id;
  if n > 0 then b := b || format('%s vehicle swap(s)', n); end if;
  select count(*) into n from payments p where p.booking_id in (select id from bookings where vehicle_id = v.id);
  if n > 0 then b := b || format('%s payment(s)', n); end if;
  select count(*) into n from owner_invoices i where i.vehicle_id = v.id and (i.status not in ('draft', 'void') or i.paid_cents > 0);
  if n > 0 then b := b || format('%s owner invoice(s) issued', n); end if;
  for t in select * from (values
      ('owner_statement_vehicles', 'owner statement line(s)'), ('booking_splits', 'booking split(s)'), ('company_statement_lines', 'company statement line(s)'),
      ('toll_tickets', 'toll or ticket notice(s)'), ('damage_intakes', 'damage intake(s)'), ('incidents', 'incident(s)'), ('turo_trips', 'Turo trip(s)'),
      ('company_expenses', 'expense(s)'), ('owner_deductions', 'owner deduction(s)'), ('vehicle_prepaids', 'prepaid month(s)'),
      ('referral_kickbacks', 'referral kickback(s)'), ('fleet_report_vehicles', 'fleet report line(s)')) x(tbl, label) loop
    if to_regclass('public.' || t.tbl) is not null then
      execute format('select count(*) from public.%I where vehicle_id = $1', t.tbl) into n using v.id;
      if n > 0 then b := b || format('%s %s', n, t.label); end if;
    end if;
  end loop;
  if not coalesce(v.is_sample, false) then
    select count(*) into n from vehicle_schedules s where s.vehicle_id = v.id and (s.signed_at is not null or s.document_id is not null);
    if n > 0 then b := b || format('%s signed vehicle schedule(s)', n); end if;
  end if;
  select count(*) into n from documents d where d.vehicle_id = v.id and d.purged_at is null;
  if n > 0 then b := b || format('%s stored document(s)', n); end if;
  return b;
end $$;

-- The requests removed with a car: kept here (what they were, their history and offers), never with money.
create table deleted_booking_requests (
  id              uuid primary key default gen_random_uuid(),
  booking_id      uuid not null,
  booking_number  text not null,
  vehicle_id      uuid not null,
  vehicle_name    text,
  renter_id       uuid,
  status          text not null,
  pickup_at       timestamptz,
  return_at       timestamptz,
  booking         jsonb not null,
  events          jsonb not null default '[]'::jsonb,
  offers          jsonb not null default '[]'::jsonb,
  message_ids     jsonb not null default '[]'::jsonb,
  deleted_by      uuid,
  deleted_at      timestamptz not null default now()
);
create index deleted_booking_requests_number_idx on deleted_booking_requests (booking_number);
comment on table deleted_booking_requests is 'Booking requests that never confirmed or took money, removed with a car that was deleted (0064). The renter record stays.';
alter table deleted_booking_requests enable row level security;
create policy admin_all on deleted_booking_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on deleted_booking_requests from anon, authenticated;
create trigger audit_deleted_booking_requests after insert or update or delete on deleted_booking_requests
  for each row execute function app.audit_row();

-- 0046's delete, with the requests archived first. History tables that only ever grow (booking_events, messages) let
-- go of these rows for the length of the delete only.
create or replace function app.vehicle_delete(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_block text[];
  v_files jsonb;
  v_removes jsonb;
  v_confirm text := upper(regexp_replace(coalesce(p ->> 'confirm', ''), '\s', '', 'g'));
  n integer;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = (p ->> 'vehicle_id')::uuid for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  if not coalesce((p ->> 'bulk')::boolean, false)
     and v_confirm not in (upper(regexp_replace(coalesce(v.plate, '-'), '\s', '', 'g')), upper(regexp_replace(app.vehicle_name(v.id), '\s', '', 'g'))) then
    raise exception 'Type the plate (or the car''s name, %) to confirm', app.vehicle_name(v.id) using errcode = '22023';
  end if;
  v_block := app.vehicle_delete_blockers(v.id);
  if cardinality(v_block) > 0 then
    raise exception 'This car cannot be deleted: it has %. Retire it instead', array_to_string(v_block, ', ') using errcode = '23514';
  end if;
  v_removes := app.vehicle_delete_removes(v.id);
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_files from (
    select jsonb_build_object('bucket', 'vehicle-public', 'path', ph.processed_path) as x from vehicle_photos ph where ph.vehicle_id = v.id and ph.processed_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-originals', 'path', ph.original_path) from vehicle_photos ph where ph.vehicle_id = v.id and ph.original_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-originals', 'path', ph.uncovered_path) from vehicle_photos ph where ph.vehicle_id = v.id and ph.uncovered_path is not null
    union all select jsonb_build_object('bucket', 'vehicle-public', 'path', vv ->> 'path')
                from vehicle_photos ph cross join lateral jsonb_array_elements(case when jsonb_typeof(ph.variants) = 'array' then ph.variants else '[]'::jsonb end) vv
               where ph.vehicle_id = v.id and vv ->> 'path' is not null) q;
  -- the requests: archived, then removed with the car
  insert into deleted_booking_requests (booking_id, booking_number, vehicle_id, vehicle_name, renter_id, status, pickup_at, return_at, booking, events, offers, message_ids, deleted_by)
  select b.id, b.booking_number, v.id, app.vehicle_name(v.id), b.renter_id, b.status::text, b.pickup_at, b.return_at, to_jsonb(b),
         coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at) from booking_events e where e.booking_id = b.id), '[]'::jsonb),
         coalesce((select jsonb_agg(to_jsonb(o) order by o.version) from booking_offers o where o.booking_id = b.id), '[]'::jsonb),
         coalesce((select jsonb_agg(m.id) from messages m where m.booking_id = b.id), '[]'::jsonb), p_by
    from bookings b where b.vehicle_id = v.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before)
  values (p_by, 'vehicle_delete', 'vehicles', v.id::text,
          jsonb_build_object('name', app.vehicle_name(v.id), 'vin', v.vin, 'plate', v.plate, 'supply_type', v.supply_type, 'is_sample', v.is_sample, 'status', v.status,
                             'requests_removed', v_removes));
  perform set_config('app.vehicle_delete', v.id::text, true);
  if jsonb_array_length(v_removes) > 0 then
    alter table booking_events disable trigger booking_events_append_only;
    alter table messages disable trigger messages_append_only;
  end if;
  n := app.purge_rows('public.vehicles'::regclass, format('id = %L', v.id));
  if jsonb_array_length(v_removes) > 0 then
    alter table booking_events enable trigger booking_events_append_only;
    alter table messages enable trigger messages_append_only;
  end if;
  perform set_config('app.vehicle_delete', '', true);
  return jsonb_build_object('vehicle_id', v.id, 'deleted', true, 'rows', n, 'files', v_files, 'requests_removed', v_removes);
end $$;

-- 0046's bulk delete, word for word, also returning the requests removed.
create or replace function app.vehicles_delete_samples(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_done jsonb := '[]'::jsonb;
  v_kept jsonb := '[]'::jsonb;
  v_files jsonb := '[]'::jsonb;
  v_removed jsonb := '[]'::jsonb;
  v_res jsonb;
  v_block text[];
begin
  perform app.assert_admin(p_by);
  if upper(coalesce(p ->> 'confirm', '')) <> 'DELETE SAMPLE CARS' then
    raise exception 'Type DELETE SAMPLE CARS to confirm' using errcode = '22023';
  end if;
  for r in select id from vehicles where is_sample order by fleet_number nulls last, id loop
    v_block := app.vehicle_delete_blockers(r.id);
    if cardinality(v_block) > 0 then
      v_kept := v_kept || jsonb_build_object('vehicle_id', r.id, 'name', app.vehicle_name(r.id), 'why', array_to_string(v_block, ', '));
    else
      v_res := app.vehicle_delete(p_by, jsonb_build_object('vehicle_id', r.id, 'bulk', true));
      v_done := v_done || jsonb_build_object('vehicle_id', r.id);
      v_files := v_files || (v_res -> 'files');
      v_removed := v_removed || (v_res -> 'requests_removed');
    end if;
  end loop;
  return jsonb_build_object('deleted', jsonb_array_length(v_done), 'kept', v_kept, 'files', v_files, 'requests_removed', v_removed);
end $$;

-- ================================================================ 7. requests whose pickup time passed expire
insert into status_transitions (entity, from_status, to_status, note) values
  ('booking', 'requested', 'expired', 'the pickup time passed before an offer was sent (0064)')
on conflict do nothing;

alter table booking_events drop constraint if exists booking_events_kind_check;
alter table booking_events add constraint booking_events_kind_check check (kind in ('adjusted', 'agreement_completed', 'agreement_opened', 'agreement_signed',
  'agreement_voided', 'booking_change', 'calendar_switch', 'cancelled', 'change_requested', 'confirmed', 'declined', 'deposit_waived', 'extension',
  'info_replied', 'info_requested', 'offer_approved', 'offer_expired', 'offer_sent', 'offer_withdrawn', 'payment_refused', 'promo_applied', 'promo_removed',
  'pushed_back', 'requested', 'verification', 'reopened', 'review_request', 'added_by_staff', 'sales_credit', 'custom_price', 'request_expired'));

create or replace function app.expire_stale_requests(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
  s program_settings := app.settings();
  v_note text;
begin
  if not coalesce(s.stale_request_expire, true) then return 0; end if;
  for r in select b.id, b.booking_number, b.pickup_at from bookings b
            where b.status = 'requested' and b.pickup_at <= p_now and b.booking_type::text <> 'owner'
            order by b.pickup_at, b.id for update skip locked loop
    v_note := format('The pickup time (%s, Toronto) passed before an offer was sent, so the request expired by itself. %s',
                     to_char(r.pickup_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                     case when s.stale_request_email_renter then 'The renter was emailed.' else 'The renter was not emailed.' end);
    update bookings set status = 'expired' where id = r.id;
    perform app.log_booking_event(r.id, 'request_expired', 'requested', 'expired', null, v_note, null, 'system');
    perform app.resolve_tasks(array['booking_request'], r.id, null, 'The pickup time passed: the request expired');
    if s.stale_request_email_renter then
      perform app.ntf_emit('renter_request_declined', 'booking', r.id, 'expired',
                           jsonb_build_object('booking_id', r.id, 'note', 'The pickup time passed before we could confirm this car for you.'));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- 0016's job, which now also expires the stale requests.
create or replace function app.job_offers_expire(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_run uuid;
  v_n integer;
  v_r integer;
begin
  if not exists (select 1 from bookings b where b.status = 'offered' and b.offer_expires_at <= p_now)
     and not (coalesce((app.settings()).stale_request_expire, true) and exists (select 1 from bookings b where b.status = 'requested' and b.pickup_at <= p_now)) then
    return 'not_due';
  end if;
  v_run := app.job_claim('offers-expire', to_char(p_now at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"'));
  if v_run is null then return 'already_run'; end if;
  begin
    v_n := app.expire_offers(p_now);
    v_r := app.expire_stale_requests(p_now);
    perform app.job_succeed(v_run, jsonb_build_object('offers_expired', v_n, 'requests_expired', v_r));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;


-- ================================================================ 8b. Add a rental before the listing is finished
-- Staff add a rental for a car whose listing is not finished or published (a draft listing, onboarding, no photos,
-- no rates, plate not checked): the car exists and has a valid supplier (an owner, CarmaCars, or a partner whose
-- partnership has not ended). The public site still shows only published listings (every public flow reads
-- public_vehicle_listings, and publishing makes a car Available). Handover rules are unchanged: a car is handed over
-- only when it is Available. A car with no rates takes a price typed by hand with its reason (the usual price flags).
-- A program owner's car whose listing is not finished and that is not yet on the fleet insurance policy (the owner
-- onboarding step; CarmaCars-owned cars have no such step and a partner insures its own) is added only by an Admin
-- who confirms it is insured.
create or replace function app.vehicle_bookable(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select v.bookings_enabled
     and v.retired_at is null
     and v.management_mode <> 'turo_only'
     and v.status in ('onboarding', 'ready_to_list', 'available', 'on_rent', 'cleaning', 'out_of_service', 'exit_notice')
     and not (v.management_mode = 'self_managed' and v.in_arrears)
     and v.owner_id is not null
     and (v.supply_type is distinct from 'partner' or exists (select 1 from partners pr where pr.id = v.partner_id and pr.status <> 'ended'))
    from vehicles v where v.id = p_vehicle
$$;

create or replace function app.vehicle_listing_finished(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicle_listings l where l.vehicle_id = p_vehicle and l.status = 'published')
$$;

-- A program owner's car takes a rental only once its Revenue Share is set (the owner's share of each rental).
create or replace function app.vehicle_needs_terms(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.supply_type = 'program_owner' and (select t.company_share_bps from app.vehicle_split_terms(v.id, app.today(), 'standard') t) is null
                     from vehicles v where v.id = p_vehicle), false)
$$;

create or replace function app.vehicle_needs_policy_confirm(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.supply_type = 'program_owner' and not coalesce(v.on_fleet_policy, false) and not app.vehicle_listing_finished(v.id)
                     from vehicles v where v.id = p_vehicle), false)
$$;

-- The cars of Add a rental, with "Listing not finished", no rates and the insurance check.
create or replace function app.manual_rental_vehicles(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'supply_type', v.supply_type,
           'bookable', app.vehicle_bookable(v.id), 'retired', v.retired_at is not null, 'status', v.status::text,
           'daily_rate_cents', rc.daily_rate_cents, 'has_rates', rc.id is not null,
           'listing_status', coalesce(l.status, 'none'), 'listing_finished', coalesce(l.status = 'published', false),
           'needs_policy_confirm', app.vehicle_needs_policy_confirm(v.id), 'needs_terms', app.vehicle_needs_terms(v.id))
           order by app.vehicle_bookable(v.id) desc, coalesce(l.status = 'published', false) desc, v.make, v.model, v.year), '[]'::jsonb)
    from vehicles v
    left join vehicle_listings l on l.vehicle_id = v.id
    left join lateral (select r.* from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now()) limit 1) rc on true
   where v.status not in ('declined', 'exited', 'total_loss')
     and (app.user_is_admin(p_by) or (v.retired_at is null and not coalesce(v.is_sample, false) and app.vehicle_bookable(v.id)))
$$;

-- A rental added by hand for a car with no rates: the default kilometres and deposit on the booking as it is written.
create or replace function app.booking_rental_defaults() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb;
begin
  d := nullif(current_setting('app.rental_defaults', true), '')::jsonb;
  if d is null or new.rate_card_id is not null or (d ->> 'vehicle_id')::uuid is distinct from new.vehicle_id then return new; end if;
  if coalesce(new.km_allowance_per_day, 0) = 0 and (d ->> 'km_per_day') is not null then
    new.km_allowance_per_day := (d ->> 'km_per_day')::integer;
    new.km_allowance_total := new.km_allowance_per_day * new.billable_days;
  end if;
  if coalesce(new.overage_cents_per_km, 0) = 0 and (d ->> 'overage_cents') is not null then new.overage_cents_per_km := (d ->> 'overage_cents')::integer; end if;
  if coalesce(new.deposit_cents, 0) = 0 and (d ->> 'deposit_cents') is not null then new.deposit_cents := (d ->> 'deposit_cents')::bigint; end if;
  return new;
end $$;
create trigger bookings_rental_defaults before insert on bookings for each row execute function app.booking_rental_defaults();

alter function app.manual_rental_quote(uuid, jsonb) rename to manual_rental_quote_0058;
create or replace function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  rc rate_cards;
  d jsonb;
  out jsonb;
  v_days integer;
  v_price bigint := nullif(p ->> 'rental_charge_cents', '')::bigint;
  v_per bigint;
  v_notes text[] := '{}';
begin
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then return app.manual_rental_quote_0058(p_by, p); end if;
  select * into rc from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  if rc.id is not null then
    out := app.manual_rental_quote_0058(p_by, p);
  else
    -- no rates yet: the quote is priced on a stand-in rate card made from the price typed (the defaults for the
    -- kilometres and the deposit), and the stand-in is rolled back at once
    if (p ->> 'pickup_at') is null or (p ->> 'return_at') is null or (p ->> 'return_at')::timestamptz <= (p ->> 'pickup_at')::timestamptz then
      return app.manual_rental_quote_0058(p_by, p);
    end if;
    v_days := public.calc_billable_days((p ->> 'pickup_at')::timestamptz, (p ->> 'return_at')::timestamptz);
    v_per := greatest(1, ceil(coalesce(v_price, 0)::numeric / greatest(v_days, 1))::bigint);
    d := app.rate_card_defaults(v.id);
    begin
      insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day,
                              overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from, set_by)
      values (v.id, v_per, v_per, v_per * 7, v_per * 30, (d ->> 'km_per_day')::integer, coalesce((d ->> 'overage_cents')::integer, 0),
              coalesce((d ->> 'deposit_cents')::bigint, 0), 0, 0, now() - interval '1 minute', p_by);
      out := app.manual_rental_quote_0058(p_by, p);
      raise exception using errcode = 'P0001', message = 'cc64_quote_rollback';
    exception when others then
      if sqlerrm <> 'cc64_quote_rollback' then raise; end if;
    end;
    out := out || jsonb_build_object('rate_sheet_cents', null, 'price_typed_cents', v_price);
    v_notes := v_notes || case when v_price is null then 'This car has no rates yet. Type the rental charge for the whole rental and the reason, then check again.'
                               else 'This car has no rates yet: the price is the rental charge you typed.' end;
  end if;
  if not app.vehicle_listing_finished(v.id) then
    v_notes := v_notes || 'Listing not finished: the car stays off the public site. The rental, payment and agreement work as for any car.'::text;
    if v.status::text in ('onboarding', 'ready_to_list') then
      v_notes := v_notes || format('Before the handover the car must be Available (it is %s now): an Admin changes it under Vehicles, the car, Change status.', replace(v.status::text, '_', ' '));
    end if;
  end if;
  if app.vehicle_needs_terms(v.id) then
    v_notes := v_notes || 'This owner''s car has no Revenue Share yet: set its terms (Owners, the owner, the car) before adding a rental.'::text;
  end if;
  if app.vehicle_needs_policy_confirm(v.id) then
    v_notes := v_notes || case when app.user_is_admin(p_by)
      then 'This car is not on the fleet insurance policy yet. Check that it is insured for these dates, then tick the confirmation to add the rental.'
      else 'This car is not on the fleet insurance policy yet: only an Admin can add its rentals, after checking it is insured.' end;
  end if;
  return out || jsonb_build_object('has_rates', rc.id is not null, 'listing_finished', app.vehicle_listing_finished(v.id),
    'listing_status', coalesce((select l.status from vehicle_listings l where l.vehicle_id = v.id), 'none'), 'vehicle_status', v.status::text,
    'needs_policy_confirm', app.vehicle_needs_policy_confirm(v.id), 'needs_terms', app.vehicle_needs_terms(v.id), 'notes', to_jsonb(v_notes));
end $$;

alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0064;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  rc rate_cards;
  d jsonb;
  out jsonb;
  b bookings;
  v_past boolean := coalesce((p ->> 'past')::boolean, false);
  v_policy boolean;
  v_unlisted boolean;
begin
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then return app.manual_rental_create_pre0064(p_by, p - 'fleet_policy_confirmed'); end if;
  select * into rc from rate_cards r where r.vehicle_id = v.id and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now());
  v_policy := not v_past and app.vehicle_needs_policy_confirm(v.id);
  v_unlisted := not app.vehicle_listing_finished(v.id);
  if not v_past and app.vehicle_needs_terms(v.id) then
    raise exception 'This owner''s car has no Revenue Share yet: set its terms (Owners, the owner, the car) before adding a rental' using errcode = '23514';
  end if;
  if v_policy then
    if not app.user_is_admin(p_by) then
      raise exception 'This car is not on the fleet insurance policy yet: only an Admin can add its rentals, after checking it is insured' using errcode = '42501';
    end if;
    if not coalesce((p ->> 'fleet_policy_confirmed')::boolean, false) then
      raise exception 'This car is not on the fleet insurance policy yet. Tick "I checked that this car is insured for this rental" to add it' using errcode = '23514';
    end if;
  end if;
  if rc.id is null and nullif(p ->> 'rental_charge_cents', '') is null then
    raise exception 'This car has no rates yet: type the rental charge for the whole rental and the reason' using errcode = '22023';
  end if;
  if rc.id is null then
    -- the kilometres and the deposit of the defaults, set as the booking is written (0046 left them at 0 when the car
    -- had no rates; a confirmed booking's terms cannot change afterwards)
    d := app.rate_card_defaults(v.id);
    perform set_config('app.rental_defaults', jsonb_build_object('vehicle_id', v.id, 'km_per_day', d -> 'km_per_day', 'overage_cents', d -> 'overage_cents',
      'deposit_cents', case when nullif(p ->> 'deposit_cents', '') is null then d -> 'deposit_cents' end)::text, true);
  end if;
  out := app.manual_rental_create_pre0064(p_by, p - 'fleet_policy_confirmed');
  perform set_config('app.rental_defaults', '', true);
  select * into b from bookings where id = (out ->> 'booking_id')::uuid;
  if b.id is not null and (v_unlisted or v_policy) then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'manual_rental_unlisted_car', 'bookings', b.id::text,
            jsonb_build_object('booking_number', b.booking_number, 'vehicle_id', v.id, 'listing_finished', not v_unlisted, 'had_rates', rc.id is not null,
                               'vehicle_status', v.status, 'fleet_policy_confirmed', v_policy));
  end if;
  return out || jsonb_build_object('listing_finished', not v_unlisted, 'fleet_policy_confirmed', v_policy, 'had_rates', rc.id is not null);
end $$;

-- ================================================================ 8. the schema marker
create or replace function app.schema_marker() returns text
language plpgsql stable security definer set search_path = public, app as $$
declare v text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    begin
      execute $q$select max(version) from supabase_migrations.schema_migrations where version ~ '^\d{4}$'$q$ into v;
    exception when others then v := null;
    end;
  end if;
  return greatest(coalesce(v, '0064'), '0064');
end $$;

-- ================================================================ 9. the doors and privileges
create or replace function app.ops64(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_vehicle uuid := nullif(coalesce(p_ ->> 'vehicle', p_ ->> 'vehicle_id'), '')::uuid;
begin
  if p_name in ('rate_card_form', 'rate_card_check', 'rate_card_save') then
    if not app.user_runs_fleet(p_user) then
      raise exception 'Rates are set by an Admin or Fleet' using errcode = '42501';
    end if;
    if p_name = 'rate_card_form' then
      return app.rate_card_defaults(v_vehicle, p_) || jsonb_build_object('current',
        (select to_jsonb(r) from rate_cards r where r.vehicle_id = v_vehicle and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())));
    elsif p_name = 'rate_card_check' then
      return app.rate_card_check(v_vehicle, p_);
    else
      return app.rate_card_save(p_user, p_ || jsonb_build_object('vehicle', v_vehicle));
    end if;
  end if;
  if p_name = 'manual_rental_vehicles' then
    if app.manual_rental_role(p_user) is null then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.manual_rental_vehicles(p_user);
  end if;
  -- deleting a car: what blocks it and what goes with it
  perform app.assert_admin(p_user);
  if p_name = 'vehicle_delete_preview' then
    return jsonb_build_object('blockers', to_jsonb(app.vehicle_delete_blockers(v_vehicle)), 'removes', app.vehicle_delete_removes(v_vehicle));
  end if;
  -- sample_cars: 0046's list, with the requests that would go
  return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate,
                     'blockers', to_jsonb(app.vehicle_delete_blockers(v.id)), 'removes', app.vehicle_delete_removes(v.id))
                     order by v.fleet_number nulls last) from vehicles v where v.is_sample), '[]'::jsonb);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0064;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('admin_read', 'va_read', 'ops_read') and p_name in ('rate_card_form', 'rate_card_check'))
     or (p_call in ('admin_do', 'va_do', 'ops_do') and p_name = 'rate_card_save')
     or (p_call = 'ops_read' and p_name in ('vehicle_delete_preview', 'sample_cars', 'manual_rental_vehicles')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops64(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre0064(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array[
              'class_fee_default', 'rate_card_defaults', 'rc_money', 'rate_card_check', 'rate_card_save', 'vehicle_add_rates',
              'booking_never_confirmed', 'vehicle_delete_removes', 'expire_stale_requests', 'vehicle_listing_finished', 'vehicle_needs_policy_confirm', 'vehicle_needs_terms', 'booking_rental_defaults',
              'manual_rental_vehicles', 'ops64', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_pre0064', 'door'), ('manual_rental_quote_0058', 'manual_rental_quote'), ('manual_rental_create_pre0064', 'manual_rental_create')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 10. the guides for this release
create or replace function app.guide_release_0064(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                  p_md text, p_html text) returns text
language sql security definer set search_path = public, app as $$
  select app.guide_release_section(p_portal, p_slug, p_kind, p_after, p_base_md, p_title, p_blurb, p_md, p_html)
$$;
revoke all on function app.guide_release_0064(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_release_0064(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0064 START (generated by supabase/seed/0064_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_0064('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
', 'Requests, offers and bookings', 'Answer a request with an offer, run a booking, and propose a change.',
  'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
',
  '<p class="gd-p">Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>After the offer is out: <b class="gd-ui">Withdraw to edit</b> takes it back, <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section>');
select app.guide_release_0064('admin', 'fleet-and-listings', 'chapter', 'calendar-sync-with-turo-and-other-platforms', 'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 18.5 19.3, 2 83.5 12.9, 3 73.6 38.9")

> Coming soon: The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from the tracker need the tracker company''s connection first.

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the pipeline''s progress.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag stops publishing.
3. The copy is written by itself from the car''s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The editor suggests a box over the plate. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. When every public photo is covered or marked, press **Approve and publish**.
2. Or press **Approve, publish later**, or **Send back** with what to fix.

> Watch out: Publishing waits for a plate decision on every public photo ("Cover the licence plate or mark it not visible on every public photo first"). Listings already live show "Plate not checked" until someone checks them.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")
', 'Fleet and listings', 'Vehicles, the listing pipeline, similar cars and covering licence plates.',
  'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 18.5 19.3, 2 83.5 12.9, 3 73.6 38.9")

## Set a car''s rates and kilometres

Open the car, then the **Rates** tab. Everything on it saves together, in one step.

1. Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.
2. Kilometres: keep **Use the defaults** (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car''s class), or choose **Custom for this car** and type them.
3. Check the deposit (the class default is filled in), and the delivery and pickup fees (0: not offered).
4. Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press **Save the rates**.

| Rate | What it means |
| --- | --- |
| Daily rate | A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday |
| Weekend rate | A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day |
| Weekly rate | The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more |
| Monthly rate | The price for 30 days. A 7 to 29 day rental never costs more |

> Tip: A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. The same fields are on **Add a car**, so a car can be added with its rates in one pass.

> Coming soon: The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from the tracker need the tracker company''s connection first.

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the pipeline''s progress.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag stops publishing.
3. The copy is written by itself from the car''s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The editor suggests a box over the plate. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. When every public photo is covered or marked, press **Approve and publish**.
2. Or press **Approve, publish later**, or **Send back** with what to fix.

> Watch out: Publishing waits for a plate decision on every public photo ("Cover the licence plate or mark it not visible on every public photo first"). Listings already live show "Plate not checked" until someone checks them.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")
',
  '<p class="gd-p">Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.</p><section class="gd-task" id="fleet-and-listings-vehicles" data-gd-task><h2 class="gd-h2">Vehicles</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Search by plate, model or owner. <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Rates for many cars</b> changes the rates of many cars at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/vehicles</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-08-vehicles-desktop-46461f49.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:18.5%;top:19.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:83.5%;top:12.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:73.6%;top:38.9%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-set-a-car-s-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Set a car&#39;s rates and kilometres</h2><p class="gd-p">Open the car, then the <b class="gd-ui">Rates</b> tab. Everything on it saves together, in one step.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Kilometres: keep <b class="gd-ui">Use the defaults</b> (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car&#39;s class), or choose <b class="gd-ui">Custom for this car</b> and type them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the deposit (the class default is filled in), and the delivery and pickup fees (0: not offered).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press <b class="gd-ui">Save the rates</b>.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Rate</th><th scope="col">What it means</th></tr></thead><tbody><tr><td>Daily rate</td><td>A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday</td></tr><tr><td>Weekend rate</td><td>A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day</td></tr><tr><td>Weekly rate</td><td>The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more</td></tr><tr><td>Monthly rate</td><td>The price for 30 days. A 7 to 29 day rental never costs more</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. The same fields are on <b class="gd-ui">Add a car</b>, so a car can be added with its rates in one pass.</div></aside><aside class="gd-box"><div>Coming soon: The Tracker card on a car says &quot;Coming soon&quot;: live location, the remote immobilize request and mileage from the tracker need the tracker company&#39;s connection first.</div></aside></section><section class="gd-task" id="fleet-and-listings-the-listing-pipeline" data-gd-task><h2 class="gd-h2">The listing pipeline</h2><p class="gd-p">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Listings</b>. A draft waiting for review shows Needs review.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the car, plate, state, photos and the pipeline&#39;s progress.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Start a listing</b> to begin one for a car that has none.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car to review it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-09-listings-desktop-970819b6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:53.5%;top:37%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:21.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.6%;top:37%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-review-a-listing" data-gd-task><h2 class="gd-h2">Review a listing</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Similar cars on file lists possible duplicates. Press <b class="gd-ui">Not a duplicate</b> or <b class="gd-ui">Same car</b>. An open flag stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The copy is written by itself from the car&#39;s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1100"><img src="/guides/img/admin-10-listing-review-desktop-352745fd.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1100"><span class="gd-pin" style="left:20.6%;top:16.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:86.1%;top:47.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.9%;top:100%" aria-hidden="true">3</span><span class="gd-pin" style="left:74.9%;top:100%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-cover-the-licence-plate" data-gd-task><h2 class="gd-h2">Cover the licence plate</h2><p class="gd-p">On each public photo press <b class="gd-ui">Cover the plate</b>. The editor opens.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The editor suggests a box over the plate. Check it. <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under Cover the plate with, choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the covered photo</b>. <b class="gd-ui">Clear the boxes</b> starts over.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">No plate in the shot? Press <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671</span></div><div class="gd-imgwrap" style="aspect-ratio:690/703"><img src="/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg" alt="" loading="lazy" decoding="async" width="690" height="703"><span class="gd-pin" style="left:42.5%;top:83.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:49.6%;top:29.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.3%;top:77.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.5%;top:83.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:18.1%;top:91.2%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.</div></aside></section><section class="gd-task" id="fleet-and-listings-publish" data-gd-task><h2 class="gd-h2">Publish</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When every public photo is covered or marked, press <b class="gd-ui">Approve and publish</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Approve, publish later</b>, or <b class="gd-ui">Send back</b> with what to fix.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Publishing waits for a plate decision on every public photo (&quot;Cover the licence plate or mark it not visible on every public photo first&quot;). Listings already live show &quot;Plate not checked&quot; until someone checks them.</div></aside></section><section class="gd-task" id="fleet-and-listings-a-listing-without-photos-yet-sample-photos" data-gd-task><h2 class="gd-h2">A listing without photos yet: sample photos</h2><p class="gd-p">A car can be listed before its photos are taken. Until then the site shows a sample photo.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Submit the listing without photos. The listing copy is still written for you from the car&#39;s details.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car page and the car&#39;s card show a sample photo, captioned &quot;Sample photo&quot;, so renters know it is not this car. Staff see &quot;Using sample photos&quot; on the car and in Listings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Publishing does not wait for a plate check: a sample photo has no plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-sample-photos" data-gd-task><h2 class="gd-h2">Sample photos</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sample photos</b>. The pictures a car shows until its real photos are in.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press <b class="gd-ui">Add the photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The most specific photo wins: make and model, then make and body type, then body type. <b class="gd-ui">Turn off</b> or <b class="gd-ui">Delete</b> a photo you no longer want.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/sample-photos</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-36-sample-photos-desktop-55c64070.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:26.8%;top:28.9%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_0064('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. First choose who supplies it.

1. **A program owner''s car**: choose the owner. The car starts its onboarding (terms, agreements, registry) as if the owner had applied.
2. **CarmaCars-owned (company fleet)**: no owner. All of its revenue is CarmaCars'' and it shows in the company statement as company fleet.
3. **A partner rental company''s car**: choose the partner. Leave the commission empty to use the partner''s, or type one for this car.
4. Type the VIN, the plate and the details, and the rates if you have them. Press **Add the car**.

> Tip: The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
3. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
4. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
5. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A past rental is recorded as completed.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once. Type DELETE SAMPLE CARS to confirm; the ones kept show why.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. First choose who supplies it.

1. **A program owner''s car**: choose the owner. The car starts its onboarding (terms, agreements, registry) as if the owner had applied.
2. **CarmaCars-owned (company fleet)**: no owner. All of its revenue is CarmaCars'' and it shows in the company statement as company fleet.
3. **A partner rental company''s car**: choose the partner. Leave the commission empty to use the partner''s, or type one for this car.
4. Type the VIN, the plate and the details.
5. Under Rates and kilometres, type the rates now (only the daily rate is needed) and keep the default kilometres, or leave the rates empty and set them later on the car''s Rates tab. What renters pay shows as you type. Press **Add the car**.

> Tip: The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
3. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
4. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
5. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car to be Available (Overview, Change status).
6. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
7. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A past rental is recorded as completed.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. First choose who supplies it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">A program owner&#39;s car</b>: choose the owner. The car starts its onboarding (terms, agreements, registry) as if the owner had applied.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">CarmaCars-owned (company fleet)</b>: no owner. All of its revenue is CarmaCars&#39; and it shows in the company statement as company fleet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">A partner rental company&#39;s car</b>: choose the partner. Leave the commission empty to use the partner&#39;s, or type one for this car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Type the VIN, the plate and the details.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Under Rates and kilometres, type the rates now (only the daily rate is needed) and keep the default kilometres, or leave the rates empty and set them later on the car&#39;s Rates tab. What renters pay shows as you type. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the price: the car&#39;s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car to be Available (Overview, Change status).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Choose Where it came from and how it is paid: <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b>, <b class="gd-ui">Charge the saved card when the renter signs</b> or <b class="gd-ui">Unpaid: invoice later</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A past rental is recorded as completed.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_0064('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves and block the car with the turnaround. For each car on Turo, press **This car is on Turo**, type its name exactly as Turo''s emails show it and press **Save**.
2. Under "Turo emails to check", an email the reader was not sure about: check the trip on Turo, then **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
4. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
5. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

1. Handovers and returns without a job are listed first. Every booking needs one.
2. Press **Schedule**: choose the kind, car, when, place, field staff and instructions.
3. Jobs, next three days: each with its field staff and whether they acknowledged it.
4. Change a job with **Assign**, **Reassign**, **Move** or **Cancel**.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate listing stops publishing until you decide.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves and block the car with the turnaround. For each car on Turo, press **This car is on Turo**, type its name exactly as Turo''s emails show it and press **Save**.
2. Under "Turo emails to check", an email the reader was not sure about: check the trip on Turo, then **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
4. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
5. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Handovers and returns without a job are listed first. Every booking needs one.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Schedule</b>: choose the kind, car, when, place, field staff and instructions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Jobs, next three days: each with its field staff and whether they acknowledged it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> or <b class="gd-ui">Cancel</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1180"><img src="/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1180"><span class="gd-pin" style="left:15.4%;top:10.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:78.9%;top:12.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:11.4%;top:68.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:78.9%;top:83.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate listing stops publishing until you decide.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Cover the plate</b>. Check the suggested box; <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves and block the car with the turnaround. For each car on Turo, press <b class="gd-ui">This car is on Turo</b>, type its name exactly as Turo&#39;s emails show it and press <b class="gd-ui">Save</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Under &quot;Turo emails to check&quot;, an email the reader was not sure about: check the trip on Turo, then <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div></section>');
select app.guide_release_0064('va', 'add-a-rental-by-hand', 'chapter', 'sales', 'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
3. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.
4. To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.
5. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card when the renter signs**.
6. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
7. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
8. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
', 'Add a rental by hand', 'Choose the car and dates, find the renter, price it, record how it is paid.',
  'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
3. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.
4. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
5. To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.
6. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card when the renter signs**.
7. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
8. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
9. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
',
  '<p class="gd-p">Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.</p><section class="gd-task" id="add-a-rental-by-hand-add-a-rental" data-gd-task><h2 class="gd-h2">Add a rental</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. Your home address must be in your profile first: until it is, the page asks for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner&#39;s car not yet on the fleet insurance policy is added by an Admin only.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b> or <b class="gd-ui">Charge the saved card when the renter signs</b>.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Add the rental</b>. The renter gets the confirmation email unless you tick <b class="gd-ui">Do not email the renter</b>.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.</div></aside></section>');
-- GUIDES 0064 END
