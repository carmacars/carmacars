-- 0126_fleet_order.sql
-- The public fleet in one order, always. app.public_fleet sorted its cars by featured, daily rate and first publication
-- time only; cars published in the same transaction share that time, so cars at the same rate came out in whatever
-- order the query plan read them. A different plan (after the statistics change, for example) swapped them, and every
-- landing page and place term that lists such cars saw "new" cars: seo_snapshot_refresh rewrote their snapshots, moved
-- their sitemap dates (cars_changed_at) and queued them for IndexNow, with no change to the fleet (suite 47 caught it:
-- the second refresh in a row rewrote 19 pages when the plan changed). The car's id now breaks the last tie, so the
-- fleet, the snapshots and the live pages (which all sort the same input) are the same every time.
create or replace function app.public_fleet(p_filters jsonb default '{}'::jsonb) returns setof jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  return query
  select q.r from (
    select app.public_listing_row(l.vehicle_id) r, l.is_featured, l.first_published_at, l.vehicle_id
      from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     where l.status = 'published' and v.management_mode <> 'turo_only'
       and (p_filters ->> 'class' is null or app.vehicle_in_classes(v.id, array[p_filters ->> 'class']))
       and (jsonb_typeof(p_filters -> 'classes') is distinct from 'array'
            or app.vehicle_in_classes(v.id, array(select jsonb_array_elements_text(p_filters -> 'classes'))))
       and (p_filters ->> 'make' is null or app.slugify(v.make) = app.slugify(p_filters ->> 'make'))
       and (p_filters ->> 'model' is null or app.slugify(v.model) = app.slugify(p_filters ->> 'model'))
       and (p_filters ->> 'fuel' is null or v.fuel::text = p_filters ->> 'fuel')
       and (p_filters ->> 'body_style' is null or lower(coalesce(l.body_style, v.body_type)) = lower(p_filters ->> 'body_style'))
       and (not coalesce((p_filters ->> 'featured')::boolean, false) or l.is_featured)
     offset 0) q
   where q.r is not null
   order by q.is_featured desc, (q.r ->> 'daily_rate_cents')::bigint nulls last, q.first_published_at, q.vehicle_id;
end $$;
