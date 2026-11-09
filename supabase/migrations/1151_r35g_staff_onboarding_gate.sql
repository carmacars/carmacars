-- 1151_r35g_staff_onboarding_gate.sql
-- Release 35, part G (helper G), task B: staff have no working access until they are fully onboarded. The owner: "staff that
-- are onboarded only have access to everything if they have signed the agreement and if they have confirmed that they have
-- joined the whatsapp ... a lead was given to harman but idk who that is and that lead should be opened back up for syed".
-- Then: strict and in order, no grace period, existing staff included from deploy.
--   1. The steps, in order, each opening only after the one before: (1) the academy passed (or waived by an Admin), (2) the
--      staff agreement signed (or waived), (3) the WhatsApp groups joined and confirmed by the staff member, one checkbox a
--      group: Sales staff the Sales group and the Team group, everyone else the Team group (an Admin may mark it or take it
--      back, one person or every signed person at once). app.staff_onboarding_state says where a person is.
--   2. One helper: app.staff_fully_onboarded(uid): an Admin, a test or verify account (app.staff_is_test, so the live
--      verification accounts keep working), a person exempted (staff_profiles.onboarding_exempt), or a staff member whose three
--      steps are done (kept in staff_profiles.onboarding_done, refreshed by triggers on every input, so the role checks stay
--      cheap). Program settings staff_onboarding_gate (on) switches it off.
--   3. Enforced in the database: the role checks every policy and function uses (app.user_is_staff, app.user_va_has,
--      app.is_field_person, so app.user_is_field; app.va_has, so app.is_va and app.is_staff; app.is_field) are false for a
--      staff member who is not fully onboarded, and the door refuses every call but the onboarding screens' own (Welcome, the
--      academy, the profile, the documents to sign, pay details) with "Finish your onboarding first". Inside those calls (and
--      while my_roles reads the person's roles for the portal) the checks see the person as they are (app.onboarding_pass).
--      app.my_roles adds onboarding_locked and onboarding_step for the portal (Welcome only until done).
--   4. Leads never go to a staff member who is not fully onboarded: an assignment to one is moved (to the salesperson who
--      had or brought the lead, else to the pool), a claim by one is refused, and an Admin cannot reassign to one. Every lead
--      held now by such a person is returned at once (this migration), and again whenever a person stops being onboarded
--      (an Admin takes the WhatsApp confirmation back): to the salesperson who brought it (leads.sourced_by) or who last had
--      it (lead_claim_log), when they are onboarded Sales, else to the pool. Each move is a lead event (lead_claim_log,
--      action return or release). Admin: Return lead to previous owner on a lead (lead_return).
-- The existing inactivity lock (1060: no sign-in for 10 days, counted from the account's creation when they never signed
-- in, locked by the hiring job, unlocked by an Admin) stays as it is, alongside.
-- No applied migration is edited: the role checks and lead_reassign are patched in place (their grants and the policies that
-- name them stay); my_roles, staff_team_joined and the door are wrapped or replaced.
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
  if position(p_old in d) = 0 then raise exception '1151: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings and columns
alter table program_settings add column if not exists staff_onboarding_gate boolean not null default true;
comment on column program_settings.staff_onboarding_gate is 'Staff onboarding gate (1151): a staff member opens nothing but onboarding until the academy is passed, the agreement signed and the WhatsApp groups confirmed.';

alter table staff_profiles
  add column if not exists whatsapp_joined text[] not null default '{}',
  add column if not exists whatsapp_joined_at timestamptz,
  add column if not exists whatsapp_marked_by uuid references users (id),
  add column if not exists onboarding_exempt boolean not null default false,
  add column if not exists onboarding_done boolean not null default false;
comment on column staff_profiles.whatsapp_joined is 'The WhatsApp groups the staff member confirmed they joined (1151): sales, team. Sales staff need both, everyone else team.';
comment on column staff_profiles.whatsapp_marked_by is 'Set when an Admin marked (or took back) the WhatsApp confirmation for the person (1151); empty when they confirmed it themselves.';
comment on column staff_profiles.onboarding_exempt is 'Never held by the onboarding gate (1151). Test and verify accounts are exempt by app.staff_is_test without it.';
comment on column staff_profiles.onboarding_done is 'Kept by triggers (1151): the academy passed, the agreement signed and the WhatsApp groups confirmed. Read by app.staff_fully_onboarded.';

alter table lead_claim_log drop constraint if exists lead_claim_log_action_check;
alter table lead_claim_log add constraint lead_claim_log_action_check check (action in ('claim', 'extend', 'unclaim', 'expire', 'reassign', 'release', 'return'));
comment on column lead_claim_log.action is 'claim, extend, unclaim, expire, reassign, release; return (1151): the lead went back to the salesperson who had or brought it (user_id), from a person not fully onboarded or by an Admin.';

-- ================================================================ 1. the steps
create function app.staff_required_groups(p_functions text[]) returns text[]
language sql immutable as $$
  select case when 'sales' = any (coalesce(p_functions, '{}')) then array['sales', 'team'] else array['team'] end
$$;

-- the WhatsApp groups of a person with their names, links (empty until set in Program settings) and whether confirmed
create function app.staff_group_list(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', g, 'name', case g when 'sales' then 'CARMA Closers' else 'CarmaCars Team' end,
           'url', case g when 'sales' then (app.settings()).whatsapp_sales_group_url else (app.settings()).whatsapp_team_group_url end,
           'joined', g = any (sp.whatsapp_joined)) order by g), '[]'::jsonb)
    from staff_profiles sp, unnest(app.staff_required_groups(sp.functions)) g where sp.user_id = p_user
$$;

-- where a person is: academy, agreement, whatsapp, then done (each step only after the one before)
create function app.staff_onboarding_state(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  sp staff_profiles;
  v_prev text := coalesce(current_setting('app.onboarding_pass', true), '');
  v_academy boolean;
  v_agreement boolean;
  v_whatsapp boolean;
  v_req text[];
begin
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null then return jsonb_build_object('member', false, 'done', true, 'step', 'done'); end if;
  -- the person as they are (not as the gate shows them) while the academy paths are worked out
  perform set_config('app.onboarding_pass', p_user::text, true);
  v_academy := not coalesce(s.academy_gate, false) or app.academy_done(p_user) or app.academy_waived(p_user);
  perform set_config('app.onboarding_pass', v_prev, true);
  v_agreement := not coalesce(s.staff_agreement_gate, false) or sp.agreement_waived_at is not null or app.staff_agreement_signed(p_user);
  v_req := app.staff_required_groups(sp.functions);
  v_whatsapp := v_req <@ sp.whatsapp_joined;
  return jsonb_build_object('member', true, 'academy', v_academy, 'agreement', v_agreement, 'whatsapp', v_whatsapp,
    'required', to_jsonb(v_req), 'joined', to_jsonb(sp.whatsapp_joined), 'whatsapp_joined_at', sp.whatsapp_joined_at, 'marked_by', sp.whatsapp_marked_by,
    'exempt', sp.onboarding_exempt or app.staff_is_test(p_user),
    'step', case when not v_academy then 'academy' when not v_agreement then 'agreement' when not v_whatsapp then 'whatsapp' else 'done' end,
    'done', v_academy and v_agreement and v_whatsapp);
end $$;

-- THE helper: may this person use the staff side at all?
create function app.staff_fully_onboarded(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is null
      or not coalesce((app.settings()).staff_onboarding_gate, false)
      or app.user_is_admin(p_user)
      or coalesce((select sp.onboarding_exempt or sp.onboarding_done from staff_profiles sp where sp.user_id = p_user), true)
      or app.staff_is_test(p_user)
$$;
comment on function app.staff_fully_onboarded(uuid) is 'The staff onboarding gate (1151): true for an Admin, someone with no staff record, a test or verify account, an exempt person, or a staff member with the academy passed, the agreement signed and the WhatsApp groups confirmed. The role checks and the lead routing use it.';

-- the role checks: the gate, or the person as they are inside an onboarding call (set by the door and my_roles only)
create function app.staff_gate_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is null or coalesce(current_setting('app.onboarding_pass', true), '') = p_user::text or app.staff_fully_onboarded(p_user)
$$;

-- ================================================================ 4. the leads (defined before the refresh, which returns leads)
-- the salesperson a lead goes back to: who brought it, else who last had it; onboarded Sales only; never p_exclude
create function app.lead_previous_owner(p_lead uuid, p_exclude uuid default null) returns uuid
language sql stable security definer set search_path = public, app as $$
  select x.u from (
    select l.sourced_by u, 0 pri, null::timestamptz at, 0::bigint hid from leads l where l.id = p_lead and l.sourced_by is not null
    union all
    select h.user_id, 1, h.at, h.id from lead_claim_log h where h.lead_id = p_lead and h.action in ('claim', 'extend', 'reassign', 'return')) x
   where x.u is distinct from p_exclude and app.staff_fully_onboarded(x.u) and app.user_va_has(x.u, 'sales') and not app.staff_is_test(x.u)
   order by x.pri, x.at desc nulls last, x.hid desc
   limit 1
$$;

-- move one lead off its holder: to the previous salesperson (assigned and claimed) or to the pool; logged on the lead
create function app.lead_return_do(p_lead uuid, p_by uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  c lead_claims;
  v_from uuid;
  v_to uuid;
  s sales_lead_settings := app.sl_settings();
  v_win integer;
begin
  select * into l from leads where id = p_lead for update;
  if l.id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  select * into c from lead_claims where lead_id = l.id and expires_at > now();
  v_from := coalesce(c.claimed_by, l.assigned_to);
  if v_from is null then raise exception 'Nobody holds this lead: it is in the pool' using errcode = '23514'; end if;
  v_to := app.lead_previous_owner(l.id, v_from);
  delete from lead_claims where lead_id = l.id;
  insert into lead_claim_log (lead_id, user_id, action, by_user, note) values (l.id, v_from, 'release', p_by, left(p_note, 300));
  if v_to is not null then
    v_win := app.sl_window(app.sl_type(l));
    insert into lead_claims (lead_id, claimed_by, claimed_at, expires_at, cap_at)
    values (l.id, v_to, now(), now() + make_interval(mins => v_win), now() + make_interval(mins => greatest(v_win, coalesce(s.extend_max_minutes, 60))));
    insert into lead_claim_log (lead_id, user_id, action, by_user, note) values (l.id, v_to, 'return', p_by, left(format('Returned from %s', app.sl_name(v_from)), 300));
  end if;
  perform set_config('app.lead_return', 'on', true);
  update leads set assigned_to = v_to, updated_at = now() where id = l.id;
  perform set_config('app.lead_return', '', true);
  return jsonb_build_object('lead', l.id, 'from', v_from, 'to', v_to, 'to_name', case when v_to is null then null else app.sl_name(v_to) end);
end $$;

-- every open lead held (assigned or claimed) by a staff member who is not fully onboarded: returned. p_user: only theirs.
create function app.leads_return_unonboarded(p_by uuid default null, p_user uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select l.id from leads l left join lead_claims c on c.lead_id = l.id and c.expires_at > now()
     where l.handled_at is null and l.status not in ('converted', 'closed', 'spam')
       and coalesce(c.claimed_by, l.assigned_to) is not null
       and (p_user is null or coalesce(c.claimed_by, l.assigned_to) = p_user)
       and app.staff_is_member(coalesce(c.claimed_by, l.assigned_to)) and not app.staff_fully_onboarded(coalesce(c.claimed_by, l.assigned_to))
     order by l.created_at
  loop
    perform app.lead_return_do(r.id, p_by, 'Not fully onboarded (academy, agreement and WhatsApp): the lead went back');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ the kept flag and its triggers
create function app.staff_onboarding_refresh(p_user uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v_was boolean;
  v_now boolean;
begin
  select onboarding_done into v_was from staff_profiles where user_id = p_user;
  if not found then return null; end if;
  v_now := coalesce((app.staff_onboarding_state(p_user) ->> 'done')::boolean, false);
  if v_now is distinct from v_was then
    update staff_profiles set onboarding_done = v_now where user_id = p_user;
    -- no longer onboarded (an Admin took a step back): their leads go back now
    if v_was and not v_now then perform app.leads_return_unonboarded(null, p_user); end if;
  end if;
  return v_now;
end $$;

create function app.staff_onboarding_refresh_all() returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  for r in select user_id from staff_profiles loop perform app.staff_onboarding_refresh(r.user_id); n := n + 1; end loop;
  return n;
end $$;

create function app.staff_onboarding_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := case when TG_OP = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_user uuid := nullif(case when TG_TABLE_NAME = 'sign_requests' then r ->> 'staff_user_id' else r ->> 'user_id' end, '')::uuid;
begin
  if v_user is not null then perform app.staff_onboarding_refresh(v_user); end if;
  return null;
end $$;

create function app.staff_onboarding_all_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.staff_onboarding_refresh_all();
  return null;
end $$;

create trigger staff_profiles_onboarding after insert or update of whatsapp_joined, agreement_waived_at, functions, onboarding_exempt, is_active, sales_opt_in_at on staff_profiles
  for each row execute function app.staff_onboarding_trg();
create trigger sign_requests_onboarding after insert or update of status on sign_requests
  for each row when (new.staff_user_id is not null and new.doc_type = 'staff_agreement') execute function app.staff_onboarding_trg();
create trigger academy_attempts_onboarding after insert or update on academy_attempts for each row execute function app.staff_onboarding_trg();
create trigger academy_waivers_onboarding after insert or update or delete on academy_waivers for each row execute function app.staff_onboarding_trg();
create trigger user_roles_onboarding after insert or delete on user_roles for each row execute function app.staff_onboarding_trg();
create trigger academy_path_sections_onboarding after insert or update or delete on academy_path_sections for each statement execute function app.staff_onboarding_all_trg();
create trigger program_settings_onboarding after update of academy_gate, staff_agreement_gate on program_settings for each statement execute function app.staff_onboarding_all_trg();

-- ================================================================ 3. the role checks
select pg_temp.patch_fn('app.user_is_staff(uuid)'::regprocedure,
  'where r.user_id = p_user and r.role = ''va'' and u.status = ''active'')',
  'where r.user_id = p_user and r.role = ''va'' and u.status = ''active'') and app.staff_gate_ok(p_user)');
select pg_temp.patch_fn('app.user_va_has(uuid, text[])'::regprocedure,
  'else p_functions end)',
  'else p_functions end) and app.staff_gate_ok(p_user)');
select pg_temp.patch_fn('app.is_field_person(uuid)'::regprocedure,
  'where r.user_id = p_user and r.role = ''field'' and u.status = ''active'')',
  'where r.user_id = p_user and r.role = ''field'' and u.status = ''active'') and app.staff_gate_ok(p_user)');
select pg_temp.patch_fn('app.va_has(text[])'::regprocedure,
  'and app.staff_two_step_ok()', 'and app.staff_two_step_ok() and app.staff_gate_ok(app.uid())');
select pg_temp.patch_fn('app.is_field()'::regprocedure,
  'and app.staff_two_step_ok()', 'and app.staff_two_step_ok() and app.staff_gate_ok(app.uid())');

-- the portal's roles: read as the person is, plus where they are in onboarding
alter function app.my_roles(uuid) rename to my_roles_pre1151;
create function app.my_roles(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_prev text := coalesce(current_setting('app.onboarding_pass', true), '');
  v jsonb;
  st jsonb;
begin
  if p_user is not null then perform set_config('app.onboarding_pass', p_user::text, true); end if;
  v := app.my_roles_pre1151(p_user);
  perform set_config('app.onboarding_pass', v_prev, true);
  if p_user is null or not app.staff_is_member(p_user) or app.staff_fully_onboarded(p_user) then
    return v || jsonb_build_object('onboarding_locked', false, 'onboarding_step', 'done');
  end if;
  st := app.staff_onboarding_state(p_user);
  return v || jsonb_build_object('onboarding_locked', true, 'onboarding_step', st ->> 'step');
end $$;
select pg_temp.copy_grants('app.my_roles(uuid)'::regprocedure, 'app.my_roles_pre1151(uuid)'::regprocedure);

-- ================================================================ 1. the WhatsApp step: the staff member, then the Admin
-- p {sales?: bool, team?: bool} (or {groups: [...]}): the groups they confirm they joined; only once the agreement is done
create function app.staff_whatsapp_confirm(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  sp staff_profiles;
  st jsonb := app.staff_onboarding_state(p_user);
  v_req text[];
  v_new text[];
begin
  select * into sp from staff_profiles where user_id = p_user for update;
  if sp.user_id is null then raise exception 'Staff only' using errcode = '42501'; end if;
  if not coalesce((st ->> 'academy')::boolean, false) then raise exception 'Pass the academy first: the WhatsApp step opens after the academy and the agreement' using errcode = '23514'; end if;
  if not coalesce((st ->> 'agreement')::boolean, false) then raise exception 'Sign your staff agreement first: the WhatsApp step opens after it' using errcode = '23514'; end if;
  v_req := app.staff_required_groups(sp.functions);
  select coalesce(array_agg(distinct g order by g), '{}') into v_new from (
    select unnest(sp.whatsapp_joined) g
    union all select g from unnest(v_req) g where coalesce((p ->> g)::boolean, false) or coalesce(p -> 'groups', '[]'::jsonb) ? g) x
   where g = any (v_req);
  if v_new = sp.whatsapp_joined and not (v_req <@ v_new) then raise exception 'Tick each group you joined' using errcode = '22023'; end if;
  update staff_profiles set whatsapp_joined = v_new, whatsapp_marked_by = null,
         whatsapp_joined_at = case when v_req <@ v_new then coalesce(whatsapp_joined_at, now()) else null end,
         team_group_joined_at = case when v_req <@ v_new then coalesce(team_group_joined_at, now()) else team_group_joined_at end
   where user_id = p_user;
  return jsonb_build_object('joined', to_jsonb(v_new), 'done', v_req <@ v_new, 'onboarded', app.staff_fully_onboarded(p_user));
end $$;

-- 1060's "I joined" (one button for every group shown): every group of the person, at the same step
create or replace function app.staff_team_joined(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.staff_whatsapp_confirm(p_user, jsonb_build_object('groups', to_jsonb(app.staff_required_groups((select sp.functions from staff_profiles sp where sp.user_id = p_user)))));
end $$;

-- Welcome (1060's steps): the team step is the WhatsApp step (every group of the person, link or not, with its checkbox
-- state), open once the academy and the agreement are done; the page stays locked until the person is fully onboarded
alter function app.staff_welcome(uuid) rename to staff_welcome_pre1151;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_welcome_pre1151(p_user);
  st jsonb := app.staff_onboarding_state(p_user);
  v_open boolean := coalesce((st ->> 'academy')::boolean and (st ->> 'agreement')::boolean, true);
  v_steps jsonb := '[]'::jsonb;
  x jsonb;
begin
  for x in select y from jsonb_array_elements(coalesce(v -> 'steps', '[]'::jsonb)) y loop
    if x ->> 'key' = 'team' then
      x := x || jsonb_build_object('done', coalesce((st ->> 'whatsapp')::boolean, true), 'open', v_open,
                 'groups', case when v_open then app.staff_group_list(p_user) else '[]'::jsonb end, 'confirm', true);
    end if;
    v_steps := v_steps || x;
  end loop;
  return v || jsonb_build_object('steps', v_steps, 'onboarding_step', coalesce(st ->> 'step', 'done'),
    'locked', coalesce((v ->> 'locked')::boolean, false) or (app.staff_is_member(p_user) and not app.staff_fully_onboarded(p_user)));
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)'::regprocedure, 'app.staff_welcome_pre1151(uuid)'::regprocedure);

-- Admin: p {user, joined: bool}: mark the person's groups joined, or take it back
create function app.staff_whatsapp_mark(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user', '')::uuid;
  v_joined boolean := coalesce((p ->> 'joined')::boolean, true);
  sp staff_profiles;
begin
  perform app.assert_admin(p_by);
  select * into sp from staff_profiles where user_id = v_user for update;
  if sp.user_id is null then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
  update staff_profiles set whatsapp_joined = case when v_joined then app.staff_required_groups(sp.functions) else '{}' end,
         whatsapp_joined_at = case when v_joined then coalesce(whatsapp_joined_at, now()) end, whatsapp_marked_by = p_by,
         team_group_joined_at = case when v_joined then coalesce(team_group_joined_at, now()) else null end
   where user_id = v_user;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, case when v_joined then 'staff_whatsapp_marked' else 'staff_whatsapp_revoked' end, 'staff_profiles', v_user::text, jsonb_build_object('groups', app.staff_required_groups(sp.functions)));
  return jsonb_build_object('user', v_user, 'joined', v_joined, 'onboarded', app.staff_fully_onboarded(v_user), 'state', app.staff_onboarding_state(v_user));
end $$;

-- Admin: every active staff member with the agreement signed (or waived) and the WhatsApp step not done: marked joined
create function app.staff_whatsapp_mark_all(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  perform app.assert_admin(p_by);
  for r in select sp.user_id from staff_profiles sp
            where sp.is_active and app.staff_is_member(sp.user_id) and not (app.staff_required_groups(sp.functions) <@ sp.whatsapp_joined)
              and coalesce((app.staff_onboarding_state(sp.user_id) ->> 'agreement')::boolean, false) loop
    perform app.staff_whatsapp_mark(p_by, jsonb_build_object('user', r.user_id, 'joined', true));
    n := n + 1;
  end loop;
  return jsonb_build_object('marked', n);
end $$;

-- Admin: every active staff member, where they are in onboarding (not onboarded first)
create function app.staff_onboarding_list(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(x order by (x ->> 'onboarded')::boolean, x ->> 'name') from (
    select jsonb_build_object('user_id', sp.user_id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email), 'functions', to_jsonb(sp.functions),
             'onboarded', app.staff_fully_onboarded(sp.user_id), 'state', app.staff_onboarding_state(sp.user_id), 'groups', app.staff_group_list(sp.user_id),
             'marked_by', (select coalesce(m.full_name, m.email) from users m where m.id = sp.whatsapp_marked_by)) x
      from staff_profiles sp join users u on u.id = sp.user_id
     where sp.is_active and app.staff_is_member(sp.user_id)) y), '[]'::jsonb);
end $$;

-- ================================================================ 4. the leads: the routing
-- an assignment to a staff member who is not fully onboarded goes to the previous salesperson, else to the pool
create function app.leads_assignee_onboarded() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.assigned_to is not null and coalesce(current_setting('app.lead_return', true), '') <> 'on'
     and app.staff_is_member(new.assigned_to) and not app.staff_fully_onboarded(new.assigned_to) then
    new.assigned_to := case when TG_OP = 'UPDATE' and new.id is not null then app.lead_previous_owner(new.id, new.assigned_to) end;
  end if;
  return new;
end $$;
create trigger leads_assignee_onboarded before insert or update of assigned_to on leads for each row execute function app.leads_assignee_onboarded();

create function app.lead_claims_onboarded() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.staff_is_member(new.claimed_by) and not app.staff_fully_onboarded(new.claimed_by) then
    raise exception '% has not finished onboarding (academy, agreement and WhatsApp): leads cannot go to them yet', app.sl_name(new.claimed_by) using errcode = '23514';
  end if;
  return new;
end $$;
create trigger lead_claims_onboarded before insert or update of claimed_by on lead_claims for each row execute function app.lead_claims_onboarded();

select pg_temp.patch_fn('app.lead_reassign(uuid, jsonb)'::regprocedure,
  'if v_to is null or not app.sl_may(v_to)',
  'if v_to is not null and app.staff_is_member(v_to) and not app.staff_fully_onboarded(v_to) then
    raise exception ''% has not finished onboarding (academy, agreement and WhatsApp): leads cannot go to them yet'', app.sl_name(v_to) using errcode = ''23514'';
  end if;
  if v_to is null or not app.sl_may(v_to)');

-- Admin: p {lead}: Return lead to previous owner (the salesperson who brought or last had it, else the pool)
create function app.lead_return(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_lead uuid := nullif(p ->> 'lead', '')::uuid;
begin
  perform app.assert_admin(p_by);
  perform app.sl_expire();
  if not exists (select 1 from leads where id = v_lead) then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  return app.lead_return_do(v_lead, p_by, coalesce(nullif(btrim(left(p ->> 'note', 300)), ''), 'Returned to the previous owner by an Admin'));
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1151;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_held boolean := p_user is not null and app.staff_is_member(p_user) and not app.staff_fully_onboarded(p_user);
begin
  if v_held then
    if p_call = 'roles' or p_name in ('staff_welcome', 'staff_welcome_task', 'staff_team_groups', 'staff_team_joined', 'staff_whatsapp_confirm', 'staff_onboarding_state',
        'staff_preferred_name_save', 'staff_location_save', 'staff_agreement_prepare', 'staff_document', 'staff_document_register', 'staff_licence_register',
        'onboarding_document', 'form_document', 'home_address', 'home_address_save', 'my_pay_details', 'my_pay_details_save', 'my_pay_identity', 'my_pay_identity_save',
        'my_profile', 'my_greeting_save', 'my_staff_digest', 'my_staff_digest_save', 'self_profile', 'profile', 'profile_save', 'name_change_request',
        'notify_channel_set', 'notify_reach', 'sales_state', 'sales_optin', 'help_find', 'help_stuck', 'guide_section_version',
        'academy_home', 'academy_section', 'academy_progress', 'academy_quiz_submit', 'academy_viewed', 'academy_gate_state', 'academy_content') then
      -- an onboarding screen: the person as they are, for this call only
      perform set_config('app.onboarding_pass', p_user::text, true);
    else
      raise exception 'Finish your onboarding first: the academy, your staff agreement, then the WhatsApp groups (Welcome shows the next step)' using errcode = '42501';
    end if;
  end if;
  if p_call in ('ops_read', 'va_read', 'field_read') and p_name = 'staff_onboarding_state' then
    perform app.door_begin(p_user, p_aal);
    return app.staff_onboarding_state(p_user) || jsonb_build_object('groups', app.staff_group_list(p_user));
  end if;
  if p_call in ('ops_do', 'va_do', 'field_do') and p_name = 'staff_whatsapp_confirm' then
    perform app.door_begin(p_user, p_aal);
    return app.staff_whatsapp_confirm(p_user, p_);
  end if;
  if (p_call in ('ops_read', 'admin_read') and p_name = 'staff_onboarding_list')
     or (p_call in ('ops_do', 'admin_do') and p_name in ('staff_whatsapp_mark', 'staff_whatsapp_mark_all', 'lead_return')) then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return case p_name
      when 'staff_onboarding_list' then app.staff_onboarding_list(p_user, p_)
      when 'staff_whatsapp_mark' then app.staff_whatsapp_mark(p_user, p_)
      when 'staff_whatsapp_mark_all' then app.staff_whatsapp_mark_all(p_user, p_)
      else app.lead_return(p_user, p_) end;
  end if;
  return app.door_pre1151(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1151(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ at deploy: no grace (the owner); 1060's "I joined" counts
update staff_profiles sp set whatsapp_joined = app.staff_required_groups(sp.functions), whatsapp_joined_at = sp.team_group_joined_at
 where sp.team_group_joined_at is not null and sp.whatsapp_joined = '{}';
select app.staff_onboarding_refresh_all();
select app.leads_return_unonboarded(null, null);

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['staff_required_groups', 'staff_group_list', 'staff_onboarding_state', 'staff_fully_onboarded', 'staff_gate_ok',
                     'lead_previous_owner', 'lead_return_do', 'leads_return_unonboarded', 'staff_onboarding_refresh', 'staff_onboarding_refresh_all', 'staff_onboarding_trg',
                     'staff_onboarding_all_trg', 'my_roles_pre1151', 'staff_whatsapp_confirm', 'staff_team_joined', 'staff_whatsapp_mark', 'staff_whatsapp_mark_all',
                     'staff_onboarding_list', 'staff_welcome_pre1151', 'leads_assignee_onboarded', 'lead_claims_onboarded', 'lead_return', 'door_pre1151'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
