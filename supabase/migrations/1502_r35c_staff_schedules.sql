-- 1502_r35c_staff_schedules.sql
-- Release 35, part C (item 3): staff schedules in the portal, used for who is on duty, lateness and the KPIs.
--   staff_schedules: one default per role (user_id null) and, when an Admin sets one, a person's own (user_id). A schedule
--   is the weekdays (ISO, 1 Monday to 7 Sunday) and days of the month it applies to, the start and the end (Toronto), the
--   extra days a week the person may add when there is overflow work, and the day it starts. Breaks are at the person's
--   discretion: nothing is deducted.
--   The role defaults (no personal names):
--     Customer service  6 days a week, 8:00 to 18:00, Tuesday off
--     Finance           Monday, Wednesday and Friday plus the 10th and the 15th of each month, 10:00 to 19:00, one extra
--                       day a week with overflow work, from Wednesday 2026-11-11
--     Fleet             6 days a week, 11:00 to 21:00, Sunday off
--   Uses: the clock-in reminder starts from the schedule (app.va_clock_start); the staff alerts sent to whoever is on duty
--   also reach a person clocked in during their scheduled hours (app.staff_alert_users); lateness is the first clock-in of a
--   scheduled day after its start plus staff_late_grace_minutes; the duty board (Admin > Staff > Schedules, and each staff
--   member's Schedule page) shows today's schedule, who is clocked in and who is late.
-- No applied migration is edited: app.va_clock_start is replaced, app.staff_alert_users patched, app.door wrapped.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1502: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

alter table program_settings
  add column if not exists staff_late_grace_minutes integer not null default 10 check (staff_late_grace_minutes between 0 and 120);
comment on column program_settings.staff_late_grace_minutes is 'Staff schedules (1502): minutes after a scheduled start before a clock-in counts as late.';

create table if not exists staff_schedules (
  id                  uuid primary key default gen_random_uuid(),
  function            text not null check (function in ('cs', 'fleet', 'finance', 'sales')),
  user_id             uuid references users (id) on delete cascade,
  weekdays            integer[] not null default '{}' check (weekdays <@ array[1, 2, 3, 4, 5, 6, 7]),
  month_days          integer[] not null default '{}' check (month_days <@ '{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31}'::integer[]),
  start_time          time not null,
  end_time            time not null,
  extra_days_per_week integer not null default 0 check (extra_days_per_week between 0 and 3),
  starts_on           date,
  note                text check (length(note) <= 300),
  updated_by          uuid references users (id),
  updated_at          timestamptz not null default now(),
  check (end_time > start_time),
  check (cardinality(weekdays) + cardinality(month_days) > 0)
);
comment on table staff_schedules is 'Staff schedules (1502): a role''s default (user_id null) or a person''s own, set by an Admin. Days: the ISO weekdays and the days of the month; times are Toronto; breaks at the person''s discretion.';
create unique index if not exists staff_schedules_role_default on staff_schedules (function) where user_id is null;
create unique index if not exists staff_schedules_person on staff_schedules (user_id, function) where user_id is not null;
alter table staff_schedules enable row level security;
revoke all on staff_schedules from anon, authenticated;
grant all on staff_schedules to service_role;
create policy admin_all on staff_schedules for select to authenticated using (app.is_admin());
drop trigger if exists audit_staff_schedules on staff_schedules;
create trigger audit_staff_schedules after insert or update or delete on staff_schedules for each row execute function app.audit_row();

insert into staff_schedules (function, weekdays, month_days, start_time, end_time, extra_days_per_week, starts_on, note) values
  ('cs', '{1,3,4,5,6,7}', '{}', '08:00', '18:00', 0, null, 'Six days a week, Tuesday off. Breaks at your discretion.'),
  ('finance', '{1,3,5}', '{10,15}', '10:00', '19:00', 1, date '2026-11-11', 'Monday, Wednesday and Friday plus the 10th and the 15th; one extra day a week when there is overflow work. Breaks at your discretion.'),
  ('fleet', '{1,2,3,4,5,6}', '{}', '11:00', '21:00', 0, null, 'Six days a week, Sunday off. Breaks at your discretion.')
on conflict do nothing;

-- the schedule that applies to a person for a function: their own, else the role's
create function app.staff_schedule_of(p_user uuid, p_fn text) returns staff_schedules
language sql stable security definer set search_path = public, app as $$
  select s from staff_schedules s where s.function = p_fn and (s.user_id = p_user or s.user_id is null)
   order by (s.user_id is null) limit 1
$$;

-- a person's scheduled hours on a day (Toronto): one row per function held whose schedule has the day
create function app.staff_shifts_on(p_user uuid, p_day date)
returns table (function text, starts_at timestamptz, ends_at timestamptz, own boolean)
language sql stable security definer set search_path = public, app as $$
  select f, (p_day + s.start_time) at time zone 'America/Toronto', (p_day + s.end_time) at time zone 'America/Toronto', s.user_id is not null
    from staff_profiles sp cross join unnest(sp.functions) f cross join lateral (select (app.staff_schedule_of(p_user, f)).*) s
   where sp.user_id = p_user and sp.is_active and f in ('cs', 'fleet', 'finance', 'sales') and s.id is not null
     and (s.starts_on is null or p_day >= s.starts_on)
     and (extract(isodow from p_day)::int = any (s.weekdays) or extract(day from p_day)::int = any (s.month_days))
$$;

create function app.staff_on_shift(p_user uuid, p_at timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from app.staff_shifts_on(p_user, app.local_date(p_at)) x where p_at >= x.starts_at and p_at < x.ends_at)
$$;

-- lateness on a scheduled day: the first clock-in against the earliest start (null: not scheduled that day)
create function app.staff_day_status(p_user uuid, p_day date, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with sh as (select min(starts_at) a, max(ends_at) z from app.staff_shifts_on(p_user, p_day)),
       ci as (select min(e.started_at) first_in, coalesce(sum(app.va_clock_minutes(e, p_now)), 0) minutes from staff_clock_entries e
               where e.user_id = p_user and e.voided_at is null and app.local_date(e.started_at) = p_day)
  select case when sh.a is null then jsonb_build_object('scheduled', false, 'first_in', ci.first_in, 'minutes', ci.minutes)
    else jsonb_build_object('scheduled', true, 'starts_at', sh.a, 'ends_at', sh.z, 'first_in', ci.first_in, 'minutes', ci.minutes,
      'late_minutes', case when ci.first_in is not null and ci.first_in > sh.a + make_interval(mins => (app.settings()).staff_late_grace_minutes)
                           then floor(extract(epoch from ci.first_in - sh.a) / 60)::int
                           when ci.first_in is null and p_now > sh.a + make_interval(mins => (app.settings()).staff_late_grace_minutes) and p_now < sh.z
                           then floor(extract(epoch from p_now - sh.a) / 60)::int end,
      'late', (ci.first_in is not null and ci.first_in > sh.a + make_interval(mins => (app.settings()).staff_late_grace_minutes))
              or (ci.first_in is null and p_now > sh.a + make_interval(mins => (app.settings()).staff_late_grace_minutes)),
      'absent', ci.first_in is null and p_now >= sh.z) end
    from sh, ci
$$;

-- the clock-in reminder starts from the schedule; a person with no schedule keeps the old setting (va_clock_starts)
create or replace function app.va_clock_start(p_user uuid, p_day date) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select min(x.starts_at) from app.staff_shifts_on(p_user, p_day) x where x.function in ('cs', 'fleet', 'finance')),
    case when not exists (select 1 from staff_profiles sp cross join unnest(sp.functions) f
                           where sp.user_id = p_user and f in ('cs', 'fleet', 'finance') and (app.staff_schedule_of(p_user, f)).id is not null) then
      (select min((p_day + (s.va_clock_starts ->> f)::time) at time zone 'America/Toronto')
         from staff_profiles sp, program_settings s, unnest(sp.functions) f
        where sp.user_id = p_user and f in ('cs', 'fleet', 'finance') and (s.va_clock_starts ->> f) ~ '^\d{1,2}:\d{2}$'
          and s.id = (app.settings()).id and extract(isodow from p_day)::int = any (s.va_clock_days)) end)
$$;

-- the staff alerts for whoever is on duty also reach a person clocked in within their scheduled hours
select pg_temp.patch_fn('app.staff_alert_users(text, jsonb)'::regprocedure,
  'join chat_staff_prefs cp on cp.user_id = u.id and cp.last_seen_at > now() - make_interval(mins => v_shift)
         where u.status = ''active''',
  'left join chat_staff_prefs cp on cp.user_id = u.id
         where u.status = ''active''
           and (cp.last_seen_at > now() - make_interval(mins => v_shift)
                or (app.staff_on_shift(u.id, now()) and exists (select 1 from staff_clock_entries ce where ce.user_id = u.id and ce.ended_at is null and ce.voided_at is null)))');

-- ================================================================ reads and the Admin's changes
create function app.staff_schedule_json(s staff_schedules) returns jsonb
language sql stable as $$
  select jsonb_build_object('id', s.id, 'function', s.function, 'user_id', s.user_id, 'weekdays', to_jsonb(s.weekdays), 'month_days', to_jsonb(s.month_days),
    'start', to_char(s.start_time, 'HH24:MI'), 'end', to_char(s.end_time, 'HH24:MI'), 'extra_days_per_week', s.extra_days_per_week, 'starts_on', s.starts_on, 'note', s.note,
    'updated_at', s.updated_at)
$$;

-- today's duty board: every active office staff member, their schedule today, clocked in or not, late or not
create function app.staff_duty_board(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email),
      'functions', to_jsonb(array(select f from unnest(sp.functions) f where f in ('cs', 'fleet', 'finance', 'sales'))),
      'today', app.staff_day_status(sp.user_id, app.local_date(p_now), p_now), 'on_shift', app.staff_on_shift(sp.user_id, p_now),
      'clocked_in', exists (select 1 from staff_clock_entries e where e.user_id = sp.user_id and e.ended_at is null and e.voided_at is null))
      order by coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email)), '[]'::jsonb)
    from staff_profiles sp join users u on u.id = sp.user_id
   where sp.is_active and u.status = 'active' and sp.functions && array['cs', 'fleet', 'finance'] and not app.user_is_admin(sp.user_id)
$$;

create function app.staff_schedules_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
begin
  if not (v_admin or app.user_is_staff(p_by) or app.user_is_field(p_by)) then raise exception 'Staff only' using errcode = '42501'; end if;
  return jsonb_build_object('admin', v_admin, 'today', app.today(), 'late_grace_minutes', (app.settings()).staff_late_grace_minutes,
    'defaults', coalesce((select jsonb_agg(app.staff_schedule_json(s) order by s.function) from staff_schedules s where s.user_id is null), '[]'::jsonb),
    'mine', coalesce((select jsonb_agg(jsonb_build_object('function', f, 'schedule', app.staff_schedule_json(app.staff_schedule_of(p_by, f)))) from staff_profiles sp, unnest(sp.functions) f
                       where sp.user_id = p_by and f in ('cs', 'fleet', 'finance', 'sales') and (app.staff_schedule_of(p_by, f)).id is not null), '[]'::jsonb),
    'my_week', (select jsonb_agg(jsonb_build_object('day', d::date, 'shifts', (select coalesce(jsonb_agg(jsonb_build_object('function', x.function, 'starts_at', x.starts_at, 'ends_at', x.ends_at)), '[]'::jsonb)
                                                                                  from app.staff_shifts_on(p_by, d::date) x)) order by d)
                  from generate_series(app.today(), app.today() + 6, interval '1 day') d),
    'own', case when v_admin then coalesce((select jsonb_agg(app.staff_schedule_json(s) || jsonb_build_object('name', coalesce(u.full_name, u.email)) order by u.full_name, s.function)
                                              from staff_schedules s join users u on u.id = s.user_id), '[]'::jsonb) end,
    'staff', case when v_admin then coalesce((select jsonb_agg(jsonb_build_object('id', sp.user_id, 'name', coalesce(u.full_name, u.email),
                                                 'functions', to_jsonb(array(select f from unnest(sp.functions) f where f in ('cs', 'fleet', 'finance', 'sales')))) order by u.full_name)
                                                from staff_profiles sp join users u on u.id = sp.user_id where sp.is_active and sp.functions && array['cs', 'fleet', 'finance', 'sales']), '[]'::jsonb) end,
    'board', app.staff_duty_board(now()));
end $$;

-- p: {function, user_id (empty: the role's default), weekdays [], month_days [], start, end, extra_days_per_week, starts_on, note}
create function app.staff_schedule_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_fn text := p ->> 'function';
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_wd integer[]; v_md integer[];
  v_id uuid;
begin
  perform app.assert_admin(p_by);
  if v_fn is null or v_fn not in ('cs', 'fleet', 'finance', 'sales') then raise exception 'Choose the role' using errcode = '22023'; end if;
  if v_user is not null and not exists (select 1 from staff_profiles sp where sp.user_id = v_user and v_fn = any (sp.functions)) then
    raise exception 'That person does not hold this role' using errcode = '22023';
  end if;
  v_wd := array(select distinct (x)::int from jsonb_array_elements_text(coalesce(case when jsonb_typeof(p -> 'weekdays') = 'array' then p -> 'weekdays' end,
                  to_jsonb(string_to_array(nullif(regexp_replace(coalesce(p ->> 'weekdays', ''), '[^0-9,]', '', 'g'), ''), ',')))) x where x ~ '^[0-9]+$' order by 1);
  v_md := array(select distinct (x)::int from jsonb_array_elements_text(coalesce(case when jsonb_typeof(p -> 'month_days') = 'array' then p -> 'month_days' end,
                  to_jsonb(string_to_array(nullif(regexp_replace(coalesce(p ->> 'month_days', ''), '[^0-9,]', '', 'g'), ''), ',')))) x where x ~ '^[0-9]+$' order by 1);
  if not v_wd <@ array[1, 2, 3, 4, 5, 6, 7] then raise exception 'Weekdays are 1 (Monday) to 7 (Sunday)' using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_md) d where d < 1 or d > 31) then raise exception 'Days of the month are 1 to 31' using errcode = '22023'; end if;
  if cardinality(v_wd) + cardinality(v_md) = 0 then raise exception 'Choose at least one day' using errcode = '22023'; end if;
  if coalesce(p ->> 'start', '') !~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' or coalesce(p ->> 'end', '') !~ '^([01]?[0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Give the start and the end as HH:MM (Toronto)' using errcode = '22023';
  end if;
  if (p ->> 'end')::time <= (p ->> 'start')::time then raise exception 'The end is after the start (same day)' using errcode = '22023'; end if;
  if v_user is null then
    update staff_schedules set weekdays = v_wd, month_days = v_md, start_time = (p ->> 'start')::time, end_time = (p ->> 'end')::time,
           extra_days_per_week = coalesce(nullif(p ->> 'extra_days_per_week', '')::int, 0), starts_on = nullif(p ->> 'starts_on', '')::date,
           note = nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''), updated_by = p_by, updated_at = now()
     where function = v_fn and user_id is null returning id into v_id;
  else
    update staff_schedules set weekdays = v_wd, month_days = v_md, start_time = (p ->> 'start')::time, end_time = (p ->> 'end')::time,
           extra_days_per_week = coalesce(nullif(p ->> 'extra_days_per_week', '')::int, 0), starts_on = nullif(p ->> 'starts_on', '')::date,
           note = nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''), updated_by = p_by, updated_at = now()
     where function = v_fn and user_id = v_user returning id into v_id;
  end if;
  if v_id is null then
    insert into staff_schedules (function, user_id, weekdays, month_days, start_time, end_time, extra_days_per_week, starts_on, note, updated_by)
    values (v_fn, v_user, v_wd, v_md, (p ->> 'start')::time, (p ->> 'end')::time, coalesce(nullif(p ->> 'extra_days_per_week', '')::int, 0),
            nullif(p ->> 'starts_on', '')::date, nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''), p_by)
    returning id into v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

-- p: {id}: a person's own schedule removed (the role's default applies again); a role's default is never removed
create function app.staff_schedule_clear(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  perform app.assert_admin(p_by);
  delete from staff_schedules where id = nullif(p ->> 'id', '')::uuid and user_id is not null returning id into v_id;
  if v_id is null then raise exception 'Only a person''s own schedule is removed; a role''s default is changed instead' using errcode = '23514'; end if;
  return jsonb_build_object('id', v_id, 'removed', true);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1502;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call in ('ops_read', 'admin_read') and p_name = 'staff_schedules') or (p_call in ('ops_do', 'admin_do') and p_name in ('staff_schedule_save', 'staff_schedule_clear')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'staff_schedules' then app.staff_schedules_read(p_user, p_)
                       when 'staff_schedule_save' then app.staff_schedule_save(p_user, p_)
                       else app.staff_schedule_clear(p_user, p_) end;
  end if;
  return app.door_pre1502(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['staff_schedule_of', 'staff_shifts_on', 'staff_on_shift', 'staff_day_status',
                    'staff_schedule_json', 'staff_duty_board', 'staff_schedules_read', 'staff_schedule_save', 'staff_schedule_clear', 'door_pre1502', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
