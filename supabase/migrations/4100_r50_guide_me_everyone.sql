-- 4100 (Guide me for everyone; docs/changes/2026-11-24-r50-guide-me-everyone.md): the step-by-step coach of 3950 now runs
-- in the owner, renter and investor portals too (and on the public site, where nothing is kept on the server). Every
-- signed-in person may keep it on and record their runs; the runs say which portal. The Admin's report (Academy) counts
-- everyone. Functions keep search_path public, app, pg_temp and the server role alone executes them. SCHEMA_MARKER 4101.
-- No applied migration is edited.

alter table guide_me_runs drop constraint if exists guide_me_runs_portal_check;
alter table guide_me_runs add constraint guide_me_runs_portal_check check (portal in ('admin', 'va', 'field', 'owner', 'renter', 'investor'));

-- the name stays (public.guide_me_state, guide_me_do call it); it now answers for every signed-in person
create or replace function app.guide_me_staff(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_by is not null and exists (select 1 from users u where u.id = p_by)
$$;
comment on function app.guide_me_staff(uuid) is 'Guide me (3950, 4100): who may keep it on and record runs: every signed-in person.';

revoke all on function app.guide_me_staff(uuid) from public, anon, authenticated;
grant execute on function app.guide_me_staff(uuid) to service_role;
