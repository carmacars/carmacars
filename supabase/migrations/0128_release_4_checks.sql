-- 0128: the release 4 checks (docs/changes/2026-10-23-release-4-checks.md)
--
-- 1. The owner emails name the payee of the pre-authorized debit by the business name, CarmaCars. 0122 made
--    app.owner_payee_name() the legal name alone for the agreements (the owner: "Agreements need to just say the
--    numbered corp, no operating as"), and every owner email took it too (payee_name: the Payee row, the sender line
--    above the mailing address, the confirmation's subject, and the copy of the debit agreement in the confirmation):
--    the emails showed the numbered company, which the brand rule never allows in an email or a page. The agreements,
--    their PDFs, the countersignature and the Banking page keep the legal name alone; only the emails' values change.
-- 2. The make pages of the fleet's makes the catalog does not cover (/cars/bmw, 0097: they list our cars of that make)
--    are in a sitemap: the hubs file (public.sitemap_hubs) lists the model pages of the fleet's cars, without those the
--    vehicle sitemaps already list (each address in one sitemap file), and those make pages. /cars links them
--    (public.vehicle_fleet_makes).

-- ================================================================ 1. the payee in the owner emails
create or replace function app.owner_email_payee_name() returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(btrim(s.company_trade_name), ''), 'CarmaCars') from app.settings() s
$$;
revoke all on function app.owner_email_payee_name() from public, anon, authenticated;
grant execute on function app.owner_email_payee_name() to service_role;

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0128;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0128(p_code, p_event, p_to);
  v_legal text;
  v_email text;
begin
  if p_code not like 'owner\_%' then return x; end if;
  v_legal := app.owner_payee_name();
  v_email := app.owner_email_payee_name();
  if x ? 'payee_name' then x := x || jsonb_build_object('payee_name', v_email); end if;
  -- the confirmation carries the debit agreement: its first paragraph names the payee
  if x ? 'agreement_1' and v_legal is distinct from v_email then
    x := x || jsonb_build_object('agreement_1', replace(x ->> 'agreement_1', 'You authorize ' || v_legal || ' to debit', 'You authorize ' || v_email || ' to debit'));
  end if;
  return x;
end $$;
revoke all on function app.notification_payload(text, app_events, jsonb) from public, anon, authenticated;
revoke all on function app.ntf_payload_pre0128(text, app_events, jsonb) from public, anon, authenticated;
grant execute on function app.notification_payload(text, app_events, jsonb) to service_role;

-- ================================================================ 2. the fleet's make pages in the hubs sitemap
-- The makes of our published cars that the vehicle catalog does not cover: each has its make page (app.vehicle_make_page).
create or replace function app.vpage_fleet_makes() returns table (slug text, name text, path text)
language sql stable security definer set search_path = public, app as $$
  select c.make_slug, min(v.make), app.vpage_path(c.make_slug)
    from app.vpage_cars() c join vehicles v on v.id = c.vehicle_id
   where c.make_slug is not null and not exists (select 1 from vehicle_catalog_makes m where m.slug = c.make_slug)
   group by c.make_slug
$$;
revoke all on function app.vpage_fleet_makes() from public, anon, authenticated;
grant execute on function app.vpage_fleet_makes() to service_role;

-- For /cars ("Browse by make"): the fleet's makes beside the catalog's (public.vehicle_makes)
create or replace function public.vehicle_fleet_makes() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', f.slug, 'name', f.name, 'path', f.path, 'models', 0) order by f.name), '[]'::jsonb)
    from app.vpage_fleet_makes() f
$$;
revoke all on function public.vehicle_fleet_makes() from public;
grant execute on function public.vehicle_fleet_makes() to anon, authenticated, service_role;

-- The hubs sitemap (/sitemap-hubs.xml, 0102): the model pages of the fleet's cars that the vehicle sitemaps do not list
-- (a model of the catalog is in its make's models file while those files are on), then the fleet's make pages the
-- catalog does not cover, when in search.
create or replace function public.sitemap_hubs() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with h as materialized (select s.path, s.lastmod from public.sitemap_all() s where s.kind = 'model_hub'),
       on_ as materialized (select public.vehicle_sitemap_tree('') v),
       listed as materialized (
         select x.path from (select distinct split_part(h.path, '/', 3) make from h) m
          cross join lateral app.vehicle_sitemap_stored(m.make || '-models') x
          where (select v from on_)),
       mk as materialized (select f.path, app.vehicle_make_page(f.slug) pg from app.vpage_fleet_makes() f)
  select coalesce(jsonb_agg(jsonb_build_object('path', r.path, 'lastmod', r.lastmod) order by r.o, r.path), '[]'::jsonb)
    from (select h.path, h.lastmod, 0 o from h where not exists (select 1 from listed l where l.path = h.path)
          union all
          select mk.path, (mk.pg ->> 'lastmod')::timestamptz, 1 from mk where coalesce((mk.pg ->> 'indexable')::boolean, false)) r
$$;
revoke all on function public.sitemap_hubs() from public, anon, authenticated;
grant execute on function public.sitemap_hubs() to service_role;
