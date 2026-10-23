-- 0110: the sitemap index files (/sitemap.xml, /sitemap-index/<n>.xml) built by the website from a small stored shape.
-- public.vehicle_sitemap_index numbered up to 50,000 files in SQL on every request: 3.4 s for one file and 7 to 12 s for a
-- full index file, so /sitemap-index/2.xml sometimes passed the 8 s limit and Search Console could not fetch it (Oct 22).
-- The numbering only needs the level files (311), how many place and colour files a tree has, and the trees (129): the
-- job of 0107 now stores those with the file list, and public.vehicle_sitemap_shape returns them in a few milliseconds.
-- The website numbers the files exactly as app.vpage_index_page does (src/features/seo/sitemap.ts).
alter table app.vehicle_sitemap_files_cache_state add column if not exists shape jsonb;

create or replace function app.vehicle_sitemap_shape_live() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'base', coalesce((select jsonb_agg(jsonb_build_object('file', f.file, 'lastmod', f.lastmod) order by f.file) from app.vehicle_sitemap_files_stored() f), '[]'::jsonb),
    'tiers', coalesce((select files from app.vpage_tier_shape()), 0),
    'trees', coalesce((select jsonb_agg(t.prefix order by t.ord) from (select prefix, row_number() over () ord from app.vpage_trees()) t), '[]'::jsonb))
$$;

-- stored when it was made after the last catalog import, else live
create or replace function public.vehicle_sitemap_shape() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb;
begin
  select st.shape into v from app.vehicle_sitemap_files_cache_state st
   where st.shape is not null
     and st.refreshed_at >= coalesce((select max(coalesce(i.finished_at, i.started_at)) from vehicle_catalog_imports i), '-infinity');
  return coalesce(v, app.vehicle_sitemap_shape_live());
end $$;
revoke all on function app.vehicle_sitemap_shape_live(), public.vehicle_sitemap_shape() from public, anon, authenticated;
grant execute on function app.vehicle_sitemap_shape_live(), public.vehicle_sitemap_shape() to service_role;

create or replace function app.vehicle_sitemap_shape_refresh() returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('statement_timeout', '120s', true);
  update app.vehicle_sitemap_files_cache_state set shape = app.vehicle_sitemap_shape_live();
end $$;
revoke all on function app.vehicle_sitemap_shape_refresh() from public, anon, authenticated;
grant execute on function app.vehicle_sitemap_shape_refresh() to service_role;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-sitemap-files', '7,37 * * * *', 'select app.vehicle_sitemap_files_refresh(); select app.vehicle_sitemap_shape_refresh()');
  end if;
end $$;
select app.vehicle_sitemap_shape_refresh();
