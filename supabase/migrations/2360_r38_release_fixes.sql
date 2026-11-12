-- 2360: release 38's fixes on top of release 37 (the r37 tables, the owner's staff onboarding asks of November 11).
--   1. Indexes on every join-path foreign key of the r37 tables (99_r35sec's rule; 2252 has the r36b ones).
--   2. channel_bookings is audited like every table that holds a booking (03_flows' rule); channel_calls is a call log (no money,
--      pricing or status) and stays out of the audit. bug_reports: no browser session deletes rows (04_rls' rule; Admins change
--      them through the door).
--   3. A sale's "Who found this client?" for a person who can never be credited (2330: customer service, Fleet, Finance): their
--      first offer no longer stops on the question; the booking is recorded "Entered for CarmaCars".
--   4. Staff onboarding (the owner, 20:19: "I should be able to mark people as in the WhatsApp without automatically saying that
--      they have finished the academy and signed the agreement"): the WhatsApp confirmation is an independent fact. An Admin (or
--      the person) marks it or takes it back at any step; it records only the groups, who and when, never the academy or the
--      agreement. The gate order stays academy, agreement, WhatsApp, approval: a WhatsApp marked early counts when the person
--      reaches that step. The approval is asked (Fleet To do, alert) only once the academy, the agreement and the WhatsApp step
--      are all done, whichever comes last, and never again by itself after a rejection (the person asks again).
--      Every person's state lists exactly what is missing (waiting_on: "Academy (3 of 11 sections)", "Staff agreement signature",
--      "WhatsApp CarmaCars Team group confirmation", "Approval by an Admin or a Fleet VA"), on Admin > Settings > Staff and the
--      Fleet approvals list, which now also lists the people held only by the WhatsApp step. An Admin confirms the WhatsApp groups
--      and approves in one step (staff_whatsapp_approve; audited; never their own).
-- No applied migration is edited: functions are wrapped or patched in place (their grants kept or copied).
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
  if position(p_old in d) = 0 then raise exception '2360: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. foreign key indexes
create index if not exists bug_reports_status_changed_by_idx on bug_reports (status_changed_by);
create index if not exists channel_bookings_partner_id_idx on channel_bookings (partner_id);
create index if not exists channel_calls_key_id_idx on channel_calls (key_id);
create index if not exists channel_calls_partner_id_idx on channel_calls (partner_id);
create index if not exists channel_keys_partner_id_idx on channel_keys (partner_id);
create index if not exists lead_holds_prev_claimed_by_idx on lead_holds (prev_claimed_by);

-- ================================================================ 2. audit and grants
drop trigger if exists audit_channel_bookings on channel_bookings;
create trigger audit_channel_bookings after insert or update or delete on channel_bookings for each row execute function app.audit_row();
revoke delete, truncate on bug_reports from authenticated, anon;

-- ================================================================ 3. no "Who found this client?" for a person never credited
alter function app.offer_sales_choice(uuid, uuid, text) rename to offer_sales_choice_pre2360;
create function app.offer_sales_choice(p_by uuid, p_booking uuid, p_choice text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_choice is null and app.credit_blocked(p_by) then
    update bookings set sales_choice = 'for_carmacars', sales_choice_by = p_by, sales_choice_at = now()
     where id = p_booking and sales_choice is null and sales_claim_by is null;
    return;
  end if;
  perform app.offer_sales_choice_pre2360(p_by, p_booking, p_choice);
end $$;
select pg_temp.copy_grants('app.offer_sales_choice(uuid, uuid, text)'::regprocedure, 'app.offer_sales_choice_pre2360(uuid, uuid, text)'::regprocedure);

-- ================================================================ 4. staff onboarding: WhatsApp independent, what is missing
-- the person confirms their groups at any step (the Welcome page still shows the step after the agreement)
select pg_temp.patch_fn('app.staff_whatsapp_confirm(uuid, jsonb)'::regprocedure,
  $o$  if not coalesce((st ->> 'academy')::boolean, false) then raise exception 'Pass the academy first: the WhatsApp step opens after the academy and the agreement' using errcode = '23514'; end if;
  if not coalesce((st ->> 'agreement')::boolean, false) then raise exception 'Sign your staff agreement first: the WhatsApp step opens after it' using errcode = '23514'; end if;
$o$, '');

-- the academy sections of a person's paths: passed / all (the sales opt-in paths left out, as app.academy_done does)
create function app.staff_academy_count(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('passed', count(*) filter (where app.academy_passed(p_user, s.section_id)), 'total', count(*))
    from (select distinct ps.section_id from academy_path_sections ps
           where ps.path_code = any (app.academy_paths_of(p_user)) and ps.path_code not in ('sales_in_person', 'sales_remote')) s
$$;

-- what one person still needs, in words, in the gate's order (every missing step, not only the first)
create function app.staff_waiting_on(p_user uuid, p_state jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  w text[] := '{}';
  c jsonb;
  g text;
  v_req text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(p_state -> 'required') x), '{}');
  v_joined text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(p_state -> 'joined') x), '{}');
begin
  if not coalesce((p_state ->> 'member')::boolean, false) or coalesce((p_state ->> 'exempt')::boolean, false) or coalesce((p_state ->> 'done')::boolean, false) then
    return '[]'::jsonb;
  end if;
  if not coalesce((p_state ->> 'academy')::boolean, false) then
    c := app.staff_academy_count(p_user);
    w := w || case when (c ->> 'total')::int > 0 then format('Academy (%s of %s sections)', c ->> 'passed', c ->> 'total') else 'Academy' end;
  end if;
  if not coalesce((p_state ->> 'agreement')::boolean, false) then w := w || 'Staff agreement signature'::text; end if;
  foreach g in array v_req loop
    if not (g = any (v_joined)) then
      w := w || format('WhatsApp %s group confirmation', case g when 'sales' then 'CARMA Closers' else 'CarmaCars Team' end);
    end if;
  end loop;
  if coalesce(p_state ->> 'step', '') = 'approval' then
    w := w || case when p_state ->> 'reject_reason' is not null then format('Asking again after the rejection (%s)', p_state ->> 'reject_reason')
                   else 'Approval by an Admin or a Fleet VA' end;
  end if;
  return to_jsonb(w);
end $$;

alter function app.staff_onboarding_state(uuid) rename to staff_onboarding_state_pre2360;
create function app.staff_onboarding_state(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.staff_onboarding_state_pre2360(p_user);
begin
  if not coalesce((v ->> 'member')::boolean, false) then return v; end if;
  return v || jsonb_build_object('waiting_on', app.staff_waiting_on(p_user, v));
end $$;
select pg_temp.copy_grants('app.staff_onboarding_state(uuid)'::regprocedure, 'app.staff_onboarding_state_pre2360(uuid)'::regprocedure);

-- the approval is asked when the last of the earlier steps is done (any order), once; not after a rejection (they ask again)
create function app.staff_onboarding_ask_if_due(p_user uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare sp staff_profiles;
begin
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null or sp.onboarding_approved_at is not null or sp.onboarding_asked_at is not null or sp.onboarding_rejected_at is not null then return false; end if;
  if coalesce(app.staff_onboarding_state(p_user) ->> 'step', '') <> 'approval' then return false; end if;
  return app.staff_onboarding_ask(p_user);
end $$;

-- WhatsApp newly complete: asks only when the academy and the agreement are done too (was: always)
create or replace function app.staff_approval_ask_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_req text[] := app.staff_required_groups(new.functions);
begin
  if v_req <@ new.whatsapp_joined and not (v_req <@ coalesce(old.whatsapp_joined, '{}')) and new.onboarding_approved_at is null then
    perform app.staff_onboarding_ask_if_due(new.user_id);
  end if;
  return null;
end $$;

-- every onboarding event (the academy passed, the agreement signed, a waiver, the WhatsApp marked) refreshes the person:
-- the approval is asked there when the step was reached
alter function app.staff_onboarding_refresh(uuid) rename to staff_onboarding_refresh_pre2360;
create function app.staff_onboarding_refresh(p_user uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare v boolean := app.staff_onboarding_refresh_pre2360(p_user);
begin
  if v is not null and not v then perform app.staff_onboarding_ask_if_due(p_user); end if;
  return v;
end $$;
select pg_temp.copy_grants('app.staff_onboarding_refresh(uuid)'::regprocedure, 'app.staff_onboarding_refresh_pre2360(uuid)'::regprocedure);

-- Admin: p {user}: confirm the person's WhatsApp groups and approve in one step (the academy and the agreement must be done)
create function app.staff_whatsapp_approve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user', '')::uuid;
  st jsonb;
begin
  perform app.assert_admin(p_by);
  if v_user = p_by then raise exception 'Someone else approves your onboarding' using errcode = '42501'; end if;
  if not exists (select 1 from staff_profiles where user_id = v_user) then raise exception 'Staff member not found' using errcode = 'P0002'; end if;
  st := app.staff_onboarding_state(v_user);
  if not coalesce((st ->> 'academy')::boolean, false) or not coalesce((st ->> 'agreement')::boolean, false) then
    raise exception '% cannot be approved yet. Waiting on: %', app.staff_display_name(v_user),
      (select string_agg(x, ', ') from jsonb_array_elements_text(st -> 'waiting_on') x where x not like 'WhatsApp%' and x not like 'Approval%') using errcode = '23514';
  end if;
  if not coalesce((st ->> 'whatsapp')::boolean, false) then perform app.staff_whatsapp_mark(p_by, jsonb_build_object('user', v_user, 'joined', true)); end if;
  if coalesce(app.staff_onboarding_state(v_user) ->> 'step', '') = 'approval' then
    perform app.staff_onboarding_approve(p_by, jsonb_build_object('user', v_user));
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_whatsapp_confirmed_and_approved', 'staff_profiles', v_user::text, jsonb_build_object('onboarded', app.staff_fully_onboarded(v_user)));
  return jsonb_build_object('user', v_user, 'onboarded', app.staff_fully_onboarded(v_user), 'state', app.staff_onboarding_state(v_user));
end $$;

-- the people waiting (Admin and Fleet): at the approval step, and those held only by the WhatsApp step; each with what is missing
create or replace function app.staff_onboarding_approvals(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.staff_may_approve(p_by) then raise exception 'Admins and Fleet only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', x.user_id, 'name', app.staff_display_name(x.user_id), 'functions', to_jsonb(x.functions),
             'asked_at', x.onboarding_asked_at, 'rejected_at', x.onboarding_rejected_at, 'reject_reason', x.onboarding_reject_reason, 'self', x.user_id = p_by,
             'step', x.st ->> 'step', 'waiting_on', coalesce(x.st -> 'waiting_on', '[]'::jsonb))
           order by (x.st ->> 'step') = 'approval' desc, x.onboarding_asked_at nulls last, app.staff_display_name(x.user_id))
      from (select sp.*, app.staff_onboarding_state(sp.user_id) st from staff_profiles sp
             where sp.is_active and app.staff_is_member(sp.user_id) and sp.onboarding_approved_at is null and not sp.onboarding_exempt and not app.staff_is_test(sp.user_id)) x
     where x.st ->> 'step' in ('approval', 'whatsapp')), '[]'::jsonb);
end $$;

-- ================================================================ 5. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2360;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'staff_whatsapp_approve' then
    perform app.door_begin(p_user, p_aal);
    return app.staff_whatsapp_approve(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2360(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2360(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 6. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['offer_sales_choice_pre2360', 'staff_academy_count', 'staff_waiting_on', 'staff_onboarding_state_pre2360',
       'staff_onboarding_ask_if_due', 'staff_onboarding_refresh_pre2360', 'staff_whatsapp_approve', 'door_pre2360'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
