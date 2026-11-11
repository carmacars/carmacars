-- 1153_r35g_unassigned_lead_alerts.sql
-- Release 35, part G (helper G), a follow-up to 1152. Since 1152 no lead is given to anyone by itself, so the lead alerts
-- of 0460 (the Admins and the person a lead is assigned to) reached no salesperson for a new owner lead. The owner: new
-- unassigned leads alert every fully onboarded Sales person on duty, plus the Admins; once someone claims the lead, later
-- alerts go to the claimer only.
--   1. Who holds a lead is read when the alert is sent (not when it was made): the live claim (lead_claims, 0950), else the
--      lead's assigned_to. For an unfinished request (a contact capture) it is its lead's holder, else the person its lead
--      or task is assigned to, as in 0460.
--   2. A lead with a holder: the Admins and the holder only (a holder not fully onboarded, 1151, gets nothing).
--   3. A lead with no holder: the Admins, and everyone fully onboarded on duty in Sales (and, for renter leads and unfinished
--      requests, customer service, as in 0460). On duty is the notion of 0460 (Live chat, Live visitors or Texts open within
--      chat_shift_minutes) or clocked in now (staff_clock_entries, 1061: an open, not voided entry).
--   4. The hot visitor alert keeps its people (on duty, customer service and Sales), now only those fully onboarded.
-- The alerts stay in the app and on the phone only (no email and no text, 0460), urgent, so no SMS quiet hours apply; a
-- staff phone follows its own settings (0466). Test and verify accounts are still never sent one.
-- No applied migration is edited: app.lead_alert_users is replaced (same signature and grants).

create or replace function app.lead_on_duty(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from chat_staff_prefs cp
                  where cp.user_id = p_user and cp.last_seen_at > now() - make_interval(mins => (app.settings()).chat_shift_minutes))
      or exists (select 1 from staff_clock_entries ce
                  where ce.user_id = p_user and ce.ended_at is null and ce.voided_at is null and ce.started_at <= now())
$$;
comment on function app.lead_on_duty(uuid) is 'Lead alerts (1153): Live chat, Live visitors or Texts open within chat_shift_minutes (0460), or clocked in now (1061).';
revoke all on function app.lead_on_duty(uuid) from public, anon, authenticated;
grant execute on function app.lead_on_duty(uuid) to service_role;

-- the holder of a lead now: the live claim, else the person it is assigned to
create or replace function app.lead_holder(p_lead uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce((select c.claimed_by from lead_claims c where c.lead_id = p_lead and c.expires_at > now()),
                  (select l.assigned_to from leads l where l.id = p_lead))
$$;
revoke all on function app.lead_holder(uuid) from public, anon, authenticated;
grant execute on function app.lead_holder(uuid) to service_role;

create or replace function app.lead_alert_users(p_code text, p jsonb) returns table (user_id uuid, audience text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_lead uuid := nullif(p ->> 'lead_id', '')::uuid;
  v_holder uuid;
  v_fns text[];
begin
  if v_lead is null and nullif(p ->> 'capture_id', '') is not null then
    select cc.lead_id into v_lead from contact_captures cc where cc.id = (p ->> 'capture_id')::uuid;
  end if;
  v_holder := case when v_lead is not null then app.lead_holder(v_lead) end;
  if v_holder is null then v_holder := nullif(p ->> 'assigned_to', '')::uuid; end if;
  -- who is told when nobody holds it (or, for a hot visitor, always)
  v_fns := case
    when p_code = 'staff_hot_visitor' then array['cs', 'sales']
    when v_holder is not null then array[]::text[]
    when p_code = 'staff_owner_lead_new' then array['sales']
    when p_code in ('staff_lead_new', 'staff_request_unfinished') then array['cs', 'sales']
    else array[]::text[] end;
  return query
    select distinct on (c.uid) c.uid, c.aud
      from (
        -- the Admins, always
        select u.id uid, 'staff_admin'::text aud, 0 ord
          from users u where u.status = 'active' and exists (select 1 from user_roles r where r.user_id = u.id and r.role::text = 'admin')
        union all
        -- the holder (the claimer, else the person it is assigned to)
        select u.id, 'staff_va_' || sp.va_function::text, 1
          from users u join staff_profiles sp on sp.user_id = u.id and sp.staff_type = 'va' and sp.is_active
         where u.id = v_holder and u.status = 'active' and p_code in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new')
           and app.staff_fully_onboarded(u.id)
        union all
        -- nobody holds it: everyone fully onboarded on duty in those functions (own or covered)
        select u.id, 'staff_va_' || sp.va_function::text, 2
          from users u join staff_profiles sp on sp.user_id = u.id and sp.staff_type = 'va' and sp.is_active
         where u.status = 'active' and cardinality(v_fns) > 0
           and (sp.va_function::text = any (v_fns) or exists (select 1 from unnest(sp.cover_functions) x where x::text = any (v_fns)))
           and app.staff_fully_onboarded(u.id) and app.lead_on_duty(u.id)
      ) c
     where not app.staff_is_test(c.uid)
     order by c.uid, c.ord;
end $$;

-- what the Alerts settings and the catalogue say
update staff_alert_rules set who = '{admin,assigned,unassigned_on_duty:sales}' where rule = 'staff_owner_lead_new';
update notification_catalogue set trigger_text = replace(trigger_text,
    'To the Admins and the Sales person it is assigned to (Sales see only their own owner leads).',
    'To the Admins and the salesperson who claimed it or holds it; while nobody does, every fully onboarded Sales person on duty or clocked in (1153).')
 where code = 'staff_owner_lead_new';
update notification_catalogue set trigger_text = replace(trigger_text,
    'else customer service and Sales on duty.',
    'else (nobody claimed it) customer service and Sales on duty or clocked in and fully onboarded (1153).')
 where code in ('staff_lead_new', 'staff_request_unfinished');
