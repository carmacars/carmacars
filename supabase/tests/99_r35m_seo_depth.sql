-- 99: release 35, part M (migrations 1100 to 1103): every page indexable, the content epoch behind lastmod, the sourced
-- page data (specs, maintenance costs, stops and hotels, each with its source), IndexNow's back-off on 5xx with smaller
-- batches, the 01 Motors comparison terms and the coverage count of Admin > Settings > Search.
select test.suite('99 r35m seo depth');

-- ---------------------------------------------------------------- every page indexable
insert into seo_pages (slug, kind, name, facts, match, copy, min_real_cars) values
  ('r35m-use', 'use', 'R35M use', '{}', '{"class": "no-such-class"}', '{}', 5)
on conflict (slug) do nothing;
select test.ok('a landing page for a use with no matching car and no copy yet is indexable (filled, never noindexed)',
  (select app.seo_page_indexable(p) from seo_pages p where slug = 'r35m-use'));
select test.throws('the place quality gate cannot be turned on again', $$update program_settings set place_quality_gate = true where id = (app.settings()).id$$, 'program_settings_no_quality_gate');
select test.ok('a place far beyond the delivery reach, with no real matching car, is indexable', (
  select bool_and(app.place_hub_indexable(p, t, false, 0)) from places p, place_terms t
   where p.kind in (5, 6) and app.place_enabled(p) and t.slug = 'car-rental' and p.id in (select id from places where kind in (5, 6) order by id limit 3)));
select test.throws('the vehicle pages'' rules mode is retired', $$update program_settings set vpage_index_mode = 'rules' where id = (app.settings()).id$$, 'program_settings_vpage_index_all');
select test.ok('a synonym still names its term''s page (not a thin-page rule)', not exists (
  select 1 from place_terms t, places p where t.canonical_slug is not null and app.place_hub_indexable(p, t, true, 1) limit 1));

-- ---------------------------------------------------------------- the content epoch
-- 2004 (release 36) moved the template on again: depth-1 or a later one
select test.ok('the epoch carries this release''s template (or a later one)', (select template in ('depth-1', 'r36-1') from app.seo_content_epoch));
update app.seo_content_epoch set changed_at = now() - interval '3 days' where id;
update program_settings set seo_ai_daily_neurons = seo_ai_daily_neurons where id = (app.settings()).id;
select test.ok('a settings save that changes no page fact keeps the epoch', (select changed_at < now() - interval '2 days' from app.seo_content_epoch));
update fee_defaults set amount_cents = amount_cents + 100 where fee_type_code = 'toll_admin_fee' and vehicle_class is null;
select test.ok('a fee every page shows moves the epoch (and so every page''s lastmod)', (select changed_at > now() - interval '1 minute' from app.seo_content_epoch) or
  not exists (select 1 from fee_defaults where fee_type_code = 'toll_admin_fee'));
update app.seo_content_epoch set changed_at = now() - interval '3 days' where id;
update program_settings set vpage_gas_cents_per_litre = vpage_gas_cents_per_litre + 1 where id = (app.settings()).id;
select test.ok('the fuel price behind the cost of 100 km moves it too', (select changed_at > now() - interval '1 minute' from app.seo_content_epoch));
select test.ok('the server reads it', public.seo_content_epoch() > now() - interval '1 minute');
select test.ok('anon cannot read the epoch function', not has_function_privilege('anon', 'public.seo_content_epoch()', 'execute'));

-- ---------------------------------------------------------------- sourced page data
select test.eq('the loader takes stops and hotels with their source', (app.server_seo_data_load($j${"kind": "pois", "rows": [
  {"kind": "go_station", "agency": "GO Transit", "ref": "R35M1", "name": "Example GO", "lat": 43.6, "lng": -79.6, "source": "gtfs", "source_url": "https://example.test/go", "licence": "Example licence", "attribution": "Stops: GO Transit GTFS (Example licence)", "fetched_at": "2026-11-08T00:00:00Z"},
  {"kind": "hotel", "agency": null, "ref": "node/1", "name": "Example Hotel", "lat": 43.61, "lng": -79.6, "source": "osm", "source_url": "https://www.openstreetmap.org/node/1", "licence": "ODbL 1.0", "attribution": "Hotels: © OpenStreetMap contributors (ODbL)", "fetched_at": "2026-11-08T00:00:00Z"}]}$j$) ->> 'loaded')::int, 2);
select test.throws('a row with no https source is refused', $$select app.server_seo_data_load('{"kind": "pois", "rows": [{"kind": "hotel", "ref": "node/2", "name": "X", "lat": 43.6, "lng": -79.6, "source": "osm", "source_url": "http://x", "licence": "ODbL", "attribution": "OSM", "fetched_at": "2026-11-08T00:00:00Z"}]}')$$, 'source_url');
select test.eq('the place pages read the nearest, with the attribution to show',
  (select string_agg((e ->> 'kind') || ':' || (e ->> 'name') || ':' || (e ->> 'attribution'), '|' order by e ->> 'kind') from jsonb_array_elements(public.place_pois_near(43.6, -79.6, 5, 5)) e where e ->> 'name' like 'Example%'),
  'go_station:Example GO:Stops: GO Transit GTFS (Example licence)|hotel:Example Hotel:Hotels: © OpenStreetMap contributors (ODbL)');
select test.eq('nothing far away', jsonb_array_length(public.place_pois_near(45.4, -75.7, 5, 5)), 0);
select app.server_seo_data_load('{"kind": "pois", "rows": [], "prune": {"source": "gtfs", "agency": "GO Transit", "before": "2026-11-09T00:00:00Z"}}');
select test.eq('a run prunes the stops its feed no longer lists', (select count(*) from place_pois where ref = 'R35M1'), 0::bigint);

select app.server_seo_data_load($j${"kind": "specs", "rows": [
  {"make": "Example", "model": "Model", "year": 2024, "trim": "", "field": "tire_size", "value": "225/45R17", "source": "oem", "source_url": "https://example.test/spec", "fetched_at": "2026-11-08T00:00:00Z"},
  {"make": "Example", "model": "Model", "year": 2024, "trim": "", "field": "paint_colour", "value": "Example Red", "code": "R1", "source": "oem", "source_url": "https://example.test/colours", "fetched_at": "2026-11-08T00:00:00Z"},
  {"make": "Example", "model": "Model", "year": 2024, "trim": "", "field": "paint_colour", "value": "Example Blue", "code": "B1", "source": "oem", "source_url": "https://example.test/colours", "fetched_at": "2026-11-08T00:00:00Z"},
  {"make": "Example", "model": "Model", "year": 2024, "trim": "", "field": "tire_size", "value": "225/40R18", "source": "oem", "source_url": "https://example.test/spec2", "fetched_at": "2026-11-08T00:00:00Z"}]}$j$);
select test.eq('specs: one value per field (the later load wins), every colour its own row, each with its source',
  (select string_agg((e ->> 'field') || '=' || (e ->> 'value') || '@' || (e ->> 'source_url'), '|' order by e ->> 'field', e ->> 'value') from jsonb_array_elements(public.vehicle_specs_for('example', 'model', 2024)) e),
  'paint_colour=Example Blue@https://example.test/colours|paint_colour=Example Red@https://example.test/colours|tire_size=225/40R18@https://example.test/spec2');
select test.throws('a field the pages do not know is refused', $$select app.server_seo_data_load('{"kind": "specs", "rows": [{"make": "Example", "model": "Model", "year": 2024, "field": "made_up", "value": "1", "source": "oem", "source_url": "https://example.test/x", "fetched_at": "2026-11-08T00:00:00Z"}]}')$$);
delete from vehicle_maintenance_costs where segment = 'compact';
select test.eq('no maintenance estimate until the cost table has the make or segment', public.maintenance_cost_for('Example', 'compact'), null::jsonb);
select app.server_seo_data_load('{"kind": "maintenance", "rows": [{"make": "", "segment": "compact", "per_year_cents": 61000, "per_10k_km_cents": 38000, "assumptions": "Assumes 16,000 km a year at Ontario labour rates.", "source": "Example table", "source_url": "https://example.test/costs", "fetched_at": "2026-11-08T00:00:00Z"}]}');
select test.eq('then the segment''s cost, with its assumptions and source', public.maintenance_cost_for('Example', 'Compact') ->> 'source_url', 'https://example.test/costs');
select test.ok('the data tables and loaders are the server''s only', not has_table_privilege('anon', 'place_pois', 'select') and not has_table_privilege('authenticated', 'vehicle_specs', 'select')
  and not has_function_privilege('anon', 'public.place_pois_near(numeric, numeric, numeric, integer)', 'execute') and not has_function_privilege('authenticated', 'app.server_seo_data_load(jsonb)', 'execute'));

-- ---------------------------------------------------------------- IndexNow: smaller batches, back-off on 5xx
update program_settings set indexnow_enabled = true where id = (app.settings()).id;
update indexnow_sweep set backoff_until = null, backoff_s = 0, streak_5xx = 0, streak_429 = 0, next_round_at = null where id;
select test.eq('the sweep sends 1,000 addresses a request by default', (select indexnow_sweep_batch from program_settings where id = (app.settings()).id), 1000);
select app.server_indexnow_report('{"status": 502, "count": 1000, "error": "Bad Gateway", "cursor": {"phase": "places", "p_pos": 99}}');
select test.eq('a 502: 10 minutes, the cursor where it was', (select backoff_s || '/' || streak_5xx from indexnow_sweep), '600/1');
select app.server_indexnow_report('{"status": 503, "count": 1000}');
select app.server_indexnow_report('{"status": 0, "count": 0, "error": "fetch failed"}');
select test.eq('each failure in a row doubles the wait', (select backoff_s || '/' || streak_5xx from indexnow_sweep), '2400/3');
select test.eq('at most 6 hours', app.indexnow_5xx_wait(12), 21600);
select app.server_indexnow_report('{"status": 200, "count": 1000}');
select test.eq('a 2xx resets it', (select coalesce(backoff_s, 0) || '/' || streak_5xx from indexnow_sweep), '0/0');
select app.server_indexnow_report('{"status": 429, "count": 1000, "retry_after": 120}');
select test.eq('a 429 keeps its Retry-After', (select backoff_s from indexnow_sweep), 120);
update indexnow_sweep set q_backoff_until = null, q_backoff_s = 0, q_last_status = null where id;
select app.server_indexnow_sent('{"paths": [], "status": 502}');
select app.server_indexnow_sent('{"paths": [], "status": 502}');
select test.eq('the changed pages double too after 5xx answers', (select q_backoff_s from indexnow_sweep), 1200);
select app.server_indexnow_sent('{"paths": [], "status": 429}');
select test.ok('and a 429 waits at least an hour (0220''s rule)', (select q_backoff_s >= 3600 from indexnow_sweep));

-- ---------------------------------------------------------------- 01 Motors
select test.eq('the 01 Motors terms, active rental terms of their own', (select string_agg(slug || ':' || title, '|' order by sort_order) from place_terms
  where slug in ('01-motors-alternative', 'carmacars-vs-01-motors') and is_active and vertical = 'rental' and canonical_slug is null),
  '01-motors-alternative:01 Motors Alternative|carmacars-vs-01-motors:CarmaCars vs 01 Motors');
select test.ok('they say the page is written by CarmaCars and never that CarmaCars is unaffiliated (01 Motors is a partner, 0093)',
  (select bool_and(intent_note ~ '(written by CarmaCars|in figures from this site)' and (intent_note || faq::text) !~* 'not affiliated') from place_terms where slug in ('01-motors-alternative', 'carmacars-vs-01-motors')));
select test.ok('nothing about the other company''s prices, rules or service', not exists (select 1 from place_terms where slug in ('01-motors-alternative', 'carmacars-vs-01-motors')
  and (intent_note || faq::text) ~* '(cheaper|better than|unlike|their (fees|prices|service)|lower than)'));
select test.ok('the alternative has vehicle twins ("01 Motors alternative: <car>"); the versus page has none', exists (select 1 from app.vpage_terms() where slug = '01-motors-alternative')
  and not exists (select 1 from app.vpage_terms() where slug = 'carmacars-vs-01-motors'));
select test.eq('both in the sitemap files', (select count(distinct f ->> 'term') from jsonb_array_elements(public.place_sitemap_files()) f
  where f ->> 'term' in ('01-motors-alternative', 'carmacars-vs-01-motors')), 2::bigint);

-- ---------------------------------------------------------------- the coverage count
delete from app.gsc_coverage_log;
select app.gsc_coverage_store('{"inspected": 1649, "by_state": {"Submitted and indexed": 15, "Indexed, not submitted in sitemap": 4, "Crawled - currently not indexed": 14, "Discovered - currently not indexed": 3, "URL is unknown to Google": 1600, "Page with redirect": 13}}');
select app.gsc_coverage_store('{"inspected": 10, "by_state": {"Submitted and indexed": 7}, "by_bucket": {"indexed": 7, "crawled": 2, "discovered": 0, "unknown": 1, "other": 0}, "by_part": {"priority": {"indexed": 6, "crawled": 1, "discovered": 0, "unknown": 0, "other": 0}, "tail": {"indexed": 1, "crawled": 1, "discovered": 0, "unknown": 1, "other": 0}}}');
select test.eq('an old row''s states by pattern: 19 indexed, 1,600 unknown to Google',
  (select app.gsc_coverage_buckets(c) from app.gsc_coverage_log c where inspected = 1649), '{"other": 13, "crawled": 14, "indexed": 19, "unknown": 1600, "discovered": 3}'::jsonb);
select test.eq('the trend: indexed of the addresses Google knows, the priority part, the unknown apart',
  (select (d ->> 'inspected') || '/' || (d ->> 'known') || '/' || (d ->> 'indexed') || '/' || (d ->> 'unknown') || '/' || (d ->> 'priority_indexed') || ' of ' || (d ->> 'priority_inspected')
     from jsonb_array_elements(app.gsc_coverage_trend((select u.id from users u where app.user_is_admin(u.id) order by u.created_at limit 1))) d limit 1), '1659/58/26/1601/6 of 7');
