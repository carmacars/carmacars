-- 0814_r34o_signal_alerts.sql
-- Release 34 part O, section C: a live-visitor signal can alert on its own. Until now only the hot band (a score at or above
-- hot_score, 0460/0086) alerted, and "Came back for the same car" (same_car_return) alone never did. visitor_signal_rules gets
-- alert_on_own (on by default for same_car_return; Admin > Today > Live visitors > Signal settings changes it per signal):
-- when that signal turns on in a visit, Admins and the on-duty customer service and Sales staff get the alert (the rule
-- visitor_signal in staff_alert_rules: push or in-app by each person's alert settings), once per visitor per signal per
-- day, with the same guards as the hot alert (analytics consent, renters only, not staff, not test addresses).
set local check_function_bodies = off;

alter table visitor_signal_rules add column if not exists alert_on_own boolean not null default false;
comment on column visitor_signal_rules.alert_on_own is 'Live visitors (0814): when this signal turns on in a visit, alert the Admins and the on-duty customer service and Sales staff on its own, without waiting for the hot score. Once per visitor per day.';
update visitor_signal_rules set alert_on_own = true where code = 'same_car_return';

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('visitor_signal', 'Visitor signal on its own (for example came back for the same car)', 'Leads', '{admin,on_duty:cs,on_duty:sales}', 'urgent', 'visitors', true, false,
   'A Live visitors signal with "Alert on its own" on (Signal settings) turned on in a visit (0814). Once per visitor per signal per day.', 14)
on conflict (rule) do nothing;

create function app.visitor_signal_own_alert() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  r visitor_signal_rules;
  s visitor_sessions;
begin
  begin
    if not new.active or (tg_op = 'UPDATE' and old.active) then return null; end if;
    select * into r from visitor_signal_rules where code = new.kind and enabled and alert_on_own;
    if r.code is null then return null; end if;
    select * into s from visitor_sessions where id = new.session_id;
    if s.id is null or s.consent <> 'analytics' or s.audience is distinct from 'renter' then return null; end if;
    if not coalesce((app.settings()).visitor_tracking_enabled, true) then return null; end if;
    if app.email_is_test(s.known_email) then return null; end if;
    if s.user_id is not null and exists (select 1 from user_roles x where x.user_id = s.user_id and x.role::text in ('admin', 'va', 'field')) then return null; end if;
    perform app.staff_alert('visitor_signal', 'visitor', s.visitor_id, new.kind || ':' || app.local_date(now())::text,
      r.label || ': ' || app.visitor_who(s), coalesce(nullif(new.why, ''), r.explain) || coalesce(' (' || nullif(s.city, '') || ')', ''),
      jsonb_build_object('session_id', s.id, 'signal', new.kind));
  exception when others then
    raise warning 'visitor signal alert not made for %: %', new.session_id, sqlerrm;
  end;
  return null;
end $$;
create trigger visitor_live_signals_own_alert after insert or update of active on visitor_live_signals for each row execute function app.visitor_signal_own_alert();

-- Admin: the switch per signal
create function app.live_signal_alert_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  update visitor_signal_rules set alert_on_own = coalesce((p ->> 'alert_on_own')::boolean, alert_on_own), updated_at = now(), updated_by = p_by where code = p ->> 'code';
  if not found then raise exception 'Unknown signal' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0814;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_name = 'live_signal_alert_save' and p_call in ('admin_do', 'ops_do') then
    perform app.door_begin(p_user, p_aal);
    return app.live_signal_alert_save(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0814(p_user, p_aal, p_call, p_name, p);
end $$;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0814(uuid, text, text, text, jsonb)'::regprocedure);
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['visitor_signal_own_alert', 'live_signal_alert_save', 'door_pre0814'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
