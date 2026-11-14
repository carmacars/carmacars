-- 2863 (release 45, part B): a townhall that did not happen counts nobody absent.
--
-- app.job_townhall (1068) recorded every active staff member absent for each weekly townhall once its time was over,
-- held or not, so Settings > Staff showed "Missed 1 townhall (8 weeks)" for everyone after a week with no call.
--   1. townhall_meetings.not_held (with the reason, who and when): a meeting with no attendance at all (nobody joined,
--      checked in or was marked present) is recorded as not held and counts nobody absent. Two misses in a row
--      (townhall_lockouts, 1505) count only meetings that were held.
--   2. admin_do townhall_not_held {meeting_at, reason}: "This townhall did not happen" on the Townhall page marks a past
--      meeting not held, clears its absences, closes its absence alerts and lifts a lockout it caused.
--   3. admin_do townhall_cancel {meeting_at, reason, on}: an upcoming townhall is cancelled (on false: back on). No reminder
--      is sent for it, and it is recorded as not held once its time is over.
--   4. The Townhall page (ops_read townhall) lists the last 8 meetings (held or not, how many were there and missed) and
--      the next 4 (cancelled or not) for an Admin.
--   5. Once: every past meeting with no attendance at all is marked not held and its absences cleared.
-- No applied migration is edited: job_townhall, townhall_reminders, townhall_view and the door are wrapped (_pre2863);
-- townhall_lockouts is replaced; the hour-before alert of 1068 (in job_townhall_pre1505) is patched to skip a cancelled one.
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
  if position(p_old in d) = 0 then raise exception '2863: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. not held
alter table townhall_meetings add column if not exists not_held boolean not null default false;
alter table townhall_meetings add column if not exists not_held_reason text;
alter table townhall_meetings add column if not exists not_held_by uuid references users (id);
alter table townhall_meetings add column if not exists not_held_at timestamptz;
comment on column townhall_meetings.not_held is 'r45 (2863): the townhall did not happen (nobody attended, cancelled ahead, or an Admin said so): nobody counts as absent.';

create table if not exists townhall_cancellations (
  meeting_at   timestamptz primary key,
  reason       text not null check (length(btrim(reason)) between 3 and 300),
  cancelled_by uuid references users (id),
  cancelled_at timestamptz not null default now()
);
comment on table townhall_cancellations is 'r45 (2863): an upcoming townhall an Admin cancelled: no reminders, recorded as not held once its time is over.';
alter table townhall_cancellations enable row level security;
revoke all on townhall_cancellations from anon, authenticated;
grant all on townhall_cancellations to service_role;
create policy admin_all on townhall_cancellations for select to authenticated using (app.is_admin());
create trigger audit_townhall_cancellations after insert or update or delete on townhall_cancellations for each row execute function app.audit_row();

-- a meeting not held: no absences, its absence alert read, a lockout it caused lifted
create function app.townhall_not_held_apply(p_at timestamptz, p_by uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_absent uuid[];
  v_alerts integer;
  v_unlocked integer := 0;
  r record;
begin
  select absent into v_absent from townhall_meetings where meeting_at = p_at;
  insert into townhall_meetings (meeting_at, absent, not_held, not_held_reason, not_held_by, not_held_at)
  values (p_at, '{}', true, left(p_reason, 300), p_by, now())
  on conflict (meeting_at) do update set absent = '{}', not_held = true, not_held_reason = excluded.not_held_reason, not_held_by = excluded.not_held_by, not_held_at = now();
  update notifications n set read_at = now()
    from app_events e
   where e.id = n.event_id and n.read_at is null and e.payload ->> 'rule' = 'townhall_absent'
     and e.payload ->> 'kind' = 'townhall_absent:absent:' || to_char(p_at, 'YYYYMMDDHH24MI');
  get diagnostics v_alerts = row_count;
  for r in select sp.user_id from staff_profiles sp
            where sp.lock_reason = 'townhall' and sp.inactive_locked_at is not null and sp.user_id = any (coalesce(v_absent, '{}'))
              and exists (select 1 from audit_log a where a.action = 'staff_locked_townhall' and a.entity_id = sp.user_id::text
                            and a.after -> 'meetings' @> jsonb_build_array(p_at)) loop
    update staff_profiles set inactive_locked_at = null, inactive_unlocked_at = now(), inactive_unlocked_by = p_by, last_seen_at = now()
     where user_id = r.user_id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'staff_unlocked', 'staff_profiles', r.user_id::text, jsonb_build_object('reason', 'townhall not held', 'meeting_at', p_at));
    v_unlocked := v_unlocked + 1;
  end loop;
  return jsonb_build_object('meeting_at', p_at, 'cleared', coalesce(cardinality(v_absent), 0), 'alerts_closed', v_alerts, 'unlocked', v_unlocked);
end $$;

alter function app.job_townhall(timestamptz) rename to job_townhall_pre2863;
create function app.job_townhall(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_m timestamptz;
  n integer := 0;
begin
  -- before the absences are counted (job_townhall_pre2863 skips a meeting already recorded): a cancelled one, or one with
  -- no attendance at all, is recorded as not held
  for v_m in select m from (select app.townhall_next(p_now - make_interval(days => d)) m from generate_series(1, 8) d) x
              where m is not null and m + make_interval(mins => s.townhall_minutes + 15) <= p_now and m > p_now - interval '7 days' group by m loop
    if exists (select 1 from townhall_meetings where meeting_at = v_m) then continue; end if;
    if exists (select 1 from townhall_cancellations c where c.meeting_at = v_m) then
      insert into townhall_meetings (meeting_at, absent, not_held, not_held_reason, not_held_by, not_held_at)
      select v_m, '{}', true, 'Cancelled: ' || c.reason, c.cancelled_by, now() from townhall_cancellations c where c.meeting_at = v_m;
      n := n + 1;
    elsif not exists (select 1 from townhall_attendance a where a.meeting_at = v_m) then
      insert into townhall_meetings (meeting_at, absent, not_held, not_held_reason, not_held_at) values (v_m, '{}', true, 'Nobody attended: recorded as not held', now());
      n := n + 1;
    end if;
  end loop;
  return app.job_townhall_pre2863(p_now) || format(', %s not held', n);
end $$;
select pg_temp.copy_grants('app.job_townhall(timestamptz)'::regprocedure, 'app.job_townhall_pre2863(timestamptz)'::regprocedure);
revoke all on function app.job_townhall_pre2863(timestamptz) from public, anon, authenticated;
grant execute on function app.job_townhall_pre2863(timestamptz) to service_role;

-- two missed in a row: only meetings that were held count (1505's rule otherwise unchanged)
create or replace function app.townhall_lockouts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  m1 townhall_meetings; m0 townhall_meetings;
  r record;
  n integer := 0;
begin
  select * into m1 from townhall_meetings where not not_held order by meeting_at desc limit 1;
  select * into m0 from townhall_meetings where not not_held and meeting_at < m1.meeting_at order by meeting_at desc limit 1;
  if m1.meeting_at is null or m0.meeting_at is null then return 0; end if;
  for r in select sp.user_id from staff_profiles sp
            where sp.user_id = any (m1.absent) and sp.user_id = any (m0.absent) and sp.inactive_locked_at is null and app.staff_is_member(sp.user_id)
              and coalesce(sp.inactive_unlocked_at, '-infinity'::timestamptz) < m1.meeting_at loop
    update staff_profiles set inactive_locked_at = p_now, lock_reason = 'townhall' where user_id = r.user_id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'staff_locked_townhall', 'staff_profiles', r.user_id::text, jsonb_build_object('meetings', jsonb_build_array(m0.meeting_at, m1.meeting_at)));
    perform app.staff_alert('townhall_absent', 'user', r.user_id, 'locked:' || r.user_id || ':' || to_char(m1.meeting_at, 'YYYYMMDDHH24MI'),
      (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) from users u where u.id = r.user_id) || ' is locked out: two townhalls missed in a row',
      'Unlock them on the staff list once you have spoken to them.', jsonb_build_object('path_admin', '/admin/settings/staff'));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ 3. no reminder for a cancelled one
alter function app.townhall_reminders(timestamptz) rename to townhall_reminders_pre2863;
create function app.townhall_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from townhall_cancellations c where c.meeting_at = app.townhall_next(p_now)) then return 0; end if;
  return app.townhall_reminders_pre2863(p_now);
end $$;
select pg_temp.copy_grants('app.townhall_reminders(timestamptz)'::regprocedure, 'app.townhall_reminders_pre2863(timestamptz)'::regprocedure);
revoke all on function app.townhall_reminders_pre2863(timestamptz) from public, anon, authenticated;
grant execute on function app.townhall_reminders_pre2863(timestamptz) to service_role;
select pg_temp.patch_fn('app.job_townhall_pre1505(timestamptz)'::regprocedure,
  'if v_next is not null and v_next > p_now and v_next <= p_now + interval ''60 minutes'' then',
  'if v_next is not null and v_next > p_now and v_next <= p_now + interval ''60 minutes'' and not exists (select 1 from townhall_cancellations c where c.meeting_at = v_next) then');

-- ================================================================ 2 and 3. the Admin's actions
create function app.townhall_meeting_do(p_by uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_at timestamptz := nullif(p ->> 'meeting_at', '')::timestamptz;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_on boolean := coalesce((p ->> 'on')::boolean, true);
  r jsonb;
begin
  perform app.assert_admin(p_by);
  if v_at is null then raise exception 'Choose the townhall' using errcode = '22023'; end if;
  if p_name = 'townhall_not_held' then
    if v_at > now() then raise exception 'That townhall has not started yet: cancel it instead' using errcode = '23514'; end if;
    if length(v_reason) < 3 then v_reason := 'The townhall did not happen'; end if;
    r := app.townhall_not_held_apply(v_at, p_by, v_reason);
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'townhall_not_held', 'townhall_meetings', v_at::text, r || jsonb_build_object('reason', v_reason));
    return r;
  end if;
  -- townhall_cancel
  if v_at <= now() then raise exception 'That townhall has already started: say it did not happen instead' using errcode = '23514'; end if;
  if v_on then
    if length(v_reason) < 3 then raise exception 'Give the reason for cancelling it' using errcode = '22023'; end if;
    insert into townhall_cancellations (meeting_at, reason, cancelled_by) values (v_at, left(v_reason, 300), p_by)
    on conflict (meeting_at) do update set reason = excluded.reason, cancelled_by = excluded.cancelled_by, cancelled_at = now();
  else
    delete from townhall_cancellations where meeting_at = v_at;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, case when v_on then 'townhall_cancelled' else 'townhall_uncancelled' end, 'townhall_cancellations', v_at::text, jsonb_build_object('reason', nullif(v_reason, '')));
  return jsonb_build_object('meeting_at', v_at, 'cancelled', v_on);
end $$;

-- ================================================================ 4. the page
create function app.townhall_meetings_admin(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'past', coalesce((select jsonb_agg(jsonb_build_object('meeting_at', m.meeting_at, 'held', not m.not_held, 'reason', m.not_held_reason, 'missed', cardinality(m.absent),
               'attended', (select count(*) from townhall_attendance a where a.meeting_at = m.meeting_at and app.townhall_attended(m.meeting_at, a.user_id))) order by m.meeting_at desc)
             from (select * from townhall_meetings where meeting_at <= p_now order by meeting_at desc limit 8) m), '[]'::jsonb),
    'upcoming', coalesce((select jsonb_agg(jsonb_build_object('meeting_at', x.m, 'cancelled', c.meeting_at is not null, 'reason', c.reason) order by x.m)
             from (select distinct app.townhall_next(p_now + make_interval(days => 7 * k)) m from generate_series(0, 3) k) x
             left join townhall_cancellations c on c.meeting_at = x.m where x.m > p_now), '[]'::jsonb))
$$;

alter function app.townhall_view(uuid, jsonb) rename to townhall_view_pre2863;
create function app.townhall_view(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.townhall_view_pre2863(p_by, p);
begin
  return v || jsonb_build_object('next_cancelled', exists (select 1 from townhall_cancellations c where c.meeting_at = app.townhall_next(now())))
    || case when app.user_is_admin(p_by) then jsonb_build_object('meetings', app.townhall_meetings_admin(now())) else '{}'::jsonb end;
end $$;
select pg_temp.copy_grants('app.townhall_view(uuid, jsonb)'::regprocedure, 'app.townhall_view_pre2863(uuid, jsonb)'::regprocedure);
revoke all on function app.townhall_view_pre2863(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.townhall_view_pre2863(uuid, jsonb) to service_role;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2863;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name in ('townhall_not_held', 'townhall_cancel') then
    perform app.door_begin(p_user, p_aal);
    return app.townhall_meeting_do(p_user, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2863(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2863(uuid, text, text, text, jsonb)'::regprocedure);
revoke all on function app.door_pre2863(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre2863(uuid, text, text, text, jsonb) to service_role;

do $$
declare f text;
begin
  foreach f in array array['app.townhall_not_held_apply(timestamptz, uuid, text)', 'app.townhall_meeting_do(uuid, text, jsonb)', 'app.townhall_meetings_admin(timestamptz)',
                           'app.townhall_lockouts(timestamptz)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- ================================================================ 5. once: the past meetings nobody attended
do $$
declare
  v_m timestamptz;
  n integer := 0;
  v_cleared integer := 0;
  r jsonb;
begin
  for v_m in select m.meeting_at from townhall_meetings m
              where m.meeting_at < now() and not m.not_held and not exists (select 1 from townhall_attendance a where a.meeting_at = m.meeting_at) loop
    r := app.townhall_not_held_apply(v_m, null, 'Nobody attended: recorded as not held (2863)');
    n := n + 1;
    v_cleared := v_cleared + (r ->> 'cleared')::integer;
  end loop;
  raise notice '2863: % townhall(s) marked not held, % absence(s) cleared', n, v_cleared;
end $$;
