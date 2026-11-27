-- 5071 (R50 hotfix 2; docs/changes/2026-11-25-r50-hotfix2.md): no lead reaches a person who has not passed the academy.
-- The owner (Nov 25): "Sales people shouldn't be getting leads while they're still stuck in academy."
-- Why it could still happen: the lead routing (1151) asks app.staff_fully_onboarded, which is true for everyone while the
-- Program settings switches staff_onboarding_gate or academy_gate are off, and its academy step (app.academy_done) leaves
-- out the Sales path for a person who opted into Sales from another function (0931). The alerts sent to whoever is on
-- shift (staff_alert_users: on_duty, unassigned_on_duty) never asked at all, and nothing stopped a lead or visitor notice
-- (bell, push, email, text, WhatsApp) to such a person at the point it is written.
--   1. app.staff_academy_cleared(uid): an Admin, a test or verify account, a person with no staff record, an exempt person
--      (staff_profiles.onboarding_exempt, an Admin's decision like a waiver), a person whose academy an Admin waived, or one
--      who passed every path of their functions and, when they work Sales (the function or the opt-in), the Sales path too.
--      It does not read the gate switches. app.staff_leads_ok(uid) = fully onboarded and academy cleared.
--   2. Every lead path asks app.staff_leads_ok: an assignment (trigger on leads: moved to the previous salesperson or the
--      pool), a claim and a hold (trigger on lead_claims: refused), an Admin's reassign (lead_reassign, refused), the
--      assignee list (lead_assignee_ok), the return target (lead_previous_owner), the lead list, a lead's page and the
--      dashboard (sl_may, sl_sees: nothing), a visitor's assignment (trigger on visitor_sessions: cleared), and a lead or
--      visitor To do (trigger on tasks: unassigned).
--   3. The alerts: staff_alert_users leaves such a person out of the lead and visitor rules (every route but Admin; other
--      rules still reach them); and a notice about a lead or a visitor is not written to them (trigger on notifications,
--      notification_outbox, push_outbox and phone_outbox), so no bell, push, email, text or WhatsApp.
--   4. Auto hire of Sales (hiring_auto_hire_sales) makes a staff member at the first onboarding step: it gives no lead, and
--      the person gets none until the steps above pass.
--   4. A reset by an Admin or a waiver taken away returns the person's held leads at once; a change to a path's sections
--      checks every holder again; a pass or a waiver clears the kept answer (app.leads_ok_memo).
--   5. Now: every open lead held by such a person goes back (app.leads_return_unonboarded, as 1151 does); the note says
--      "Academy not passed" when that is the reason, and the count is logged.
-- No applied migration is edited: functions are patched in place (the patch refuses when the text is not found) or replaced
-- with the same signature (grants kept).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5071: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the helpers
create function app.staff_academy_cleared(p_user uuid) returns boolean
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  sp staff_profiles;
  v_prev text := coalesce(current_setting('app.onboarding_pass', true), '');
  v_ok boolean;
begin
  if p_user is null or coalesce(app.user_is_admin(p_user), false) or app.staff_is_test(p_user) then return true; end if;
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null or sp.onboarding_exempt or app.academy_waived(p_user) then return true; end if;
  -- the paths as the person is (not as the gate shows them), as app.staff_onboarding_state does
  perform set_config('app.onboarding_pass', p_user::text, true);
  v_ok := app.academy_done(p_user)
      and (not ('sales' = any (coalesce(sp.functions, '{}')) or sp.sales_opt_in_at is not null)
           or not exists (select 1 from academy_path_sections ps where ps.path_code = app.fx_sales_path(p_user) and not app.academy_passed(p_user, ps.section_id)));
  perform set_config('app.onboarding_pass', v_prev, true);
  return coalesce(v_ok, false);
end $$;
comment on function app.staff_academy_cleared(uuid) is 'R50 hotfix 2 (5071): the academy is behind this person: an Admin, a test account, no staff record, exempt, waived by an Admin, or every path of their functions passed (the Sales path too when they work Sales). Ignores the gate switches.';

-- kept for the statement (a list asks it once a row): app.leads_ok_memo holds 'user|transaction|statement start|answer'.
-- A pass, a waiver, a reset or a path change clears it (app.leads_ok_forget, section 4).
create function app.staff_leads_ok(p_user uuid) returns boolean
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_key text;
  v_memo text := coalesce(current_setting('app.leads_ok_memo', true), '');
  v_ok boolean;
begin
  if p_user is null then return true; end if;
  v_key := p_user::text || '|' || coalesce(txid_current_if_assigned()::text, '-') || '|' || statement_timestamp()::text || '|';
  if left(v_memo, length(v_key)) = v_key then return substr(v_memo, length(v_key) + 1) = 't'; end if;
  v_ok := app.staff_fully_onboarded(p_user) and app.staff_academy_cleared(p_user);
  perform set_config('app.leads_ok_memo', v_key || case when v_ok then 't' else 'f' end, true);
  return v_ok;
end $$;
comment on function app.staff_leads_ok(uuid) is 'R50 hotfix 2 (5071): may this person receive, claim, be given or see a lead or a visitor: fully onboarded (1151) and the academy passed or waived.';

-- ================================================================ 2. the lead paths
create or replace function app.leads_assignee_onboarded() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.assigned_to is not null and coalesce(current_setting('app.lead_return', true), '') <> 'on'
     and app.staff_is_member(new.assigned_to) and not app.staff_leads_ok(new.assigned_to) then
    new.assigned_to := case when TG_OP = 'UPDATE' and new.id is not null then app.lead_previous_owner(new.id, new.assigned_to) end;
  end if;
  return new;
end $$;

create or replace function app.lead_claims_onboarded() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if app.staff_is_member(new.claimed_by) and not app.staff_leads_ok(new.claimed_by) then
    raise exception '% has not finished onboarding (academy, agreement and WhatsApp): leads cannot go to them yet', app.sl_name(new.claimed_by) using errcode = '23514';
  end if;
  return new;
end $$;

select pg_temp.patch_fn('app.lead_reassign(uuid, jsonb)'::regprocedure,
  'if v_to is not null and app.staff_is_member(v_to) and not app.staff_fully_onboarded(v_to) then',
  'if v_to is not null and app.staff_is_member(v_to) and not app.staff_leads_ok(v_to) then');
select pg_temp.patch_fn('app.lead_previous_owner(uuid, uuid)'::regprocedure,
  'app.staff_fully_onboarded(x.u)', 'app.staff_leads_ok(x.u)');
select pg_temp.patch_fn('app.leads_return_unonboarded(uuid, uuid)'::regprocedure,
  'not app.staff_fully_onboarded(coalesce(c.claimed_by, l.assigned_to))', 'not app.staff_leads_ok(coalesce(c.claimed_by, l.assigned_to))');
-- the note says the reason; by_user stays null (the system): there is no system account, and app.system_admin is a real Admin
select pg_temp.patch_fn('app.leads_return_unonboarded(uuid, uuid)'::regprocedure,
  'select l.id from leads l', 'select l.id, coalesce(c.claimed_by, l.assigned_to) holder from leads l');
select pg_temp.patch_fn('app.leads_return_unonboarded(uuid, uuid)'::regprocedure,
  'perform app.lead_return_do(r.id, p_by, ''Not fully onboarded (academy, agreement and WhatsApp): the lead went back'');',
  'perform app.lead_return_do(r.id, p_by, case when app.staff_fully_onboarded(r.holder) then ''Academy not passed: the lead went back''
                                                else ''Not fully onboarded (academy, agreement and WhatsApp): the lead went back'' end);');
select pg_temp.patch_fn('app.lead_assignee_ok(uuid)'::regprocedure,
  'app.staff_fully_onboarded(p_user)', 'app.staff_leads_ok(p_user)');

-- the list, a lead's page, the dashboard: nothing for such a person
create or replace function app.sl_may(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_user is not null and (coalesce(app.user_is_admin(p_user), false)
     or ((app.user_va_has(p_user, 'sales') or app.user_va_has(p_user, 'cs')) and app.staff_leads_ok(p_user)))
$$;
select pg_temp.patch_fn('app.sl_sees(uuid, leads)'::regprocedure,
  'select app.sl_listed(l) and (', 'select app.sl_listed(l) and (coalesce(app.user_is_admin(p_user), false) or app.staff_leads_ok(p_user)) and (');

-- a visitor given to such a person: not given
create function app.visitor_assignee_ok() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.assigned_to is not null and app.staff_is_member(new.assigned_to) and not app.staff_leads_ok(new.assigned_to) then
    new.assigned_to := null; new.assigned_at := null;
  end if;
  return new;
end $$;
create trigger b_visitor_assignee_ok before insert or update of assigned_to on visitor_sessions for each row execute function app.visitor_assignee_ok();

-- a To do about a lead or a visitor given to such a person: back in its queue
create function app.lead_task_assignee_ok() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.assigned_to is not null and new.related_table in ('leads', 'visitor_sessions')
     and app.staff_is_member(new.assigned_to) and not app.staff_leads_ok(new.assigned_to) then
    new.assigned_to := null;
    if new.status = 'in_progress' then new.status := 'open'; end if;
  end if;
  return new;
end $$;
create trigger b_lead_task_assignee_ok before insert or update of assigned_to on tasks for each row execute function app.lead_task_assignee_ok();

-- ================================================================ 3. the alerts
-- the alert rules and notice codes about a lead, a visitor or a sales request: an exact list (not a word match, so
-- leaderboard, lead_time, override_requested or owner_trip_new are not caught). Booking requests and offers are customer
-- service work and stay open to them.
create function app.lead_notice_code(p_code text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(p_code, '') in ('staff_lead_new', 'staff_owner_lead_new', 'staff_hot_visitor', 'visitor_signal', 'lead_phone_shown',
                                  'staff_request_unfinished', 'staff_request_open_to_sales', 'staff_offer_reopen_ask')
$$;
create function app.staff_alert_is_lead(p_rule text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select app.lead_notice_code(p_rule)
$$;
-- only the lead rules ask for the academy: a fleet, finance or customer service alert (booking_not_back) still reaches
-- the person on shift while they learn
select pg_temp.patch_fn('app.staff_alert_users(text, jsonb)'::regprocedure,
  'where not app.staff_is_test(c.uid)',
  'where not app.staff_is_test(c.uid)
       and (c.ord = 0 or not app.staff_alert_is_lead(p_rule) or app.staff_leads_ok(c.uid))');

-- a notice about a lead or a visitor is never written to such a person (every channel starts at one of these tables)
create function app.lead_notice_fence() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  j jsonb := to_jsonb(new);
  v_who uuid := nullif(coalesce(j ->> 'user_id', j ->> 'recipient_user_id'), '')::uuid;
begin
  if v_who is null or not (coalesce(j ->> 'entity', '') in ('lead', 'leads', 'visitor', 'visitor_sessions')
                           or app.lead_notice_code(j ->> 'code') or app.lead_notice_code(j ->> 'kind') or app.lead_notice_code(j ->> 'sms_kind')) then
    return new;
  end if;
  if app.staff_is_member(v_who) and not app.staff_leads_ok(v_who) then return null; end if;
  return new;
end $$;
create trigger b_lead_notice_fence before insert on notifications for each row execute function app.lead_notice_fence();
create trigger b_lead_notice_fence before insert on notification_outbox for each row execute function app.lead_notice_fence();
create trigger b_lead_notice_fence before insert on push_outbox for each row execute function app.lead_notice_fence();
create trigger b_lead_notice_fence before insert on phone_outbox for each row execute function app.lead_notice_fence();

-- ================================================================ 4. the academy changes: forget the kept answer, return the leads
-- a pass (academy_attempts) or a waiver given: the kept answer is forgotten. An Admin's reset, a waiver taken away: the
-- person's held leads go back now. A path's sections changed: every holder is checked again.
create function app.leads_ok_forget() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform set_config('app.leads_ok_memo', '', true);
  if TG_TABLE_NAME = 'academy_path_sections' then perform app.leads_return_unonboarded(null, null); end if;
  return null;
end $$;
create function app.leads_academy_lost() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform set_config('app.leads_ok_memo', '', true);
  if TG_OP = 'DELETE' then
    perform app.leads_return_unonboarded(null, old.user_id);
  elsif TG_TABLE_NAME = 'academy_resets' then
    perform app.leads_return_unonboarded(null, new.user_id);
  elsif new.revoked_at is not null then
    perform app.leads_return_unonboarded(null, new.user_id);
  end if;
  return null;
end $$;
create trigger z_leads_ok_forget after insert on academy_attempts for each statement execute function app.leads_ok_forget();
create trigger z_leads_ok_forget after insert or update or delete on academy_path_sections for each statement execute function app.leads_ok_forget();
create trigger z_leads_academy_lost after insert or update on academy_resets for each row execute function app.leads_academy_lost();
create trigger z_leads_academy_lost after insert or update or delete on academy_waivers for each row execute function app.leads_academy_lost();

-- ================================================================ privileges: the server only
revoke all on function app.staff_academy_cleared(uuid), app.staff_leads_ok(uuid), app.visitor_assignee_ok(), app.lead_task_assignee_ok(),
  app.lead_notice_code(text), app.staff_alert_is_lead(text), app.lead_notice_fence(), app.leads_ok_forget(), app.leads_academy_lost() from public, anon, authenticated;
grant execute on function app.staff_academy_cleared(uuid), app.staff_leads_ok(uuid), app.visitor_assignee_ok(), app.lead_task_assignee_ok(),
  app.lead_notice_code(text), app.staff_alert_is_lead(text), app.lead_notice_fence(), app.leads_ok_forget(), app.leads_academy_lost() to service_role;

-- ================================================================ 5. now
do $$
declare n integer := app.leads_return_unonboarded(null, null);
begin
  raise notice '5071: % open lead(s) returned from people who have not passed the academy or onboarding', n;
end $$;
