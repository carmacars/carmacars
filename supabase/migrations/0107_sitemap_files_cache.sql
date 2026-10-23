-- 0107: the vehicle sitemap file list, kept in a table.
-- With the catalog loaded (2,490 trims, Oct 22), app.vehicle_sitemap_files() takes about 10 s: it walks every make,
-- model, year and trim page. The sitemap index (/sitemap.xml, public.vehicle_sitemap_index) reads it on every request,
-- and anon gives up after 2.5 s (0106), so /sitemap.xml answered 500 and Search Console could not read it.
-- The list changes only when the catalog or the page switches change, so the index now reads it from a table a job
-- fills every 30 minutes (without the anon time limit). After a catalog import, until the job runs again, the live list.

create table if not exists app.vehicle_sitemap_files_cache (
  file text primary key,
  urls bigint not null,
  lastmod timestamptz
);
create table if not exists app.vehicle_sitemap_files_cache_state (
  id boolean primary key default true check (id),
  refreshed_at timestamptz not null
);
alter table app.vehicle_sitemap_files_cache enable row level security;
alter table app.vehicle_sitemap_files_cache_state enable row level security;
revoke all on app.vehicle_sitemap_files_cache, app.vehicle_sitemap_files_cache_state from public, anon, authenticated;

-- The stored list, when it was made after the last catalog import (a newer import, or none stored yet: the live list).
-- Only the sitemap index reads it; the sitemap files, IndexNow and the Admin's counts keep the live list.
create or replace function app.vehicle_sitemap_files_stored() returns table (file text, urls bigint, lastmod timestamptz)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if exists (select 1 from app.vehicle_sitemap_files_cache_state st
              where st.refreshed_at >= coalesce((select max(coalesce(i.finished_at, i.started_at)) from vehicle_catalog_imports i), '-infinity')) then
    return query select c.file, c.urls, c.lastmod from app.vehicle_sitemap_files_cache c order by c.file;
  else
    return query select * from app.vehicle_sitemap_files();
  end if;
end $$;

create or replace function app.vehicle_sitemap_files_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  perform set_config('statement_timeout', '120s', true);
  create temp table if not exists _vsf (file text, urls bigint, lastmod timestamptz) on commit drop;
  truncate _vsf;
  insert into _vsf select * from app.vehicle_sitemap_files();
  delete from app.vehicle_sitemap_files_cache c where not exists (select 1 from _vsf v where v.file = c.file);
  insert into app.vehicle_sitemap_files_cache (file, urls, lastmod) select file, urls, lastmod from _vsf
    on conflict (file) do update set urls = excluded.urls, lastmod = excluded.lastmod
    where (app.vehicle_sitemap_files_cache.urls, app.vehicle_sitemap_files_cache.lastmod) is distinct from (excluded.urls, excluded.lastmod);
  select count(*) into n from _vsf;
  insert into app.vehicle_sitemap_files_cache_state (id, refreshed_at) values (true, now())
    on conflict (id) do update set refreshed_at = excluded.refreshed_at;
  return n;
end $$;

revoke all on function app.vehicle_sitemap_files_stored(), app.vehicle_sitemap_files_refresh() from public, anon, authenticated;
grant execute on function app.vehicle_sitemap_files_stored(), app.vehicle_sitemap_files_refresh() to service_role;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-sitemap-files', '7,37 * * * *', 'select app.vehicle_sitemap_files_refresh()');
  end if;
end $$;

-- the index (0097's app.vpage_index_page) reads the stored list
create or replace function app.vpage_index_page(p_offset bigint, p_limit integer) returns table (i bigint, file text, lastmod timestamptz, total bigint)
language plpgsql stable security definer set search_path = public, app as $$
declare
  base text[]; base_lm timestamptz[]; nb integer; nt integer; per bigint; trees text[]; v_total bigint;
begin
  select coalesce(array_agg(f.file order by f.file), '{}'), coalesce(array_agg(f.lastmod order by f.file), '{}') into base, base_lm from app.vehicle_sitemap_files_stored() f;
  nb := cardinality(base);
  select files into nt from app.vpage_tier_shape();
  per := nb + coalesce(nt, 0);
  select coalesce(array_agg(t.prefix), '{}') into trees from app.vpage_trees() t;
  v_total := per * cardinality(trees);
  return query
    select x.n, trees[((x.n - 1) / per)::integer + 1] || case when (x.n - 1) % per < nb then base[((x.n - 1) % per)::integer + 1] else 'tiers-' || ((x.n - 1) % per - nb + 1) end,
           case when (x.n - 1) % per < nb then base_lm[((x.n - 1) % per)::integer + 1] end, v_total
      from generate_series(p_offset + 1, least(p_offset + greatest(p_limit, 0), v_total)) x(n);
  if v_total = 0 or p_offset >= v_total then return query select 0::bigint, null::text, null::timestamptz, v_total; end if;
end $$;

-- fill it now
select app.vehicle_sitemap_files_refresh();
