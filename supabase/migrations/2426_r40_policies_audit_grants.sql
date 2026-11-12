-- 2426_r40_policies_audit_grants.sql
-- Release 40: the structure suites (03 flows, 04 rls, 06, 08, 09) failed on three tables and three functions of releases 39 and 40.
--   * showroom_backgrounds (2400), site_selfqa_runs (2400) and reward_tier_perks (2421) had no admin_all policy (every table has
--     one; the browser still reaches nothing, the tables are not granted to the browser roles beyond the old read policies).
--   * showroom_backgrounds and reward_tier_perks are settings an Admin edits: audited like the others. site_selfqa_runs is a
--     run log (one row per deploy, no money, pricing or status); the suite lists it with the other logs.
--   * leads.admin_assigned_by had no foreign key index, app.any_car_answered was executable by PUBLIC and public.my_any_car by anon.
--   * the server (service_role) may run every function of the app schema: three of 2421 lacked the grant.
do $$
declare t text;
begin
  foreach t in array array['showroom_backgrounds', 'site_selfqa_runs', 'reward_tier_perks'] loop
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
  end loop;
end $$;
revoke insert, update, delete on showroom_backgrounds, site_selfqa_runs, reward_tier_perks from anon, authenticated;

create trigger audit_showroom_backgrounds after insert or update or delete on showroom_backgrounds for each row execute function app.audit_row();
create trigger audit_reward_tier_perks after insert or update or delete on reward_tier_perks for each row execute function app.audit_row();

grant execute on function app.rewards_points_12m(uuid), app.rewards_has_perk(uuid, text), app.rewards_tiers_admin_do(uuid, text, jsonb) to service_role;

-- the security suite (35sec): a trigger function is not executable by PUBLIC (the server may run it), the renter's Any car answer is
-- for a signed-in session only (the account page), and leads.admin_assigned_by (2411) has its foreign key index
revoke all on function app.any_car_answered() from public, anon, authenticated;
grant execute on function app.any_car_answered() to service_role;
revoke all on function public.my_any_car() from anon;
create index if not exists leads_admin_assigned_by_idx on leads (admin_assigned_by) where admin_assigned_by is not null;
