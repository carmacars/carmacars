-- 3354 (release 48, integration): what the merge of RW left to wire.
-- 1. The owner's new-booking emails, opted in. 2620 switched owner_new_booking, owner_booking_confirmed and
--    owner_booking_changed off in the catalogue (is_enabled false: the event is closed as "code disabled"), and they stay
--    off there. RW (3260) gave owners the type "New bookings on your cars" (owner_new_bookings, every channel off by
--    default) in their notification preferences, but a switch turned on sent nothing. Now app.process_events delivers
--    one of the three codes when the car's owner has turned at least one channel of that type on: the email, the text
--    and the phone alert follow the owner's channels (3260's outbox triggers), the notice shows in the portal. An owner
--    who has not opted in hears nothing, as before 3260.
-- 2. Alert targets (2960): two kinds of record staff alerts are written for since 3192 and 3199 are registered, so each
--    alert opens its record: dispute_packs (dispute_deadline: the booking's Money section) and tasks (fee_evidence_needed:
--    the To do, as "task").
-- 3. Every staff alert rule has its notify type (3260 typed the rules there were then; the rules added since, such as the
--    tracker rules of 3320 and 3326 and the pickup check of 3293, had none): a rule added later takes its type by the
--    same rule, unless its migration names one.
-- 4. Indexes for the foreign keys of RW's tables that 99_r35sec_security names as missing (the parent's delete or update would
--    scan the child table): staff_free_days (created_by), notify_prefs and notify_profiles (updated_by), social_post_stats
--    (updated_by), owner_reward_requests (decided_by), social_calendars (generated_by). The FK indexes of r48-fe are 3324's.
-- No applied migration is edited: app.process_events_pre0827 (0018, 0827) is patched in one place; app.alert_entity_kind,
-- app.alert_entity_table, app.alert_entity_tab and app.alert_target (2960, this release) are wrapped (_pre3354).
-- SCHEMA_MARKER 3354.
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
  if position(p_old in d) = 0 then raise exception '3354: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the owner's new-booking emails, when the owner opted in
-- true when a code switched off in the catalogue is one an owner may opt into, and a recipient of this event did
create function app.notify_code_opted_in(p_event app_events, p_c notification_catalogue) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare r record; f record;
begin
  if p_c.code is null or p_c.code not in ('owner_new_booking', 'owner_booking_confirmed', 'owner_booking_changed') or p_c.pref_type is null then return false; end if;
  for r in select x.user_id from app.notification_recipients(p_event, p_c) x where x.user_id is not null loop
    select * into f from app.notify_pref_of('user', r.user_id, p_c.pref_type);
    if f.known and not f.locked and (f.push or f.email or f.sms) then return true; end if;
  end loop;
  return false;
end $$;
revoke all on function app.notify_code_opted_in(app_events, notification_catalogue) from public, anon, authenticated;
grant execute on function app.notify_code_opted_in(app_events, notification_catalogue) to service_role;

select pg_temp.patch_fn('app.process_events_pre0827(integer, timestamptz)'::regprocedure,
  $o$if c.code is null or not c.is_enabled then$o$,
  $n$if c.code is null or not (c.is_enabled or app.notify_code_opted_in(e, c)) then$n$);
comment on function app.notify_code_opted_in(app_events, notification_catalogue) is 'The owner''s new-booking emails (3354): owner_new_booking, owner_booking_confirmed and owner_booking_changed stay switched off in the catalogue (2620) and are delivered only to an owner who turned a channel of "New bookings on your cars" (owner_new_bookings, 3260) on.';

-- ================================================================ 2. the alert targets of dispute packs and To dos
alter function app.alert_entity_kind(text) rename to alert_entity_kind_pre3354;
create function app.alert_entity_kind(p_entity text) returns text
language sql immutable set search_path = public, app as $$
  select case p_entity when 'dispute_packs' then 'booking' when 'dispute_pack' then 'booking' when 'tasks' then 'record' else app.alert_entity_kind_pre3354(p_entity) end
$$;
alter function app.alert_entity_table(text) rename to alert_entity_table_pre3354;
create function app.alert_entity_table(p_entity text) returns text
language sql immutable set search_path = public, app as $$
  select case p_entity when 'dispute_packs' then 'dispute_packs' when 'dispute_pack' then 'dispute_packs' when 'tasks' then 'tasks' else app.alert_entity_table_pre3354(p_entity) end
$$;
alter function app.alert_entity_tab(text) rename to alert_entity_tab_pre3354;
create function app.alert_entity_tab(p_entity text) returns text
language sql immutable set search_path = public, app as $$
  select case when p_entity in ('dispute_packs', 'dispute_pack') then 'money' else app.alert_entity_tab_pre3354(p_entity) end
$$;
alter function app.alert_target(uuid, boolean, boolean, text, uuid, text, jsonb) rename to alert_target_pre3354;
create function app.alert_target(p_user uuid, p_admin boolean, p_field_only boolean, p_entity text, p_id uuid,
                                 p_rule text default null, p_payload jsonb default null) returns text
language sql stable security definer set search_path = public, app as $$
  select app.alert_target_pre3354(p_user, p_admin, p_field_only, case p_entity when 'tasks' then 'task' when 'dispute_pack' then 'dispute_packs' else p_entity end, p_id, p_rule, p_payload)
$$;
select pg_temp.copy_grants('app.alert_entity_kind(text)'::regprocedure, 'app.alert_entity_kind_pre3354(text)'::regprocedure);
select pg_temp.copy_grants('app.alert_entity_table(text)'::regprocedure, 'app.alert_entity_table_pre3354(text)'::regprocedure);
select pg_temp.copy_grants('app.alert_entity_tab(text)'::regprocedure, 'app.alert_entity_tab_pre3354(text)'::regprocedure);
select pg_temp.copy_grants('app.alert_target(uuid, boolean, boolean, text, uuid, text, jsonb)'::regprocedure, 'app.alert_target_pre3354(uuid, boolean, boolean, text, uuid, text, jsonb)'::regprocedure);
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname ~ '_pre3354$' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 3. every staff alert rule has its type
create function app.staff_alert_rule_type(r staff_alert_rules) returns text
language sql immutable as $$
  select case
    when r.rule in ('job_assigned', 'job_late') or r.rule like 'shift_%' then 'staff_jobs'
    when r.rule like 'sent:%' then 'staff_sent'
    when r.grp = 'Leads' then 'staff_leads'
    when r.grp = 'Money' then 'staff_money'
    when r.grp = 'Bookings' then 'staff_bookings'
    when r.grp = 'Customers' then 'staff_customers'
    when r.grp = 'Documents' then 'staff_documents'
    when r.grp in ('Fleet and cars', 'Field work') then 'staff_fleet'
    when r.rule ~ '^(townhall|interview|staff_restore|onboarding)' then 'staff_onboarding'
    else 'staff_system' end
$$;
create function app.staff_alert_rule_type_default() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.pref_type is null then new.pref_type := app.staff_alert_rule_type(new); end if;
  return new;
end $$;
create trigger staff_alert_rules_pref_type before insert on staff_alert_rules for each row execute function app.staff_alert_rule_type_default();
update staff_alert_rules r set pref_type = app.staff_alert_rule_type(r) where pref_type is null;
revoke all on function app.staff_alert_rule_type(staff_alert_rules), app.staff_alert_rule_type_default() from public, anon, authenticated;
grant execute on function app.staff_alert_rule_type(staff_alert_rules), app.staff_alert_rule_type_default() to service_role;

-- ================================================================ 4. the foreign keys of RW's tables
create index if not exists staff_free_days_created_by on staff_free_days (created_by) where created_by is not null;
create index if not exists notify_prefs_updated_by on notify_prefs (updated_by) where updated_by is not null;
create index if not exists notify_profiles_updated_by on notify_profiles (updated_by) where updated_by is not null;
create index if not exists social_post_stats_updated_by on social_post_stats (updated_by) where updated_by is not null;
create index if not exists owner_reward_requests_decided_by on owner_reward_requests (decided_by) where decided_by is not null;
create index if not exists social_calendars_generated_by on social_calendars (generated_by) where generated_by is not null;
