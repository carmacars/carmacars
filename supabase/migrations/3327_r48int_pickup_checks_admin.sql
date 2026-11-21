-- 3327 (release 48, integration): the pickup identity checks (3293) get the admin_all policy every table has (04_rls "every table has the
-- admin policy"). Only the select grant exists (revoked from anon and authenticated except select), so nothing else opens. SCHEMA_MARKER 3327.
create policy admin_all on pickup_identity_checks for all to authenticated using (app.is_admin()) with check (app.is_admin());
