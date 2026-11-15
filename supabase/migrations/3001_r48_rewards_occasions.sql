-- 3001 (release 48): birthday and holiday rewards by tier (docs/changes/2026-11-14-r48-rewards-notices.md).
--
-- The owner, Nov 14: the second tier gets a discount on the renter's birthday and on holidays, the top tier a bigger one.
--   1. Per tier (Admin > Settings > Rewards, Birthday and holiday rewards): a birthday percent and a holiday percent with
--      an on/off. Defaults: Gold (the second tier: Member is the first) 10%, Platinum (between) 15%, Black (the top) 20%.
--      Program switches for each kind, the birthday window (7 days either side), the notice days (14 and 10).
--   2. The birthday: the licence date of birth when we have it, else the month and day the renter gave (Account > Profile
--      or the Rewards page; the year is optional). 29 February is 28 February in other years.
--   3. The holidays (reward_holidays, editable): New Year's Day, Family Day, Good Friday, Victoria Day, Canada Day, Civic
--      Holiday, Labour Day, Thanksgiving, Christmas Day, Boxing Day, each by its date rule. The window is the holiday
--      weekend: a Monday holiday from the Saturday, a Friday or Saturday holiday to the Sunday or Monday, otherwise the day
--      before to the day after.
--   4. The money: a pickup in a window gives one line "Birthday reward -10%" or "Holiday reward -10%" (a minus sign) off
--      the rental charge, before tax, never stacked (the bigger wins, the birthday on a tie). Never below the car's lowest
--      daily price (1205: the discount stops there), never on an Owner Booking, a booking billed to an insurer, a Turo trip
--      or a price staff typed. Quotes for the signed-in renter show it; a request or an offer locks it on the booking
--      (bookings.occasion_kind, occasion_bps) as lead-time pricing does (0360), so the offer and the payment keep it. It
--      counts with the rental charge everywhere (owner revenue, commissions, the split, refunds), as a promo code does.
--   5. Notices (marketing, with the unsubscribe link): renter_rewards_birthday 14 days before, renter_rewards_holiday 10
--      days before each holiday weekend, to renters of a tier with that reward on.
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3001: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings, tiers, the birthday, the holidays
alter table rewards_settings
  add column if not exists birthday_reward_enabled boolean not null default true,
  add column if not exists holiday_reward_enabled boolean not null default true,
  add column if not exists birthday_window_days integer not null default 7 check (birthday_window_days between 0 and 30),
  add column if not exists birthday_notice_days integer not null default 14 check (birthday_notice_days between 1 and 60),
  add column if not exists holiday_notice_days integer not null default 10 check (holiday_notice_days between 1 and 60);
comment on column rewards_settings.birthday_reward_enabled is 'r48 (3001): the birthday reward (a percent off the rental charge by tier) for a pickup near the renter''s birthday.';
comment on column rewards_settings.holiday_reward_enabled is 'r48 (3001): the holiday reward (a percent off the rental charge by tier) for a pickup on a holiday weekend (reward_holidays).';
comment on column rewards_settings.birthday_window_days is 'r48 (3001): a pickup this many days either side of the birthday gets the birthday reward.';
comment on column rewards_settings.birthday_notice_days is 'r48 (3001): "Your birthday reward is waiting" this many days before the birthday.';
comment on column rewards_settings.holiday_notice_days is 'r48 (3001): "Holiday reward" this many days before the holiday weekend starts.';

alter table reward_tiers
  add column if not exists birthday_bps integer not null default 0 check (birthday_bps between 0 and 5000),
  add column if not exists holiday_bps integer not null default 0 check (holiday_bps between 0 and 5000),
  add column if not exists occasion_enabled boolean not null default true;
comment on column reward_tiers.birthday_bps is 'r48 (3001): the birthday reward of the tier, basis points off the rental charge (Gold 1000, Platinum 1500, Black 2000).';
comment on column reward_tiers.holiday_bps is 'r48 (3001): the holiday reward of the tier, basis points off the rental charge (Gold 1000, Platinum 1500, Black 2000).';
comment on column reward_tiers.occasion_enabled is 'r48 (3001): the tier''s birthday and holiday rewards on or off.';
update reward_tiers set birthday_bps = 1000, holiday_bps = 1000 where code = 'gold';
update reward_tiers set birthday_bps = 1500, holiday_bps = 1500 where code = 'platinum';
update reward_tiers set birthday_bps = 2000, holiday_bps = 2000 where code = 'black';

alter table renters
  add column if not exists birthday_month smallint check (birthday_month between 1 and 12),
  add column if not exists birthday_day smallint check (birthday_day between 1 and 31),
  add column if not exists birthday_year smallint check (birthday_year between 1900 and 2100);
alter table renters add constraint renters_birthday_shape check ((birthday_month is null) = (birthday_day is null)
  and (birthday_year is null or birthday_month is not null)
  and (birthday_day is null or birthday_day <= (array[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])[birthday_month]));
comment on column renters.birthday_month is 'r48 (3001): the birthday the renter gave (month and day, the year optional) for the Rewards birthday; the licence date of birth wins when we have it.';

create table if not exists reward_holidays (
  code        text primary key check (code ~ '^[a-z][a-z0-9_]{1,30}$'),
  name        text not null check (length(btrim(name)) between 2 and 60),
  kind        text not null check (kind in ('fixed', 'nth_weekday', 'weekday_before', 'easter')),
  month       smallint check (month between 1 and 12),
  day         smallint check (day between 1 and 31),
  isodow      smallint check (isodow between 1 and 7),
  nth         smallint check (nth between 1 and 5),
  offset_days smallint not null default 0 check (offset_days between -60 and 60),
  enabled     boolean not null default true,
  sort        integer not null default 0,
  updated_by  uuid references users (id) on delete set null,
  updated_at  timestamptz not null default now(),
  check (kind = 'easter' or month is not null),
  check (kind <> 'fixed' or day is not null),
  check (kind <> 'nth_weekday' or (isodow is not null and nth is not null)),
  check (kind <> 'weekday_before' or (isodow is not null and day is not null))
);
create index if not exists reward_holidays_updated_by_idx on reward_holidays (updated_by) where updated_by is not null;
comment on table reward_holidays is 'r48 (3001): the holidays of the Rewards holiday reward, each by a date rule: fixed (month, day), nth_weekday (the nth isodow of the month), weekday_before (the last isodow before month/day), easter (Easter Sunday plus offset_days).';
insert into reward_holidays (code, name, kind, month, day, isodow, nth, offset_days, sort) values
  ('new_year', 'New Year''s Day', 'fixed', 1, 1, null, null, 0, 1),
  ('family_day', 'Family Day', 'nth_weekday', 2, null, 1, 3, 0, 2),
  ('good_friday', 'Good Friday', 'easter', null, null, null, null, -2, 3),
  ('victoria_day', 'Victoria Day', 'weekday_before', 5, 25, 1, null, 0, 4),
  ('canada_day', 'Canada Day', 'fixed', 7, 1, null, null, 0, 5),
  ('civic_holiday', 'Civic Holiday', 'nth_weekday', 8, null, 1, 1, 0, 6),
  ('labour_day', 'Labour Day', 'nth_weekday', 9, null, 1, 1, 0, 7),
  ('thanksgiving', 'Thanksgiving', 'nth_weekday', 10, null, 1, 2, 0, 8),
  ('christmas', 'Christmas Day', 'fixed', 12, 25, null, null, 0, 9),
  ('boxing_day', 'Boxing Day', 'fixed', 12, 26, null, null, 0, 10)
on conflict (code) do nothing;
alter table reward_holidays enable row level security;
create policy admin_all on reward_holidays for select to authenticated using (app.is_admin());
revoke all on reward_holidays from anon, authenticated;
grant all on reward_holidays to service_role;
create trigger audit_reward_holidays after insert or update or delete on reward_holidays for each row execute function app.audit_row();

-- ================================================================ 2. the dates
-- Easter Sunday (the Gregorian computus)
create function app.easter_sunday(y integer) returns date
language plpgsql immutable as $$
declare a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int;
begin
  a := y % 19; b := y / 100; c := y % 100; d := b / 4; e := b % 4; f := (b + 8) / 25; g := (b - f + 1) / 3;
  h := (19 * a + b - d - g + 15) % 30; i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  return make_date(y, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
end $$;

create function app.reward_holiday_on(h reward_holidays, y integer) returns date
language plpgsql immutable as $$
declare d date;
begin
  if h.kind = 'fixed' then
    d := make_date(y, h.month, least(h.day, extract(day from (make_date(y, h.month, 1) + interval '1 month' - interval '1 day'))::int));
  elsif h.kind = 'nth_weekday' then
    d := make_date(y, h.month, 1);
    d := d + ((h.isodow - extract(isodow from d)::int + 7) % 7) + 7 * (h.nth - 1);
    if extract(month from d) <> h.month then d := d - 7; end if;
  elsif h.kind = 'weekday_before' then
    d := make_date(y, h.month, h.day) - 1;
    d := d - ((extract(isodow from d)::int - h.isodow + 7) % 7);
  else
    d := app.easter_sunday(y);
  end if;
  return d + h.offset_days;
end $$;

-- the holiday weekend around a holiday: a Monday from the Saturday, a Friday or Saturday to the Sunday or Monday after, a
-- Sunday from the Saturday to the Monday, otherwise the day before to the day after
create function app.reward_holiday_window(d date) returns daterange
language sql immutable as $$
  select case extract(isodow from d)::int
           when 1 then daterange(d - 2, d, '[]')
           when 5 then daterange(d, d + 2, '[]')
           when 6 then daterange(d, d + 2, '[]')
           else daterange(d - 1, d + 1, '[]') end
$$;

-- every enabled holiday whose window touches the days asked for
create function app.reward_holidays_between(p_from date, p_to date)
returns table (code text, name text, on_date date, w_from date, w_to date)
language sql stable security definer set search_path = public, app as $$
  select h.code, h.name, x.d, lower(x.w), upper(x.w) - 1
    from reward_holidays h
    cross join lateral generate_series(extract(year from p_from)::int - 1, extract(year from p_to)::int + 1) gs(y)
    cross join lateral (select app.reward_holiday_on(h, gs.y) d) d0
    cross join lateral (select d0.d, app.reward_holiday_window(d0.d) w) x
   where h.enabled and lower(x.w) <= p_to and upper(x.w) - 1 >= p_from
   order by lower(x.w), h.sort
$$;

-- the renter's birthday in a year: the licence date of birth first, else the one they gave
create function app.renter_birthday_on(p_renter uuid, p_year integer) returns date
language sql stable security definer set search_path = public, app as $$
  select case when m = 2 and d = 29 and not (p_year % 4 = 0 and (p_year % 100 <> 0 or p_year % 400 = 0)) then make_date(p_year, 2, 28)
              else make_date(p_year, m, d) end
    from (select coalesce(extract(month from r.date_of_birth)::int, r.birthday_month::int) m, coalesce(extract(day from r.date_of_birth)::int, r.birthday_day::int) d
            from renters r where r.id = p_renter) x
   where m is not null and d is not null
$$;

-- the words of the line
create function app.occasion_text(p_kind text, p_bps integer) returns text
language sql immutable as $$
  select case when p_kind = 'birthday' then 'Birthday reward ' else 'Holiday reward ' end || chr(8722) || app.fmt_pct(p_bps)
$$;

-- the reward for a renter's pickup: {kind, bps, label, name, from, to} or null (the bigger of the two, the birthday on a tie)
create function app.rewards_occasion(p_renter uuid, p_pickup timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s rewards_settings := app.rewards();
  t reward_tiers;
  v_on date := app.local_date(p_pickup);
  v_b date;
  v_bday jsonb;
  v_hol jsonb;
  h record;
  y int;
begin
  if p_renter is null or p_pickup is null or not coalesce(s.enabled, false) then return null; end if;
  if not exists (select 1 from renters r where r.id = p_renter and not coalesce(r.is_blocked, false) and r.merged_into is null) then return null; end if;
  t := app.rewards_tier_of(p_renter);
  if t.code is null or t.code = 'member' or not t.active or not t.occasion_enabled then return null; end if;
  if s.birthday_reward_enabled and t.birthday_bps > 0 then
    for y in extract(year from v_on)::int - 1 .. extract(year from v_on)::int + 1 loop
      v_b := app.renter_birthday_on(p_renter, y);
      exit when v_b is null;
      if abs(v_on - v_b) <= s.birthday_window_days then
        v_bday := jsonb_build_object('kind', 'birthday', 'bps', t.birthday_bps, 'label', app.occasion_text('birthday', t.birthday_bps), 'name', 'Birthday',
                                     'from', v_b - s.birthday_window_days, 'to', v_b + s.birthday_window_days);
        exit;
      end if;
    end loop;
  end if;
  if s.holiday_reward_enabled and t.holiday_bps > 0 then
    select * into h from app.reward_holidays_between(v_on, v_on) limit 1;
    if h.code is not null then
      v_hol := jsonb_build_object('kind', 'holiday', 'bps', t.holiday_bps, 'label', app.occasion_text('holiday', t.holiday_bps), 'name', h.name,
                                  'holiday', h.code, 'from', h.w_from, 'to', h.w_to);
    end if;
  end if;
  if v_bday is not null and (v_hol is null or (v_bday ->> 'bps')::int >= (v_hol ->> 'bps')::int) then return v_bday; end if;
  return v_hol;
end $$;

-- ================================================================ 3. the money
insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, stage, refundable_by_tier, change_default, change_vehicle,
                       change_booking, in_master_spec, sort_order, gl_account)
select 'occasion_discount', 'Rewards birthday or holiday reward: a percentage off the rental charge', 'rental', 'percent', 'rental',
       f.revenue_class, f.hst_applies, 'booking', f.refundable_by_tier, false, false, false, false, 15, f.gl_account
  from fee_types f where f.code = 'rental_charge'
on conflict (code) do nothing;

alter table bookings
  add column if not exists occasion_kind text check (occasion_kind in ('birthday', 'holiday')),
  add column if not exists occasion_bps integer check (occasion_bps between 0 and 5000),
  add column if not exists occasion_locked_at timestamptz;
comment on column bookings.occasion_kind is 'r48 (3001): the Rewards birthday or holiday reward locked on this booking when the request or the offer was made (null: none).';
comment on column bookings.occasion_bps is 'r48 (3001): the percent of that reward, in basis points off the rental charge.';

-- the line, after the rental lines and before the car's price limits: p.occasion {kind, bps} is what the caller decided
-- (a quote: the signed-in renter now; a booking: its own). The discount never takes the rental a day below the car's
-- lowest daily price, nor the rental below zero after the other discounts.
create function app.price_lines_occasion(v jsonb, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o jsonb := case when jsonb_typeof(p -> 'occasion') = 'object' then p -> 'occasion' end;
  v_bps integer := coalesce(nullif(o ->> 'bps', '')::integer, 0);
  v_rental bigint := coalesce((v ->> 'rental_charge_cents')::bigint, 0);
  v_days integer := greatest(coalesce((v ->> 'billable_days')::integer, 1), 1);
  v_net bigint;
  v_lo bigint;
  v_amt bigint;
  v_hst integer := coalesce((p ->> 'hst_bps')::integer, 0);
  v_lines jsonb;
  v_sub bigint;
  v_tax bigint;
begin
  if o is null or v_bps <= 0 or o ->> 'kind' not in ('birthday', 'holiday') or v_rental <= 0 then return v; end if;
  if coalesce(p ->> 'booking_type', 'standard') = 'owner' or coalesce((p ->> 'insurer_billed')::boolean, false) then return v; end if;
  select coalesce(sum((x.value ->> 'amount_cents')::bigint), 0) into v_net
    from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)) x(value)
   where x.value ->> 'charge_type' in ('rental_charge', 'lead_time', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount');
  v_amt := least(public.calc_bps(v_rental, v_bps), greatest(v_net, 0));
  if nullif(p ->> 'vehicle_id', '') is not null and not coalesce((p ->> 'price_limit_override')::boolean, false) then
    v_lo := (app.price_limits_for((p ->> 'vehicle_id')::uuid) ->> 'min_daily_cents')::bigint;
    if v_lo is not null then v_amt := least(v_amt, greatest(v_net - v_lo * v_days, 0)); end if;
  end if;
  if v_amt <= 0 then return v; end if;
  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),
         coalesce(sum((x.value ->> 'amount_cents')::bigint), 0), coalesce(sum((x.value ->> 'hst_cents')::bigint), 0)
    into v_lines, v_sub, v_tax
    from jsonb_array_elements(coalesce(v -> 'lines', '[]'::jsonb)
           || jsonb_build_array(app.price_line('occasion_discount', 1, -v_amt, -v_amt, v_hst, app.occasion_text(o ->> 'kind', v_bps), null,
                                               jsonb_build_object('kind', o ->> 'kind', 'bps', v_bps, 'name', o ->> 'name'))))
         with ordinality x(value, ord);
  return v || jsonb_build_object('lines', v_lines, 'subtotal_cents', v_sub, 'hst_cents', v_tax, 'total_cents', v_sub + v_tax,
                                 'occasion_cents', -v_amt, 'occasion_label', app.occasion_text(o ->> 'kind', v_bps), 'occasion_kind', o ->> 'kind');
end $$;

select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$v jsonb := app.price_lines_pre1205(p);$o$, $n$v jsonb := app.price_lines_occasion(app.price_lines_pre1205(p), p);   -- 3001$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$'staff_discount', 'promo_discount', 'discount');$o$, $n$'staff_discount', 'promo_discount', 'discount', 'occasion_discount');$n$);

-- every list of the lines that make the rental counts the line with the rental charge (as 1205 did for price_limit)
do $$
declare f text;
begin
  foreach f in array array['app.sync_booking_price(uuid)', 'app.preview_booking_change(uuid, jsonb)', 'app.commission_line_types()',
                           'app.booking_split_parts(uuid)', 'app.booking_line_allocation(uuid)', 'app.booking_part_open_raw(uuid, text)',
                           'app.booking_tie_lines_raw(uuid, text, uuid)', 'app.apply_line_overrides(jsonb, jsonb, integer)',
                           'app.public_site_facts()', 'app.snapshot_booking_fee_terms(uuid)', 'app.compute_booking_split_pre0156(uuid)',
                           'app.preview_extension_pre1201(uuid, timestamptz, timestamptz)', 'app.put_price_line(uuid, jsonb)'] loop
    perform pg_temp.patch_fn(f::regprocedure, $o$'lead_time', 'price_limit'$o$, $n$'lead_time', 'price_limit', 'occasion_discount'$n$);
  end loop;
end $$;
select pg_temp.patch_fn('app.offer_revert_prepare(uuid, jsonb)'::regprocedure,
  $o$not in ('rental_charge', 'lead_time', 'non_refundable_discount'$o$, $n$not in ('rental_charge', 'lead_time', 'occasion_discount', 'non_refundable_discount'$n$);

-- A quote's reward: the signed-in renter's (staff pricing: the renter the offer is for); none for an Owner Booking, a
-- price staff typed, an insurer's booking, or when the caller says so ('occasion': 'none').
create function app.quote_occasion(p_vehicle uuid, p_pickup timestamptz, o jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_staff boolean := coalesce(current_setting('app.staff_pricing', true), '') = 'on';
begin
  if coalesce(o ->> 'booking_type', 'standard') = 'owner' or coalesce(o ->> 'occasion', '') = 'none' or nullif(o ->> 'insurer_id', '') is not null
     or (v_staff and nullif(o ->> 'staff_rental_charge_cents', '') is not null) then
    return null;
  end if;
  return app.rewards_occasion(case when v_staff then nullif(o ->> 'renter_id', '')::uuid else app.my_renter_id() end, p_pickup);
end $$;
select pg_temp.patch_fn('app.price_quote_pre1202(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$'lead_time_hours', app.lead_time_hours(p_pickup),$o$,
  $n$'lead_time_hours', app.lead_time_hours(p_pickup),
    'occasion', app.quote_occasion(p_vehicle, p_pickup, o),   -- 3001$n$);

-- a booking's price uses the reward it locked; a price typed by hand has none
alter function app.booking_price_spec(uuid, jsonb) rename to booking_price_spec_pre3001;
create function app.booking_price_spec(p_booking uuid, p_changes jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.booking_price_spec_pre3001(p_booking, p_changes) ||
           case when b.custom_price_at is not null or b.price_tax is not null or (p_changes ->> 'rental_charge_cents') is not null
                     or b.occasion_kind is null or coalesce(b.occasion_bps, 0) = 0 then '{}'::jsonb
                else jsonb_build_object('occasion', jsonb_build_object('kind', b.occasion_kind, 'bps', b.occasion_bps,
                                        'name', case when b.occasion_kind = 'birthday' then 'Birthday' else 'Holiday' end)) end
    from bookings b where b.id = p_booking
$$;
select pg_temp.copy_grants('app.booking_price_spec(uuid, jsonb)'::regprocedure, 'app.booking_price_spec_pre3001(uuid, jsonb)'::regprocedure);

-- locked when the request or the offer is made (an Owner Booking, a placeholder, an insurer's booking and a Turo trip never)
create function app.bookings_occasion_lock() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare o jsonb;
begin
  if new.booking_type::text <> 'owner' and new.status::text in ('requested', 'offered') and new.occasion_locked_at is null
     and not coalesce(new.is_placeholder, false) and new.renter_id is not null and new.insurer_id is null and new.pickup_at is not null
     and coalesce(new.source, '') <> 'turo' then
    o := app.rewards_occasion(new.renter_id, new.pickup_at);
    new.occasion_locked_at := now();
    if o is not null then
      new.occasion_kind := o ->> 'kind';
      new.occasion_bps := (o ->> 'bps')::integer;
    end if;
  end if;
  return new;
end $$;
create trigger bookings_occasion_lock before insert on bookings for each row execute function app.bookings_occasion_lock();

-- ================================================================ 4. the notices: 14 days before the birthday, 10 before a holiday weekend
alter function app.job_rewards_notices(timestamptz) rename to job_rewards_notices_pre3001;
create function app.job_rewards_notices(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.job_rewards_notices_pre3001(p_now);
  s rewards_settings := app.rewards();
  v_local timestamp := p_now at time zone 'America/Toronto';
  v_today date := (p_now at time zone 'America/Toronto')::date;
  r record;
  h record;
  t reward_tiers;
  v_b date;
  n_b int := 0; n_h int := 0;
begin
  if not s.enabled or not s.notices_enabled or extract(hour from v_local) not between 10 and 19 then return v; end if;
  if s.birthday_reward_enabled and app.rewards_notice_on('renter_rewards_birthday') then
    for r in select x.renter_id from reward_accounts x join renters rn on rn.id = x.renter_id
              where coalesce(extract(month from rn.date_of_birth)::int, rn.birthday_month::int) is not null loop
      v_b := app.renter_birthday_on(r.renter_id, extract(year from v_today)::int);
      if v_b is not null and v_b < v_today then v_b := app.renter_birthday_on(r.renter_id, extract(year from v_today)::int + 1); end if;
      continue when v_b is null or v_b - v_today > s.birthday_notice_days or v_b - v_today < 1;
      continue when exists (select 1 from app_events e where e.dedupe_key = 'renter_rewards_birthday:' || r.renter_id || ':' || extract(year from v_b));
      t := app.rewards_tier_of(r.renter_id);
      continue when t.code is null or t.code = 'member' or not t.occasion_enabled or t.birthday_bps <= 0;
      if app.rewards_notice_emit('renter_rewards_birthday', r.renter_id, extract(year from v_b)::text, jsonb_build_object(
           'reward_pct', app.fmt_pct(t.birthday_bps), 'tier_name', t.name,
           'window_from', app.fmt_day(v_b - s.birthday_window_days), 'window_to', app.fmt_day(v_b + s.birthday_window_days))) is not null then n_b := n_b + 1; end if;
    end loop;
  end if;
  if s.holiday_reward_enabled and app.rewards_notice_on('renter_rewards_holiday') then
    -- holidays whose weekends touch (Christmas and Boxing Day) are one email, named for the first, to the last day
    for h in select x.code, x.name, x.w_from,
                    (select max(y.w_to) from app.reward_holidays_between(x.w_from, x.w_to + 1) y where y.w_from >= x.w_from and y.w_from <= x.w_to + 1) w_to
               from app.reward_holidays_between(v_today + 1, v_today + s.holiday_notice_days) x
              where x.w_from > v_today and x.w_from <= v_today + s.holiday_notice_days
                and not exists (select 1 from app.reward_holidays_between(x.w_from - 1, x.w_from - 1) z where z.w_from < x.w_from) loop
      for r in select x.renter_id from reward_accounts x loop
        continue when exists (select 1 from app_events e where e.dedupe_key = 'renter_rewards_holiday:' || r.renter_id || ':' || h.code || ':' || h.w_from);
        t := app.rewards_tier_of(r.renter_id);
        continue when t.code is null or t.code = 'member' or not t.occasion_enabled or t.holiday_bps <= 0;
        if app.rewards_notice_emit('renter_rewards_holiday', r.renter_id, h.code || ':' || h.w_from, jsonb_build_object(
             'holiday_name', h.name, 'reward_pct', app.fmt_pct(t.holiday_bps), 'tier_name', t.name,
             'window_from', app.fmt_day(h.w_from), 'window_to', app.fmt_day(h.w_to))) is not null then n_h := n_h + 1; end if;
      end loop;
    end loop;
  end if;
  return v || jsonb_build_object('birthdays', n_b, 'holidays', n_h);
end $$;

-- ================================================================ 5. the renter: the birthday, and what the rewards are
create function public.rewards_mine_birthday(p_month integer, p_day integer, p_year integer default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_renter uuid := app.rewards_renter_of(app.uid());
begin
  if v_renter is null then raise exception 'Your birthday is saved with your renter details, after your first booking request' using errcode = '42501'; end if;
  if p_month is null and p_day is null then
    update renters set birthday_month = null, birthday_day = null, birthday_year = null where id = v_renter;
    return jsonb_build_object('saved', false);
  end if;
  if p_month is null or p_day is null or p_month not between 1 and 12 or p_day < 1 or p_day > (array[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])[p_month] then
    raise exception 'Choose a real month and day' using errcode = '22023';
  end if;
  if p_year is not null and (p_year < 1900 or p_year > extract(year from app.today())::int - 16
                             or (p_month = 2 and p_day = 29 and not (p_year % 4 = 0 and (p_year % 100 <> 0 or p_year % 400 = 0)))) then
    raise exception 'Check the year, or leave it empty' using errcode = '22023';
  end if;
  update renters set birthday_month = p_month, birthday_day = p_day, birthday_year = p_year where id = v_renter;
  return jsonb_build_object('saved', true, 'month', p_month, 'day', p_day, 'year', p_year);
end $$;
revoke all on function public.rewards_mine_birthday(integer, integer, integer) from public, anon;
grant execute on function public.rewards_mine_birthday(integer, integer, integer) to authenticated, service_role;

alter function app.rewards_state(uuid) rename to rewards_state_pre3001;
create function app.rewards_state(p_renter uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.rewards_state_pre3001(p_renter);
  s rewards_settings := app.rewards();
  rn renters;
  t reward_tiers;
  v_b date;
begin
  if p_renter is null or not coalesce((v ->> 'renter')::boolean, false) then return v; end if;
  select * into rn from renters where id = p_renter;
  t := app.rewards_tier_of(p_renter);
  v_b := app.renter_birthday_on(p_renter, extract(year from app.today())::int);
  return v || jsonb_build_object(
    'birthday', jsonb_build_object('month', coalesce(extract(month from rn.date_of_birth)::int, rn.birthday_month), 'day', coalesce(extract(day from rn.date_of_birth)::int, rn.birthday_day),
                                   'year', case when rn.date_of_birth is null then rn.birthday_year end, 'from_licence', rn.date_of_birth is not null,
                                   'label', case when v_b is not null then to_char(v_b, 'FMMonth FMDD') end),
    'occasions', jsonb_build_object(
      'birthday_pct', case when s.birthday_reward_enabled and t.code <> 'member' and t.occasion_enabled and t.birthday_bps > 0 then app.fmt_pct(t.birthday_bps) end,
      'holiday_pct', case when s.holiday_reward_enabled and t.code <> 'member' and t.occasion_enabled and t.holiday_bps > 0 then app.fmt_pct(t.holiday_bps) end,
      'window_days', s.birthday_window_days,
      'tiers', (select coalesce(jsonb_agg(jsonb_build_object('name', x.name, 'birthday_pct', case when x.occasion_enabled and x.birthday_bps > 0 and s.birthday_reward_enabled then app.fmt_pct(x.birthday_bps) end,
                  'holiday_pct', case when x.occasion_enabled and x.holiday_bps > 0 and s.holiday_reward_enabled then app.fmt_pct(x.holiday_bps) end) order by x.min_points), '[]'::jsonb)
                from reward_tiers x where x.active and x.code <> 'member'),
      'holidays', case when s.holiday_reward_enabled then (select coalesce(jsonb_agg(jsonb_build_object('name', h.name, 'from', h.w_from, 'to', h.w_to) order by h.w_from), '[]'::jsonb)
                  from (select * from app.reward_holidays_between(app.today(), app.today() + 120) limit 4) h) else '[]'::jsonb end));
end $$;
select pg_temp.copy_grants('app.rewards_state(uuid)'::regprocedure, 'app.rewards_state_pre3001(uuid)'::regprocedure);

-- ================================================================ 6. Admin > Settings > Rewards: the birthday and holiday rewards
create function app.rewards_occasions_admin(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare s rewards_settings := app.rewards();
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('birthday_enabled', s.birthday_reward_enabled, 'holiday_enabled', s.holiday_reward_enabled,
    'birthday_window_days', s.birthday_window_days, 'birthday_notice_days', s.birthday_notice_days, 'holiday_notice_days', s.holiday_notice_days,
    'tiers', (select coalesce(jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name, 'birthday_bps', t.birthday_bps, 'holiday_bps', t.holiday_bps,
                'enabled', t.occasion_enabled) order by t.min_points), '[]'::jsonb) from reward_tiers t where t.active and t.code <> 'member'),
    'holidays', (select coalesce(jsonb_agg(jsonb_build_object('code', h.code, 'name', h.name, 'kind', h.kind, 'month', h.month, 'day', h.day, 'isodow', h.isodow,
                   'nth', h.nth, 'offset_days', h.offset_days, 'enabled', h.enabled,
                   'next', (select jsonb_build_object('on', x.on_date, 'from', x.w_from, 'to', x.w_to) from app.reward_holidays_between(app.today(), app.today() + 400) x
                             where x.code = h.code order by x.w_from limit 1)) order by h.sort, h.code), '[]'::jsonb) from reward_holidays h),
    'bookings_30d', (select count(*) from bookings b where b.occasion_kind is not null and b.created_at > now() - interval '30 days'));
end $$;

create function app.rewards_occasions_admin_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text := nullif(btrim(coalesce(p ->> 'code', '')), '');
  h reward_holidays;
begin
  perform app.assert_admin(p_by);
  if p_name = 'rewards_occasion_save' then
    update rewards_settings set birthday_reward_enabled = coalesce((p ->> 'birthday_enabled')::boolean, birthday_reward_enabled),
           holiday_reward_enabled = coalesce((p ->> 'holiday_enabled')::boolean, holiday_reward_enabled),
           birthday_window_days = coalesce((p ->> 'birthday_window_days')::int, birthday_window_days),
           birthday_notice_days = coalesce((p ->> 'birthday_notice_days')::int, birthday_notice_days),
           holiday_notice_days = coalesce((p ->> 'holiday_notice_days')::int, holiday_notice_days), updated_by = p_by, updated_at = now() where singleton;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'rewards_settings', 'singleton', p);
  elsif p_name = 'rewards_occasion_tier_save' then
    update reward_tiers set birthday_bps = coalesce((p ->> 'birthday_bps')::int, birthday_bps), holiday_bps = coalesce((p ->> 'holiday_bps')::int, holiday_bps),
           occasion_enabled = coalesce((p ->> 'enabled')::boolean, occasion_enabled)
     where code = v_code and active and code <> 'member';
    if not found then raise exception 'Unknown tier' using errcode = 'P0002'; end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'reward_tiers', v_code, p);
  elsif p_name = 'rewards_holiday_save' then
    if coalesce((p ->> 'remove')::boolean, false) then
      delete from reward_holidays where code = v_code returning * into h;
      if h.code is null then raise exception 'Unknown holiday' using errcode = 'P0002'; end if;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, before) values (p_by, p_name, 'reward_holidays', v_code, to_jsonb(h));
      return app.rewards_occasions_admin(p_by);
    end if;
    if v_code is null then
      v_code := left(regexp_replace(lower(btrim(coalesce(p ->> 'name', ''))), '[^a-z0-9]+', '_', 'g'), 30);
      v_code := btrim(v_code, '_');
      if v_code !~ '^[a-z]' then v_code := 'h_' || v_code; end if;
    end if;
    insert into reward_holidays (code, name, kind, month, day, isodow, nth, offset_days, enabled, sort, updated_by)
    values (v_code, coalesce(nullif(btrim(p ->> 'name'), ''), (select name from reward_holidays where code = v_code)),
            coalesce(nullif(p ->> 'kind', ''), (select kind from reward_holidays where code = v_code), 'fixed'),
            nullif(p ->> 'month', '')::smallint, nullif(p ->> 'day', '')::smallint, nullif(p ->> 'isodow', '')::smallint, nullif(p ->> 'nth', '')::smallint,
            coalesce(nullif(p ->> 'offset_days', '')::smallint, 0), coalesce((p ->> 'enabled')::boolean, true),
            coalesce((select sort from reward_holidays where code = v_code), (select coalesce(max(sort), 0) + 1 from reward_holidays)), p_by)
    on conflict (code) do update set name = excluded.name, kind = excluded.kind,
      month = case when p ? 'month' then excluded.month else reward_holidays.month end, day = case when p ? 'day' then excluded.day else reward_holidays.day end,
      isodow = case when p ? 'isodow' then excluded.isodow else reward_holidays.isodow end, nth = case when p ? 'nth' then excluded.nth else reward_holidays.nth end,
      offset_days = case when p ? 'offset_days' then excluded.offset_days else reward_holidays.offset_days end,
      enabled = case when p ? 'enabled' then excluded.enabled else reward_holidays.enabled end, updated_by = p_by, updated_at = now();
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, p_name, 'reward_holidays', v_code, p);
  else
    raise exception 'Unknown rewards call %', p_name using errcode = '22023';
  end if;
  return app.rewards_occasions_admin(p_by);
exception when check_violation or not_null_violation then
  raise exception 'Each holiday needs a name and its date rule: a month and day, the nth weekday of a month, the weekday before a date, or Easter with days before or after' using errcode = '22023';
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3001;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb;
begin
  if p_call = 'admin_read' and p_name = 'rewards' then
    v := app.door_pre3001(p_user, p_aal, p_call, p_name, p);
    return v || jsonb_build_object('occasions', app.rewards_occasions_admin(p_user));
  end if;
  if p_call = 'admin_do' and p_name in ('rewards_occasion_save', 'rewards_occasion_tier_save', 'rewards_holiday_save') then
    perform app.door_begin(p_user, p_aal);
    return app.rewards_occasions_admin_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3001(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3001(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 7. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['easter_sunday', 'reward_holiday_on', 'reward_holiday_window', 'reward_holidays_between', 'renter_birthday_on',
             'occasion_text', 'rewards_occasion', 'price_lines_occasion', 'quote_occasion', 'booking_price_spec_pre3001', 'bookings_occasion_lock',
             'job_rewards_notices', 'job_rewards_notices_pre3001', 'rewards_state_pre3001', 'rewards_occasions_admin', 'rewards_occasions_admin_do', 'door_pre3001'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
