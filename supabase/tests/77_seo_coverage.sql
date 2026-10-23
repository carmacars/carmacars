-- 77: SEO coverage (migration 0115). The new search terms and synonyms: a synonym points to an own term of its vertical
-- and copies what that term says, is served with its canonical and stays out of the sitemaps and the vehicle trees;
-- the chauffeur terms take a request; buying, financing and leasing are never offered; body repair never promises
-- mechanical work; brand names keep their capitals and say we are not affiliated. The catalog takes years from 1900
-- and the further catalog sources are off by default. No fixtures of its own beyond one catalog year, removed again.
select test.suite('77 seo coverage');

-- ================================================================ 1. the terms
select test.eq('terms: the new own terms are in, each in its vertical',
  (select string_agg(slug || ':' || vertical || ':' || served, ',' order by slug) from place_terms where canonical_slug is null and slug = any (array[
     'car-rental-pickup', 'rental-car-while-car-is-in-the-shop', 'loaner-car', 'courtesy-car', 'replacement-car-rental', 'car-subscription', 'short-term-car-lease',
     'amazon-flex-car-rental', 'uber-black-car-rental', 'car-service', 'black-car-service', 'black-suv-service', 'executive-car-service', 'limo-service', 'airport-car-service',
     'new-cars', 'trucks-for-sale', 'suvs-for-sale', 'rent-to-own-cars', 'car-repair', 'auto-repair'])),
  'airport-car-service:rental:request,amazon-flex-car-rental:rental:yes,auto-repair:bodyshop:yes,black-car-service:rental:request,black-suv-service:rental:request,'
  || 'car-rental-pickup:rental:yes,car-repair:bodyshop:yes,car-service:rental:request,car-subscription:rental:yes,courtesy-car:rental:yes,executive-car-service:rental:request,'
  || 'limo-service:rental:request,loaner-car:rental:yes,new-cars:sale:request,rent-to-own-cars:sale:request,rental-car-while-car-is-in-the-shop:rental:yes,'
  || 'replacement-car-rental:rental:yes,short-term-car-lease:rental:yes,suvs-for-sale:sale:request,trucks-for-sale:sale:request,uber-black-car-rental:rental:yes');
select test.eq('terms: the synonyms of 0115', (select count(*)::integer from place_terms where canonical_slug is not null), 97);
select test.eq('terms: a synonym points to an own term of its own vertical (no chain, no other vertical)',
  (select count(*)::integer from place_terms s left join place_terms t on t.slug = s.canonical_slug
    where s.canonical_slug is not null and (t.slug is null or t.canonical_slug is not null or t.vertical <> s.vertical)), 0);
select test.eq('terms: a synonym says what its term says (served, rules, landing page, service, lead kind, note)',
  (select count(*)::integer from place_terms s join place_terms t on t.slug = s.canonical_slug
    where (s.served, s.match, s.landing_slug, s.service_code, s.lead_kind, s.intent_note) is distinct from (t.served, t.match, t.landing_slug, t.service_code, t.lead_kind, t.intent_note)), 0);
select test.eq('terms: the owner''s words each have a page or a synonym',
  (select string_agg(w, ',') from unnest(array['car-rental', 'cars-for-sale', 'car-financing', 'car-repair', 'car-service', 'car-detailing', 'uber-eats-car-rental',
     'uber-rental-car', 'black-truck-rental', 'black-truck-service', 'chauffeur-service', 'car-rental-delivery', 'car-rental-pickup', 'insurance-replacement-rental',
     'car-leasing', 'car-lease', 'car-hire', 'auto-rental', 'vehicle-rental', 'auto-financing', 'car-loan', 'bad-credit-car-loans', 'auto-repair', 'collision-repair',
     'limo-service', 'black-car-service', 'executive-car-service', 'courtesy-car', 'replacement-vehicle', 'airport-car-service']) w
    where not exists (select 1 from place_terms t where t.slug = w and t.is_active)), null);
select test.eq('terms: the chauffeur service is a request a person answers, never booked on the page',
  (select count(*)::integer from place_terms where slug in ('car-service', 'black-car-service', 'black-suv-service', 'executive-car-service', 'limo-service', 'airport-car-service')
     and served = 'request' and lead_kind = 'place_request' and intent_note ~ 'chauffeur service'), 6);
select test.eq('terms: buying, financing and leasing are always a request, buyer or finance',
  (select count(*)::integer from place_terms where vertical = 'sale' and (served <> 'request' or lead_kind not in ('buyer', 'finance'))), 0);
select test.ok('terms: the new buying terms say we do not sell or arrange it',
  (select bool_and(intent_note ~* 'we do not') from place_terms where slug in ('new-cars', 'trucks-for-sale', 'suvs-for-sale', 'rent-to-own-cars')));
select test.ok('terms: leasing and subscriptions on the rental side say there is no lease',
  (select bool_and(intent_note ~* 'do not lease|no subscription contract') from place_terms where slug in ('car-subscription', 'short-term-car-lease')));
select test.ok('terms: body repair terms say we do not do mechanical work',
  (select bool_and(intent_note ~* 'do not do mechanical') from place_terms where slug in ('car-repair', 'auto-repair')));
select test.eq('terms: no page for work we do not do (mechanical repair, oil changes, tires, towing)',
  (select string_agg(slug, ',') from place_terms where slug ~ '(mechanic|oil-change|brake|tire-shop|tire-change|towing|tow-truck|engine-repair|transmission-repair)'), null);
select test.eq('terms: brand names keep their capitals',
  (select string_agg(phrase, '|' order by slug) from place_terms where slug in ('uber-eats-rental-car', 'doordash-rental-car', 'amazon-flex-car-rental', 'uber-black-car-rental', 'lyft-car-rental')),
  'Amazon Flex car rental|DoorDash rental car|Lyft car rental|Uber Black car rental|Uber Eats rental car');
select test.eq('terms: every term naming a brand says CarmaCars is not affiliated',
  (select string_agg(slug, ',') from place_terms where phrase ~ '(Uber|Lyft|DoorDash|SkipTheDishes|Instacart|Hopp|Amazon)' and intent_note !~ 'not affiliated'), null);
select test.eq('terms: phrases lower case except the brand words, titles short',
  (select string_agg(slug, ',') from place_terms where (phrase <> lower(phrase) and phrase !~ '(Uber|Lyft|DoorDash|SkipTheDishes|Instacart|Hopp|Amazon|Flex|Eats|Black|SUV|PPF|PDR|G2|DUI|Canada)')
     or char_length(title) > 60), null);
select test.eq('terms: no em or en dash in what a page says',
  (select count(*)::integer from place_terms where (phrase || title || intent_note || faq::text) ~ '[—–]'), 0);

-- ================================================================ 2. synonyms on the pages and in the sitemaps
select test.eq('hub: a synonym''s page is served with its term''s page as canonical',
  (select public.place_hub('rental', 'car-rentals', 'canada') -> 'term' ->> 'canonical_path'), '/car-rental/canada');
select test.eq('hub: a synonym''s page is never indexed', (select (public.place_hub('rental', 'car-rentals', 'canada') ->> 'indexable')::boolean), false);
select test.eq('hub: a synonym of a buying term points to its term''s page',
  (select public.place_hub('sale', 'car-loan', 'canada') -> 'term' ->> 'canonical_path'), '/buy/auto-loans/canada');
select test.ok('hub: a new own term has its page, indexable as its tier allows',
  (select public.place_hub('rental', 'loaner-car', 'canada') ->> 'path') = '/car-rental/loaner-car/canada');
select test.eq('hub: a chauffeur term takes a request',
  (select public.place_hub('rental', 'black-car-service', 'canada') -> 'term' ->> 'lead_kind'), 'place_request');
select test.eq('sitemaps: no synonym has a sitemap file',
  (select count(*)::integer from jsonb_array_elements(public.place_sitemap_files()) f join place_terms t on t.slug = f ->> 'term' where t.canonical_slug is not null), 0);
select test.ok('sitemaps: the new own terms have their files',
  (select count(distinct f ->> 'term') from jsonb_array_elements(public.place_sitemap_files()) f where f ->> 'term' in ('loaner-car', 'car-service', 'new-cars', 'car-repair')) = 4);
select test.eq('vehicle pages: synonyms have no tree of their own',
  (select count(*)::integer from app.vpage_terms() v join place_terms t on t.slug = v.slug where t.canonical_slug is not null), 0);
select test.ok('vehicle pages: the new own terms each have a tree',
  (select count(*) from app.vpage_terms() where slug in ('loaner-car', 'car-service', 'new-cars', 'car-repair')) = 4);
select test.ok('the public term list: own terms only', not exists (select 1 from jsonb_array_elements(public.place_terms_public()) e join place_terms t on t.slug = e ->> 'slug' where t.canonical_slug is not null));

-- ================================================================ 3. the catalog
select test.throws('catalog: a model year before 1900 is refused',
  $q$insert into vehicle_catalog_years (make_slug, model_slug, year) select make_slug, slug, 1899 from vehicle_catalog_models order by make_slug, slug limit 1$q$, 'vehicle_catalog_years_year_check');
select test.lives('catalog: a model year from 1900 is taken (Wikidata''s older models)',
  $q$insert into vehicle_catalog_years (make_slug, model_slug, year, sources) select make_slug, slug, 1900, '{wikidata}' from vehicle_catalog_models order by make_slug, slug limit 1$q$);
delete from vehicle_catalog_years where year = 1900 and sources = '{wikidata}';
select test.eq('catalog: the further sources are off until the database has moved', (app.settings()).vpage_extra_sources, '{}'::text[]);
select test.throws('catalog: only the known further sources', $q$update program_settings set vpage_extra_sources = '{epa2}'$q$, 'vpage_extra_sources');

-- ================================================================ 4. crawl priority and click depth
select test.ok('priority sitemap: the refresh runs and the file reads the store',
  app.sitemap_priority_refresh() >= 0 and jsonb_typeof(public.sitemap_priority()) = 'array');
select test.ok('priority sitemap: at most 49,500 addresses, no synonym, every make page first',
  jsonb_array_length(public.sitemap_priority()) <= 49500
  and not exists (select 1 from jsonb_array_elements(public.sitemap_priority()) e join place_terms t on t.canonical_slug is not null
                   and (e ->> 'path') like '%/' || t.slug || '/%')
  and coalesce((select min(c.sort) from app.sitemap_priority_cache c where c.path !~ '^/cars/[a-z0-9-]+$'), 2147483647)
      > coalesce((select max(c.sort) from app.sitemap_priority_cache c where c.path ~ '^/cars/[a-z0-9-]+$'), 0));
select test.eq('priority sitemap: only the stored vehicle pages (indexed ones)',
  (select count(*)::integer from app.sitemap_priority_cache c where c.path like '/cars/%' and not exists (select 1 from app.vehicle_sitemap_paths_cache v where v.path = c.path)), 0);
select test.ok('priority sitemap: the Ontario place pages for the first terms of each family',
  not exists (select 1 from app.sitemap_priority_cache c where c.path ~ '^/(car-rental|buy|detailing|body-shop)/' and c.lastmod is null)
  and (select count(*) from places p join place_regions r on r.id = p.region_id and r.code = 'CA-ON' where p.kind in (5, 6) and p.is_active) = 0
   or exists (select 1 from app.sitemap_priority_cache c where c.path ~ '^/car-rental/'));
select test.ok('directory: the refresh runs; the index lists pages of a thousand places by id',
  app.place_directory_refresh() >= 0 and not exists (select 1 from jsonb_array_elements(public.place_directory_index()) e where (e ->> 'places')::integer > 1000));
select test.eq('directory: a page lists the places with pages in its id range, never a landmark or a region switched off',
  (select count(*)::integer from jsonb_array_elements(public.place_directory_page(1)) e join places p on p.slug = e ->> 'slug' where p.kind = 8 or not app.place_enabled(p) or p.id > 1000), 0);
select test.eq('directory: past the last page, nothing', jsonb_array_length(public.place_directory_page(99999)), 0);
select test.eq('directory: a page number out of range is null', public.place_directory_page(0), null::jsonb);
select test.eq('make index: every make with its models',
  (select count(*)::integer from jsonb_array_elements(public.vehicle_make_index()) e), (select count(*)::integer from vehicle_catalog_makes));
select test.eq('make index: anonymous may read the directory and the make index',
  (select bool_and(has_function_privilege('anon', f, 'execute')) from unnest(array['public.place_directory_index()', 'public.place_directory_page(integer)', 'public.vehicle_make_index()']) f), true);
select test.eq('priority sitemap: only the server reads it', has_function_privilege('anon', 'public.sitemap_priority()', 'execute'), false);
