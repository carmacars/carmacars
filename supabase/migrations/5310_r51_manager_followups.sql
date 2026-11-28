-- 5310 (R51 staff, REQ-138; docs/changes/2026-11-27-r51-staff.md): managers follow up on their staff, and pass a Manager
-- section of the academy. The owner (Nov 27 19:45): "Managers should be following up on their assigned staff and what not
-- and get academy shit for it".
--   1. team_followups: a manager's To dos for their own team, made by the hourly job app.job_team_followups:
--      academy   a member who has not passed their whole academy and did nothing in it for 2 days (no lesson, start or try);
--      onboarding a member whose onboarding is not done (the steps still open, from app.staff_onboarding_state);
--      missed_shift a field shift they booked that ended in the last 7 days with no shift clocked in it;
--      missed_job a field job of theirs scheduled in the last 7 days (2 hours past) still not started;
--      kpi       a KPI of their role below target in the last full week.
--      One open follow-up a member and kind (a missed shift or job: one each); due in 2 days. The manager hears of new ones
--      (alert team_followup, once a run). A follow-up still open after its due time is escalated to the Admins once
--      (alert team_followup_overdue).
--   2. On My team (ops_read my_team: followups), each has Call and Text (the member's own mobile, as an Admin sees it) and
--      Mark followed up with a note (ops_do team_followup_done). Only the member's manager acts on it.
--   3. A weekly team summary to each manager (alert team_weekly, Monday morning, app.job_team_weekly).
--   4. The Manager path of the academy (academy_paths 'manager', section manager-follow-up: how to follow up, coach,
--      escalate and approve hours). Every manager has it on their path (app.academy_paths_of), wired like the other role
--      sections, with 7 days before it holds them (an enrollment with lock_from, as for new sections, 2990). Until it is
--      passed, My team's follow-ups stay closed (the list waits; the job still makes them).
-- No applied migration is edited: academy_paths_of, my_team_read, staff_manager_set and the door are wrapped (_pre5310).
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

-- ================================================================ 4. the Manager path
insert into academy_paths (code, title, blurb, sort, core_count) values
  ('manager', 'Managers', 'Following up on the staff assigned to you: what to look at, how to coach, when to escalate, and approving hours.', 9, 0)
on conflict (code) do update set title = excluded.title, blurb = excluded.blurb;
insert into academy_sections (slug, title, blurb, guide_refs) values ('manager-follow-up', 'Managing your team: follow up, coach, escalate, approve hours',
  'Your team''s follow-ups on My team, a short coaching call, when to hand it to an Admin, and checking hours before they are paid.', array['va/my-team']::text[])
on conflict (slug) do update set title = excluded.title, blurb = excluded.blurb, guide_refs = excluded.guide_refs, updated_at = now();
insert into academy_path_sections (path_code, section_id, sort) select 'manager', id, 1 from academy_sections where slug = 'manager-follow-up' on conflict do nothing;
insert into academy_lessons (section_id, sort, title, scenes) values
 ((select id from academy_sections where slug = 'manager-follow-up'), 1, 'Your follow-ups',
  '[{"caption":"My team lists what needs you","say":"My team shows a follow-up when someone on your team is stuck in the academy for two days, has onboarding steps open, missed a shift or a job, or was below a KPI target last week.","visual":{"kind":"list","heading":"A follow-up comes when","items":["Academy: nothing done for 2 days","Onboarding steps still open","A missed shift or field job","A KPI below target last week"]}},{"caption":"One tap each","say":"Call or text the person from the follow-up. Then press Mark followed up and write what you agreed. Each one is due in two days.","visual":{"kind":"steps","heading":"Close it","items":["Call or Text from the follow-up","Agree the next step and a time","Mark followed up, with the note"]}}]'::jsonb),
 ((select id from academy_sections where slug = 'manager-follow-up'), 2, 'Coach, then escalate',
  '[{"caption":"Coach first","say":"Ask what blocked them, show the guide chapter or the academy lesson, and agree one next step with a time. Keep it short and kind.","visual":{"kind":"dodont","heading":"A coaching call","alt":"Do and do not pairs for a coaching call","pairs":[{"do":"Ask what blocked them","dont":"Read out their numbers"},{"do":"Agree one next step and a time","dont":"Give a list of ten things"},{"do":"Point to the guide chapter","dont":"Do the work for them"}]}},{"caption":"When to escalate","say":"A follow-up still open after its due time goes to the Admins by itself. Hand it to an Admin yourself for money, a safety problem, a renter complaint, or the same miss twice.","visual":{"kind":"rule","heading":"Escalate to an Admin","text":"Money, safety, a renter complaint, or the same miss twice. Overdue follow-ups go to the Admins by themselves.","tone":"warn"}}]'::jsonb),
 ((select id from academy_sections where slug = 'manager-follow-up'), 3, 'Approving hours',
  '[{"caption":"Check hours before pay","say":"On My team, open the person: their hours of the last 14 days show each clock-in and field shift. Check that each shift matches the work done. Finance pays the hours; tell Finance or an Admin about anything wrong before the pay run.","visual":{"kind":"steps","heading":"Hours","items":["Open the person on My team","Check each shift against the jobs","Anything wrong: tell Finance before the pay run"]}}]'::jsonb)
on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values
 ((select id from academy_sections where slug = 'manager-follow-up'), 1, 'Someone on your team did nothing in the academy for 2 days. What do you do first?',
  '["Wait a week","Call or text them from the follow-up and agree one next step","Reset their academy","Tell the whole team"]'::jsonb, 1, 'Reach them from the follow-up and agree one next step with a time.'),
 ((select id from academy_sections where slug = 'manager-follow-up'), 2, 'How do you close a follow-up?',
  '["Ignore it until it goes away","Mark followed up, with a note of what you agreed","Delete the person from your team","Ask the person to close it"]'::jsonb, 1, 'Mark followed up and write what you agreed.'),
 ((select id from academy_sections where slug = 'manager-follow-up'), 3, 'What happens to a follow-up still open after its due time?',
  '["Nothing","It goes to the Admins by itself","It closes by itself","It is sent to the renter"]'::jsonb, 1, 'Overdue follow-ups are escalated to the Admins.'),
 ((select id from academy_sections where slug = 'manager-follow-up'), 4, 'When do you hand a problem to an Admin yourself?',
  '["Never","Money, safety, a renter complaint, or the same miss twice","Only on weekends","Whenever a KPI moves"]'::jsonb, 1, 'Escalate money, safety, a renter complaint or a repeated miss.'),
 ((select id from academy_sections where slug = 'manager-follow-up'), 5, 'A field shift on the hours list looks wrong. What do you do?',
  '["Change it yourself","Tell Finance or an Admin before the pay run","Pay it anyway","Delete it"]'::jsonb, 1, 'My team is read only: Finance or an Admin corrects hours before the pay run.')
on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();

alter function app.academy_paths_of(uuid) rename to academy_paths_of_pre5310;
create function app.academy_paths_of(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when app.staff_is_manager(p_user) then (select array_agg(distinct p order by p) from unnest(coalesce(app.academy_paths_of_pre5310(p_user), '{}') || array['manager']) p)
              else app.academy_paths_of_pre5310(p_user) end
$$;
select pg_temp.copy_grants('app.academy_paths_of(uuid)', 'app.academy_paths_of_pre5310(uuid)');

-- the Manager section passed (a real pass: never counted as passed for another reason)
create function app.manager_section_passed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from academy_attempts a join academy_sections s on s.id = a.section_id
                  where a.user_id = p_user and s.slug = 'manager-follow-up' and a.passed and not a.voided)
$$;

-- marked a manager: enrolled on the Manager path, 7 days before it holds them (as new sections for staff already working)
alter function app.staff_manager_set(uuid, jsonb) rename to staff_manager_set_pre5310;
create function app.staff_manager_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r jsonb := app.staff_manager_set_pre5310(p_by, p);
begin
  if coalesce((r ->> 'manager')::boolean, false) then
    insert into academy_enrollments (user_id, path_code, gate, lock_from, source, enrolled_by)
    values (nullif(p ->> 'user_id', '')::uuid, 'manager', true, now() + interval '7 days', 'admin', p_by)
    on conflict (user_id, path_code) do nothing;
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.staff_manager_set(uuid, jsonb)', 'app.staff_manager_set_pre5310(uuid, jsonb)');

-- ================================================================ 1. the follow-ups
create table team_followups (
  id           uuid primary key default gen_random_uuid(),
  manager_id   uuid not null references users (id) on delete cascade,
  member_id    uuid not null references users (id) on delete cascade,
  kind         text not null check (kind in ('academy', 'onboarding', 'missed_shift', 'missed_job', 'kpi')),
  detail       text not null,
  ref_id       uuid,
  dedupe_key   text not null unique,
  due_at       timestamptz not null default now() + interval '2 days',
  status       text not null default 'open' check (status in ('open', 'done')),
  note         text check (note is null or length(note) between 1 and 500),
  done_at      timestamptz,
  done_by      uuid references users (id),
  escalated_at timestamptz,
  created_at   timestamptz not null default now(),
  check ((status = 'done') = (done_at is not null and note is not null))
);
create index team_followups_manager_idx on team_followups (manager_id, status);
create index team_followups_member_idx on team_followups (member_id);
comment on table team_followups is 'Managers (5310, REQ-138): a manager''s To dos for their own team (academy stalled, onboarding open, a missed shift or job, a KPI below target), closed with a note.';
alter table team_followups enable row level security;
create policy admin_all on team_followups for select to authenticated using (app.is_admin());
revoke all on team_followups from anon, authenticated;
grant select on team_followups to authenticated;
grant select, insert, update, delete on team_followups to service_role;
create trigger audit_team_followups after insert or update or delete on team_followups for each row execute function app.audit_row();

-- the last time a member did anything in the academy
create function app.academy_last_activity(p_user uuid) returns timestamptz
language sql stable security definer set search_path = public, app, pg_temp as $$
  select greatest((select max(created_at) from academy_attempts where user_id = p_user), (select max(viewed_at) from academy_lesson_views where user_id = p_user),
                  (select max(started_at) from academy_quiz_starts where user_id = p_user))
$$;

-- the follow-ups one member needs now: [{kind, detail, ref, key}]
create function app.team_followups_due(p_member uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  c jsonb := app.academy_counts(p_member);
  st jsonb := app.staff_onboarding_state(p_member);
  v_week text := to_char(p_now at time zone 'America/Toronto', 'IYYY-IW');
  out jsonb := '[]'::jsonb;
  k jsonb;
  r record;
begin
  -- the academy: not all passed, nothing done for 2 days (and on the team for 2 days)
  if (c ->> 'passed')::int < (c ->> 'total')::int
     and coalesce(app.academy_last_activity(p_member), (select created_at from users where id = p_member)) < p_now - interval '2 days' then
    out := out || jsonb_build_object('kind', 'academy', 'key', 'academy:' || p_member || ':' || v_week,
      'detail', format('Academy: %s of %s sections passed, nothing done for %s days.', c ->> 'passed', c ->> 'total',
        floor(extract(epoch from p_now - coalesce(app.academy_last_activity(p_member), (select created_at from users where id = p_member))) / 86400)));
  end if;
  -- onboarding steps still open
  if coalesce((st ->> 'member')::boolean, false) and not coalesce((st ->> 'done')::boolean, false) and not coalesce((st ->> 'exempt')::boolean, false) then
    out := out || jsonb_build_object('kind', 'onboarding', 'key', 'onboarding:' || p_member || ':' || v_week,
      'detail', 'Onboarding open: ' || coalesce(nullif(array_to_string(array(select jsonb_array_elements_text(coalesce(st -> 'waiting_on', '[]'::jsonb))), '; '), ''), st ->> 'step') || '.');
  end if;
  -- a booked field shift that ended with no shift clocked in it (the last 7 days)
  for r in select p.id, p.starts_at, p.ends_at from field_shift_plans p
            where p.staff_id = p_member and p.cancelled_at is null and p.ends_at between p_now - interval '7 days' and p_now
              and not exists (select 1 from field_shifts f where f.staff_id = p_member and f.voided_at is null
                               and f.started_at < p.ends_at and coalesce(f.ended_at, p_now) > p.starts_at) loop
    out := out || jsonb_build_object('kind', 'missed_shift', 'key', 'missed_shift:' || r.id, 'ref', r.id,
      'detail', 'Missed shift: ' || to_char(r.starts_at at time zone 'America/Toronto', 'Dy Mon FMDD, FMHH12:MI am') || ', no shift clocked.');
  end loop;
  -- a field job of theirs scheduled in the last 7 days, 2 hours past and not started
  for r in select j.id, j.kind, j.scheduled_at from field_jobs j
            where j.assigned_to = p_member and j.status in ('scheduled', 'acknowledged') and j.scheduled_at between p_now - interval '7 days' and p_now - interval '2 hours' loop
    out := out || jsonb_build_object('kind', 'missed_job', 'key', 'missed_job:' || r.id, 'ref', r.id,
      'detail', format('Missed field job: %s, %s, not started.', replace(r.kind, '_', ' '), to_char(r.scheduled_at at time zone 'America/Toronto', 'Dy Mon FMDD, FMHH12:MI am')));
  end loop;
  -- KPIs below target in the last full week
  begin
    select x into k from jsonb_array_elements(coalesce(app.role_kpi_weeks(p_member, 2), '[]'::jsonb)) x
     where (x ->> 'week_start')::date < date_trunc('week', p_now at time zone 'America/Toronto')::date order by x ->> 'week_start' desc limit 1;
    if k is not null and exists (select 1 from jsonb_array_elements(k -> 'items') i where (i ->> 'met') = 'false') then
      out := out || jsonb_build_object('kind', 'kpi', 'key', 'kpi:' || p_member || ':' || (k ->> 'week_start'),
        'detail', 'Below target last week: ' || (select string_agg(i ->> 'label' || ' ' || coalesce(i ->> 'value', '0') || ' of ' || coalesce(i ->> 'target', '?'), '; ')
                                                  from jsonb_array_elements(k -> 'items') i where (i ->> 'met') = 'false') || '.');
    end if;
  exception when others then null;  -- a role with no KPIs
  end;
  return out;
end $$;

-- the hourly job: new follow-ups (the manager told once a run), overdue ones to the Admins once
create function app.job_team_followups(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  m record;
  t record;
  d jsonb;
  v_new integer;
  v_made integer := 0;
  v_late integer := 0;
  f record;
begin
  for m in select sp.user_id from staff_profiles sp where app.staff_is_manager(sp.user_id) loop
    v_new := 0;
    for t in select sp.user_id from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active' where sp.manager_id = m.user_id loop
      for d in select x from jsonb_array_elements(app.team_followups_due(t.user_id, p_now)) x loop
        -- one a member and kind and week (a missed shift or job: one each)
        insert into team_followups (manager_id, member_id, kind, detail, ref_id, dedupe_key, due_at)
        values (m.user_id, t.user_id, d ->> 'kind', d ->> 'detail', nullif(d ->> 'ref', '')::uuid, d ->> 'key', p_now + interval '2 days')
        on conflict (dedupe_key) do nothing;
        if found then v_new := v_new + 1; end if;
      end loop;
    end loop;
    if v_new > 0 then
      v_made := v_made + v_new;
      perform app.staff_alert('team_followup', 'user', m.user_id, 'new:' || to_char(p_now, 'YYYYMMDDHH24'),
        format('%s new follow-up%s on your team', v_new, case when v_new = 1 then '' else 's' end),
        'Open My team: call or text, then mark each followed up with a note.',
        jsonb_build_object('assigned_to', m.user_id, 'path_staff', '/staff/team', 'path_admin', '/admin/settings/staff'));
    end if;
  end loop;
  for f in select x.*, app.staff_display_name(x.manager_id) mname, app.staff_display_name(x.member_id) wname from team_followups x
            where x.status = 'open' and x.due_at < p_now and x.escalated_at is null loop
    update team_followups set escalated_at = p_now where id = f.id;
    v_late := v_late + 1;
    perform app.staff_alert('team_followup_overdue', 'user', f.member_id, 'overdue:' || f.id,
      format('Follow-up overdue: %s (manager %s)', f.wname, f.mname), f.detail, jsonb_build_object('path_admin', '/admin/settings/staff'));
  end loop;
  return jsonb_build_object('made', v_made, 'escalated', v_late);
end $$;

-- the weekly summary to each manager
create function app.job_team_weekly(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  m record;
  n integer := 0;
begin
  for m in select sp.user_id from staff_profiles sp where app.staff_is_manager(sp.user_id) and exists (select 1 from staff_profiles t where t.manager_id = sp.user_id) loop
    perform app.staff_alert('team_weekly', 'user', m.user_id, 'week:' || to_char(p_now at time zone 'America/Toronto', 'IYYY-IW'),
      'Your team this week',
      (select format('%s people. Hours last 7 days: %s h. Academy all passed: %s of %s. Follow-ups open: %s (overdue %s), closed this week: %s.',
                     count(*), round(sum(app.team_minutes(t.user_id, p_now - interval '7 days')) / 60.0, 1),
                     count(*) filter (where (app.academy_counts(t.user_id) ->> 'passed') = (app.academy_counts(t.user_id) ->> 'total')), count(*),
                     (select count(*) from team_followups f where f.manager_id = m.user_id and f.status = 'open'),
                     (select count(*) from team_followups f where f.manager_id = m.user_id and f.status = 'open' and f.due_at < p_now),
                     (select count(*) from team_followups f where f.manager_id = m.user_id and f.status = 'done' and f.done_at > p_now - interval '7 days'))
         from staff_profiles t join users u on u.id = t.user_id and u.status = 'active' where t.manager_id = m.user_id),
      jsonb_build_object('assigned_to', m.user_id, 'path_staff', '/staff/team', 'path_admin', '/admin/settings/staff'));
    n := n + 1;
  end loop;
  return n;
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, hint, sort) values
  ('team_followup', 'New follow-ups on your team', 'Staff', '{assigned}', 'normal', 'alerts', true, true, 'A manager''s team needs a follow-up: academy, onboarding, a missed shift or job, a KPI.', 131),
  ('team_followup_overdue', 'A manager''s follow-up is overdue', 'Staff', '{admin}', 'normal', 'alerts', true, true, 'A follow-up still open after its due time (2 days).', 132),
  ('team_weekly', 'Your team this week (managers)', 'Staff', '{assigned}', 'digest', 'alerts', true, true, 'The weekly team summary for each manager.', 133)
on conflict (rule) do nothing;

-- ================================================================ 2. My team: the follow-ups and closing one
alter function app.my_team_read(uuid) rename to my_team_read_pre5310;
create function app.my_team_read(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.my_team_read_pre5310(p_user);
  v_passed boolean := app.manager_section_passed(p_user);
begin
  return v || jsonb_build_object('manager_passed', v_passed,
    'manager_section', '/staff/academy/manager/manager-follow-up',
    'followups', case when not v_passed then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'member_id', f.member_id, 'name', app.staff_display_name(f.member_id),
                    'phone', u.phone, 'kind', f.kind, 'detail', f.detail, 'due_at', f.due_at, 'overdue', f.due_at < now(), 'created_at', f.created_at) order by f.due_at)
                   from team_followups f join users u on u.id = f.member_id where f.manager_id = p_user and f.status = 'open'), '[]'::jsonb) end,
    'followups_waiting', (select count(*) from team_followups f where f.manager_id = p_user and f.status = 'open'));
end $$;
select pg_temp.copy_grants('app.my_team_read(uuid)', 'app.my_team_read_pre5310(uuid)');

create function app.team_followup_done(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  f team_followups;
  v_note text := left(nullif(btrim(coalesce(p ->> 'note', '')), ''), 500);
begin
  select * into f from team_followups where id = nullif(p ->> 'id', '')::uuid for update;
  if f.id is null or f.manager_id <> p_user then raise exception 'Not one of your follow-ups' using errcode = '42501'; end if;
  if not app.manager_section_passed(p_user) then raise exception 'Pass the Manager section of the academy first' using errcode = '55000'; end if;
  if f.status = 'done' then return jsonb_build_object('ok', true, 'repeat', true); end if;
  if v_note is null then raise exception 'Write what you agreed' using errcode = '22023'; end if;
  update team_followups set status = 'done', note = v_note, done_at = now(), done_by = p_user where id = f.id;
  return jsonb_build_object('ok', true);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5310;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('ops_do', 'field_do', 'va_do') and p_name = 'team_followup_done' then
    perform app.door_begin(p_user, p_aal);
    return app.team_followup_done(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre5310(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5310(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ the jobs (pg_cron where it exists)
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: the team follow-up jobs are not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): the team follow-up jobs are not scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-r51-team-followups', '23 * * * *', $q$select app.job_team_followups()$q$);
  -- Monday 8:41 Toronto (13:41 UTC in winter)
  perform cron.schedule('carmacars-r51-team-weekly', '41 13 * * 1', $q$select app.job_team_weekly()$q$);
end $$;

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['academy_paths_of_pre5310', 'manager_section_passed', 'staff_manager_set_pre5310', 'academy_last_activity',
                    'team_followups_due', 'job_team_followups', 'job_team_weekly', 'my_team_read_pre5310', 'team_followup_done', 'door_pre5310']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
