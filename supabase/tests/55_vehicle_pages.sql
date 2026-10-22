-- 55: vehicle pages (migration 0092). The catalog fixture (a real subset of the EPA catalog with the Canadian trims,
-- supabase/seed/vehicle_catalog_fixture.sql) through the import functions; the Canadian trims tied to their EPA
-- powertrains; a fleet car matched to its trim; one read per page level; the gate (every page indexed by default, the
-- rules when an Admin chooses them) flipping with our inventory; the sitemaps; the old model hubs; the Admin door.
-- Fixtures "vp".
select test.suite('55 vehicle pages');

\ir ../seed/vehicle_catalog_fixture.sql

-- ---------------------------------------------------------------- the catalog
select test.ok('the fixture imported: makes, models, years, trims', (select count(*) from vehicle_catalog_makes) >= 10 and (select count(*) from vehicle_catalog_years) >= 20
  and (select count(*) from vehicle_catalog_trims) >= 50);
select test.eq('the import is recorded as done', (select status from vehicle_catalog_imports order by started_at desc limit 1), 'done');
select test.eq('the Canadian Sportline of the 2020 Jetta has its page', (select name from vehicle_catalog_trims where make_slug = 'volkswagen' and model_slug = 'jetta' and year = 2020 and slug = 'sportline'), 'Sportline');
select test.eq('trims keep the lineup order', (select string_agg(slug, ',' order by rank) from vehicle_catalog_trims where make_slug = 'volkswagen' and model_slug = 'jetta' and year = 2020),
  'comfortline,highline,sportline,execline,gli');
select test.eq('"EX+" is its own page', (select name from vehicle_catalog_trims where make_slug = 'kia' and model_slug = 'forte' and year = 2021 and slug = 'ex-plus'), 'EX+');
select test.ok('a model year has its fuel use summary', (select l100_min between 4 and 12 and powertrains > 0 from vehicle_catalog_years where make_slug = 'volkswagen' and model_slug = 'jetta' and year = 2020));
select test.eq('a model is found by its key whatever the spelling ("F-150" is the F150)', (select model_slug from app.vehicle_catalog_match('Ford', 'F-150', 2022, 'XLT SuperCrew 4x4')), 'f150');
select test.eq('vPIC''s names add no model of their own (Mustang Mach-E is EPA''s)', (select string_agg(slug, ',' order by slug) from vehicle_catalog_models where make_slug = 'ford'), 'f-150-lightning,f150,mustang,mustang-mach-e');

-- trims and powertrains: "LE" is the gas Camry, "Hybrid SE" the hybrid, the GLI its own engine, "N Line" not the N
create function test.vp_models(p_make text, p_model text, p_year integer, p_trim text) returns text language sql as $$
  select string_agg(distinct v ->> 'epa_model', '; ' order by v ->> 'epa_model') from vehicle_catalog_trims t join vehicle_catalog_years y using (make_slug, model_slug, year)
   cross join lateral jsonb_array_elements(y.variants) v
   where t.make_slug = p_make and t.model_slug = p_model and t.year = p_year and t.slug = p_trim and (v ->> 'id')::integer = any (t.variant_ids) $$;
select test.ok('Camry LE: gas only', test.vp_models('toyota', 'camry', 2023, 'le') !~* 'hybrid' and test.vp_models('toyota', 'camry', 2023, 'le') ~ 'LE');
select test.ok('Camry Hybrid SE: the hybrid (SE/XLE/XSE is one word with alternatives)', test.vp_models('toyota', 'camry', 2023, 'hybrid-se') ~* 'hybrid');
select test.ok('Jetta GLI 2021: the GLI powertrain only', test.vp_models('volkswagen', 'jetta', 2021, 'gli') = 'Jetta GLI');
select test.ok('Jetta GLI 2020 (EPA lists it as "Jetta"): the largest engine; the Sportline the others',
  test.vp_models('volkswagen', 'jetta', 2020, 'gli') = 'Jetta' and (select count(*) from vehicle_catalog_trims t, vehicle_catalog_years y, jsonb_array_elements(y.variants) v
   where (t.make_slug, t.model_slug, t.year) = (y.make_slug, y.model_slug, y.year) and t.make_slug = 'volkswagen' and t.year = 2020 and t.slug = 'sportline'
     and (v ->> 'id')::integer = any (t.variant_ids) and (v ->> 'displ')::numeric >= 2) = 0);
select test.ok('Jetta Comfortline 2021: never the GLI', test.vp_models('volkswagen', 'jetta', 2021, 'comfortline') !~ 'GLI');
select test.ok('Elantra N Line: a package, not the N', test.vp_models('hyundai', 'elantra', 2023, 'n-line') !~ 'Elantra N');
select test.ok('Tesla Long Range: its own powertrain', test.vp_models('tesla', 'model-3', 2023, 'long-range') = 'Model 3 Long Range AWD');
select test.ok('C 300 4MATIC is the C300, the AMG C 43 the C43', test.vp_models('mercedes-benz', 'c-class', 2022, 'c-300-4matic') !~ 'C43' and test.vp_models('mercedes-benz', 'c-class', 2022, 'amg-c-43') ~ 'C43');

-- ---------------------------------------------------------------- a fleet car and its catalog page
select test.eq('trim words: COMFORTLINE SPORT is a Comfortline', (select trim_slug from app.vehicle_catalog_match('VOLKSWAGEN', 'JETTA', 2020, 'COMFORTLINE SPORT')), 'comfortline');
select test.eq('an unclear trim stays at the year', (select trim_slug from app.vehicle_catalog_match('Volkswagen', 'Jetta', 2020, 'S / SE / Sportline')), null::text);
select test.eq('"SEL" is not an "S"-anything it is not', (select trim_slug from app.vehicle_catalog_match('Volkswagen', 'Jetta', 2020, 'SEL')), null::text);
select test.eq('the model by EPA alias: a C300 is a C-Class, with its trim', (select model_slug || '/' || trim_slug from app.vehicle_catalog_match('Mercedes-Benz', 'C300', 2022, '4MATIC Sedan')), 'c-class/c-300-4matic');
select test.eq('a model the catalog lacks keeps its own slug', (select model_slug || ':' || in_catalog from app.vehicle_catalog_match('Toyota', 'Corolla Test', 2022, null)), 'corolla-test:false');
select test.eq('the model link of every car is the vehicle page', app.model_hub_path('Volkswagen', 'JETTA'), '/cars/volkswagen/jetta');

-- ---------------------------------------------------------------- one read per page level
select test.ok('make page', (public.vehicle_make_page('volkswagen') ->> 'path') = '/cars/volkswagen' and jsonb_array_length(public.vehicle_make_page('volkswagen') -> 'models') >= 1);
select test.eq('unknown make: null (404)', public.vehicle_make_page('nosuchmake'), null::jsonb);
select test.eq('model page', public.vehicle_model_page('volkswagen', 'jetta') ->> 'path', '/cars/volkswagen/jetta');
select test.eq('another spelling of a model answers 301', public.vehicle_model_page('mercedes-benz', 'c300') ->> 'redirect', '/cars/mercedes-benz/c-class');
select test.eq('unknown model: null (404)', public.vehicle_model_page('volkswagen', 'nosuchmodel'), null::jsonb);
select test.ok('year page: powertrains, trims, other years', jsonb_array_length(public.vehicle_year_page('volkswagen', 'jetta', 2020) -> 'variants') > 0
  and jsonb_array_length(public.vehicle_year_page('volkswagen', 'jetta', 2020) -> 'trims') = 5 and (public.vehicle_year_page('volkswagen', 'jetta', 2020) -> 'prev' ->> 'year') = '2019');
select test.eq('a year the catalog lacks: null (404)', public.vehicle_year_page('volkswagen', 'jetta', 1999), null::jsonb);
select test.ok('trim page: its own powertrains, siblings and years', (public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') -> 'trim' ->> 'name') = 'Sportline'
  and jsonb_array_length(public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') -> 'siblings') = 5
  and jsonb_array_length(public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') -> 'trim_years') = 2);
select test.eq('unknown trim: null (404)', public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'nosuchtrim'), null::jsonb);

-- ---------------------------------------------------------------- the gate: every page indexed by default
select test.eq('the default indexes everything', (app.settings()).vpage_index_mode, 'all');
select test.ok('a trim page with no car of ours is indexed, self-canonical', (public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'execline') ->> 'indexable')::boolean
  and public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'execline') ->> 'canonical' = '/cars/volkswagen/jetta/2020/execline');
select test.ok('every page is in the sitemaps', (select count(*) from app.vpage_all() where not indexable) = 0
  and (select sum(urls) from app.vehicle_sitemap_files()) = (select count(*) from app.vpage_all()));
select test.ok('sitemaps by make and level, each under 50,000', exists (select 1 from app.vehicle_sitemap_files() where file = 'makes') and exists (select 1 from app.vehicle_sitemap_files() where file = 'volkswagen-trims')
  and (select max(urls) from app.vehicle_sitemap_files()) < 50000);
select test.ok('a sitemap lists its pages with a lastmod', exists (select 1 from app.vehicle_sitemap('volkswagen-trims') where path = '/cars/volkswagen/jetta/2020/sportline' and lastmod is not null));

-- the rules (an Admin's choice): pages flip with our inventory
update program_settings set vpage_index_mode = 'rules' where id = (app.settings()).id;
select test.ok('rules: a trim with no car of ours is noindex, canonical at its year', not (public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') ->> 'indexable')::boolean
  and public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') ->> 'canonical' = '/cars/volkswagen/jetta/2020');
select test.ok('rules: a popular model''s year from 2015 is indexed', (public.vehicle_year_page('volkswagen', 'jetta', 2020) ->> 'indexable')::boolean);
-- (a model year no car of any suite matches: earlier suites add cars of their own, a 2015 Cadillac CTS among them)
select test.ok('rules: a year of a model not on the list, with no car, is not', (select bool_and(not (public.vehicle_year_page(y.make_slug, y.model_slug, y.year) ->> 'indexable')::boolean) and count(*) > 0
  from vehicle_catalog_years y join vehicle_catalog_makes k on k.slug = y.make_slug join vehicle_catalog_models m on m.make_slug = y.make_slug and m.slug = y.model_slug
 where not exists (select 1 from vehicle_catalog_popular p where p.make_slug = y.make_slug and p.model_slug = y.model_slug)
   and not exists (select 1 from vehicles v where lower(v.make) = lower(k.name) and app.slugify(v.model) = y.model_slug)));
select test.ok('rules: makes are always indexed', (public.vehicle_make_page('cadillac') ->> 'indexable')::boolean);
select test.ok('rules: the sitemap leaves out the trim', not exists (select 1 from app.vehicle_sitemap('volkswagen-trims') where path = '/cars/volkswagen/jetta/2020/sportline'));

select test.mk_owner('vp_own');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:VP1'), test.id('owner:vp_own'), 2020, 'Volkswagen', 'Jetta', 'Sportline', 'Grey', 'VP1AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan'),
       (test.id('vehicle:VP2'), test.id('owner:vp_own'), 2015, 'Cadillac', 'CTS', 'Luxury', 'Silver', 'VP2AAA', 'standard', 'available', 'managed', 'transfer', 'Sedan');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, app.listing_slug(v.id), 'x', 'published', now(), 5, 'Automatic', 'Sedan' from vehicles v where v.id in (test.id('vehicle:VP1'), test.id('vehicle:VP2'));

select test.ok('our 2020 Jetta Sportline is the exact car of its trim page', exists (select 1 from jsonb_array_elements(public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') -> 'inventory' -> 'exact') c
  where (c ->> 'vehicle_id')::uuid = test.id('vehicle:VP1')));
select test.eq('real cars counted for the gate', (public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') -> 'inventory' ->> 'real_exact')::integer, 1);
select test.ok('the gate flips: the trim page is indexed with our car, self-canonical', (public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') ->> 'indexable')::boolean
  and public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') ->> 'canonical' = '/cars/volkswagen/jetta/2020/sportline');
select test.ok('and it joins its sitemap', exists (select 1 from app.vehicle_sitemap('volkswagen-trims') where path = '/cars/volkswagen/jetta/2020/sportline'));
select test.ok('a car of the year makes its year page indexed', (public.vehicle_year_page('cadillac', 'cts', 2015) ->> 'indexable')::boolean);
select test.ok('the same model in another year: listed under "other years"', exists (select 1 from jsonb_array_elements(public.vehicle_year_page('volkswagen', 'jetta', 2021) -> 'inventory' -> 'same_model') c
  where (c ->> 'vehicle_id')::uuid = test.id('vehicle:VP1')));
select test.ok('no exact car: similar cars instead of an empty block', jsonb_array_length(public.vehicle_year_page('toyota', 'camry', 2023) -> 'inventory' -> 'similar') >= 1);
update vehicle_listings set status = 'unpublished' where vehicle_id = test.id('vehicle:VP1');
select test.ok('the car leaves the site: the trim page flips back to noindex', not (public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') ->> 'indexable')::boolean);
update vehicle_listings set status = 'unpublished' where vehicle_id = test.id('vehicle:VP2');
update program_settings set vpage_index_mode = 'all' where id = (app.settings()).id;

-- ---------------------------------------------------------------- the old model hubs
select test.eq('/rent/<make-model> answers with the vehicle page', public.vehicle_hub_path('volkswagen-jetta'), '/cars/volkswagen/jetta');
select test.eq('an unknown hub: null (404)', public.vehicle_hub_path('nosuch-hub'), null::text);

-- ---------------------------------------------------------------- the import: content hashes keep lastmod still
create temp table vp_before as select make_slug, model_slug, year, updated_at from vehicle_catalog_years;
select pg_sleep(0.01);
\ir ../seed/vehicle_catalog_fixture.sql
select test.eq('an import of the same data moves no lastmod', (select count(*) from vehicle_catalog_years y join vp_before b using (make_slug, model_slug, year) where y.updated_at <> b.updated_at), 0::bigint);
select test.throws('an import with no make is refused', $$select app.vehicle_catalog_import_begin('{}'::jsonb); select app.vehicle_catalog_import_finish('{"makes": []}'::jsonb)$$, 'no make');
select app.vehicle_catalog_import_fail('{"error": "test"}'::jsonb);

-- ---------------------------------------------------------------- Admin > Settings > Vehicle pages
select test.mk_user('vp_admin', 'admin');
select test.ok('the panel: counts by level', (app.door(test.id('vp_admin'), 'aal2', 'admin_read', 'vehicle_pages', '{}') -> 'counts' -> 'trim' ->> 'total')::integer > 0);
select test.eq('trims edited for one model, kept apart from the list', app.door(test.id('vp_admin'), 'aal2', 'admin_do', 'vehicle_pages_trims',
  '{"make": "volkswagen", "model": "jetta", "lines": "2020: Comfortline, Highline, United"}') ->> 'trims', '3');
select test.eq('the edited trims are the pages', (select string_agg(slug, ',' order by rank) from vehicle_catalog_trims where make_slug = 'volkswagen' and model_slug = 'jetta'), 'comfortline,highline,united');
select test.throws('a malformed trim line is refused', $$select app.door(test.id('vp_admin'), 'aal2', 'admin_do', 'vehicle_pages_trims', '{"make": "volkswagen", "model": "jetta", "lines": "Comfortline"}')$$, '2020-2021');
select app.door(test.id('vp_admin'), 'aal2', 'admin_do', 'vehicle_pages_trims', '{"make": "volkswagen", "model": "jetta", "lines": ""}');
select test.eq('emptied: the list''s trims come back', (select count(*) from vehicle_catalog_trims where make_slug = 'volkswagen' and model_slug = 'jetta' and year = 2020), 5::bigint);
select test.eq('the popular list replaced', app.door(test.id('vp_admin'), 'aal2', 'admin_do', 'vehicle_pages_popular', '{"lines": "Toyota Camry\nVolkswagen | Jetta\nNo Such Car"}') ->> 'count', '2');
select test.ok('a model taken off the list is not added back by the next import', exists (select 1 from vehicle_catalog_popular_removed where make_slug = 'toyota' and model_slug = 'corolla'));
select app.door(test.id('vp_admin'), 'aal2', 'admin_do', 'vehicle_pages_import', '{}');
select test.ok('Import now: the daily check finds it due', app.vehicle_catalog_import_due());
select test.mk_user('vp_cs', 'va', 'cs');
select test.throws('only an Admin', $$select app.door(test.id('vp_cs'), 'aal2', 'admin_read', 'vehicle_pages', '{}')$$);


-- ---------------------------------------------------------------- city and colour pages (the owner, October 22)
insert into seo_pages (slug, kind, name, sort_order, facts, copy) values
  ('vp-town', 'location', 'Vptown', 10, '{"lat": 43.59, "lng": -79.64, "nearby": ["vp-port"], "transit": ["Line 9"]}', '{"h1": "x"}'),
  ('vp-port', 'location', 'Vp Airport (VPA)', 20, '{"airport_code": "VPA", "lat": 43.68, "lng": -79.62, "terminals": ["Terminal 1"]}', '{"h1": "x"}');
select test.ok('without the places table (migration 0095), the places are the active location landing pages', (select count(*) from app.vpage_landing_places() where slug in ('vp-town', 'vp-port')) = 2
  and app.vpage_place('vp-town') ->> 'kind' = 'city' and app.vpage_place('vp-port') ->> 'kind' = 'airport');
select test.eq('twelve colours', (select count(*) from vehicle_colours), 12::bigint);
select test.ok('without place_terms (0095), the default terms: renting, sale, detailing and body shop, each with its lead', (select count(distinct kind) from app.vpage_terms()) = 4
  and not exists (select 1 from app.vpage_terms() where kind <> 'rental' and lead is null));
select test.ok('every trim is numbered (the sitemaps take ranges of it)', not exists (select 1 from vehicle_catalog_trims where ord is null)
  and (select count(distinct ord) from vehicle_catalog_trims) = (select count(*) from vehicle_catalog_trims));
select test.eq('a place page: its trim with the place', public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-town', null) ->> 'path', '/cars/volkswagen/jetta/2020/sportline/vp-town');
select test.eq('a place and colour page', public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-town', 'black') ->> 'level', 'city_colour');
select test.eq('a colour page', public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', null, 'gold') ->> 'path', '/cars/volkswagen/jetta/2020/sportline/colour/gold');
select test.ok('the nearby place named by the landing page comes first', public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-town', null) -> 'city' -> 'nearby' -> 0 ->> 'slug' = 'vp-port');
select test.ok('unknown place, colour or trim: 404', public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'nowhere', null) is null
  and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', null, 'plaid') is null and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'nosuch', 'vp-town', null) is null);
select test.ok('indexed and self-canonical by default', (public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-port', 'red') ->> 'indexable')::boolean
  and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-port', 'red') ->> 'canonical' = '/cars/volkswagen/jetta/2020/sportline/vp-port/red');

-- The local SEO release's places and terms (0095), once there, replace the landing pages and the default terms. Their
-- shape is simulated here (only when 0095 is not applied) and removed after.
do $do$
begin
  if to_regclass('public.places') is not null then return; end if;
  create table places (id integer primary key, parent_id integer, kind smallint not null, region_id integer, flags integer not null default 0, lat real, lng real,
    population integer, src_id text, slug text not null unique, name text not null, country text not null default 'CA', iata text, landing_slug text,
    is_active boolean not null default true, updated_on date not null default current_date);
  create table place_regions (code text primary key, country text, name text, is_enabled boolean not null default true, places integer not null default 0);
  create table place_terms (slug text primary key, vertical text not null, phrase text not null, canonical_slug text, lead_kind text, sort_order integer not null default 0, is_active boolean not null default true);
  create function app.place_enabled(p places) returns boolean language sql stable as 'select p.is_active';
  insert into places (id, parent_id, kind, flags, lat, lng, population, slug, name) values
    (1, null, 1, 0, null, null, 40000000, 'vp-canada', 'Vpcanada'), (2, 1, 4, 1, null, null, null, 'vp-gta', 'Vp GTA'),
    (3, 2, 5, 1, 43.6, -79.6, 50000, 'vp-borough', 'Vp Borough'), (4, 3, 6, 1, 43.61, -79.61, null, 'vp-corner', 'Vp Corner'),
    (5, 3, 8, 1, 43.62, -79.62, null, 'vp-tower', 'Vp Tower'), (7, 3, 5, 1, 43.7, -79.7, 900, 'vp-off', 'Vp Off');
  update places set is_active = false where id = 7;
  insert into place_regions values ('ON', 'CA', 'Ontario', true, 3);
  insert into place_terms values ('car-rental', 'rental', 'car rental', null, null, 10), ('car-hire', 'rental', 'car hire', null, null, 20),
    ('rent-a-car', 'rental', 'rent a car', 'car-rental', null, 30), ('used', 'sale', 'used', null, 'buyer', 10), ('ppf', 'detailing', 'ppf', null, 'detailing', 10);
  perform test.eq('place_terms: active, not a synonym, not car rental itself', (select string_agg(slug || ':' || coalesce(lead, '-'), ',' order by slug) from app.vpage_terms()), 'car-hire:-,ppf:detailing,used:buyer');
  perform test.ok('a neighbourhood page names its city; a region page lists its places; no page for a landmark or a place switched off',
    public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-corner', null) -> 'city' ->> 'parent' = 'Vp Borough'
    and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-gta', null) -> 'city' -> 'within' -> 0 ->> 'slug' = 'vp-borough'
    and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-gta', null) -> 'city' -> 'delivery' = 'null'::jsonb
    and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-tower', null) is null
    and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-off', null) is null
    and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-town', null) is null);
  perform test.eq('the sitemaps number the places by id; a landmark or a place switched off has no pages',
    (select string_agg(r.slug, ',' order by r.ord) from app.vpage_places_range(1, app.vpage_place_max()) r), 'vp-canada,vp-gta,vp-borough,vp-corner');
  drop function app.place_enabled(places);
  drop table places, place_regions, place_terms;
end $do$;

-- the sitemaps: no file over 50,000, the slices read by keyset within one trim, every page once
create function pg_temp.vp_all_tiers() returns table (f integer, g bigint, path text) language plpgsql as $f$
declare n integer; a bigint; k integer; r record;
begin
  n := public.vehicle_tier_files_count();
  for i in 1 .. n loop
    a := -1;
    loop
      k := 0;
      for r in select * from app.vehicle_tier_sitemap(i, a, 4000) loop
        k := k + 1; a := greatest(a, r.g);
        if r.path is not null then f := i; g := r.g; path := r.path; return next; end if;
      end loop;
      exit when k = 0;
    end loop;
  end loop;
end $f$;
create temp table vp_all as select * from pg_temp.vp_all_tiers();
create temp table vp_slices as select * from app.vehicle_tier_sitemap(1, -1, 3);
insert into vp_slices select * from app.vehicle_tier_sitemap(1, (select max(g) from vp_slices), 3);
select test.ok('the next slice starts after the last pair read (keyset), no address twice', (select count(path) from vp_slices) = (select count(distinct path) from vp_slices)
  and (select count(path) from vp_slices) > 13);
select test.ok('a pair is at most 13 addresses, a file at most 50,000', (select max(n) from (select count(*) n from vp_all group by g) x) <= 13
  and (select max(n) from (select count(*) n from vp_all group by f) x) <= 50000);
select test.eq('every trim has its place pages, place and colour pages and colour pages, each once',
  (select count(*) || '/' || count(distinct path) from vp_all),
  (select n || '/' || n from (select (select count(*) from vehicle_catalog_trims) * ((select count(*) from app.vpage_landing_places()) * 13 + 12) n) x));
select test.ok('no file past the last', not exists (select 1 from app.vehicle_tier_sitemap(public.vehicle_tier_files_count() + 1, -1, 4000)));
select test.ok('the index: every tree has the level files and the tiers files', (public.vehicle_sitemap_index(0, 1) ->> 'total')::integer
  = (select count(*) from app.vpage_trees()) * ((select count(*) from app.vehicle_sitemap_files()) + public.vehicle_tier_files_count()));
select test.ok('every tree is allowed by default', public.vehicle_sitemap_tree('') and public.vehicle_sitemap_tree('buy-') and public.vehicle_sitemap_tree('t-car-hire-') and public.vehicle_sitemap_tree('t-ceramic-coating-'));
-- (earlier suites send IndexNow batches too: one quota, one sweep; start from a clean cursor)
update indexnow_sweep set backoff_until = null, backoff_s = 0, file_i = 0, pos = -1, sent_today = 0, day = (now() at time zone 'America/Toronto')::date;
update program_settings set indexnow_enabled = true where id = (app.settings()).id;
select test.ok('IndexNow: a batch of at most 10,000 addresses from the sitemaps, the cursor after it', (select jsonb_array_length(c -> 'paths') between 1 and 10000 and (c -> 'cursor' ->> 'file_i') is not null
  from app.server_indexnow_claim(10000) c));
select app.server_indexnow_report('{"status": 200, "count": 10, "cursor": {"file_i": 3, "pos": 5}}');
select test.eq('a 2xx moves the cursor and counts the addresses', (select file_i || '/' || pos || '/' || sent_today from indexnow_sweep), '3/5/10');
select app.server_indexnow_report('{"status": 429, "count": 10, "cursor": {"file_i": 9, "pos": 9}}');
select test.ok('a 429 backs off and keeps the cursor', (select backoff_until > now() + interval '14 minutes' and file_i = 3 from indexnow_sweep)
  and app.server_indexnow_claim(10000) ->> 'why' = 'backing off');
update indexnow_sweep set backoff_until = null, backoff_s = 0, file_i = 0, pos = -1, sent_today = 0;

-- the switches: off takes the tier out of search at once
update program_settings set vpage_place_index = false, vpage_buy_index = false, vpage_detailing_index = false where id = (app.settings()).id;
select test.ok('place switch off: noindex, canonical at the trim; the colour pages stay', not (public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-town', null) ->> 'indexable')::boolean
  and public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-town', null) ->> 'canonical' = '/cars/volkswagen/jetta/2020/sportline'
  and (public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', null, 'gold') ->> 'indexable')::boolean
  and not exists (select 1 from pg_temp.vp_all_tiers() where path !~ '/colour/'));
select test.ok('/buy and detailing switches off: those trees leave the sitemaps', not public.vehicle_sitemap_tree('buy-') and not public.vehicle_sitemap_tree('t-used-')
  and not public.vehicle_sitemap_tree('t-ceramic-coating-') and public.vehicle_sitemap_tree('t-car-hire-') and public.vehicle_sitemap_tree('t-bumper-repair-'));
update program_settings set vpage_place_index = true, vpage_buy_index = true, vpage_detailing_index = true where id = (app.settings()).id;

-- ---------------------------------------------------------------- the /buy twins: for sale only when a car really is
select test.eq('no car flagged: nothing for sale', jsonb_array_length(public.vehicle_buy_extras('volkswagen', 'jetta', 2020, 'sportline') -> 'for_sale'), 0);
update vehicle_catalog_years set recalls = '[]', complaints = '{}' where make_slug = 'volkswagen' and model_slug = 'jetta' and year = 2020;
select test.eq('recalls unknown until NHTSA is imported: null, never "none"', public.vehicle_buy_extras('volkswagen', 'jetta', 2020, 'sportline') -> 'recalls', 'null'::jsonb);
update vehicle_catalog_years set recalls = '[{"campaign": "20V000000", "date": "2020-05-01", "component": "AIR BAGS", "summary": "x"}]', complaints = '{"total": 7, "components": [{"component": "ENGINE", "n": 4}]}'
 where make_slug = 'volkswagen' and model_slug = 'jetta' and year = 2020;
select test.eq('imported: the year''s recalls', jsonb_array_length(public.vehicle_buy_extras('volkswagen', 'jetta', 2020, 'sportline') -> 'recalls'), 1);
select test.ok('the model page: recalls and complaints by year', exists (select 1 from jsonb_array_elements(public.vehicle_buy_extras('volkswagen', 'jetta', null, null) -> 'by_year') y where (y ->> 'year')::integer = 2020 and (y ->> 'complaints')::integer = 7));
select test.throws('for sale needs a price', $$select app.door(test.id('vp_admin'), 'aal2', 'admin_do', 'vehicle_for_sale', jsonb_build_object('vehicle_id', test.id('vehicle:VP1'), 'for_sale', true))$$, 'asking price');
select app.door(test.id('vp_admin'), 'aal2', 'admin_do', 'vehicle_for_sale', jsonb_build_object('vehicle_id', test.id('vehicle:VP1'), 'for_sale', true, 'asking_price_cents', 2150000));
select test.eq('flagged by an Admin: on its /buy pages with the asking price', (public.vehicle_buy_extras('volkswagen', 'jetta', 2020, 'sportline') -> 'for_sale' -> 0 ->> 'asking_price_cents')::bigint, 2150000::bigint);
select test.eq('and on its model''s, not on another trim''s', jsonb_array_length(public.vehicle_buy_extras('volkswagen', 'jetta', null, null) -> 'for_sale') || '/' || jsonb_array_length(public.vehicle_buy_extras('volkswagen', 'jetta', 2020, 'highline') -> 'for_sale'), '1/0');
select test.throws('only an Admin flags a car for sale', $$select app.door(test.id('vp_cs'), 'aal2', 'admin_do', 'vehicle_for_sale', jsonb_build_object('vehicle_id', test.id('vehicle:VP1'), 'for_sale', false))$$);
select test.ok('the panel counts every tier', (select (d -> 'tiers' -> 'place' ->> 'total')::bigint > 0 and (d -> 'tiers' -> 'sale' ->> 'total')::bigint > (d -> 'counts' -> 'trim' ->> 'total')::bigint
  and (d -> 'tiers' -> 'detailing_terms' ->> 'terms')::integer >= 1 and (d -> 'tiers' ->> 'for_sale')::integer = 1 and (d -> 'db' ->> 'bytes')::bigint > 0
  from app.door(test.id('vp_admin'), 'aal2', 'admin_read', 'vehicle_pages', '{}') d));
update vehicles set for_sale = false where id = test.id('vehicle:VP1');

-- buyer leads: "Find me this car" goes to Sales with a To do line
select test.ok('a buyer lead', (app.submit_lead('{"kind": "buyer", "name": "Vp Buyer", "email": "vp-buyer@example.com", "payload": {"vehicle": "2020 Volkswagen Jetta Sportline", "budget": "22000", "timeline": "Within a month"}}'::jsonb) ->> 'ok')::boolean);
select test.eq('kept as a buyer lead', (select kind from leads where email = 'vp-buyer@example.com'), 'buyer');
select test.eq('with a Sales task naming the car and the budget', (select t.queue || ': ' || t.detail from tasks t join leads l on l.id = t.related_id where l.email = 'vp-buyer@example.com'),
  'sales: Vp Buyer wants to buy 2020 Volkswagen Jetta Sportline. Budget: 22000. Timeline: Within a month.');
select test.throws('a buyer lead needs an email or a phone', $$select app.submit_lead('{"kind": "buyer", "name": "X"}'::jsonb)$$, 'email address or a phone');
select app.submit_lead(jsonb_build_object('kind', k, 'name', 'Vp ' || k, 'email', 'vp-' || k || '@example.com', 'payload', jsonb_build_object('vehicle', '2020 Volkswagen Jetta Sportline', 'service', 'Ceramic coating')))
  from unnest(array['finance', 'detailing', 'bodyshop']) k;
select test.eq('detailing and body shop requests and financing questions are leads for Sales too',
  (select string_agg(t.queue || ': ' || t.title, ' | ' order by l.kind) from leads l join tasks t on t.related_id = l.id where l.email in ('vp-finance@example.com', 'vp-detailing@example.com', 'vp-bodyshop@example.com')),
  'sales: A body shop request | sales: A detailing request | sales: Someone asked about financing or leasing a car');
select test.ok('other enquiries still go the old way', (app.submit_lead('{"kind": "contact", "name": "Vp C", "email": "vp-c@example.com", "message": "hello there"}'::jsonb) ->> 'ok')::boolean);

-- ---------------------------------------------------------------- who may call what
set role anon;
select test.ok('anon reads a page (the public site)', public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') is not null);
select test.throws('anon cannot import', $$select app.vehicle_catalog_import_batch('{}'::jsonb)$$, 'permission denied');
select test.throws('anon cannot read the tables', $$select count(*) from vehicle_catalog_years$$, 'permission denied');
select test.ok('anon reads a city page and a /buy twin''s extras, and the sitemaps', public.vehicle_tier_page('volkswagen', 'jetta', 2020, 'sportline', 'vp-town', 'black') is not null
  and public.vehicle_buy_extras('volkswagen', 'jetta', 2020, 'sportline') is not null and (public.vehicle_sitemap_index(0, 1) ->> 'total')::integer > 0 and jsonb_array_length(public.vehicle_tier_sitemap(1, -1, 1)) > 0);
select test.throws('anon cannot claim IndexNow batches', $$select app.server_indexnow_claim(10)$$, 'permission denied');
select test.throws('anon cannot flag a car for sale', $$select app.vpage_for_sale_set(null, '{}'::jsonb)$$, 'permission denied');
reset role;
