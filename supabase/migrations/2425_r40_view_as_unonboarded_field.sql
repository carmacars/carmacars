-- 2425_r40_view_as_unonboarded_field.sql
-- Release 40: Admin "View as (Field work)" and Portals > Field refused every field staff member still in onboarding ("<name> is not
-- field staff"): app.person_portals reads app.user_is_field, which since 1151 includes the onboarding gate (staff_gate_ok), and
-- person_portals never set app.onboarding_pass (my_roles does). The portal list now reads the person as they are, as my_roles
-- does, for this one read; is_field_person and the gate are unchanged, so the person's own field actions stay refused until
-- they finish onboarding.
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.person_portals(uuid) rename to person_portals_pre2425;
create function app.person_portals(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_prev text := coalesce(current_setting('app.onboarding_pass', true), '');
  v jsonb;
begin
  if p_user is not null then perform set_config('app.onboarding_pass', p_user::text, true); end if;
  v := app.person_portals_pre2425(p_user);
  perform set_config('app.onboarding_pass', v_prev, true);
  return v;
end $$;
select pg_temp.copy_grants('app.person_portals(uuid)'::regprocedure, 'app.person_portals_pre2425(uuid)'::regprocedure);

-- the renamed original is for the new one only (0036 keeps person_portals itself limited the same way)
revoke all on function app.person_portals_pre2425(uuid) from public, anon, authenticated;
grant execute on function app.person_portals_pre2425(uuid) to service_role;
