-- 99 r37 SEO market (migration 2350): the place pages keep to our market (US and Mexico regions off: 404 and out of the
-- sitemaps), the Worker's tick says whether any region outside Canada is on, the place sitemap index lists only files that
-- hold pages, and a language keeps its pages indexed while new strings wait for translation. Fixtures start with "sm".
select test.suite('99 r37 SEO market');
select test.mk_user('sm_admin', 'admin');

select test.eq('market: Canada on, the United States and Mexico off',
  (select string_agg(country || '=' || on_::text, ',' order by country) from (select country, bool_or(is_enabled) on_ from place_regions group by country) x),
  'CA=true,MX=false,US=false');
select test.eq('market: a new region starts off', (select column_default from information_schema.columns where table_name = 'place_regions' and column_name = 'is_enabled'), 'false');
select test.ok('market: recorded in the audit log', exists (select 1 from audit_log where action = 'place_market_canada'));

insert into places (kind, region_id, lat, lng, population, slug, name, country) values
  (5, (select id from place_regions where code = 'CA-ON'), 43.8561, -79.337, 338503, 'sm-markham-on', 'Markham', 'CA'),
  (5, (select id from place_regions where code = 'US-NY'), 42.5, -74.9, 300, 'sm-toddsville-ny', 'Toddsville', 'US'),
  (5, (select id from place_regions where code = 'MX-CAM'), 18.6, -91.8, 2000, 'sm-villa-del-mar-cam', 'Villa del Mar', 'MX');

select test.ok('hub: a Canadian place has its page', public.place_hub('rental', 'suv-rental', 'sm-markham-on') is not null);
select test.eq('hub: a US place answers 404 (no hub)', public.place_hub('rental', 'suv-rental', 'sm-toddsville-ny'), null::jsonb);
select test.eq('hub: a Mexican place answers 404 (no hub)', public.place_hub('bodyshop', 'collision-repair', 'sm-villa-del-mar-cam'), null::jsonb);
select test.eq('hub: the United States country page is off', public.place_hub('rental', 'car-rental', 'united-states'), null::jsonb);

-- the sitemap rows of the files: no US or Mexican place
select test.ok('sitemaps: no US or Mexican place in a place file',
  not exists (select 1 from generate_series(1, 2) g, jsonb_array_elements(public.place_sitemap('rental', 'suv-rental', g)) x where x ->> 'path' like '%-ny' or x ->> 'path' like '%-cam'));
select test.ok('sitemaps: the Canadian place is listed',
  exists (select 1 from generate_series(1, 2) g, jsonb_array_elements(public.place_sitemap('rental', 'suv-rental', g)) x where x ->> 'path' = '/car-rental/suv-rental/sm-markham-on'));

-- the index lists only the files that hold pages (the place directory's stored pages)
select app.place_directory_refresh();
select test.ok('sitemap index: every listed file holds an enabled place',
  not exists (select 1 from jsonb_array_elements(public.place_sitemap_files()) f
               where not exists (select 1 from places p join place_regions r on r.id = p.region_id and r.is_enabled
                                  where p.is_active and p.kind <> 8
                                    and (p.id - 1) / (app.settings()).place_sitemap_file_urls + 1 = (f ->> 'page')::integer)
                 and not exists (select 1 from places p where p.kind = 1 and p.country = 'CA' and (p.id - 1) / (app.settings()).place_sitemap_file_urls + 1 = (f ->> 'page')::integer)));
select test.ok('sitemap index: each indexed term still has a file', (select count(distinct f ->> 'term') from jsonb_array_elements(public.place_sitemap_files()) f) >= 1);

-- the Worker's tick
select test.eq('tick: no region outside Canada on', (app.server_jobs_due() ->> 'place_foreign')::boolean, false);
select public.door(test.id('sm_admin'), null, 'admin_do', 'place_settings_save', '{"region": "US-NY", "enabled": true}');
select test.eq('tick: an Admin switches New York back on', (app.server_jobs_due() ->> 'place_foreign')::boolean, true);
select test.ok('hub: then the New York place has its page again', public.place_hub('rental', 'suv-rental', 'sm-toddsville-ny') is not null);
select public.door(test.id('sm_admin'), null, 'admin_do', 'place_settings_save', '{"region": "US-NY", "enabled": false}');
select test.throws('anon: cannot call the tick flag', $$set local role anon; select app.place_foreign_on()$$, 'permission');
reset role;

-- languages: new strings do not noindex a ready language during the grace
select test.ok('languages: the grace is a Program setting, 7 days', (app.settings()).seo_i18n_grace_days = 7);
insert into seo_languages (code, name, native_name, hreflang, dir, mt_code, is_active, sort_order)
  values ('sm', 'Smtest', 'Smtest', 'sm-CA', 'ltr', null, true, 999) on conflict (code) do nothing;
delete from seo_strings where lang = 'sm';
insert into seo_string_sources (key, text, hash, updated_at)
  select 'sm.k' || g, 'String ' || g, md5('String ' || g), now() - interval '30 days' from generate_series(1, 10) g
  on conflict (key) do nothing;
insert into seo_strings (lang, key, text, source_hash)
  select 'sm', x.key, 'T ' || x.key, x.hash from seo_string_sources x;
select test.eq('languages: fully translated is ready', (select (x ->> 'ready')::boolean from jsonb_array_elements(public.seo_languages_state()) x where x ->> 'code' = 'sm'), true);
insert into seo_string_sources (key, text, hash) select 'sm.new' || g, 'New ' || g, md5('New ' || g) from generate_series(1, 5) g;
select test.eq('languages: strings added today do not count against the language (still ready)',
  (select (x ->> 'ready')::boolean from jsonb_array_elements(public.seo_languages_state()) x where x ->> 'code' = 'sm'), true);
update seo_string_sources set updated_at = now() - interval '8 days' where key like 'sm.new%';
select test.eq('languages: once the grace ends, missing strings count again (10 of 15: not ready)',
  (select (x ->> 'ready')::boolean from jsonb_array_elements(public.seo_languages_state()) x where x ->> 'code' = 'sm'), false);
update program_settings set seo_i18n_grace_days = 30;
select test.eq('languages: the grace follows the setting',
  (select (x ->> 'ready')::boolean from jsonb_array_elements(public.seo_languages_state()) x where x ->> 'code' = 'sm'), true);
update program_settings set seo_i18n_grace_days = 7;
delete from seo_string_sources where key like 'sm.%';
delete from seo_languages where code = 'sm';

-- the queries within reach (ranking 5 to 30) on the SEO page, Admin and staff alike
delete from app.gsc_page_query where key like 'sm %';
insert into app.gsc_page_query (kind, key, clicks, impressions, ctr, position, window_end) values
  ('query', 'sm suv rental markham', 3, 900, 0.0033, 8.4, current_date),
  ('query', 'sm car rental toronto', 40, 2000, 0.02, 2.1, current_date),
  ('query', 'sm cheap van rental', 0, 500, 0, 41, current_date),
  ('query', 'sm rare query', 0, 5, 0, 12, current_date);
select test.eq('within reach: positions 5 to 30 with enough impressions only',
  (select string_agg(x ->> 'key', ',') from jsonb_array_elements(app.seo_data() -> 'striking') x where x ->> 'key' like 'sm %'), 'sm suv rental markham');
select test.eq('within reach: the line follows the Program settings', app.seo_data() -> 'striking_line' ->> 'max_pos', '30.0');
select test.ok('within reach: the read-only staff view has it too', jsonb_typeof(app.seo_data(now(), true) -> 'striking') = 'array');
select test.throws('within reach: the range is checked', $$update program_settings set seo_striking_min_pos = 40, seo_striking_max_pos = 30$$, 'program_settings_seo_striking_range');
select test.throws('anon: cannot read the SEO data', $$set local role anon; select app.seo_data()$$, 'permission');
reset role;
delete from app.gsc_page_query where key like 'sm %';
