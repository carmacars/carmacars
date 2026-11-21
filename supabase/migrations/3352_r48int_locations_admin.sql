-- 3352 (release 48, integration): the live map location tables (3350) get the admin_all policy every table has (04_rls "every table has the
-- admin policy"). Browser sessions have no grant on them (service_role only), so the policy opens nothing by itself. SCHEMA_MARKER 3352.
do $$
declare t text;
begin
  foreach t in array array['location_prefs', 'person_locations', 'location_job_points'] loop
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
