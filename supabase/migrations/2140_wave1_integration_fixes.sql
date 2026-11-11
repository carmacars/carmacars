-- 2140_wave1_integration_fixes.sql
-- Release 35 wave 1: the integration fixes of the combined r35 + r36 release (the database checks of 03, 04 and 99 r35sec
-- run over every table and function, so the r36 additions are brought under them here). SCHEMA_MARKER 2140. No applied
-- migration is edited.
--   1. Audit: auto_replies (every question seen and what was done) and address_imports (each run of the addresses
--      workflow) get the row audit. ca_addresses is bulk reference data loaded by the workflow (millions of rows, each run
--      recorded in address_imports) and is listed as exempt in 03_flows, like places and vehicle_specs.
--   2. The standard admin policy (admin_all) on auto_replies, ca_addresses and address_imports. The browser grants are
--      unchanged (auto_replies and address_imports: select only; ca_addresses: none), so this adds no write path.
--   3. SECURITY DEFINER functions of 2002, 2003 and 2004 were still executable by PUBLIC: revoked from PUBLIC, keeping
--      their explicit grants (anon, authenticated, service_role), the same loop as 1600.
--   4. The public reads r35/r36 added to the anonymous door (airport_pages, calc_rental_charge_tiers, delivery_to_point,
--      fleet_popular_ids, rent_vs_own_inputs, rent_vs_own_page, review_summary, seo_event, seo_events_list,
--      seo_i18n_bundle, seo_languages_state, sitemap_families, sitemap_languages, tracker_product) are pinned in the
--      allow-list of 99_r35sec_security. Each was checked: stable or immutable, no writes, only data the public pages
--      show (calc_rental_charge_tiers is the immutable calculator calc_rental_charge was before 1200, inputs only;
--      fleet_popular_ids returns the ids of published cars the job flagged popular, which the public fleet already shows).
--   5. Indexes on the join-path foreign keys auto_replies(outbox_id), seo_strings(key), listing_covers(photo_id) and
--      listing_covers(job_id).

-- ================================================================ 1. audit
drop trigger if exists audit_auto_replies on auto_replies;
create trigger audit_auto_replies after insert or update or delete on auto_replies for each row execute function app.audit_row();
drop trigger if exists audit_address_imports on address_imports;
create trigger audit_address_imports after insert or update or delete on address_imports for each row execute function app.audit_row();

-- ================================================================ 2. the admin policy
drop policy if exists admin_all on auto_replies;
create policy admin_all on auto_replies for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists admin_all on ca_addresses;
create policy admin_all on ca_addresses for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy if exists admin_all on address_imports;
create policy admin_all on address_imports for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- ================================================================ 3. no SECURITY DEFINER function executable by PUBLIC
do $$
declare
  f record;
  g text;
begin
  for f in
    select p.oid::regprocedure sig,
           coalesce((select array_agg(r.rolname) from aclexplode(p.proacl) a join pg_roles r on r.oid = a.grantee
                      where a.privilege_type = 'EXECUTE' and r.rolname in ('anon', 'authenticated', 'service_role')), '{}') explicit
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'app') and p.prosecdef
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
       and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))
  loop
    execute format('revoke execute on function %s from public', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
    foreach g in array f.explicit loop
      execute format('grant execute on function %s to %I', f.sig, g);
    end loop;
  end loop;
end $$;

-- ================================================================ 5. foreign key indexes
create index if not exists auto_replies_outbox on auto_replies (outbox_id) where outbox_id is not null;
create index if not exists seo_strings_key on seo_strings (key);
create index if not exists listing_covers_photo on listing_covers (photo_id);
create index if not exists listing_covers_job on listing_covers (job_id);
