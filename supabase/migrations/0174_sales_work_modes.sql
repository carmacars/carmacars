-- 0174_sales_work_modes.sql
-- Sales staff work in one of two modes, on the same Sales dashboard (docs/changes/2026-10-26-sales-work-modes.md). The
-- owner's decision of October 26, 2026. Wording everywhere: "in person" and "remote", never a nationality.
--
-- 1. staff_profiles.sales_work_mode: in_person or remote, for a Sales assistant (staff_type va, va_function sales); empty for
--    everyone else (a trigger keeps it so: a Sales assistant without a mode is in person, the rule before this release).
--    An Admin sets it on the staff page (admin_do staff_sales_mode_set); the hire flow calls app.staff_set_sales_mode.
-- 2. The Sales tiers by mode (Program settings): in person the 0058 tiers (10% under 50 rental days in the month, 15% from
--    50, 20% from 100); remote 5 points lower on every tier (sales_remote_tier_low/mid/high_bps: 5%, 10%, 15%), on the same
--    days. Remote has a monthly activity minimum (sales_remote_min_touches, 400 logged touches): below it, when the month
--    ends, the month's rate is sales_remote_drop_tiers (1) tier lower; dropping below the lowest tier gives
--    sales_remote_floor_bps (2.5%). Each month's schedule (the mode, the tier rates and days, the minimum, the touches and
--    the drop) is kept in sales_month_rates and locked when an Admin approves the month: a later change of the settings or
--    of the person's mode, or a touch voided later, does not change it. The rental days still move the tier inside the
--    locked schedule (a refund after payment lowers the tier and is clawed back, staff agreement 3.4, as before).
--    staff_commissions.work_mode keeps the mode of each commission.
-- 3. Credit: in person as before (rentals they source or an Admin credits: walk-ins, handovers they close, partner visits).
--    Remote: only rentals they source. A walk-in (source walk_in), a partner deal (source partner, or a referral partner on
--    the booking) earns a remote rep nothing; a website request they answer with the first offer during one of their
--    availability blocks is credited to them as sourced, with a line in the booking's history.
-- 4. Remote duties: sales_touches (follow-up, repost, DM reply, outreach call, email or text, owner outreach), logged by
--    themselves where the system knows (an offer sent, a portal message or text, a live chat answered, a call or text from
--    the phone line, an ad posted, an owner recruitment call or message) and by hand ("Log a touch": type and an optional
--    link); sales_availability (the weekly blocks the rep submits; the peak hours are Thursday to Sunday afternoons,
--    sales_remote_peak_from_hour to sales_remote_peak_until_hour Toronto time, sales_remote_cover_hours (20) a week); the
--    reply time on chats and reply tasks assigned to them during their blocks (target sales_remote_reply_minutes, 15).
-- 5. Reads: va_read sales_duties (the person's own), admin_read sales_modes and sales_duties; writes: va_do sales_touch_log,
--    sales_availability_save; admin_do staff_sales_mode_set, sales_touch_void.
-- Functions changed are wrapped (suffix _pre0174) or replaced where noted. No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists sales_remote_tier_low_bps integer not null default 500 check (sales_remote_tier_low_bps between 0 and 10000),
  add column if not exists sales_remote_tier_mid_bps integer not null default 1000 check (sales_remote_tier_mid_bps between 0 and 10000),
  add column if not exists sales_remote_tier_high_bps integer not null default 1500 check (sales_remote_tier_high_bps between 0 and 10000),
  add column if not exists sales_remote_min_touches integer not null default 400 check (sales_remote_min_touches between 0 and 10000),
  add column if not exists sales_remote_drop_tiers integer not null default 1 check (sales_remote_drop_tiers between 0 and 3),
  add column if not exists sales_remote_floor_bps integer not null default 250 check (sales_remote_floor_bps between 0 and 10000),
  add column if not exists sales_remote_cover_hours integer not null default 20 check (sales_remote_cover_hours between 0 and 84),
  add column if not exists sales_remote_reply_minutes integer not null default 15 check (sales_remote_reply_minutes between 1 and 240),
  add column if not exists sales_remote_peak_from_hour integer not null default 12 check (sales_remote_peak_from_hour between 0 and 23),
  add column if not exists sales_remote_peak_until_hour integer not null default 18 check (sales_remote_peak_until_hour between 1 and 24);
alter table program_settings drop constraint if exists program_settings_sales_remote_peak_check;
alter table program_settings add constraint program_settings_sales_remote_peak_check check (sales_remote_peak_until_hour > sales_remote_peak_from_hour);
comment on column program_settings.sales_remote_tier_low_bps is 'Remote Sales (0174): commission under sales_tier_mid_days rental days in the month, 5% by default (5 points under in person)';
comment on column program_settings.sales_remote_tier_mid_bps is 'Remote Sales (0174): commission from sales_tier_mid_days rental days, 10% by default';
comment on column program_settings.sales_remote_tier_high_bps is 'Remote Sales (0174): commission from sales_tier_high_days rental days, 15% by default';
comment on column program_settings.sales_remote_min_touches is 'Remote Sales (0174): touches to log in a calendar month (400 by default); below it the month''s rate drops sales_remote_drop_tiers tiers when the month ends';
comment on column program_settings.sales_remote_drop_tiers is 'Remote Sales (0174): tiers the month''s rate drops when the touches are under the minimum (1 by default; 0 switches the drop off). Below the lowest tier: sales_remote_floor_bps';
comment on column program_settings.sales_remote_floor_bps is 'Remote Sales (0174): the month''s rate when the drop goes below the lowest remote tier, 2.5% by default';
comment on column program_settings.sales_remote_cover_hours is 'Remote Sales (0174): peak hours (Thursday to Sunday afternoons, Toronto time) to cover each week, 20 by default';
comment on column program_settings.sales_remote_reply_minutes is 'Remote Sales (0174): reply target on chats, texts and calls assigned during the rep''s blocks, 15 minutes by default';
comment on column program_settings.sales_remote_peak_from_hour is 'Remote Sales (0174): the peak hours start (Toronto hour, 12 is noon), Thursday to Sunday';
comment on column program_settings.sales_remote_peak_until_hour is 'Remote Sales (0174): the peak hours end (Toronto hour, 18 is 6 pm), Thursday to Sunday';

-- ================================================================ 2. the mode
alter table staff_profiles add column if not exists sales_work_mode text check (sales_work_mode in ('in_person', 'remote'));
comment on column staff_profiles.sales_work_mode is 'Sales assistants only (0174): in_person (Toronto, 10/15/20% tiers, credit for walk-ins, handovers, partner visits and rentals they source) or remote (worldwide contractor, 5/10/15%, peak-hour cover, daily lead generation, a monthly minimum of touches, credit only for rentals they source). Empty for everyone else';
alter table staff_commissions add column if not exists work_mode text check (work_mode in ('in_person', 'remote'));
comment on column staff_commissions.work_mode is 'The Sales mode of the month the commission counts in (0174): in_person or remote; empty outside the Sales tiers';

-- A Sales assistant always has a mode (in person unless an Admin chose remote); nobody else has one.
create or replace function app.staff_profiles_sales_mode() returns trigger
language plpgsql set search_path = public, app as $$
begin
  if new.staff_type = 'va' and new.va_function::text = 'sales' then
    new.sales_work_mode := coalesce(new.sales_work_mode, 'in_person');
  else
    new.sales_work_mode := null;
  end if;
  return new;
end $$;
drop trigger if exists staff_profiles_sales_mode on staff_profiles;
create trigger staff_profiles_sales_mode before insert or update of staff_type, va_function, sales_work_mode on staff_profiles
  for each row execute function app.staff_profiles_sales_mode();
update staff_profiles set sales_work_mode = 'in_person' where staff_type = 'va' and va_function::text = 'sales' and sales_work_mode is null;

-- ================================================================ 3. tables
create table if not exists sales_month_rates (
  staff_id        uuid not null references users (id),
  month           date not null check (month = date_trunc('month', month)::date),
  work_mode       text not null check (work_mode in ('in_person', 'remote')),
  tier_low_bps    integer not null,
  tier_mid_bps    integer not null,
  tier_high_bps   integer not null,
  tier_mid_days   integer not null,
  tier_high_days  integer not null,
  min_touches     integer not null default 0,
  drop_tiers      integer not null default 0,
  floor_bps       integer not null default 0,
  touches         integer not null default 0,
  tier_days       integer not null default 0,
  tier_bps        integer not null default 0,
  rate_bps        integer not null default 0,
  below_minimum   boolean not null default false,
  dropped         boolean not null default false,
  locked_at       timestamptz,
  locked_by       uuid references users (id),
  updated_at      timestamptz not null default now(),
  primary key (staff_id, month)
);
comment on table sales_month_rates is 'A Sales staff member''s month (0174): the mode and the schedule used (tier rates and days, the remote minimum and drop), the touches, the rental days, the tier and the rate. Kept up to date by app.commission_retier; the schedule is locked when an Admin approves the month (locked_at), after which only the rental days move the tier.';

create table if not exists sales_touches (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references users (id),
  at          timestamptz not null default now(),
  kind        text not null check (kind in ('follow_up', 'repost', 'dm_reply', 'outreach_call', 'outreach_email', 'outreach_text', 'owner_outreach')),
  source      text not null check (source in ('manual', 'offer', 'message', 'chat', 'phone', 'ad_posting', 'recruit_call', 'recruit_message')),
  source_key  text unique,
  booking_id  uuid references bookings (id) on delete set null,
  link        text check (link is null or (length(link) <= 500 and link ~ '^https?://[^[:space:]]+$')),
  note        text check (note is null or length(note) <= 300),
  voided_at   timestamptz,
  voided_by   uuid references users (id),
  void_reason text,
  created_at  timestamptz not null default now(),
  check (source = 'manual' or source_key is not null),
  check ((voided_at is null) = (void_reason is null))
);
create index if not exists sales_touches_staff_idx on sales_touches (staff_id, at);
create index if not exists sales_touches_booking_idx on sales_touches (booking_id) where booking_id is not null;
comment on table sales_touches is 'Sales activity (0174): one row per touch (a follow-up, a repost, a DM reply, an outreach call, email or text, an owner outreach). Logged by the system where it knows (source offer, message, chat, phone, ad_posting, recruit_call, recruit_message; one live chat counts once a day) and by hand (manual, with an optional link). An Admin may void one with a reason. Remote Sales need sales_remote_min_touches a month.';

create table if not exists sales_availability (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid not null references users (id),
  day           date not null,
  from_minute   integer not null check (from_minute between 0 and 1439),
  until_minute  integer not null check (until_minute between 1 and 1440),
  created_at    timestamptz not null default now(),
  check (until_minute > from_minute)
);
create index if not exists sales_availability_staff_idx on sales_availability (staff_id, day);
comment on table sales_availability is 'A remote Sales rep''s availability blocks (0174), Toronto time, submitted week by week: the peak-hour cover (Thursday to Sunday afternoons) and the reply-time measure use them. A website request answered with the first offer inside a block is credited to them as sourced.';

do $$
declare t text;
begin
  foreach t in array array['sales_month_rates', 'sales_touches', 'sales_availability'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('drop policy if exists own_select on %I', t);
    execute format('create policy own_select on %I for select to authenticated using (staff_id = app.uid())', t);
  end loop;
end $$;
drop trigger if exists audit_sales_month_rates on sales_month_rates;
create trigger audit_sales_month_rates after insert or update or delete on sales_month_rates for each row execute function app.audit_row();
drop trigger if exists audit_sales_availability on sales_availability;
create trigger audit_sales_availability after insert or update or delete on sales_availability for each row execute function app.audit_row();

-- ================================================================ 4. the rules
-- The mode of a person who earns by the Sales tiers (a Sales assistant): in_person or remote. Null for anyone else.
create or replace function app.swm_mode(p_staff uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when sp.staff_type = 'va' and sp.va_function::text = 'sales' then coalesce(sp.sales_work_mode, 'in_person') end
    from (select 1) one left join staff_profiles sp on sp.user_id = p_staff
$$;

-- The mode a month counts in: the locked one once approved, else the person's mode now.
create or replace function app.swm_mode_for(p_staff uuid, p_month date) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select r.work_mode from sales_month_rates r where r.staff_id = p_staff and r.month = p_month and r.locked_at is not null), app.swm_mode(p_staff))
$$;

create or replace function app.swm_month_end(p_month date) returns date
language sql immutable as $$ select (p_month + interval '1 month' - interval '1 day')::date $$;

-- Touches in a calendar month (Toronto), not voided.
create or replace function app.swm_touch_count(p_staff uuid, p_month date) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from sales_touches t
   where t.staff_id = p_staff and t.voided_at is null
     and t.at >= app.local_midnight(p_month) and t.at < app.local_midnight((p_month + interval '1 month')::date)
$$;

-- The month's schedule and rate for a number of rental days. Locked: the schedule as approved. Else the person's mode now
-- and the settings of the month's last day. The remote drop applies once the month has ended (closed) when the touches are
-- under the minimum: the tier sales_remote_drop_tiers lower, or the floor below the lowest tier. projected_bps: the rate if
-- the month ended with the touches it has now.
create or replace function app.swm_rate(p_staff uuid, p_month date, p_days integer) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r sales_month_rates;
  s program_settings;
  v_mode text;
  v_tiers integer[];
  v_mid_days integer; v_high_days integer;
  v_min integer; v_drop integer; v_floor integer; v_touches integer;
  v_closed boolean;
  v_locked boolean;
  v_idx integer;
  v_below boolean;
  v_dropped_bps integer;
begin
  select * into r from sales_month_rates x where x.staff_id = p_staff and x.month = p_month;
  v_locked := r.locked_at is not null;
  if v_locked then
    v_mode := r.work_mode; v_tiers := array[r.tier_low_bps, r.tier_mid_bps, r.tier_high_bps];
    v_mid_days := r.tier_mid_days; v_high_days := r.tier_high_days;
    v_min := r.min_touches; v_drop := r.drop_tiers; v_floor := r.floor_bps; v_touches := r.touches; v_closed := true;
  else
    s := app.settings(app.swm_month_end(p_month));
    v_mode := coalesce(app.swm_mode(p_staff), 'in_person');
    v_tiers := case when v_mode = 'remote' then array[s.sales_remote_tier_low_bps, s.sales_remote_tier_mid_bps, s.sales_remote_tier_high_bps]
                    else array[s.sales_tier_low_bps, s.sales_tier_mid_bps, s.sales_tier_high_bps] end;
    v_mid_days := s.sales_tier_mid_days; v_high_days := s.sales_tier_high_days;
    v_min := case when v_mode = 'remote' then s.sales_remote_min_touches else 0 end;
    v_drop := case when v_mode = 'remote' then s.sales_remote_drop_tiers else 0 end;
    v_floor := case when v_mode = 'remote' then s.sales_remote_floor_bps else 0 end;
    v_touches := app.swm_touch_count(p_staff, p_month);
    v_closed := app.today() >= (p_month + interval '1 month')::date;
  end if;
  v_idx := case when coalesce(p_days, 0) >= v_high_days then 3 when coalesce(p_days, 0) >= v_mid_days then 2 else 1 end;
  v_below := v_mode = 'remote' and v_drop > 0 and v_touches < v_min;
  v_dropped_bps := case when v_idx - v_drop >= 1 then v_tiers[v_idx - v_drop] else v_floor end;
  return jsonb_build_object('mode', v_mode, 'locked', v_locked, 'closed', v_closed, 'days', coalesce(p_days, 0),
    'tier_low_bps', v_tiers[1], 'tier_mid_bps', v_tiers[2], 'tier_high_bps', v_tiers[3], 'tier_mid_days', v_mid_days, 'tier_high_days', v_high_days,
    'tier_index', v_idx, 'tier_bps', v_tiers[v_idx],
    'min_touches', v_min, 'drop_tiers', v_drop, 'floor_bps', v_floor, 'touches', v_touches, 'below_minimum', v_below,
    'dropped', v_below and v_closed,
    'rate_bps', case when v_below and v_closed then v_dropped_bps else v_tiers[v_idx] end,
    'projected_bps', case when v_below then v_dropped_bps else v_tiers[v_idx] end,
    'dropped_bps', v_dropped_bps);
end $$;

-- Keep the month's row in step (the schedule only while it is not locked; the days, tier and rate always).
create or replace function app.swm_snapshot(p_staff uuid, p_month date, p_days integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.swm_rate(p_staff, p_month, p_days);
begin
  insert into sales_month_rates as r (staff_id, month, work_mode, tier_low_bps, tier_mid_bps, tier_high_bps, tier_mid_days, tier_high_days, min_touches, drop_tiers,
                                      floor_bps, touches, tier_days, tier_bps, rate_bps, below_minimum, dropped, updated_at)
  values (p_staff, p_month, x ->> 'mode', (x ->> 'tier_low_bps')::int, (x ->> 'tier_mid_bps')::int, (x ->> 'tier_high_bps')::int, (x ->> 'tier_mid_days')::int,
          (x ->> 'tier_high_days')::int, (x ->> 'min_touches')::int, (x ->> 'drop_tiers')::int, (x ->> 'floor_bps')::int, (x ->> 'touches')::int,
          coalesce(p_days, 0), (x ->> 'tier_bps')::int, (x ->> 'rate_bps')::int, (x ->> 'below_minimum')::boolean, (x ->> 'dropped')::boolean, now())
  on conflict (staff_id, month) do update set
    work_mode = case when r.locked_at is null then excluded.work_mode else r.work_mode end,
    tier_low_bps = case when r.locked_at is null then excluded.tier_low_bps else r.tier_low_bps end,
    tier_mid_bps = case when r.locked_at is null then excluded.tier_mid_bps else r.tier_mid_bps end,
    tier_high_bps = case when r.locked_at is null then excluded.tier_high_bps else r.tier_high_bps end,
    tier_mid_days = case when r.locked_at is null then excluded.tier_mid_days else r.tier_mid_days end,
    tier_high_days = case when r.locked_at is null then excluded.tier_high_days else r.tier_high_days end,
    min_touches = case when r.locked_at is null then excluded.min_touches else r.min_touches end,
    drop_tiers = case when r.locked_at is null then excluded.drop_tiers else r.drop_tiers end,
    floor_bps = case when r.locked_at is null then excluded.floor_bps else r.floor_bps end,
    touches = case when r.locked_at is null then excluded.touches else r.touches end,
    below_minimum = case when r.locked_at is null then excluded.below_minimum else r.below_minimum end,
    tier_days = excluded.tier_days, tier_bps = excluded.tier_bps, rate_bps = excluded.rate_bps, dropped = excluded.dropped, updated_at = now()
  where (r.work_mode, r.tier_days, r.tier_bps, r.rate_bps, r.touches, r.dropped, r.below_minimum, r.tier_low_bps, r.tier_mid_bps, r.tier_high_bps, r.min_touches, r.drop_tiers, r.floor_bps)
        is distinct from (case when r.locked_at is null then excluded.work_mode else r.work_mode end, excluded.tier_days, excluded.tier_bps, excluded.rate_bps,
                          case when r.locked_at is null then excluded.touches else r.touches end, excluded.dropped,
                          case when r.locked_at is null then excluded.below_minimum else r.below_minimum end,
                          case when r.locked_at is null then excluded.tier_low_bps else r.tier_low_bps end, case when r.locked_at is null then excluded.tier_mid_bps else r.tier_mid_bps end,
                          case when r.locked_at is null then excluded.tier_high_bps else r.tier_high_bps end, case when r.locked_at is null then excluded.min_touches else r.min_touches end,
                          case when r.locked_at is null then excluded.drop_tiers else r.drop_tiers end, case when r.locked_at is null then excluded.floor_bps else r.floor_bps end);
  return x;
end $$;

-- 0058's recalculation of a person's month (replaced): the Sales rate now comes from the month's mode and schedule
-- (app.swm_rate), the month's row is kept (app.swm_snapshot) and each commission carries the mode.
create or replace function app.commission_retier(p_staff uuid, p_month date) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_scheme text := app.commission_scheme(p_staff);
  v_days integer := app.commission_month_days(p_staff, p_month);
  v_rate integer;
  v_mode text;
  v_x jsonb;
  c staff_commissions;
  v_amount bigint;
  v_net bigint;
begin
  if p_staff is null or p_month is null then return; end if;
  if v_scheme = 'sales_tier' then
    v_x := app.swm_snapshot(p_staff, p_month, v_days);
    v_rate := (v_x ->> 'rate_bps')::integer;
    v_mode := v_x ->> 'mode';
  else
    v_rate := case v_scheme when 'override' then (select sp.commission_bps from staff_profiles sp where sp.user_id = p_staff)
                            else (app.settings(app.swm_month_end(p_month))).staff_commission_bps end;
  end if;
  for c in select * from staff_commissions x where x.staff_id = p_staff and x.month = p_month and x.kind = 'commission'
                and x.status in ('accruing', 'pending_approval', 'approved', 'paid') for update loop
    v_amount := case when c.reversed_at is null then public.calc_bps(c.base_cents, v_rate) else 0 end;
    if c.status in ('accruing', 'pending_approval') then
      update staff_commissions set scheme = v_scheme, tier_days = v_days, rate_bps = v_rate, amount_cents = v_amount, work_mode = v_mode, updated_at = now() where id = c.id;
    elsif c.status = 'approved' then
      if v_amount <> c.amount_cents then
        update staff_commissions set scheme = v_scheme, tier_days = v_days, rate_bps = v_rate, amount_cents = v_amount, work_mode = coalesce(v_mode, work_mode), status = 'pending_approval',
               approved_at = null, approved_by = null, note = 'The amount changed after it was approved (a refund or the month''s tier): approve it again', updated_at = now()
         where id = c.id;
      else
        update staff_commissions set scheme = v_scheme, tier_days = v_days, work_mode = coalesce(v_mode, work_mode), updated_at = now() where id = c.id;
      end if;
    else
      -- paid: what was paid less clawbacks plus adjustments, against what is due now
      select c.amount_cents + coalesce(sum(x2.amount_cents) filter (where x2.status not in ('reversed', 'void')), 0) into v_net
        from staff_commissions x2 where x2.clawback_of = c.id;
      update staff_commissions set tier_days = v_days, updated_at = now() where id = c.id;
      if v_amount < v_net then
        insert into staff_commissions (booking_id, staff_id, kind, clawback_of, scheme, month, rental_days, tier_days, base_cents, rate_bps, amount_cents, status, reason, earned_at, work_mode)
        values (c.booking_id, p_staff, 'clawback', c.id, v_scheme, p_month, 0, v_days, c.base_cents, v_rate, v_amount - v_net, 'approved',
                coalesce(c.reason, case when c.reversed_at is not null then 'Reversed after it was paid' else 'A refund or the month''s tier lowered it after it was paid' end), now(), coalesce(v_mode, c.work_mode));
      elsif v_amount > v_net then
        insert into staff_commissions (booking_id, staff_id, kind, clawback_of, scheme, month, rental_days, tier_days, base_cents, rate_bps, amount_cents, status, reason, earned_at, work_mode)
        values (c.booking_id, p_staff, 'adjustment', c.id, v_scheme, p_month, 0, v_days, c.base_cents, v_rate, v_amount - v_net, 'pending_approval',
                'The month''s tier rose after it was paid', now(), coalesce(v_mode, c.work_mode));
      end if;
    end if;
  end loop;
  perform app.commission_split_refresh(p_staff, p_month);
end $$;

-- 0058's month progress (replaced): the tiers of the person's mode, and for remote the touches, the minimum and the rate
-- the month would end at (projected_bps).
create or replace function app.sales_month_progress(p_staff uuid, p_month date default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_month date := coalesce(p_month, app.month_start(app.today()));
  s program_settings := app.settings();
  v_days integer := app.commission_month_days(p_staff, v_month);
  v_scheme text := app.commission_scheme(p_staff);
  v_rate integer;
  x jsonb;
  v_low integer := s.sales_tier_low_bps; v_mid integer := s.sales_tier_mid_bps; v_high integer := s.sales_tier_high_bps;
  v_mid_days integer := s.sales_tier_mid_days; v_high_days integer := s.sales_tier_high_days;
begin
  if v_scheme = 'sales_tier' then
    x := app.swm_rate(p_staff, v_month, v_days);
    v_low := (x ->> 'tier_low_bps')::int; v_mid := (x ->> 'tier_mid_bps')::int; v_high := (x ->> 'tier_high_bps')::int;
    v_mid_days := (x ->> 'tier_mid_days')::int; v_high_days := (x ->> 'tier_high_days')::int;
    v_rate := (x ->> 'rate_bps')::int;
  else
    v_rate := case v_scheme when 'override' then (select sp.commission_bps from staff_profiles sp where sp.user_id = p_staff) else s.staff_commission_bps end;
  end if;
  return jsonb_build_object('month', v_month, 'label', to_char(v_month, 'FMMonth YYYY'), 'scheme', v_scheme, 'days', v_days, 'rate_bps', v_rate,
    'target_days', v_high_days, 'mid_days', v_mid_days,
    'tiers', jsonb_build_array(jsonb_build_object('from_days', 0, 'bps', v_low), jsonb_build_object('from_days', v_mid_days, 'bps', v_mid),
                               jsonb_build_object('from_days', v_high_days, 'bps', v_high)),
    'progress_pct', least(100, round(100.0 * v_days / greatest(v_high_days, 1))),
    'next', case when v_scheme <> 'sales_tier' then null
                 when v_days < v_mid_days then jsonb_build_object('days', v_mid_days, 'bps', v_mid, 'to_go', v_mid_days - v_days)
                 when v_days < v_high_days then jsonb_build_object('days', v_high_days, 'bps', v_high, 'to_go', v_high_days - v_days) end,
    'rises', case when v_scheme <> 'sales_tier' then null
                  else concat_ws(' / ', case when v_days < v_mid_days then format('rises to %s at %s days', app.bps_words(v_mid), v_mid_days) end,
                                        case when v_days < v_high_days then format('%s at %s days', app.bps_words(v_high), v_high_days) end) end)
    || case when v_scheme = 'sales_tier' then jsonb_build_object('mode', x ->> 'mode', 'tier_bps', (x ->> 'tier_bps')::int, 'projected_bps', (x ->> 'projected_bps')::int,
           'touches', (x ->> 'touches')::int, 'min_touches', (x ->> 'min_touches')::int, 'below_minimum', (x ->> 'below_minimum')::boolean,
           'drop_tiers', (x ->> 'drop_tiers')::int, 'dropped', (x ->> 'dropped')::boolean, 'closed', (x ->> 'closed')::boolean, 'locked', (x ->> 'locked')::boolean,
           'touches_pct', case when (x ->> 'min_touches')::int > 0 then least(100, round(100.0 * (x ->> 'touches')::int / (x ->> 'min_touches')::int)) end)
         else '{}'::jsonb end;
end $$;

-- The credit: a remote rep earns only on rentals they source. A walk-in or a partner deal (source partner, or a referral
-- partner on the booking) earns them nothing; in person, as before.
alter function app.commission_own_reason(uuid, uuid) rename to commission_own_reason_pre0174;
create or replace function app.commission_own_reason(p_booking uuid, p_staff uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v text := app.commission_own_reason_pre0174(p_booking, p_staff);
  b bookings;
begin
  if v is not null then return v; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  if app.swm_mode_for(p_staff, app.month_start(app.local_date(coalesce(b.checked_in_at, b.return_at)))) = 'remote'
     and (b.source in ('walk_in', 'partner') or b.referral_partner_id is not null) then
    return 'Remote sales: a walk-in or a partner deal earns no commission';
  end if;
  return null;
end $$;
select pg_temp.copy_grants('app.commission_own_reason(uuid, uuid)'::regprocedure, 'app.commission_own_reason_pre0174(uuid, uuid)'::regprocedure);

-- Approving a Sales month locks its schedule (the mode, the tier rates and days, the minimum, the touches and the drop).
create or replace function app.swm_lock(p_staff uuid, p_month date, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.swm_snapshot(p_staff, p_month, app.commission_month_days(p_staff, p_month));
  update sales_month_rates set locked_at = now(), locked_by = p_by, updated_at = now() where staff_id = p_staff and month = p_month and locked_at is null;
end $$;

alter function app.commission_approve(uuid, jsonb) rename to commission_approve_pre0174;
create or replace function app.commission_approve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.commission_approve_pre0174(p_by, p);
  r record;
begin
  for r in select distinct c.staff_id, c.month from staff_commissions c
            where c.approved_by = p_by and c.approved_at = now() and c.scheme = 'sales_tier' and c.status = 'approved' loop
    perform app.swm_lock(r.staff_id, r.month, p_by);
  end loop;
  return v;
end $$;
select pg_temp.copy_grants('app.commission_approve(uuid, jsonb)'::regprocedure, 'app.commission_approve_pre0174(uuid, jsonb)'::regprocedure);

-- The line of a month on the person's statement.
create or replace function app.swm_month_line(r sales_month_rates) returns text
language sql stable security definer set search_path = public, app as $$
  select to_char(r.month, 'FMMonth YYYY') || ', ' || case r.work_mode when 'remote' then 'remote' else 'in person' end || ': '
    || r.tier_days || ' rental ' || case when r.tier_days = 1 then 'day' else 'days' end
    || case when r.dropped
            then format(' reach %s, but %s of the %s touches were logged: the month''s rate is %s, %s.', app.bps_words(r.tier_bps), r.touches, r.min_touches,
                        case when r.drop_tiers = 1 then 'one tier lower' else r.drop_tiers || ' tiers lower' end, app.bps_words(r.rate_bps))
            when r.work_mode = 'remote' and r.drop_tiers > 0 and r.below_minimum
            then format(', %s. %s of %s touches so far: under %s when the month ends, the rate drops to %s.', app.bps_words(r.rate_bps), r.touches, r.min_touches, r.min_touches,
                        app.bps_words((app.swm_rate(r.staff_id, r.month, r.tier_days) ->> 'dropped_bps')::int))
            when r.work_mode = 'remote' and r.drop_tiers > 0
            then format(', %s. %s of %s touches: minimum met.', app.bps_words(r.rate_bps), r.touches, r.min_touches)
            else format(', %s.', app.bps_words(r.rate_bps)) end
$$;

-- A person's commissions (0058) with the mode, each month's line and the mode of each commission.
alter function app.staff_commissions_json(uuid) rename to staff_commissions_json_pre0174;
create or replace function app.staff_commissions_json(p_staff uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_commissions_json_pre0174(p_staff);
begin
  return v || jsonb_build_object(
    'mode', app.swm_mode(p_staff),
    'rows', coalesce((select jsonb_agg(e || jsonb_build_object('work_mode', c.work_mode) order by n)
                        from jsonb_array_elements(v -> 'rows') with ordinality as q(e, n) left join staff_commissions c on c.id = (e ->> 'id')::uuid), '[]'::jsonb),
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', r.month, 'label', to_char(r.month, 'FMMonth YYYY'), 'work_mode', r.work_mode, 'tier_days', r.tier_days,
                          'tier_bps', r.tier_bps, 'rate_bps', r.rate_bps, 'touches', r.touches, 'min_touches', r.min_touches, 'below_minimum', r.below_minimum,
                          'dropped', r.dropped, 'locked', r.locked_at is not null, 'line', app.swm_month_line(r)) order by r.month desc)
                        from (select * from sales_month_rates x where x.staff_id = p_staff order by x.month desc limit 12) r), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.staff_commissions_json(uuid)'::regprocedure, 'app.staff_commissions_json_pre0174(uuid)'::regprocedure);

-- Money > Staff commissions (0058) with each person's mode and the remote settings.
alter function app.commission_admin(uuid, jsonb) rename to commission_admin_pre0174;
create or replace function app.commission_admin(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.commission_admin_pre0174(p_by, p);
begin
  return jsonb_set(v, '{people}', coalesce((select jsonb_agg(e || jsonb_build_object('work_mode', app.swm_mode((e ->> 'staff_id')::uuid)) order by n)
                                              from jsonb_array_elements(v -> 'people') with ordinality as q(e, n)), '[]'::jsonb))
         || jsonb_build_object('remote_settings', (select jsonb_build_object('low_bps', s.sales_remote_tier_low_bps, 'mid_bps', s.sales_remote_tier_mid_bps, 'high_bps', s.sales_remote_tier_high_bps,
                                 'min_touches', s.sales_remote_min_touches, 'drop_tiers', s.sales_remote_drop_tiers, 'floor_bps', s.sales_remote_floor_bps)
                                 from (select (app.settings()).*) s));
end $$;
select pg_temp.copy_grants('app.commission_admin(uuid, jsonb)'::regprocedure, 'app.commission_admin_pre0174(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. shifts, cover and reply time
-- Inside one of the person's availability blocks (Toronto time)?
create or replace function app.swm_on_shift(p_staff uuid, p_at timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from sales_availability a
                  where a.staff_id = p_staff and a.day = app.local_date(p_at)
                    and extract(hour from (p_at at time zone 'America/Toronto')) * 60 + extract(minute from (p_at at time zone 'America/Toronto')) >= a.from_minute
                    and extract(hour from (p_at at time zone 'America/Toronto')) * 60 + extract(minute from (p_at at time zone 'America/Toronto')) < a.until_minute)
$$;

-- Minutes of a block inside the peak hours (Thursday to Sunday, the peak hours of the settings).
create or replace function app.swm_peak_minutes(p_day date, p_from integer, p_until integer) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when extract(isodow from p_day) in (4, 5, 6, 7)
              then greatest(0, least(p_until, s.sales_remote_peak_until_hour * 60) - greatest(p_from, s.sales_remote_peak_from_hour * 60)) else 0 end::integer
    from (select (app.settings(p_day)).*) s
$$;

create or replace function app.swm_hhmm(p_minute integer) returns text
language sql immutable as $$ select lpad((p_minute / 60)::text, 2, '0') || ':' || lpad((p_minute % 60)::text, 2, '0') $$;

-- A week (Monday to Sunday) of blocks with their peak minutes.
create or replace function app.swm_week(p_staff uuid, p_start date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('start', p_start, 'end', p_start + 6, 'label', 'Week of ' || to_char(p_start, 'FMMonth FMDD'),
    'blocks', coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'day', a.day, 'day_label', to_char(a.day, 'FMDay FMMonth FMDD'), 'from', app.swm_hhmm(a.from_minute),
                 'to', app.swm_hhmm(a.until_minute), 'peak_minutes', app.swm_peak_minutes(a.day, a.from_minute, a.until_minute)) order by a.day, a.from_minute)
                 filter (where a.id is not null), '[]'::jsonb),
    'peak_hours', round(coalesce(sum(app.swm_peak_minutes(a.day, a.from_minute, a.until_minute)), 0) / 60.0, 1),
    'hours', round(coalesce(sum(a.until_minute - a.from_minute), 0) / 60.0, 1))
    from (select 1) one left join sales_availability a on a.staff_id = p_staff and a.day between p_start and p_start + 6
$$;

-- Replies on items assigned to the person that came in during their blocks: live chats assigned to them (from the moment a
-- person was asked for to the first reply) and reply tasks assigned to them (a renter message, a missed call, a text, a chat
-- request, a booking request: from the task to its completion). Open items past the target count as late.
create or replace function app.swm_replies(p_staff uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with items as (
    select c.human_requested_at as start_at, c.first_human_reply_at as reply_at from chat_conversations c
     where c.assigned_to = p_staff and c.human_requested_at >= p_from and c.human_requested_at < p_to
    union all
    select t.created_at, t.completed_at from tasks t
     where t.assigned_to = p_staff and t.status <> 'cancelled' and t.created_at >= p_from and t.created_at < p_to
       and t.task_type in ('renter_message', 'phone_missed_call', 'account_phone_review', 'live_chat_waiting', 'chat_request', 'chat_contact', 'booking_request')
  ), on_shift as (
    select i.start_at, i.reply_at, extract(epoch from (coalesce(i.reply_at, now()) - i.start_at)) / 60.0 as minutes from items i where app.swm_on_shift(p_staff, i.start_at)
  )
  select jsonb_build_object('target_minutes', s.sales_remote_reply_minutes,
    'count', count(o.*), 'replied', count(o.*) filter (where o.reply_at is not null),
    'within', count(o.*) filter (where o.reply_at is not null and o.minutes <= s.sales_remote_reply_minutes),
    'late_open', count(o.*) filter (where o.reply_at is null and o.minutes > s.sales_remote_reply_minutes),
    'median_minutes', round((percentile_cont(0.5) within group (order by o.minutes) filter (where o.reply_at is not null))::numeric, 1),
    'within_pct', case when count(o.*) > 0 then round(100.0 * count(o.*) filter (where o.reply_at is not null and o.minutes <= s.sales_remote_reply_minutes) / count(o.*)) end)
    from (select (app.settings()).*) s left join on_shift o on true
   group by s.sales_remote_reply_minutes
$$;

-- ================================================================ 6. remote: a website request answered on shift is theirs
create or replace function app.swm_offer_source() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if new.sent_by is null or app.swm_mode(new.sent_by) is distinct from 'remote' then return null; end if;
  select * into b from bookings where id = new.booking_id;
  if b.id is null or b.source <> 'web' or b.booking_type = 'owner' or b.sales_sourced or b.sales_staff_id is distinct from new.sent_by
     or b.sales_source is distinct from 'offer' then return null; end if;
  if exists (select 1 from booking_offers o where o.booking_id = b.id and o.id <> new.id and o.version < new.version) then return null; end if;
  if not app.swm_on_shift(new.sent_by, new.sent_at) then return null; end if;
  update bookings set sales_sourced = true, sales_choice = 'sourced', sales_choice_by = new.sent_by, sales_choice_at = now(), sales_claim_by = null, sales_claim_at = null
   where id = b.id;
  perform app.log_booking_event(b.id, 'sales_credit', null, b.status::text, null,
    format('Website request answered on a remote shift by %s: credited as having sourced it', (select coalesce(u.full_name, u.email) from users u where u.id = new.sent_by)),
    new.sent_by, 'staff', jsonb_build_object('remote_shift', true, 'staff', new.sent_by));
  return null;
end $$;
drop trigger if exists booking_offers_swm_source on booking_offers;
create trigger booking_offers_swm_source after insert on booking_offers for each row execute function app.swm_offer_source();

-- ================================================================ 7. touches the system logs by itself
create or replace function app.swm_logs(p_staff uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_staff is not null and exists (select 1 from staff_profiles sp where sp.user_id = p_staff and sp.staff_type = 'va' and sp.va_function::text = 'sales')
$$;

create or replace function app.swm_touch_auto(p_staff uuid, p_kind text, p_source text, p_key text, p_booking uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.swm_logs(p_staff) then return; end if;
  insert into sales_touches (staff_id, at, kind, source, source_key, booking_id) values (p_staff, coalesce(p_at, now()), p_kind, p_source, p_key, p_booking)
  on conflict (source_key) do nothing;
exception when others then
  -- the touch log never stops the message, the offer or the call it follows
  raise warning 'sales touch not logged: %', sqlerrm;
end $$;

create or replace function app.swm_touch_trigger() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := to_jsonb(new);
begin
  case tg_table_name
  when 'booking_offers' then
    perform app.swm_touch_auto((j ->> 'sent_by')::uuid, 'follow_up', 'offer', 'offer:' || (j ->> 'id'), (j ->> 'booking_id')::uuid, (j ->> 'sent_at')::timestamptz);
  when 'messages' then
    if j ->> 'direction' = 'outbound' and j ->> 'sent_by' is not null and j ->> 'channel' <> 'push' and coalesce(j ->> 'related_table', '') <> 'tasks'
       and coalesce(j ->> 'renter_id', j ->> 'owner_id', j ->> 'user_id', j ->> 'to_address') is not null then
      perform app.swm_touch_auto((j ->> 'sent_by')::uuid,
        case when j ->> 'booking_id' is not null then 'follow_up' when j ->> 'channel' = 'phone' then 'outreach_call'
             when j ->> 'channel' in ('sms', 'whatsapp') then 'outreach_text' else 'outreach_email' end,
        'message', 'message:' || (j ->> 'id'), (j ->> 'booking_id')::uuid, (j ->> 'occurred_at')::timestamptz);
    end if;
  when 'chat_messages' then
    if j ->> 'sender' = 'staff' and j ->> 'staff_id' is not null then
      perform app.swm_touch_auto((j ->> 'staff_id')::uuid, 'dm_reply', 'chat',
        'chat:' || (j ->> 'conversation_id') || ':' || app.local_date((j ->> 'at')::timestamptz) || ':' || (j ->> 'staff_id'),
        (select c.booking_id from chat_conversations c where c.id = (j ->> 'conversation_id')::uuid), (j ->> 'at')::timestamptz);
    end if;
  when 'phone_activity' then
    if j ->> 'direction' = 'out' and j ->> 'sent_by' is not null then
      perform app.swm_touch_auto((j ->> 'sent_by')::uuid,
        case when j ->> 'kind' = 'call' then 'outreach_call' when j ->> 'booking_id' is not null then 'follow_up' else 'outreach_text' end,
        'phone', 'phone:' || (j ->> 'id'), (j ->> 'booking_id')::uuid, (j ->> 'started_at')::timestamptz);
    end if;
  when 'ad_postings' then
    perform app.swm_touch_auto((j ->> 'posted_by')::uuid, 'repost', 'ad_posting', 'ad:' || (j ->> 'id'), null, now());
  when 'recruit_calls' then
    perform app.swm_touch_auto((j ->> 'called_by')::uuid, 'owner_outreach', 'recruit_call', 'recruit_call:' || (j ->> 'id'), null, (j ->> 'called_at')::timestamptz);
  when 'recruit_messages' then
    perform app.swm_touch_auto((j ->> 'sent_by')::uuid, 'owner_outreach', 'recruit_message', 'recruit_message:' || (j ->> 'id'), null, (j ->> 'created_at')::timestamptz);
  else null;
  end case;
  return null;
end $$;
drop trigger if exists booking_offers_swm_touch on booking_offers;
create trigger booking_offers_swm_touch after insert on booking_offers for each row when (new.sent_by is not null) execute function app.swm_touch_trigger();
drop trigger if exists messages_swm_touch on messages;
create trigger messages_swm_touch after insert on messages for each row when (new.sent_by is not null and new.direction = 'outbound') execute function app.swm_touch_trigger();
drop trigger if exists chat_messages_swm_touch on chat_messages;
create trigger chat_messages_swm_touch after insert on chat_messages for each row when (new.sender = 'staff' and new.staff_id is not null) execute function app.swm_touch_trigger();
drop trigger if exists phone_activity_swm_touch on phone_activity;
create trigger phone_activity_swm_touch after insert or update of sent_by on phone_activity for each row when (new.sent_by is not null and new.direction = 'out') execute function app.swm_touch_trigger();
drop trigger if exists ad_postings_swm_touch on ad_postings;
create trigger ad_postings_swm_touch after insert on ad_postings for each row when (new.posted_by is not null) execute function app.swm_touch_trigger();
drop trigger if exists recruit_calls_swm_touch on recruit_calls;
create trigger recruit_calls_swm_touch after insert on recruit_calls for each row when (new.called_by is not null) execute function app.swm_touch_trigger();
drop trigger if exists recruit_messages_swm_touch on recruit_messages;
create trigger recruit_messages_swm_touch after insert on recruit_messages for each row when (new.sent_by is not null) execute function app.swm_touch_trigger();

-- ================================================================ 8. what the rep and the Admins do
create or replace function app.swm_kind_label(p text) returns text
language sql immutable as $$
  select case p when 'follow_up' then 'Follow-up' when 'repost' then 'Repost' when 'dm_reply' then 'DM reply' when 'outreach_call' then 'Outreach call'
                when 'outreach_email' then 'Outreach email' when 'outreach_text' then 'Outreach text' when 'owner_outreach' then 'Owner outreach' else p end
$$;

-- "Log a touch" (a remote rep, for themselves). p: {kind, link, booking, note}
create or replace function app.sales_touch_log(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := nullif(p ->> 'kind', '');
  v_link text := nullif(btrim(coalesce(p ->> 'link', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_booking uuid;
  v_id uuid;
begin
  if app.swm_mode(p_by) is distinct from 'remote' then raise exception 'Touches are logged by remote Sales staff' using errcode = '42501'; end if;
  if v_kind is null or v_kind not in ('follow_up', 'repost', 'dm_reply', 'outreach_call', 'outreach_email', 'outreach_text', 'owner_outreach') then
    raise exception 'Choose the type of touch' using errcode = '22023';
  end if;
  if v_link is not null and (length(v_link) > 500 or v_link !~ '^https?://[^[:space:]]+$') then raise exception 'The link starts with https:// (or http://) and has no spaces' using errcode = '22023'; end if;
  if v_note is not null and length(v_note) > 300 then raise exception 'Keep the note under 300 characters' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'booking', '')), '') is not null then
    select b.id into v_booking from bookings b where b.booking_number = upper(btrim(p ->> 'booking')) or b.id::text = btrim(p ->> 'booking');
    if v_booking is null then raise exception 'No booking %', btrim(p ->> 'booking') using errcode = 'P0002'; end if;
  end if;
  if (select count(*) from sales_touches t where t.staff_id = p_by and t.source = 'manual' and t.at >= app.local_midnight(app.today())) >= 300 then
    raise exception 'That is 300 touches logged by hand today: the rest wait for tomorrow' using errcode = '23514';
  end if;
  insert into sales_touches (staff_id, kind, source, booking_id, link, note) values (p_by, v_kind, 'manual', v_booking, v_link, v_note) returning id into v_id;
  return jsonb_build_object('id', v_id, 'touches', app.swm_touch_count(p_by, app.month_start(app.today())));
end $$;

-- An Admin voids a touch (logged by mistake), with a reason. Not in a month already approved. p: {id, reason}
create or replace function app.sales_touch_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t sales_touches;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_month date;
begin
  perform app.assert_admin(p_by);
  select * into t from sales_touches where id = nullif(p ->> 'id', '')::uuid for update;
  if t.id is null then raise exception 'Touch not found' using errcode = 'P0002'; end if;
  if t.voided_at is not null then raise exception 'This touch is already voided' using errcode = '23514'; end if;
  if v_reason is null then raise exception 'Say why the touch is voided' using errcode = '22023'; end if;
  v_month := app.month_start(app.local_date(t.at));
  if exists (select 1 from sales_month_rates r where r.staff_id = t.staff_id and r.month = v_month and r.locked_at is not null) then
    raise exception 'That month is approved: its touches no longer change' using errcode = '23514';
  end if;
  update sales_touches set voided_at = now(), voided_by = p_by, void_reason = v_reason where id = t.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'sales_touch_void', 'sales_touches', t.id::text, jsonb_build_object('staff', t.staff_id, 'kind', t.kind, 'reason', v_reason));
  perform app.commission_retier(t.staff_id, v_month);
  return jsonb_build_object('id', t.id, 'voided', true);
end $$;

-- A remote rep's blocks for one week (Monday to Sunday): the days from today on are replaced; days already past stay.
-- p: {week (any day of it), blocks: [{day, from 'HH:MM', to 'HH:MM'}]}
create or replace function app.sales_availability_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_today date := app.today();
  v_start date := date_trunc('week', coalesce(nullif(p ->> 'week', '')::date, v_today))::date;
  e jsonb;
  v_day date;
  v_from integer;
  v_to integer;
  v_n integer := 0;
  v_blocks jsonb := coalesce(p -> 'blocks', '[]'::jsonb);
begin
  if app.swm_mode(p_by) is distinct from 'remote' then raise exception 'Availability blocks are for remote Sales staff' using errcode = '42501'; end if;
  if v_start < date_trunc('week', v_today)::date then raise exception 'A past week cannot change' using errcode = '23514'; end if;
  if v_start > date_trunc('week', v_today)::date + 21 then raise exception 'Plan up to three weeks ahead' using errcode = '22023'; end if;
  if jsonb_typeof(v_blocks) <> 'array' or jsonb_array_length(v_blocks) > 28 then raise exception 'Up to 28 blocks a week' using errcode = '22023'; end if;
  create temp table if not exists swm_new (day date, from_minute integer, until_minute integer) on commit drop;
  delete from swm_new;
  for e in select * from jsonb_array_elements(v_blocks) loop
    begin
      v_day := (e ->> 'day')::date;
      v_from := split_part(e ->> 'from', ':', 1)::integer * 60 + coalesce(nullif(split_part(e ->> 'from', ':', 2), ''), '0')::integer;
      v_to := split_part(e ->> 'to', ':', 1)::integer * 60 + coalesce(nullif(split_part(e ->> 'to', ':', 2), ''), '0')::integer;
    exception when others then
      raise exception 'Give each block a day and times like 13:00' using errcode = '22023';
    end;
    if v_day is null or v_from is null or v_to is null then raise exception 'Give each block a day and times like 13:00' using errcode = '22023'; end if;
    if v_day < v_start or v_day > v_start + 6 then raise exception '% is not in the week of %', app.fmt_day(v_day), app.fmt_day(v_start) using errcode = '22023'; end if;
    if v_day < v_today then raise exception '% is past: it cannot change', app.fmt_day(v_day) using errcode = '23514'; end if;
    if v_from < 0 or v_to > 1440 or v_to <= v_from then raise exception 'A block on % ends after it starts, between 00:00 and 24:00', app.fmt_day(v_day) using errcode = '22023'; end if;
    if exists (select 1 from swm_new n where n.day = v_day and n.from_minute < v_to and n.until_minute > v_from) then
      raise exception 'Two blocks overlap on %', app.fmt_day(v_day) using errcode = '22023';
    end if;
    insert into swm_new values (v_day, v_from, v_to);
  end loop;
  delete from sales_availability where staff_id = p_by and day between greatest(v_start, v_today) and v_start + 6;
  insert into sales_availability (staff_id, day, from_minute, until_minute) select p_by, n.day, n.from_minute, n.until_minute from swm_new n;
  get diagnostics v_n = row_count;
  return app.swm_week(p_by, v_start) || jsonb_build_object('saved', v_n);
end $$;

-- An Admin sets a Sales assistant's mode (the staff page; the hire flow calls the same). The months already approved keep
-- the mode they were approved in; the open months are worked out again.
create or replace function app.staff_set_sales_mode(p_by uuid, p_staff uuid, p_mode text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  sp staff_profiles;
begin
  perform app.assert_admin(p_by);
  select * into sp from staff_profiles where user_id = p_staff for update;
  if sp.user_id is null or sp.staff_type <> 'va' or sp.va_function::text <> 'sales' then raise exception 'Choose a Sales staff member' using errcode = '22023'; end if;
  if p_mode is null or p_mode not in ('in_person', 'remote') then raise exception 'Choose in person or remote' using errcode = '22023'; end if;
  if sp.sales_work_mode is not distinct from p_mode then return jsonb_build_object('staff', p_staff, 'mode', p_mode, 'changed', false); end if;
  update staff_profiles set sales_work_mode = p_mode where user_id = p_staff;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'staff_sales_mode_set', 'staff_profiles', p_staff::text, jsonb_build_object('sales_work_mode', sp.sales_work_mode),
          jsonb_build_object('sales_work_mode', p_mode, 'reason', nullif(btrim(coalesce(p_reason, '')), '')));
  return jsonb_build_object('staff', p_staff, 'mode', p_mode, 'changed', true);
end $$;

-- When the mode changes: the open months and their bookings are worked out again (rates and the remote credit rule).
create or replace function app.staff_profiles_sales_mode_resync() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v uuid;
  m date;
begin
  for v in select b.id from bookings b
            where b.sales_staff_id = new.user_id and b.sales_sourced
              and coalesce(b.checked_in_at, b.return_at) >= app.local_midnight((app.month_start(app.today()) - interval '2 months')::date)
              and not exists (select 1 from sales_month_rates r where r.staff_id = new.user_id and r.locked_at is not null
                                and r.month = app.month_start(app.local_date(coalesce(b.checked_in_at, b.return_at)))) loop
    perform app.commission_sync(v);
  end loop;
  for m in select distinct c.month from staff_commissions c where c.staff_id = new.user_id and c.kind = 'commission' and c.status in ('accruing', 'pending_approval', 'approved')
             and not exists (select 1 from sales_month_rates r where r.staff_id = c.staff_id and r.month = c.month and r.locked_at is not null) loop
    perform app.commission_retier(new.user_id, m);
  end loop;
  return null;
end $$;
drop trigger if exists staff_profiles_sales_mode_resync on staff_profiles;
create trigger staff_profiles_sales_mode_resync after update of sales_work_mode on staff_profiles
  for each row when (old.sales_work_mode is distinct from new.sales_work_mode) execute function app.staff_profiles_sales_mode_resync();

-- The Sales duties of one person: the mode, the month's rate, and for remote the touches, the checklist, the cover and the
-- reply time. A rep reads their own (va_read); an Admin anyone's (admin_read).
create or replace function app.swm_duties(p_staff uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_mode text := app.swm_mode(p_staff);
  s program_settings := app.settings();
  v_today date := app.today();
  v_month date := app.month_start(app.today());
  v_week date := date_trunc('week', app.today())::date;
  v_day0 timestamptz := app.local_midnight(app.today());
  v_quotes integer;
begin
  if v_mode is null then return jsonb_build_object('mode', null); end if;
  if v_mode = 'in_person' then
    return jsonb_build_object('mode', v_mode, 'progress', app.sales_month_progress(p_staff));
  end if;
  select count(*) into v_quotes from bookings b
   where b.sales_staff_id = p_staff and b.status in ('requested', 'offered', 'pending_payment')
     and (select count(*) from sales_touches t where t.staff_id = p_staff and t.booking_id = b.id and t.kind = 'follow_up' and t.voided_at is null) < 3;
  return jsonb_build_object(
    'mode', v_mode, 'today', v_today,
    'progress', app.sales_month_progress(p_staff),
    'settings', jsonb_build_object('min_touches', s.sales_remote_min_touches, 'drop_tiers', s.sales_remote_drop_tiers, 'floor_bps', s.sales_remote_floor_bps,
                  'cover_hours', s.sales_remote_cover_hours, 'reply_minutes', s.sales_remote_reply_minutes, 'peak_from', app.swm_hhmm(s.sales_remote_peak_from_hour * 60),
                  'peak_until', app.swm_hhmm(s.sales_remote_peak_until_hour * 60)),
    'touches_month', app.swm_touch_count(p_staff, v_month),
    'touches_today', coalesce((select jsonb_object_agg(k, n) from (select t.kind as k, count(*) as n from sales_touches t
                       where t.staff_id = p_staff and t.voided_at is null and t.at >= v_day0 group by t.kind) q), '{}'::jsonb),
    'checklist', jsonb_build_array(
      jsonb_build_object('key', 'repost', 'label', 'Repost cars on Marketplace and the classified sites',
        'count', (select count(*) from sales_touches t where t.staff_id = p_staff and t.voided_at is null and t.at >= v_day0 and t.kind = 'repost')),
      jsonb_build_object('key', 'dm_reply', 'label', 'Answer the social media DMs',
        'count', (select count(*) from sales_touches t where t.staff_id = p_staff and t.voided_at is null and t.at >= v_day0 and t.kind = 'dm_reply')),
      jsonb_build_object('key', 'follow_up', 'label', 'Three follow-ups on every quote', 'open_quotes', v_quotes,
        'count', (select count(*) from sales_touches t where t.staff_id = p_staff and t.voided_at is null and t.at >= v_day0 and t.kind = 'follow_up')),
      jsonb_build_object('key', 'outreach', 'label', 'Long-term and business outreach',
        'count', (select count(*) from sales_touches t where t.staff_id = p_staff and t.voided_at is null and t.at >= v_day0 and t.kind in ('outreach_call', 'outreach_email', 'outreach_text')))),
    'week', app.swm_week(p_staff, v_week),
    'next_week', app.swm_week(p_staff, v_week + 7),
    'replies_week', app.swm_replies(p_staff, app.local_midnight(v_week), app.local_midnight(v_week + 7)),
    'replies_month', app.swm_replies(p_staff, app.local_midnight(v_month), app.local_midnight((v_month + interval '1 month')::date)),
    'touches', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'at', t.at, 'kind', t.kind, 'kind_label', app.swm_kind_label(t.kind), 'source', t.source, 'link', t.link,
                   'note', t.note, 'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id), 'voided', t.voided_at is not null,
                   'void_reason', t.void_reason) order by t.at desc)
                 from (select * from sales_touches x where x.staff_id = p_staff and x.at >= app.local_midnight(v_month) order by x.at desc limit 40) t), '[]'::jsonb));
end $$;

-- Admin: every Sales assistant with the mode, this month's touches, this week's cover, the reply time and the rate.
create or replace function app.sales_modes_admin(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_week date := date_trunc('week', app.today())::date;
  v_month date := app.month_start(app.today());
  s program_settings := app.settings();
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'settings', jsonb_build_object('in_person', jsonb_build_array(s.sales_tier_low_bps, s.sales_tier_mid_bps, s.sales_tier_high_bps),
                  'remote', jsonb_build_array(s.sales_remote_tier_low_bps, s.sales_remote_tier_mid_bps, s.sales_remote_tier_high_bps),
                  'mid_days', s.sales_tier_mid_days, 'high_days', s.sales_tier_high_days, 'min_touches', s.sales_remote_min_touches, 'drop_tiers', s.sales_remote_drop_tiers,
                  'floor_bps', s.sales_remote_floor_bps, 'cover_hours', s.sales_remote_cover_hours, 'reply_minutes', s.sales_remote_reply_minutes),
    'people', coalesce((select jsonb_agg(x order by x ->> 'name') from (
      select jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email), 'email', u.email, 'status', u.status, 'mode', sp.sales_work_mode,
               'progress', app.sales_month_progress(u.id),
               'touches', case when sp.sales_work_mode = 'remote' then app.swm_touch_count(u.id, v_month) end,
               'cover_hours', case when sp.sales_work_mode = 'remote' then (app.swm_week(u.id, v_week) ->> 'peak_hours')::numeric end,
               'replies', case when sp.sales_work_mode = 'remote' then app.swm_replies(u.id, app.local_midnight(v_month), app.local_midnight((v_month + interval '1 month')::date)) end) as x
        from staff_profiles sp join users u on u.id = sp.user_id
       where sp.staff_type = 'va' and sp.va_function::text = 'sales' and sp.is_active) q), '[]'::jsonb));
end $$;

-- ================================================================ 9. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0174;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'va_read' and p_name = 'sales_duties' then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.swm_duties(p_user);   -- always the person's own
  end if;
  if p_call = 'va_do' and p_name in ('sales_touch_log', 'sales_availability_save') then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return case p_name when 'sales_touch_log' then app.sales_touch_log(p_user, q) else app.sales_availability_save(p_user, q) end;
  end if;
  if p_call = 'admin_read' and p_name in ('sales_modes', 'sales_duties') then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return case p_name when 'sales_modes' then app.sales_modes_admin(p_user) else app.swm_duties(nullif(q ->> 'staff', '')::uuid) end;
  end if;
  if p_call = 'admin_do' and p_name in ('staff_sales_mode_set', 'sales_touch_void') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'staff_sales_mode_set' then app.staff_set_sales_mode(p_user, nullif(q ->> 'staff', '')::uuid, nullif(q ->> 'mode', ''), q ->> 'reason')
      else app.sales_touch_void(p_user, q) end;
  end if;
  return app.door_pre0174(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0174(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 10. grants of the new functions
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['staff_profiles_sales_mode', 'swm_mode', 'swm_mode_for', 'swm_month_end', 'swm_touch_count', 'swm_rate', 'swm_snapshot',
             'commission_retier', 'sales_month_progress', 'commission_own_reason', 'commission_own_reason_pre0174', 'swm_lock', 'commission_approve', 'commission_approve_pre0174',
             'swm_month_line', 'staff_commissions_json', 'staff_commissions_json_pre0174', 'commission_admin', 'commission_admin_pre0174', 'swm_on_shift', 'swm_peak_minutes',
             'swm_hhmm', 'swm_week', 'swm_replies', 'swm_offer_source', 'swm_logs', 'swm_touch_auto', 'swm_touch_trigger', 'swm_kind_label', 'sales_touch_log',
             'sales_touch_void', 'sales_availability_save', 'staff_set_sales_mode', 'staff_profiles_sales_mode_resync', 'swm_duties', 'sales_modes_admin'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 11. the guides
-- GUIDES 0174 START (generated by supabase/seed/0174_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'people-and-access', 'chapter', 'getting-around-admin', 'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Audit log** shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Staff** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings** > **All settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. **Home address** here changes it if it is wrong.
7. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |
', 'People and access', 'Portals and sign-in, invitations, password links, View as, staff and scorecards.',
  'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Audit log** shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Staff** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings** > **All settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. **Home address** here changes it if it is wrong.
7. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |

## Sales staff: in person or remote

Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.

1. Press **Work mode** on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.
2. The list shows the mode, the rate now, the rate the month would end at, and for remote this month''s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.
3. On a remote person''s Sales page, Remote duties shows their checklist, touches, blocks and reply time. **Void** beside a touch logged by mistake takes it off, with a reason.
4. When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.

|  | Rule |
| --- | --- |
| Rates | In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15% |
| Credit | In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing |
| Remote minimum | 400 touches a month. Under it, when the month ends, the month''s rate is one tier lower (5% becomes 2.5%). Settings > Program settings, Staff commissions, changes the minimum, the drop and the floor |
',
  '<p class="gd-p">Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.</p><section class="gd-task" id="people-and-access-portals-and-sign-in" data-gd-task><h2 class="gd-h2">Portals and sign-in</h2><p class="gd-p">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>. Every portal has a card.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each card links to <b class="gd-ui">Its sign-in page</b>, the address to send that person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a person in the list on the card.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Open as this person</b> to see that portal as they see it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-27-portals-desktop-0361bf61.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:65.9%;top:30.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:58.1%;top:39.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:51.6%;top:45.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-invite-a-person" data-gd-task><h2 class="gd-h2">Invite a person</h2><p class="gd-p">Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in the Name and Email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Invite</b>. The link in the email works for 24 hours.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/360"><img src="/guides/img/admin-27-portals-desktop-c10725cb.jpg" alt="" loading="lazy" decoding="async" width="1230" height="360"><span class="gd-pin" style="left:18.8%;top:40.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:50%;top:40.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.8%;top:66.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:9.8%;top:87.8%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People &gt; Owners and People &gt; Investors also have a one-click invite for a record without a sign-in.</div></aside></section><section class="gd-task" id="people-and-access-send-a-password-link" data-gd-task><h2 class="gd-h2">Send a password link</h2><p class="gd-p">For anyone who forgot their password or let their invitation expire.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under People who can sign in, search by name or email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On their row, press <b class="gd-ui">Send password link</b>. They get &quot;Reset your CarmaCars password&quot;, valid for 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">View as (...)</b> on the same row opens their portal, read only.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/440"><img src="/guides/img/admin-27-portals-desktop-ee9b3e94.jpg" alt="" loading="lazy" decoding="async" width="1230" height="440"><span class="gd-pin" style="left:74.8%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:68.2%;top:28.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.1%;top:28.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-view-as-see-what-someone-sees" data-gd-task><h2 class="gd-h2">View as: see what someone sees</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A red banner says &quot;Viewing as Name (email), read only.&quot; on every page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Click around their portal. Nothing can be changed: every save is refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Exit</b> to come back. A view also ends by itself after 30 minutes.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/620"><img src="/guides/img/admin-28-view-as-desktop-f858e38c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="620"><span class="gd-pin" style="left:48.6%;top:4.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:4.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Can&#39;t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.</div></aside></section><section class="gd-task" id="people-and-access-the-audit-log" data-gd-task><h2 class="gd-h2">The audit log</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Audit log</b> shows who changed what, and when.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every View as is recorded (view_as_start), with the person viewed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Search by table, record id or value.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/audit</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-29-audit-desktop-b7504100.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:22.6%;top:31.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:39%;top:46.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.6%;top:20.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-staff-and-roles" data-gd-task><h2 class="gd-h2">Staff and roles</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b> opens Staff and roles.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Invite staff here too: Role, Name, Email, Main function and Also covers, then <b class="gd-ui">Invite</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row has <b class="gd-ui">Send password link</b>, <b class="gd-ui">View as (...)</b> and Limits (how much they may approve or refund).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End access</b> to close their staff portal at once. <b class="gd-ui">Restore</b> undoes it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/staff</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/780"><img src="/guides/img/admin-26-staff-desktop-72287d0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="780"><span class="gd-pin" style="left:20.8%;top:59%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:86.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:83.3%;top:92.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-admin-access" data-gd-task><h2 class="gd-h2">Admin access</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Admin access. Who may hold the Admin role.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site&#39;s nightly checks sign in with.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change the list only if the business&#39;s Admin address changes.</div></li></ol></div></section><section class="gd-task" id="people-and-access-staff-scorecards" data-gd-task><h2 class="gd-h2">Staff scorecards</h2><p class="gd-p">See how each assistant is doing against the targets.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure (for example quote sent within 5 minutes) and the result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/350"><img src="/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg" alt="" loading="lazy" decoding="async" width="1230" height="350"><span class="gd-pin" style="left:21.1%;top:42.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-sales-by-staff-member" data-gd-task><h2 class="gd-h2">Sales by staff member</h2><p class="gd-p">See each person&#39;s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Sales</b>. Press <b class="gd-ui">By week</b> or <b class="gd-ui">By month</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A deal credited to the wrong person, or marked sourced when it was not? Press <b class="gd-ui">Reassign</b> beside it, choose who, say whether they sourced the client, and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Commission rate</b> gives this person their own flat rate (empty: the Program settings). <b class="gd-ui">Reverse</b> beside a commission stops it, for example for a household rental found later.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. <b class="gd-ui">Home address</b> here changes it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The whole team: <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Overview</b>, the Sales card at the bottom. Choose another month and press <b class="gd-ui">Show</b>.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to</td><td>Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it.</td></tr><tr><td>Conversion</td><td>Of the deals credited in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off.</td></tr></tbody></table></div></section><section class="gd-task" id="people-and-access-sales-staff-in-person-or-remote" data-gd-task><h2 class="gd-h2">Sales staff: in person or remote</h2><p class="gd-p">Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Work mode</b> on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The list shows the mode, the rate now, the rate the month would end at, and for remote this month&#39;s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On a remote person&#39;s Sales page, Remote duties shows their checklist, touches, blocks and reply time. <b class="gd-ui">Void</b> beside a touch logged by mistake takes it off, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Rule</th></tr></thead><tbody><tr><td>Rates</td><td>In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15%</td></tr><tr><td>Credit</td><td>In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing</td></tr><tr><td>Remote minimum</td><td>400 touches a month. Under it, when the month ends, the month&#39;s rate is one tier lower (5% becomes 2.5%). Settings &gt; Program settings, Staff commissions, changes the minimum, the drop and the floor</td></tr></tbody></table></div></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurer rates**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurer rates**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-vehicle-class-rules" data-gd-task><h2 class="gd-h2">Vehicle class rules</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Vehicle class rules</b>. How a new car&#39;s class is decided from its VIN: the first rule that matches wins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Add a rule</b> or <b class="gd-ui">Change</b>: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Try a car</b> gives the class the rules decide for a year, make, model, trim and body, and why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Delete</b> removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.</div></aside></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurer rates</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
select app.guide_release_section('va', 'sales', 'chapter', 'fleet', 'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works. Answer requests and follow offers out.
2. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **My work** > **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image: the name and date of birth match the booking, class G2 or G, valid past the return, no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## My sales

Open **My work** > **My sales**. It shows your own sales and commissions only.

1. Commissions comes first. In Sales your rate depends on the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%. The bar shows your days against the target of 100, and says when your rate rises.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owner leads

1. Owner leads: each enquiry with the name, contact, car and status.
2. Press **Take it** to make it yours, then call the owner.
3. Press **Update** to set the status. When you close a lead, say why.
4. Owner applications, last 90 days, shows who applied and how far onboarding has come.

![](/guides/img/va-sales-04-leads-desktop-3402e913.jpg "desktop; size: 1230 400; address: carmacars.ca/va/leads; pins: 1 6.5 26.5, 3 94.8 44.0, 4 15.4 63.0")
', 'Sales', 'Requests and offers, new quotes and owner leads.',
  'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works. Answer requests and follow offers out.
2. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **My work** > **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image: the name and date of birth match the booking, class G2 or G, valid past the return, no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **My work** > **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **My work** > **My sales**. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owner leads

1. Owner leads: each enquiry with the name, contact, car and status.
2. Press **Take it** to make it yours, then call the owner.
3. Press **Update** to set the status. When you close a lead, say why.
4. Owner applications, last 90 days, shows who applied and how far onboarding has come.

![](/guides/img/va-sales-04-leads-desktop-3402e913.jpg "desktop; size: 1230 400; address: carmacars.ca/va/leads; pins: 1 6.5 26.5, 3 94.8 44.0, 4 15.4 63.0")
',
  '<p class="gd-p">You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.</p><p class="gd-p">Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.</p><section class="gd-task" id="sales-requests-offers-and-new-quotes" data-gd-task><h2 class="gd-h2">Requests, offers and new quotes</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Requests and offers</b>: the same queue customer service works. Answer requests and follow offers out.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Send an offer</b>: one screen for a caller, sent at once, as in chapter 2. <b class="gd-ui">New quote</b> still makes a request to offer later.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">An offer that is out: <b class="gd-ui">Edit the offer</b>, then <b class="gd-ui">Save and send the update</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:39.8%;top:59.5%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your first reply target is 5 minutes, the &quot;Quote sent&quot; measure on your scorecard. Follow every offer out before it expires.</div></aside></section><section class="gd-task" id="sales-check-the-renter-s-licence" data-gd-task><h2 class="gd-h2">Check the renter&#39;s licence</h2><p class="gd-p">Sales approve the renter&#39;s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">My work</b> &gt; <b class="gd-ui">To do</b>, <b class="gd-ui">Licences to check</b> lists each booking with an image waiting, the longest wait first. Press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On a booking, the card <b class="gd-ui">Renter licence</b> has the same: press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Look at each image: the name and date of birth match the booking, class G2 or G, valid past the return, no alteration, the selfie matches the licence photo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>. The renter is told and asked for a new image.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image still waiting is approved at once. An image the system refuses is named with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.</div></aside></section><section class="gd-task" id="sales-in-person-or-remote" data-gd-task><h2 class="gd-h2">In person or remote</h2><p class="gd-p">Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">In person (Toronto)</th><th scope="col">Remote (anywhere)</th></tr></thead><tbody><tr><td>Commission</td><td>Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20%</td><td>Under 50 rental days 5%, from 50 days 10%, from 100 days 15%</td></tr><tr><td>Credit</td><td>Walk-ins, handovers you close, partner visits and the rentals you source</td><td>Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing</td></tr><tr><td>Hours</td><td>You choose</td><td>At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you</td></tr><tr><td>Every day</td><td>Nothing set</td><td>Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach</td></tr><tr><td>Every month</td><td>Nothing set</td><td>400 touches. Under 400 when the month ends, the month&#39;s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5%</td></tr></tbody></table></div></section><section class="gd-task" id="sales-remote-your-duties" data-gd-task><h2 class="gd-h2">Remote: your duties</h2><p class="gd-p">On <b class="gd-ui">My work</b> &gt; <b class="gd-ui">To do</b>, <b class="gd-ui">Remote duties</b> shows this month&#39;s touches against 400, today&#39;s checklist, the peak hours you scheduled this week and your reply time.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">For anything else press <b class="gd-ui">Log a touch</b>: choose the type and add the link of the post, profile or listing if there is one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The checklist ticks itself as the day&#39;s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under My availability choose this week or next, press <b class="gd-ui">Add a block</b> for each time you will be on, then <b class="gd-ui">Save the week</b>. Days already past stay as they were.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.</div></aside></section><section class="gd-task" id="sales-my-sales" data-gd-task><h2 class="gd-h2">My sales</h2><p class="gd-p">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>. It shows your own sales and commissions only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press <b class="gd-ui">By month</b> for months, <b class="gd-ui">By week</b> for weeks.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">By week (or By month) lists each period with the same figures, newest first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to you</td><td>A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else.</td></tr><tr><td>Quotes created, offers sent, rentals added</td><td>Counted on the day they happened.</td></tr><tr><td>Bookings confirmed, booked revenue</td><td>Counted on the day the booking was confirmed.</td></tr><tr><td>Conversion</td><td>Of the deals credited to you in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off.</td></tr><tr><td>Rental days (Sales)</td><td>The days of the completed, paid rentals you sourced that end in the month. The month&#39;s tier applies to all of that month&#39;s rentals.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Sales commissions are approved after the month ends, when the month&#39;s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.</div></aside></section><section class="gd-task" id="sales-owner-leads" data-gd-task><h2 class="gd-h2">Owner leads</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner leads: each enquiry with the name, contact, car and status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours, then call the owner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Update</b> to set the status. When you close a lead, say why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner applications, last 90 days, shows who applied and how far onboarding has come.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/leads</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/400"><img src="/guides/img/va-sales-04-leads-desktop-3402e913.jpg" alt="" loading="lazy" decoding="async" width="1230" height="400"><span class="gd-pin" style="left:6.5%;top:26.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:44%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.4%;top:63%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'commissions', 'chapter', 'add-a-rental-by-hand', 'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay and no set hours. By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month''s rentals |
| Customer service, finance, fleet | 10% |
| How much | The rate on the rental charge before tax, after discounts, with late extra days; never on delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
', 'Commissions', 'I sourced this client, your rate, when it is earned, approved and paid.',
  'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay. By the rental days of the month, on all of that month''s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales) |
| Customer service, finance, fleet | 10% |
| How much | The rate on the rental charge before tax, after discounts, with late extra days; never on delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
',
  '<p class="gd-p">Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you enter the rental, the quote or the offer.</p><section class="gd-task" id="commissions-mark-who-found-the-client" data-gd-task><h2 class="gd-h2">Mark who found the client</h2><p class="gd-p">Every rental, quote and offer you enter asks: <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose <b class="gd-ui">I sourced this client</b> when you found the renter yourself: someone you know, your own post or your own outreach.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Entered for CarmaCars</b> when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>Commission only, with no base pay. By the rental days of the month, on all of that month&#39;s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales)</td></tr><tr><td>Customer service, finance, fleet</td><td>10%</td></tr><tr><td>How much</td><td>The rate on the rental charge before tax, after discounts, with late extra days; never on delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off</td></tr><tr><td>When earned</td><td>When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental</td></tr><tr><td>Your home address</td><td>It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client</td></tr><tr><td>Paid</td><td>After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.</div></aside></section>');
-- GUIDES 0174 END
