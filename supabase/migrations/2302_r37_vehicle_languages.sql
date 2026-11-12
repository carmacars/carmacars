-- 2302_r37_vehicle_languages.sql (release 37)
-- The vehicle pages' multipliers in the 18 languages (2004's path), only where real cars back them: no thin or made-up
-- page. For every real car on the site (published, not a sample, matched to a catalog trim):
--   /<lang>/cars/<make>/<model>/<year>/<trim>                      the trim
--   /<lang>/cars/<make>/<model>/<year>/<trim>/<place>              the trim in each of the top places (Program setting)
--   /<lang>/cars/<make>/<model>/<year>/<trim>/<place>/<colour>     the trim in each place, in the colour of a real car
--   /<lang>/t/<term>/<make>/<model>/<year>/<trim>                  per-car service pages: detailing terms, and the rentals
--                                                                  for drivers with a DUI, a suspension or a bad record that
--                                                                  the existing terms serve
-- The English twins keep their own rules (0097, 0098); the place and colour switches (vpage_place_index,
-- vpage_colour_index) and the term switch (vpage_term_index) apply here too. A language page whose path is not in this set
-- is a 404; a language under its coverage is noindex (2004). The language sitemap lists them with hreflang alternates.

alter table program_settings add column if not exists seo_i18n_vehicle_places integer not null default 12 check (seo_i18n_vehicle_places between 0 and 200);
comment on column program_settings.seo_i18n_vehicle_places is 'Languages (2302): how many places (the largest first) multiply each real car''s trim page in every language (0 = the trim pages only).';

create or replace function app.vehicle_language_paths() returns table (path text, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  with s as (select * from app.settings()),
  cars as (select c.make_slug, c.model_slug, c.year, c.trim_slug, vc.slug colour, coalesce(c.content_updated_at, c.first_published_at) m
             from app.vpage_cars() c join vehicles v on v.id = c.vehicle_id
             left join vehicle_colours vc on vc.slug = lower(btrim(coalesce(v.colour, '')))
            where not c.is_sample and c.trim_slug is not null and c.model_slug is not null and c.year is not null),
  base as (select app.vpage_path(make_slug, model_slug, year, trim_slug) p, colour, max(m) m from cars group by 1, 2),
  places as (select l.slug from app.vpage_landing_places() l, s where s.vpage_place_index
              order by nullif(l.facts ->> 'population', '')::numeric desc nulls last, l.slug limit (select seo_i18n_vehicle_places from s)),
  terms as (select t.slug from place_terms t, s where s.vpage_term_index and t.is_active and t.canonical_slug is null and t.served = 'yes'
               and (t.vertical = 'detailing' or t.slug ~ '(^|-)(dui|suspend|suspended|suspension|bad-driv|driving-record|bad-record)'))
  select x.path, max(x.m) from (
    select b.p path, b.m from base b
    union all select b.p || '/' || pl.slug, b.m from base b cross join places pl
    union all select b.p || '/' || pl.slug || '/' || b.colour, b.m from base b cross join places pl, s where b.colour is not null and s.vpage_colour_index
    union all select '/t/' || t.slug || substr(b.p, 6), b.m from base b cross join terms t) x
  group by x.path
$$;
comment on function app.vehicle_language_paths() is 'Release 37 (2302): the vehicle and per-car service pages that have language versions: only combinations backed by a real car on the site.';

-- one path (no language prefix): is it a language-backed page
create or replace function public.vehicle_language_ok(p_path text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from app.vehicle_language_paths() x where x.path = p_path)
$$;

-- the language sitemap: 2004's pages plus these
create or replace function public.sitemap_languages() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with ready as (select x ->> 'code' code, x ->> 'hreflang' hreflang from jsonb_array_elements(public.seo_languages_state()) x where (x ->> 'ready')::boolean),
  pages as (select '/car-rental/' || slug path, content_updated_at lastmod from seo_pages where is_active and app.seo_page_indexable(seo_pages)
            union all select '/events/' || slug, updated_at from seo_events where is_active
            union all select '/airport-car-rental/' || lower(code), updated_at from airports where is_active
            union all select v.path, v.lastmod from app.vehicle_language_paths() v)
  select jsonb_build_object('languages', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'hreflang', hreflang)) from ready), '[]'::jsonb),
                            'pages', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'lastmod', lastmod)) from pages), '[]'::jsonb))
$$;

revoke all on function app.vehicle_language_paths() from public, anon, authenticated;
grant execute on function app.vehicle_language_paths() to service_role;
grant execute on function public.vehicle_language_ok(text) to anon, authenticated, service_role;
