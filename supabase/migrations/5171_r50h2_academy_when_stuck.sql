-- 5171 (R50 hotfix 2, academy; docs/changes/2026-11-27-r50-hotfix2-academy.md): stuck on a page, take its academy section.
-- The owner (Nov 27): "If a staff member reports being stuck on a page too long, or hits repeated errors (stuck_help,
-- stuck_errors, client_errors), assign them that page's academy section and require it before continuing that area."
--   1. academy_assignments: one section a person must pass before they continue an area of the staff portal (the page's route
--      up to its first id, for example /staff/bookings; a portal home, /staff or /staff/field, is that page only). The section
--      is the page's own in the Stuck? help map (web/src/features/help/routes.ts), so the web sends it. Reasons: stuck_idle,
--      stuck_errors, stuck_loop (the Stuck? prompt shown, 0510) and client_errors (Program settings stuck_errors browser errors
--      on that area within 30 minutes, 0433). One open assignment a section; none again for 7 days after it was passed.
--   2. public.academy_assign_stuck(p_by, p {area, lesson: "path/section", reason}): the server's call (service role only) from
--      /api/help and /api/client-error. Staff members only: never an Admin, a test account, an exempt or waived person. The
--      person is told (alert academy_assigned, with the link).
--   3. A pass of the section closes it (trigger on academy_attempts). The assigned section opens to the person even when it is
--      not on their paths or not reached yet (academy_section, academy_section_id, the quiz submit, academy_may_watch).
--   4. app.my_roles adds academy_required [{area, path, section, title, href, reason, at}]: the staff portal sends a page of that
--      area to the section until it is passed. Admin > Academy shows them per person (academy_gate_state.required).
-- No applied migration is edited: my_roles and academy_gate_state are wrapped; the access checks (academy_section_pre1154, academy_section_id, academy_quiz_submit_pre1154, academy_may_watch) are patched in place.
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
  if position(p_old in d) = 0 then raise exception '5171: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the table
create table academy_assignments (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references users (id) on delete cascade,
  section_id   uuid not null references academy_sections (id) on delete cascade,
  path_code    text not null references academy_paths (code) on delete cascade,
  area         text not null check (area ~ '^/staff(/[a-z0-9_-]+)*$' and length(area) <= 200),
  reason       text not null check (reason in ('stuck_idle', 'stuck_errors', 'stuck_loop', 'client_errors')),
  created_at   timestamptz not null default now(),
  done_at      timestamptz,
  done_attempt uuid references academy_attempts (id) on delete set null
);
create unique index academy_assignments_open on academy_assignments (user_id, section_id) where done_at is null;
create index academy_assignments_user on academy_assignments (user_id, created_at desc);
create index academy_assignments_section on academy_assignments (section_id);
create index academy_assignments_path on academy_assignments (path_code);
create index academy_assignments_attempt on academy_assignments (done_attempt);
comment on table academy_assignments is 'A section a staff member must pass before they continue an area of the staff portal, given when they were stuck there (5171).';
alter table academy_assignments enable row level security;
create policy admin_all on academy_assignments to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on academy_assignments from anon, authenticated;
grant select, insert, update, delete on academy_assignments to service_role;
create trigger audit_academy_assignments after insert or update or delete on academy_assignments for each row execute function app.audit_row();

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort)
values ('academy_assigned', 'Academy section to pass: stuck on a page', 'Staff', '{assigned}', 'normal', 'alerts', true, true, false,
        'To the person: they were stuck on a page or hit repeated errors there, so its academy section is required before they continue that area (5171).', 119)
on conflict (rule) do nothing;

-- ================================================================ 2. giving one
create function app.academy_assigned(p_user uuid, p_section uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from academy_assignments a where a.user_id = p_user and a.section_id = p_section and a.done_at is null)
$$;

create function public.academy_assign_stuck(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_area text := nullif(btrim(coalesce(p ->> 'area', '')), '');
  v_reason text := p ->> 'reason';
  v_path text := split_part(coalesce(p ->> 'lesson', ''), '/', 1);
  v_sec academy_sections;
  v_id uuid;
  sp staff_profiles;
begin
  if p_by is null or not app.staff_is_member(p_by) or app.staff_is_test(p_by) then return jsonb_build_object('assigned', false, 'why', 'not staff'); end if;
  select * into sp from staff_profiles where user_id = p_by;
  if sp.onboarding_exempt or app.academy_waived(p_by) then return jsonb_build_object('assigned', false, 'why', 'exempt'); end if;
  if v_area is null or v_area !~ '^/staff(/[a-z0-9_-]+)*$' or length(v_area) > 200 then raise exception 'Not a staff area' using errcode = '22023'; end if;
  if v_reason is null or v_reason not in ('stuck_idle', 'stuck_errors', 'stuck_loop', 'client_errors') then raise exception 'Not a reason' using errcode = '22023'; end if;
  select s.* into v_sec from academy_sections s join academy_path_sections ps on ps.section_id = s.id and ps.path_code = v_path
   where s.slug = split_part(p ->> 'lesson', '/', 2);
  if v_sec.id is null then return jsonb_build_object('assigned', false, 'why', 'no section'); end if;
  -- repeated errors: the setting's count of browser errors on the area within 30 minutes
  if v_reason = 'client_errors' and (select count(*) from client_errors e where e.user_id = p_by and e.created_at > now() - interval '30 minutes'
        and (e.path = v_area or e.path like v_area || '/%')) < greatest(coalesce((app.settings()).stuck_errors, 3), 2) then
    return jsonb_build_object('assigned', false, 'why', 'not repeated');
  end if;
  if app.academy_assigned(p_by, v_sec.id) then return jsonb_build_object('assigned', false, 'why', 'open'); end if;
  if exists (select 1 from academy_assignments a where a.user_id = p_by and a.section_id = v_sec.id and a.done_at > now() - interval '7 days') then
    return jsonb_build_object('assigned', false, 'why', 'recent');
  end if;
  insert into academy_assignments (user_id, section_id, path_code, area, reason) values (p_by, v_sec.id, v_path, v_area, v_reason)
  on conflict do nothing returning id into v_id;
  if v_id is null then return jsonb_build_object('assigned', false, 'why', 'open'); end if;
  perform app.staff_alert('academy_assigned', 'academy_assignment', v_id, 'new', 'Pass "' || v_sec.title || '" to continue',
    format('You were stuck on %s. Pass the academy section "%s" (its lessons and quiz) and that part of the portal opens again.', v_area, v_sec.title),
    jsonb_build_object('assigned_to', p_by, 'path_staff', '/staff/academy/' || v_path || '/' || v_sec.slug));
  return jsonb_build_object('assigned', true, 'id', v_id, 'href', '/staff/academy/' || v_path || '/' || v_sec.slug);
end $$;
-- the notice opens the section (path_staff in the notice), a list kind, not one record's page (99_r48_alert_targets)
alter function app.alert_entity_kind(text) rename to alert_entity_kind_pre5171;
create function app.alert_entity_kind(p_entity text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_entity = 'academy_assignment' then 'list' else app.alert_entity_kind_pre5171(p_entity) end
$$;
select pg_temp.copy_grants('app.alert_entity_kind(text)', 'app.alert_entity_kind_pre5171(text)');
revoke all on function public.academy_assign_stuck(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.academy_assign_stuck(uuid, jsonb) to service_role;

-- ================================================================ 3. passing it, and opening it
create function app.academy_assignment_pass() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.passed then
    update academy_assignments set done_at = now(), done_attempt = new.id
     where user_id = new.user_id and section_id = new.section_id and done_at is null;
  end if;
  return new;
end $$;
revoke all on function app.academy_assignment_pass() from public, anon, authenticated;
grant execute on function app.academy_assignment_pass() to service_role;
create trigger academy_assignment_pass after insert on academy_attempts for each row execute function app.academy_assignment_pass();

select pg_temp.patch_fn('app.academy_section_pre1154(uuid,jsonb)'::regprocedure,
  'if not (v_path = any (app.academy_paths_of(p_user)) or app.user_is_admin(p_user)) then',
  'if not (v_path = any (app.academy_paths_of(p_user)) or app.user_is_admin(p_user) or app.academy_assigned(p_user, v_sec.id)) then');
select pg_temp.patch_fn('app.academy_section_pre1154(uuid,jsonb)'::regprocedure,
  'if not app.user_is_admin(p_user) and not app.academy_open(p_user, v_path, v_sec.id) then',
  'if not app.user_is_admin(p_user) and not app.academy_assigned(p_user, v_sec.id) and not app.academy_open(p_user, v_path, v_sec.id) then');
select pg_temp.patch_fn('app.academy_quiz_submit_pre1154(uuid,jsonb)'::regprocedure,
  'if not app.user_is_admin(p_user) and not exists',
  'if not app.user_is_admin(p_user) and not app.academy_assigned(p_user, v_sec) and not exists');
select pg_temp.patch_fn('app.academy_section_id(uuid,jsonb)'::regprocedure,
  'if not app.user_is_admin(p_user) and not exists',
  'if not app.user_is_admin(p_user) and not app.academy_assigned(p_user, v_sec) and not exists');
select pg_temp.patch_fn('app.academy_may_watch(uuid,uuid)'::regprocedure,
  'select app.user_is_admin(p_user) or exists',
  'select app.user_is_admin(p_user) or exists (select 1 from academy_lessons l where l.id = p_lesson and app.academy_assigned(p_user, l.section_id)) or exists');

-- ================================================================ 4. what the portal reads
create function app.academy_required(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'area', a.area, 'path', a.path_code, 'section', s.slug, 'title', s.title,
           'href', '/staff/academy/' || a.path_code || '/' || s.slug, 'reason', a.reason, 'at', a.created_at) order by a.created_at), '[]'::jsonb)
    from academy_assignments a join academy_sections s on s.id = a.section_id
   where a.user_id = p_user and a.done_at is null
     and not app.academy_waived(p_user)
     and not exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.onboarding_exempt)
$$;

alter function app.my_roles(uuid) rename to my_roles_pre5171;
create function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.my_roles_pre5171(p_user) || jsonb_build_object('academy_required', case when p_user is null then '[]'::jsonb else app.academy_required(p_user) end)
$$;
select pg_temp.copy_grants('app.my_roles(uuid)', 'app.my_roles_pre5171(uuid)');

alter function app.academy_gate_state(uuid) rename to academy_gate_state_pre5171;
create function app.academy_gate_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.academy_gate_state_pre5171(p_user) || jsonb_build_object('required', app.academy_required(p_user))
$$;
select pg_temp.copy_grants('app.academy_gate_state(uuid)', 'app.academy_gate_state_pre5171(uuid)');

alter function app.academy_home(uuid) rename to academy_home_pre5171;
create function app.academy_home(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.academy_home_pre5171(p_user) || jsonb_build_object('required', app.academy_required(p_user))
$$;
select pg_temp.copy_grants('app.academy_home(uuid)', 'app.academy_home_pre5171(uuid)');

revoke all on function app.academy_assigned(uuid, uuid) from public, anon, authenticated;
grant execute on function app.academy_assigned(uuid, uuid) to service_role;
revoke all on function app.academy_required(uuid) from public, anon, authenticated;
grant execute on function app.academy_required(uuid) to service_role;
