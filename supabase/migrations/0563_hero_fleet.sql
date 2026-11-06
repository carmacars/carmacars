-- 0563_hero_fleet.sql
-- Release 28 (docs/changes/2026-11-06-r28-platform.md, B5): the home page's hero shows real cars of the fleet, each on the
-- black studio of the sample cars (the listing photo worker's studio preset, studio_v2 and later), one after another.
-- Only a car on the site (its listing published) whose cover photo (the front three-quarter shot) went through the studio
-- and is approved and public. The home page reads this when it is rebuilt (hourly, an edge copy): never per visit. With
-- none, the hero keeps the sample car photo of Admin > Site content.
create or replace function app.site_hero_photos(p_limit integer default 6) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x.j order by x.o), '[]'::jsonb) from (
    select jsonb_build_object('vehicle_id', ph.vehicle_id, 'path', ph.processed_path, 'width', coalesce(ph.width, 2400), 'height', coalesce(ph.height, 1600), 'alt', ph.alt_text) j,
           row_number() over (order by l.pinned_rank nulls last, coalesce(t.score, 0) desc, ph.vehicle_id) o
      from (select distinct on (p.vehicle_id) p.* from vehicle_photos p
             where p.is_cover and p.is_public and p.status = 'approved' and p.replaced_at is null and p.processed_path is not null
               and p.background_status = 'done' and p.preset_version like 'studio%' and p.processed_path !~ '^/'
             order by p.vehicle_id, p.sort_order, p.created_at desc) ph
      join vehicle_listings l on l.vehicle_id = ph.vehicle_id and l.status = 'published'
      join vehicles v on v.id = ph.vehicle_id and not coalesce(v.is_sample, false) and v.retired_at is null
      left join app.fleet_trend t on t.vehicle_id = ph.vehicle_id
     order by o limit least(greatest(coalesce(p_limit, 6), 1), 12)) x
$$;
create or replace function public.site_hero_photos(p_limit integer default 6) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.site_hero_photos(p_limit) $$;
revoke all on function app.site_hero_photos(integer) from public, anon, authenticated;
revoke all on function public.site_hero_photos(integer) from public;
grant execute on function public.site_hero_photos(integer) to anon, authenticated, service_role;
comment on function public.site_hero_photos(integer) is 'The home hero''s real cars (0563): published cars whose approved cover photo is on the studio background; public photos only.';
