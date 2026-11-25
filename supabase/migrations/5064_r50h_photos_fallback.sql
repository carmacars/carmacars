-- 5064 (R50 hotfix, docs/changes/2026-11-25-r50-hotfix.md): a car always shows its car.
-- What went wrong: 3701 made every public photo a studio render that passed the studio gate, and a car with none got one
-- "Photos coming soon" placeholder: the scene's empty plate (the dealership background with no car, no logo, no name). In
-- production no render had passed yet, so every card, every car page and every sample car showed the empty plate.
-- Now: a car with at least one live outside render shows its renders, as 3701 does. A car with none shows its photos exactly
-- as before release 50 (app.public_listing_photos_pre3701 and the row of app.public_listing_row_pre3701: its real photos,
-- the renders of 3150, or the built-in sample photos of 0054 with their caption). The placeholder stays only for a car that
-- would otherwise have no photo at all. The hero and the home sections fall back in the web (components/SlotCars.tsx).
-- No applied migration is edited: the 3701 functions are replaced with create or replace (same signatures, grants kept).
-- SCHEMA_MARKER 5064.
set local check_function_bodies = off;

-- a car with at least one live outside render (3701's standard); example cars never have one
create function app.photo_has_live_render(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select not coalesce((select v.is_sample from vehicles v where v.id = p_vehicle), true)
     and exists (select 1 from vehicle_photos x where x.vehicle_id = p_vehicle and app.photo_render_live(x) and app.photo_is_exterior(x.shot_type))
$$;
comment on function app.photo_has_live_render(uuid) is 'R50 hotfix (5064): the car has a live outside studio render; without one its photos are as before release 50.';
revoke all on function app.photo_has_live_render(uuid) from public, anon, authenticated;
grant execute on function app.photo_has_live_render(uuid) to service_role;

create or replace function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with r as (
    select distinct on (x.shot_type) x.* from vehicle_photos x
     where x.vehicle_id = p_vehicle and app.photo_render_live(x)
       and not coalesce((select v.is_sample from vehicles v where v.id = p_vehicle), true)
     order by x.shot_type, x.created_at desc
  ), g as (
    select jsonb_build_object('path', r.processed_path, 'variants', coalesce(r.variants, '[]'::jsonb),
             'alt', app.vehicle_name(p_vehicle) || ', ' || lower(coalesce(st.label, r.shot_type)),
             'width', coalesce(r.width, 1800), 'height', coalesce(r.height, 1200), 'shot', r.shot_type, 'label', coalesce(st.label, r.shot_type),
             'generated', true) j,
           array_position(app.photo_render_order(), r.shot_type) k
      from r left join listing_shot_types st on st.code = r.shot_type
  )
  select case
    -- 5064: no live outside render yet: the photos as before release 50; the placeholder only when there is none at all
    when not app.photo_has_live_render(p_vehicle) then
      coalesce(nullif(app.public_listing_photos_pre3701(p_vehicle), '[]'::jsonb), jsonb_build_array(app.photo_placeholder(p_vehicle)))
    else (select jsonb_agg(g.j || jsonb_build_object('is_cover', g.k = (select min(k) from g)) order by g.k) from g) end
$$;

create or replace function app.photo_row_cover(p_vehicle uuid, r jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare g jsonb; c jsonb; v_place boolean;
begin
  if r is null then return null; end if;
  -- 5064: no live outside render: the row as before release 50 (its cover, sample flag and cutout), unless it has no cover
  if not app.photo_has_live_render(p_vehicle) and jsonb_typeof(r -> 'cover') = 'object' and nullif(r #>> '{cover,path}', '') is not null then
    return r;
  end if;
  g := app.public_listing_photos(p_vehicle);
  c := g -> 0;
  v_place := coalesce((c ->> 'placeholder')::boolean, false);
  return r || jsonb_build_object(
    'cover', jsonb_build_object('path', c ->> 'path', 'variants', coalesce(c -> 'variants', '[]'::jsonb), 'alt', c ->> 'alt', 'shot', c ->> 'shot', 'width', (c ->> 'width')::integer, 'height', (c ->> 'height')::integer,
               'generated', coalesce((c ->> 'generated')::boolean, false), 'placeholder', v_place, 'sample', v_place or coalesce((c ->> 'sample')::boolean, false),
               'cutout', (select app.photo_side_cutout(p_vehicle) from site_cutouts k
                           where not v_place and k.vehicle_id = p_vehicle and k.shot = 'left' and k.source_path = c ->> 'path' limit 1)),
    'sample_photos', v_place or coalesce((c ->> 'sample')::boolean, false), 'placeholder', v_place,
    'rendered', case when v_place then 0 else jsonb_array_length(g) end);
end $$;
comment on function app.photo_row_cover(uuid, jsonb) is 'R50 hotfix (5064): with a live studio render, the cover is the gallery''s first photo (3701); without one, the row as before release 50.';

-- the listing cache and the landing pages' snapshots hold the covers again
do $$
begin
  perform app.listing_cache_refresh(array(select l.vehicle_id from vehicle_listings l where l.status in ('published', 'paused')));
  perform app.seo_snapshot_refresh();
exception when undefined_function then null;
end $$;
