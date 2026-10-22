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
select test.ok('rules: a year of a model not on the list, with no car, is not', not (public.vehicle_year_page('cadillac', 'cts', 2015) ->> 'indexable')::boolean);
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

-- ---------------------------------------------------------------- who may call what
set role anon;
select test.ok('anon reads a page (the public site)', public.vehicle_trim_page('volkswagen', 'jetta', 2020, 'sportline') is not null);
select test.throws('anon cannot import', $$select app.vehicle_catalog_import_batch('{}'::jsonb)$$, 'permission denied');
select test.throws('anon cannot read the tables', $$select count(*) from vehicle_catalog_years$$, 'permission denied');
reset role;
