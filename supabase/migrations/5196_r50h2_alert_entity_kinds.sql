-- 5196 (R50 hotfix 2, CI doctor, REQ-117): the notices of the weekly Admin call (5150), the call flags (5137) and the shift
-- claims (5136) carry their own page in the notice (path_admin), so their records are a list kind, not one record's page.
-- 99_r48_alert_targets failed on them: "every kind of record a staff notice is written for is known".
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.alert_entity_kind(text) rename to alert_entity_kind_pre5196;
create function app.alert_entity_kind(p_entity text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_entity in ('admin_call_deck', 'phone_activity', 'shift_claim') then 'list' else app.alert_entity_kind_pre5196(p_entity) end
$$;
select pg_temp.copy_grants('app.alert_entity_kind(text)', 'app.alert_entity_kind_pre5196(text)');
