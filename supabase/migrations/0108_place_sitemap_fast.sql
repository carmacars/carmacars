-- 0108: a place sitemap file in a third of a second instead of ten.
-- 0095's public.place_sitemap expanded (app.settings()).* in an inlined CTE, so the settings were read again for every
-- place it looked at (25,000 a file): about 9.5 s a file, past the 8 s limit, and some /sitemap-places files answered 500
-- (Oct 22). The settings, the term, the origin and the switched-on regions are now read once (materialized); same rows.
create or replace function public.place_sitemap(p_vertical text, p_term text, p_page integer) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as materialized (select * from app.settings()),
       t as materialized (select * from place_terms where slug = p_term and vertical = p_vertical and is_active and canonical_slug is null),
       o as materialized (select app.place_origin() o),
       en as materialized (select id from place_regions where is_enabled),
       ec as materialized (select distinct country from place_regions where is_enabled)
  select coalesce(jsonb_agg(jsonb_build_object('path', app.place_hub_path(t.vertical, t.slug, p.slug), 'lastmod', p.updated_on) order by p.id), '[]'::jsonb)
    from s, t, o, places p
   where p.id > (greatest(p_page, 1) - 1) * s.place_sitemap_file_urls and p.id <= greatest(p_page, 1) * s.place_sitemap_file_urls
     and p.is_active and p.kind <> 8 and (p.region_id in (select id from en) or (p.kind = 1 and p.country in (select country from ec)))
     and not (t.vertical = 'rental' and t.slug = 'car-rental' and p.landing_slug is not null)
     and not (t.vertical = 'rental' and t.landing_slug is not null and p.slug = 'toronto')
     and (not s.place_quality_gate or p.kind in (1, 2, 4)
          or app.distance_km((o.o ->> 'lat')::numeric, (o.o ->> 'lng')::numeric, p.lat::numeric, p.lng::numeric) <= s.place_delivery_reach_km)
$$;
