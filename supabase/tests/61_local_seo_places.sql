-- 61: local search, places and terms (migration 0095). Landing pages by body style, car flag and any of several rules
-- with their own threshold; one name, address and phone; the business rating only from enough published reviews; the
-- places tree loaded through the staging table (parents, slugs, landing pages, the GTA, the size budget); the terms and
-- services; a hub's data (near, far, a region switched off); the sitemaps by id range and the quality gate; requests
-- with their tasks; the Admin door; who may call what. Fixtures start with "lp".
select test.suite('61 local search, places and terms');
select test.mk_user('lp_admin', 'admin');
select test.mk_user('lp_cs', 'va', 'cs');

-- ================================================================ 1. landing page rules
select test.eq('match: a body style word, case-insensitive', app.seo_match('{"taking_requests": true, "body_style": "Cabriolet"}', '{"bodies": ["cabriolet"]}'), true);
select test.eq('match: a flag must be true', app.seo_match('{"taking_requests": true}', '{"flags": ["no_credit_card"]}'), false);
select test.eq('match: a flag that is true', app.seo_match('{"taking_requests": true, "no_credit_card": true}', '{"flags": ["no_credit_card"]}'), true);
select test.eq('match: any of several rules', app.seo_match('{"taking_requests": true, "seats": 7, "classes": ["standard"]}', '{"any": [{"classes": ["van"]}, {"seats_min": 7}]}'), true);
select test.eq('match: none of the rules', app.seo_match('{"taking_requests": true, "seats": 5, "classes": ["standard"]}', '{"any": [{"classes": ["van"]}, {"seats_min": 7}]}'), false);
select test.eq('match: a car not taking requests never matches', app.seo_match('{"taking_requests": false}', '{}'), false);
insert into seo_pages (slug, kind, name, facts, match, copy, min_real_cars) values
  ('lp-flag', 'use', 'Lp flag', '{}', '{"flags": ["no_credit_card"]}', '{"seo_title": "x", "meta_description": "x", "h1": "x", "intro": "x", "sections": [], "faq": []}', 3);
select test.eq('landing: a page for flagged cars stays out of search without three such real cars', (select app.seo_page_indexable(p) from seo_pages p where slug = 'lp-flag'), false);
select test.eq('landing: the real-car count reads a flag the vehicles table does not have as false', app.seo_real_count('{"flags": ["no_credit_card"]}'), 0);
delete from seo_pages where slug = 'lp-flag';

-- ================================================================ 2. one name, address and phone; the rating
select test.eq('NAP: the business address is the street address the site shows',
  (select concat_ws('|', business_street, business_city, business_region, business_postal_code) from site_settings), '1570 Midland Ave|Toronto|ON|M1P 3C3');
select test.ok('rating: none below seo_rating_min_reviews published reviews',
  public.business_rating() is null or ((public.business_rating() ->> 'count')::integer >= (app.settings()).seo_rating_min_reviews));

-- ================================================================ 3. places
select test.eq('regions: Canada 13, the United States 56 (states, DC, territories), Mexico 32, all on',
  (select string_agg(country || '=' || n || '/' || on_, ',' order by country) from (select country, count(*) n, bool_and(is_enabled) on_ from place_regions group by country) x), 'CA=13/true,MX=32/true,US=56/true');
select test.eq('places: the curated top', (select string_agg(slug || ':' || app.place_kind(kind), ',' order by id) from places where flags & 16 <> 0 and slug in ('canada', 'united-states', 'mexico', 'ontario', 'gta')),
  'canada:country,united-states:country,mexico:country,ontario:province,gta:area');
select test.ok('places: the size cap is 6 GB by default', (app.settings()).place_db_cap_mb = 6144);

create temp table lp_imp as select public.server_places_import_begin(array['CA-ON'], array['geonames'], null) as id;
insert into places_staging (src_id, kind, flags, region_code, country, lat, lng, population, parent_src_id, slug, name, iata) values
  (6093943, 2, 2, 'CA-ON', 'CA', 49.25, -84.5, 13000000, 6251999, 'ontario-ca', 'Ontario', null),
  (9800001, 3, 2, 'CA-ON', 'CA', 43.75, -79.78, null, 6093943, 'peel-region-on', 'Peel', null),
  (9800002, 5, 2, 'CA-ON', 'CA', 43.5789, -79.6583, 668549, 9800001, 'lp-mississauga-on', 'Mississauga', null),
  (9800003, 6, 6, 'CA-ON', 'CA', 43.5501, -79.5829, null, 9800002, 'lp-port-credit-mississauga-on', 'Port Credit', null),
  (9800004, 5, 2, 'CA-ON', 'CA', 48.3809, -89.2477, 108843, 6093943, 'lp-thunder-bay-on', 'Thunder Bay', null),
  (9800005, 7, 2, 'CA-ON', 'CA', 43.6772, -79.6306, null, 9800001, 'lp-yyz-airport', 'Toronto Pearson International Airport', 'YYZ'),
  (9800006, 5, 2, 'CA-ON', 'CA', 43.6, -79.6, 10, 9800001, 'lp-mississauga-on', 'Mississauga Twin', null);
select test.eq('import: one region in place (7 staged, 6 new, Ontario updated)',
  (select (r ->> 'staged') || '/' || (r ->> 'added') || '/' || (r ->> 'updated') from (select public.server_places_import_apply((select id from lp_imp), 'CA-ON') r) x), '7/6/1');
select test.eq('import: a curated place keeps its slug and its kind', (select slug || ':' || kind from places where src_id = 6093943), 'ontario:2');
select test.eq('import: parents from the staged parents', (select (select slug from places q where q.id = p.parent_id) from places p where src_id = 9800003), 'lp-mississauga-on');
select test.ok('import: a slug already taken gets a short suffix', (select slug ~ '^lp-mississauga-on-[0-9a-f]{5}$' from places where src_id = 9800006));
select test.eq('import: the same run again changes nothing', (select (r ->> 'added') || '/' || (r ->> 'updated') from (select public.server_places_import_apply((select id from lp_imp), 'CA-ON') r) x), '0/0');
insert into seo_pages (slug, kind, name, facts, match, copy) values ('lp-pearson-yyz', 'location', 'Lp Pearson (YYZ)', '{"airport_code": "YYZ"}', '{}',
  '{"seo_title": "x", "meta_description": "x", "h1": "x", "intro": "x", "sections": [], "faq": []}') on conflict do nothing;
create temp table lp_fin as select public.server_places_import_finish((select id from lp_imp), '{"US-TX": "skipped: past the cap"}'::jsonb) as f;
select test.ok('finish: the counts per country and kind, and the region skipped', (select (f -> 'by_country' -> 'CA' ->> 'city')::integer >= 2 from lp_fin)
  and (select skipped like 'skipped%' from place_regions where code = 'US-TX'));
select test.ok('finish: the GTA holds Peel''s places', (select flags & 1 <> 0 from places where src_id = 9800003));
select test.eq('finish: the airport is the place of the landing page with its code', (select slug || '/' || landing_slug from places where src_id = 9800005), 'lp-pearson-yyz/lp-pearson-yyz');
select test.ok('budget: the database size and the cap', (public.server_places_budget() ->> 'cap_bytes')::bigint = 6144::bigint * 1048576);

-- ================================================================ 4. terms
select test.eq('terms: rental 31, buying help 14, detailing 27, body shop 20',
  (select string_agg(vertical || '=' || n, ',' order by vertical) from (select vertical, count(*) n from place_terms group by vertical) x), 'bodyshop=20,detailing=27,rental=31,sale=14');
select test.ok('terms: buying help always takes a request, never "served"', not exists (select 1 from place_terms where vertical = 'sale' and served <> 'request'));
select test.ok('terms: no long dash in a seeded note', not exists (select 1 from place_terms where intent_note ~ ('[' || chr(8210) || chr(8211) || chr(8212) || chr(8213) || ']')));
select test.eq('services: detailing 4, body shop 4, none priced', (select count(*) filter (where vertical = 'detailing') || '/' || count(*) filter (where vertical = 'bodyshop') || '/' || count(from_price_cents) from shop_services), '4/4/0');

-- ================================================================ 5. hubs
select test.ok('hub: a neighbourhood near Toronto, within the reach, its family and its airport',
  (select (h -> 'delivery' ->> 'in_reach')::boolean and h -> 'place' ->> 'kind' = 'neighbourhood' and jsonb_array_length(h -> 'ancestors') >= 3
          and h -> 'airport' ->> 'iata' = 'YYZ' and (h ->> 'indexable')::boolean
     from (select public.place_hub('rental', 'suv-rental', 'lp-port-credit-mississauga-on') h) x));
select test.ok('hub: a far city is beyond the reach and has no delivery price',
  (select not (h -> 'delivery' ->> 'in_reach')::boolean and (h -> 'delivery' ->> 'km')::numeric > 500 and h -> 'delivery' -> 'fee_from_cents' is null
     from (select public.place_hub('rental', 'car-rental', 'lp-thunder-bay-on') h) x));
select test.ok('hub: buying help carries the notice; body shop leads to the replacement rentals',
  (select public.place_hub('sale', 'car-financing', 'lp-thunder-bay-on') ->> 'disclaimer' like '%not a lender%')
  and (select public.place_hub('bodyshop', 'collision-repair', 'lp-port-credit-mississauga-on') -> 'rental_terms' -> 0 ->> 'path' like '/car-rental/%'));
select test.eq('hub: a term of another family is unknown here', public.place_hub('rental', 'car-financing', 'lp-thunder-bay-on'), null::jsonb);
update place_regions set is_enabled = false where code = 'CA-ON';
select test.eq('hub: a region switched off has no pages', public.place_hub('rental', 'car-rental', 'lp-thunder-bay-on'), null::jsonb);
update place_regions set is_enabled = true where code = 'CA-ON';

-- ================================================================ 6. sitemaps and the quality gate
select test.ok('sitemaps: one family of files per term of each tier', (select count(*) from jsonb_array_elements(public.place_sitemap_files())) >= 90);
select test.ok('sitemap: Port Credit''s SUV page is listed, a landmark never, the base page of a place with a landing page never',
  (select bool_or(x ->> 'path' = '/car-rental/suv-rental/lp-port-credit-mississauga-on') from jsonb_array_elements(public.place_sitemap('rental', 'suv-rental', 1)) x)
  and not exists (select 1 from jsonb_array_elements(public.place_sitemap('rental', 'car-rental', 1)) x where x ->> 'path' = '/car-rental/lp-pearson-yyz'));
update program_settings set place_quality_gate = true where id = (app.settings()).id;
select test.ok('gate on: a far city leaves the sitemap; a place within the reach stays',
  not exists (select 1 from jsonb_array_elements(public.place_sitemap('detailing', 'car-detailing', 1)) x where x ->> 'path' like '%lp-thunder-bay-on')
  and exists (select 1 from jsonb_array_elements(public.place_sitemap('detailing', 'car-detailing', 1)) x where x ->> 'path' like '%lp-port-credit-mississauga-on'));
select test.eq('gate on: the far city''s page is not indexed', (public.place_hub('detailing', 'car-detailing', 'lp-thunder-bay-on') ->> 'indexable')::boolean, false);
update program_settings set place_quality_gate = false where id = (app.settings()).id;
update program_settings set sale_hubs_index = false where id = (app.settings()).id;
select test.ok('tier off: no buying help file and no buying help page indexed', not exists (select 1 from jsonb_array_elements(public.place_sitemap_files()) x where x ->> 'vertical' = 'sale')
  and not (public.place_hub('sale', 'used-cars', 'lp-port-credit-mississauga-on') ->> 'indexable')::boolean);
update program_settings set sale_hubs_index = true where id = (app.settings()).id;

-- ================================================================ 7. requests
delete from app.rate_limit_hits;
create temp table lp_lead as select public.submit_place_lead('{"kind": "detailing", "name": "Lp Dee", "email": "lp.dee@example.test", "payload": {"service": "Mobile detailing", "where": "mobile", "place": "Port Credit"}}', '203.0.113.61') as r;
select test.eq('request: a detailing lead with its task', (select l.kind || '/' || t.task_type || '/' || t.queue || '/' || t.status from leads l join tasks t on t.related_id = l.id where l.email = 'lp.dee@example.test'),
  'detailing/detailing_request/cs/open');
select test.ok('request: the task says what was asked', (select detail like '%Mobile detailing%Port Credit%' from tasks t join leads l on l.id = t.related_id where l.email = 'lp.dee@example.test'));
select test.throws('request: an unknown kind is refused', $$select public.submit_place_lead('{"kind": "loan", "email": "x@example.test"}')$$, 'Unknown kind');
select test.throws('request: a way to reply is required', $$select public.submit_place_lead('{"kind": "buyer"}')$$, 'email address or a phone');

-- ================================================================ 8. the door
select public.door(test.id('lp_admin'), null, 'admin_do', 'place_settings_save', '{"region": "MX-JAL", "enabled": false, "place_delivery_reach_km": 60}');
select test.eq('door: an Admin switches a region off and sets the reach', (select (not is_enabled)::text from place_regions where code = 'MX-JAL') || '/' || (app.settings()).place_delivery_reach_km, 'true/60');
select public.door(test.id('lp_admin'), null, 'admin_do', 'place_settings_save', '{"region": "MX-JAL", "enabled": true, "place_delivery_reach_km": 80}');
select public.door(test.id('lp_admin'), null, 'admin_do', 'place_term_save', '{"slug": "car-hire", "canonical_slug": "car-rental"}');
select test.eq('door: a synonym points to its term; its pages are not indexed', (public.place_hub('rental', 'car-hire', 'lp-port-credit-mississauga-on') -> 'term' ->> 'canonical_path'), '/car-rental/lp-port-credit-mississauga-on');
select public.door(test.id('lp_admin'), null, 'admin_do', 'place_term_save', '{"slug": "car-hire", "canonical_slug": ""}');
select test.throws('door: a long dash is refused in a note', format($$select public.door(%L, null, 'admin_do', 'place_term_save', jsonb_build_object('slug', 'wax', 'intent_note', 'Wax ' || chr(8212) || ' shine'))$$, test.id('lp_admin')), 'long dashes');
select public.door(test.id('lp_admin'), null, 'admin_do', 'shop_service_save', '{"code": "glass", "from_price_cents": 9900}');
select test.eq('door: a starting price on a service', (select from_price_cents from shop_services where code = 'glass'), 9900::bigint);
select test.throws('door: an assistant cannot change the place settings', format($$select public.door(%L, null, 'admin_do', 'place_settings_save', '{"place_quality_gate": true}')$$, test.id('lp_cs')), null);
select test.ok('door: the overview counts the places by country and kind', (public.door(test.id('lp_admin'), null, 'admin_read', 'place_overview', '{}') -> 'places' -> 'CA' ->> 'city')::integer >= 2);

-- ================================================================ 9. privileges
set role anon;
select test.lives('anon: reads a hub, the roots, the terms, the sitemaps and the services', $$select public.place_hub('rental', 'car-rental', 'lp-thunder-bay-on'), public.place_roots(), public.place_terms_public(),
  public.place_sitemap_files(), public.place_sitemap('rental', 'car-rental', 1), public.shop_services_public('detailing'), public.business_rating(), public.places_known(array['ontario'])$$);
select test.throws('anon: cannot load places', $$select public.server_places_import_apply(1, 'CA-ON')$$, 'permission');
select test.throws('anon: cannot send a request straight to the database (the site sends it after Turnstile)', $$select public.submit_place_lead('{"kind": "buyer", "email": "a@example.test"}')$$, 'permission');
select test.throws('anon: cannot read the places table', $$select count(*) from places$$, 'permission');
reset role;
