-- 5302 (R51 staff, REQ-131; docs/changes/2026-11-27-r51-staff.md): managers see the staff assigned to them. The owner
-- (Nov 27 17:29): "also i need to be able to set staff to managers that have insight on the staff that are assigned to them".
--   1. staff_profiles.is_manager and staff_profiles.manager_id. An Admin marks a manager (admin_do staff_manager_set) and
--      assigns staff to one (admin_do staff_team_set). Nobody manages themself and a team never loops back to its member.
--      A manager no longer marked keeps no team (their staff are unassigned). Each change tells the manager and the staff
--      member (alert team_changed).
--   2. A manager reads, read only, their team (ops_read my_team): each member's functions, last seen, hours in the last 7
--      days, academy progress, pay owed (pending pay lines and commissions not yet paid, with "held"), field jobs open and
--      done in 7 days. One member (ops_read team_member): the scorecard and KPIs, the academy, pay owed, the field jobs of
--      the last 14 days and the next 7, the clock entries of 14 days and the last 20 actions (what and when, as the audit
--      log names them; no values). Nothing a manager reads is more than an Admin sees: no pay details, no addresses, no
--      customer numbers. Anyone else is refused.
--   3. app.my_roles says manager (and the team size), for the staff menu and the app.
-- No applied migration is edited: my_roles and the door are wrapped (_pre5302).
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

-- ================================================================ 1. managers and teams
alter table staff_profiles
  add column if not exists is_manager boolean not null default false,
  add column if not exists manager_id uuid references users (id) on delete set null;
alter table staff_profiles add constraint staff_profiles_not_own_manager check (manager_id is null or manager_id <> user_id);
create index if not exists staff_profiles_manager_idx on staff_profiles (manager_id) where manager_id is not null;
comment on column staff_profiles.is_manager is 'Managers (5302, REQ-131): this staff member manages the staff assigned to them (manager_id) and reads their team, read only.';
comment on column staff_profiles.manager_id is 'Managers (5302): the manager this staff member is assigned to.';

create function app.staff_is_manager(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id where sp.user_id = p_user and sp.is_manager and u.status = 'active')
$$;

-- this person manages that one (directly)
create function app.manages(p_manager uuid, p_member uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.staff_is_manager(p_manager) and exists (select 1 from staff_profiles sp where sp.user_id = p_member and sp.manager_id = p_manager)
$$;

create function app.team_notify(p_manager uuid, p_member uuid, p_joined boolean) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.staff_alert('team_changed', 'user', p_member, case when p_joined then 'joined:' else 'left:' end || p_manager,
    case when p_joined then format('%s joined your team', app.staff_display_name(p_member)) else format('%s left your team', app.staff_display_name(p_member)) end,
    case when p_joined then 'Their hours, academy, KPIs, pay owed and field jobs are on My team.' else 'They are no longer on My team.' end,
    jsonb_build_object('assigned_to', p_manager, 'path_staff', '/staff/team', 'path_admin', '/admin/settings/staff'));
  perform app.staff_alert('team_changed', 'user', p_member, case when p_joined then 'manager:' else 'nomanager:' end || p_manager,
    case when p_joined then format('Your manager is %s', app.staff_display_name(p_manager)) else format('%s is no longer your manager', app.staff_display_name(p_manager)) end,
    case when p_joined then 'They can see your hours, academy progress, KPIs, pay owed and field jobs, read only.' else 'They no longer see your work.' end,
    jsonb_build_object('assigned_to', p_member, 'path_staff', '/staff', 'path_admin', '/admin/settings/staff'));
exception when others then raise warning 'team alert not made: %', sqlerrm;
end $$;

create function app.staff_manager_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_on boolean := coalesce((p ->> 'manager')::boolean, true);
  m record;
begin
  perform app.assert_admin(p_by);
  if not exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id where sp.user_id = v_user and u.status = 'active') then
    raise exception 'Choose an active staff member' using errcode = '22023';
  end if;
  update staff_profiles set is_manager = v_on where user_id = v_user;
  if not v_on then
    for m in select user_id from staff_profiles where manager_id = v_user loop
      update staff_profiles set manager_id = null where user_id = m.user_id;
      perform app.team_notify(v_user, m.user_id, false);
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'manager', v_on, 'team', (select count(*) from staff_profiles where manager_id = v_user));
end $$;

create function app.staff_team_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_mgr uuid := nullif(p ->> 'manager_id', '')::uuid;
  v_old uuid;
begin
  perform app.assert_admin(p_by);
  select manager_id into v_old from staff_profiles where user_id = v_user;
  if not found then raise exception 'Choose a staff member' using errcode = '22023'; end if;
  if v_mgr is not null then
    if v_mgr = v_user then raise exception 'Nobody manages themself' using errcode = '22023'; end if;
    if not app.staff_is_manager(v_mgr) then raise exception 'Mark them as a manager first' using errcode = '22023'; end if;
    -- no loop: the new manager is not managed (at any level) by this person
    if exists (with recursive up as (select sp.manager_id m, 1 d from staff_profiles sp where sp.user_id = v_mgr
                                    union all select sp.manager_id, up.d + 1 from staff_profiles sp join up on sp.user_id = up.m where up.d < 20)
               select 1 from up where m = v_user) then
      raise exception '% is in %''s team: a team cannot loop back', app.staff_display_name(v_mgr), app.staff_display_name(v_user) using errcode = '22023';
    end if;
  end if;
  if v_old is not distinct from v_mgr then return jsonb_build_object('ok', true, 'changed', false); end if;
  update staff_profiles set manager_id = v_mgr where user_id = v_user;
  if v_old is not null then perform app.team_notify(v_old, v_user, false); end if;
  if v_mgr is not null then perform app.team_notify(v_mgr, v_user, true); end if;
  return jsonb_build_object('ok', true, 'changed', true, 'manager', case when v_mgr is not null then app.staff_display_name(v_mgr) end);
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, hint, sort) values
  ('team_changed', 'Team changed (manager or member)', 'Staff', '{assigned}', 'normal', 'alerts', true, true, 'A manager hears who joined or left their team; the staff member hears who their manager is.', 129)
on conflict (rule) do nothing;

-- ================================================================ 2. what a manager reads
-- the minutes worked from a time: clocked (office) and field shifts, ended or still open, not voided
create function app.team_minutes(p_user uuid, p_from timestamptz) returns integer
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(sum(extract(epoch from least(coalesce(x.e, now()), now()) - greatest(x.s, p_from)) / 60), 0)::integer
    from (select c.started_at s, c.ended_at e from staff_clock_entries c where c.user_id = p_user and c.voided_at is null and coalesce(c.ended_at, now()) > p_from
          union all
          select f.started_at, f.ended_at from field_shifts f where f.staff_id = p_user and f.voided_at is null and coalesce(f.ended_at, now()) > p_from) x
   where coalesce(x.e, now()) > greatest(x.s, p_from)
$$;

-- pay owed: pay lines not paid yet and commissions earned and not paid
create function app.team_pay_owed(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'pay_lines_cents', coalesce((select sum(l.gross_cents) from field_pay_lines l join field_pay_runs r on r.id = l.run_id
                                  where l.staff_id = p_user and l.status = 'pending' and r.status <> 'void'), 0),
    'held', exists (select 1 from field_pay_lines l where l.staff_id = p_user and l.status = 'pending' and l.academy_held_at is not null),
    'commission_cents', coalesce((select sum(c.amount_cents) from staff_commissions c
                                   where c.staff_id = p_user and c.status in ('accruing', 'pending_approval', 'approved')), 0))
$$;

create function app.team_row(p_member uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('id', u.id, 'name', app.staff_display_name(u.id), 'status', u.status, 'functions', to_jsonb(coalesce(sp.functions, '{}')),
           'last_seen_at', greatest(sp.last_seen_at, (select a.last_at from staff_activity a where a.user_id = u.id)),
           'minutes_7d', app.team_minutes(u.id, now() - interval '7 days'),
           'academy', app.academy_counts(u.id),
           'pay', app.team_pay_owed(u.id),
           'jobs_open', (select count(*) from field_jobs j where j.assigned_to = u.id and j.status in ('scheduled', 'acknowledged', 'in_progress')),
           'jobs_done_7d', (select count(*) from field_jobs j where j.assigned_to = u.id and j.status = 'done' and j.completed_at > now() - interval '7 days'))
    from users u join staff_profiles sp on sp.user_id = u.id where u.id = p_member
$$;

create function app.my_team_read(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not app.staff_is_manager(p_user) then raise exception 'Only a manager sees a team' using errcode = '42501'; end if;
  return jsonb_build_object('members', coalesce((select jsonb_agg(app.team_row(sp.user_id) order by app.staff_display_name(sp.user_id))
                                                   from staff_profiles sp where sp.manager_id = p_user), '[]'::jsonb));
end $$;

create function app.team_member_read(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_m uuid := nullif(p ->> 'user_id', '')::uuid;
  v_score jsonb;
begin
  if not app.manages(p_user, v_m) then raise exception 'Not on your team' using errcode = '42501'; end if;
  begin v_score := app.staff_scorecard(v_m, 6); exception when others then v_score := null; end;
  return app.team_row(v_m) || jsonb_build_object(
    'scorecard', v_score,
    'jobs', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'kind', j.kind, 'status', j.status, 'at', j.scheduled_at, 'done_at', j.completed_at,
                                                          'booking', b.booking_number, 'car', nullif(btrim(concat_ws(' ', v.year, v.make, v.model)), '')) order by j.scheduled_at desc)
                        from field_jobs j left join bookings b on b.id = j.booking_id left join vehicles v on v.id = j.vehicle_id
                       where j.assigned_to = v_m and j.scheduled_at between now() - interval '14 days' and now() + interval '7 days'), '[]'::jsonb),
    'clock', coalesce((select jsonb_agg(jsonb_build_object('from', x.s, 'to', x.e, 'kind', x.k) order by x.s desc)
                         from (select c.started_at s, c.ended_at e, 'clock' k from staff_clock_entries c where c.user_id = v_m and c.voided_at is null and c.started_at > now() - interval '14 days'
                               union all select f.started_at, f.ended_at, 'shift' from field_shifts f where f.staff_id = v_m and f.voided_at is null and f.started_at > now() - interval '14 days') x), '[]'::jsonb),
    'activity', coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'action', a.action, 'what', a.entity_table) order by a.at desc)
                            from (select at, action, entity_table from audit_log where actor_user_id = v_m order by at desc limit 20) a), '[]'::jsonb));
end $$;

-- ================================================================ 3. the roles say manager
alter function app.my_roles(uuid) rename to my_roles_pre5302;
create function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.my_roles_pre5302(p_user) || jsonb_build_object('manager', coalesce(app.staff_is_manager(p_user), false),
           'team_size', case when app.staff_is_manager(p_user) then (select count(*) from staff_profiles sp where sp.manager_id = p_user) else 0 end)
$$;
select pg_temp.copy_grants('app.my_roles(uuid)', 'app.my_roles_pre5302(uuid)');

-- Admin > Settings > Staff: who manages, and whom
create function app.staff_teams_read(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'managers', coalesce((select jsonb_agg(jsonb_build_object('id', sp.user_id, 'name', app.staff_display_name(sp.user_id)) order by app.staff_display_name(sp.user_id))
                            from staff_profiles sp join users u on u.id = sp.user_id where sp.is_manager and u.status = 'active'), '[]'::jsonb),
    'people', coalesce((select jsonb_object_agg(sp.user_id::text, jsonb_build_object('is_manager', sp.is_manager, 'manager_id', sp.manager_id,
                                 'manager', case when sp.manager_id is not null then app.staff_display_name(sp.manager_id) end,
                                 'team', (select count(*) from staff_profiles t where t.manager_id = sp.user_id)))
                          from staff_profiles sp), '{}'::jsonb));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5302;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call in ('ops_read', 'field_read', 'va_read') and p_name in ('my_team', 'team_member'))
     or (p_call = 'admin_read' and p_name = 'staff_teams') or (p_call = 'admin_do' and p_name in ('staff_manager_set', 'staff_team_set')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'my_team' then app.my_team_read(p_user)
                       when 'team_member' then app.team_member_read(p_user, p_)
                       when 'staff_teams' then app.staff_teams_read(p_user)
                       when 'staff_manager_set' then app.staff_manager_set(p_user, p_)
                       else app.staff_team_set(p_user, p_) end;
  end if;
  return app.door_pre5302(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5302(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['staff_is_manager', 'manages', 'team_notify', 'staff_manager_set', 'staff_team_set', 'team_minutes', 'team_pay_owed',
                    'team_row', 'my_team_read', 'team_member_read', 'staff_teams_read', 'my_roles_pre5302', 'door_pre5302']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
