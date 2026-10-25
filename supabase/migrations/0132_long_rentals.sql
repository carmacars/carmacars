-- 0132: long rentals, monthly agreements, the monthly rate, every fee editable, split payments
-- (docs/changes/2026-10-24-long-rentals.md)
--
-- The owner, October 24, 2026, entering a rental picked up the day before: "It won't let me put in the dates cuz the
-- maximum days are 31 or something. In reality people should be able to book more than a month but a new rental
-- agreement should be generated for each month automatically. That being said the monthly discount is not being
-- applied. And then I can adjust the monthly rate but cannot adjust the young driver fee or protection plan price. I'm
-- trying to input how it was paid and I can only write out one payment method per booking when the guy actually paid
-- his deposit in e-transfer and his rental in cash. This whole process just isn't smooth."
--
-- 1. Long rentals. The pricing engine took 1 to 30 days and every booking path refused more ("Longer stays renew with a
--    new booking", a renewal nothing ever made). Now: the renter's request takes up to Program settings, Longest
--    booking (max_rental_days, 365 by default); staff (rentals added by hand, offers, quotes, changes) up to the staff
--    limit (staff_max_rental_days, 730). A rental already underway (picked up yesterday) was already accepted (0074).
-- 2. The monthly rate. 30 days or more is priced at the car's monthly rate for each 30 days (the monthly rate divided
--    by 30, times the days), on the renter's quote, the request, the offer, the quick rental form and every preview:
--    the same engine (public.calc_rental_charge). 7 to 29 days stays the weekly rate capped at the monthly rate.
-- 3. Monthly periods. A rental longer than one period (30 days from the pickup by default, or calendar months) is cut into
--    periods (app.rental_periods): priced and listed on Add a rental and the offer screen; the per-day fees with a cap per
--    rental (young driver, additional driver, winter tire, baby seat) and a Protection Plan priced per rental apply their
--    cap per period. Each period's own agreement and invoice come in the next migration.
-- 4. Every fee line editable. A line set by hand for one booking (booking_line_overrides): young driver, additional
--    driver, Protection Plan, delivery and pickup, winter tire, baby seat, each add-on. Admin, and customer service and
--    sales while Program settings, Staff may change fees, is on (the staff who may type a rental price). On the quick
--    rental form, the offer screen and an existing booking (before and after confirmation); each change recorded with
--    who, when, before and after (booking_fee_changes) and in the booking's history.
-- 5. Split payments on the quick rental form: the rental paid in parts (cash and e-Transfer, for example), the deposit
--    its own way with its own reference, in the same call.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0132: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists staff_max_rental_days integer not null default 730 check (staff_max_rental_days between 1 and 3660),
  add column if not exists long_rental_period_days integer not null default 30 check (long_rental_period_days between 7 and 31),
  add column if not exists long_rental_cycle text not null default 'days' check (long_rental_cycle in ('days', 'calendar_month')),
  add column if not exists long_rental_agreement_lead_days integer not null default 3 check (long_rental_agreement_lead_days between 0 and 14),
  add column if not exists long_rental_autocharge boolean not null default true,
  add column if not exists staff_may_edit_fees boolean not null default true;
alter table program_settings alter column max_rental_days set default 365;
update program_settings set max_rental_days = 365 where max_rental_days <= 30;
comment on column program_settings.max_rental_days is 'Longest booking a renter may request online, in days (0132: 365 by default; longer than one period is cut into monthly periods, each with its own agreement and invoice).';
comment on column program_settings.staff_max_rental_days is 'Longest rental staff may enter or offer, in days (0132). The longer of this and max_rental_days applies to staff.';
comment on column program_settings.long_rental_period_days is 'A rental longer than this is cut into periods of this many days from the pickup, each with its own agreement and invoice (0132). Used when the cycle is days.';
comment on column program_settings.long_rental_cycle is 'How a long rental is cut (0132): days (periods of long_rental_period_days from the pickup) or calendar_month (the same day each month).';
comment on column program_settings.long_rental_agreement_lead_days is 'The next period''s agreement and invoice are made this many days before it starts (0132).';
comment on column program_settings.long_rental_autocharge is 'Charge the card on file for each later period of a long rental when its invoice is due (0132); off: Finance collects each one.';
comment on column program_settings.staff_may_edit_fees is 'Customer service and sales may change a fee line on one booking (young driver, Protection Plan, delivery, add-ons), with the change recorded (0132). Admins always may.';

-- the longest booking for whoever is asking: staff (the door marks the session) or a renter
create or replace function app.max_rental_days_now() returns integer
language sql stable security definer set search_path = public, app as $$
  select case when coalesce(current_setting('app.staff_pricing', true), '') = 'on'
              then greatest(s.max_rental_days, s.staff_max_rental_days) else s.max_rental_days end
    from app.settings() s
$$;

-- the door marks a staff session, so the staff limit and the staff-only pricing inputs apply to it alone
select pg_temp.patch_fn('app.door_begin(uuid, text)'::regprocedure,
  $o$  v_staff := app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user);$o$,
  $n$  v_staff := app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user);
  perform set_config('app.staff_pricing', case when v_staff then 'on' else '' end, true);   -- 0132$n$);

-- ================================================================ 2. periods and the monthly rate
-- The periods a rental is cut into: one when it fits in a period; otherwise periods of the set length (or calendar
-- months) from the pickup, the last one shorter. Days are billable days (24 hours from the pickup on the Toronto clock).
create or replace function app.rental_periods(p_pickup timestamptz, p_return timestamptz)
returns table (seq integer, starts_at timestamptz, ends_at timestamptz, days integer)
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_len integer := coalesce(s.long_rental_period_days, 30);
  v_from timestamptz := p_pickup;
  v_to timestamptz;
  i integer := 0;
begin
  if p_pickup is null or p_return is null or p_return <= p_pickup then return; end if;
  loop
    i := i + 1;
    v_to := case when s.long_rental_cycle = 'calendar_month'
                 then ((p_pickup at time zone 'America/Toronto') + make_interval(months => i)) at time zone 'America/Toronto'
                 else ((p_pickup at time zone 'America/Toronto') + make_interval(days => v_len * i)) at time zone 'America/Toronto' end;
    if v_to >= p_return or i >= 400 then
      seq := i; starts_at := v_from; ends_at := p_return; days := public.calc_billable_days(v_from, p_return);
      return next; return;
    end if;
    seq := i; starts_at := v_from; ends_at := v_to; days := public.calc_billable_days(v_from, v_to);
    return next;
    v_from := v_to;
  end loop;
end $$;

-- A per-day fee with a cap per rental, its cap applied to each period of a long rental (one period: as before).
create or replace function app.calc_capped_periods(p_rate_cents bigint, p_pickup timestamptz, p_return timestamptz, p_cap_cents bigint, p_units integer default 1)
returns bigint language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(public.calc_capped_per_day(p_rate_cents, x.days, p_cap_cents, p_units)), 0)::bigint from app.rental_periods(p_pickup, p_return) x
$$;

-- 30 days or more: the monthly rate for each 30 days (the monthly rate divided by 30, times the days); no upper bound here
-- (the booking paths apply the longest booking).
select pg_temp.patch_fn('public.calc_rental_charge(timestamptz, integer, bigint, bigint, bigint, bigint, text)'::regprocedure,
  $o$  if p_days < 1 or p_days > 30 then
    raise exception 'A rental transaction is 1 to 30 days; % requested. Longer stays renew with a new booking.', p_days
      using errcode = '22023';
  end if;$o$,
  $n$  if p_days < 1 or p_days > 3660 then
    raise exception 'A rental is 1 to 3,660 days; % requested.', p_days using errcode = '22023';
  end if;$n$);
select pg_temp.patch_fn('public.calc_rental_charge(timestamptz, integer, bigint, bigint, bigint, bigint, text)'::regprocedure,
  $o$    return query select 'monthly'::text, 0, 0, p_monthly;$o$,
  $n$    return query select 'monthly'::text, 0, 0, round(p_monthly::numeric * p_days / 30)::bigint;   -- 0132: each 30 days at the monthly rate$n$);

select pg_temp.patch_fn('app.partner_sheet_rental_cents(uuid, timestamptz, integer)'::regprocedure,
  $o$p_days between 1 and 30$o$, $n$p_days >= 1$n$);

-- price_lines: the rule of a long rental, the caps per period, the Protection Plan per period, the lines set by hand
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$    v_uncapped := v_monthly;
    v_rule := 'monthly rate';$o$,
  $n$    v_uncapped := r.rental_charge_cents;
    v_rule := case when v_days > 30 then format('monthly rate for %s days (the monthly rate divided by 30, times %s days)', v_days, v_days) else 'monthly rate' end;$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$public.calc_capped_per_day(v_rate, v_days, v_cap, n);$o$, $n$app.calc_capped_periods(v_rate, v_pickup, v_return, v_cap, n);$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$public.calc_capped_per_day(v_rate, v_days, v_cap);$o$, $n$app.calc_capped_periods(v_rate, v_pickup, v_return, v_cap);$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$          v_lines := v_lines || app.price_line('coverage_sold', 1, v_rate, v_rate, v_hst, null, null,
            jsonb_build_object('source', t ->> 'source'));$o$,
  $n$          n := greatest((select count(*) from app.rental_periods(v_pickup, v_return))::integer, 1);   -- 0132: priced per rental, so per period
          v_lines := v_lines || app.price_line('coverage_sold', n, v_rate, v_rate * n, v_hst, null, null,
            jsonb_build_object('source', t ->> 'source', 'periods', n));$n$);
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),$o$,
  $n$  -- 0132: a fee line set by hand for this booking
  if jsonb_typeof(p -> 'line_overrides') = 'object' and p -> 'line_overrides' <> '{}'::jsonb then
    v_lines := app.apply_line_overrides(v_lines, p -> 'line_overrides', v_hst);
  end if;
  select coalesce(jsonb_agg(x.value order by (x.value ->> 'sort_order')::integer, x.ord), '[]'::jsonb),$n$);

-- ================================================================ 3. the longest booking
alter table booking_extensions drop constraint if exists booking_extensions_new_days_check;
alter table bookings drop constraint if exists bookings_billable_days_check;
alter table bookings add constraint bookings_billable_days_check check (billable_days between 1 and 3660);

select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days
      using errcode = '22023';
  end if;$o$,
  $n$  if v_days > app.max_rental_days_now() then
    raise exception 'A booking is 1 to % days; these dates make %. Shorten the dates.', app.max_rental_days_now(), v_days using errcode = '22023';
  end if;$n$);
-- staff (the door) may price lines set by hand into a quote; a visitor's quote never takes them
select pg_temp.patch_fn('app.price_quote(uuid, timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$    'coverage_option', v_cover, 'fee_terms', v_terms));$o$,
  $n$    'coverage_option', v_cover, 'fee_terms', v_terms,
    'line_overrides', case when coalesce(current_setting('app.staff_pricing', true), '') = 'on' then o -> 'line_overrides' end));$n$);
select pg_temp.patch_fn('app.search_available(timestamptz, timestamptz, jsonb)'::regprocedure,
  $o$  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days$o$,
  $n$  if v_days > app.max_rental_days_now() then
    raise exception 'A booking is 1 to % days; these dates make %. Shorten the dates.', app.max_rental_days_now(), v_days$n$);
select pg_temp.patch_fn('app.submit_booking_request_pre0066(jsonb, inet, text, uuid)'::regprocedure,
  $o$  if v_days > v_set.max_rental_days then
    raise exception 'A rental transaction is 1 to % days; % requested. Longer stays renew with a new booking.', v_set.max_rental_days, v_days$o$,
  $n$  if v_days > app.max_rental_days_now() then
    raise exception 'A booking is 1 to % days; these dates make %. Shorten the dates.', app.max_rental_days_now(), v_days$n$);
select pg_temp.patch_fn('app.preview_extension(uuid, timestamptz, timestamptz)'::regprocedure,
  $o$format('The total length stays at %s days or less. A longer stay is a renewal: a new booking and agreement.', least(v_set.max_rental_days, 30))$o$,
  $n$format('The total length stays at %s days or less.', app.max_rental_days_now())$n$);
select pg_temp.patch_fn('app.preview_extension(uuid, timestamptz, timestamptz)'::regprocedure,
  $o$least(v_set.max_rental_days, 30)$o$, $n$app.max_rental_days_now()$n$);
select pg_temp.patch_fn('app.preview_booking_change(uuid, jsonb)'::regprocedure,
  $o$format('A rental is %s days or less. A longer stay is a renewal.', least(v_set.max_rental_days, 30))$o$,
  $n$format('A booking is %s days or less.', app.max_rental_days_now())$n$);
select pg_temp.patch_fn('app.preview_booking_change(uuid, jsonb)'::regprocedure,
  $o$least(v_set.max_rental_days, 30)$o$, $n$app.max_rental_days_now()$n$);
select pg_temp.patch_fn('app.calendar_preview_change(uuid, jsonb, timestamptz)'::regprocedure,
  $o$  elsif public.calc_billable_days(v_pickup, v_return) > v_set.max_rental_days then
    v_refusal := format('A rental is at most %s days; longer stays renew with a new booking', v_set.max_rental_days);$o$,
  $n$  elsif public.calc_billable_days(v_pickup, v_return) > app.max_rental_days_now() then
    v_refusal := format('A booking is at most %s days', app.max_rental_days_now());$n$);
select pg_temp.patch_fn('app.manual_rental_create_0058(uuid, jsonb)'::regprocedure,
  $o$  if v_days > s.max_rental_days then
    raise exception 'A rental is 1 to % days; these dates make %. Shorten it, and add the rest later as a new booking.', s.max_rental_days, v_days using errcode = '22023';
  end if;$o$,
  $n$  if v_days > greatest(s.max_rental_days, s.staff_max_rental_days) then
    raise exception 'A rental is 1 to % days; these dates make %. Check the return date (Program settings, Longest rental staff may enter).', greatest(s.max_rental_days, s.staff_max_rental_days), v_days using errcode = '22023';
  end if;$n$);

select pg_temp.patch_fn('app.request_booking(uuid, uuid, timestamptz, timestamptz, booking_type, text, text, uuid, text, text, text, text, text, text)'::regprocedure,
  $o$  v_days := public.calc_billable_days(p_pickup, p_return);$o$,
  $n$  v_days := public.calc_billable_days(p_pickup, p_return);
  if v_days > app.max_rental_days_now() then   -- 0132: the pricing engine no longer stops at 30 days
    raise exception 'A booking is 1 to % days; these dates make %. Shorten the dates.', app.max_rental_days_now(), v_days using errcode = '22023';
  end if;$n$);

-- ================================================================ 4. fee lines set by hand
create table if not exists booking_line_overrides (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings (id) on delete cascade,
  line_key    text not null check (line_key ~ '^[a-z0-9_]+(:[A-Za-z0-9_-]+)?$'),
  total_cents bigint not null check (total_cents >= 0),
  reason      text,
  set_by      uuid references users (id),
  set_at      timestamptz not null default now(),
  unique (booking_id, line_key)
);
comment on table booking_line_overrides is 'A fee line''s amount (before HST) set by hand for one booking (0132). line_key: the charge type (young_driver_21_25, coverage_sold, delivery...) or addon:<code>. The price engine uses it in place of the computed amount.';
create table if not exists booking_fee_changes (
  id            uuid primary key default gen_random_uuid(),
  booking_id    uuid not null references bookings (id) on delete cascade,
  line_key      text not null,
  label         text not null,
  before_cents  bigint,
  after_cents   bigint,
  reason        text,
  booking_status text,
  changed_by    uuid references users (id),
  changed_at    timestamptz not null default now()
);
comment on table booking_fee_changes is 'Every fee line changed by hand on a booking (0132): who, when, the amount before and after (before HST; null after: back to the computed amount), the reason and the booking''s status then.';
create index if not exists booking_fee_changes_booking on booking_fee_changes (booking_id, changed_at);
do $$
declare t text;
begin
  foreach t in array array['booking_line_overrides', 'booking_fee_changes'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;

-- the key of a price line: an add-on by its code, anything else by its charge type
create or replace function app.line_key(l jsonb) returns text
language sql immutable as $$
  select case when nullif(l #>> '{detail,code}', '') is not null and (l #>> '{detail,addon_id}' is not null or l ->> 'booking_addon_id' is not null or l ->> 'charge_type' = 'addon')
              then 'addon:' || (l #>> '{detail,code}') else l ->> 'charge_type' end
$$;

-- The lines with the amounts set by hand: the first line of each key takes the amount (any other line of that key is
-- 0); a key with no line yet (a Protection Plan or delivery fee not priced) is added as one line of that charge.
create or replace function app.apply_line_overrides(p_lines jsonb, p_over jsonb, p_hst integer) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  out jsonb := '[]'::jsonb;
  l jsonb;
  k text;
  seen text[] := '{}';
  v_keys text[];
  v bigint;
begin
  select coalesce(array_agg(app.line_key(x)), '{}') into v_keys from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x;
  for l in select value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    k := app.line_key(l);
    -- an add-on named by its charge (winter_tire) rather than its code: the line of that charge
    if not p_over ? k and p_over ? (l ->> 'charge_type') and not (l ->> 'charge_type') = any (v_keys) then k := l ->> 'charge_type'; end if;
    if p_over ? k and jsonb_typeof(p_over -> k) = 'number' and k not in ('rental_charge', 'non_refundable_discount', 'promo_discount', 'staff_discount') then
      v := case when k = any (seen) then 0 else (p_over ->> k)::bigint end;
      seen := seen || k;
      l := l || jsonb_build_object('amount_cents', v, 'unit_amount_cents', case when coalesce((l ->> 'quantity')::numeric, 1) > 0 then round(v / coalesce((l ->> 'quantity')::numeric, 1))::bigint else v end,
                                   'hst_cents', case when coalesce((l ->> 'hst_applies')::boolean, false) then public.calc_hst(v, p_hst) else 0 end,
                                   'set_by_hand', true, 'detail', coalesce(l -> 'detail', '{}'::jsonb) || jsonb_build_object('set_by_hand', true));
    end if;
    out := out || l;
  end loop;
  for k in select x from jsonb_object_keys(p_over) x loop
    if not k = any (seen) and k !~ ':' and jsonb_typeof(p_over -> k) = 'number' and (p_over ->> k)::bigint > 0
       and exists (select 1 from fee_types f where f.code = k and f.stage = 'booking' and f.code not in ('rental_charge', 'non_refundable_discount', 'promo_discount', 'staff_discount', 'addon')) then
      out := out || (app.price_line(k, 1, (p_over ->> k)::bigint, (p_over ->> k)::bigint, p_hst) || jsonb_build_object('set_by_hand', true, 'detail', jsonb_build_object('set_by_hand', true)));
    end if;
  end loop;
  return out;
end $$;

-- who may change a fee line on one booking: an Admin; customer service or sales while the setting is on
create or replace function app.may_edit_fees(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.user_is_admin(p_user), false)
      or (coalesce((app.settings()).staff_may_edit_fees, false) and (app.user_va_has(p_user, 'cs') or app.user_va_has(p_user, 'sales')))
$$;

-- the booking's own lines set by hand go into its price
select pg_temp.patch_fn('app.booking_price_spec(uuid, jsonb)'::regprocedure,
  $o$    'coverage_option', b.coverage_option, 'fee_terms', v_terms,$o$,
  $n$    'coverage_option', b.coverage_option, 'fee_terms', v_terms,
    'line_overrides', (select coalesce(jsonb_object_agg(o.line_key, o.total_cents), '{}'::jsonb) from booking_line_overrides o where o.booking_id = p_booking),$n$);

-- the label of a key, for the history and the screens
create or replace function app.line_key_label(p_key text) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_key like 'addon:%' then coalesce((select a.name from addons a where a.code = substr(p_key, 7) limit 1), substr(p_key, 7))
              when p_key = 'coverage_sold' then 'Protection Plan'
              else coalesce((select f.label from fee_types f where f.code = p_key), replace(p_key, '_', ' ')) end
$$;

-- Store the lines set by hand on a booking (no repricing here). p: {key: cents or null (back to the computed amount)}.
create or replace function app.booking_line_overrides_store(p_booking uuid, p_by uuid, p jsonb, p_reason text default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  k text;
  n integer := 0;
begin
  if p is null or jsonb_typeof(p) <> 'object' or p = '{}'::jsonb then return 0; end if;
  if not app.may_edit_fees(p_by) then
    raise exception 'Only an Admin, or customer service and sales while Program settings let staff change fees, changes a fee on one booking' using errcode = '42501';
  end if;
  for k in select x from jsonb_object_keys(p) x loop
    if k !~ '^[a-z0-9_]+(:[A-Za-z0-9_-]+)?$' or k in ('rental_charge', 'non_refundable_discount', 'promo_discount', 'staff_discount', 'deposit') then
      raise exception 'The fee "%" is not changed here (the rental charge, discounts and the deposit have their own fields)', k using errcode = '22023';
    end if;
    if jsonb_typeof(p -> k) = 'null' then
      delete from booking_line_overrides where booking_id = p_booking and line_key = k;
    else
      if jsonb_typeof(p -> k) <> 'number' or (p ->> k)::numeric < 0 then raise exception 'A fee is 0 or more' using errcode = '22023'; end if;
      insert into booking_line_overrides as o (booking_id, line_key, total_cents, reason, set_by)
      values (p_booking, k, round((p ->> k)::numeric)::bigint, nullif(btrim(coalesce(p_reason, '')), ''), p_by)
      on conflict (booking_id, line_key) do update set total_cents = excluded.total_cents, reason = excluded.reason, set_by = excluded.set_by, set_at = now();
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- the amount (before HST) of a key's lines on a booking now
create or replace function app.booking_line_key_cents(p_booking uuid, p_key text) returns bigint
language sql stable security definer set search_path = public, app as $$
  select sum(li.amount_cents)::bigint from booking_line_items li left join booking_addons ba on ba.id = li.booking_addon_id left join addons a on a.id = ba.addon_id
   where li.booking_id = p_booking and li.stage = 'booking' and li.voided_at is null
     and (case when li.booking_addon_id is not null then 'addon:' || a.code else li.charge_type end) = p_key
$$;

-- Change fee lines on a booking, before or after confirmation: stored, the booking repriced, each change recorded.
-- p: {booking, lines: {key: cents or null}, reason}.
create or replace function app.booking_fees_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  k text;
  v_before jsonb := '{}'::jsonb;
  v_lines jsonb := coalesce(p -> 'lines', '{}'::jsonb);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_changes jsonb := '[]'::jsonb;
  v_after bigint;
  v_total0 bigint;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status in ('closed', 'cancelled', 'declined', 'expired', 'no_show') then
    raise exception 'Booking % is %: its fees no longer change here (a later charge or a refund does it)', b.booking_number, b.status using errcode = '23514';
  end if;
  if b.booking_type = 'owner' then raise exception 'An owner booking has no fees' using errcode = '23514'; end if;
  if jsonb_typeof(v_lines) <> 'object' or v_lines = '{}'::jsonb then raise exception 'Change at least one fee' using errcode = '22023'; end if;
  for k in select x from jsonb_object_keys(v_lines) x loop
    v_before := v_before || jsonb_build_object(k, app.booking_line_key_cents(b.id, k));
  end loop;
  v_total0 := b.total_due_at_booking_cents;
  perform app.booking_line_overrides_store(b.id, p_by, v_lines, v_reason);
  perform app.sync_booking_price(b.id);
  for k in select x from jsonb_object_keys(v_lines) x loop
    v_after := app.booking_line_key_cents(b.id, k);
    if (v_before ->> k)::bigint is distinct from v_after then
      insert into booking_fee_changes (booking_id, line_key, label, before_cents, after_cents, reason, booking_status, changed_by)
      values (b.id, k, app.line_key_label(k), (v_before ->> k)::bigint, v_after, v_reason, b.status::text, p_by);
      v_changes := v_changes || jsonb_build_object('key', k, 'label', app.line_key_label(k), 'before_cents', (v_before ->> k)::bigint, 'after_cents', v_after);
    end if;
  end loop;
  select * into b from bookings where id = b.id;
  if jsonb_array_length(v_changes) > 0 then
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
      (select string_agg(format('%s: %s to %s', c ->> 'label', coalesce(app.fmt_money((c ->> 'before_cents')::bigint), 'none'), coalesce(app.fmt_money((c ->> 'after_cents')::bigint), 'none')), '; ')
         from jsonb_array_elements(v_changes) c) || coalesce(' (' || v_reason || ')', ''),
      p_by, 'staff', jsonb_build_object('fee_changes', v_changes, 'total_before_cents', v_total0, 'total_after_cents', b.total_due_at_booking_cents));
  end if;
  return jsonb_build_object('ok', true, 'booking_number', b.booking_number, 'changes', v_changes, 'total_cents', b.total_due_at_booking_cents,
                            'total_before_cents', v_total0, 'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'));
end $$;

-- the review screen's edit (offers, edit in place, the offer screen): lines set by hand
alter function app.admin_apply_booking_edit(uuid, uuid, jsonb) rename to admin_apply_booking_edit_pre0132;
create or replace function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.admin_apply_booking_edit_pre0132(p_admin, p_booking, p - 'line_overrides' - 'fee_reason');
  if jsonb_typeof(p -> 'line_overrides') = 'object' and p -> 'line_overrides' <> '{}'::jsonb then
    perform app.booking_fees_change(p_admin, jsonb_build_object('booking', p_booking, 'lines', p -> 'line_overrides',
                                                                'reason', coalesce(nullif(btrim(coalesce(p ->> 'fee_reason', '')), ''), 'Set on the offer')));
  end if;
end $$;
select pg_temp.patch_fn('app.staff_offer_create(uuid, jsonb)'::regprocedure,
  $o$    'fee_terms', p -> 'fee_terms', 'coverage_cents', p -> 'coverage_cents', 'coverage_reason', p -> 'coverage_reason',$o$,
  $n$    'fee_terms', p -> 'fee_terms', 'coverage_cents', p -> 'coverage_cents', 'coverage_reason', p -> 'coverage_reason',
    'line_overrides', case when jsonb_typeof(p -> 'line_overrides') = 'object' and p -> 'line_overrides' <> '{}'::jsonb then p -> 'line_overrides' end,
    'fee_reason', p -> 'fee_reason',$n$);

-- the quick rental form: its quote prices the lines set by hand; the rental stores them before it is priced
select pg_temp.patch_fn('app.manual_rental_quote_0058(uuid, jsonb)'::regprocedure,
  $o$               'promo_code', case when v_role = 'admin' or s.manual_rental_va_promo then nullif(p ->> 'promo_code', '') end));$o$,
  $n$               'promo_code', case when v_role = 'admin' or s.manual_rental_va_promo then nullif(p ->> 'promo_code', '') end,
               'line_overrides', case when app.may_edit_fees(p_by) and jsonb_typeof(p -> 'line_overrides') = 'object' then p -> 'line_overrides' end));$n$);
select pg_temp.patch_fn('app.manual_rental_quote_0058(uuid, jsonb)'::regprocedure,
  $o$    'may_override_price', true,$o$,
  $n$    'may_override_price', true, 'may_edit_fees', app.may_edit_fees(p_by),
    'periods', (select coalesce(jsonb_agg(jsonb_build_object('seq', x.seq, 'starts_at', x.starts_at, 'ends_at', x.ends_at, 'days', x.days) order by x.seq), '[]'::jsonb)
                  from app.rental_periods(v_from, v_to) x),$n$);
select pg_temp.patch_fn('app.manual_rental_create_0058(uuid, jsonb)'::regprocedure,
  $o$  perform app.sync_booking_price(b.id);
  select * into b from bookings where id = b.id;
  perform app.log_booking_event(b.id, 'added_by_staff',$o$,
  $n$  if jsonb_typeof(p -> 'line_overrides') = 'object' and p -> 'line_overrides' <> '{}'::jsonb then   -- 0132: fees set by hand
    perform app.booking_line_overrides_store(b.id, p_by, jsonb_strip_nulls(p -> 'line_overrides'), coalesce(nullif(btrim(coalesce(p ->> 'fee_reason', '')), ''), 'Set when the rental was entered'));
  end if;
  perform app.sync_booking_price(b.id);
  select * into b from bookings where id = b.id;
  insert into booking_fee_changes (booking_id, line_key, label, before_cents, after_cents, reason, booking_status, changed_by)
  select b.id, o.line_key, app.line_key_label(o.line_key), null, o.total_cents, o.reason, b.status::text, p_by from booking_line_overrides o where o.booking_id = b.id;
  perform app.log_booking_event(b.id, 'added_by_staff',$n$);

-- ================================================================ 5. the quick rental form: the rental paid in parts
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0132;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_more jsonb := case when jsonb_typeof(p -> 'more_payments') = 'array' then p -> 'more_payments' else '[]'::jsonb end;
  v_out jsonb;
  x jsonb;
  v_paid jsonb := '[]'::jsonb;
  b bookings;
  v_left bigint;
  v_open bigint;
  v_part bigint;
  v_cov text;
  v_ref text;
begin
  if jsonb_array_length(v_more) > 0 and coalesce(p #>> '{payment,mode}', '') <> 'other_way' then
    raise exception 'Add more payments to a rental paid another way (cash, e-Transfer, cheque, bank transfer)' using errcode = '22023';
  end if;
  if jsonb_array_length(v_more) > 0 and nullif(p #>> '{payment,amount_cents}', '') is null then
    raise exception 'With more than one payment, enter the amount of each' using errcode = '22023';
  end if;
  v_out := app.manual_rental_create_pre0132(p_by, p - 'more_payments');
  select * into b from bookings where id = (v_out ->> 'booking_id')::uuid;
  -- each further part pays the rental first, then the fees (a part that straddles both is recorded as two)
  for x in select value from jsonb_array_elements(v_more) loop
    if nullif(x ->> 'amount_cents', '') is null or (x ->> 'amount_cents')::bigint <= 0 then
      raise exception 'Enter the amount of each payment' using errcode = '22023';
    end if;
    v_left := (x ->> 'amount_cents')::bigint;
    v_ref := nullif(btrim(coalesce(x ->> 'reference', '')), '');
    while v_left > 0 loop
      v_open := app.booking_part_open(b.id, 'rental');
      v_cov := 'rental';
      if v_open <= 0 then v_open := app.booking_part_open(b.id, 'fees'); v_cov := 'fees'; end if;
      v_part := case when v_open > 0 then least(v_open, v_left) else v_left end;
      v_paid := v_paid || app.record_booking_payment(p_by, jsonb_build_object('booking', b.id, 'covers', v_cov, 'method', coalesce(nullif(x ->> 'method', ''), 'cash'),
        'amount_cents', v_part, 'reference', v_ref, 'received_on', coalesce(nullif(x ->> 'received_on', ''), p #>> '{payment,received_on}'),
        'note', nullif(x ->> 'note', '')));
      v_left := v_left - v_part;
      -- the rest of the same payment: its reference marked as a second part (one reference is recorded once)
      if v_ref is not null then v_ref := v_ref || ' (part 2)'; x := x || jsonb_build_object('note', 'Rest of ' || (x ->> 'reference') || ', for the fees'); end if;
    end loop;
  end loop;
  return v_out || jsonb_build_object('more_payments', v_paid, 'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'));
end $$;

-- a payment of the whole booking with no part named (the quick rental form's first payment, those before 0129): the
-- rental first, the rest pays the fees (it used to count for the rental only, so the fees looked unpaid)
select pg_temp.patch_fn('app.booking_part_open(uuid, text)'::regprocedure,
  $o$    v_paid := v_paid + (select coalesce(sum(m.amount_cents), 0) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers is null)
              * case when p_covers = 'rental' then 1 else 0 end;$o$,
  $n$    v_paid := v_paid + case when p_covers = 'rental'
      then (select coalesce(sum(m.amount_cents), 0) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers is null)
      else greatest((select coalesce(sum(m.amount_cents), 0) from manual_payments m where m.booking_id = p_booking and m.voided_at is null and m.covers is null) - v_rental, 0) end;$n$);

-- The fee lines of a booking for the screens: each line with its key, whether it was set by hand, what may be added,
-- the history of changes, and whether this person may change them.
create or replace function app.booking_fees(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'booking_number', b.booking_number, 'status', b.status, 'billable_days', b.billable_days,
    'may_edit', app.may_edit_fees(p_by) and b.status not in ('closed', 'cancelled', 'declined', 'expired', 'no_show') and b.booking_type <> 'owner',
    'lines', coalesce((select jsonb_agg(jsonb_build_object('key', k.key, 'label', coalesce(k.descr, app.line_key_label(k.key)), 'amount_cents', k.amount, 'hst_cents', k.hst,
                         'set_by_hand', o.id is not null, 'reason', o.reason, 'paid', k.paid) order by k.sort, k.key)
               from (select case when li.booking_addon_id is not null then 'addon:' || a.code else li.charge_type end as key, min(li.description) as descr,
                            sum(li.amount_cents)::bigint as amount, sum(li.hst_cents)::bigint as hst, bool_and(li.payment_id is not null) as paid, min(coalesce(f.sort_order, 115)) as sort
                       from booking_line_items li left join booking_addons ba on ba.id = li.booking_addon_id left join addons a on a.id = ba.addon_id
                       left join fee_types f on f.code = li.charge_type
                      where li.booking_id = b.id and li.stage = 'booking' and li.voided_at is null and li.charged_to_renter
                        and li.charge_type not in ('rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount')
                      group by 1) k
               left join booking_line_overrides o on o.booking_id = b.id and o.line_key = k.key), '[]'::jsonb),
    -- a fee not on the booking yet that staff may add: the Protection Plan (option 3), delivery and pickup, young or additional driver
    'addable', coalesce((select jsonb_agg(jsonb_build_object('key', f.code, 'label', app.line_key_label(f.code)) order by f.sort_order)
               from fee_types f
              where f.code in ('coverage_sold', 'delivery', 'pickup', 'young_driver_21_25', 'young_driver_18_20', 'additional_driver')
                and not exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = f.code and li.stage = 'booking' and li.voided_at is null)), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('label', c.label, 'before_cents', c.before_cents, 'after_cents', c.after_cents, 'reason', c.reason,
                           'status', c.booking_status, 'by', (select u.full_name from users u where u.id = c.changed_by), 'at', c.changed_at) order by c.changed_at desc)
               from booking_fee_changes c where c.booking_id = b.id), '[]'::jsonb),
    'total_cents', b.total_due_at_booking_cents,
    'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0132;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call = 'ops_read' and p_name in ('booking_fees'))
     or (p_call = 'ops_do' and p_name in ('booking_fees_change')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    case p_name
    when 'booking_fees' then return app.booking_fees(p_user, p_);
    when 'booking_fees_change' then return app.booking_fees_change(p_user, p_);
    end case;
  end if;
  return app.door_pre0132(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['max_rental_days_now', 'rental_periods', 'calc_capped_periods', 'line_key', 'apply_line_overrides', 'may_edit_fees',
              'line_key_label', 'booking_line_overrides_store', 'booking_line_key_cents', 'booking_fees_change', 'booking_fees', 'admin_apply_booking_edit',
              'admin_apply_booking_edit_pre0132', 'manual_rental_create', 'manual_rental_create_pre0132', 'door', 'door_pre0132'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the offer screen: whether this person may set fee lines by hand, and the longest booking for staff
alter function app.staff_offer_form(uuid, jsonb) rename to staff_offer_form_pre0132;
create or replace function app.staff_offer_form(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return app.staff_offer_form_pre0132(p_by, p) || jsonb_build_object('may_edit_fees', app.may_edit_fees(p_by), 'max_days', app.max_rental_days_now(),
    'period_days', (app.settings()).long_rental_period_days, 'cycle', (app.settings()).long_rental_cycle);
end $$;
revoke all on function app.staff_offer_form(uuid, jsonb), app.staff_offer_form_pre0132(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.staff_offer_form(uuid, jsonb), app.staff_offer_form_pre0132(uuid, jsonb) to service_role;

-- ================================================================ 6. edit a booking that has started (or ended)
-- The owner: "we can't edit a booking after it already started or whatever, that's not right either." An Admin, and
-- customer service and sales while Program settings let staff change bookings, change a confirmed, on-trip or returned
-- booking directly (an Admin also a closed one, to correct it): the pickup and the return (extend or shorten), the car,
-- the rental charge, each fee, the kilometres, the deposit (an Admin) and the note. Totals are repriced; a closed
-- booking's owner split and the staff commission follow; each edit is recorded (who, when, why, before and after) and
-- the renter is told what changed, or not (a silent correction). To have the renter accept and sign first, staff still
-- use Propose a change.
alter table program_settings add column if not exists staff_may_edit_bookings boolean not null default true;
comment on column program_settings.staff_may_edit_bookings is 'Customer service and sales may edit a confirmed, on-trip or returned booking directly (dates, car, rental charge, fees, kilometres, note), each edit recorded (0132). Admins always may, closed bookings too.';

create table if not exists booking_staff_edits (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references bookings (id) on delete cascade,
  edited_by      uuid references users (id),
  edited_at      timestamptz not null default now(),
  booking_status text not null,
  reason         text,
  told_renter    boolean not null default false,
  changes        jsonb not null default '[]'::jsonb,
  before         jsonb not null,
  after          jsonb not null,
  total_before_cents bigint,
  total_after_cents  bigint
);
comment on table booking_staff_edits is 'Each direct edit of a booking by staff (0132): who, when, the status then, the reason, each change (label, before, after), the totals, and whether the renter was told.';
create index if not exists booking_staff_edits_booking on booking_staff_edits (booking_id, edited_at);
alter table booking_staff_edits enable row level security;
create policy admin_all on booking_staff_edits for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on booking_staff_edits from anon, authenticated;
grant all on booking_staff_edits to service_role;
create trigger audit_booking_staff_edits after insert or update or delete on booking_staff_edits for each row execute function app.audit_row();

-- who may edit this booking directly, or why not (null: may)
create or replace function app.booking_edit_refusal(p_user uuid, b bookings) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when b.id is null then 'Booking not found'
    when b.status::text in ('cancelled', 'declined', 'expired', 'no_show') then format('Booking %s is %s: nothing to edit', b.booking_number, replace(b.status::text, '_', ' '))
    when b.status::text in ('requested', 'offered', 'pending_payment', 'tentative') then 'This booking is not confirmed yet: change it on the Review tab (Edit the offer)'
    when app.user_is_admin(p_user) then null
    when b.status::text = 'closed' then 'Only an Admin corrects a closed booking'
    when coalesce((app.settings()).staff_may_edit_bookings, false) and (app.user_va_has(p_user, 'cs') or app.user_va_has(p_user, 'sales')) then null
    else 'Only an Admin, or customer service and sales while Program settings let staff change bookings, edits a booking' end
$$;

create or replace function app.booking_snapshot(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('pickup_at', b.pickup_at, 'return_at', b.return_at, 'vehicle_id', b.vehicle_id, 'vehicle', app.vehicle_name(b.vehicle_id),
    'billable_days', b.billable_days, 'rental_charge_cents', b.rental_charge_cents, 'km_allowance_per_day', b.km_allowance_per_day,
    'deposit_cents', b.deposit_cents, 'notes', b.notes, 'pickup_place', b.pickup_place, 'return_place', b.return_place, 'total_cents', b.total_due_at_booking_cents)
    from bookings b where b.id = p_booking
$$;

-- p: {booking, changes: {pickup_at, return_at, vehicle_id, rental_charge_cents, km_allowance_per_day, deposit_cents, notes},
--     lines: {fee key: cents or null}, reason, tell_renter}
create or replace function app.booking_staff_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  b0 bookings;
  c jsonb := coalesce(p -> 'changes', '{}'::jsonb);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_tell boolean := coalesce((p ->> 'tell_renter')::boolean, false);
  v_refuse text;
  v_admin boolean := app.user_is_admin(p_by);
  v_before jsonb;
  v_after jsonb;
  v_from timestamptz;
  v_to timestamptz;
  v_days integer;
  v_rate record;
  v_rental bigint;
  v_typed bigint := nullif(c ->> 'rental_charge_cents', '')::bigint;
  v_car uuid := nullif(c ->> 'vehicle_id', '')::uuid;
  v_changes jsonb := '[]'::jsonb;
  k text;
  v_fees jsonb;
  v_cr uuid;
  v_note text;
  s program_settings := app.settings();
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  v_refuse := app.booking_edit_refusal(p_by, b);
  if v_refuse is not null then raise exception '%', v_refuse using errcode = case when b.id is null then 'P0002' else '42501' end; end if;
  if jsonb_typeof(c) <> 'object' then raise exception 'Give the changes as a list' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(c) loop
    if k not in ('pickup_at', 'return_at', 'vehicle_id', 'rental_charge_cents', 'km_allowance_per_day', 'deposit_cents', 'notes', 'pickup_place', 'return_place') then
      raise exception 'Unknown change "%"', k using errcode = '22023';
    end if;
  end loop;
  if c ? 'deposit_cents' and not v_admin then raise exception 'Only an Admin changes the deposit' using errcode = '42501'; end if;
  if v_typed is not null and v_typed < 0 then raise exception 'The rental charge is 0 or more' using errcode = '22023'; end if;
  b0 := b;
  v_before := app.booking_snapshot(b.id);

  -- the dates: extend or shorten (the start too, for a correction); the rental is repriced at the booking's own rates
  v_from := coalesce(nullif(c ->> 'pickup_at', '')::timestamptz, b.pickup_at);
  v_to := coalesce(nullif(c ->> 'return_at', '')::timestamptz, b.return_at);
  if v_to <= v_from then raise exception 'The return must be after the pickup: check both dates and times' using errcode = '22023'; end if;
  if v_from <> b.pickup_at or v_to <> b.return_at then
    v_days := public.calc_billable_days(v_from, v_to);
    if v_days > greatest(s.max_rental_days, s.staff_max_rental_days) then
      raise exception 'A booking is 1 to % days; these dates make %', greatest(s.max_rental_days, s.staff_max_rental_days), v_days using errcode = '22023';
    end if;
    if b.blocks_calendar and b.status::text in ('confirmed', 'on_rent') and exists (
         select 1 from bookings x where x.vehicle_id = b.vehicle_id and x.id <> b.id and x.status in ('confirmed', 'on_rent') and x.blocks_calendar
            and x.rental_window && tstzrange(v_from, v_to, '[)')) then
      raise exception 'The car is booked by % in the new dates: shorten the change, or move that booking first',
        (select string_agg(x.booking_number, ', ') from bookings x where x.vehicle_id = b.vehicle_id and x.id <> b.id and x.status in ('confirmed', 'on_rent') and x.blocks_calendar
            and x.rental_window && tstzrange(v_from, v_to, '[)')) using errcode = '23P01';
    end if;
    select * into v_rate from public.calc_rental_charge(v_from, v_days, b.daily_rate_cents, b.weekend_rate_cents, b.weekly_rate_cents, b.monthly_rate_cents, 'America/Toronto', b.multi_day_rate_cents);
    -- a price typed by hand before: the same price a day for the new length
    v_rental := case when b.custom_price_at is not null and b.billable_days > 0 then round(b.rental_charge_cents::numeric * v_days / b.billable_days)::bigint else v_rate.rental_charge_cents end;
    update bookings set pickup_at = v_from, return_at = v_to, billable_days = v_days, km_allowance_total = km_allowance_per_day * v_days,
           rental_charge_cents = v_rental, rate_applied = v_rate.rate_applied, daily_days = v_rate.daily_days, weekend_days = v_rate.weekend_days,
           discount_cents = case when booking_type = 'non_refundable' then public.calc_bps(v_rental, s.non_refundable_discount_bps) else 0 end,
           handed_over_at = case when handed_over_at is not null and status::text in ('returned', 'closed') then v_from else handed_over_at end,
           checked_in_at = case when checked_in_at is not null and status::text in ('returned', 'closed') then v_to else checked_in_at end
     where id = b.id;
  end if;
  -- the car (on trip: the swap of record, with the old car freed; otherwise the booking moves)
  if v_car is not null and v_car <> b.vehicle_id then
    if not exists (select 1 from vehicles v where v.id = v_car) then raise exception 'Choose the car' using errcode = '22023'; end if;
    if b.status::text in ('confirmed', 'on_rent') and not app.vehicle_is_available(v_car, greatest(v_from, now()), greatest(v_to, now() + interval '1 minute'), b.id) then
      raise exception '% is not free for the rest of this booking', app.vehicle_name(v_car) using errcode = '23P01';
    end if;
    if b.status::text = 'on_rent' then
      insert into booking_vehicle_swaps (booking_id, from_vehicle_id, to_vehicle_id, swapped_at, reason, approved_by)
      values (b.id, b.vehicle_id, v_car, now(), coalesce(v_reason, 'Changed by staff'), p_by);
      update tracker_access_blocks set ends_at = greatest(now(), starts_at) where booking_id = b.id and vehicle_id = b.vehicle_id and ends_at is null;
      update vehicles set status = 'out_of_service' where id = b.vehicle_id and status = 'on_rent';   -- as a swap of record: Fleet checks the car it left
      update vehicles set status = 'on_rent' where id = v_car and status = 'available';
    end if;
    update bookings set vehicle_id = v_car where id = b.id;
    update field_jobs set vehicle_id = v_car where booking_id = b.id and status in ('scheduled', 'acknowledged');
  end if;
  if c ? 'km_allowance_per_day' then
    update bookings set km_allowance_per_day = (c ->> 'km_allowance_per_day')::integer, km_allowance_total = (c ->> 'km_allowance_per_day')::integer * billable_days where id = b.id;
  end if;
  if c ? 'deposit_cents' then update bookings set deposit_cents = (c ->> 'deposit_cents')::bigint where id = b.id; end if;
  if c ? 'notes' then update bookings set notes = nullif(btrim(c ->> 'notes'), '') where id = b.id; end if;
  if c ? 'pickup_place' then update bookings set pickup_place = nullif(btrim(c ->> 'pickup_place'), '') where id = b.id; end if;
  if c ? 'return_place' then update bookings set return_place = nullif(btrim(c ->> 'return_place'), '') where id = b.id; end if;
  if v_typed is not null then
    update bookings set rental_charge_cents = v_typed, custom_price_reason = coalesce(v_reason, 'Set by staff'), custom_price_by = p_by, custom_price_at = now(),
           discount_cents = case when booking_type = 'non_refundable' then public.calc_bps(v_typed, s.non_refundable_discount_bps) else 0 end
     where id = b.id;
  end if;
  perform app.sync_booking_price(b.id);
  -- each fee
  v_fees := case when jsonb_typeof(p -> 'lines') = 'object' and p -> 'lines' <> '{}'::jsonb then p -> 'lines' end;
  if v_fees is not null then
    perform app.booking_fees_change(p_by, jsonb_build_object('booking', b.id, 'lines', v_fees, 'reason', coalesce(v_reason, 'Edited by staff')));
  end if;
  select * into b from bookings where id = b.id;
  v_after := app.booking_snapshot(b.id);
  for k in select x from jsonb_object_keys(v_after) x loop
    if k not in ('vehicle', 'total_cents') and (v_before -> k) is distinct from (v_after -> k) then
      v_changes := v_changes || jsonb_build_object('field', k, 'before', v_before -> k, 'after', v_after -> k,
        'label', case k when 'pickup_at' then 'Pickup' when 'return_at' then 'Return' when 'vehicle_id' then 'Car' when 'billable_days' then 'Days'
                        when 'rental_charge_cents' then 'Rental charge' when 'km_allowance_per_day' then 'Kilometres a day' when 'deposit_cents' then 'Deposit' when 'pickup_place' then 'Pickup place' when 'return_place' then 'Return place' else 'Note' end);
    end if;
  end loop;
  if v_fees is not null then v_changes := v_changes || jsonb_build_object('field', 'fees', 'label', 'Fees', 'before', null, 'after', v_fees); end if;
  if jsonb_array_length(v_changes) = 0 then
    return jsonb_build_object('ok', true, 'changed', false, 'booking_number', b.booking_number);
  end if;
  -- a closed booking's split, and the commission, follow (a split already on a sent statement is left for Finance)
  if b.status::text in ('returned', 'closed') then
    begin
      perform app.compute_booking_split(b.id);
    exception when others then
      perform app.raise_task(p_type => 'statement_correction', p_title => format('Booking %s was corrected after it closed: check the owner statement (%s)', b.booking_number, left(sqlerrm, 120)),
        p_booking => b.id, p_queue => 'finance', p_created_by => p_by, p_dedupe => 'staff_edit_split:' || b.id || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
    end;
  end if;
  begin perform app.commission_sync(b.id); exception when others then null; end;
  insert into booking_staff_edits (booking_id, edited_by, booking_status, reason, told_renter, changes, before, after, total_before_cents, total_after_cents)
  values (b.id, p_by, b.status::text, v_reason, v_tell, v_changes, v_before, v_after, (v_before ->> 'total_cents')::bigint, b.total_due_at_booking_cents);
  v_note := (select string_agg(case when x ->> 'field' in ('pickup_at', 'return_at') then format('%s: %s to %s', x ->> 'label', app.fmt_datetime((x ->> 'before')::timestamptz), app.fmt_datetime((x ->> 'after')::timestamptz))
                                  when x ->> 'field' in ('rental_charge_cents', 'deposit_cents') then format('%s: %s to %s', x ->> 'label', app.fmt_money((x ->> 'before')::bigint), app.fmt_money((x ->> 'after')::bigint))
                                  when x ->> 'field' = 'vehicle_id' then format('Car: %s to %s', v_before ->> 'vehicle', v_after ->> 'vehicle')
                                  when x ->> 'field' = 'fees' then 'Fees changed'
                                  else format('%s: %s to %s', x ->> 'label', coalesce(x ->> 'before', 'none'), coalesce(x ->> 'after', 'none')) end, '; ')
              from jsonb_array_elements(v_changes) x)
            || format('. Total %s to %s', app.fmt_money((v_before ->> 'total_cents')::bigint), app.fmt_money(b.total_due_at_booking_cents))
            || coalesce(' (' || v_reason || ')', '') || case when v_tell then '. The renter was told.' else '. Not sent to the renter.' end;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version, v_note, p_by, 'staff',
    jsonb_build_object('staff_edit', true, 'changes', v_changes, 'told_renter', v_tell));
  -- the renter (and the owner, when the car or the income changes) hear of it as of an applied change
  if v_tell then
    insert into booking_change_requests (booking_id, requested_by_role, requested_by, status, note, changes, before, after, source, decided_by, decided_at, priced_at)
    values (b.id, 'staff', p_by, 'approved', coalesce(v_reason, 'Updated by our team'), v_changes,
            v_before || jsonb_build_object('total_cents', (v_before ->> 'total_cents')::bigint), v_after || jsonb_build_object('total_cents', b.total_due_at_booking_cents),
            'staff_calendar', p_by, now(), now())
    returning id into v_cr;
    update booking_change_requests set status = 'applied', applied_at = now(), applied_by = p_by where id = v_cr;
  end if;
  return jsonb_build_object('ok', true, 'changed', true, 'booking_number', b.booking_number, 'changes', v_changes, 'note', v_note,
    'total_before_cents', (v_before ->> 'total_cents')::bigint, 'total_cents', b.total_due_at_booking_cents,
    'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'));
end $$;

-- the edit form: what may be changed, the cars, and the edits so far
create or replace function app.booking_edit_form(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'refusal', app.booking_edit_refusal(p_by, b), 'admin', app.user_is_admin(p_by),
    'now', app.booking_snapshot(b.id) || jsonb_build_object('custom_price', b.custom_price_at is not null, 'daily_rate_cents', b.daily_rate_cents, 'monthly_rate_cents', b.monthly_rate_cents),
    'cars', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'car_code', v.car_code) order by app.vehicle_name(v.id))
                      from vehicles v where v.retired_at is null and coalesce(v.is_sample, false) = false), '[]'::jsonb),
    'edits', coalesce((select jsonb_agg(jsonb_build_object('at', e.edited_at, 'by', (select u.full_name from users u where u.id = e.edited_by), 'status', e.booking_status,
                         'reason', e.reason, 'told_renter', e.told_renter, 'changes', e.changes, 'total_before_cents', e.total_before_cents, 'total_after_cents', e.total_after_cents) order by e.edited_at desc)
                       from booking_staff_edits e where e.booking_id = b.id), '[]'::jsonb));
end $$;

-- the renter's email for a change staff made: the money as it is (no card was charged by the change itself)
select pg_temp.patch_fn('app.ntf_payload_0040(text, app_events, jsonb)'::regprocedure,
  $o$        'money_text', case when coalesce(c.total_difference_cents, 0) > 0$o$,
  $n$        'money_text', case when c.source = 'staff_calendar' and c.payment_id is null and c.refund_id is null and c.total_difference_cents is null
                           then format('Your booking''s total is now %s. Our team settles any difference with you.', app.fmt_money(coalesce((c.after ->> 'total_cents')::bigint, b.total_due_at_booking_cents)))
                           when coalesce(c.total_difference_cents, 0) > 0$n$);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0132b;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call = 'ops_read' and p_name = 'booking_edit_form') or (p_call = 'ops_do' and p_name = 'booking_staff_edit') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    if p_name = 'booking_edit_form' then return app.booking_edit_form(p_user, p_); end if;
    return app.booking_staff_edit(p_user, p_);
  end if;
  return app.door_pre0132b(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['booking_edit_refusal', 'booking_snapshot', 'booking_staff_edit', 'booking_edit_form', 'door', 'door_pre0132b'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 7. the Stripe events the site did not listen to
-- The live webhook endpoint took 8 events. Refunds made from the site settle days later (refund.updated), a refund made
-- in Stripe's dashboard never reached the booking's money (charge.refunded), a dispute (chargeback) reached nobody
-- (charge.dispute.created, .updated, .closed), and a saved-card charge the bank wanted confirmed (requires_action) waited
-- silently. scripts/deploy/supabase.sh subscribes the endpoint to them; these record each one once.
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('stripe_refund_outside', 'finance', 'A refund was made in Stripe, not from the site', 'normal', 'end_of_day', null, 'charge.refunded for a payment the site did not refund: the refund is recorded on the booking; check why (0132).'),
  ('stripe_refund_failed', 'finance', 'A refund failed at the bank', 'high', 'end_of_day', null, 'refund.updated with status failed: give the money back another way (0132).'),
  ('stripe_dispute', 'admin', 'A card payment is disputed (chargeback)', 'urgent', 'business_days', 2, 'charge.dispute.created: gather the agreement, photos and messages and answer in Stripe before the evidence date (0132).'),
  ('stripe_dispute_finance', 'finance', 'A card payment is disputed: hold the owner''s share', 'high', 'business_days', 1, 'charge.dispute.created: the disputed amount is withheld from the owner until the dispute is decided (0132).'),
  ('stripe_requires_action', 'finance', 'A card charge needs the renter to confirm it', 'high', 'end_of_day', null, 'payment_intent.requires_action on a charge the site made: send the renter a payment link instead (0132).'),
  ('statement_correction', 'finance', 'A closed booking was corrected: check the owner statement', 'high', 'end_of_day', null, 'A staff edit of a closed booking could not recompute its split (0132).')
on conflict (task_type) do nothing;

-- the payment a Stripe object belongs to: by the PaymentIntent, then by the charge
create or replace function app.stripe_payment_of(p_intent text, p_charge text) returns payments
language sql stable security definer set search_path = public, app as $$
  select x.* from payments x join payment_processor_details pd on pd.payment_id = x.id
   where x.kind in ('charge', 'capture') and ((p_intent is not null and pd.processor_payment_id = p_intent) or (p_charge is not null and pd.processor_charge_id = p_charge))
   order by x.created_at limit 1
$$;

-- A refund's state from Stripe (refund.updated, refund.created, charge.refunded): the site's own refund settles or fails;
-- one made in Stripe's dashboard is recorded against its payment with a task for Finance. Idempotent by the refund's id.
create or replace function public.server_stripe_refund_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ref text := nullif(p ->> 'refund_id', '');
  v_status text := coalesce(nullif(p ->> 'status', ''), 'succeeded');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  rp payments;
  pay payments;
  rf refunds;
  v_new uuid;
begin
  if v_ref is null then return jsonb_build_object('ignored', 'no refund id'); end if;
  select x.* into rp from payments x join payment_processor_details pd on pd.payment_id = x.id where pd.processor_refund_id = v_ref and x.kind = 'refund' limit 1;
  if rp.id is not null then
    select * into rf from refunds where refund_payment_id = rp.id;
    if v_status = 'succeeded' and rp.status <> 'succeeded' then
      update payments set status = 'succeeded', processed_at = coalesce(processed_at, now()) where id = rp.id;
      update refunds set status = 'paid', paid_at = coalesce(paid_at, now()) where id = rf.id and status <> 'paid';
      return jsonb_build_object('refund', v_ref, 'settled', true);
    elsif v_status in ('failed', 'canceled') and rp.status <> 'failed' then
      update payments set status = 'failed' where id = rp.id;
      update refunds set status = 'failed', note = concat_ws(' | ', note, 'Stripe: ' || coalesce(nullif(p ->> 'failure_reason', ''), v_status)) where id = rf.id;
      perform app.raise_task(p_type => 'stripe_refund_failed', p_title => format('Refund of %s failed at the bank: give it back another way', app.fmt_money(rp.amount_cents)),
        p_booking => rp.booking_id, p_related_table => 'refunds', p_related_id => rf.id, p_dedupe => 'stripe_refund_failed:' || v_ref);
      return jsonb_build_object('refund', v_ref, 'failed', true);
    end if;
    return jsonb_build_object('refund', v_ref, 'unchanged', true);
  end if;
  -- the site's refund still being issued (its finish has not run yet): the finish records it
  if exists (select 1 from refunds r where r.id::text = p ->> 'site_refund_id' and r.status = 'processing') then
    return jsonb_build_object('refund', v_ref, 'waiting_for_finish', true);
  end if;
  pay := app.stripe_payment_of(nullif(p ->> 'intent_id', ''), nullif(p ->> 'charge_id', ''));
  if pay.id is null then return jsonb_build_object('refund', v_ref, 'ignored', 'no payment of ours'); end if;
  if v_status in ('failed', 'canceled') then return jsonb_build_object('refund', v_ref, 'ignored', v_status); end if;
  insert into payments (booking_id, renter_id, owner_id, purpose, kind, method, amount_cents, currency, status, parent_payment_id, card_brand, card_last4, processed_at)
  values (pay.booking_id, pay.renter_id, pay.owner_id, pay.purpose, 'refund', pay.method, coalesce(v_amount, pay.amount_cents), pay.currency,
          case when v_status = 'succeeded' then 'succeeded' else 'pending' end, pay.id, pay.card_brand, pay.card_last4, case when v_status = 'succeeded' then now() end)
  returning id into v_new;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, processor_charge_id, processor_refund_id, raw)
  values (v_new, 'stripe', nullif(p ->> 'intent_id', ''), nullif(p ->> 'charge_id', ''), v_ref, jsonb_build_object('source', 'stripe_dashboard', 'status', v_status));
  if pay.booking_id is not null then
    perform app.log_booking_event(pay.booking_id, 'adjusted', null, null, null,
      format('%s refunded in Stripe (not from the site), reference %s', app.fmt_money(coalesce(v_amount, pay.amount_cents)), v_ref), null, 'system', jsonb_build_object('payment_id', v_new));
  end if;
  perform app.raise_task(p_type => 'stripe_refund_outside', p_title => format('%s was refunded in Stripe, not from the site: check why and record the reason', app.fmt_money(coalesce(v_amount, pay.amount_cents))),
    p_booking => pay.booking_id, p_owner => pay.owner_id, p_related_table => 'payments', p_related_id => v_new, p_dedupe => 'stripe_refund_outside:' || v_ref);
  return jsonb_build_object('refund', v_ref, 'recorded', true, 'payment_id', v_new);
end $$;

-- A dispute (chargeback) from Stripe: recorded once per dispute and kept current; the Admin and Finance get tasks when it opens.
create or replace function public.server_stripe_dispute_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ref text := nullif(p ->> 'dispute_id', '');
  v_st text := p ->> 'status';
  v_status text := case when v_st = 'won' then 'won' when v_st = 'lost' then 'lost' when v_st in ('under_review', 'warning_under_review') then 'evidence_submitted' else 'open' end;
  pay payments;
  d disputes;
begin
  if v_ref is null then return jsonb_build_object('ignored', 'no dispute id'); end if;
  select * into d from disputes where processor_dispute_ref = v_ref for update;
  if d.id is null then
    pay := app.stripe_payment_of(nullif(p ->> 'intent_id', ''), nullif(p ->> 'charge_id', ''));
    if pay.id is null then return jsonb_build_object('dispute', v_ref, 'ignored', 'no payment of ours'); end if;
    insert into disputes (payment_id, booking_id, processor_dispute_ref, amount_cents, reason, status, evidence_due_at, resolved_at)
    values (pay.id, pay.booking_id, v_ref, greatest(coalesce(nullif(p ->> 'amount_cents', '')::bigint, pay.amount_cents), 1), nullif(p ->> 'reason', ''), v_status,
            nullif(p ->> 'evidence_due_at', '')::timestamptz, case when v_status in ('won', 'lost') then now() end)
    returning * into d;
    perform app.raise_task(p_type => 'stripe_dispute', p_title => format('Card payment of %s disputed (%s): answer in Stripe by %s', app.fmt_money(d.amount_cents), coalesce(d.reason, 'no reason given'),
              coalesce(app.fmt_date(d.evidence_due_at), 'the evidence date')),
      p_booking => d.booking_id, p_related_table => 'disputes', p_related_id => d.id, p_due_at => d.evidence_due_at, p_dedupe => 'stripe_dispute:' || v_ref);
    perform app.raise_task(p_type => 'stripe_dispute_finance', p_title => format('Disputed card payment of %s: hold the owner''s share until it is decided', app.fmt_money(d.amount_cents)),
      p_booking => d.booking_id, p_related_table => 'disputes', p_related_id => d.id, p_dedupe => 'stripe_dispute_finance:' || v_ref);
    if d.booking_id is not null then
      perform app.log_booking_event(d.booking_id, 'adjusted', null, null, null, format('Card payment disputed in Stripe: %s (%s)', app.fmt_money(d.amount_cents), coalesce(d.reason, 'no reason')), null, 'system',
        jsonb_build_object('dispute_id', d.id));
    end if;
    return jsonb_build_object('dispute', v_ref, 'recorded', true, 'status', v_status);
  end if;
  if d.status is distinct from v_status then
    update disputes set status = v_status, resolved_at = case when v_status in ('won', 'lost') then coalesce(resolved_at, now()) end,
           evidence_due_at = coalesce(nullif(p ->> 'evidence_due_at', '')::timestamptz, evidence_due_at)
     where id = d.id;
    if d.booking_id is not null and v_status in ('won', 'lost') then
      perform app.log_booking_event(d.booking_id, 'adjusted', null, null, null, format('Dispute %s: %s', v_status, app.fmt_money(d.amount_cents)), null, 'system', jsonb_build_object('dispute_id', d.id));
    end if;
  end if;
  return jsonb_build_object('dispute', v_ref, 'status', v_status);
end $$;

-- A charge the site made that the bank wants the renter to confirm: Finance sends a payment link instead.
create or replace function public.server_stripe_requires_action(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  pay payments;
begin
  pay := app.stripe_payment_of(nullif(p ->> 'intent_id', ''), null);
  if pay.id is null and nullif(p ->> 'payment_id', '') is not null then select * into pay from payments where id::text = p ->> 'payment_id'; end if;
  if pay.id is null then return jsonb_build_object('ignored', 'no payment of ours'); end if;
  perform app.raise_task(p_type => 'stripe_requires_action', p_title => format('The bank wants the renter to confirm %s: send them a payment link (Collect a card)', app.fmt_money(pay.amount_cents)),
    p_booking => pay.booking_id, p_related_table => 'payments', p_related_id => pay.id, p_dedupe => 'stripe_requires_action:' || coalesce(p ->> 'intent_id', pay.id::text));
  return jsonb_build_object('task', true, 'payment_id', pay.id);
end $$;
revoke all on function app.stripe_payment_of(text, text), public.server_stripe_refund_event(jsonb), public.server_stripe_dispute_event(jsonb), public.server_stripe_requires_action(jsonb) from public, anon, authenticated;
grant execute on function app.stripe_payment_of(text, text), public.server_stripe_refund_event(jsonb), public.server_stripe_dispute_event(jsonb), public.server_stripe_requires_action(jsonb) to service_role;

-- ================================================================ 8. edit a renter's details
-- The owner: "There's no way to adjust a renter's details. We accidentally entered someone's email wrong and need to
-- change it asap." An Admin, customer service and sales correct the name, email, phone, date of birth, home address,
-- licence and a staff note, from the renter's page or any booking. The email follows everywhere the renter is written
-- to (the account, the open agreements' signers; offers and links read the record); the server changes the sign-in's
-- email too (no confirmation needed for a typo staff correct). Another renter with that email is refused by name; one
-- with that phone is a warning. Each edit is kept (renter_edits) and in the audit log.
alter table renters add column if not exists staff_note text;
comment on column renters.staff_note is 'A note about the renter for staff only (0132).';
create table if not exists renter_edits (
  id         uuid primary key default gen_random_uuid(),
  renter_id  uuid not null references renters (id) on delete cascade,
  edited_by  uuid references users (id),
  edited_at  timestamptz not null default now(),
  reason     text,
  before     jsonb not null,
  after      jsonb not null,
  email_changed boolean not null default false
);
comment on table renter_edits is 'Each correction of a renter''s details by staff (0132): who, when, why, before and after.';
create index if not exists renter_edits_renter on renter_edits (renter_id, edited_at);
alter table renter_edits enable row level security;
create policy admin_all on renter_edits for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on renter_edits from anon, authenticated;
grant all on renter_edits to service_role;
create trigger audit_renter_edits after insert or update or delete on renter_edits for each row execute function app.audit_row();

create or replace function app.renter_snapshot(p_renter uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('full_name', r.legal_name, 'email', coalesce(r.email, u.email), 'mobile', r.mobile, 'date_of_birth', r.date_of_birth,
    'address_line1', r.address_line1, 'address_line2', r.address_line2, 'city', r.city, 'province', r.province, 'postal_code', r.postal_code,
    'licence_number', d.licence_number, 'licence_class', d.licence_class, 'licence_issuer', d.licence_issuer, 'licence_expiry', d.licence_expiry, 'staff_note', r.staff_note)
    from renters r left join users u on u.id = r.user_id left join drivers d on d.renter_id = r.id and d.is_account_holder where r.id = p_renter
$$;

create or replace function app.may_edit_renter(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.user_is_admin(p_user), false) or app.user_va_has(p_user, 'cs') or app.user_va_has(p_user, 'sales')
$$;

-- p: {renter (id) or booking (id or number), full_name, email, mobile, date_of_birth, address_line1, address_line2, city, province, postal_code,
--     licence_number, licence_class, licence_issuer, licence_expiry, staff_note, reason}; only the keys sent change.
create or replace function app.renter_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r renters;
  u users;
  v_before jsonb;
  v_after jsonb;
  v_email text := lower(nullif(btrim(coalesce(p ->> 'email', '')), ''));
  v_other text;
  v_warn jsonb := '[]'::jsonb;
  v_changed boolean := false;
begin
  if not app.may_edit_renter(p_by) then raise exception 'An Admin, customer service or sales corrects a renter''s details' using errcode = '42501'; end if;
  select * into r from renters where id::text = p ->> 'renter'
     or id = (select b.renter_id from bookings b where b.id::text = p ->> 'booking' or b.booking_number = upper(btrim(coalesce(p ->> 'booking', ''))))
   for update;
  if r.id is null then raise exception 'Renter not found' using errcode = 'P0002'; end if;
  select * into u from users where id = r.user_id for update;
  v_before := app.renter_snapshot(r.id);
  if p ? 'full_name' and nullif(btrim(p ->> 'full_name'), '') is null then raise exception 'The full legal name cannot be empty' using errcode = '22023'; end if;
  if p ? 'email' then
    if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address (like name@example.com)' using errcode = '22023'; end if;
    select coalesce(r2.legal_name, u2.full_name, u2.email) into v_other from users u2 left join renters r2 on r2.user_id = u2.id
     where lower(u2.email) = v_email and u2.id <> r.user_id limit 1;
    if v_other is null then
      select r2.legal_name into v_other from renters r2 where lower(r2.email) = v_email and r2.id <> r.id limit 1;
    end if;
    if v_other is not null then
      raise exception '% is already on file with %: open that renter instead (or ask an Admin to merge the two)', v_other, v_email using errcode = '23505';
    end if;
    v_changed := v_email is distinct from lower(coalesce(r.email, u.email));
  end if;
  if p ? 'mobile' and nullif(regexp_replace(coalesce(p ->> 'mobile', ''), '\D', '', 'g'), '') is not null then
    select coalesce(jsonb_agg(jsonb_build_object('renter_id', r2.id, 'name', r2.legal_name)), '[]'::jsonb) into v_warn from renters r2
     where r2.id <> r.id and right(regexp_replace(coalesce(r2.mobile, ''), '\D', '', 'g'), 10) = right(regexp_replace(p ->> 'mobile', '\D', '', 'g'), 10);
  end if;
  if p ? 'date_of_birth' and nullif(p ->> 'date_of_birth', '') is not null and (p ->> 'date_of_birth')::date > current_date - interval '16 years' then
    raise exception 'Check the date of birth' using errcode = '22023';
  end if;
  update renters set
    legal_name = case when p ? 'full_name' then btrim(p ->> 'full_name') else legal_name end,
    email = case when p ? 'email' then v_email else email end,
    mobile = case when p ? 'mobile' then nullif(btrim(p ->> 'mobile'), '') else mobile end,
    date_of_birth = case when p ? 'date_of_birth' then nullif(p ->> 'date_of_birth', '')::date else date_of_birth end,
    address_line1 = case when p ? 'address_line1' then nullif(btrim(p ->> 'address_line1'), '') else address_line1 end,
    address_line2 = case when p ? 'address_line2' then nullif(btrim(p ->> 'address_line2'), '') else address_line2 end,
    city = case when p ? 'city' then nullif(btrim(p ->> 'city'), '') else city end,
    province = case when p ? 'province' then nullif(btrim(p ->> 'province'), '') else province end,
    postal_code = case when p ? 'postal_code' then upper(nullif(btrim(p ->> 'postal_code'), '')) else postal_code end,
    staff_note = case when p ? 'staff_note' then nullif(btrim(p ->> 'staff_note'), '') else staff_note end
   where id = r.id returning * into r;
  if u.id is not null then
    update users set email = case when p ? 'email' then v_email else email end,
                     full_name = case when p ? 'full_name' then btrim(p ->> 'full_name') else full_name end
     where id = u.id;
  end if;
  update drivers set full_name = r.legal_name, date_of_birth = coalesce(r.date_of_birth, date_of_birth), email = coalesce(r.email, email), mobile = coalesce(r.mobile, mobile),
         licence_number = case when p ? 'licence_number' then nullif(btrim(p ->> 'licence_number'), '') else licence_number end,
         licence_class = case when p ? 'licence_class' then upper(coalesce(nullif(btrim(p ->> 'licence_class'), ''), licence_class)) else licence_class end,
         licence_issuer = case when p ? 'licence_issuer' then coalesce(nullif(btrim(p ->> 'licence_issuer'), ''), licence_issuer) else licence_issuer end,
         licence_expiry = case when p ? 'licence_expiry' then nullif(p ->> 'licence_expiry', '')::date else licence_expiry end
   where renter_id = r.id and is_account_holder;
  -- the bookings not yet over print the corrected name, birth date and licence; unsigned agreements go to the new address
  update booking_drivers bd set full_name = d.full_name, date_of_birth = d.date_of_birth, licence_number = d.licence_number, licence_class = d.licence_class,
         licence_issuer = d.licence_issuer, licence_expiry = d.licence_expiry
    from drivers d, bookings b
   where d.id = bd.driver_id and d.renter_id = r.id and d.is_account_holder and b.id = bd.booking_id and b.status::text not in ('closed', 'cancelled', 'declined', 'expired', 'no_show');
  update rental_agreement_signers g set signer_email = r.email, signer_name = r.legal_name
    from rental_agreements a, bookings b
   where g.agreement_id = a.id and a.booking_id = b.id and b.renter_id = r.id and g.signer_role = 'renter' and g.signed_at is null and a.status = 'open';
  v_after := app.renter_snapshot(r.id);
  if v_after = v_before then return jsonb_build_object('ok', true, 'changed', false, 'warnings', v_warn); end if;
  insert into renter_edits (renter_id, edited_by, reason, before, after, email_changed) values (r.id, p_by, nullif(btrim(coalesce(p ->> 'reason', '')), ''), v_before, v_after, v_changed);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after) values (p_by, 'renter_edit', 'renters', r.id::text, v_before, v_after);
  return jsonb_build_object('ok', true, 'changed', true, 'renter_id', r.id, 'user_id', r.user_id, 'email_changed', v_changed, 'email', r.email,
    'full_name', r.legal_name, 'warnings', v_warn, 'before', v_before, 'after', v_after);
end $$;

create or replace function app.renter_edit_form(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select r.id into v_id from renters r where r.id::text = p ->> 'renter'
     or r.id = (select b.renter_id from bookings b where b.id::text = p ->> 'booking' or b.booking_number = upper(btrim(coalesce(p ->> 'booking', ''))));
  if v_id is null then raise exception 'Renter not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('renter_id', v_id, 'may_edit', app.may_edit_renter(p_by), 'now', app.renter_snapshot(v_id),
    'edits', coalesce((select jsonb_agg(jsonb_build_object('at', e.edited_at, 'by', (select u.full_name from users u where u.id = e.edited_by), 'reason', e.reason,
                        'fields', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(e.after) k where (e.after -> k) is distinct from (e.before -> k)),
                        'before', e.before, 'after', e.after) order by e.edited_at desc) from renter_edits e where e.renter_id = v_id), '[]'::jsonb));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0132c;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call = 'ops_read' and p_name = 'renter_edit_form') or (p_call = 'ops_do' and p_name = 'renter_edit') then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    if p_name = 'renter_edit_form' then return app.renter_edit_form(p_user, p_); end if;
    return app.renter_edit(p_user, p_);
  end if;
  return app.door_pre0132c(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['renter_snapshot', 'may_edit_renter', 'renter_edit', 'renter_edit_form', 'door', 'door_pre0132c'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 9. the balance after a change, and paying it
-- The owner (booking CC-10012): "we forgot to charge a young drivers fee and there's no way to add it in rn. And also
-- when changes are made they need to be updated of their outstanding balance and we need to be able to process the
-- payment." A fee is added from the catalogue (the young driver fee priced from the settings for the days) or as a line
-- of its own (custom_fee, with or without HST); after any change the booking shows what is open, and staff send the
-- renter one pay link for exactly the balance (covers 'balance': the rental first, then the fees), or record cash or an
-- e-Transfer, or charge the saved card. The renter's booking page shows the balance with Pay.
insert into fee_types (code, label, family, unit, per_what, revenue_class, hst_applies, stage, change_booking, in_master_spec, sort_order)
select 'custom_fee', 'Other charge', 'fee', 'flat', 'rental', revenue_class, true, 'booking', true, false, 140 from fee_types where code = 'delivery'
on conflict (code) do nothing;

alter table payment_requests drop constraint if exists payment_requests_covers_check;
alter table payment_requests add constraint payment_requests_covers_check check (covers in ('rental', 'deposit', 'fees', 'later', 'card', 'balance'));

-- what is open by part, with a card payment of the balance paying the rental first, then the fees
alter function app.booking_part_open(uuid, text) rename to booking_part_open_raw;
select pg_temp.patch_fn('app.booking_part_open_raw(uuid, text)'::regprocedure, $o$  v_rental bigint;$o$, $n$  v_rental bigint;
  v_whole bigint := 0;$n$);
-- a card payment of the whole booking (the website's, or the saved card charged by staff) no longer closes every part
-- for good: it pays the rental first, then the fees, so a fee added after it (the young driver fee forgotten) is open
select pg_temp.patch_fn('app.booking_part_open_raw(uuid, text)'::regprocedure,
  $o$  if exists (select 1 from payments x where x.booking_id = p_booking and x.purpose = 'booking_total' and x.method = 'card' and x.kind in ('charge', 'capture') and x.status = 'succeeded'
               and not exists (select 1 from payment_requests q where q.payment_id = x.id)) then
    return 0;
  end if;$o$,
  $n$  v_whole := (select coalesce(sum(x.amount_cents), 0) from payments x where x.booking_id = p_booking and x.purpose = 'booking_total' and x.method = 'card' and x.kind in ('charge', 'capture')
                  and x.status = 'succeeded' and not exists (select 1 from payment_requests q where q.payment_id = x.id))
            - (select coalesce(sum(r.amount_cents), 0) from payments r join payments x on x.id = r.parent_payment_id where r.booking_id = p_booking and r.kind = 'refund' and r.status = 'succeeded'
                  and x.purpose = 'booking_total' and x.method = 'card' and not exists (select 1 from payment_requests q where q.payment_id = x.id));
  if v_whole > 0 then
    v_paid := v_paid + case when p_covers = 'rental' then least(v_whole, v_rental) else greatest(v_whole - v_rental, 0) end;
    v_rental := greatest(v_rental - v_whole, 0);   -- what the card left of the rental, for a payment of no part below
  end if;$n$);
create or replace function app.booking_part_open(p_booking uuid, p_covers text) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_bal bigint;
  v_r bigint;
begin
  if p_covers not in ('rental', 'fees', 'balance') then return app.booking_part_open_raw(p_booking, p_covers); end if;
  v_bal := app.card_part_paid(p_booking, 'balance');
  v_r := app.booking_part_open_raw(p_booking, 'rental');
  if p_covers = 'rental' then return greatest(v_r - v_bal, 0); end if;
  if p_covers = 'fees' then return greatest(app.booking_part_open_raw(p_booking, 'fees') - greatest(v_bal - v_r, 0), 0); end if;
  return greatest(v_r + app.booking_part_open_raw(p_booking, 'fees') - v_bal, 0);
end $$;
alter function app.booking_tie_lines(uuid, text, uuid) rename to booking_tie_lines_raw;
create or replace function app.booking_tie_lines(p_booking uuid, p_covers text, p_payment uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_covers = 'balance' then
    perform app.booking_tie_lines_raw(p_booking, 'rental', p_payment);
    perform app.booking_tie_lines_raw(p_booking, 'fees', p_payment);
  else
    perform app.booking_tie_lines_raw(p_booking, p_covers, p_payment);
  end if;
end $$;
select pg_temp.patch_fn('app.payreq_create(uuid, jsonb)'::regprocedure,
  $o$    if v_covers not in ('rental', 'fees', 'later') then raise exception 'Choose what the card pays: the rental, fees or a later charge' using errcode = '22023'; end if;$o$,
  $n$    if v_covers not in ('rental', 'fees', 'later', 'balance') then raise exception 'Choose what the card pays: the balance, the rental, fees or a later charge' using errcode = '22023'; end if;$n$);

-- a line of its own on a booking (a charge the catalogue has not got): its label, amount before HST, and whether HST applies
create or replace function app.booking_custom_fee(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_label text := nullif(btrim(coalesce(p ->> 'label', '')), '');
  v_hst boolean := coalesce((p ->> 'hst')::boolean, true);
  v_id uuid;
begin
  if not app.may_edit_fees(p_by) then raise exception 'Only an Admin, or customer service and sales while Program settings let staff change fees, adds a charge' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text in ('cancelled', 'declined', 'expired', 'no_show') then raise exception 'Booking % is %', b.booking_number, b.status using errcode = '23514'; end if;
  if v_label is null then raise exception 'Say what the charge is for (the renter sees it)' using errcode = '22023'; end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
  select b.id, 'custom_fee', v_label, 1, v_amount, v_amount, v_hst, case when v_hst then public.calc_hst(v_amount, b.hst_bps) else 0 end, f.revenue_class, 'booking'
    from fee_types f where f.code = 'custom_fee'
  returning id into v_id;
  perform app.sync_booking_price(b.id);
  insert into booking_fee_changes (booking_id, line_key, label, before_cents, after_cents, reason, booking_status, changed_by)
  values (b.id, 'custom_fee', v_label, null, v_amount, nullif(btrim(coalesce(p ->> 'reason', '')), ''), b.status::text, p_by);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version, format('Charge added: %s, %s%s', v_label, app.fmt_money(v_amount), case when v_hst then ' plus HST' else '' end), p_by, 'staff',
    jsonb_build_object('line_id', v_id));
  if b.status::text in ('returned', 'closed') then begin perform app.compute_booking_split(b.id); exception when others then null; end; end if;
  begin perform app.commission_sync(b.id); exception when others then null; end;
  select * into b from bookings where id = b.id;
  return jsonb_build_object('ok', true, 'line_id', v_id, 'total_cents', b.total_due_at_booking_cents, 'open_cents', app.booking_part_open(b.id, 'balance'));
end $$;

-- the fee a booking would carry for a catalogue key it has not got (the young driver fee for its days, from the settings)
create or replace function app.booking_fee_suggestion(p_booking uuid, p_key text) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  t record;
  v_rate bigint;
begin
  select * into b from bookings where id = p_booking;
  if p_key in ('young_driver_18_20', 'young_driver_21_25', 'additional_driver') then
    select * into t from app.fee_term(p_key, b.vehicle_id, app.local_date(b.booked_at), p_booking);
    v_rate := app.fee_per_day(to_jsonb(t), b.daily_rate_cents);
    if coalesce(v_rate, 0) <= 0 then return null; end if;
    return app.calc_capped_periods(v_rate, b.pickup_at, b.return_at, (to_jsonb(t) ->> 'cap_cents')::bigint);
  elsif p_key = 'delivery' then
    return (select r.delivery_fee_cents from rate_cards r where r.vehicle_id = b.vehicle_id and r.effective_to is null limit 1);
  elsif p_key = 'pickup' then
    return (select r.pickup_fee_cents from rate_cards r where r.vehicle_id = b.vehicle_id and r.effective_to is null limit 1);
  end if;
  return null;
end $$;
alter function app.booking_fees(uuid, jsonb) rename to booking_fees_pre0132b;
create or replace function app.booking_fees(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.booking_fees_pre0132b(p_by, p);
  v_id uuid := (select b.id from bookings b where b.booking_number = x ->> 'booking_number');
begin
  return x || jsonb_build_object(
    'addable', coalesce((select jsonb_agg(a || jsonb_build_object('suggested_cents', app.booking_fee_suggestion(v_id, a ->> 'key'))) from jsonb_array_elements(x -> 'addable') a), '[]'::jsonb),
    'parts', jsonb_build_object('rental', app.booking_part_open(v_id, 'rental'), 'fees', app.booking_part_open(v_id, 'fees'), 'balance', app.booking_part_open(v_id, 'balance')),
    'card', (select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4) from bookings b join payment_methods pm on pm.id = b.card_on_file_id and pm.status = 'active' where b.id = v_id),
    'renter_reach', (select jsonb_build_object('email', coalesce(r.email, u.email) is not null, 'mobile', r.mobile is not null) from bookings b join renters r on r.id = b.renter_id left join users u on u.id = r.user_id where b.id = v_id));
end $$;

-- the renter pays the balance from their booking page: a pay link for exactly what is open
create or replace function public.renter_balance_payreq(p_booking uuid, p_by uuid, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_open bigint;
  v_id uuid;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  if b.status::text not in ('confirmed', 'on_rent', 'returned') then raise exception 'Nothing to pay on this booking here' using errcode = '23514'; end if;
  v_open := app.booking_part_open(b.id, 'balance');
  if v_open <= 0 then raise exception 'Nothing is owing on this booking' using errcode = '23514'; end if;
  if p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  update payment_requests set status = 'cancelled' where booking_id = b.id and status = 'open' and kind = 'charge' and covers = 'balance';
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by)
  values (b.id, b.renter_id, 'charge', 'balance', v_open, 'the balance of your booking', p_token_sha256, 'link', now() + interval '2 hours', p_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'kind', 'charge', 'covers', 'balance', 'amount_cents', v_open, 'booking_id', b.id, 'booking_number', b.booking_number,
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email), 'mobile', r.mobile,
                 'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                                  where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1))
                 from renters r left join users u on u.id = r.user_id where r.id = b.renter_id));
end $$;
create or replace function public.renter_balance(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return jsonb_build_object('balance_cents', app.booking_part_open(p_booking, 'balance'),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('description', coalesce(li.description, f.label), 'amount_cents', li.amount_cents, 'hst_cents', li.hst_cents) order by li.created_at)
                        from booking_line_items li join fee_types f on f.code = li.charge_type
                       where li.booking_id = p_booking and li.stage = 'booking' and li.voided_at is null and li.charged_to_renter), '[]'::jsonb));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0132d;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if p_call = 'ops_do' and p_name = 'booking_custom_fee' then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    return app.booking_custom_fee(p_user, p_);
  end if;
  return app.door_pre0132d(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['booking_part_open_raw', 'booking_part_open', 'booking_tie_lines', 'booking_tie_lines_raw', 'booking_custom_fee',
                     'booking_fee_suggestion', 'booking_fees', 'booking_fees_pre0132b', 'door', 'door_pre0132d']))
               or (n.nspname = 'public' and p.proname = any (array['renter_balance_payreq', 'renter_balance']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 10. every row of the price editable where it is entered
-- The owner, with a picture of the quick rental form's price: "each field needs to be editable when uploading a rental or
-- sending an offer back." The quick rental form and the offer screen take, besides each fee set by hand: lines of their
-- own (custom_fees: [{label, amount_cents, hst}]) and the kilometres a day; the quote prices them before anything is saved.
create or replace function app.custom_fee_lines(p jsonb, p_hst integer) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(app.price_line('custom_fee', 1, (x ->> 'amount_cents')::bigint, (x ->> 'amount_cents')::bigint, case when coalesce((x ->> 'hst')::boolean, true) then p_hst else 0 end,
                                           btrim(x ->> 'label')) || jsonb_build_object('hst_applies', coalesce((x ->> 'hst')::boolean, true), 'custom', true)), '[]'::jsonb)
    from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) x
   where nullif(btrim(coalesce(x ->> 'label', '')), '') is not null and coalesce(nullif(x ->> 'amount_cents', '')::bigint, 0) > 0
$$;
create or replace function app.booking_custom_fees_add(p_booking uuid, p_by uuid, p jsonb, p_reason text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb;
  n integer := 0;
begin
  for x in select value from jsonb_array_elements(app.custom_fee_lines(p, (select hst_bps from bookings where id = p_booking))) loop
    if not app.may_edit_fees(p_by) then raise exception 'Only an Admin, or customer service and sales while Program settings let staff change fees, adds a charge' using errcode = '42501'; end if;
    insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
    values (p_booking, 'custom_fee', x ->> 'description', 1, (x ->> 'amount_cents')::bigint, (x ->> 'amount_cents')::bigint, (x ->> 'hst_applies')::boolean, (x ->> 'hst_cents')::bigint,
            (x ->> 'revenue_class')::revenue_class, 'booking');
    insert into booking_fee_changes (booking_id, line_key, label, before_cents, after_cents, reason, booking_status, changed_by)
    select p_booking, 'custom_fee', x ->> 'description', null, (x ->> 'amount_cents')::bigint, p_reason, b.status::text, p_by from bookings b where b.id = p_booking;
    n := n + 1;
  end loop;
  return n;
end $$;
-- the quick rental form's quote: the lines of its own priced in, and the kilometres asked for
alter function app.manual_rental_quote(uuid, jsonb) rename to manual_rental_quote_pre0132;
create or replace function app.manual_rental_quote(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  out jsonb := app.manual_rental_quote_pre0132(p_by, p - 'custom_fees' - 'km_allowance_per_day');
  v_extra jsonb;
  v_hst integer := (app.settings()).hst_bps;
  v_sub bigint;
  v_tax bigint;
begin
  if app.may_edit_fees(p_by) and jsonb_typeof(p -> 'custom_fees') = 'array' then
    v_extra := app.custom_fee_lines(p -> 'custom_fees', v_hst);
    if jsonb_array_length(v_extra) > 0 then
      select coalesce(sum((l ->> 'amount_cents')::bigint), 0), coalesce(sum((l ->> 'hst_cents')::bigint), 0) into v_sub, v_tax from jsonb_array_elements(v_extra) l;
      out := jsonb_set(out, '{quote,lines}', (out #> '{quote,lines}') || v_extra);
      out := jsonb_set(out, '{quote,total_due_at_booking_cents}', to_jsonb((out #>> '{quote,total_due_at_booking_cents}')::bigint + v_sub + v_tax));
    end if;
  end if;
  if nullif(p ->> 'km_allowance_per_day', '') is not null then
    out := jsonb_set(out, '{quote,km_allowance_total}', to_jsonb((p ->> 'km_allowance_per_day')::integer * coalesce((out #>> '{quote,billable_days}')::integer, 1)));
    out := jsonb_set(out, '{quote,km_allowance_per_day}', to_jsonb((p ->> 'km_allowance_per_day')::integer));
  end if;
  return out;
end $$;
-- the rental: its own lines go in before it is priced and paid (so the first payment covers them), the kilometres after
select pg_temp.patch_fn('app.manual_rental_create_0058(uuid, jsonb)'::regprocedure,
  $o$  if jsonb_typeof(p -> 'line_overrides') = 'object' and p -> 'line_overrides' <> '{}'::jsonb then   -- 0132: fees set by hand$o$,
  $n$  perform app.booking_custom_fees_add(b.id, p_by, p -> 'custom_fees', coalesce(nullif(btrim(coalesce(p ->> 'fee_reason', '')), ''), 'Added when the rental was entered'));
  if jsonb_typeof(p -> 'line_overrides') = 'object' and p -> 'line_overrides' <> '{}'::jsonb then   -- 0132: fees set by hand$n$);
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0132b;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb := app.manual_rental_create_pre0132b(p_by, p - 'km_allowance_per_day');
  v_km integer := nullif(p ->> 'km_allowance_per_day', '')::integer;
begin
  if v_km is not null and v_km >= 0 then
    update bookings set km_allowance_per_day = v_km, km_allowance_total = v_km * billable_days where id = (v_out ->> 'booking_id')::uuid;
  end if;
  return v_out;
end $$;
-- the offer: its own lines through the review screen's edit (so the preview and the offer sent carry them)
alter function app.admin_apply_booking_edit(uuid, uuid, jsonb) rename to admin_apply_booking_edit_pre0132b;
create or replace function app.admin_apply_booking_edit(p_admin uuid, p_booking uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.admin_apply_booking_edit_pre0132b(p_admin, p_booking, p - 'custom_fees');
  if jsonb_typeof(p -> 'custom_fees') = 'array' and jsonb_array_length(p -> 'custom_fees') > 0 then
    delete from booking_line_items where booking_id = p_booking and charge_type = 'custom_fee' and stage = 'booking' and payment_id is null;   -- an offer edited again: its lines as now typed
    perform app.booking_custom_fees_add(p_booking, p_admin, p -> 'custom_fees', coalesce(nullif(btrim(coalesce(p ->> 'fee_reason', '')), ''), 'Set on the offer'));
    perform app.sync_booking_price(p_booking);
  end if;
end $$;
select pg_temp.patch_fn('app.staff_offer_create(uuid, jsonb)'::regprocedure,
  $o$    'fee_reason', p -> 'fee_reason',$o$,
  $n$    'fee_reason', p -> 'fee_reason', 'custom_fees', case when jsonb_typeof(p -> 'custom_fees') = 'array' and jsonb_array_length(p -> 'custom_fees') > 0 then p -> 'custom_fees' end,$n$);
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['custom_fee_lines', 'booking_custom_fees_add', 'manual_rental_quote', 'manual_rental_quote_pre0132', 'manual_rental_create',
                     'manual_rental_create_pre0132b', 'admin_apply_booking_edit', 'admin_apply_booking_edit_pre0132b'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 11. every confirmed booking gets its agreement
-- Booking CC-10013 (added by hand, confirmed, with an additional driver) had no rental agreement at all: a rental added by
-- hand opened its agreement only when the renter first opened the signing page, so a renter who never did was never asked
-- to sign and the additional driver never got a link. Now the site opens it for every confirmed or on-trip booking that has
-- none (not signed on paper), right after a rental is added and on the five-minute job: the agreement and Blind Spot's,
-- the renter's "sign your agreement" (email and text, by the renter's choice of channel) and each additional driver's own
-- link. Reminders before pickup are the existing ones (0023). The bookings already confirmed without one are queued here
-- and logged in the audit log; the first job run opens and sends them.
create table if not exists agreement_auto_runs (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings (id) on delete cascade,
  ran_at     timestamptz not null default now(),
  ok         boolean not null,
  error      text,
  source     text not null default 'job'
);
comment on table agreement_auto_runs is 'The site opening a confirmed booking''s rental agreement by itself (0132): each try, ok or with the error (three failures stop the tries; staff see the task).';
create index if not exists agreement_auto_runs_booking on agreement_auto_runs (booking_id, ran_at);
alter table agreement_auto_runs enable row level security;
create policy admin_all on agreement_auto_runs for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on agreement_auto_runs from anon, authenticated;
grant all on agreement_auto_runs to service_role;
create trigger audit_agreement_auto_runs after insert or update or delete on agreement_auto_runs for each row execute function app.audit_row();

create or replace function app.booking_needs_agreement(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select b.status::text in ('confirmed', 'on_rent') and b.booking_type <> 'owner' and not coalesce(b.agreement_on_paper, false)
     and exists (select 1 from renters r where r.id = b.renter_id and r.user_id is not null)
     and not exists (select 1 from rental_agreements a where a.booking_id = b.id and a.status in ('open', 'signed', 'completed'))
     and not exists (select 1 from paper_signatures ps where ps.booking_id = b.id and ps.voided_at is null)
     and (select count(*) from agreement_auto_runs x where x.booking_id = b.id and not x.ok) < 3
$$;
create or replace function public.server_agreements_due(p_limit integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', q.id, 'booking_number', q.booking_number, 'renter_user_id', q.user_id) order by q.pickup_at), '[]'::jsonb)
    from (select b.id, b.booking_number, b.pickup_at, r.user_id from bookings b join renters r on r.id = b.renter_id
           where app.booking_needs_agreement(b) order by b.pickup_at limit greatest(p_limit, 1)) q
$$;
-- after the site opened (or failed to open) the agreement: the renter's "sign your agreement" (the driver links went with it)
create or replace function public.server_agreement_auto_done(p_booking uuid, p_ok boolean, p_error text default null, p_source text default 'job') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a rental_agreements;
  g rental_agreement_signers;
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  insert into agreement_auto_runs (booking_id, ok, error, source) values (p_booking, p_ok, left(p_error, 500), coalesce(p_source, 'job'));
  if not p_ok then
    if (select count(*) from agreement_auto_runs x where x.booking_id = p_booking and not x.ok) >= 3 then
      perform app.raise_task(p_type => 'paper_agreement_scan', p_title => format('Booking %s: the rental agreement could not be made by itself. Open the booking and press Sign now, or record it on paper', b.booking_number),
        p_booking => p_booking, p_renter => b.renter_id, p_dedupe => 'agreement_auto_failed:' || p_booking);
    end if;
    return jsonb_build_object('ok', false);
  end if;
  select * into a from rental_agreements where booking_id = p_booking and status = 'open' order by opened_at desc limit 1;
  for g in select * from rental_agreement_signers where agreement_id = a.id and signer_role = 'renter' and signed_at is null loop
    perform app.emit_event('renter_agreement_ready', 'rental_agreement', a.id,
      jsonb_build_object('booking_id', p_booking, 'booking_number', b.booking_number, 'agreement_number', a.agreement_number, 'signer_id', g.id,
                         'signer_role', g.signer_role, 'signer_name', g.signer_name, 'signer_email', g.signer_email, 'signer_user_id', g.user_id, 'opened_by_site', true),
      'renter_agreement_ready:' || a.id || ':' || g.id);
  end loop;
  perform app.log_booking_event(p_booking, 'adjusted', b.status::text, b.status::text, null, 'Rental agreement made and sent to sign (the renter and each additional driver)', null, 'system',
    jsonb_build_object('agreement_id', a.id, 'source', p_source));
  return jsonb_build_object('ok', true, 'agreement_id', a.id);
end $$;
-- the five-minute job runs when there is work
alter function app.server_jobs_due() rename to server_jobs_due_pre0132;
create or replace function app.server_jobs_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.server_jobs_due_pre0132() || jsonb_build_object('agreements', exists (select 1 from bookings b where b.status::text in ('confirmed', 'on_rent') and app.booking_needs_agreement(b)))
$$;
revoke all on function app.booking_needs_agreement(bookings), public.server_agreements_due(integer), public.server_agreement_auto_done(uuid, boolean, text, text),
  app.server_jobs_due(), app.server_jobs_due_pre0132() from public, anon, authenticated;
grant execute on function app.booking_needs_agreement(bookings), public.server_agreements_due(integer), public.server_agreement_auto_done(uuid, boolean, text, text),
  app.server_jobs_due(), app.server_jobs_due_pre0132() to service_role;
-- the repair: confirmed or on-trip bookings with no agreement today, logged; the first job run makes and sends them
insert into audit_log (action, entity_table, entity_id, after)
select 'agreement_repair_queued', 'bookings', b.id::text, jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'migration', '0132')
  from bookings b where app.booking_needs_agreement(b);
do $$
declare n integer;
begin
  select count(*) into n from bookings b where app.booking_needs_agreement(b);
  raise notice '0132: % confirmed or on-trip booking(s) have no rental agreement; queued for the agreements job (audit_log agreement_repair_queued)', n;
end $$;

-- ================================================================ the guides
-- GUIDES 0132 START (generated by supabase/seed/0132_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

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

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

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
', 'Requests, offers and bookings', 'Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

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

## Send an offer without a request

**Bookings** > **Send an offer**, or **Send an offer** on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.

1. The customer: type a name, phone or email and choose them. Not on file? Press **Add a new customer**: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.
2. The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).
3. The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.
4. How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).
5. Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.
6. The right side is the offer as the renter will see it, priced by the database as you type. Press **Send the offer**. **Save without sending** keeps it as a request for later.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press **Edit the offer** on the booking.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.
2. Write what changed in Message to the renter and choose how long the offer is open.
3. Press **Save and send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without telling the renter** and tell them yourself.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.

## Payments by part: the rental, the deposit and later charges

On the booking''s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.

1. **Record a payment**: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press **Record it**. The renter gets a receipt; **Print** prints one to hand over.
2. **Collect a card**: a payment, the deposit hold or saving the card. The renter types the card in Stripe''s secure form: on this device (**Open the card form**, then hand it over) or by a link texted or emailed to them (**Send the link**). Staff never type a card number.
3. A deposit hold lasts about 7 days and shows the days left. After the return, **Capture the hold** (all or part, with the reason) or **Release the hold**.
4. **Charge the saved card** (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter''s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.
5. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check out (pickup)** under Check-out, check-in and signing; a booking on rent shows **Check in (return)**. Today lists the check-outs and check-ins due, each with **Check out** or **Check in**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-out, check-in and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-in time** (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
3. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
4. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. Tick the checks, then **Approve**. Or type the reason the renter reads and press **Reject**: they are asked for a new one.
4. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute.

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
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Send an offer</b>, or <b class="gd-ui">Send an offer</b> on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The customer: type a name, phone or email and choose them. Not on file? Press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason and can be plus tax or tax included. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The right side is the offer as the renter will see it, priced by the database as you type. Press <b class="gd-ui">Send the offer</b>. <b class="gd-ui">Save without sending</b> keeps it as a request for later.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press <b class="gd-ui">Edit the offer</b> on the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter and choose how long the offer is open.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save and send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without telling the renter</b> and tell them yourself.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-part-the-rental-the-deposit-and-later-charges" data-gd-task><h2 class="gd-h2">Payments by part: the rental, the deposit and later charges</h2><p class="gd-p">On the booking&#39;s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press <b class="gd-ui">Record it</b>. The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Collect a card</b>: a payment, the deposit hold or saving the card. The renter types the card in Stripe&#39;s secure form: on this device (<b class="gd-ui">Open the card form</b>, then hand it over) or by a link texted or emailed to them (<b class="gd-ui">Send the link</b>). Staff never type a card number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit hold lasts about 7 days and shows the days left. After the return, <b class="gd-ui">Capture the hold</b> (all or part, with the reason) or <b class="gd-ui">Release the hold</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge the saved card</b> (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter&#39;s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check out (pickup)</b> under Check-out, check-in and signing; a booking on rent shows <b class="gd-ui">Check in (return)</b>. Today lists the check-outs and check-ins due, each with <b class="gd-ui">Check out</b> or <b class="gd-ui">Check in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-out, check-in and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-in time</b> (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick the checks, then <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section>');
select app.guide_release_section('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. When the VIN fits several trims, the form asks which trim it is: press the one on the car''s papers or badge, or **Not sure** (Admin > Today asks again).
3. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
4. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
5. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
6. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
7. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

The gearbox comes from the government''s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin > Today shows **Confirm gearbox and seats**: press the gearbox and the number of seats, then **Save**. A car whose VIN fits several trims shows **Pick the trim** there: press the right one. Either way the title, description and search text are written again.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**People** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **People** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
2. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
3. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
4. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
5. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
6. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
7. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
8. The rental is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. The deposit is taken by card hold, cash, e-Transfer or no deposit.
9. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
10. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. When the VIN fits several trims, the form asks which trim it is: press the one on the car''s papers or badge, or **Not sure** (Admin > Today asks again).
3. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
4. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
5. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
6. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
7. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

The gearbox comes from the government''s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin > Today shows **Confirm gearbox and seats**: press the gearbox and the number of seats, then **Save**. A car whose VIN fits several trims shows **Pick the trim** there: press the right one. Either way the title, description and search text are written again.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**People** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **People** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
2. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
3. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
4. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
5. Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes.
6. Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed.
7. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
8. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
9. The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press **Add another payment (paid in parts)** and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.
10. Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit and the agreement.
11. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
12. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the VIN fits several trims, the form asks which trim it is: press the one on the car&#39;s papers or badge, or <b class="gd-ui">Not sure</b> (Admin &gt; Today asks again).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">The gearbox comes from the government&#39;s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin &gt; Today shows <b class="gd-ui">Confirm gearbox and seats</b>: press the gearbox and the number of seats, then <b class="gd-ui">Save</b>. A car whose VIN fits several trims shows <b class="gd-ui">Pick the trim</b> there: press the right one. Either way the title, description and search text are written again.</p><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-fleet-on-its-own-rates" data-gd-task><h2 class="gd-h2">A partner fleet on its own rates</h2><p class="gd-p">Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner. <b class="gd-ui">Pricing</b> shows how it is paid: the renter pays the partner&#39;s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press <b class="gd-ui">Edit pricing</b> to change the markup, the cut or the basis for every car at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Cars</b> lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter&#39;s rates. Press <b class="gd-ui">Edit</b> on a car to change a negotiated rate, give that car its own markup or cut, mark it <b class="gd-ui">Insurance included</b> or <b class="gd-ui">No credit card needed</b>, or confirm its model year. The renter&#39;s rates change at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and &quot;Guideline rates; final price confirmed after review&quot;. A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says &quot;Year confirmed when you book&quot;; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car&#39;s page before its first handover.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Real photos: open the car (its name in Cars), <b class="gd-ui">Photos</b>, and add them. Once approved they replace the eight studio stand-ins.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The partner&#39;s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner&#39;s share in proportion; a discount CarmaCars gives comes out of the markup.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Quick start sets the usual choices in one tap: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b>, <b class="gd-ui">Insurance replacement</b>, <b class="gd-ui">Owner using own car</b> or <b class="gd-ui">Placeholder</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press <b class="gd-ui">Add another payment (paid in parts)</b> and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit and the agreement.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car&#39;s calendar for an insurance replacement with dates not known yet, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> asks first (&quot;Hide all 20 sample cars from the site?&quot;); press <b class="gd-ui">Hide them</b> to take every sample car off the site at once, or <b class="gd-ui">Keep them</b>. Nothing else stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Owner leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (**Record a payment**, For: the rental and fees).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Tick every check under a document, then press **Approve**. Or type the reason the renter reads and press **Reject**.
3. The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Owner leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-send-an-offer-to-a-caller" data-gd-task><h2 class="gd-h2">Send an offer to a caller</h2><p class="gd-p">Open <b class="gd-ui">Send an offer</b> (or <b class="gd-ui">Send an offer</b> beside a car in Find a car). No request needed: one screen, and the renter has the link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the customer by name, phone or email, or press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the offer as the renter will see it on the right, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An offer that is out is changed in place: <b class="gd-ui">Edit the offer</b>, change it, then <b class="gd-ui">Save and send the update</b> or <b class="gd-ui">Save without telling the renter</b>. No need to withdraw it first.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-edit-a-booking-a-fee-or-the-renter" data-gd-task><h2 class="gd-h2">Edit a booking, a fee or the renter</h2><p class="gd-p">A booking that is confirmed, on trip or returned is edited directly; the renter&#39;s details are corrected from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Overview, <b class="gd-ui">Edit the booking</b>: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Money tab, Fees, <b class="gd-ui">Change or add a fee</b>: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, or record cash or an e-Transfer (<b class="gd-ui">Record a payment</b>, For: the rental and fees).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Edit renter</b>: a wrong email, phone, name, licence or address. A new email is their sign-in at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is recorded with your name, the time, the reason and the before and after.</div></aside></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">A renter or an additional driver who has not signed yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking, press <b class="gd-ui">Sign now on this device</b>. Confirm the name and that you saw the original licence, then <b class="gd-ui">Hand the device to</b> the signer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Email the signing link</b> or <b class="gd-ui">Text the signing link</b>: they sign on their own phone.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tick every check under a document, then press <b class="gd-ui">Approve</b>. Or type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The coverage: OPCF 27 shows the insurer, policy number and expiry; credit card coverage shows the card, its type and whether the name matches. Approve or reject it as a whole.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do.</div></aside></section><section class="gd-task" id="customer-service-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Which credit cards include rental car coverage?</h2><p class="gd-p">Renters ask this often. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Card coverage</b> (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Send the renter <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span>: each card&#39;s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car&#39;s model year and trim so they can check.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Never tell a renter they are covered. Their card&#39;s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card marked Unverified came from a published summary, not the issuer&#39;s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings &gt; Card coverage.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
select app.guide_release_section('va', 'add-a-rental-by-hand', 'chapter', 'sales', 'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.
3. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
4. The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.
5. Quick start: **Phone**, **Walk-in**, **Turo or another platform** or **Insurance replacement** sets the usual choices.
6. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
7. To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.
8. Choose how the rental is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin) and how the deposit is taken (card hold, cash or e-Transfer). Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car''s calendar and say why.
9. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
10. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
11. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
', 'Add a rental by hand', 'Choose the car and dates, find the renter, price it, record how it is paid.',
  'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.
3. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
4. The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.
5. Quick start: **Phone**, **Walk-in**, **Turo or another platform** or **Insurance replacement** sets the usual choices.
6. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
7. Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused.
8. Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed.
9. Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car''s calendar and say why.
10. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
11. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
12. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
',
  '<p class="gd-p">Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.</p><section class="gd-task" id="add-a-rental-by-hand-add-a-rental" data-gd-task><h2 class="gd-h2">Add a rental</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. Your home address must be in your profile first: until it is, the page asks for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Quick start: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b> or <b class="gd-ui">Insurance replacement</b> sets the usual choices.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner&#39;s car not yet on the fleet insurance policy is added by an Admin only.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car&#39;s calendar and say why.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Press <b class="gd-ui">Add the rental</b>. The renter gets the confirmation email unless you tick <b class="gd-ui">Do not email the renter</b>.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.</div></aside></section>');
-- GUIDES 0132 END
