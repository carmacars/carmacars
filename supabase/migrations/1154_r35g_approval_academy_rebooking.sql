-- 1154_r35g_approval_academy_rebooking.sql
-- Release 35, part G (helper G), the owner's follow-ups to 1151 and 1152.
--   1. Onboarding step 4, approved. Once a staff member has confirmed the WhatsApp groups (step 3), the Admins and every Fleet
--      VA get an alert and a Fleet To do "Approve <name>'s onboarding". Only after an Admin or a Fleet VA approves (never
--      themselves) is app.staff_fully_onboarded true. Everyone with staff-portal access, existing staff included (no grace,
--      as 1151): the staff who were onboarded before this release wait at this step, with the same alert and To do, and an
--      Admin may approve everyone waiting in one press. Test and verify accounts and exempt people stay exempt. Reject (with
--      a reason) keeps the person held and shows the reason on Welcome, where they ask again. Taking the WhatsApp
--      confirmation back also takes the approval back. Admin: Settings > Staff onboarding; Fleet: the Field jobs page.
--   2. The academy, harder to game: the pass mark is 90% (academy_pass_bps); the quiz is handed out by academy_quiz_start
--      in a random order of questions and of options (the questions are no longer in the section read); a minimum reading
--      time per section before its quiz opens (its words at academy_read_wpm, counted from the first time the person
--      opened the section); after a failed attempt, academy_fail_cooldown_minutes (30) before the next one of that quiz; at
--      most academy_attempts_per_day (3) attempts of a quiz a Toronto day; a failed attempt no longer shows the right
--      answers; an attempt answered in under academy_rapid_seconds (3) a question is flagged to the Admins (alert
--      academy_rapid). An Admin resets chosen sections for a person (academy_reset: their passes, views and reading clock
--      on those sections start over; the attempts stay on record). The academy link is in the menu in every state.
--   3. Rebooking: a returning renter's new lead is claimed at once for the salesperson credited on their last booking
--      (bookings.sales_staff_id, the last confirmed or later booking), when that person is fully onboarded and in Sales,
--      with the normal claim window and its release rules (it expires back to the list like any claim). Not paced or capped
--      (it is not the person's own claim), logged as a claim with the note "Rebooking".
-- No applied migration is edited: staff_onboarding_state, staff_welcome, academy_section, academy_quiz_submit and the door
-- are wrapped or replaced; academy_passed and academy_path_progress are replaced (same signatures and grants).
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

-- ================================================================ settings and columns
alter table program_settings
  add column if not exists academy_read_wpm integer not null default 200 check (academy_read_wpm between 0 and 1000),
  add column if not exists academy_fail_cooldown_minutes integer not null default 30 check (academy_fail_cooldown_minutes between 0 and 1440),
  add column if not exists academy_attempts_per_day integer not null default 3 check (academy_attempts_per_day between 1 and 1000),
  add column if not exists academy_rapid_seconds integer not null default 3 check (academy_rapid_seconds between 0 and 60);
alter table program_settings alter column academy_pass_bps set default 9000;
update program_settings set academy_pass_bps = 9000 where academy_pass_bps < 9000;
comment on column program_settings.academy_read_wpm is 'Academy (1154): the reading speed (words a minute) that sets each section''s minimum reading time before its quiz opens; 0 for none.';
comment on column program_settings.academy_fail_cooldown_minutes is 'Academy (1154): minutes after a failed attempt before the same quiz can be taken again.';
comment on column program_settings.academy_attempts_per_day is 'Academy (1154): the most attempts of one quiz a person may make in a Toronto day.';
comment on column program_settings.academy_rapid_seconds is 'Academy (1154): an attempt answered in under this many seconds a question is flagged to the Admins; 0 for off.';

alter table staff_profiles
  add column if not exists onboarding_approved_at timestamptz,
  add column if not exists onboarding_approved_by uuid references users (id),
  add column if not exists onboarding_asked_at timestamptz,
  add column if not exists onboarding_rejected_at timestamptz,
  add column if not exists onboarding_rejected_by uuid references users (id),
  add column if not exists onboarding_reject_reason text check (length(onboarding_reject_reason) <= 300);
comment on column staff_profiles.onboarding_approved_at is 'Onboarding step 4 (1154): approved by an Admin or a Fleet VA after the WhatsApp groups were confirmed. Taken back with the WhatsApp confirmation.';

alter table academy_attempts add column if not exists flagged boolean not null default false,
                             add column if not exists seconds integer;
comment on column academy_attempts.flagged is 'Answered in under academy_rapid_seconds a question (1154); the Admins were alerted.';

create table if not exists academy_section_opens (
  user_id    uuid not null references users (id) on delete cascade,
  section_id uuid not null references academy_sections (id) on delete cascade,
  opened_at  timestamptz not null default now(),
  primary key (user_id, section_id)
);
comment on table academy_section_opens is 'Academy (1154): when a person first opened a section; its reading time counts from here.';
create table if not exists academy_quiz_starts (
  user_id    uuid not null references users (id) on delete cascade,
  section_id uuid not null references academy_sections (id) on delete cascade,
  started_at timestamptz not null default now(),
  primary key (user_id, section_id)
);
comment on table academy_quiz_starts is 'Academy (1154): the quiz handed out (academy_quiz_start) and not yet submitted; the attempt''s time counts from here.';
create table if not exists academy_resets (
  user_id    uuid not null references users (id) on delete cascade,
  section_id uuid not null references academy_sections (id) on delete cascade,
  reset_at   timestamptz not null default now(),
  reset_by   uuid not null references users (id),
  primary key (user_id, section_id)
);
comment on table academy_resets is 'Academy (1154): a section an Admin reset for a person; their attempts before reset_at no longer count (they stay on record).';
revoke all on academy_section_opens, academy_quiz_starts, academy_resets from anon, authenticated;
grant all on academy_section_opens, academy_quiz_starts, academy_resets to service_role;
alter table academy_section_opens enable row level security;
alter table academy_quiz_starts enable row level security;
alter table academy_resets enable row level security;
-- the house rule: every table has the admin policy (no grant to authenticated: the server reads and writes them)
create policy admin_all on academy_section_opens for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on academy_quiz_starts for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on academy_resets for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_academy_section_opens after insert or update or delete on academy_section_opens for each row execute function app.audit_row();
create trigger audit_academy_quiz_starts after insert or update or delete on academy_quiz_starts for each row execute function app.audit_row();
create trigger audit_academy_resets after insert or update or delete on academy_resets for each row execute function app.audit_row();

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('staff_onboarding_approve', 'A staff member waits for onboarding approval', 'Staff', '{admin,fn:fleet}', 'urgent', 'alerts', true, false,
   'Sent when a staff member confirms the WhatsApp groups (1154). An Admin or a Fleet VA approves on Settings > Staff onboarding or the Field jobs page.', 165),
  ('academy_rapid', 'Academy quiz answered too fast', 'Staff', '{admin}', 'normal', 'alerts', true, false,
   'An attempt answered in under the seconds a question of Program settings (1154).', 166)
on conflict (rule) do nothing;

-- ================================================================ 1. step 4: approved
alter function app.staff_onboarding_state(uuid) rename to staff_onboarding_state_pre1154;
create function app.staff_onboarding_state(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_onboarding_state_pre1154(p_user);
  sp staff_profiles;
  v_ok boolean;
begin
  if not coalesce((v ->> 'member')::boolean, false) then return v; end if;
  select * into sp from staff_profiles where user_id = p_user;
  v_ok := sp.onboarding_approved_at is not null;
  return v || jsonb_build_object('approved', v_ok, 'approved_at', sp.onboarding_approved_at,
    'approved_by', (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) from users u where u.id = sp.onboarding_approved_by),
    'asked_at', sp.onboarding_asked_at, 'rejected_at', sp.onboarding_rejected_at, 'reject_reason', sp.onboarding_reject_reason,
    'step', case when v ->> 'step' <> 'done' then v ->> 'step' when not v_ok then 'approval' else 'done' end,
    'done', coalesce((v ->> 'done')::boolean, false) and v_ok);
end $$;
select pg_temp.copy_grants('app.staff_onboarding_state(uuid)'::regprocedure, 'app.staff_onboarding_state_pre1154(uuid)'::regprocedure);

create function app.staff_display_name(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) from users u where u.id = p_user
$$;

-- may this person approve onboarding: an Admin, or a fully onboarded Fleet VA
create function app.staff_may_approve(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_by is not null and not app.staff_is_test(p_by)
     and (app.user_is_admin(p_by) or (app.user_va_has(p_by, 'fleet') and app.staff_fully_onboarded(p_by)))
$$;

-- the request: the alert to the Admins and every Fleet VA, and one open Fleet To do
create function app.staff_onboarding_ask(p_user uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v_name text := app.staff_display_name(p_user);
  sp staff_profiles;
begin
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null or sp.onboarding_approved_at is not null or sp.onboarding_exempt or app.staff_is_test(p_user) or not app.staff_is_member(p_user) then return false; end if;
  update staff_profiles set onboarding_asked_at = now(), onboarding_rejected_at = null, onboarding_rejected_by = null, onboarding_reject_reason = null where user_id = p_user;
  if not exists (select 1 from tasks t where t.task_type = 'approve_onboarding' and t.related_id = p_user and t.status in ('open', 'in_progress', 'waiting')) then
    insert into tasks (queue, task_type, title, detail, priority, related_table, related_id)
    values ('fleet', 'approve_onboarding', format('Approve %s''s onboarding', v_name),
            'They passed the academy, signed the agreement and joined the WhatsApp groups. Approve or reject on the Field jobs page (Admins: Settings > Staff onboarding).',
            'high', 'staff_profiles', p_user);
  end if;
  begin
    perform app.staff_alert('staff_onboarding_approve', 'staff', p_user, 'ask:' || floor(extract(epoch from now()))::bigint,
      format('Approve %s''s onboarding', v_name), 'Academy passed, agreement signed, WhatsApp groups joined. Approve or reject.',
      jsonb_build_object('path_admin', '/admin/settings/staff', 'path_staff', '/staff/fleet#onboarding-approvals'));
  exception when others then
    raise warning 'onboarding approval alert not made for %: %', p_user, sqlerrm;
  end;
  return true;
end $$;

create function app.staff_onboarding_close_task(p_user uuid, p_status text, p_by uuid default null) returns void
language sql security definer set search_path = public, app as $$
  update tasks set status = p_status, updated_at = now(), completed_at = case when p_status = 'done' then now() end where task_type = 'approve_onboarding' and related_id = p_user and status in ('open', 'in_progress', 'waiting')
$$;

-- WhatsApp taken back (or no longer complete): the approval goes with it
create function app.staff_approval_whatsapp_before() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.staff_required_groups(new.functions) <@ new.whatsapp_joined) then
    new.onboarding_approved_at := null; new.onboarding_approved_by := null; new.onboarding_asked_at := null;
  end if;
  return new;
end $$;
drop trigger if exists staff_profiles_approval_whatsapp on staff_profiles;
create trigger staff_profiles_approval_whatsapp before update of whatsapp_joined, functions on staff_profiles
  for each row execute function app.staff_approval_whatsapp_before();

-- WhatsApp newly complete, not approved: ask for approval
create function app.staff_approval_ask_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_req text[] := app.staff_required_groups(new.functions);
begin
  if v_req <@ new.whatsapp_joined and not (v_req <@ coalesce(old.whatsapp_joined, '{}')) and new.onboarding_approved_at is null then
    perform app.staff_onboarding_ask(new.user_id);
  end if;
  return null;
end $$;
drop trigger if exists staff_profiles_approval_ask on staff_profiles;
create trigger staff_profiles_approval_ask after update of whatsapp_joined on staff_profiles
  for each row execute function app.staff_approval_ask_after();

drop trigger if exists staff_profiles_onboarding_approval on staff_profiles;
create trigger staff_profiles_onboarding_approval after update of onboarding_approved_at on staff_profiles
  for each row when (old.onboarding_approved_at is distinct from new.onboarding_approved_at) execute function app.staff_onboarding_trg();

-- p {user}: approve (an Admin or a Fleet VA, never themselves; only at the approval step)
create function app.staff_onboarding_approve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user', '')::uuid;
  st jsonb;
begin
  if not app.staff_may_approve(p_by) then raise exception 'Admins and Fleet only' using errcode = '42501'; end if;
  if v_user = p_by then raise exception 'Someone else approves your onboarding' using errcode = '42501'; end if;
  if not exists (select 1 from staff_profiles where user_id = v_user) then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
  st := app.staff_onboarding_state(v_user);
  if st ->> 'step' <> 'approval' then
    raise exception '% is not waiting for approval (now: %)', app.staff_display_name(v_user), coalesce(st ->> 'step', 'done') using errcode = '23514';
  end if;
  update staff_profiles set onboarding_approved_at = now(), onboarding_approved_by = p_by, onboarding_rejected_at = null, onboarding_rejected_by = null, onboarding_reject_reason = null
   where user_id = v_user;
  perform app.staff_onboarding_close_task(v_user, 'done');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'staff_onboarding_approved', 'staff_profiles', v_user::text, '{}'::jsonb);
  return jsonb_build_object('user', v_user, 'onboarded', app.staff_fully_onboarded(v_user));
end $$;

-- p {user, reason}: reject (stays held; the reason shows on Welcome, where they ask again)
create function app.staff_onboarding_reject(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user', '')::uuid;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not app.staff_may_approve(p_by) then raise exception 'Admins and Fleet only' using errcode = '42501'; end if;
  if v_user = p_by then raise exception 'Someone else decides on your onboarding' using errcode = '42501'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Give the reason: the person sees it' using errcode = '22023'; end if;
  if coalesce(app.staff_onboarding_state(v_user) ->> 'step', '') <> 'approval' then raise exception 'Not waiting for approval' using errcode = '23514'; end if;
  update staff_profiles set onboarding_rejected_at = now(), onboarding_rejected_by = p_by, onboarding_reject_reason = left(v_reason, 300), onboarding_asked_at = null
   where user_id = v_user;
  perform app.staff_onboarding_close_task(v_user, 'cancelled');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'staff_onboarding_rejected', 'staff_profiles', v_user::text, jsonb_build_object('reason', v_reason));
  return jsonb_build_object('user', v_user, 'rejected', true);
end $$;

-- the staff member, after a rejection: ask again
create function app.staff_onboarding_ask_again(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(app.staff_onboarding_state(p_user) ->> 'step', '') <> 'approval' then raise exception 'Nothing to ask: finish the steps before' using errcode = '23514'; end if;
  if exists (select 1 from staff_profiles where user_id = p_user and onboarding_asked_at > now() - interval '1 hour' and onboarding_rejected_at is null) then
    return jsonb_build_object('asked', true);
  end if;
  return jsonb_build_object('asked', app.staff_onboarding_ask(p_user));
end $$;

-- Admin: everyone at the approval step, approved in one press
create function app.staff_onboarding_approve_all(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  perform app.assert_admin(p_by);
  for r in select sp.user_id from staff_profiles sp
            where sp.is_active and sp.user_id <> p_by and app.staff_is_member(sp.user_id) and sp.onboarding_approved_at is null
              and app.staff_onboarding_state(sp.user_id) ->> 'step' = 'approval' loop
    perform app.staff_onboarding_approve(p_by, jsonb_build_object('user', r.user_id));
    n := n + 1;
  end loop;
  return jsonb_build_object('approved', n);
end $$;

-- the people waiting (Admin and Fleet)
create function app.staff_onboarding_approvals(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.staff_may_approve(p_by) then raise exception 'Admins and Fleet only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', sp.user_id, 'name', app.staff_display_name(sp.user_id), 'functions', to_jsonb(sp.functions),
             'asked_at', sp.onboarding_asked_at, 'rejected_at', sp.onboarding_rejected_at, 'reject_reason', sp.onboarding_reject_reason, 'self', sp.user_id = p_by)
           order by sp.onboarding_asked_at nulls last)
      from staff_profiles sp
     where sp.is_active and app.staff_is_member(sp.user_id) and sp.onboarding_approved_at is null and not sp.onboarding_exempt and not app.staff_is_test(sp.user_id)
       and app.staff_onboarding_state(sp.user_id) ->> 'step' = 'approval'), '[]'::jsonb);
end $$;

-- Welcome: step 4 after the WhatsApp step
alter function app.staff_welcome(uuid) rename to staff_welcome_pre1154;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_welcome_pre1154(p_user);
  st jsonb := app.staff_onboarding_state(p_user);
  v_steps jsonb := '[]'::jsonb;
  x jsonb;
begin
  if not coalesce((st ->> 'member')::boolean, false) then return v; end if;
  for x in select y from jsonb_array_elements(coalesce(v -> 'steps', '[]'::jsonb)) y loop
    v_steps := v_steps || x;
    if x ->> 'key' = 'team' then
      v_steps := v_steps || jsonb_build_object('key', 'approval',
        'done', coalesce((st ->> 'approved')::boolean, false) or coalesce((st ->> 'exempt')::boolean, false),
        'open', coalesce((st ->> 'step') in ('approval', 'done'), false),
        'asked_at', st -> 'asked_at', 'rejected_at', st -> 'rejected_at', 'reject_reason', st -> 'reject_reason', 'approved_by', st -> 'approved_by');
    end if;
  end loop;
  return v || jsonb_build_object('steps', v_steps);
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)'::regprocedure, 'app.staff_welcome_pre1154(uuid)'::regprocedure);

-- Admin's list: the approval in the state already; who approved
-- (staff_onboarding_list reads staff_onboarding_state, so it carries approved, asked_at and reject_reason)

-- ================================================================ 2. the academy
create function app.academy_since(p_user uuid, p_section uuid) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select coalesce((select r.reset_at from academy_resets r where r.user_id = p_user and r.section_id = p_section), '-infinity'::timestamptz)
$$;

create or replace function app.academy_passed(p_user uuid, p_section uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from academy_attempts a where a.user_id = p_user and a.section_id = p_section and a.passed
                    and a.created_at > app.academy_since(p_user, p_section))
$$;

create or replace function app.academy_path_progress(p_user uuid, p_path text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('code', p.code, 'title', p.title, 'blurb', p.blurb,
    'sections', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'title', s.title, 'blurb', s.blurb, 'sort', ps.sort,
        'open', app.academy_open(p_user, p.code, s.id), 'passed', app.academy_passed(p_user, s.id),
        'unlocked_early', exists (select 1 from academy_unlocks u where u.user_id = p_user and u.section_id = s.id),
        'best_bps', (select max(a.score_bps) from academy_attempts a where a.user_id = p_user and a.section_id = s.id and a.created_at > app.academy_since(p_user, s.id)),
        'attempts', (select count(*) from academy_attempts a where a.user_id = p_user and a.section_id = s.id and a.created_at > app.academy_since(p_user, s.id)),
        'flagged', (select count(*) from academy_attempts a where a.user_id = p_user and a.section_id = s.id and a.flagged),
        'reset_at', (select r.reset_at from academy_resets r where r.user_id = p_user and r.section_id = s.id),
        'lessons', (select count(*) from academy_lessons l where l.section_id = s.id),
        'viewed', (select count(*) from academy_lesson_views v join academy_lessons l on l.id = v.lesson_id where v.user_id = p_user and l.section_id = s.id),
        'questions', (select count(*) from academy_questions q where q.section_id = s.id)) order by ps.sort)
      from academy_path_sections ps join academy_sections s on s.id = ps.section_id where ps.path_code = p.code), '[]'::jsonb),
    'passed', not exists (select 1 from academy_path_sections ps where ps.path_code = p.code and not app.academy_passed(p_user, ps.section_id)))
  from academy_paths p where p.code = p_path
$$;

-- the words of a section's lessons (each scene's narration, else its caption) and its reading time
create function app.academy_read_seconds(p_section uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.settings()).academy_read_wpm, 0) = 0 then 0 else
    ceil(coalesce((select sum(array_length(regexp_split_to_array(t, '\s+'), 1)) from (
        select btrim(coalesce(nullif(btrim(sc ->> 'say'), ''), sc ->> 'caption', '')) t
          from academy_lessons l cross join jsonb_array_elements(l.scenes) sc where l.section_id = p_section) w where t <> ''), 0)
      * 60.0 / (app.settings()).academy_read_wpm)::integer end
$$;

-- when the quiz of a section opens for the person (null: open now), and why not
create function app.academy_quiz_wait(p_user uuid, p_section uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_since timestamptz := app.academy_since(p_user, p_section);
  v_read integer := app.academy_read_seconds(p_section);
  v_open timestamptz;
  v_fail timestamptz;
  v_today integer;
  v_day_start timestamptz := (date_trunc('day', now() at time zone 'America/Toronto')) at time zone 'America/Toronto';
begin
  if app.user_is_admin(p_user) then return jsonb_build_object('ok', true, 'read_seconds', v_read); end if;
  select o.opened_at into v_open from academy_section_opens o where o.user_id = p_user and o.section_id = p_section;
  if v_read > 0 and (v_open is null or v_open + make_interval(secs => v_read) > now()) then
    return jsonb_build_object('ok', false, 'reason', 'reading', 'read_seconds', v_read,
      'until', coalesce(v_open, now()) + make_interval(secs => v_read),
      'message', format('Read the section first: its quiz opens %s minutes after you open it', ceil(v_read / 60.0)::integer));
  end if;
  select count(*) into v_today from academy_attempts a where a.user_id = p_user and a.section_id = p_section and a.created_at >= greatest(v_day_start, v_since);
  if v_today >= s.academy_attempts_per_day then
    return jsonb_build_object('ok', false, 'reason', 'daily', 'read_seconds', v_read, 'until', v_day_start + interval '1 day',
      'message', format('You used your %s tries of this quiz today: try again tomorrow', s.academy_attempts_per_day));
  end if;
  select max(a.created_at) into v_fail from academy_attempts a where a.user_id = p_user and a.section_id = p_section and not a.passed and a.created_at > v_since;
  if v_fail is not null and s.academy_fail_cooldown_minutes > 0 and v_fail + make_interval(mins => s.academy_fail_cooldown_minutes) > now() then
    return jsonb_build_object('ok', false, 'reason', 'cooldown', 'read_seconds', v_read, 'until', v_fail + make_interval(mins => s.academy_fail_cooldown_minutes),
      'message', format('After a failed try, wait %s minutes: try again at %s', s.academy_fail_cooldown_minutes,
                        to_char((v_fail + make_interval(mins => s.academy_fail_cooldown_minutes)) at time zone 'America/Toronto', 'HH24:MI')));
  end if;
  return jsonb_build_object('ok', true, 'read_seconds', v_read, 'tries_left', s.academy_attempts_per_day - v_today);
end $$;

-- the section read: no questions for a learner (they come with academy_quiz_start); the reading time and the quiz's state
alter function app.academy_section(uuid, jsonb) rename to academy_section_pre1154;
create function app.academy_section(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.academy_section_pre1154(p_user, p);
  v_sec uuid := (v ->> 'id')::uuid;
begin
  return v || jsonb_build_object('question_count', jsonb_array_length(coalesce(v -> 'questions', '[]'::jsonb)),
    'questions', case when app.user_is_admin(p_user) then v -> 'questions' else '[]'::jsonb end,
    'opened_at', (select o.opened_at from academy_section_opens o where o.user_id = p_user and o.section_id = v_sec),
    'quiz', app.academy_quiz_wait(p_user, v_sec));
end $$;
select pg_temp.copy_grants('app.academy_section(uuid, jsonb)'::regprocedure, 'app.academy_section_pre1154(uuid, jsonb)'::regprocedure);

create function app.academy_section_id(p_user uuid, p jsonb) returns uuid
language plpgsql stable security definer set search_path = public, app as $$
declare v_sec uuid;
begin
  select id into v_sec from academy_sections where id::text = p ->> 'section' or slug = p ->> 'section';
  if v_sec is null then raise exception 'No such section' using errcode = 'P0002'; end if;
  if not app.user_is_admin(p_user) and not exists (select 1 from academy_path_sections ps where ps.section_id = v_sec
      and ps.path_code = any (app.academy_paths_of(p_user)) and app.academy_open(p_user, ps.path_code, ps.section_id)) then
    raise exception 'Pass the section before this one first' using errcode = '42501';
  end if;
  return v_sec;
end $$;

-- p {section}: the reading clock starts (the first time only)
create function app.academy_opened(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_sec uuid := app.academy_section_id(p_user, p);
begin
  insert into academy_section_opens (user_id, section_id) values (p_user, v_sec) on conflict do nothing;
  return jsonb_build_object('opened_at', (select opened_at from academy_section_opens where user_id = p_user and section_id = v_sec), 'quiz', app.academy_quiz_wait(p_user, v_sec));
end $$;

-- p {section}: the quiz, in a random order of questions and of options (keys: each shown option's index in the question,
-- the index the answer is given by); the attempt's time counts from here
create function app.academy_quiz_start(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_sec uuid := app.academy_section_id(p_user, p);
  w jsonb := app.academy_quiz_wait(p_user, v_sec);
begin
  if not coalesce((w ->> 'ok')::boolean, false) then raise exception '%', w ->> 'message' using errcode = '55000'; end if;
  if not exists (select 1 from academy_questions where section_id = v_sec) then raise exception 'This section has no quiz yet' using errcode = '22023'; end if;
  insert into academy_quiz_starts (user_id, section_id, started_at) values (p_user, v_sec, now())
    on conflict (user_id, section_id) do update set started_at = now();
  return jsonb_build_object('section', v_sec, 'started_at', now(), 'tries_left', w -> 'tries_left',
    'questions', (select jsonb_agg(x.j order by x.r) from (
        select random() r, jsonb_build_object('id', q.id, 'prompt', q.prompt, 'options', o.opts, 'keys', o.keys) j
          from academy_questions q
          cross join lateral (select jsonb_agg(e.value order by e.r) opts, jsonb_agg(e.i - 1 order by e.r) keys
                                from (select value, i, random() r from jsonb_array_elements(q.options) with ordinality t(value, i)) e) o
         where q.section_id = v_sec) x));
end $$;

-- the submit: a started quiz (learners), the waits, the time taken (flagged when too fast), the right answers only on a pass
alter function app.academy_quiz_submit(uuid, jsonb) rename to academy_quiz_submit_pre1154;
create function app.academy_quiz_submit(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_sec uuid := app.academy_section_id(p_user, p);
  v_admin boolean := app.user_is_admin(p_user);
  v_start timestamptz;
  w jsonb;
  r jsonb;
  v_secs integer;
  v_n integer;
  v_flag boolean := false;
  v_att uuid;
begin
  if not v_admin then
    select started_at into v_start from academy_quiz_starts where user_id = p_user and section_id = v_sec;
    if v_start is null or v_start < now() - interval '3 hours' then raise exception 'Start the quiz first' using errcode = '55000'; end if;
    -- the waits as they were when the quiz was handed out (reading time, tries a day, the cooldown)
    w := app.academy_quiz_wait(p_user, v_sec);
    if not coalesce((w ->> 'ok')::boolean, false) and w ->> 'reason' <> 'reading' then raise exception '%', w ->> 'message' using errcode = '55000'; end if;
  end if;
  r := app.academy_quiz_submit_pre1154(p_user, jsonb_build_object('section', v_sec, 'answers', p -> 'answers'));
  if not v_admin then
    delete from academy_quiz_starts where user_id = p_user and section_id = v_sec;
    v_secs := greatest(0, floor(extract(epoch from now() - v_start)))::integer;
    v_n := (r ->> 'total')::integer;
    v_flag := s.academy_rapid_seconds > 0 and v_secs < s.academy_rapid_seconds * v_n;
    select id into v_att from academy_attempts where user_id = p_user and section_id = v_sec order by created_at desc limit 1;
    update academy_attempts set seconds = v_secs, flagged = v_flag where id = v_att;
    if v_flag then
      begin
        perform app.staff_alert('academy_rapid', 'academy_attempt', v_att, 'rapid',
          format('Academy: %s answered too fast', app.staff_display_name(p_user)),
          format('%s questions of "%s" in %s seconds (%s).', v_n, (select title from academy_sections where id = v_sec), v_secs, case when (r ->> 'passed')::boolean then 'passed' else 'not passed' end),
          jsonb_build_object('path_admin', '/admin/academy/staff/' || p_user));
      exception when others then raise warning 'academy rapid alert not made: %', sqlerrm;
      end;
    end if;
  end if;
  if not coalesce((r ->> 'passed')::boolean, false) then
    -- a failed try: which were wrong, not the right answers
    r := r || jsonb_build_object('results', (select coalesce(jsonb_agg(jsonb_build_object('id', x ->> 'id', 'given', x -> 'given', 'answer', null, 'right', x -> 'right', 'explain', '')), '[]'::jsonb)
                                            from jsonb_array_elements(r -> 'results') x));
  end if;
  return r || jsonb_build_object('seconds', v_secs, 'flagged', v_flag, 'quiz', app.academy_quiz_wait(p_user, v_sec));
end $$;
select pg_temp.copy_grants('app.academy_quiz_submit(uuid, jsonb)'::regprocedure, 'app.academy_quiz_submit_pre1154(uuid, jsonb)'::regprocedure);

-- Admin: p {user_id, sections: [id, ...]}: those sections start over for the person
create function app.academy_reset(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_secs uuid[];
begin
  perform app.assert_admin(p_by);
  if v_user is null or not exists (select 1 from users where id = v_user) then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
  -- the sections: an array, one section, or the page's ticks (s_<section id>: true)
  select coalesce(array_agg(s.id), '{}') into v_secs from academy_sections s
   where s.id::text in (select jsonb_array_elements_text(case when jsonb_typeof(p -> 'sections') = 'array' then p -> 'sections' else jsonb_build_array(p ->> 'section') end)
                        union select substr(e.key, 3) from jsonb_each(p) e where e.key like 's\_%' and e.value = 'true'::jsonb);
  if cardinality(v_secs) = 0 then raise exception 'Choose the sections to reset' using errcode = '22023'; end if;
  insert into academy_resets (user_id, section_id, reset_at, reset_by) select v_user, x, now(), p_by from unnest(v_secs) x
    on conflict (user_id, section_id) do update set reset_at = now(), reset_by = p_by;
  delete from academy_lesson_views v using academy_lessons l where l.id = v.lesson_id and v.user_id = v_user and l.section_id = any (v_secs);
  delete from academy_section_opens where user_id = v_user and section_id = any (v_secs);
  delete from academy_quiz_starts where user_id = v_user and section_id = any (v_secs);
  delete from academy_unlocks where user_id = v_user and section_id = any (v_secs);
  perform app.staff_onboarding_refresh(v_user);
  return jsonb_build_object('reset', cardinality(v_secs), 'onboarded', app.staff_fully_onboarded(v_user));
end $$;

-- ================================================================ 3. rebooking: the last booking's salesperson claims the new lead
create function app.lead_rebook_person(l leads) returns uuid
language sql stable security definer set search_path = public, app as $$
  select b.sales_staff_id
    from bookings b join renters rn on rn.id = b.renter_id left join users u on u.id = rn.user_id
   where b.status::text in ('confirmed', 'on_rent', 'returned', 'closed')
     and ((nullif(l.email, '') is not null and lower(coalesce(nullif(rn.email, ''), u.email)) = lower(l.email))
          or (app.phone_e164(l.phone) is not null and app.phone_e164(rn.mobile) = app.phone_e164(l.phone)))
   order by b.pickup_at desc, b.created_at desc
   limit 1
$$;

create function app.lead_rebook_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_to uuid;
  v_win integer;
  s sales_lead_settings := app.sl_settings();
  v_prev text := coalesce(current_setting('app.lead_admin_move', true), '');
begin
  begin
    if app.sl_type(new) <> 'renter' or new.assigned_to is not null or new.status in ('spam', 'closed', 'converted') or app.email_is_test(new.email) then return null; end if;
    if exists (select 1 from lead_claims c where c.lead_id = new.id) then return null; end if;
    v_to := app.lead_rebook_person(new);
    if v_to is null or app.staff_is_test(v_to) or not app.staff_fully_onboarded(v_to) or not app.user_va_has(v_to, 'sales')
       or not exists (select 1 from users u where u.id = v_to and u.status = 'active') then return null; end if;
    v_win := app.sl_window('renter');
    perform set_config('app.lead_admin_move', 'on', true);
    insert into lead_claims (lead_id, claimed_by, claimed_at, expires_at, cap_at)
    values (new.id, v_to, now(), now() + make_interval(mins => v_win), now() + make_interval(mins => greatest(v_win, s.extend_max_minutes)));
    perform set_config('app.lead_admin_move', v_prev, true);
    insert into lead_claim_log (lead_id, user_id, action, by_user, note) values (new.id, v_to, 'claim', null, 'Rebooking: credited on their last booking');
  exception when others then
    perform set_config('app.lead_admin_move', v_prev, true);
    raise warning 'rebooking claim not made for lead %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists leads_b_rebook on leads;
create trigger leads_b_rebook after insert on leads for each row execute function app.lead_rebook_trg();

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1154;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_member boolean := p_user is not null and app.staff_is_member(p_user);
begin
  -- the learner's academy calls and asking again: open while held (the person as they are)
  if p_call in ('ops_do', 'va_do', 'field_do') and p_name in ('academy_opened', 'academy_quiz_start', 'staff_onboarding_ask_again') then
    perform app.door_begin(p_user, p_aal);
    if v_member then perform set_config('app.onboarding_pass', p_user::text, true); end if;
    if not (app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user)) then raise exception 'Staff only' using errcode = '42501'; end if;
    return case p_name when 'academy_opened' then app.academy_opened(p_user, p_)
                       when 'academy_quiz_start' then app.academy_quiz_start(p_user, p_)
                       else app.staff_onboarding_ask_again(p_user, p_) end;
  end if;
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'staff_onboarding_approvals')
     or (p_call in ('ops_do', 'va_do', 'admin_do') and p_name in ('staff_onboarding_approve', 'staff_onboarding_reject', 'staff_onboarding_approve_all')) then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'staff_onboarding_approvals' then app.staff_onboarding_approvals(p_user, p_)
      when 'staff_onboarding_approve' then app.staff_onboarding_approve(p_user, p_)
      when 'staff_onboarding_reject' then app.staff_onboarding_reject(p_user, p_)
      else app.staff_onboarding_approve_all(p_user, p_) end;
  end if;
  if p_call = 'admin_do' and p_name = 'academy_reset' then
    perform app.door_begin(p_user, p_aal);
    return app.academy_reset(p_user, p_);
  end if;
  return app.door_pre1154(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1154(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ at deploy: everyone onboarded before waits for approval
-- (no grace, as 1151); each gets the alert and the Fleet To do
do $$
declare r record;
begin
  perform app.staff_onboarding_refresh_all();
  for r in select sp.user_id from staff_profiles sp
            where sp.is_active and sp.onboarding_approved_at is null and not sp.onboarding_exempt and not app.staff_is_test(sp.user_id)
              and app.staff_is_member(sp.user_id) and app.staff_onboarding_state(sp.user_id) ->> 'step' = 'approval' loop
    perform app.staff_onboarding_ask(r.user_id);
  end loop;
end $$;
select app.leads_return_unonboarded(null, null);

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['staff_onboarding_state_pre1154', 'staff_display_name', 'staff_may_approve', 'staff_onboarding_ask',
                     'staff_onboarding_close_task', 'staff_approval_whatsapp_before', 'staff_approval_ask_after', 'staff_onboarding_approve', 'staff_onboarding_reject',
                     'staff_onboarding_ask_again', 'staff_onboarding_approve_all', 'staff_onboarding_approvals', 'staff_welcome_pre1154', 'academy_since',
                     'academy_read_seconds', 'academy_quiz_wait', 'academy_section_pre1154', 'academy_section_id', 'academy_opened', 'academy_quiz_start',
                     'academy_quiz_submit_pre1154', 'academy_reset', 'lead_rebook_person', 'lead_rebook_trg', 'door_pre1154'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
