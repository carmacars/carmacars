-- 5304 (R51 staff, REQ-135; docs/changes/2026-11-27-r51-staff.md): no dead end in onboarding. The owner (Nov 27 17:45):
-- "jamal got the academy waived for him and now it says your agreement first and theres no buttons to click anywhere other
-- than resign ... he needs extremely easy steps to follow for getting access to portals. all staff should have easy flows."
-- Cause: Welcome showed a Sign button only when a sign request was already sent. The agreement is made by the agreements
-- job (1060), which skips a person for a day after each try and stops after 5 tries (app.staff_agreements_due_rows), and
-- the page then said "It is being prepared" with nothing to press. A Sales and Field person also waits on the licence
-- number and the availability, each on its own card.
--   1. Sign now (door ops_do staff_agreement_now): the person asks for their agreement now. The job's wait and its
--      5-try stop are cleared for them, so the server makes it at once (web/src/server/actions/onboarding-now.ts). When it
--      still waits for something only CarmaCars sets (pay, start date, vehicle types), the Admins get the urgent alert
--      staff_agreement_stuck naming what is missing, once a day a person.
--   2. Welcome (app.staff_welcome) gains the pay details step (done when a payout account is on file; it does not hold
--      the portal, payouts need it) and says which step is next (next). The page draws each step left as one button.
-- No applied migration is edited: staff_welcome is wrapped (_pre5304); the door is wrapped (_pre5304).
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

-- ================================================================ 1. Sign now
create function app.staff_agreement_now(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ag jsonb := app.staff_agreement_state(p_user);
begin
  if ag is null then raise exception 'Only staff sign a staff agreement' using errcode = '42501'; end if;
  if ag ->> 'state' in ('signed', 'waived', 'sent') then return ag; end if;
  -- the job's wait (a day after a try) and its 5-try stop do not apply when the person asks
  update staff_agreement_auto set last_at = null, tries = 0 where user_id = p_user;
  return ag || jsonb_build_object('due', p_user in (select app.staff_agreements_due_rows(1000)));
end $$;

-- the agreement still waits for something only CarmaCars sets: the Admins hear it at once, with what is missing
create function app.staff_agreement_help(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  ag jsonb := app.staff_agreement_state(p_user);
  v_missing text := nullif(array_to_string(array(select jsonb_array_elements_text(case when jsonb_typeof(p -> 'missing') = 'array' then p -> 'missing' else ag -> 'missing' end)), ', '), '');
begin
  if ag is null or ag ->> 'state' in ('signed', 'waived', 'sent') then return jsonb_build_object('ok', true, 'alerted', false); end if;
  perform app.staff_alert('staff_agreement_stuck', 'user', p_user, 'stuck:' || to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD'),
    format('%s cannot sign their agreement yet', app.staff_display_name(p_user)),
    coalesce('Missing: ' || v_missing || '. ', '') || coalesce('Last error: ' || left(nullif(p ->> 'error', ''), 160) || '. ', '')
      || 'They pressed Sign now on Welcome. Set it on their staff record, or waive the agreement.',
    jsonb_build_object('path_admin', '/admin/settings/staff'));
  return jsonb_build_object('ok', true, 'alerted', true);
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, hint, sort) values
  ('staff_agreement_stuck', 'Staff agreement cannot be made', 'Staff', '{admin}', 'urgent', 'alerts', true, true,
   'A staff member pressed Sign now and their agreement still needs a value only an Admin sets (pay, start date, vehicle types), or making it failed.', 130)
on conflict (rule) do nothing;

-- ================================================================ 2. Welcome: pay details and the next step
alter function app.staff_welcome(uuid) rename to staff_welcome_pre5304;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.staff_welcome_pre5304(p_user);
  v_steps jsonb;
  v_pay boolean := exists (select 1 from staff_payout_accounts a where a.user_id = p_user and a.is_current);
begin
  if jsonb_typeof(v -> 'steps') <> 'array' then return v; end if;
  -- pay details before the first tasks (or last)
  select jsonb_agg(x order by o) into v_steps from (
    select s x, n::numeric o from jsonb_array_elements(v -> 'steps') with ordinality t(s, n)
    union all
    select jsonb_build_object('key', 'pay', 'done', v_pay, 'required', false),
           coalesce((select n - 0.5 from jsonb_array_elements(v -> 'steps') with ordinality t(s, n) where s ->> 'key' = 'tasks'), 1000)) q;
  return v || jsonb_build_object('steps', v_steps,
    -- the first step left that the person can do now (welcome and the first-day tasks are not steps to press)
    'next', (select s ->> 'key' from jsonb_array_elements(v_steps) with ordinality t(s, n)
              where not coalesce((s ->> 'done')::boolean, false) and s ->> 'key' not in ('welcome', 'tasks')
                and coalesce((s ->> 'open')::boolean, true) order by n limit 1));
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)', 'app.staff_welcome_pre5304(uuid)');

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5304;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('ops_do', 'field_do', 'va_do') and p_name in ('staff_agreement_now', 'staff_agreement_help') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'staff_agreement_now' then app.staff_agreement_now(p_user)
                       else app.staff_agreement_help(p_user, coalesce(p, '{}'::jsonb) - '_va') end;
  end if;
  return app.door_pre5304(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5304(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.staff_agreement_now(uuid), app.staff_agreement_help(uuid, jsonb), app.staff_welcome_pre5304(uuid), app.door_pre5304(uuid, text, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function app.staff_agreement_now(uuid), app.staff_agreement_help(uuid, jsonb), app.staff_welcome_pre5304(uuid), app.door_pre5304(uuid, text, text, text, jsonb)
  to service_role;
