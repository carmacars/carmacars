-- 1060_r35k_staff_onboarding.sql
-- Release 35, part K (docs/changes/2026-11-08-r35-staff-onboarding.md). SCHEMA_MARKER 1064 (with 1061 to 1064).
--   1. Staff agreements (27a, with the order of 21:16): every staff member signs their role's agreement. The order is the
--      academy first, then the agreement, then the rest of the portal: once the academy is passed (or waived), a staff
--      member without a signed agreement opens only Welcome, their profile, the guide and their documents to sign
--      (app.agreement_locked, Program settings staff_agreement_gate, on). The right agreement per function: the Field Staff
--      Agreement (an employee's) for field work only; the Virtual Assistant Contractor Agreement for customer service, fleet,
--      finance and Sales in person or remote (0197 gave in-person Sales the field agreement). Every staff member without one
--      (never an Admin) gets it by itself, filled from their record (server_staff_agreements_due, the agreements job); one
--      reminder 3 days after it was sent; Admin > Staff > Staff agreements lists who has not signed. Existing staff keep 3
--      days before the agreement holds them (staff_profiles.agreement_lock_from); an Admin may waive it with a reason.
--   2. Welcome: welcome, profile (with the preferred name, item 29), the academy, the agreement, the team group (27h:
--      the WhatsApp group link of Program settings, empty until the owner's team fills it), the first tasks. The team
--      group email goes once the academy and the agreement are done.
--   3. Closed roles (27b): a closed role's page says it is filled and sends the applicant to Sales (server_hiring_closed_role).
--      Program settings hiring_refer_va_to_sales (on): every customer service, fleet or finance applicant is referred to
--      Sales (remote, or in person for an in-person role) with the referral email; the applicants not yet hired and not
--      referred get it by the hiring job.
--   4. Auto-hire for Sales (27c): a Sales applicant (in person or remote) whose AI interview score meets the auto-hire mark
--      (hiring_auto_hire_mark, default the role's pass mark: passing the AI interview), with no knock-out and no "decline", is hired with one-step
--      Hire by the interviews job; an Admin alert per auto-hire (server_hire_auto_due, server_hire_auto_done).
--   5. AI interviews for every role (27c2): hiring_ai_all_roles (on): the in-person roles (field, Sales in person) take the
--      AI video interview too (a phone call stays optional), with questions of their own.
--   6. Standard pay (27e): the Hire form's standard pay of a function reads the open role of that function (its pay, or the
--      amount in its pay text), so the Hire form and the careers page say the same.
--   7. Preferred name (29): users.greeting_name (0324) is the preferred name; the profile step asks for it; my_roles and the
--      staff list carry it.
--   8. Inactivity lock (coordinator, item 1): a staff account (never an Admin) with no sign-in or use for
--      staff_inactive_lock_days (10) is locked; an email warns at staff_inactive_warn_days (7); Admins are alerted and unlock
--      in one click on the staff list, which shows the last sign-in.
-- No applied migration is edited: app.my_roles, app.staff_welcome, app.door, app.server_jobs_due, app.hire_standard_pay,
-- app.hiring_screen, app.ai_interview_applies, app.ai_interview_questions, app.hiring_ai_new_link,
-- app.hiring_waiting_by_role, public.server_ai_interviews_due, app.job_hiring and app.staff_agreement_kind are wrapped or
-- replaced.
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
  if position(p_old in d) = 0 then raise exception '1060: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings
alter table program_settings
  add column if not exists staff_agreement_gate boolean not null default true,
  add column if not exists hiring_refer_va_to_sales boolean not null default true,
  add column if not exists hiring_auto_hire_sales boolean not null default true,
  add column if not exists hiring_auto_hire_mark integer check (hiring_auto_hire_mark is null or hiring_auto_hire_mark between 0 and 100),
  add column if not exists hiring_ai_all_roles boolean not null default true,
  add column if not exists whatsapp_sales_group_url text not null default '' check (whatsapp_sales_group_url = '' or whatsapp_sales_group_url ~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]{10,40}$'),
  add column if not exists whatsapp_team_group_url text not null default '' check (whatsapp_team_group_url = '' or whatsapp_team_group_url ~ '^https://chat\.whatsapp\.com/[A-Za-z0-9]{10,40}$'),
  add column if not exists staff_inactive_lock_days integer not null default 10 check (staff_inactive_lock_days between 3 and 90),
  add column if not exists staff_inactive_warn_days integer not null default 7 check (staff_inactive_warn_days between 1 and 89);
comment on column program_settings.staff_agreement_gate is 'Staff agreements (1060): after the academy, a staff member without a signed agreement opens only Welcome, the profile, the guide and the documents to sign.';
comment on column program_settings.hiring_refer_va_to_sales is 'Hiring (1060): every customer service, fleet or finance applicant is referred to Sales (remote, or in person for an in-person role) with the referral email.';
comment on column program_settings.hiring_auto_hire_sales is 'Hiring (1060): a Sales applicant whose AI interview score meets the auto-hire mark is hired with one-step Hire by itself.';
comment on column program_settings.hiring_auto_hire_mark is 'Hiring (1060): the auto-hire mark (0 to 100); empty: the role''s pass mark (the owner: passing the AI interview means hired).';
comment on column program_settings.hiring_ai_all_roles is 'Hiring (1060): every role takes the AI video interview, the in-person roles included (a phone call stays optional).';
comment on column program_settings.whatsapp_sales_group_url is 'The WhatsApp group link new Sales staff get after the academy and the agreement (1060). Empty: none shown.';
comment on column program_settings.whatsapp_team_group_url is 'The WhatsApp group link new customer service, fleet, finance and field staff get after the academy and the agreement (1060). Empty: none shown.';
comment on column program_settings.staff_inactive_lock_days is 'A staff account (never an Admin) with no sign-in or use for this many days is locked until an Admin unlocks it (1060).';
comment on column program_settings.staff_inactive_warn_days is 'The day of no sign-in on which the staff member is warned by email that the lock is coming (1060).';

alter table staff_profiles
  add column if not exists agreement_lock_from timestamptz,
  add column if not exists agreement_waived_at timestamptz,
  add column if not exists agreement_waived_by uuid references users (id),
  add column if not exists agreement_waived_reason text check (agreement_waived_reason is null or length(btrim(agreement_waived_reason)) between 3 and 300),
  add column if not exists team_group_sent_at timestamptz,
  add column if not exists team_group_joined_at timestamptz,
  add column if not exists last_seen_at timestamptz,
  add column if not exists inactive_warned_at timestamptz,
  add column if not exists inactive_locked_at timestamptz,
  add column if not exists inactive_unlocked_at timestamptz,
  add column if not exists inactive_unlocked_by uuid references users (id);
comment on column staff_profiles.agreement_lock_from is 'From when a missing signed staff agreement holds the portal (1060); empty: at once (after the academy). Staff on file at 1060 got 3 days.';
comment on column staff_profiles.last_seen_at is 'The last sign-in or use of the staff portal (1060, kept to the hour): the inactivity lock counts from it.';
comment on column staff_profiles.inactive_locked_at is 'Locked for inactivity (1060): no sign-in or use for staff_inactive_lock_days. Cleared by an Admin (Unlock).';

-- the staff on file now: the agreement holds them in 3 days; their inactivity counts from now
update staff_profiles set agreement_lock_from = now() + interval '3 days' where agreement_lock_from is null;
update staff_profiles set last_seen_at = now() where last_seen_at is null;

-- ================================================================ 1. which agreement, signed, locked
-- The owner (27a): Sales staff got the Field Staff Agreement, which is wrong. The field agreement is for field work only.
create or replace function app.staff_agreement_kind(sp staff_profiles) returns text
language sql stable set search_path = public, app as $$
  select case when 'field' = any (sp.functions) or (cardinality(sp.functions) = 0 and sp.staff_type = 'field') then 'in_person' else 'remote' end
$$;

create function app.staff_agreement_signed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from sign_requests r where r.staff_user_id = p_user and r.doc_type = 'staff_agreement' and r.status = 'signed')
$$;

create function app.staff_is_member(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not app.user_is_admin(p_user)
     and exists (select 1 from user_roles r join users u on u.id = r.user_id where r.user_id = p_user and r.role in ('va', 'field') and u.status = 'active')
     and exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.is_active)
$$;

-- after the academy: no signed agreement (and none waived) holds the portal
create function app.agreement_locked(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).staff_agreement_gate, false) and app.staff_is_member(p_user)
     and not app.academy_locked(p_user)
     and not app.staff_agreement_signed(p_user)
     and exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.agreement_waived_at is null
                  and coalesce(sp.agreement_lock_from, '-infinity'::timestamptz) <= now())
$$;

create function app.inactive_locked(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not app.user_is_admin(p_user) and exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.inactive_locked_at is not null)
$$;

-- the WhatsApp groups of a person: Sales, the team, or both
create function app.staff_groups(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by x ->> 'key'), '[]'::jsonb) from (
    select jsonb_build_object('key', 'sales', 'name', 'CARMA Closers', 'url', (app.settings()).whatsapp_sales_group_url) x
      from staff_profiles sp where sp.user_id = p_user and 'sales' = any (sp.functions) and (app.settings()).whatsapp_sales_group_url <> ''
    union all
    select jsonb_build_object('key', 'team', 'name', 'CarmaCars Team', 'url', (app.settings()).whatsapp_team_group_url)
      from staff_profiles sp where sp.user_id = p_user and sp.functions && array['cs', 'fleet', 'finance', 'field'] and (app.settings()).whatsapp_team_group_url <> '') y
$$;

-- the state of a person's agreement: signed, waived, sent (waiting), or none yet (with what the automatic send waits for)
create table if not exists staff_agreement_auto (
  user_id     uuid primary key references users (id) on delete cascade,
  tries       integer not null default 0,
  last_at     timestamptz,
  last_error  text,
  missing     text[] not null default '{}',
  request_id  uuid references sign_requests (id) on delete set null,
  reminded_at timestamptz,
  updated_at  timestamptz not null default now()
);
comment on table staff_agreement_auto is 'The staff agreement sent by itself (1060): each try, what it waited for, and the one reminder.';
alter table staff_agreement_auto enable row level security;
revoke all on staff_agreement_auto from anon, authenticated;
grant all on staff_agreement_auto to service_role;

create function app.staff_agreement_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'state', case when app.staff_agreement_signed(p_user) then 'signed' when sp.agreement_waived_at is not null then 'waived'
                  when r.id is not null then 'sent' else 'none' end,
    'request_id', r.id, 'sent_at', r.sent_at,
    'signed_at', (select max(x.signed_at) from sign_requests x where x.staff_user_id = p_user and x.doc_type = 'staff_agreement' and x.status = 'signed'),
    'kind', app.staff_agreement_kind(sp), 'reminded_at', a.reminded_at, 'missing', to_jsonb(coalesce(a.missing, '{}')), 'error', a.last_error,
    'waived_reason', sp.agreement_waived_reason, 'lock_from', sp.agreement_lock_from)
    from staff_profiles sp
    left join lateral (select * from sign_requests x where x.staff_user_id = p_user and x.doc_type = 'staff_agreement' and x.status = 'sent' order by x.sent_at desc limit 1) r on true
    left join staff_agreement_auto a on a.user_id = p_user
   where sp.user_id = p_user
$$;

-- ================================================================ 2. my_roles
alter function app.my_roles(uuid) rename to my_roles_pre1060;
create function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.my_roles_pre1060(p_user) || jsonb_build_object('agreement_locked', app.agreement_locked(p_user), 'inactive_locked', app.inactive_locked(p_user),
    'preferred_name', (select nullif(btrim(u.greeting_name), '') from users u where u.id = p_user))
$$;
select pg_temp.copy_grants('app.my_roles(uuid)'::regprocedure, 'app.my_roles_pre1060(uuid)'::regprocedure);

-- ================================================================ 3. Welcome: academy, then agreement, then the team group
alter function app.staff_welcome(uuid) rename to staff_welcome_pre1060;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_welcome_pre1060(p_user);
  v_steps jsonb := '[]'::jsonb;
  st jsonb;
  ag jsonb := app.staff_agreement_state(p_user);
  v_academy boolean;
  v_signed boolean;
  v_pref text := (select nullif(btrim(u.greeting_name), '') from users u where u.id = p_user);
  v_groups jsonb := app.staff_groups(p_user);
  sp staff_profiles;
begin
  select * into sp from staff_profiles where user_id = p_user;
  v_academy := coalesce((select (x ->> 'done')::boolean from jsonb_array_elements(v -> 'steps') x where x ->> 'key' = 'academy'), true);
  v_signed := ag ->> 'state' in ('signed', 'waived');
  for st in select x from jsonb_array_elements(v -> 'steps') x loop
    if st ->> 'key' = 'profile' then
      st := st || jsonb_build_object('preferred_name', v_pref, 'done', (st ->> 'done')::boolean and v_pref is not null);
    end if;
    if st ->> 'key' = 'tasks' then
      v_steps := v_steps
        || jsonb_build_object('key', 'agreement', 'done', v_signed, 'state', ag ->> 'state', 'request_id', ag ->> 'request_id', 'kind', ag ->> 'kind',
             'waiting_for_academy', not v_academy, 'missing', ag -> 'missing')
        || jsonb_build_object('key', 'team', 'done', jsonb_array_length(v_groups) = 0 or sp.team_group_joined_at is not null,
             'open', v_academy and v_signed, 'groups', case when v_academy and v_signed then v_groups else '[]'::jsonb end);
    end if;
    v_steps := v_steps || st;
  end loop;
  return v || jsonb_build_object('steps', v_steps, 'locked', (v ->> 'locked')::boolean or app.agreement_locked(p_user), 'preferred_name', v_pref,
    'name', coalesce(v_pref, v ->> 'name'));
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)'::regprocedure, 'app.staff_welcome_pre1060(uuid)'::regprocedure);

-- the preferred name (any staff member, their own)
create function app.staff_preferred_name_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v text := nullif(btrim(coalesce(p ->> 'preferred_name', '')), '');
begin
  if not (app.user_is_admin(p_user) or exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('va', 'field'))) then raise exception 'Staff only' using errcode = '42501'; end if;
  if v is null then raise exception 'Enter the name you go by' using errcode = '22023'; end if;
  if length(v) > 60 then raise exception 'The preferred name is at most 60 characters' using errcode = '22023'; end if;
  update users set greeting_name = v, updated_at = now() where id = p_user;
  return jsonb_build_object('preferred_name', v);
end $$;

-- "I joined the group" on Welcome
create function app.staff_team_joined(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  update staff_profiles set team_group_joined_at = coalesce(team_group_joined_at, now()) where user_id = p_user;
  if not found then raise exception 'Staff only' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 4. the agreements sent by themselves, the reminder, the Admin list
-- the Admin the automatic work acts as: the signing officer's account when it is an Admin, else the first Admin
create function app.system_admin() returns uuid
language sql stable security definer set search_path = public, app as $$
  select u.id from users u join user_roles r on r.user_id = u.id and r.role = 'admin'
   where u.status = 'active'
   order by (lower(btrim(coalesce(u.full_name, ''))) = lower(btrim(coalesce((app.settings()).signing_officer_name, '')))) desc, u.created_at
   limit 1
$$;

create function app.staff_agreements_due_rows(p_limit integer default 5) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select sp.user_id from staff_profiles sp
   where app.staff_is_member(sp.user_id) and sp.agreement_waived_at is null
     and not app.staff_agreement_signed(sp.user_id)
     and not exists (select 1 from sign_requests r where r.staff_user_id = sp.user_id and r.doc_type = 'staff_agreement' and r.status = 'sent')
     and not exists (select 1 from staff_agreement_auto a where a.user_id = sp.user_id
                      and (a.last_at > now() - interval '1 day' or a.tries >= 5))
   order by sp.created_at
   limit greatest(p_limit, 1)
$$;

create function public.server_staff_agreements_due(p_limit integer default 3) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('actor', app.system_admin(), 'users', coalesce((select jsonb_agg(jsonb_build_object('user_id', x,
           'pay', (select jsonb_build_object('pay_basis', o.pay_basis, 'pay_cents', o.pay_cents, 'pay_currency', o.pay_currency)
                     from staff_onboarding o where o.user_id = x order by o.created_at desc limit 1)))
      from app.staff_agreements_due_rows(p_limit) x), '[]'::jsonb))
$$;

-- after a try: sent (request), or what it waits for (an Admin To do), or the error
create function public.server_staff_agreement_auto_done(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_req uuid := nullif(p ->> 'request_id', '')::uuid;
  v_missing text[] := coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(p -> 'missing') = 'array' then p -> 'missing' else '[]'::jsonb end)), '{}');
  v_err text := left(nullif(btrim(coalesce(p ->> 'error', '')), ''), 300);
  v_name text := (select coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) from users u where u.id = p_user);
begin
  insert into staff_agreement_auto (user_id, tries, last_at, last_error, missing, request_id, updated_at)
  values (p_user, 1, now(), v_err, v_missing, v_req, now())
  on conflict (user_id) do update set tries = case when excluded.request_id is not null then 0 else staff_agreement_auto.tries + 1 end, last_at = now(),
         last_error = excluded.last_error, missing = excluded.missing, request_id = coalesce(excluded.request_id, staff_agreement_auto.request_id), updated_at = now();
  if v_req is null then
    perform app.raise_task(p_type => 'staff_agreement_send', p_queue => 'admin', p_priority => 'high',
      p_title => left(format('Staff agreement for %s could not be sent', v_name), 200),
      p_detail => left(case when cardinality(v_missing) > 0 then 'It waits for: ' || array_to_string(v_missing, ', ') || '. Fill them in on Settings > Staff, Staff agreements, then press Send.'
                            else coalesce('Error: ' || v_err, 'Not sent') end, 600),
      p_related_table => 'users', p_related_id => p_user, p_dedupe => 'staff_agreement_send:' || p_user);
  else
    update tasks set status = 'done', completed_at = now(), completion_note = 'Agreement sent'
     where task_type = 'staff_agreement_send' and related_id = p_user and status in ('open', 'in_progress', 'waiting');
  end if;
  return jsonb_build_object('ok', true);
end $$;
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('staff_agreement_send', 'admin', 'A staff agreement could not be sent', 'high', 'none', null, 'The staff agreement is sent by itself to every staff member without one (1060). This one waits for a value the record does not hold, or failed.')
on conflict (task_type) do nothing;

-- the reminder (once, 3 days after it was sent) and the team group email (once the academy and the agreement are done)
create function app.job_staff_agreements(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n_rem integer := 0;
  n_team integer := 0;
  v_groups jsonb;
begin
  for r in select x.id, x.staff_user_id, x.sent_at, u.email, coalesce(nullif(btrim(u.greeting_name), ''), split_part(btrim(coalesce(u.full_name, '')), ' ', 1)) first_name
             from sign_requests x join users u on u.id = x.staff_user_id
            where x.doc_type = 'staff_agreement' and x.status = 'sent' and x.sent_at < p_now - interval '3 days' and app.staff_is_member(x.staff_user_id)
              and not exists (select 1 from staff_agreement_auto a where a.user_id = x.staff_user_id and a.reminded_at is not null) loop
    perform app.emit_event('staff_agreement_reminder', 'user', r.staff_user_id, jsonb_build_object('recipient_user_id', r.staff_user_id, 'first_name', coalesce(nullif(r.first_name, ''), 'there'),
      'sign_url', rtrim((app.settings()).notify_base_url, '/') || case when exists (select 1 from staff_profiles sp where sp.user_id = r.staff_user_id and 'field' = any (sp.functions) and not ('cs' = any (sp.functions) or 'fleet' = any (sp.functions) or 'finance' = any (sp.functions) or 'sales' = any (sp.functions))) then '/staff/field/sign' else '/staff/sign' end),
      'staff_agreement_reminder:' || r.id);
    insert into staff_agreement_auto (user_id, reminded_at) values (r.staff_user_id, p_now)
    on conflict (user_id) do update set reminded_at = p_now, updated_at = now();
    n_rem := n_rem + 1;
  end loop;
  for r in select sp.user_id, coalesce(nullif(btrim(u.greeting_name), ''), split_part(btrim(coalesce(u.full_name, '')), ' ', 1)) first_name
             from staff_profiles sp join users u on u.id = sp.user_id
            where sp.team_group_sent_at is null and app.staff_is_member(sp.user_id) and not app.academy_locked(sp.user_id)
              and (app.staff_agreement_signed(sp.user_id) or sp.agreement_waived_at is not null) loop
    v_groups := app.staff_groups(r.user_id);
    if jsonb_array_length(v_groups) = 0 then continue; end if;
    perform app.emit_event('staff_team_group', 'user', r.user_id, jsonb_build_object('recipient_user_id', r.user_id, 'first_name', coalesce(nullif(r.first_name, ''), 'there'),
      'group_name', v_groups -> 0 ->> 'name', 'group_url', v_groups -> 0 ->> 'url',
      'second_group_name', coalesce(v_groups -> 1 ->> 'name', ''), 'second_group_url', coalesce(v_groups -> 1 ->> 'url', '')), 'staff_team_group:' || r.user_id);
    update staff_profiles set team_group_sent_at = p_now where user_id = r.user_id;
    n_team := n_team + 1;
  end loop;
  return format('%s agreement reminder(s), %s team group email(s)', n_rem, n_team);
end $$;

-- Admin > Staff > Staff agreements: every staff member and their agreement, the ones not signed first
create function app.staff_agreements_status(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(x order by (x ->> 'state') = 'signed', (x ->> 'state') = 'waived', x ->> 'name') from (
    select jsonb_build_object('user_id', sp.user_id, 'name', coalesce(u.full_name, u.email), 'preferred_name', nullif(btrim(u.greeting_name), ''), 'email', u.email,
             'functions', to_jsonb(sp.functions), 'academy_locked', app.academy_locked(sp.user_id), 'locked', app.agreement_locked(sp.user_id))
           || app.staff_agreement_state(sp.user_id) x
      from staff_profiles sp join users u on u.id = sp.user_id where app.staff_is_member(sp.user_id)) y), '[]'::jsonb);
end $$;

create function app.staff_agreement_waive(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_on boolean := coalesce((p ->> 'on')::boolean, true);
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
begin
  perform app.assert_admin(p_by);
  if v_on and length(v_reason) < 3 then raise exception 'Give the reason for waiving the agreement' using errcode = '22023'; end if;
  update staff_profiles set agreement_waived_at = case when v_on then now() end, agreement_waived_by = case when v_on then p_by end,
         agreement_waived_reason = case when v_on then left(v_reason, 300) end where user_id = v_user;
  if not found then raise exception 'That person is not on the staff' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, case when v_on then 'staff_agreement_waived' else 'staff_agreement_waiver_removed' end, 'staff_profiles', v_user::text, jsonb_build_object('reason', nullif(v_reason, '')));
  return app.staff_agreement_state(v_user);
end $$;

-- ================================================================ 5. inactivity
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('staff_inactive_locked', 'A staff account was locked for inactivity', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'No sign-in or use for the days of Program settings (1060). Unlock on Staff.', 160),
  ('hire_auto', 'A Sales applicant was hired by itself', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'The AI interview score met the auto-hire mark (1060).', 161),
  ('staff_unanswered', 'A customer is waiting for an answer', 'Messages', '{admin,on_duty:cs}', 'urgent', 'messages', true, false, 'A text or missed call with no answer past the time of Program settings (1061).', 162),
  ('staff_clock_reminder', 'Not clocked in at the start time', 'Staff', '{assigned}', 'normal', 'alerts', true, false, 'Customer service, Fleet and Finance staff not clocked in by their start time (1061).', 163),
  ('townhall_soon', 'The weekly townhall starts in an hour', 'Staff', '{admin,on_duty:cs,on_duty:fleet,on_duty:finance,on_duty:sales}', 'normal', 'alerts', true, false, 'The weekly staff call (1062).', 164)
on conflict (rule) do nothing;

create function app.staff_last_active(sp staff_profiles) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select greatest(sp.last_seen_at, sp.inactive_unlocked_at, (select x.last_seen_at from staff_seen x where x.user_id = sp.user_id), (select u.last_sign_in_at from users u where u.id = sp.user_id), sp.created_at)
$$;

-- the door touches it at most once an hour
-- kept in its own table, so the door never writes staff_profiles (its triggers rebalance shifts and sync roles)
create table if not exists staff_seen (
  user_id      uuid primary key references users (id) on delete cascade,
  last_seen_at timestamptz not null default now()
);
comment on table staff_seen is 'The last use of each signed-in account (1060), kept to the hour by the door: the inactivity lock counts from it.';
alter table staff_seen enable row level security;
revoke all on staff_seen from anon, authenticated;
grant all on staff_seen to service_role;
create function app.staff_touch(p_user uuid) returns void
language sql security definer set search_path = public, app as $$
  insert into staff_seen (user_id, last_seen_at) select p_user, now() where exists (select 1 from users u where u.id = p_user)
  on conflict (user_id) do update set last_seen_at = now() where staff_seen.last_seen_at < now() - interval '1 hour'
$$;

-- a sign-in (every method): the account's last sign-in; a locked staff account says so
create function public.server_signed_in(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  update users set last_sign_in_at = now() where id = p_user;
  perform app.staff_touch(p_user);
  return jsonb_build_object('inactive_locked', app.inactive_locked(p_user));
end $$;

create function app.job_staff_inactivity(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r record;
  n_warn integer := 0;
  n_lock integer := 0;
begin
  for r in select sp.user_id, app.staff_last_active(sp) last_at, sp.inactive_warned_at, coalesce(u.full_name, u.email) name,
                  coalesce(nullif(btrim(u.greeting_name), ''), split_part(btrim(coalesce(u.full_name, '')), ' ', 1)) first_name
             from staff_profiles sp join users u on u.id = sp.user_id
            where sp.inactive_locked_at is null and app.staff_is_member(sp.user_id) loop
    if r.last_at < p_now - make_interval(days => s.staff_inactive_lock_days) then
      update staff_profiles set inactive_locked_at = p_now where user_id = r.user_id;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
      values (null, 'staff_inactive_locked', 'staff_profiles', r.user_id::text, jsonb_build_object('last_active', r.last_at, 'days', s.staff_inactive_lock_days));
      perform app.staff_alert('staff_inactive_locked', 'user', r.user_id, 'locked:' || to_char(p_now, 'YYYYMMDD'),
        left(format('%s was locked for inactivity', r.name), 140), format('No sign-in since %s. Unlock on Staff if they still work with us.', app.fmt_at(r.last_at)),
        jsonb_build_object('path_admin', '/admin/staff'));
      n_lock := n_lock + 1;
    elsif r.last_at < p_now - make_interval(days => s.staff_inactive_warn_days) and (r.inactive_warned_at is null or r.inactive_warned_at < r.last_at) then
      perform app.emit_event('staff_inactivity_warning', 'user', r.user_id, jsonb_build_object('recipient_user_id', r.user_id, 'first_name', coalesce(nullif(r.first_name, ''), 'there'),
        'days_idle', s.staff_inactive_warn_days::text, 'lock_days', s.staff_inactive_lock_days::text,
        'lock_on', to_char((r.last_at + make_interval(days => s.staff_inactive_lock_days)) at time zone 'America/Toronto', 'FMDay, FMMonth FMDD'),
        'sign_in_url', rtrim(s.notify_base_url, '/') || '/sign-in?next=/staff'), 'staff_inactivity_warning:' || r.user_id || ':' || to_char(r.last_at, 'YYYYMMDDHH24'));
      update staff_profiles set inactive_warned_at = p_now where user_id = r.user_id;
      n_warn := n_warn + 1;
    end if;
  end loop;
  return format('%s warned, %s locked for inactivity', n_warn, n_lock);
end $$;

create function app.staff_unlock(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_user uuid := nullif(p ->> 'user_id', '')::uuid;
begin
  perform app.assert_admin(p_by);
  update staff_profiles set inactive_locked_at = null, inactive_unlocked_at = now(), inactive_unlocked_by = p_by, inactive_warned_at = null, last_seen_at = now()
   where user_id = v_user and inactive_locked_at is not null;
  if not found then raise exception 'That account is not locked' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'staff_unlocked', 'staff_profiles', v_user::text, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'user_id', v_user);
end $$;

-- the staff list's sign-in facts (Admin)
create function app.staff_access_facts(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_object_agg(sp.user_id::text, jsonb_build_object('last_sign_in_at', u.last_sign_in_at, 'last_active_at', app.staff_last_active(sp),
           'locked_at', sp.inactive_locked_at, 'preferred_name', nullif(btrim(u.greeting_name), '')))
    from staff_profiles sp join users u on u.id = sp.user_id), '{}'::jsonb);
end $$;

-- ================================================================ 6. standard pay from the role's own pay
create function app.pay_text_cents(p_text text) returns bigint
language sql immutable as $$
  select case when m is null then null else round(replace(m[1], ',', '')::numeric * 100)::bigint end
    from (select regexp_match(coalesce(p_text, ''), '(?:US|CA|C)?\$\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)') m) x
$$;

-- the role a function hires for: the application's role when it is that function's, else the open role of that function
create function app.hire_role_for(p_path text, p_role uuid) returns hiring_roles
language sql stable security definer set search_path = public, app as $$
  select r.* from hiring_roles r
   where app.hire_default_path(r) = p_path
   order by (r.id = p_role) desc, r.active desc, r.updated_at desc
   limit 1
$$;

alter function app.hire_standard_pay(text, uuid) rename to hire_standard_pay_pre1060;
create function app.hire_standard_pay(p_path text, p_role uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r hiring_roles := app.hire_role_for(p_path, p_role);
  v jsonb;
  v_cents bigint;
  v_cur text;
begin
  v := app.hire_standard_pay_pre1060(p_path, r.id);
  if p_path in ('sales_in_person', 'sales_remote') or r.id is null then return v; end if;
  v_cents := coalesce(r.pay_min_cents, app.pay_text_cents(r.pay_text));
  if v_cents is null or v_cents <= 0 then return v; end if;
  v_cur := coalesce(r.pay_currency, case when r.pay_text ~ '^\s*US' then 'USD' when r.pay_text ~ '^\s*C' then 'CAD' end, v ->> 'currency');
  return jsonb_build_object('basis', v ->> 'basis', 'cents', v_cents, 'currency', v_cur,
    'text', format('%s %s %s', v_cur, to_char(v_cents / 100.0, 'FM999990.00'), case when v ->> 'basis' = 'hourly' then 'an hour' else 'a month' end),
    'from_role', r.slug);
end $$;
select pg_temp.copy_grants('app.hire_standard_pay(text, uuid)'::regprocedure, 'app.hire_standard_pay_pre1060(text, uuid)'::regprocedure);

-- ================================================================ 7. closed roles and the referral to Sales
-- the Sales role an applicant of this role is sent to: remote Sales for a remote role, in-person Sales otherwise
create function app.hiring_sales_for(r hiring_roles) returns hiring_roles
language sql stable security definer set search_path = public, app as $$
  select s.* from hiring_roles s
   where s.active and s.va_function = 'sales' and s.id <> r.id
   order by (coalesce(s.work_mode, case when s.remote then 'remote' else 'in_person' end) = case when r.remote then 'remote' else 'in_person' end) desc, s.sort_order
   limit 1
$$;

-- a role's page when the role is closed (filled): the Sales role to apply for instead
create function public.server_hiring_closed_role(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('slug', r.slug, 'title', r.title, 'short_title', r.short_title, 'remote', r.remote,
           'sales', (select jsonb_build_object('slug', s.slug, 'title', s.title, 'summary', s.summary, 'pay_text', s.pay_text, 'remote', s.remote)
                       from app.hiring_sales_for(r) s where s.id is not null))
    from hiring_roles r where r.slug = p_slug and not r.active
$$;

alter function app.hiring_screen(uuid) rename to hiring_screen_pre1060;
create function app.hiring_screen(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  r hiring_roles;
begin
  select * into a from job_applications where id = p_id;
  select * into r from hiring_roles where id = a.role_id;
  if coalesce((app.settings()).hiring_refer_va_to_sales, false) and r.va_function in ('cs', 'fleet', 'finance') and a.status = 'new' then
    return app.hiring_refer_sales(a);
  end if;
  return app.hiring_screen_pre1060(p_id);
end $$;
select pg_temp.copy_grants('app.hiring_screen(uuid)'::regprocedure, 'app.hiring_screen_pre1060(uuid)'::regprocedure);

-- one applicant of a customer service, fleet or finance role sent to Sales with the referral email (0173's), once
create function app.hiring_refer_sales(a job_applications) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r hiring_roles;
  t hiring_roles;
begin
  select * into r from hiring_roles where id = a.role_id;
  t := app.hiring_sales_for(r);
  if t.id is null then return app.hiring_screen_pre1060(a.id); end if;
  if exists (select 1 from job_applications x where x.role_id = t.id and lower(x.email) = lower(a.email) and x.id <> a.id and x.purged_at is null) then
    update job_applications set status = 'below_bar', screened_at = coalesce(screened_at, now()), updated_at = now(),
           note = concat_ws(E'\n', note, format('Already applied for %s: no referral sent.', t.short_title)) where id = a.id;
    return jsonb_build_object('outcome', 'received');
  end if;
  update job_applications set status = 'referred', referred_role_id = t.id, screened_at = coalesce(screened_at, now()), decided_at = now(), updated_at = now()
   where id = a.id returning * into a;
  perform app.hiring_emit('applicant_referred', a, jsonb_build_object('reason_text', format('The %s role is filled', r.short_title), 'other_role_title', t.title, 'other_role_summary', t.summary,
    'apply_url', app.hiring_url('/careers/' || t.slug || '/apply?ref=' || a.token || '&src=referral'), 'alt_role_title', '', 'alt_apply_url', ''), 'applicant_referred:' || a.id);
  return jsonb_build_object('outcome', 'referred', 'other_role', t.slug, 'other_title', t.title, 'token', a.token);
end $$;

-- the applicants of those roles not hired, not referred and not decided yet: referred by the hiring job (a few a run)
create function app.hiring_refer_waiting(p_limit integer default 20) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  n integer := 0;
begin
  if not coalesce((app.settings()).hiring_refer_va_to_sales, false) then return 0; end if;
  for a in select j.* from job_applications j join hiring_roles r on r.id = j.role_id
            where r.va_function in ('cs', 'fleet', 'finance') and j.purged_at is null and j.hired_user_id is null and j.referred_role_id is null
              and j.status in ('new', 'below_bar', 'invited') and nullif(btrim(coalesce(j.email, '')), '') is not null
              and not exists (select 1 from ai_interviews i where i.application_id = j.id and i.state in ('started', 'submitted', 'scored'))
            order by j.created_at limit p_limit for update of j skip locked loop
    perform app.hiring_refer_sales(a);
    n := n + 1;
  end loop;
  return n;
end $$;

alter function app.job_hiring(timestamptz) rename to job_hiring_pre1060;
create function app.job_hiring(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.job_hiring_pre1060(p_now) || jsonb_build_object('referred_to_sales', app.hiring_refer_waiting(20),
    'agreements', app.job_staff_agreements(p_now), 'inactivity', app.job_staff_inactivity(p_now));
end $$;
select pg_temp.copy_grants('app.job_hiring(timestamptz)'::regprocedure, 'app.job_hiring_pre1060(timestamptz)'::regprocedure);

-- ================================================================ 8. AI interviews for every role
create or replace function app.ai_interview_applies(a job_applications) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).hiring_ai_interviews, false)
     and exists (select 1 from hiring_roles r where r.id = a.role_id and ((r.remote and r.staff_kind = 'va') or coalesce((app.settings()).hiring_ai_all_roles, false)))
$$;

-- the 0380 questions, with the in-person roles' own: their work, getting to Toronto, the driving record
alter function app.ai_interview_questions(uuid) rename to ai_interview_questions_pre1060;
create function app.ai_interview_questions(p_role uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r hiring_roles;
  q jsonb := app.ai_interview_questions_pre1060(p_role);
  v jsonb := '[]'::jsonb;
  x jsonb;
begin
  select * into r from hiring_roles where id = p_role;
  if r.remote then return q; end if;
  for x in select e from jsonb_array_elements(q) e loop
    x := case x ->> 'key'
      when 'skills' then x || jsonb_build_object('text', case when r.staff_kind = 'field'
        then 'Tell me about your driving and car care: what you have driven, any cleaning or detailing you have done, and how you check a car before you hand it to someone.'
        else 'Tell me about something you sold in person. How did you meet the customer, and how did you close the sale?' end)
      when 'social' then case when r.staff_kind = 'field'
        then x || jsonb_build_object('text', 'Tell me about a time something went wrong on a job, for example a late customer or a problem with a car. What did you do?')
        else x end
      when 'internet' then x || jsonb_build_object('text', 'How do you get around Toronto for work, and what do you do if your ride or transit fails on a work day? Do you hold a full Ontario G licence, and is your driving record clean?')
      else x end;
    v := v || x;
  end loop;
  return v;
end $$;
select pg_temp.copy_grants('app.ai_interview_questions(uuid)'::regprocedure, 'app.ai_interview_questions_pre1060(uuid)'::regprocedure);

select pg_temp.patch_fn('app.hiring_ai_new_link(uuid, jsonb)'::regprocedure,
  'if not exists (select 1 from hiring_roles r where r.id = a.role_id and r.remote and r.staff_kind = ''va'') then',
  'if not app.ai_interview_applies(a) then');

create or replace function app.hiring_waiting_by_role() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', r.slug, 'title', r.title, 'short_title', r.short_title, 'count', x.n) order by r.sort_order, r.title), '[]'::jsonb)
    from hiring_roles r
    join lateral (select count(*)::int n from job_applications j where j.role_id = r.id and j.status = 'invited' and j.purged_at is null
                     and not exists (select 1 from ai_interviews i where i.application_id = j.id and i.state in ('sent', 'started', 'expired'))) x on x.n > 0
   where not app.hiring_open_slots(r.id)
     and not (coalesce((app.settings()).hiring_ai_interviews, false) and ((r.remote and r.staff_kind = 'va') or coalesce((app.settings()).hiring_ai_all_roles, false)))
$$;

-- the scoring knows the in-person roles (their "internet" topic is getting around and the licence)
alter function public.server_ai_interviews_due(integer) rename to server_ai_interviews_due_pre1060;
create function public.server_ai_interviews_due(p_limit integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select public.server_ai_interviews_due_pre1060(p_limit) || jsonb_build_object('in_person_roles', coalesce((select jsonb_agg(r.slug) from hiring_roles r where not r.remote), '[]'::jsonb))
$$;
select pg_temp.copy_grants('public.server_ai_interviews_due(integer)'::regprocedure, 'public.server_ai_interviews_due_pre1060(integer)'::regprocedure);

-- ================================================================ 9. auto-hire for Sales
create table if not exists hiring_auto_hires (
  application_id uuid primary key references job_applications (id) on delete cascade,
  score          integer not null,
  mark           integer not null,
  ok             boolean,
  error          text,
  tried_at       timestamptz not null default now(),
  done_at        timestamptz
);
comment on table hiring_auto_hires is 'Sales applicants hired by themselves (1060): the AI interview score, the mark, and how it went.';
alter table hiring_auto_hires enable row level security;
revoke all on hiring_auto_hires from anon, authenticated;
grant all on hiring_auto_hires to service_role;

create function app.hire_auto_mark(r hiring_roles) returns integer
language sql stable security definer set search_path = public, app as $$
  select least(coalesce((app.settings()).hiring_auto_hire_mark, r.pass_mark), 100)
$$;

create function public.server_hire_auto_due(p_limit integer default 3) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('actor', app.system_admin(), 'applications', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'score', i.interview_score, 'mark', app.hire_auto_mark(r),
             'function', case when coalesce(r.work_mode, case when r.remote then 'remote' else 'in_person' end) = 'remote' then 'sales_remote' else 'sales_in_person' end))
      from (select a.* from job_applications a join hiring_roles r on r.id = a.role_id join ai_interviews i on i.application_id = a.id
             where coalesce((app.settings()).hiring_auto_hire_sales, false) and r.va_function = 'sales' and i.state = 'scored'
               and i.interview_score >= app.hire_auto_mark(r) and coalesce(i.recommendation, '') <> 'decline'
               and cardinality(a.knockouts) = 0 and a.status in ('interviewed', 'invited') and a.hired_user_id is null and a.purged_at is null
               and nullif(btrim(coalesce(a.email, '')), '') is not null
               and not exists (select 1 from hiring_auto_hires h where h.application_id = a.id)
             order by i.scored_at limit greatest(p_limit, 1)) a
      join hiring_roles r on r.id = a.role_id join ai_interviews i on i.application_id = a.id), '[]'::jsonb))
$$;

create function public.server_hire_auto_done(p_app uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
begin
  select * into a from job_applications where id = p_app;
  if a.id is null then return jsonb_build_object('ok', false); end if;
  insert into hiring_auto_hires (application_id, score, mark, ok, error, done_at)
  values (a.id, coalesce(nullif(p ->> 'score', '')::int, 0), coalesce(nullif(p ->> 'mark', '')::int, 0), v_ok, left(p ->> 'error', 300), now())
  on conflict (application_id) do update set ok = excluded.ok, error = excluded.error, done_at = now();
  if v_ok then
    perform app.staff_alert('hire_auto', 'job_application', a.id, 'hired', left(format('Hired by itself: %s (Sales)', a.full_name), 140),
      format('AI interview score %s, the auto-hire mark %s. Their account, agreement, academy and welcome are on their way.', p ->> 'score', p ->> 'mark'),
      jsonb_build_object('path_admin', '/admin/hiring/' || a.id));
  else
    perform app.raise_task(p_type => 'hire_auto_failed', p_queue => 'admin', p_priority => 'high',
      p_title => left(format('Auto-hire of %s did not go through', a.full_name), 200), p_detail => left(coalesce(p ->> 'error', 'Unknown error') || '. Hire them from Hiring.', 600),
      p_related_table => 'job_applications', p_related_id => a.id, p_dedupe => 'hire_auto_failed:' || a.id);
  end if;
  return jsonb_build_object('ok', true);
end $$;
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('hire_auto_failed', 'admin', 'An auto-hire did not go through', 'high', 'none', null, 'A Sales applicant met the auto-hire mark but one-step Hire failed (1060). Hire them from Hiring.')
on conflict (task_type) do nothing;

-- the interviews job has work when an auto-hire or a staff agreement waits
create function app.k_jobs_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'agreements_staff', exists (select 1 from app.staff_agreements_due_rows(1)),
    'hire_auto', coalesce((app.settings()).hiring_auto_hire_sales, false) and exists (select 1 from ai_interviews i join job_applications a on a.id = i.application_id
                   join hiring_roles r on r.id = a.role_id where i.state = 'scored' and r.va_function = 'sales' and a.hired_user_id is null
                   and not exists (select 1 from hiring_auto_hires h where h.application_id = a.id) and i.interview_score >= app.hire_auto_mark(r)))
$$;

alter function app.server_jobs_due() rename to server_jobs_due_pre1060;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.server_jobs_due_pre1060();
  k jsonb := app.k_jobs_due();
begin
  return j || jsonb_build_object('agreements', coalesce((j ->> 'agreements')::boolean, false) or (k ->> 'agreements_staff')::boolean,
                                 'interviews', coalesce((j ->> 'interviews')::boolean, false) or (k ->> 'hire_auto')::boolean);
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre1060()'::regprocedure);

-- ================================================================ 10. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1060;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'ops_read' and p_name = 'staff_agreements_status') or (p_call = 'admin_do' and p_name in ('staff_agreement_waive', 'staff_unlock'))
     or (p_call = 'admin_read' and p_name = 'staff_access_facts') then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return case p_name
      when 'staff_agreements_status' then app.staff_agreements_status(p_user, p_)
      when 'staff_agreement_waive' then app.staff_agreement_waive(p_user, p_)
      when 'staff_unlock' then app.staff_unlock(p_user, p_)
      else app.staff_access_facts(p_user, p_) end;
  end if;
  if p_call = 'ops_do' and p_name in ('staff_preferred_name_save', 'staff_team_joined') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'staff_preferred_name_save' then app.staff_preferred_name_save(p_user, p_) else app.staff_team_joined(p_user, p_) end;
  end if;
  return app.door_pre1060(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1060(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ the emails
-- CATALOGUE 1060 START (generated by supabase/seed/1060_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_agreement_reminder', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Reminder: please sign your CarmaCars staff agreement', 'It takes a few minutes, in your staff portal.', '3 days after the agreement was sent, once', 'A staff member''s staff agreement has waited 3 days for their signature (migration 1060). Sent once to that staff member. The agreement opens for signing once their academy is passed.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"sign_url","type":"url"}]'::jsonb, 'templates/staff_agreement_reminder.html', 'templates/staff_agreement_reminder.txt'),
  ('staff_inactivity_warning', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars staff account locks on {{lock_on}}', 'Sign in before then to keep it open.', 'On the warning day, once', 'A staff account (never an Admin) has had no sign-in or use of the staff portal for the warning days of Program settings (7 by default; migration 1060). Sent once per idle stretch.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"days_idle","type":"string"},{"name":"first_name","type":"string"},{"name":"lock_days","type":"string"},{"name":"lock_on","type":"string"},{"name":"sign_in_url","type":"url"}]'::jsonb, 'templates/staff_inactivity_warning.html', 'templates/staff_inactivity_warning.txt'),
  ('staff_team_group', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'You are in: join the {{group_name}} WhatsApp group', 'The team talks there every day.', 'Immediate, once', 'A new staff member has passed the academy and signed their staff agreement, and a WhatsApp group link is set in Program settings (migration 1060). Sent once: Sales staff get the Sales group, customer service, fleet, finance and field staff the team group (both when they do both).', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"group_name","type":"string"},{"name":"group_url","type":"url"},{"name":"second_group_name","type":"string"},{"name":"second_group_url","type":"url"}]'::jsonb, 'templates/staff_team_group.html', 'templates/staff_team_group.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 1060 END

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['staff_agreement_kind', 'staff_agreement_signed', 'staff_is_member', 'agreement_locked', 'inactive_locked',
                     'staff_groups', 'staff_agreement_state', 'my_roles_pre1060', 'staff_welcome_pre1060', 'staff_welcome', 'staff_preferred_name_save', 'staff_team_joined',
                     'system_admin', 'staff_agreements_due_rows', 'job_staff_agreements', 'staff_agreements_status', 'staff_agreement_waive', 'staff_last_active',
                     'staff_touch', 'job_staff_inactivity', 'staff_unlock', 'staff_access_facts', 'pay_text_cents', 'hire_role_for', 'hire_standard_pay_pre1060',
                     'hiring_sales_for', 'hiring_screen_pre1060', 'hiring_refer_sales', 'hiring_refer_waiting', 'job_hiring_pre1060', 'ai_interview_questions_pre1060',
                     'hire_auto_mark', 'k_jobs_due', 'server_jobs_due_pre1060', 'door_pre1060']))
               or (n.nspname = 'public' and p.proname = any (array['server_staff_agreements_due', 'server_staff_agreement_auto_done', 'server_signed_in',
                     'server_hiring_closed_role', 'server_ai_interviews_due_pre1060', 'server_hire_auto_due', 'server_hire_auto_done']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
