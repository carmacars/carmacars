-- 99 r40 SEO scope (migration 2402): the place pages keep to Ontario (every other region off, none deleted, the edge mask),
-- cars from vpage_min_year (2005) on in every tree and sitemap, and one page per service group (synonyms answer 301 and are
-- listed on the group's pages). Fixtures start with "r40".
select test.suite('99 r40 SEO scope');
select test.mk_user('r40_admin', 'admin');

-- ================================================================ A. Ontario only
select test.eq('market: Ontario is the only region on', (select string_agg(code, ',') from place_regions where is_enabled), 'CA-ON');
select test.ok('market: no region was deleted (13 Canadian, 56 US, 32 Mexican)',
  (select count(*) filter (where country = 'CA') = 13 and count(*) filter (where country = 'US') = 56 and count(*) filter (where country = 'MX') = 32 from place_regions));
select test.ok('market: recorded in the audit log', exists (select 1 from audit_log where action = 'place_market_ontario'));

insert into places (kind, region_id, lat, lng, population, slug, name, country) values
  (5, (select id from place_regions where code = 'CA-ON'), 43.59, -79.64, 717961, 'r40-mississauga-on', 'Mississauga', 'CA'),
  (5, (select id from place_regions where code = 'CA-QC'), 45.48, -75.70, 291041, 'r40-gatineau-qc', 'Gatineau', 'CA'),
  (5, (select id from place_regions where code = 'CA-BC'), 49.88, -119.49, 144576, 'r40-kelowna-bc', 'Kelowna', 'CA');
insert into places (parent_id, kind, region_id, lat, lng, population, slug, name, country) values
  ((select id from places where slug = 'r40-mississauga-on'), 6, (select id from place_regions where code = 'CA-ON'), 43.59, -79.65, 30000, 'r40-port-credit-mississauga-on', 'Port Credit', 'CA'),
  ((select id from places where slug = 'canada'), 2, (select id from place_regions where code = 'CA-QC'), 52.0, -72.0, null, 'r40-quebec', 'Quebec', 'CA');
select app.place_roots_refresh();

select test.ok('neighbourhoods: an Ontario neighbourhood has its page', public.place_hub('detailing', 'car-detailing', 'r40-port-credit-mississauga-on') is not null);
select test.ok('neighbourhoods: every active Ontario place is on, neighbourhoods included',
  not exists (select 1 from places p join place_regions r on r.id = p.region_id where r.code = 'CA-ON' and p.is_active and not app.place_enabled(p)));
select test.eq('another province: Quebec answers 404 (no hub)', public.place_hub('rental', 'suv-rental', 'r40-gatineau-qc'), null::jsonb);
select test.eq('another province: the province page itself answers 404', public.place_hub('rental', 'car-rental', 'r40-quebec'), null::jsonb);
select test.eq('countries: the United States page answers 404', public.place_hub('rental', 'car-rental', 'united-states'), null::jsonb);
select test.eq('Canada: its page says we operate in Ontario', (select string_agg(e ->> 'slug', ',') from jsonb_array_elements(public.place_hub('rental', 'car-rental', 'canada') -> 'operating') e), 'ontario');
select test.ok('Canada: it links no province that is off', not exists (select 1 from jsonb_array_elements(public.place_hub('rental', 'car-rental', 'canada') -> 'children') e where e ->> 'slug' = 'r40-quebec'));
select test.eq('another province: British Columbia answers 404 (no hub)', public.place_hub('bodyshop', 'collision-repair', 'r40-kelowna-bc'), null::jsonb);
select test.ok('sitemaps: the Ontario neighbourhood is listed, the other provinces are not',
  exists (select 1 from generate_series(1, 2) g, jsonb_array_elements(public.place_sitemap('detailing', 'car-detailing', g)) x where x ->> 'path' = '/detailing/car-detailing/r40-port-credit-mississauga-on')
  and not exists (select 1 from generate_series(1, 2) g, jsonb_array_elements(public.place_sitemap('detailing', 'car-detailing', g)) x where x ->> 'path' like '%-qc' or x ->> 'path' like '%-bc'));
select app.place_directory_refresh();
select test.ok('directory: only Ontario (and Canada itself)',
  not exists (select 1 from app.place_directory_cache c, unnest(c.regions) r where r not in ('Ontario', 'Canada')));
select test.eq('roots: the countries and provinces listed are Canada and Ontario only',
  (select string_agg(x ->> 'slug', ',' order by x ->> 'slug') from jsonb_array_elements(public.place_roots() -> 'tops') x where x ->> 'kind' in ('country', 'province')), 'canada,ontario');
select test.ok('tier sitemaps: they span the places of the regions that are on',
  app.vpage_place_max() < (select max(id) from places) and app.vpage_place_max() >= (select max(id) from places where slug = 'r40-port-credit-mississauga-on'));

-- the Worker's tick: the mask of the regions that are on (bit 0 Ontario), and the old flag (any region but Ontario)
select test.eq('tick: the market mask is Ontario', (app.server_jobs_due() ->> 'place_market')::integer, 1);
select test.eq('tick: no region but Ontario on', (app.server_jobs_due() ->> 'place_foreign')::boolean, false);
select public.door(test.id('r40_admin'), null, 'admin_do', 'place_settings_save', '{"region": "CA-QC", "enabled": true}');
select test.eq('tick: an Admin switches Quebec back on (bit 1)', (app.server_jobs_due() ->> 'place_market')::integer, 3);
select test.eq('tick: the old flag follows', (app.server_jobs_due() ->> 'place_foreign')::boolean, true);
select test.ok('hub: then the Quebec place has its page again', public.place_hub('rental', 'suv-rental', 'r40-gatineau-qc') is not null);
select test.ok('roots: Quebec is listed at once', exists (select 1 from jsonb_array_elements(public.place_roots() -> 'tops') x where x ->> 'slug' = 'r40-quebec'));
select public.door(test.id('r40_admin'), null, 'admin_do', 'place_settings_save', '{"region": "US-NY", "enabled": true}');
select test.eq('tick: any US state on sets the US bit', (app.server_jobs_due() ->> 'place_market')::integer, 3 | (1 << 13));
select public.door(test.id('r40_admin'), null, 'admin_do', 'place_settings_save', '{"region": "US-NY", "enabled": false}');
select public.door(test.id('r40_admin'), null, 'admin_do', 'place_settings_save', '{"region": "CA-QC", "enabled": false}');
select test.eq('tick: back to Ontario', (app.server_jobs_due() ->> 'place_market')::integer, 1);
select test.ok('roots: Quebec leaves them at once', not exists (select 1 from jsonb_array_elements(public.place_roots() -> 'tops') x where x ->> 'slug' = 'r40-quebec'));
select test.throws('anon: cannot call the market mask', $$set local role anon; select app.place_market_mask()$$, 'permission');
reset role;

-- ================================================================ B. cars from 2005 on
select test.eq('years: the oldest model year is a Program setting, 2005', (app.settings()).vpage_min_year, 2005);
select test.eq('tick: the Worker learns it', (app.server_jobs_due() ->> 'vpage_min_year')::integer, 2005);
select test.eq('years: the page settings carry it', (app.vpage_settings_json(app.settings())) ->> 'min_year', '2005');

insert into vehicle_catalog_makes (slug, name) values ('r40make', 'Rfortymake');
insert into vehicle_catalog_models (make_slug, slug, name, key, vclass) values
  ('r40make', 'r40new', 'Newmodel', 'r40new', 'sedan'), ('r40make', 'r40old', 'Oldmodel', 'r40old', 'sedan');
insert into vehicle_catalog_years (make_slug, model_slug, year, vclass, powertrains, variants) values
  ('r40make', 'r40new', 2003, 'sedan', 1, '[]'), ('r40make', 'r40new', 2005, 'sedan', 1, '[]'), ('r40make', 'r40new', 2020, 'sedan', 1, '[]'),
  ('r40make', 'r40old', 2001, 'sedan', 1, '[]'), ('r40make', 'r40old', 2003, 'sedan', 1, '[]');
insert into vehicle_catalog_trims (make_slug, model_slug, year, slug, name, rank, source, ord)
  select x.m, x.mo, x.y, 'base', 'Base', 1, 'test', (select coalesce(max(ord), 0) from vehicle_catalog_trims) + x.n
    from (values ('r40make', 'r40new', 2003, 1), ('r40make', 'r40new', 2005, 2), ('r40make', 'r40new', 2020, 3), ('r40make', 'r40old', 2003, 4)) x(m, mo, y, n);

select test.eq('404: a model year below 2005', app.vehicle_year_page('r40make', 'r40new', 2003), null::jsonb);
select test.eq('404: its trim page', app.vehicle_trim_page('r40make', 'r40new', 2003, 'base'), null::jsonb);
select test.eq('404: its place page', app.vehicle_tier_page('r40make', 'r40new', 2003, 'base', 'r40-mississauga-on', null), null::jsonb);
select test.eq('404: its colour page', app.vehicle_tier_page('r40make', 'r40new', 2003, 'base', null, 'black'), null::jsonb);
select test.eq('404: the public read too', public.vehicle_year_page('r40make', 'r40new', 2003), null::jsonb);
select test.ok('2005 and newer have their pages', app.vehicle_year_page('r40make', 'r40new', 2005) is not null and app.vehicle_trim_page('r40make', 'r40new', 2020, 'base') is not null);
select test.eq('the 2005 page names no older year before it', app.vehicle_year_page('r40make', 'r40new', 2005) -> 'prev', 'null'::jsonb);
select test.eq('a trim lists its years from 2005', (select string_agg(e ->> 'year', ',' order by e ->> 'year') from jsonb_array_elements(app.vehicle_trim_page('r40make', 'r40new', 2020, 'base') -> 'trim_years') e), '2005,2020');
select test.eq('the model page lists only 2005 and newer', (select string_agg(e ->> 'year', ',' order by e ->> 'year') from jsonb_array_elements(app.vehicle_model_page('r40make', 'r40new') -> 'years') e), '2005,2020');
select test.eq('the year page''s other years too', (select string_agg(e ->> 'year', ',' order by e ->> 'year') from jsonb_array_elements(app.vehicle_year_page('r40make', 'r40new', 2020) -> 'other_years') e), '2005,2020');
select test.eq('404: a model with only older years (and none of our cars)', app.vehicle_model_page('r40make', 'r40old'), null::jsonb);
select test.eq('the make page lists only the model with newer years, from 2005',
  (select string_agg(e ->> 'slug' || ':' || (e ->> 'first_year') || ':' || (e ->> 'years'), ',') from jsonb_array_elements(app.vehicle_make_page('r40make') -> 'models') e), 'r40new:2005:2');
select test.ok('sitemaps: no older year, trim or model in the addresses of the trees',
  not exists (select 1 from app.vpage_all('r40make') a where a.path ~ '/(2001|2003)(/|$)' or a.path like '%/r40old%')
  and exists (select 1 from app.vpage_all('r40make') a where a.path = '/cars/r40make/r40new/2005'));
select test.ok('sitemaps: the place and colour sitemaps skip older trims',
  not exists (select 1 from app.vpage_trim_indexed(0, 1000000000) t where t.make_slug = 'r40make' and t.year < 2005)
  and exists (select 1 from app.vpage_trim_indexed(0, 1000000000) t where t.make_slug = 'r40make' and t.year = 2020));
select app.vehicle_sitemap_files_refresh();
select test.ok('sitemaps: the stored year and trim files have no older year',
  not exists (select 1 from jsonb_array_elements(public.vehicle_sitemap('r40make-years') || public.vehicle_sitemap('r40make-trims')) x where x ->> 'path' ~ '/2003')
  and exists (select 1 from jsonb_array_elements(public.vehicle_sitemap('r40make-years')) x where x ->> 'path' = '/cars/r40make/r40new/2020'));
select test.eq('renting vs owning: no page for an older year', public.rent_vs_own_page('r40make', 'r40new', 2003, null), null::jsonb);

-- the stored sitemap shape: the stamp counts the setting, so a change reads the shape live until it is stored again
select app.vehicle_sitemap_shape_refresh();
select test.ok('shape: stored with the stamp of the setting', (select shape_switches from app.vehicle_sitemap_files_cache_state) = app.vehicle_sitemap_switches());
update program_settings set vpage_min_year = 2000;
select test.ok('shape: a new oldest year changes the stamp', (select shape_switches from app.vehicle_sitemap_files_cache_state) is distinct from app.vehicle_sitemap_switches());
select test.ok('years: the setting is followed (2003 has its page from 2000)', app.vehicle_year_page('r40make', 'r40new', 2003) is not null);
select app.vehicle_sitemap_shape_refresh();
select test.ok('shape: stored again by the job', (select shape_switches from app.vehicle_sitemap_files_cache_state) = app.vehicle_sitemap_switches());
update program_settings set vpage_min_year = 2005;
select app.vehicle_sitemap_shape_refresh();
select test.throws('years: the setting is checked', $$update program_settings set vpage_min_year = 1800$$, 'program_settings_vpage_min_year_check');

-- ================================================================ C. one page per service group
select test.eq('groups: car hire, cars for hire and vehicle rental are car rental',
  (select string_agg(slug || '>' || canonical_slug, ',' order by slug) from place_terms where slug in ('car-hire', 'cars-for-hire', 'vehicle-rental', 'car-rentals')),
  'car-hire>car-rental,car-rentals>car-rental,cars-for-hire>car-rental,vehicle-rental>car-rental');
select test.eq('groups: collision repair and auto body repair are one', (select canonical_slug from place_terms where slug = 'auto-body-repair'), 'collision-repair');
select test.eq('groups: car detailing and its plain synonyms are one',
  (select string_agg(slug, ',' order by slug) from place_terms where canonical_slug = 'car-detailing'), 'auto-detail,auto-detailing,car-cleaning,car-detail,full-detail');
select test.ok('groups: different services keep their own pages',
  (select bool_and(canonical_slug is null and is_active) from place_terms where slug in ('interior-detailing', 'exterior-detailing', 'ceramic-coating', 'window-tint', 'paint-protection-film',
     'car-financing', 'car-leasing', 'lease-takeover', 'insurance-replacement-rental', 'oil-change', 'brake-repair', 'tire-change', 'winter-tires', 'mechanic', 'car-wrap'))
  and (select count(*) from place_terms where slug in ('interior-detailing', 'exterior-detailing', 'ceramic-coating', 'window-tint', 'paint-protection-film',
     'car-financing', 'car-leasing', 'lease-takeover', 'insurance-replacement-rental', 'oil-change', 'brake-repair', 'tire-change', 'winter-tires', 'mechanic', 'car-wrap')) = 15);
select test.ok('groups: no term deleted (the synonyms stay, active)', (select count(*) from place_terms where slug in ('car-hire', 'auto-detailing', 'body-shop', 'ppf', 'vinyl-wrap') and is_active) = 5);
select test.ok('groups: one hop (no synonym points at a synonym)',
  not exists (select 1 from place_terms s join place_terms t on t.slug = s.canonical_slug where t.canonical_slug is not null));
select test.ok('groups: a group and its synonyms share a family', not exists (select 1 from place_terms s join place_terms t on t.slug = s.canonical_slug where t.vertical <> s.vertical));
select test.ok('groups: recorded in the audit log', exists (select 1 from audit_log where action = 'place_term_groups'));

-- 301: a synonym's place page answers with its group's page
select test.eq('301: car hire in a place goes to car rental there', public.place_hub('rental', 'car-hire', 'r40-mississauga-on') ->> 'redirect', '/car-rental/r40-mississauga-on');
select test.eq('301: auto detailing goes to car detailing', public.place_hub('detailing', 'auto-detailing', 'r40-port-credit-mississauga-on') ->> 'redirect', '/detailing/car-detailing/r40-port-credit-mississauga-on');
select test.eq('301: an older synonym follows its group (car body shop)', public.place_hub('bodyshop', 'car-body-shop', 'r40-mississauga-on') ->> 'redirect', '/body-shop/collision-repair/r40-mississauga-on');
select test.eq('301: never for a place that is off (404)', public.place_hub('rental', 'car-hire', 'r40-gatineau-qc'), null::jsonb);
select test.ok('group page: lists its synonyms', (public.place_hub('detailing', 'car-detailing', 'r40-mississauga-on') -> 'term' -> 'synonyms') ? 'auto detailing'
  and not (public.place_hub('detailing', 'car-detailing', 'r40-mississauga-on') ? 'redirect'));
select test.ok('group page: car rental lists car hire', (public.place_hub('rental', 'car-rental', 'r40-mississauga-on') -> 'term' -> 'synonyms') ? 'car hire');
select test.ok('group page: links only to groups (no synonym among the rentals of a body shop page)',
  not exists (select 1 from jsonb_array_elements(public.place_hub('bodyshop', 'collision-repair', 'r40-mississauga-on') -> 'rental_terms') e where e ->> 'slug' = 'collision-replacement-car'));
select test.ok('sitemaps: a synonym has no place sitemap rows', jsonb_array_length(public.place_sitemap('rental', 'car-hire', 1)) = 0
  and not exists (select 1 from jsonb_array_elements(public.place_sitemap_files()) f where f ->> 'term' in ('car-hire', 'auto-detailing', 'body-shop')));
-- the vehicle trees: no tree of a synonym, the map the /t pages answer 301 with, the phrases of each group
select test.ok('trees: no vehicle tree for a synonym', not exists (select 1 from app.vpage_trees() t where t.term in ('car-hire', 'auto-detailing', 'vinyl-wrap', 'auto-loans'))
  and exists (select 1 from app.vpage_trees() t where t.term = 'car-detailing'));
select test.eq('trees: car hire maps to the /cars tree', app.vpage_tiers() -> 'synonyms' ->> 'car-hire', '');
select test.eq('trees: auto detailing maps to the car detailing tree', app.vpage_tiers() -> 'synonyms' ->> 'auto-detailing', 'car-detailing');
select test.ok('trees: each group term carries its synonyms', exists (select 1 from jsonb_array_elements(app.vpage_tiers() -> 'terms') t where t ->> 'slug' = 'car-detailing' and (t -> 'also') ? 'auto detailing'));
select test.ok('vehicle pages: the /cars pages list the car rental group''s synonyms',
  (app.vehicle_year_page('r40make', 'r40new', 2020) -> 'also') ? 'car hire' and (app.vehicle_trim_page('r40make', 'r40new', 2020, 'base') -> 'also') ? 'vehicle rental'
  and (app.vehicle_model_page('r40make', 'r40new') -> 'also') ? 'cars for hire');
select test.ok('vehicle pages: a place page of a trim too', (app.vehicle_tier_page('r40make', 'r40new', 2020, 'base', 'r40-mississauga-on', null) -> 'also') ? 'car hire');

-- an Admin's synonym is always one hop: pointed at a synonym, it goes to the group; a group made a synonym takes its own along
insert into place_terms (slug, vertical, phrase, title) values ('r40-hire-a-car', 'rental', 'r40 hire a car', 'R40 Hire a Car'), ('r40-wheels', 'rental', 'r40 wheels', 'R40 Wheels'),
  ('r40-wheels-hire', 'rental', 'r40 wheels hire', 'R40 Wheels Hire');
select public.door(test.id('r40_admin'), null, 'admin_do', 'place_term_save', '{"slug": "r40-hire-a-car", "canonical_slug": "car-hire"}');
select test.eq('trigger: a synonym of a synonym goes to the group', (select canonical_slug from place_terms where slug = 'r40-hire-a-car'), 'car-rental');
update place_terms set canonical_slug = 'r40-wheels' where slug = 'r40-wheels-hire';
update place_terms set canonical_slug = 'car-rental' where slug = 'r40-wheels';
select test.eq('trigger: a group made a synonym takes its synonyms along', (select canonical_slug from place_terms where slug = 'r40-wheels-hire'), 'car-rental');
select test.throws('trigger: a term cannot point at its own synonym', $$update place_terms set canonical_slug = 'r40-hire-a-car' where slug = 'car-rental'$$, 'own synonyms');
delete from place_terms where slug like 'r40-%';

-- fixtures out
delete from vehicle_catalog_trims where make_slug = 'r40make';
delete from vehicle_catalog_years where make_slug = 'r40make';
delete from vehicle_catalog_models where make_slug = 'r40make';
delete from vehicle_catalog_makes where slug = 'r40make';
select app.vehicle_sitemap_files_refresh();
