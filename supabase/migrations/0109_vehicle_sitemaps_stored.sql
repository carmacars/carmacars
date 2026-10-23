-- 0109: the vehicle sitemap files (/sitemap-vehicles/<make>-<level>.xml and makes.xml) read stored pages.
-- app.vehicle_sitemap walks the make's pages and their index rules on every request: 3.5 s for acura-models and about
-- 10 s for makes.xml with the catalog loaded, so those files answered 500 (Oct 22). 0107's job now stores every
-- indexed page's address with the file list (one walk, every 30 minutes); a file reads its rows. After a catalog
-- import, until the job runs again, the live walk (as before).

create table if not exists app.vehicle_sitemap_paths_cache (
  base text not null,
  path text not null,
  lastmod timestamptz,
  primary key (base, path)
);
alter table app.vehicle_sitemap_paths_cache enable row level security;
revoke all on app.vehicle_sitemap_paths_cache from public, anon, authenticated;

create or replace function app.vehicle_sitemap_files_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  perform set_config('statement_timeout', '300s', true);
  create temp table if not exists _vsp (base text, path text, lastmod timestamptz) on commit drop;
  truncate _vsp;
  insert into _vsp
    select case when level = 'make' then 'makes' else make_slug || '-' || level || 's' end, path, max(lastmod)
      from app.vpage_all() where indexable group by 1, 2;
  delete from app.vehicle_sitemap_paths_cache c where not exists (select 1 from _vsp v where v.base = c.base and v.path = c.path);
  insert into app.vehicle_sitemap_paths_cache (base, path, lastmod) select base, path, lastmod from _vsp
    on conflict (base, path) do update set lastmod = excluded.lastmod
    where app.vehicle_sitemap_paths_cache.lastmod is distinct from excluded.lastmod;
  -- the file list, as app.vehicle_sitemap_files() makes it, from the same walk
  create temp table if not exists _vsf (file text, urls bigint, lastmod timestamptz) on commit drop;
  truncate _vsf;
  insert into _vsf
    with n as (select base, path, lastmod, (row_number() over (partition by base order by path) - 1) / 45000 + 1 part, count(*) over (partition by base) total from _vsp)
    select case when max(total) > 45000 then base || '-' || part else base end, count(*), max(lastmod) from n group by base, part;
  delete from app.vehicle_sitemap_files_cache c where not exists (select 1 from _vsf v where v.file = c.file);
  insert into app.vehicle_sitemap_files_cache (file, urls, lastmod) select file, urls, lastmod from _vsf
    on conflict (file) do update set urls = excluded.urls, lastmod = excluded.lastmod
    where (app.vehicle_sitemap_files_cache.urls, app.vehicle_sitemap_files_cache.lastmod) is distinct from (excluded.urls, excluded.lastmod);
  select count(*) into n from _vsf;
  insert into app.vehicle_sitemap_files_cache_state (id, refreshed_at) values (true, now())
    on conflict (id) do update set refreshed_at = excluded.refreshed_at;
  return n;
end $$;

-- one file's addresses: stored when the store is newer than the last catalog import, else the live walk
create or replace function app.vehicle_sitemap_stored(p_file text) returns table (path text, lastmod timestamptz)
language plpgsql stable security definer set search_path = public, app as $$
declare v_base text; v_part integer; v_numbered boolean;
begin
  if not exists (select 1 from app.vehicle_sitemap_files_cache_state st
                  where st.refreshed_at >= coalesce((select max(coalesce(i.finished_at, i.started_at)) from vehicle_catalog_imports i), '-infinity')) then
    return query select s.path, s.lastmod from app.vehicle_sitemap(p_file) s;
    return;
  end if;
  v_base := coalesce(substring(p_file from '^(.*-(?:models|years|trims))-[0-9]+$'), p_file);
  v_part := coalesce(substring(p_file from '-([0-9]+)$')::integer, 1);
  v_numbered := p_file ~ '-(models|years|trims)-[0-9]+$';
  return query
    with a as (select c.path, c.lastmod, row_number() over (order by c.path) rn, count(*) over () total
                 from app.vehicle_sitemap_paths_cache c where c.base = v_base)
    select a.path, a.lastmod from a
     where (v_numbered and a.total > 45000 and a.rn > (v_part - 1) * 45000 and a.rn <= v_part * 45000)
        or (not v_numbered and a.total <= 45000)
     order by a.path;
end $$;
revoke all on function app.vehicle_sitemap_stored(text) from public, anon, authenticated;
grant execute on function app.vehicle_sitemap_stored(text) to service_role;

create or replace function public.vehicle_sitemap(p_file text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('path', s.path, 'lastmod', s.lastmod) order by s.path), '[]'::jsonb) from app.vehicle_sitemap_stored(p_file) s
$$;

select app.vehicle_sitemap_files_refresh();

-- The place roots (the top places and the 24 biggest cities on /car-rental, /detailing and /body-shop) take about 4.6 s
-- over 475,802 places, past a visitor's 2.5 s, so /body-shop answered the busy page (Oct 22). They change only with a
-- places import or a region switch: stored by the same job, read from the store when it is under an hour old and newer than the last places load.
create table if not exists app.place_roots_cache (
  id boolean primary key default true check (id),
  roots jsonb not null,
  refreshed_at timestamptz not null
);
alter table app.place_roots_cache enable row level security;
revoke all on app.place_roots_cache from public, anon, authenticated;

create or replace function app.place_roots_live() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'tops', (select coalesce(jsonb_agg(app.place_brief(p) order by p.kind, (select r.sort_order from place_regions r where r.id = p.region_id) nulls first, p.name), '[]'::jsonb)
               from places p where (p.kind in (1, 4) or (p.kind = 2 and p.country = 'CA')) and app.place_enabled(p)),
    'cities', (select coalesce(jsonb_agg(app.place_brief(c) order by c.population desc nulls last), '[]'::jsonb)
                 from (select * from places c where c.kind = 5 and c.flags & 1 <> 0 and c.landing_slug is null and c.is_active order by c.population desc nulls last limit 24) c),
    'attribution', jsonb_build_object('geonames', exists (select 1 from places where flags & 34 <> 0), 'osm', exists (select 1 from places where flags & 4 <> 0)))
$$;

create or replace function public.place_roots() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select c.roots from app.place_roots_cache c
                     where c.refreshed_at > now() - interval '1 hour'
                       and c.refreshed_at >= coalesce((select max(coalesce(i.finished_at, i.started_at)) from place_imports i), '-infinity')
                       and c.refreshed_at >= coalesce((select max(r.loaded_at) from place_regions r), '-infinity')),
                  app.place_roots_live())
$$;

create or replace function app.place_roots_refresh() returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('statement_timeout', '120s', true);
  insert into app.place_roots_cache (id, roots, refreshed_at) values (true, app.place_roots_live(), now())
    on conflict (id) do update set roots = excluded.roots, refreshed_at = excluded.refreshed_at;
end $$;
revoke all on function app.place_roots_live(), app.place_roots_refresh() from public, anon, authenticated;
grant execute on function app.place_roots_live(), app.place_roots_refresh() to service_role;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-place-roots', '2,22,42 * * * *', 'select app.place_roots_refresh()');
  end if;
end $$;
select app.place_roots_refresh();
