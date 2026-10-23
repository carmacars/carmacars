-- 0119: the Admin switches of the vehicle pages take the sitemap index with them at once.
-- 0110 stores the shape of the vehicle sitemap index (the level files, the place and colour files per tree, the trees),
-- refreshed by the job every 30 minutes, and public.vehicle_sitemap_shape returned it whenever it was newer than the last
-- catalog import. Turning off the city and colour pages or the /buy tree (Admin > Settings > Search) changed the pages
-- at once but left their files in /sitemap.xml until the next refresh. The shape is now stored with the switches it was
-- made under; when they differ from the current ones, the shape is read live (a few milliseconds more) until the job
-- stores it again.
alter table app.vehicle_sitemap_files_cache_state add column if not exists shape_switches text;

-- the settings the shape depends on: which trees are in search and whether place and colour pages are
create or replace function app.vehicle_sitemap_switches() returns text
language sql stable security definer set search_path = public, app as $$
  select md5(coalesce(string_agg(e.key || '=' || e.value::text, ',' order by e.key), ''))
    from jsonb_each(to_jsonb(app.settings())) e
   where e.key ~ '^vpage_(.*_index|index_mode)$'
$$;

create or replace function public.vehicle_sitemap_shape() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb;
begin
  select st.shape into v from app.vehicle_sitemap_files_cache_state st
   where st.shape is not null
     and st.shape_switches is not distinct from app.vehicle_sitemap_switches()
     and st.refreshed_at >= coalesce((select max(coalesce(i.finished_at, i.started_at)) from vehicle_catalog_imports i), '-infinity');
  return coalesce(v, app.vehicle_sitemap_shape_live());
end $$;

create or replace function app.vehicle_sitemap_shape_refresh() returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('statement_timeout', '120s', true);
  update app.vehicle_sitemap_files_cache_state set shape = app.vehicle_sitemap_shape_live(), shape_switches = app.vehicle_sitemap_switches();
end $$;

revoke all on function app.vehicle_sitemap_switches(), public.vehicle_sitemap_shape(), app.vehicle_sitemap_shape_refresh() from public, anon, authenticated;
grant execute on function app.vehicle_sitemap_switches(), public.vehicle_sitemap_shape(), app.vehicle_sitemap_shape_refresh() to service_role;

select app.vehicle_sitemap_shape_refresh();
