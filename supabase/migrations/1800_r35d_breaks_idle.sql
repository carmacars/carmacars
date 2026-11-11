-- 1800_r35d_breaks_idle.sql
-- Release 35, part D (docs/changes/2026-11-11-r35d-breaks-idle.md): breaks and inactivity for the office staff who clock in
-- (customer service, Fleet, Finance; Sales does not clock in, app.va_clock_is_office).
--   1. Breaks. Start break and End break next to the clock on the portal home, with a running timer. No fixed length (at
--      the person's discretion); every break is kept with its start, end and an optional reason (staff_breaks). Paid or not
--      is Program settings va_breaks_paid (default on: salaried staff); unpaid breaks come off the hours counted for the
--      payroll (app.pay_clock_minutes). A break still open after va_break_reminder_minutes (30) reminds the person (an alert
--      to them and the Admins, once per break, and a banner on the clock card). Clocking out ends an open break. Only an
--      Admin edits or removes a break, with the reason (audited). The timesheet shows each person's breaks per day (count,
--      total, longest); the payroll lines carry the period's breaks.
--   2. Inactivity. While clocked in and not on a break, the portal tells the database the person is active (a pointer, a
--      key, a scroll or focus: the fact only, never what was typed, the page or a screenshot), at most once a minute, and
--      every action they take through the door counts too (app.va_activity_touch, at most one write a minute). A job every
--      minute opens an idle stretch once nobody has been active for more than va_idle_alert_minutes (10) within the
--      person's scheduled hours (never outside them, never when clocked out or on a break), alerts the Admins once
--      ("<preferred name> (role) inactive since 10:42, 12 min") and once more at va_idle_followup_minutes (30). The next
--      activity closes the stretch (start, end, minutes). The person's own screen shows only a gentle "Still there?" after
--      va_idle_nudge_minutes (8). The idle stretches are the Admins' only: per person and day on the timesheet, and
--      "Idle minutes" on the KPIs (at most kpi_idle_minutes_week a week).
--   3. Pauses (the owner, same day): the tracker also pauses on a phone call and in the townhall; idle is logged only
--      outside them. A call counts while it is active and for a minute after it ends (va_idle_call_grace_minutes, 1), when
--      it is linked to the person: a Quo call whose Quo user is theirs (staff_profiles.quo_user_id, set by an Admin), a
--      call they placed with the portal's Call button (outbound_calls), or a call they noted in the caller pop-up
--      (renter_notes.call_id). A call linked to nobody pauses nobody. The townhall pauses anyone who joined, checked in or
--      was marked present, from its start to its end (townhall_minutes) plus va_idle_townhall_grace_minutes (10).
-- No applied migration is edited: app.va_clock_state, app.va_clock_out, app.va_timesheet, app.payroll_line_json,
-- app.kpi_board and app.door are wrapped; app.pay_clock_minutes is replaced.
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

alter table program_settings
  add column if not exists va_breaks_paid boolean not null default true,
  add column if not exists va_break_reminder_minutes integer not null default 30 check (va_break_reminder_minutes between 5 and 240),
  add column if not exists va_idle_alert_minutes integer not null default 10 check (va_idle_alert_minutes between 3 and 120),
  add column if not exists va_idle_followup_minutes integer not null default 30 check (va_idle_followup_minutes between 5 and 480),
  add column if not exists va_idle_nudge_minutes integer not null default 8 check (va_idle_nudge_minutes between 1 and 120),
  add column if not exists kpi_idle_minutes_week integer not null default 120 check (kpi_idle_minutes_week >= 0),
  add column if not exists va_idle_call_grace_minutes integer not null default 1 check (va_idle_call_grace_minutes between 0 and 30),
  add column if not exists va_idle_townhall_grace_minutes integer not null default 10 check (va_idle_townhall_grace_minutes between 0 and 60);
comment on column program_settings.va_idle_call_grace_minutes is 'Inactivity (1800): a phone call linked to the person pauses the tracker while active and this long after it ends.';
comment on column program_settings.va_idle_townhall_grace_minutes is 'Inactivity (1800): the townhall pauses the tracker for those who joined or were present, to its end plus this long.';

alter table staff_profiles add column if not exists quo_user_id text check (quo_user_id is null or quo_user_id ~ '^[A-Za-z0-9_-]{2,64}$');
comment on column staff_profiles.quo_user_id is 'Inactivity (1800): this person''s Quo user (US...), set by an Admin; a Quo call by that user pauses their inactivity tracker.';
create unique index if not exists staff_profiles_quo_user on staff_profiles (quo_user_id) where quo_user_id is not null;
create index if not exists phone_activity_quo_user_idx on phone_activity (quo_user_id, started_at desc) where kind = 'call' and quo_user_id is not null;
comment on column program_settings.va_breaks_paid is 'Breaks (1800): breaks of the office staff are paid (on: salaried staff). Off: their break minutes come off the hours counted on the payroll.';
comment on column program_settings.va_break_reminder_minutes is 'Breaks (1800): a break still open this long reminds the person and the Admins (once per break).';
comment on column program_settings.va_idle_alert_minutes is 'Inactivity (1800): no activity for more than this, while clocked in, not on a break and within scheduled hours, alerts the Admins.';
comment on column program_settings.va_idle_followup_minutes is 'Inactivity (1800): one more alert when the same idle stretch reaches this many minutes.';
comment on column program_settings.va_idle_nudge_minutes is 'Inactivity (1800): the person''s own screen asks "Still there?" after this many minutes without activity.';
comment on column program_settings.kpi_idle_minutes_week is 'KPIs (1800): the idle minutes a week an office staff member stays within (lower is better).';

-- ================================================================ tables
create table if not exists staff_breaks (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references users (id) on delete cascade,
  clock_entry_id uuid not null references staff_clock_entries (id) on delete cascade,
  started_at     timestamptz not null,
  ended_at       timestamptz check (ended_at is null or ended_at >= started_at),
  reason         text check (length(reason) <= 200),
  reminded_at    timestamptz,
  edited_at      timestamptz,
  edited_by      uuid references users (id),
  edit_reason    text check (length(edit_reason) <= 300),
  voided_at      timestamptz,
  created_at     timestamptz not null default now()
);
comment on table staff_breaks is 'Breaks of the office staff (1800): at their discretion, no fixed length; start, end, an optional reason. Only an Admin edits or removes one, with the reason.';
create unique index if not exists staff_breaks_one_open on staff_breaks (user_id) where ended_at is null and voided_at is null;
create index if not exists staff_breaks_user_idx on staff_breaks (user_id, started_at desc);

-- the last activity of a person while clocked in, kept to the minute; idle_id: the idle stretch open now
create table if not exists staff_activity (
  user_id uuid primary key references users (id) on delete cascade,
  last_at timestamptz not null default now(),
  idle_id uuid
);
comment on table staff_activity is 'Inactivity (1800): the last activity of an office staff member while clocked in (a pointer, key, scroll, focus or an action; the fact only), written at most once a minute.';

create table if not exists staff_idle_periods (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users (id) on delete cascade,
  function    text,
  started_at  timestamptz not null,
  ended_at    timestamptz check (ended_at is null or ended_at >= started_at),
  alerted_at  timestamptz,
  followup_at timestamptz,
  created_at  timestamptz not null default now()
);
comment on table staff_idle_periods is 'Inactivity (1800): a stretch with no activity past va_idle_alert_minutes, from the last activity to the next one. The Admins'' only.';
create unique index if not exists staff_idle_one_open on staff_idle_periods (user_id) where ended_at is null;
create index if not exists staff_idle_user_idx on staff_idle_periods (user_id, started_at desc);

do $$
declare t text;
begin
  foreach t in array array['staff_breaks', 'staff_activity', 'staff_idle_periods'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for select to authenticated using (app.is_admin())', t);
  end loop;
  -- staff_activity is written once a minute per person: not audited (suite 03 lists it); breaks and idle stretches are
  foreach t in array array['staff_breaks', 'staff_idle_periods'] loop
    execute format('drop trigger if exists %I on %I', 'audit_' || t, t);
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('staff_break_long', 'A break is still open', 'Staff', '{assigned,admin}', 'normal', 'alerts', true, false, 'A customer service, Fleet or Finance break open past va_break_reminder_minutes (1800).', 165),
  ('staff_va_idle', 'An office staff member is inactive', 'Staff', '{admin}', 'urgent', 'alerts', true, false, 'Clocked in, not on a break, within their hours, and no activity past va_idle_alert_minutes; once more at va_idle_followup_minutes (1800).', 166)
on conflict (rule) do nothing;

-- ================================================================ breaks
create function app.va_break_minutes(b staff_breaks, p_now timestamptz default now()) returns integer
language sql stable as $$ select greatest(0, floor(extract(epoch from (coalesce(b.ended_at, p_now) - b.started_at)) / 60))::int $$;

-- the breaks that count: not removed, in a clock entry that is not voided
create function app.va_breaks_of(p_user uuid, p_from date, p_to date) returns setof staff_breaks
language sql stable security definer set search_path = public, app as $$
  select b.* from staff_breaks b join staff_clock_entries e on e.id = b.clock_entry_id and e.voided_at is null
   where b.user_id = p_user and b.voided_at is null and app.local_date(b.started_at) between p_from and p_to
$$;

-- {count, minutes, longest} of a person's breaks in a range of days (Toronto)
create function app.va_break_summary(p_user uuid, p_from date, p_to date, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('count', count(*), 'minutes', coalesce(sum(app.va_break_minutes(b, p_now)), 0), 'longest', coalesce(max(app.va_break_minutes(b, p_now)), 0))
    from app.va_breaks_of(p_user, p_from, p_to) b
$$;

create function app.va_break_json(b staff_breaks, p_now timestamptz default now()) returns jsonb
language sql stable as $$
  select jsonb_build_object('id', b.id, 'started_at', b.started_at, 'ended_at', b.ended_at, 'minutes', app.va_break_minutes(b, p_now), 'reason', b.reason,
    'open', b.ended_at is null, 'edited_at', b.edited_at, 'edit_reason', b.edit_reason)
$$;

create function app.va_break_start(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_entry uuid;
begin
  if not app.va_clock_is_office(p_user) then raise exception 'Breaks are for customer service, Fleet and Finance staff' using errcode = '42501'; end if;
  select e.id into v_entry from staff_clock_entries e where e.user_id = p_user and e.ended_at is null and e.voided_at is null;
  if v_entry is null then raise exception 'Clock in first: a break is taken while clocked in' using errcode = '23514'; end if;
  if exists (select 1 from staff_breaks b where b.user_id = p_user and b.ended_at is null and b.voided_at is null) then
    raise exception 'You are already on a break' using errcode = '23514';
  end if;
  insert into staff_breaks (user_id, clock_entry_id, started_at, reason) values (p_user, v_entry, now(), nullif(left(btrim(coalesce(p ->> 'reason', '')), 200), ''));
  return app.va_clock_state(p_user);
end $$;

create function app.va_break_end(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  update staff_breaks set ended_at = now(), reason = coalesce(nullif(left(btrim(coalesce(p ->> 'reason', '')), 200), ''), reason)
   where user_id = p_user and ended_at is null and voided_at is null returning id into v_id;
  if v_id is null then raise exception 'You are not on a break' using errcode = '23514'; end if;
  return app.va_clock_state(p_user);
end $$;

-- an Admin: p {id, started_at, ended_at, reason} corrects a break inside its clock entry; p {id, void: true, reason} removes it
create function app.va_break_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b staff_breaks;
  e staff_clock_entries;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_from timestamptz := nullif(p ->> 'started_at', '')::timestamptz;
  v_to timestamptz := nullif(p ->> 'ended_at', '')::timestamptz;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin edits a break' using errcode = '42501'; end if;
  if length(v_reason) < 3 then raise exception 'Give the reason for the change' using errcode = '22023'; end if;
  select * into b from staff_breaks where id = nullif(p ->> 'id', '')::uuid and voided_at is null for update;
  if b.id is null then raise exception 'Break not found' using errcode = 'P0002'; end if;
  if coalesce((p ->> 'void')::boolean, false) then
    update staff_breaks set voided_at = now(), edited_at = now(), edited_by = p_by, edit_reason = left(v_reason, 300) where id = b.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'staff_break_removed', 'staff_breaks', b.id::text, app.va_break_json(b), jsonb_build_object('reason', left(v_reason, 300)));
    return jsonb_build_object('ok', true, 'removed', true);
  end if;
  select * into e from staff_clock_entries where id = b.clock_entry_id;
  v_from := coalesce(v_from, b.started_at);
  if v_to is null then raise exception 'Give the end of the break' using errcode = '22023'; end if;
  if v_to < v_from then raise exception 'The end is after the start' using errcode = '22023'; end if;
  if v_from < e.started_at or v_to > coalesce(e.ended_at, now()) then raise exception 'A break is inside its clock entry (from the clock in to the clock out)' using errcode = '22023'; end if;
  if exists (select 1 from staff_breaks x where x.user_id = b.user_id and x.id <> b.id and x.voided_at is null
              and x.started_at < v_to and coalesce(x.ended_at, now()) > v_from) then
    raise exception 'That overlaps another break' using errcode = '22023';
  end if;
  update staff_breaks set started_at = v_from, ended_at = v_to, edited_at = now(), edited_by = p_by, edit_reason = left(v_reason, 300) where id = b.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'staff_break_edited', 'staff_breaks', b.id::text, app.va_break_json(b),
          jsonb_build_object('started_at', v_from, 'ended_at', v_to, 'reason', left(v_reason, 300)));
  return jsonb_build_object('ok', true);
end $$;

-- clocking out ends an open break at the same time
alter function app.va_clock_out(uuid, jsonb) rename to va_clock_out_pre1800;
create function app.va_clock_out(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  update staff_breaks set ended_at = now() where user_id = p_user and ended_at is null and voided_at is null;
  return app.va_clock_out_pre1800(p_user, p);
end $$;

-- the clock card: the open break (with the reminder), today's breaks, whether activity is tracked now, the settings the
-- browser needs (never the person's idle stretches)
alter function app.va_clock_state(uuid) rename to va_clock_state_pre1800;
create function app.va_clock_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.va_clock_state_pre1800(p_user) || jsonb_build_object(
    'break', (select app.va_break_json(b) || jsonb_build_object('over', app.va_break_minutes(b) >= s.va_break_reminder_minutes)
                from staff_breaks b where b.user_id = p_user and b.ended_at is null and b.voided_at is null),
    'breaks_today', app.va_break_summary(p_user, app.today(), app.today()),
    'breaks', coalesce((select jsonb_agg(app.va_break_json(b) order by b.started_at desc)
                          from (select * from app.va_breaks_of(p_user, app.today() - 13, app.today()) x order by x.started_at desc limit 40) b), '[]'::jsonb),
    'tracking', exists (select 1 from staff_clock_entries e where e.user_id = p_user and e.ended_at is null and e.voided_at is null)
                and not exists (select 1 from staff_breaks b where b.user_id = p_user and b.ended_at is null and b.voided_at is null),
    'settings', jsonb_build_object('break_reminder_minutes', s.va_break_reminder_minutes, 'idle_nudge_minutes', s.va_idle_nudge_minutes,
                                   'idle_alert_minutes', s.va_idle_alert_minutes, 'breaks_paid', s.va_breaks_paid))
    from (select (app.settings()).*) s
$$;

-- the payroll's hours: unpaid breaks (va_breaks_paid off) come off the clocked minutes
create function app.va_break_total(p_staff uuid, p_start date, p_end date) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce(sum(app.va_break_minutes(b)), 0)::integer from app.va_breaks_of(p_staff, p_start, p_end) b
$$;
create or replace function app.pay_clock_minutes(p_staff uuid, p_start date, p_end date) returns integer
language sql stable security definer set search_path = public, app as $$
  select greatest(0, coalesce(sum(app.va_clock_minutes(e)), 0)
                     - case when (app.settings()).va_breaks_paid then 0 else app.va_break_total(p_staff, p_start, p_end) end)::integer
    from staff_clock_entries e
   where e.user_id = p_staff and e.voided_at is null and app.local_date(e.started_at) between p_start and p_end
$$;

alter function app.payroll_line_json(field_pay_lines) rename to payroll_line_json_pre1800;
create function app.payroll_line_json(l field_pay_lines) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.payroll_line_json_pre1800(l) || coalesce((
    select jsonb_build_object('break_count', (x ->> 'count')::int, 'break_minutes', (x ->> 'minutes')::int, 'break_longest', (x ->> 'longest')::int,
                              'breaks_paid', (app.settings()).va_breaks_paid)
      from field_pay_runs r, lateral (select app.va_break_summary(l.staff_id, r.period_start, r.period_end) x) q
     where r.id = l.run_id and exists (select 1 from staff_profiles sp where sp.user_id = l.staff_id and sp.staff_type = 'va')), '{}'::jsonb)
$$;

-- ================================================================ inactivity
-- a person counted now: an office staff member clocked in, not on a break
create function app.va_tracked(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from staff_clock_entries e where e.user_id = p_user and e.ended_at is null and e.voided_at is null)
     and not exists (select 1 from staff_breaks b where b.user_id = p_user and b.ended_at is null and b.voided_at is null)
$$;

create function app.va_idle_close(p_user uuid, p_at timestamptz) returns void
language sql security definer set search_path = public, app as $$
  update staff_idle_periods set ended_at = greatest(started_at, p_at) where user_id = p_user and ended_at is null;
  update staff_activity set idle_id = null where user_id = p_user and idle_id is not null;
$$;

-- activity (the browser's beat, or any action through the door): kept to the minute; it closes an open idle stretch.
-- Nothing is written for someone not clocked in. True when the person is counted (clocked in, not on a break).
create function app.va_activity_touch(p_user uuid, p_now timestamptz default now()) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare v_idle uuid;
begin
  if p_user is null or not exists (select 1 from staff_clock_entries e where e.user_id = p_user and e.ended_at is null and e.voided_at is null) then return false; end if;
  select a.idle_id into v_idle from staff_activity a where a.user_id = p_user;
  if v_idle is not null then
    perform app.va_idle_close(p_user, p_now);
    update staff_activity set last_at = p_now where user_id = p_user;
  else
    insert into staff_activity (user_id, last_at) values (p_user, p_now)
    on conflict (user_id) do update set last_at = excluded.last_at where staff_activity.last_at <= excluded.last_at - interval '1 minute';
  end if;
  return app.va_tracked(p_user);
end $$;

-- the browser's beat (at most once a minute while clocked in and not on a break): {tracking, nudge_minutes}
create function app.va_activity(p_user uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('tracking', app.va_clock_is_office(p_user) and app.va_tracked(p_user), 'nudge_minutes', (app.settings()).va_idle_nudge_minutes)
$$;

-- ================================================================ pauses: a call or the townhall
-- why the person's tracker is paused at p_now ('call' or 'townhall') and since when; no row: not paused
create function app.va_pause(p_user uuid, p_now timestamptz default now()) returns table (reason text, since timestamptz)
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).* ), c as (
    select a.started_at at from phone_activity a, s
     where a.kind = 'call' and a.started_at <= p_now and a.started_at > p_now - interval '4 hours'
       and (a.ended_at is null or a.ended_at >= p_now - make_interval(mins => s.va_idle_call_grace_minutes))
       and ((a.quo_user_id is not null and a.quo_user_id = (select sp.quo_user_id from staff_profiles sp where sp.user_id = p_user))
            or exists (select 1 from renter_notes n where n.call_id = a.id and n.author_user_id = p_user))
    union all
    select o.started_at from outbound_calls o, s
     where o.staff_user_id = p_user and o.started_at <= p_now and o.started_at > p_now - interval '4 hours'
       and ((o.ended_at is null and o.status in ('starting', 'ringing_staff', 'connecting'))
            or o.ended_at >= p_now - make_interval(mins => s.va_idle_call_grace_minutes))
  ), t as (
    select a.meeting_at at from townhall_attendance a, s
     where a.user_id = p_user and a.meeting_at <= p_now
       and p_now < a.meeting_at + make_interval(mins => s.townhall_minutes + s.va_idle_townhall_grace_minutes)
  )
  select 'call', min(c.at) from c having count(*) > 0
  union all
  select 'townhall', min(t.at) from t having count(*) > 0
$$;

-- the Quo user of a call event that names it later (answered by someone) is kept on the call
alter function app.server_phone_event(jsonb) rename to server_phone_event_pre1800;
create function app.server_phone_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb := app.server_phone_event_pre1800(p);
begin
  if coalesce(p ->> 'type', '') like 'call.%' and nullif(p ->> 'user_id', '') is not null then
    update phone_activity set quo_user_id = p ->> 'user_id'
     where quo_id = coalesce(nullif(p ->> 'call_id', ''), nullif(p ->> 'quo_id', '')) and quo_user_id is distinct from p ->> 'user_id';
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.server_phone_event(jsonb)'::regprocedure, 'app.server_phone_event_pre1800(jsonb)'::regprocedure);

-- an Admin: p {user_id, quo_user_id (empty: none)}
create function app.staff_quo_user_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_user uuid := nullif(p ->> 'user_id', '')::uuid; v_q text := nullif(btrim(coalesce(p ->> 'quo_user_id', '')), '');
begin
  perform app.assert_admin(p_by);
  if v_q is not null and v_q !~ '^[A-Za-z0-9_-]{2,64}$' then raise exception 'A Quo user id looks like US followed by letters and digits' using errcode = '22023'; end if;
  if v_q is not null and exists (select 1 from staff_profiles sp where sp.quo_user_id = v_q and sp.user_id <> v_user) then
    raise exception 'That Quo user is already someone else''s' using errcode = '23505';
  end if;
  update staff_profiles set quo_user_id = v_q where user_id = v_user;
  if not found then raise exception 'That person is not on the staff' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'quo_user_id', v_q);
end $$;

create function app.va_fn_label(p_fn text) returns text
language sql immutable as $$ select case p_fn when 'cs' then 'Customer service' when 'fleet' then 'Fleet' when 'finance' then 'Finance' when 'sales' then 'Sales' else p_fn end $$;

-- every minute: a break open past the reminder (once per break); idle stretches opened, alerted once and followed up once;
-- a stretch whose person is clocked out, on a break or past their hours is closed
create function app.job_va_breaks_idle(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r record;
  n_break integer := 0; n_idle integer := 0; n_follow integer := 0; n_closed integer := 0;
  v_last timestamptz;
  v_fn text;
  v_id uuid;
  v_name text;
  v_min integer;
begin
  for r in select b.* from staff_breaks b where b.ended_at is null and b.voided_at is null and b.reminded_at is null
              and b.started_at <= p_now - make_interval(mins => s.va_break_reminder_minutes) loop
    v_name := (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) from users u where u.id = r.user_id);
    perform app.staff_alert('staff_break_long', 'user', r.user_id, 'break:' || r.id, left(format('%s is still on a break', v_name), 140),
      format('The break started at %s, %s min ago. Press End break when you are back.', to_char(r.started_at at time zone 'America/Toronto', 'FMHH24:MI'),
             floor(extract(epoch from p_now - r.started_at) / 60)::int),
      jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff', 'path_admin', '/admin/timesheet'));
    update staff_breaks set reminded_at = p_now where id = r.id;
    n_break := n_break + 1;
  end loop;

  for r in select i.id, i.user_id, i.started_at, (select min(x.since) from app.va_pause(i.user_id, p_now) x) paused_since
             from staff_idle_periods i where i.ended_at is null loop
    if r.paused_since is not null then
      -- a call or the townhall: the stretch ends when it began
      perform app.va_idle_close(r.user_id, least(p_now, greatest(r.started_at, r.paused_since)));
      n_closed := n_closed + 1;
    elsif not app.va_tracked(r.user_id) or not app.staff_on_shift(r.user_id, p_now) then
      perform app.va_idle_close(r.user_id, least(p_now, coalesce((select max(coalesce(e.ended_at, p_now)) from staff_clock_entries e where e.user_id = r.user_id and e.voided_at is null
                                                                   and e.started_at <= p_now and not exists (select 1 from staff_clock_entries o where o.user_id = r.user_id and o.ended_at is null and o.voided_at is null)), p_now),
                                                   coalesce((select b.started_at from staff_breaks b where b.user_id = r.user_id and b.ended_at is null and b.voided_at is null), p_now)));
      n_closed := n_closed + 1;
    end if;
  end loop;

  for r in select e.user_id, e.started_at clock_at, a.last_at, a.idle_id, i.started_at idle_since, i.followup_at, i.function idle_fn
             from staff_clock_entries e
             left join staff_activity a on a.user_id = e.user_id
             left join staff_idle_periods i on i.id = a.idle_id and i.ended_at is null
            where e.ended_at is null and e.voided_at is null and e.started_at <= p_now
              and not exists (select 1 from staff_breaks b where b.user_id = e.user_id and b.ended_at is null and b.voided_at is null) loop
    continue when not app.va_clock_is_office(r.user_id) or app.staff_is_test(r.user_id);
    select x.function, x.starts_at into v_fn, v_last from app.staff_shifts_on(r.user_id, app.local_date(p_now)) x
     where p_now >= x.starts_at and p_now < x.ends_at and x.function in ('cs', 'fleet', 'finance') order by x.starts_at limit 1;
    continue when v_fn is null;
    -- on a call or in the townhall: counted as active (idle is logged only outside them)
    if exists (select 1 from app.va_pause(r.user_id, p_now)) then
      insert into staff_activity (user_id, last_at) values (r.user_id, p_now) on conflict (user_id) do update set last_at = excluded.last_at, idle_id = null;
      continue;
    end if;
    v_name := (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) from users u where u.id = r.user_id);
    if r.idle_since is null then
      v_last := greatest(v_last, r.clock_at, r.last_at,
                         (select max(b.ended_at) from staff_breaks b where b.user_id = r.user_id and b.voided_at is null and b.ended_at <= p_now));
      continue when p_now - v_last <= make_interval(mins => s.va_idle_alert_minutes);
      v_min := floor(extract(epoch from p_now - v_last) / 60)::int;
      insert into staff_idle_periods (user_id, function, started_at, alerted_at) values (r.user_id, v_fn, v_last, p_now) returning id into v_id;
      insert into staff_activity (user_id, last_at, idle_id) values (r.user_id, v_last, v_id)
      on conflict (user_id) do update set idle_id = excluded.idle_id;
      perform app.staff_alert('staff_va_idle', 'user', r.user_id, 'idle:' || v_id,
        left(format('%s (%s) inactive since %s, %s min', v_name, app.va_fn_label(v_fn), to_char(v_last at time zone 'America/Toronto', 'FMHH24:MI'), v_min), 140),
        'Clocked in, not on a break, within their scheduled hours, and no activity on the portal.',
        jsonb_build_object('path_admin', '/admin/timesheet'));
      n_idle := n_idle + 1;
    elsif r.followup_at is null and p_now - r.idle_since >= make_interval(mins => s.va_idle_followup_minutes) then
      v_min := floor(extract(epoch from p_now - r.idle_since) / 60)::int;
      update staff_idle_periods set followup_at = p_now where id = r.idle_id;
      perform app.staff_alert('staff_va_idle', 'user', r.user_id, 'idle:' || r.idle_id || ':followup',
        left(format('%s (%s) still inactive since %s, %s min', v_name, app.va_fn_label(coalesce(r.idle_fn, v_fn)), to_char(r.idle_since at time zone 'America/Toronto', 'FMHH24:MI'), v_min), 140),
        'Still no activity on the portal while clocked in.', jsonb_build_object('path_admin', '/admin/timesheet'));
      n_follow := n_follow + 1;
    end if;
  end loop;
  return format('%s break reminders, %s idle alerts, %s follow-ups, %s closed', n_break, n_idle, n_follow, n_closed);
end $$;

-- ================================================================ reads for Finance and the Admins
-- a person's days in a range: hours, worked hours (unpaid breaks off), breaks; with p_idle (Admins only) the idle stretches
create function app.va_person_days(p_user uuid, p_from date, p_to date, p_idle boolean) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with days as (
    select d::date as day from generate_series(p_from, p_to, interval '1 day') d
  ), c as (
    select app.local_date(e.started_at) as day, sum(app.va_clock_minutes(e)) minutes from staff_clock_entries e
     where e.user_id = p_user and e.voided_at is null and app.local_date(e.started_at) between p_from and p_to group by 1
  ), b as (
    select app.local_date(x.started_at) as day, count(*) n, sum(app.va_break_minutes(x)) minutes, max(app.va_break_minutes(x)) longest
      from app.va_breaks_of(p_user, p_from, p_to) x group by 1
  ), i as (
    select app.local_date(x.started_at) as day, count(*) n, sum(floor(extract(epoch from coalesce(x.ended_at, now()) - x.started_at) / 60))::int minutes
      from staff_idle_periods x where p_idle and x.user_id = p_user and app.local_date(x.started_at) between p_from and p_to group by 1
  )
  select jsonb_build_object(
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', days.day, 'minutes', coalesce(c.minutes, 0),
                 'worked_minutes', greatest(0, coalesce(c.minutes, 0) - case when (app.settings()).va_breaks_paid then 0 else coalesce(b.minutes, 0) end),
                 'breaks', jsonb_build_object('count', coalesce(b.n, 0), 'minutes', coalesce(b.minutes, 0), 'longest', coalesce(b.longest, 0)))
               || case when p_idle then jsonb_build_object('idle', jsonb_build_object('count', coalesce(i.n, 0), 'minutes', coalesce(i.minutes, 0))) else '{}'::jsonb end
               order by days.day)
             from days left join c on c.day = days.day left join b on b.day = days.day left join i on i.day = days.day
            where c.day is not null or b.day is not null or i.day is not null), '[]'::jsonb),
    'breaks', coalesce((select jsonb_agg(app.va_break_json(x) order by x.started_at) from app.va_breaks_of(p_user, p_from, p_to) x), '[]'::jsonb))
  || case when p_idle then jsonb_build_object('idle', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'started_at', x.started_at, 'ended_at', x.ended_at,
          'minutes', floor(extract(epoch from coalesce(x.ended_at, now()) - x.started_at) / 60)::int, 'open', x.ended_at is null, 'function', x.function) order by x.started_at)
        from staff_idle_periods x where x.user_id = p_user and app.local_date(x.started_at) between p_from and p_to), '[]'::jsonb)) else '{}'::jsonb end
$$;

-- the timesheet (Finance and Admin, 1061) gets each person's days with their breaks; the Admins also their idle time
alter function app.va_timesheet(uuid, jsonb) rename to va_timesheet_pre1800;
create function app.va_timesheet(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.va_timesheet_pre1800(p_by, p);
  v_admin boolean := app.user_is_admin(p_by);
  v_from date := (v ->> 'from')::date;
  v_to date := (v ->> 'to')::date;
begin
  return v || jsonb_build_object('admin', v_admin, 'breaks_paid', (app.settings()).va_breaks_paid, 'idle_alert_minutes', (app.settings()).va_idle_alert_minutes,
    'people', coalesce((select jsonb_agg(x.p || app.va_person_days((x.p ->> 'user_id')::uuid, v_from, v_to, v_admin)
                                           || case when v_admin then jsonb_build_object('quo_user_id', (select sp.quo_user_id from staff_profiles sp where sp.user_id = (x.p ->> 'user_id')::uuid)) else '{}'::jsonb end order by x.k)
                          from jsonb_array_elements(v -> 'people') with ordinality x(p, k)), '[]'::jsonb));
end $$;

-- ================================================================ the KPIs: idle minutes a week (the Admins' board only)
create function app.kpi_idle(p_user uuid, p_week date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with w as (select p_week::timestamp at time zone 'America/Toronto' a, (p_week + 7)::timestamp at time zone 'America/Toronto' z),
       x as (select count(*) n, coalesce(sum(floor(extract(epoch from coalesce(i.ended_at, now()) - i.started_at) / 60)), 0)::int m
               from staff_idle_periods i, w where i.user_id = p_user and i.started_at >= w.a and i.started_at < w.z)
  select app.kpi_item('idle_minutes', 'Idle minutes', x.m, (app.settings()).kpi_idle_minutes_week, 'min', x.m <= (app.settings()).kpi_idle_minutes_week,
                      x.n || case when x.n = 1 then ' idle stretch' else ' idle stretches' end)
    from x
$$;

alter function app.kpi_board(uuid, jsonb) rename to kpi_board_pre1800;
create function app.kpi_board(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.kpi_board_pre1800(p_by, p);
  v_week date := (v ->> 'week')::date;
begin
  if not app.user_is_admin(p_by) then return v; end if;
  return v || jsonb_build_object('people', coalesce((select jsonb_agg(case when x.p -> 'functions' ?| array['cs', 'fleet', 'finance']
                 then jsonb_set(x.p, '{items}', coalesce(x.p -> 'items', '[]'::jsonb) || jsonb_build_array(app.kpi_idle((x.p ->> 'user_id')::uuid, v_week))) else x.p end order by x.k)
               from jsonb_array_elements(v -> 'people') with ordinality x(p, k)), '[]'::jsonb),
    'settings', coalesce(v -> 'settings', '{}'::jsonb) || jsonb_build_object('idle_minutes_week', (app.settings()).kpi_idle_minutes_week));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1800;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'ops_do' and p_name in ('va_break_start', 'va_break_end', 'va_activity')) or (p_call in ('ops_do', 'admin_do') and p_name in ('va_break_edit', 'staff_quo_user_set')) then
    perform app.door_begin(p_user, p_aal);
    if p_name not in ('va_break_edit', 'staff_quo_user_set') then perform app.va_activity_touch(p_user); end if;
    return case p_name
      when 'va_break_start' then app.va_break_start(p_user, p_)
      when 'va_break_end' then app.va_break_end(p_user, p_)
      when 'va_activity' then app.va_activity(p_user, p_)
      when 'staff_quo_user_set' then app.staff_quo_user_set(p_user, p_)
      else app.va_break_edit(p_user, p_) end;
  end if;
  -- every action of a person clocked in counts as activity (one write a minute at most)
  if p_call in ('ops_do', 'va_do', 'admin_do', 'admin_save', 'field_do') then perform app.va_activity_touch(p_user); end if;
  return app.door_pre1800(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1800(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['va_break_minutes', 'va_breaks_of', 'va_break_summary', 'va_break_json', 'va_break_start', 'va_break_end',
                    'va_break_edit', 'va_clock_out_pre1800', 'va_clock_out', 'va_clock_state_pre1800', 'va_clock_state', 'va_break_total', 'pay_clock_minutes',
                    'payroll_line_json_pre1800', 'payroll_line_json', 'va_tracked', 'va_idle_close', 'va_activity_touch', 'va_activity', 'va_fn_label',
                    'job_va_breaks_idle', 'va_person_days', 'va_timesheet_pre1800', 'va_timesheet', 'kpi_idle', 'kpi_board_pre1800', 'kpi_board', 'door_pre1800',
                    'va_pause', 'server_phone_event_pre1800', 'staff_quo_user_set'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-va-breaks-idle', '* * * * *', 'select app.job_va_breaks_idle()');
  end if;
end $$;
