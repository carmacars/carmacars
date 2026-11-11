-- 2004_r36s_languages_sitemaps.sql
-- Release 36, SEO (docs/changes/2026-11-11-r36-seo-growth.md), parts 2, 9, 10 and 11.
--   2. Languages: the search pages in the GTA's most spoken languages (/fr/..., /pa/..., hreflang both ways). The
--      templates' English strings (web/src/features/i18n/catalog.ts) are stored as data (seo_string_sources, synced by
--      the seo-i18n workflow) and their translations in seo_strings (machine translated once by the workflow with the
--      Workers AI translation model within its free allowance, or reviewed by a person). A language is "ready" when
--      seo_i18n_min_coverage_bps of the current strings are translated (90% by default): only then are its pages
--      indexed, listed in the sitemaps and named in hreflang; before that they render with English for the missing
--      strings (marked for translation) and noindex.
--   9. Sitemaps: one file for the new page families (events, airports, the GPS tracker, renting vs owning of the
--      popular models) and one per ready language with hreflang alternates; lastmod from each row's own date.
--  10. Delivery to a point (an event venue) the way a place page counts it (0095 app.place_delivery).
--  11. Renting vs owning: the page's inputs from the catalog's slugs, and the cities with a city page.
-- No applied migration is edited.

-- ================================================================ 2. languages
create table if not exists seo_languages (
  code        text primary key check (code ~ '^[a-z]{2,3}$'),
  name        text not null check (length(name) between 2 and 40),
  native_name text not null check (length(native_name) between 1 and 40),
  hreflang    text not null check (hreflang ~ '^[a-z]{2,3}(-[A-Za-z]{2,4})?(-[A-Z]{2})?$'),
  dir         text not null default 'ltr' check (dir in ('ltr', 'rtl')),
  mt_code     text check (mt_code is null or mt_code ~ '^[a-z]{2,3}$'),
  is_active   boolean not null default true,
  sort_order  integer not null default 100
);
comment on table seo_languages is 'The languages of the search pages (2004): the GTA''s most spoken after English. mt_code: the code the translation model takes (null: no machine translation, a person translates).';
insert into seo_languages (code, name, native_name, hreflang, dir, mt_code, sort_order) values
  ('fr', 'French', 'Français', 'fr-CA', 'ltr', 'fr', 10), ('pa', 'Punjabi', 'ਪੰਜਾਬੀ', 'pa', 'ltr', 'pa', 20), ('zh', 'Mandarin', '中文', 'zh-Hans', 'ltr', 'zh', 30),
  ('yue', 'Cantonese', '廣東話', 'zh-Hant', 'ltr', null, 40), ('ar', 'Arabic', 'العربية', 'ar', 'rtl', 'ar', 50), ('ur', 'Urdu', 'اردو', 'ur', 'rtl', 'ur', 60),
  ('tl', 'Tagalog', 'Tagalog', 'tl', 'ltr', 'tl', 70), ('es', 'Spanish', 'Español', 'es', 'ltr', 'es', 80), ('pt', 'Portuguese', 'Português', 'pt', 'ltr', 'pt', 90),
  ('it', 'Italian', 'Italiano', 'it', 'ltr', 'it', 100), ('ta', 'Tamil', 'தமிழ்', 'ta', 'ltr', 'ta', 110), ('fa', 'Farsi', 'فارسی', 'fa', 'rtl', 'fa', 120),
  ('ko', 'Korean', '한국어', 'ko', 'ltr', 'ko', 130), ('ru', 'Russian', 'Русский', 'ru', 'ltr', 'ru', 140), ('hi', 'Hindi', 'हिन्दी', 'hi', 'ltr', 'hi', 150),
  ('gu', 'Gujarati', 'ગુજરાતી', 'gu', 'ltr', 'gu', 160), ('vi', 'Vietnamese', 'Tiếng Việt', 'vi', 'ltr', 'vi', 170), ('pl', 'Polish', 'Polski', 'pl', 'ltr', 'pl', 180)
on conflict (code) do nothing;

create table if not exists seo_string_sources (
  key        text primary key check (key ~ '^[a-z0-9_.]{2,80}$'),
  text       text not null check (length(text) between 1 and 1000),
  hash       text not null,
  updated_at timestamptz not null default now()
);
comment on table seo_string_sources is 'The English strings of the language templates (2004), synced from web/src/features/i18n/catalog.ts by the seo-i18n workflow; hash = md5(text).';
create table if not exists seo_strings (
  lang        text not null references seo_languages (code) on delete cascade,
  key         text not null references seo_string_sources (key) on delete cascade,
  text        text not null check (length(text) between 1 and 2000),
  source_hash text not null,
  status      text not null default 'machine' check (status in ('machine', 'reviewed')),
  updated_at  timestamptz not null default now(),
  primary key (lang, key)
);
comment on table seo_strings is 'Translations of the language templates (2004). A row whose source_hash differs from its source''s is stale and not used. status reviewed: checked by a person.';

alter table program_settings add column if not exists seo_i18n_min_coverage_bps integer not null default 9000 check (seo_i18n_min_coverage_bps between 0 and 10000);
comment on column program_settings.seo_i18n_min_coverage_bps is 'Languages (2004): the share of the current template strings translated before a language''s pages are indexed and named in hreflang (9,000 = 90%).';

do $$
declare t text;
begin
  foreach t in array array['seo_languages', 'seo_string_sources', 'seo_strings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant select, insert, update, delete on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('drop trigger if exists %I on %I', 'audit_' || t, t);
    execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
  end loop;
end $$;

-- the languages with their coverage and whether they are ready
create or replace function public.seo_languages_state() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with n as (select count(*) total from seo_string_sources),
  c as (select s.lang, count(*) done from seo_strings s join seo_string_sources x on x.key = s.key and x.hash = s.source_hash group by s.lang)
  select coalesce(jsonb_agg(jsonb_build_object('code', l.code, 'name', l.name, 'native_name', l.native_name, 'hreflang', l.hreflang, 'dir', l.dir,
           'coverage_bps', case when n.total > 0 then (coalesce(c.done, 0) * 10000 / n.total)::integer else 0 end,
           'ready', n.total > 0 and coalesce(c.done, 0) * 10000 >= n.total * (app.settings()).seo_i18n_min_coverage_bps) order by l.sort_order), '[]'::jsonb)
    from seo_languages l cross join n left join c on c.lang = l.code where l.is_active
$$;

-- a language's strings (current ones only) for the templates
create or replace function public.seo_i18n_bundle(p_lang text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('lang', (select to_jsonb(l) from seo_languages l where l.code = p_lang and l.is_active),
    'strings', coalesce((select jsonb_object_agg(s.key, s.text) from seo_strings s join seo_string_sources x on x.key = s.key and x.hash = s.source_hash where s.lang = p_lang), '{}'::jsonb))
$$;

-- the workflow: {sources: [{key, text}]} replaces the source list; {strings: [{lang, key, text, source_hash, status?}]} upserts
-- (a reviewed translation is never overwritten by a machine one); {missing: true} returns what to translate
create or replace function app.server_i18n_load(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb; n integer := 0; m integer := 0;
begin
  if p ? 'sources' then
    for r in select * from jsonb_array_elements(p -> 'sources') loop
      insert into seo_string_sources (key, text, hash) values (r ->> 'key', r ->> 'text', md5(r ->> 'text'))
      on conflict (key) do update set text = excluded.text, hash = excluded.hash, updated_at = now() where seo_string_sources.hash <> excluded.hash;
      n := n + 1;
    end loop;
    delete from seo_string_sources where key not in (select x ->> 'key' from jsonb_array_elements(p -> 'sources') x);
  end if;
  if p ? 'strings' then
    for r in select * from jsonb_array_elements(p -> 'strings') loop
      insert into seo_strings (lang, key, text, source_hash, status) values (r ->> 'lang', r ->> 'key', r ->> 'text', r ->> 'source_hash', coalesce(r ->> 'status', 'machine'))
      on conflict (lang, key) do update set text = excluded.text, source_hash = excluded.source_hash, status = excluded.status, updated_at = now()
       where seo_strings.status = 'machine' or excluded.status = 'reviewed' or seo_strings.source_hash <> excluded.source_hash;
      m := m + 1;
    end loop;
  end if;
  return jsonb_build_object('sources', n, 'strings', m,
    'missing', case when coalesce((p ->> 'missing')::boolean, false) then (
      select coalesce(jsonb_agg(jsonb_build_object('lang', l.code, 'mt_code', l.mt_code, 'key', x.key, 'text', x.text, 'hash', x.hash)), '[]'::jsonb)
        from seo_languages l cross join seo_string_sources x
       where l.is_active and l.mt_code is not null
         and not exists (select 1 from seo_strings s where s.lang = l.code and s.key = x.key and s.source_hash = x.hash)) end);
end $$;

-- ================================================================ 10. delivery to a point (an event venue)
create or replace function public.delivery_to_point(p_lat numeric, p_lng numeric) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_km numeric;
  v_base bigint;
  v_fee bigint;
begin
  if p_lat is null or p_lng is null or s.company_latitude is null or s.company_longitude is null then return jsonb_build_object('km', null); end if;
  v_km := round(app.distance_km(s.company_latitude, s.company_longitude, p_lat, p_lng)::numeric, 1);
  if v_km > s.place_delivery_reach_km then return jsonb_build_object('in_reach', false, 'km', v_km, 'reach_km', s.place_delivery_reach_km); end if;
  v_base := app.place_base_delivery_cents();
  if v_base is not null then
    v_fee := v_base;
    if s.delivery_per_km_cents > 0 then
      v_fee := v_base + round(s.delivery_per_km_cents * v_km)::bigint;
      if s.delivery_min_cents is not null then v_fee := greatest(v_fee, s.delivery_min_cents); end if;
      if s.delivery_max_cents is not null then v_fee := least(v_fee, s.delivery_max_cents); end if;
      v_fee := (round(v_fee::numeric / s.delivery_round_cents) * s.delivery_round_cents)::bigint;
    end if;
  end if;
  return jsonb_build_object('in_reach', true, 'km', v_km, 'reach_km', s.place_delivery_reach_km, 'fee_from_cents', v_fee);
end $$;

-- ================================================================ 11. renting vs owning: the page by the catalog's slugs
create or replace function public.rent_vs_own_page(p_make text, p_model text, p_year integer, p_city text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  mk vehicle_catalog_makes; md vehicle_catalog_models; v_city jsonb;
begin
  select * into mk from vehicle_catalog_makes where slug = p_make;
  select * into md from vehicle_catalog_models where make_slug = p_make and slug = p_model;
  if mk.slug is null or md.slug is null or not exists (select 1 from vehicle_catalog_years where make_slug = p_make and model_slug = p_model and year = p_year) then return null; end if;
  if p_city is not null then
    select jsonb_build_object('slug', p.slug, 'name', p.name) into v_city from places p where p.slug = p_city and p.kind = 5 and app.place_enabled(p);
    if v_city is null then return null; end if;
  end if;
  return jsonb_build_object('make', mk.name, 'model', md.name, 'year', p_year, 'make_slug', mk.slug, 'model_slug', md.slug, 'city', v_city,
    'years', (select coalesce(jsonb_agg(y.year order by y.year desc), '[]'::jsonb) from vehicle_catalog_years y where y.make_slug = p_make and y.model_slug = p_model and y.year >= extract(year from now())::integer - 11),
    'cities', (select coalesce(jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name) order by x.km), '[]'::jsonb)
                 from (select p.slug, p.name, app.place_km(p) km from places p where p.kind = 5 and app.place_enabled(p) and app.place_km(p) <= (app.settings()).place_delivery_reach_km
                        order by app.place_km(p) limit 20) x))
    || public.rent_vs_own_inputs(mk.name, md.name, p_year, p_city);
end $$;

-- ================================================================ 9. the sitemap of the new page families
-- events (their own dates), airports, the GPS tracker (when on), the renting vs owning pages of the popular models of
-- the last 12 model years (and the 20 nearest cities for the newest 3), the language hubs of the ready languages
create or replace function public.sitemap_families() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select (app.settings()).*),
  ev as (select '/events/' || slug path, updated_at lastmod from seo_events where is_active),
  ap as (select '/airport-car-rental/' || lower(code) path, updated_at lastmod from airports where is_active),
  pop as (select y.make_slug, y.model_slug, y.year::integer y from vehicle_catalog_popular p join vehicle_catalog_years y on y.make_slug = p.make_slug and y.model_slug = p.model_slug
           where y.year >= extract(year from now())::integer - 11),
  cities as (select p.slug from places p, s where p.kind = 5 and app.place_enabled(p) and app.place_km(p) <= s.place_delivery_reach_km order by app.place_km(p) limit 20),
  rvo as (select '/rent-vs-own/' || make_slug || '/' || model_slug || '/' || y path, null::timestamptz lastmod from pop
          union all
          select '/rent-vs-own/' || make_slug || '/' || model_slug || '/' || y || '/' || c.slug, null from pop, cities c where pop.y >= extract(year from now())::integer - 2),
  hubs as (select x path, null::timestamptz lastmod from unnest(array['/events', '/airport-car-rental', '/rent-vs-own']) x
           union all select '/gps-tracker', null from s where s.tracker_product_enabled)
  select coalesce(jsonb_agg(jsonb_build_object('path', path, 'lastmod', lastmod)), '[]'::jsonb) from (select * from hubs union all select * from ev union all select * from ap union all select * from rvo limit 45000) a
$$;

-- the language versions: each ready language's landing pages, events and airports, with the English path
create or replace function public.sitemap_languages() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with ready as (select x ->> 'code' code, x ->> 'hreflang' hreflang from jsonb_array_elements(public.seo_languages_state()) x where (x ->> 'ready')::boolean),
  pages as (select '/car-rental/' || slug path, content_updated_at lastmod from seo_pages where is_active and app.seo_page_indexable(seo_pages)
            union all select '/events/' || slug, updated_at from seo_events where is_active
            union all select '/airport-car-rental/' || lower(code), updated_at from airports where is_active)
  select jsonb_build_object('languages', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'hreflang', hreflang)) from ready), '[]'::jsonb),
                            'pages', coalesce((select jsonb_agg(jsonb_build_object('path', path, 'lastmod', lastmod)) from pages), '[]'::jsonb))
$$;

revoke all on function app.server_i18n_load(jsonb) from public, anon, authenticated;
grant execute on function app.server_i18n_load(jsonb) to service_role;
grant execute on function public.seo_languages_state(), public.seo_i18n_bundle(text), public.delivery_to_point(numeric, numeric), public.rent_vs_own_page(text, text, integer, text),
  public.sitemap_families(), public.sitemap_languages() to anon, authenticated, service_role;

-- every programmatic page changes with this release's templates (the content epoch of 1100)
select app.seo_content_epoch_refresh('r36-1');

-- IndexNow: the new hubs and the airport pages once (the events queue themselves, 2003; the Turo landing pages through
-- seo_pages' own trigger)
select app.indexnow_queue_path(x, 'r36 page families') from unnest(array['/events', '/airport-car-rental', '/rent-vs-own', '/gps-tracker']) x;
select app.indexnow_queue_path('/airport-car-rental/' || lower(code), 'airport') from airports where is_active;
