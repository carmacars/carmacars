-- 0480: renter extension offers, the new late fee and one turnaround buffer of 90 minutes
-- (docs/changes/2026-11-07-extend-offers.md). SCHEMA_MARKER 0483.
--
-- 1. Late fee, for new bookings and offers only: per started hour 17.5% of the booking's daily rate
--    (late_fee_hourly_bps 1750), at least $25 an hour (late_fee_hourly_min_cents 2500); the 30 minute grace and the cap
--    of 1.5 times the daily rate per 24 hours are unchanged. Every booking that exists when this runs keeps the flat
--    $25 it was given: its late fee term is frozen into booking_fee_terms first (app.freeze_late_fee_terms). A new
--    booking's term records the rate (booking_fee_terms.rate_bps) when it is confirmed; until then the policy of the day
--    it was booked applies. app.booking_fee_term gives every caller (the check-in charge, the handover, the agreement,
--    the emails) the booking's own hourly amount. A car's own late fee and a fee set by hand for one booking stay flat.
-- 2. Extend after the return time while the car is still out (app.booking_is_out, no return recorded): priced from
--    the original return time; the late charges keep adding up until the extension is paid; once paid the return time
--    moves, so the end-of-booking messages are sent again for the new time and T13 and T14 for the old time stop.
-- 3. Self-serve: a renter's request is approved at once (extension_auto_approve, on) when the car is free for the added
--    time with the buffer, there is no unpaid balance or there is a card on file, every driver's licence is valid to
--    the new return, the coverage lasts, the length is within the maximum and no deposit hold must be captured first.
--    Otherwise it is a request for customer service, as before.
-- 4. The price of an extension (app.preview_extension, also for a date the renter picks):
--    under a day: the booking's hourly late fee for each started hour, from the original return time and without the
--    grace, less extension_short_discount_bps (10%), and never more than one discounted day (then it is priced as a day);
--    a day or more: the rate card's duration tiers on the added days (the booking's daily, 3-day, weekly and monthly
--    rates), less extension_discount_bps (5%) on the rental charge, plus the per-day fees. Lead-time pricing never
--    applies. A booking billed to an insurer, an owner booking and a car switched off (vehicles.extension_offers) get no
--    offers and no discount: they are priced as before and staff approve them.
-- 5. app.extension_offers(booking): the six options (1 hour, 3 hours, 1 day, 3 days, 1 week, 1 month), each with its
--    new return, price, regular price, saving and, when the car is taken, the reason ("Booked from Tue 9:00 am",
--    "Blocked for maintenance"), plus "Available until". public.my_extension_offers and public.renter_extend_option
--    serve the renter portal.
-- 6. Turnaround buffer: booking_buffer_minutes (90) is the one time between trips; turnaround_buffer_minutes follows
--    it both ways, so every availability and conflict check (app.vehicle_is_available, the date conflicts, the
--    calendar sync, rentals added by hand) uses it before and after each trip. The calendar's clash ring now counts it
--    between two bookings, so a booking already closer than that is flagged, never changed.
-- No applied migration is edited.
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
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0480: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings
alter table program_settings
  add column if not exists late_fee_hourly_bps integer not null default 1750 check (late_fee_hourly_bps between 0 and 100000),
  add column if not exists late_fee_hourly_min_cents bigint not null default 2500 check (late_fee_hourly_min_cents >= 0),
  add column if not exists extension_short_discount_bps integer not null default 1000 check (extension_short_discount_bps between 0 and 10000),
  add column if not exists extension_discount_bps integer not null default 500 check (extension_discount_bps between 0 and 10000),
  add column if not exists extension_auto_approve boolean not null default true,
  add column if not exists booking_buffer_minutes integer not null default 90 check (booking_buffer_minutes between 0 and 2880);
comment on column program_settings.late_fee_hourly_bps is 'Late return fee per started hour, as a share of the booking''s daily rate (0480: 1750 = 17.5%). New bookings and offers only; a booking keeps the terms it was given.';
comment on column program_settings.late_fee_hourly_min_cents is 'Late return fee per started hour, at least this much (0480: $25).';
comment on column program_settings.extension_short_discount_bps is 'Extension of 1 or 3 hours: the hourly late fee for those hours less this share (0480: 10%), never more than one discounted day.';
comment on column program_settings.extension_discount_bps is 'Extension of a day or more: this share off the rental charge for the added days (0480: 5%).';
comment on column program_settings.extension_auto_approve is 'A renter''s extension is approved at once when the car is free, the licence valid and nothing unpaid without a card (0480). Off: customer service approves each one.';
comment on column program_settings.booking_buffer_minutes is 'The time between two trips on a car, in minutes (0480: 90), before and after each trip, in every availability and conflict check. turnaround_buffer_minutes follows it.';

-- one buffer: booking_buffer_minutes and turnaround_buffer_minutes are kept equal (whichever an Admin changes); runs
-- before program_settings_one_turnaround, which copies it into the cleaning block's minutes
create or replace function app.program_settings_one_buffer() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    -- a new dated row: the one of the two that was given (both default to 90) sets the other
    if new.booking_buffer_minutes = 90 and new.turnaround_buffer_minutes is distinct from 90 then
      new.booking_buffer_minutes := least(greatest(coalesce(new.turnaround_buffer_minutes, 0), 0), 2880);
    end if;
    new.turnaround_buffer_minutes := new.booking_buffer_minutes;
  elsif new.booking_buffer_minutes is distinct from old.booking_buffer_minutes then
    new.turnaround_buffer_minutes := new.booking_buffer_minutes;
  elsif new.turnaround_buffer_minutes is distinct from old.turnaround_buffer_minutes then
    new.booking_buffer_minutes := least(greatest(coalesce(new.turnaround_buffer_minutes, 0), 0), 2880);
  end if;
  return new;
end $$;
drop trigger if exists program_settings_a_buffer on program_settings;
create trigger program_settings_a_buffer before insert or update on program_settings
  for each row execute function app.program_settings_one_buffer();
alter table program_settings alter column turnaround_buffer_minutes set default 90;
update program_settings set booking_buffer_minutes = 90, turnaround_buffer_minutes = 90;
comment on column program_settings.turnaround_buffer_minutes is 'Follows booking_buffer_minutes (0480): the one time between trips, in minutes. After each trip it shows on the calendar as the cleaning block, which staff may remove to free the time.';

-- a car's own switch for the offers (on): off, its renters ask and staff approve, at the regular price
alter table vehicles add column if not exists extension_offers boolean not null default true;
comment on column vehicles.extension_offers is 'Extension offers for this car (0480): the six options at the extension discount, approved at once when free. Off: the renter asks and staff approve, at the regular price.';

-- the extension remembers what was offered
alter table booking_extensions
  add column if not exists option_code text check (option_code in ('1h', '3h', '1d', '3d', '1w', '1m')),
  add column if not exists pricing text check (pricing in ('short', 'days', 'regular', 'owner')),
  add column if not exists regular_total_cents bigint,
  add column if not exists auto_approved boolean not null default false;
comment on column booking_extensions.regular_total_cents is 'What the added time costs without the extension discount (0480), the price struck through.';
comment on column booking_extensions.auto_approved is 'Approved at once, by the rules of app.extension_auto_refusal (0480).';
-- a few added hours may not add a billable day; an extension after the return time is paid while the car is out,
-- before its new return
alter table booking_extensions drop constraint if exists booking_extensions_check1;
alter table booking_extensions add constraint booking_extensions_check1 check (new_days >= previous_days);
alter table booking_extensions drop constraint if exists booking_extensions_check2;
alter table booking_extensions add constraint booking_extensions_check2 check (status <> 'confirmed'
  or (paid_at is not null and confirmed_in_writing_at is not null and paid_at <= new_return_at and confirmed_in_writing_at <= new_return_at));

-- ================================================================ 1. the late fee
alter table booking_fee_terms add column if not exists rate_bps integer check (rate_bps between 0 and 100000);
comment on column booking_fee_terms.rate_bps is 'Late return fee only (0480): per started hour this share of the booking''s daily rate, at least amount_cents. Null: amount_cents flat (bookings before 0480, a car''s own fee, a fee set by hand).';

-- the booking's late fee per started hour, in cents (before HST)
alter function app.booking_fee_term(uuid, text) rename to booking_fee_term_pre0480;
create function app.booking_fee_term(p_booking uuid, p_fee text)
returns table(amount_cents bigint, cap_cents bigint, percent_bps integer, grace_minutes integer, source text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  t record;
  x booking_fee_terms;
  s program_settings;
  v_rate integer;
  v_daily bigint;
begin
  select * into t from app.booking_fee_term_pre0480(p_booking, p_fee);
  if p_fee = 'late_return_fee' then
    select * into x from booking_fee_terms k where k.booking_id = p_booking and k.fee_type_code = p_fee;
    if x.id is not null then
      v_rate := x.rate_bps;
    elsif t.source = 'default' then
      select y.* into s from bookings b cross join lateral app.settings(app.local_date(b.booked_at)) y where b.id = p_booking;
      v_rate := s.late_fee_hourly_bps;
      t.amount_cents := coalesce(s.late_fee_hourly_min_cents, t.amount_cents);
    end if;
    if v_rate is not null then
      select b.daily_rate_cents into v_daily from bookings b where b.id = p_booking;
      t.amount_cents := greatest(coalesce(t.amount_cents, 0), public.calc_bps(coalesce(v_daily, 0), v_rate));
    end if;
  end if;
  return query select t.amount_cents, t.cap_cents, t.percent_bps, t.grace_minutes, t.source;
end $$;
select pg_temp.copy_grants('app.booking_fee_term(uuid, text)'::regprocedure, 'app.booking_fee_term_pre0480(uuid, text)'::regprocedure);
revoke all on function app.booking_fee_term_pre0480(uuid, text) from public, anon, authenticated;
comment on function app.booking_fee_term(uuid, text) is 'A fee''s terms for a booking (0130); for late_return_fee (0480) amount_cents is the booking''s own late fee per started hour.';

create or replace function app.late_fee_hourly_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select coalesce(t.amount_cents, 0)::bigint from app.booking_fee_term(p_booking, 'late_return_fee') t
$$;
revoke all on function app.late_fee_hourly_cents(uuid) from public, anon, authenticated;

-- every booking that exists now keeps the flat late fee it was given (its terms as they were before 0480), before the
-- trigger below gives new terms the rate
create or replace function app.freeze_late_fee_terms() returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  perform set_config('app.late_fee_freeze', 'on', true);
  insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source, rate_bps)
  select b.id, 'late_return_fee', t.amount_cents, t.cap_cents, t.percent_bps, t.source, null
    from bookings b cross join lateral app.booking_fee_term_pre0480(b.id, 'late_return_fee') t
   where t.source is not null
     and not exists (select 1 from booking_fee_terms x where x.booking_id = b.id and x.fee_type_code = 'late_return_fee');
  get diagnostics n = row_count;
  perform set_config('app.late_fee_freeze', 'off', true);
  return n;
end $$;
revoke all on function app.freeze_late_fee_terms() from public, anon, authenticated;
select app.freeze_late_fee_terms();

-- a new booking's term is the policy of the day it was booked: the share of the daily rate, at least the minimum.
-- A car's own fee and a fee set by hand for the booking are flat.
create or replace function app.booking_fee_terms_late_rate() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare s program_settings;
begin
  if new.fee_type_code <> 'late_return_fee' then return new; end if;
  if new.source <> 'default' then
    new.rate_bps := null;
  elsif tg_op = 'INSERT' and new.rate_bps is null and coalesce(current_setting('app.late_fee_freeze', true), '') <> 'on' then
    select x.* into s from bookings b cross join lateral app.settings(app.local_date(b.booked_at)) x where b.id = new.booking_id;
    if s.id is not null then
      new.rate_bps := s.late_fee_hourly_bps;
      new.amount_cents := s.late_fee_hourly_min_cents;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists booking_fee_terms_late_rate on booking_fee_terms;
create trigger booking_fee_terms_late_rate before insert or update on booking_fee_terms
  for each row execute function app.booking_fee_terms_late_rate();

update fee_defaults set note = 'per started hour from the return time once over 30 minutes late: 17.5% of the daily rate, at least $25 (Program settings late_fee_hourly_bps and late_fee_hourly_min_cents; bookings before 0480 keep $25); max 1.5 x daily rate per 24 hours'
 where fee_type_code = 'late_return_fee' and vehicle_class is null and effective_to is null;

-- ================================================================ the buffer between trips
-- what keeps the car from staying out longer: the next booking (with the buffer before it) or the next block
create or replace function app.vehicle_free_until(p_vehicle uuid, p_from timestamptz, p_ignore_booking uuid default null)
returns table(free_until timestamptz, kind text, reason text, starts_at timestamptz)
language sql stable security definer set search_path = public, app as $$
  with t as (select make_interval(mins => coalesce(app.turnaround_minutes(p_vehicle), 0)) as buf),
  nx as (
    select b.pickup_at - t.buf as free_until, 'booking'::text as kind, null::text as reason, b.pickup_at as starts_at
      from bookings b cross join t
     where b.vehicle_id = p_vehicle and b.blocks_calendar and b.status in ('confirmed', 'on_rent')
       and b.id is distinct from p_ignore_booking and b.return_at + t.buf > p_from
    union all
    select greatest(c.starts_at, p_from), 'block', c.reason, c.starts_at
      from vehicle_calendar_blocks c
     where c.vehicle_id = p_vehicle and c.removed_at is null and c.booking_id is distinct from p_ignore_booking
       and (c.ends_at is null or c.ends_at > p_from))
  select greatest(nx.free_until, p_from), nx.kind, nx.reason, nx.starts_at from nx order by nx.free_until, nx.starts_at limit 1
$$;
revoke all on function app.vehicle_free_until(uuid, timestamptz, uuid) from public, anon, authenticated;

-- "Tue 9:00 am" within the week, else "Tue Nov 10, 9:00 am" (Toronto)
create or replace function app.ext_when(p_at timestamptz, p_now timestamptz default now()) returns text
language sql stable set search_path = public, app as $$
  select case when p_at < p_now + interval '6 days'
              then to_char(p_at at time zone 'America/Toronto', 'Dy') || ' ' || app.fmt_time(p_at)
              else to_char(p_at at time zone 'America/Toronto', 'Dy Mon FMDD') || ', ' || app.fmt_time(p_at) end
$$;

-- the calendar's clash ring: two bookings that take the car clash when they are closer than the buffer
select pg_temp.patch_fn('app.admin_calendar(timestamptz, timestamptz, uuid)'::regprocedure,
  'and o.s < e.f and o.f > e.s',
  'and o.s - case when e.x ->> ''type'' = ''booking'' and o.x ->> ''type'' = ''booking''
                              then make_interval(mins => coalesce(app.turnaround_minutes((veh ->> ''id'')::uuid), 0)) else interval ''0'' end < e.f
                and o.f + case when e.x ->> ''type'' = ''booking'' and o.x ->> ''type'' = ''booking''
                              then make_interval(mins => coalesce(app.turnaround_minutes((veh ->> ''id'')::uuid), 0)) else interval ''0'' end > e.s');
-- a date change's list of what it clashes with counts the buffer around the other bookings (its "available" already did)
select pg_temp.patch_fn('app.calendar_preview_change(uuid, jsonb, timestamptz)'::regprocedure,
  'where x.vehicle_id = v_vehicle and x.id <> p_booking and x.blocks_calendar and x.status in (''confirmed'', ''on_rent'')
             and x.pickup_at < v_return and x.return_at > v_pickup',
  'where x.vehicle_id = v_vehicle and x.id <> p_booking and x.blocks_calendar and x.status in (''confirmed'', ''on_rent'')
             and x.pickup_at - make_interval(mins => coalesce(app.turnaround_minutes(v_vehicle), 0)) < v_return
             and x.return_at + make_interval(mins => coalesce(app.turnaround_minutes(v_vehicle), 0)) > v_pickup');

-- ================================================================ 2 to 4. the extension
-- offers and their discounts apply: a renter-billed rental of a car with offers on
create or replace function app.extension_offer_priced(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select b.booking_type <> 'owner' and b.bill_to = 'renter' and not coalesce(b.dates_provisional, false)
         and coalesce((select v.extension_offers from vehicles v where v.id = b.vehicle_id), true)
$$;

-- the car is still with the renter: out (0430) and no return recorded
create or replace function app.booking_still_out(b bookings, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select b.checked_in_at is null and app.booking_is_out(b, p_now)
$$;

create or replace function app.preview_extension(p_booking uuid, p_new_return timestamptz, p_now timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_set program_settings := app.settings();
  v_booked program_settings;
  v_problems jsonb := '[]'::jsonb;
  v_new_days integer;
  x record;
  v_old jsonb; v_new jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_rental bigint := 0;
  v_disc bigint := 0;
  v_promo bigint := 0;
  v_fees bigint; v_hst bigint; v_fees_hst bigint;
  v_available boolean;
  v_capture boolean;
  v_offer boolean;
  v_pricing text;
  v_secs numeric;
  v_hours integer; v_days integer;
  v_hourly bigint := 0;
  v_short_regular bigint; v_short bigint;
  v_day_regular bigint; v_day bigint;
  v_regular bigint; v_disc_bps integer := 0;
  v_regular_total bigint;
  v_late_cost bigint;
  v_so_far bigint := 0;
  t record; l record;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  v_booked := app.settings(app.local_date(b.booked_at));
  if b.status not in ('confirmed', 'on_rent') then
    v_problems := v_problems || jsonb_build_object('code', 'not_extendable', 'message', format('A booking that is %s cannot be extended.', b.status));
  end if;
  if p_new_return is null or p_new_return <= b.return_at then
    v_problems := v_problems || jsonb_build_object('code', 'not_later', 'message', 'The new return must be after the current return.');
    return jsonb_build_object('ok', false, 'problems', v_problems, 'booking_id', b.id, 'previous_return_at', b.return_at, 'new_return_at', p_new_return);
  end if;
  -- 0480: after the return time, while the car is still out
  if p_now >= b.return_at and not app.booking_still_out(b, p_now) then
    v_problems := v_problems || jsonb_build_object('code', 'too_late', 'message', 'The return time has passed and the car is not out: it can no longer be extended.');
  end if;
  if p_new_return <= p_now then
    v_problems := v_problems || jsonb_build_object('code', 'new_return_passed', 'message', 'That new return time has already passed: choose a later one.');
  end if;
  v_new_days := public.calc_billable_days(b.pickup_at, p_new_return);
  if v_new_days > app.max_rental_days_now() then
    v_problems := v_problems || jsonb_build_object('code', 'over_maximum_length',
      'message', format('The total length stays at %s days or less.', app.max_rental_days_now()));
    return jsonb_build_object('ok', false, 'problems', v_problems, 'booking_id', b.id, 'previous_return_at', b.return_at,
                              'new_return_at', p_new_return, 'previous_days', b.billable_days, 'new_days', v_new_days);
  end if;
  v_offer := app.extension_offer_priced(b);
  v_secs := extract(epoch from (p_new_return - b.return_at));
  v_hours := ceil(v_secs / 3600)::integer;
  v_days := ceil(v_secs / 86400)::integer;

  if b.booking_type = 'owner' then
    v_pricing := 'owner';
  elsif v_offer then
    -- the offer: hours at the late fee less the short discount, never more than a discounted day; else the added days
    -- at the rate card's tier for that length less the extension discount. Priced from the current (original) return.
    v_hourly := app.late_fee_hourly_cents(b.id);
    v_short_regular := v_hourly * v_hours;
    v_short := v_short_regular - public.calc_bps(v_short_regular, v_set.extension_short_discount_bps);
    select r.rental_charge_cents into v_day_regular from public.calc_rental_charge(b.return_at, 1, b.daily_rate_cents, b.weekend_rate_cents,
           b.weekly_rate_cents, b.monthly_rate_cents, 'America/Toronto', b.multi_day_rate_cents) r;
    v_day := v_day_regular - public.calc_bps(v_day_regular, v_set.extension_discount_bps);
    if v_secs < 86400 and v_short <= v_day then
      v_pricing := 'short';
      v_regular := v_short_regular; v_rental := v_short; v_disc_bps := v_set.extension_short_discount_bps;
      v_lines := v_lines || app.price_line('rental_charge', v_hours, v_hourly, v_rental, b.hst_bps,
        format('Extension: %s %s', v_hours, case when v_hours = 1 then 'hour' else 'hours' end),
        null, jsonb_build_object('regular_cents', v_regular, 'discount_bps', v_disc_bps));
    else
      v_pricing := 'days';
      select r.rental_charge_cents into v_regular from public.calc_rental_charge(b.return_at, v_days, b.daily_rate_cents, b.weekend_rate_cents,
             b.weekly_rate_cents, b.monthly_rate_cents, 'America/Toronto', b.multi_day_rate_cents) r;
      v_disc_bps := v_set.extension_discount_bps;
      v_rental := v_regular - public.calc_bps(v_regular, v_disc_bps);
      -- the lower of the two methods: the added days at the tier less the discount, or the whole booking repriced at its
      -- new length less what was already charged (so a weekly renter never pays more than before)
      select * into x from public.calc_extension(b.pickup_at, b.billable_days, v_new_days,
                                                 b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
      if x.rental_difference_cents is not null and x.rental_difference_cents >= 0 and x.rental_difference_cents < v_rental then
        v_rental := x.rental_difference_cents;
        v_disc_bps := case when v_regular > 0 then round(10000.0 * (v_regular - v_rental) / v_regular)::integer else 0 end;
      end if;
      v_lines := v_lines || app.price_line('rental_charge', v_days, null, v_rental, b.hst_bps,
        format('Extension: %s added %s', v_days, case when v_days = 1 then 'day' else 'days' end),
        null, jsonb_build_object('regular_cents', v_regular, 'discount_bps', v_disc_bps));
    end if;
  else
    -- no offer (an insurer, a car switched off): the whole booking repriced at its new length, as before 0480
    v_pricing := 'regular';
    select * into x from public.calc_extension(b.pickup_at, b.billable_days, v_new_days,
                                               b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents);
    v_rental := x.rental_difference_cents;
    if b.booking_type = 'non_refundable' then
      v_disc := public.calc_bps(b.rental_charge_cents + v_rental, v_booked.non_refundable_discount_bps) - b.discount_cents;
    end if;
    if b.promo_code_id is not null then
      v_promo := coalesce(app.promo_discount_cents(b.promo_code_id,
                   b.rental_charge_cents + v_rental - (b.discount_cents + v_disc) - b.staff_discount_cents, v_new_days), 0) - b.promo_discount_cents;
    end if;
    if v_rental <> 0 then v_lines := v_lines || app.price_line('rental_charge', 1, v_rental, v_rental, b.hst_bps, 'Rental charge for the added time'); end if;
    if v_disc <> 0 then v_lines := v_lines || app.price_line('non_refundable_discount', 1, -v_disc, -v_disc, b.hst_bps); end if;
    if v_promo <> 0 then v_lines := v_lines || app.price_line('promo_discount', 1, -v_promo, -v_promo, b.hst_bps); end if;
    v_regular := v_rental;
  end if;
  -- per-day fees, each up to its cap for the whole rental (not for a few hours priced as hours)
  if v_pricing in ('days', 'regular') then
    v_old := app.price_lines(app.booking_price_spec(p_booking, jsonb_build_object('managed', true, 'recompute_rental', true)));
    v_new := app.price_lines(app.booking_price_spec(p_booking, jsonb_build_object('managed', true, 'return_at', p_new_return)));
    select v_lines || coalesce(jsonb_agg(app.price_line(n.value ->> 'charge_type', 1,
                                  (n.value ->> 'amount_cents')::bigint - coalesce((o.value ->> 'amount_cents')::bigint, 0),
                                  (n.value ->> 'amount_cents')::bigint - coalesce((o.value ->> 'amount_cents')::bigint, 0),
                                  b.hst_bps, n.value ->> 'description', (n.value ->> 'driver_id')::uuid, n.value -> 'detail') order by n.ord), '[]'::jsonb)
      into v_lines
      from jsonb_array_elements(v_new -> 'lines') with ordinality n(value, ord)
      left join jsonb_array_elements(v_old -> 'lines') o(value)
        on o.value ->> 'charge_type' = n.value ->> 'charge_type' and (o.value ->> 'driver_id') is not distinct from (n.value ->> 'driver_id')
     where n.value ->> 'charge_type' in ('young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat')
       and (n.value ->> 'amount_cents')::bigint <> coalesce((o.value ->> 'amount_cents')::bigint, 0);
  end if;
  select coalesce(sum((l2.value ->> 'amount_cents')::bigint) filter (where l2.value ->> 'charge_type' not in ('rental_charge', 'non_refundable_discount', 'promo_discount')), 0),
         coalesce(sum((l2.value ->> 'hst_cents')::bigint), 0),
         coalesce(sum((l2.value ->> 'hst_cents')::bigint) filter (where l2.value ->> 'charge_type' not in ('rental_charge', 'non_refundable_discount', 'promo_discount')), 0)
    into v_fees, v_hst, v_fees_hst from jsonb_array_elements(v_lines) l2;
  v_regular_total := coalesce(v_regular, 0) + v_fees + public.calc_hst(coalesce(v_regular, 0), b.hst_bps) + v_fees_hst;

  -- what being that late would cost instead: the late fee and the rental of each extra day, with HST
  if v_pricing = 'short' then
    select * into t from app.booking_fee_term(b.id, 'late_return_fee');
    select * into l from public.calc_late_return(v_hours * 60, b.daily_rate_cents, coalesce(t.amount_cents, 0), coalesce(t.percent_bps, 15000), coalesce(t.grace_minutes, 30));
    v_late_cost := l.late_fee_cents + l.extra_days_cents + public.calc_hst(l.late_fee_cents + l.extra_days_cents, b.hst_bps);
  end if;
  -- late so far (after the return time): owed until the extension is paid
  if p_now > b.return_at and b.booking_type <> 'owner' then
    select * into t from app.booking_fee_term(b.id, 'late_return_fee');
    select * into l from public.calc_late_return(floor(extract(epoch from (p_now - b.return_at)) / 60)::integer, b.daily_rate_cents,
                                                 coalesce(t.amount_cents, 0), coalesce(t.percent_bps, 15000), coalesce(t.grace_minutes, 30));
    v_so_far := l.late_fee_cents + l.extra_days_cents;
  end if;

  v_available := not b.blocks_calendar or app.vehicle_is_available(b.vehicle_id, b.return_at, p_new_return, b.id);
  if not v_available then
    v_problems := v_problems || jsonb_build_object('code', 'not_available', 'message', 'The car is booked or blocked for part of the added time.');
  end if;
  v_capture := v_new_days > v_set.deposit_hold_max_days
               and exists (select 1 from deposits d where d.booking_id = p_booking and d.method = 'card_hold' and d.status = 'held');
  return jsonb_build_object('ok', jsonb_array_length(v_problems) = 0, 'problems', v_problems, 'booking_id', b.id,
    'previous_return_at', b.return_at, 'new_return_at', p_new_return, 'previous_days', b.billable_days, 'new_days', v_new_days,
    'previous_rental_charge_cents', b.rental_charge_cents, 'new_rental_charge_cents', b.rental_charge_cents + v_rental,
    'rental_difference_cents', v_rental, 'fees_difference_cents', v_fees + (-v_disc) + (-v_promo), 'hst_cents', v_hst,
    'total_cents', v_rental - v_disc - v_promo + v_fees + v_hst, 'lines', v_lines, 'available', v_available,
    'km_allowance_total', b.km_allowance_per_day * v_new_days,
    'deposit_hold_capture_needed', v_capture,
    -- 0480
    'pricing', v_pricing, 'offer', v_offer, 'added_hours', v_hours, 'added_days', v_days, 'hourly_late_fee_cents', v_hourly,
    'regular_rental_cents', v_regular, 'discount_bps', v_disc_bps, 'regular_total_cents', v_regular_total,
    'save_cents', greatest(v_regular_total - (v_rental - v_disc - v_promo + v_fees + v_hst), 0),
    'late_cost_cents', v_late_cost, 'late_so_far_cents', v_so_far, 'late', p_now > b.return_at);
end $$;

-- why a request is not approved at once (null: approve it now)
create or replace function app.extension_auto_refusal(p_booking uuid, p_preview jsonb) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_until date;
begin
  select * into b from bookings where id = p_booking;
  v_until := app.local_date((p_preview ->> 'new_return_at')::timestamptz);
  return case
    when not (app.settings()).extension_auto_approve then 'Self-serve approval is off'
    when not coalesce((p_preview ->> 'offer')::boolean, false) then 'No offers for this booking (insurer, owner booking or the car''s offers off)'
    when not coalesce((p_preview ->> 'ok')::boolean, false) then coalesce(p_preview -> 'problems' -> 0 ->> 'message', 'Not available')
    when coalesce((p_preview ->> 'deposit_hold_capture_needed')::boolean, false) then 'The deposit hold must be captured first'
    when b.card_on_file_id is null and coalesce(app.booking_part_open(b.id, 'balance'), 0) > 0 then 'An unpaid balance and no card on file'
    when exists (select 1 from booking_drivers d where d.booking_id = b.id and (d.licence_expiry is null or d.licence_expiry < v_until))
      or (not exists (select 1 from booking_drivers d where d.booking_id = b.id)
          and not exists (select 1 from drivers d where d.renter_id = b.renter_id and d.is_account_holder and d.licence_expiry >= v_until))
      then 'A licence expires before the new return'
    when exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status = 'confirmed' and c.coverage_option = 1
                    and c.policy_expiry < v_until) then 'The coverage ends before the new return'
  end;
end $$;

create or replace function app.request_extension(p_booking uuid, p_by uuid, p_new_return timestamptz, p_note text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v jsonb;
  v_id uuid;
  v_refusal text;
  v_auto boolean;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null then raise exception 'Booking % not found', p_booking; end if;
  if p_by is null or not (app.is_booking_renter(p_booking, p_by) or app.user_is_staff(p_by)) then
    raise exception 'Only the renter of this booking, or staff, asks for an extension' using errcode = '42501';
  end if;
  if exists (select 1 from booking_extensions e where e.booking_id = p_booking and e.status in ('requested', 'approved')) then
    raise exception 'An extension request is already open on booking %', b.booking_number using errcode = '23514';
  end if;
  v := app.preview_extension(p_booking, p_new_return);
  if not (v ->> 'ok')::boolean then
    raise exception '%', v -> 'problems' -> 0 ->> 'message' using errcode = '23514';
  end if;
  -- 0480: self-serve, approved at once when nothing needs a person
  v_refusal := app.extension_auto_refusal(p_booking, v);
  v_auto := v_refusal is null;
  insert into booking_extensions (booking_id, seq, status, previous_return_at, new_return_at, previous_days, new_days,
      previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, fees_difference_cents, hst_cents, total_cents,
      requested_by, note, lines, pricing, regular_total_cents, auto_approved, approved_at)
  values (p_booking, (select coalesce(max(e.seq), 0) + 1 from booking_extensions e where e.booking_id = p_booking),
      case when v_auto then 'approved' else 'requested' end,
      b.return_at, p_new_return, b.billable_days, (v ->> 'new_days')::integer,
      (v ->> 'previous_rental_charge_cents')::bigint, (v ->> 'new_rental_charge_cents')::bigint, (v ->> 'rental_difference_cents')::bigint,
      (v ->> 'fees_difference_cents')::bigint, (v ->> 'hst_cents')::bigint, (v ->> 'total_cents')::bigint,
      p_by, nullif(btrim(coalesce(p_note, '')), ''), v -> 'lines', v ->> 'pricing', (v ->> 'regular_total_cents')::bigint, v_auto,
      case when v_auto then now() end)
  returning id into v_id;
  perform app.log_booking_event(p_booking, 'extension', b.status::text, b.status::text, null, p_note, p_by, null,
    jsonb_build_object('extension_id', v_id, 'step', case when v_auto then 'approved_at_once' else 'requested' end,
                       'new_return_at', p_new_return, 'total_cents', (v ->> 'total_cents')::bigint, 'review_reason', v_refusal));
  if v_auto then
    -- the renter pays in the same panel; the confirmation follows the payment
    return v_id;
  end if;
  -- customer service's task (review_extension) is raised by the booking_extensions trigger of migration 0020
  perform app.emit_event('renter_extension_requested', 'booking_extension', v_id,
    jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'new_return_at', p_new_return,
                       'previous_return_at', b.return_at, 'total_cents', (v ->> 'total_cents')::bigint),
    'renter_extension_requested:' || v_id || ':requested');
  perform app.emit_event('staff_extension_requested', 'booking_extension', v_id,
    jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'new_return_at', p_new_return,
                       'previous_return_at', b.return_at, 'total_cents', (v ->> 'total_cents')::bigint, 'review_reason', v_refusal),
    'staff_extension_requested:' || v_id || ':requested');
  return v_id;
end $$;

-- staff approval keeps the offer's price (app.preview_extension prices both the same way); the pay-by time is the
-- current return, or the new one when the car is already late
select pg_temp.patch_fn('app.approve_extension(uuid, uuid)'::regprocedure,
  '''total_cents'', (v ->> ''total_cents'')::bigint, ''pay_before'', e.previous_return_at)',
  '''total_cents'', (v ->> ''total_cents'')::bigint, ''pay_before'', case when e.previous_return_at > now() then e.previous_return_at else e.new_return_at end)');
select pg_temp.patch_fn('app.approve_extension(uuid, uuid)'::regprocedure,
  'hst_cents = (v ->> ''hst_cents'')::bigint, total_cents = (v ->> ''total_cents'')::bigint, lines = v -> ''lines''',
  'hst_cents = (v ->> ''hst_cents'')::bigint, total_cents = (v ->> ''total_cents'')::bigint, lines = v -> ''lines'',
         pricing = v ->> ''pricing'', regular_total_cents = (v ->> ''regular_total_cents'')::bigint');

-- paid after the return time while the car is still out (before the new return) confirms it
select pg_temp.patch_fn('app.confirm_extension_payment(uuid, jsonb, bigint, timestamptz, uuid)'::regprocedure,
  'when p_at > e.previous_return_at or b.return_at <> e.previous_return_at then ''lapsed''',
  'when b.return_at <> e.previous_return_at or p_at >= e.new_return_at
         or (p_at > e.previous_return_at and not app.booking_still_out(b, p_at)) then ''lapsed''');
select pg_temp.patch_fn('app.confirm_extension_payment(uuid, jsonb, bigint, timestamptz, uuid)'::regprocedure,
  'when ''lapsed'' then ''The extension was not paid before the return time. It has lapsed.''',
  'when ''lapsed'' then ''The extension was not paid in time (before the return, or while the car was still out). It has lapsed.''');

-- an open extension lapses at the current return time, unless the car is still out and its new return is ahead
create or replace function app.lapse_extensions(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  update booking_extensions e set status = 'lapsed'
    from bookings b
   where b.id = e.booking_id and e.status in ('requested', 'approved') and e.previous_return_at <= p_now
     and (e.new_return_at <= p_now or b.return_at <> e.previous_return_at or not app.booking_still_out(b, p_now));
  get diagnostics n = row_count;
  return n;
end $$;

-- ================================================================ 5. the offers
create or replace function app.extension_offers(p_booking uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  s program_settings := app.settings();
  f record;
  o record;
  p jsonb;
  v_new timestamptz;
  v_reason text;
  v_why text;
  v_opts jsonb := '[]'::jsonb;
  v_fallback text;
  v_card jsonb;
  v_open jsonb;
  v_late jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  v_why := case
    when b.status not in ('confirmed', 'on_rent') then 'This booking cannot be extended.'
    when p_now >= b.return_at and not app.booking_still_out(b, p_now) then 'The return time has passed.'
    when b.booking_type = 'owner' then 'An owner booking is extended by our team.'
    when b.bill_to <> 'renter' or coalesce(b.dates_provisional, false) then 'Your insurer arranges extensions of this rental: ask us below and we will sort it out.'
    when not app.extension_offer_priced(b) then 'Extensions of this car are arranged by our team: ask us below.'
  end;
  select * into f from app.vehicle_free_until(b.vehicle_id, b.return_at, b.id);
  select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4) into v_card from payment_methods pm where pm.id = b.card_on_file_id;
  select jsonb_build_object('id', e.id, 'status', e.status, 'new_return_at', e.new_return_at, 'total_cents', e.total_cents,
                            'regular_total_cents', e.regular_total_cents, 'option_code', e.option_code, 'auto_approved', e.auto_approved)
    into v_open from booking_extensions e where e.booking_id = b.id and e.status in ('requested', 'approved') order by e.seq desc limit 1;
  if v_why is null then
    for o in select * from (values ('1h', '1 hour', interval '1 hour', 1), ('3h', '3 hours', interval '3 hours', 2),
                                   ('1d', '1 day', interval '1 day', 3), ('3d', '3 days', interval '3 days', 4),
                                   ('1w', '1 week', interval '7 days', 5), ('1m', '1 month', interval '30 days', 6)) t(code, label, span, ord) order by ord loop
      v_new := b.return_at + o.span;
      p := app.preview_extension(b.id, v_new, p_now);
      v_fallback := null;
      -- a few hours that would cost more than a day: the day is offered instead
      if o.code in ('1h', '3h') and p ->> 'pricing' = 'days' then
        v_fallback := '1d';
      end if;
      v_reason := null;
      if not coalesce((p ->> 'ok')::boolean, false) then
        if exists (select 1 from jsonb_array_elements(p -> 'problems') x where x ->> 'code' = 'not_available') then
          v_reason := case
            when f.kind = 'booking' then 'Booked from ' || app.ext_when(f.starts_at, p_now)
            when f.reason in ('service', 'repair') then 'Blocked for maintenance'
            when f.reason = 'cleaning' then 'Blocked for cleaning'
            when f.reason = 'external_booking' then 'Booked from ' || app.ext_when(f.starts_at, p_now)
            when f.reason in ('owner_unavailable', 'turo_owner_use') then 'The owner has the car from ' || app.ext_when(f.starts_at, p_now)
            when f.reason = 'exit' then 'The car leaves the fleet ' || app.ext_when(f.starts_at, p_now)
            else 'Not available from ' || app.ext_when(coalesce(f.starts_at, b.return_at), p_now) end;
        elsif exists (select 1 from jsonb_array_elements(p -> 'problems') x where x ->> 'code' = 'over_maximum_length') then
          v_reason := 'Longer than the longest rental';
        elsif exists (select 1 from jsonb_array_elements(p -> 'problems') x where x ->> 'code' = 'new_return_passed') then
          v_reason := 'That time has already passed';
        else
          v_reason := coalesce(p -> 'problems' -> 0 ->> 'message', 'Not available');
        end if;
      end if;
      v_opts := v_opts || jsonb_build_object('code', o.code, 'label', o.label, 'new_return_at', v_new, 'available', v_reason is null,
        'reason', v_reason, 'pricing', p ->> 'pricing', 'fallback_to', v_fallback,
        'total_cents', (p ->> 'total_cents')::bigint, 'regular_total_cents', (p ->> 'regular_total_cents')::bigint,
        'save_cents', (p ->> 'save_cents')::bigint,
        'save_pct', case when coalesce((p ->> 'regular_total_cents')::bigint, 0) > 0
                         then round(100.0 * (p ->> 'save_cents')::bigint / (p ->> 'regular_total_cents')::bigint)::integer else 0 end,
        'late_cost_cents', (p ->> 'late_cost_cents')::bigint, 'hours', (p ->> 'added_hours')::integer, 'days', (p ->> 'added_days')::integer);
    end loop;
  end if;
  if p_now > b.return_at and b.booking_type <> 'owner' then
    p := app.preview_extension(b.id, greatest(b.return_at, p_now) + interval '1 hour', p_now);
    v_late := jsonb_build_object('minutes', floor(extract(epoch from (p_now - b.return_at)) / 60)::integer, 'owed_cents', (p ->> 'late_so_far_cents')::bigint);
  end if;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'return_at', b.return_at, 'now', p_now,
    'offers', v_why is null, 'message', v_why, 'options', v_opts,
    'discount_bps', s.extension_discount_bps, 'short_discount_bps', s.extension_short_discount_bps,
    'hourly_late_fee_cents', app.late_fee_hourly_cents(b.id),
    'available_until', case when f.free_until is not null and f.free_until < b.return_at + interval '30 days' then f.free_until end,
    'available_until_text', case when f.free_until is not null and f.free_until < b.return_at + interval '30 days'
                                 then 'Available until ' || app.ext_when(f.free_until, p_now) end,
    'late', v_late, 'card', v_card, 'open', v_open);
end $$;

-- a renter's option: the new return of that option (a few hours that cost more than a day become the day)
create or replace function app.request_extension_option(p_booking uuid, p_by uuid, p_option text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  o jsonb;
  v_id uuid;
  e booking_extensions;
  v_code text;
begin
  select x into o from jsonb_array_elements(coalesce(app.extension_offers(p_booking, p_now) -> 'options', '[]'::jsonb)) x where x ->> 'code' = p_option;
  if o is null then raise exception 'That extension is not offered for this booking' using errcode = '22023'; end if;
  v_code := coalesce(o ->> 'fallback_to', p_option);
  if v_code <> p_option then
    select x into o from jsonb_array_elements(app.extension_offers(p_booking, p_now) -> 'options') x where x ->> 'code' = v_code;
  end if;
  if not coalesce((o ->> 'available')::boolean, false) then
    raise exception '%', coalesce(o ->> 'reason', 'Not available') using errcode = '23514';
  end if;
  v_id := app.request_extension(p_booking, p_by, (o ->> 'new_return_at')::timestamptz, null);
  update booking_extensions set option_code = v_code where id = v_id returning * into e;
  return jsonb_build_object('extension_id', e.id, 'status', e.status, 'auto_approved', e.auto_approved, 'option_code', v_code,
                            'new_return_at', e.new_return_at, 'total_cents', e.total_cents, 'regular_total_cents', e.regular_total_cents);
end $$;

-- "Extend at 5% off: from $X for 1 more day" (the renter's end-of-booking messages), else a plain Extend line
create or replace function app.extension_offer_line(p_booking uuid, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb;
  d jsonb;
begin
  begin
    x := app.extension_offers(p_booking, p_now);
  exception when others then x := null;
  end;
  if x is not null and coalesce((x ->> 'offers')::boolean, false) then
    select o into d from jsonb_array_elements(x -> 'options') o where o ->> 'code' = '1d' and (o ->> 'available')::boolean;
    if d is not null and (x ->> 'discount_bps')::integer > 0 then
      return format('Extend at %s off: from %s for 1 more day', rtrim(rtrim(to_char((x ->> 'discount_bps')::numeric / 100, 'FM990.99'), '0'), '.') || '%',
                    app.fmt_money((d ->> 'total_cents')::numeric));
    end if;
  end if;
  return 'Need more time? Extend';
end $$;

-- the renter's end-of-booking messages carry the offer
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0480;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x jsonb := coalesce(app.ntf_payload_pre0480(p_code, p_event, p_to), '{}'::jsonb);
begin
  if p_code in ('renter_return_soon', 'renter_return_due') then
    x := x || jsonb_build_object('extend_offer', app.extension_offer_line(
      coalesce(nullif(x ->> 'booking_id', '')::uuid, case when p_event.entity = 'booking' then p_event.entity_id end)));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0480(text, app_events, jsonb)'::regprocedure);

-- ================================================================ the renter portal
create or replace function public.my_extension_offers(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_my_booking(p_booking);
  return app.extension_offers(p_booking);
end $$;
select pg_temp.copy_grants('public.my_extension_offers(uuid)'::regprocedure, 'public.my_extension_preview(uuid, timestamptz)'::regprocedure);

create or replace function public.renter_extend_option(p_booking uuid, p_by uuid, p_option text) returns jsonb
language plpgsql set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.request_extension_option(p_booking, p_by, p_option);
end $$;
select pg_temp.copy_grants('public.renter_extend_option(uuid, uuid, text)'::regprocedure, 'public.renter_request_extension(uuid, uuid, timestamptz, text)'::regprocedure);

-- ================================================================ a car's switch (Fleet > car > Edit details)
select pg_temp.patch_fn('app.admin_do_0030(uuid, text, jsonb)'::regprocedure,
  '''owner_pickup_address'')) then',
  '''owner_pickup_address'', ''extension_offers'')) then');
select pg_temp.patch_fn('app.admin_do_0030(uuid, text, jsonb)'::regprocedure,
  'bookings_enabled = coalesce(x.bookings_enabled, v.bookings_enabled),',
  'bookings_enabled = coalesce(x.bookings_enabled, v.bookings_enabled), extension_offers = coalesce(x.extension_offers, v.extension_offers),');

-- ================================================================ the public numbers ({{lateHr}}, the FAQ)
create or replace function public.site_facts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.site_facts_pre0280() || jsonb_build_object('phone_gate', app.phone_gate_rules())
    || (select jsonb_build_object('late_fee_hourly_bps', s.late_fee_hourly_bps, 'late_fee_hourly_min_cents', s.late_fee_hourly_min_cents,
                                  'extension_discount_bps', s.extension_discount_bps, 'extension_short_discount_bps', s.extension_short_discount_bps,
                                  'booking_buffer_minutes', s.booking_buffer_minutes)
          from app.settings() s)
$$;

revoke all on function app.extension_offer_priced(bookings), app.booking_still_out(bookings, timestamptz), app.extension_auto_refusal(uuid, jsonb),
  app.extension_offers(uuid, timestamptz), app.request_extension_option(uuid, uuid, text, timestamptz), app.extension_offer_line(uuid, timestamptz),
  app.ext_when(timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function app.late_fee_hourly_cents(uuid), app.freeze_late_fee_terms(), app.vehicle_free_until(uuid, timestamptz, uuid),
  app.extension_offer_priced(bookings), app.booking_still_out(bookings, timestamptz), app.extension_auto_refusal(uuid, jsonb),
  app.extension_offers(uuid, timestamptz), app.request_extension_option(uuid, uuid, text, timestamptz), app.extension_offer_line(uuid, timestamptz),
  app.ext_when(timestamptz, timestamptz) to service_role;
