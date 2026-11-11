-- 99: release 36, SEO (migrations 2000 to 2004; docs/changes/2026-11-11-r36-seo-growth.md). Positive term copy, demand
-- steering, the car data loader's new fields and sources, parking places, reviews received elsewhere (who may add
-- them, the rules that keep them real) and the review summary, events, the Turo problem pages, the tracker product,
-- airports, renting vs owning, the languages and the sitemaps of the new families. Fixtures start with "rs".
select test.suite('99 r36 seo');
select test.mk_user('rs_admin', 'admin');
select test.mk_user('rs_cs', 'va', 'cs');
select test.mk_user('rs_sales', 'va', 'sales');
select test.mk_user('rs_fin', 'va', 'finance');
select test.mk_renter('rs_renter');

-- ================================================================ 1. positive copy
select test.eq('term notes never open with what we lack', (select count(*) from place_terms where intent_note ~* '^(we (do not|are not)|we don.t)'), 0::bigint);
select test.ok('the versus page says what to check, not what we do not publish',
  (select intent_note !~* 'do not publish' and faq::text !~* 'do not publish' from place_terms where slug = 'carmacars-vs-01-motors'));

-- ================================================================ 8. demand steering
create temp table rs_cars (label text, id uuid);
grant all on rs_cars to public;
insert into rs_cars select 'c' || g, (app.vehicle_add(test.id('rs_admin'), jsonb_build_object('supply_type', 'company', 'plate', 'RSA ' || lpad(g::text, 3, '0'), 'year', 2015 + g % 8,
  'make', 'Kia', 'model', 'Rio ' || g, 'class', 'economy', 'rates', jsonb_build_object('daily', 4000 + g))) ->> 'vehicle_id')::uuid from generate_series(1, 7) g;
create function test.rs(p text) returns uuid language sql stable as $$ select id from rs_cars where label = p $$;
update vehicle_listings set status = 'published', first_published_at = coalesce(first_published_at, now()) where vehicle_id in (select id from rs_cars);
-- c1 takes most of the requests (the older luxury sedan's pattern); the others a few each, and more views
insert into vehicle_interest_daily (vehicle_id, day, views, viewers, requests, quotes)
select id, app.local_date(now()) - 1, case when label = 'c1' then 5000 else 40 end, 10, case when label = 'c1' then 400 else 2 end, 0 from rs_cars;
select app.job_fleet_trending();
select test.ok('steering: the most requested car is popular, the others are not',
  (select popular from app.fleet_trend where vehicle_id = test.rs('c1')) and not exists (select 1 from app.fleet_trend t join rs_cars c on c.id = t.vehicle_id where c.label <> 'c1' and t.popular));
select test.ok('steering: its share is stored', (select request_share_bps > 2500 from app.fleet_trend where vehicle_id = test.rs('c1')));
select test.ok('steering: its score is capped below its raw score and under the (cap rank - 1)th car',
  (select score < raw_score from app.fleet_trend where vehicle_id = test.rs('c1'))
  and (select count(*) from app.fleet_trend where not popular and score > (select score from app.fleet_trend where vehicle_id = test.rs('c1'))) >= (select (app.settings()).fleet_demand_cap_rank - 1));
select test.ok('steering: the website''s fleet says popular', exists (select 1 from app.public_fleet_trending('{}') r where (r ->> 'vehicle_id')::uuid = test.rs('c1') and (r ->> 'popular')::boolean));
select test.ok('steering: the popular ids list it', test.rs('c1') = any (public.fleet_popular_ids()));
update program_settings set fleet_demand_cap_bps = 10000;
select app.job_fleet_trending();
select test.ok('steering: 10,000 turns it off', not (select popular from app.fleet_trend where vehicle_id = test.rs('c1')) and (select score = raw_score from app.fleet_trend where vehicle_id = test.rs('c1')));
update program_settings set fleet_demand_cap_bps = 2500;
select test.throws('steering: the cap is a checked setting', $$update program_settings set fleet_demand_cap_bps = 100$$, '%check%');

-- ================================================================ 3. car data (2001)
select app.server_seo_data_load(jsonb_build_object('kind', 'specs', 'rows', jsonb_build_array(
  jsonb_build_object('make', 'Cadillac', 'model', 'CTS', 'year', 2015, 'field', 'common_problem', 'value', 'Engine (12 complaints to NHTSA)', 'source', 'nhtsa_complaints', 'source_url', 'https://example.test/n', 'fetched_at', now()),
  jsonb_build_object('make', 'Cadillac', 'model', 'CTS', 'year', 2015, 'field', 'common_problem', 'value', 'Electrical System (9 complaints to NHTSA)', 'source', 'nhtsa_complaints', 'source_url', 'https://example.test/n', 'fetched_at', now()),
  jsonb_build_object('make', 'Cadillac', 'model', 'CTS', 'year', 2015, 'field', 'recall_item', 'value', 'Air Bags', 'code', 'TC 2015123', 'source', 'transport_canada', 'source_url', 'https://example.test/tc', 'fetched_at', now()),
  jsonb_build_object('make', 'Cadillac', 'model', 'CTS', 'year', 2015, 'field', 'production_start', 'value', '2014', 'source', 'wikidata', 'source_url', 'https://example.test/w', 'fetched_at', now()),
  jsonb_build_object('make', 'Cadillac', 'model', 'CTS', 'year', 2015, 'field', 'msrp_cad', 'value', '52895', 'source', 'oem', 'source_url', 'https://example.test/o', 'fetched_at', now()))));
select test.eq('specs: list fields keep one row per value', (select count(*) from vehicle_specs where make = 'Cadillac' and model = 'CTS' and field = 'common_problem'), 2::bigint);
select app.server_seo_data_load(jsonb_build_object('kind', 'specs', 'rows', jsonb_build_array(
  jsonb_build_object('make', 'Cadillac', 'model', 'CTS', 'year', 2015, 'field', 'common_problem', 'value', 'Engine (12 complaints to NHTSA)', 'source', 'nhtsa_complaints', 'source_url', 'https://example.test/n', 'fetched_at', now()))));
select test.eq('specs: loading again adds nothing', (select count(*) from vehicle_specs where make = 'Cadillac' and model = 'CTS' and field = 'common_problem'), 2::bigint);
select test.ok('specs: the new fields are read on the page', (select count(*) from jsonb_array_elements(public.vehicle_specs_for('Cadillac', 'CTS', 2015))) = 5);
select test.throws('specs: a value with no https source is refused', $$select app.server_seo_data_load('{"kind": "specs", "rows": [{"make": "A", "model": "B", "year": 2020, "field": "msrp_cad", "value": "1", "source": "oem", "source_url": "http://x", "fetched_at": "2026-11-11"}]}')$$, '%source_url%');
select test.throws('specs: an unknown field is refused', $$select app.server_seo_data_load('{"kind": "specs", "rows": [{"make": "A", "model": "B", "year": 2020, "field": "made_up", "value": "1", "source": "oem", "source_url": "https://x", "fetched_at": "2026-11-11"}]}')$$, '%check%');
select app.server_seo_data_load(jsonb_build_object('kind', 'specs', 'rows', '[]'::jsonb, 'prune', jsonb_build_object('source', 'nhtsa_complaints', 'before', now() + interval '1 minute', 'fields', jsonb_build_array('common_problem'))));
select test.eq('specs: a prune by source and field removes only those', (select count(*) from vehicle_specs where make = 'Cadillac' and model = 'CTS'), 3::bigint);

-- ================================================================ 4. parking
select app.server_seo_data_load(jsonb_build_object('kind', 'pois', 'rows', jsonb_build_array(
  jsonb_build_object('kind', 'parking_lot', 'ref', 'way/rs1', 'name', 'Example Garage', 'lat', 43.6440, 'lng', -79.3790, 'source', 'osm', 'source_url', 'https://www.openstreetmap.org/way/1',
    'licence', 'ODbL 1.0', 'attribution', 'Parking: © OpenStreetMap contributors (ODbL)', 'fetched_at', now(), 'detail', jsonb_build_object('parking', 'multi-storey', 'capacity', 300)),
  jsonb_build_object('kind', 'street_parking', 'ref', 'way/rs2', 'name', 'Example Street', 'lat', 43.6445, 'lng', -79.3795, 'source', 'osm', 'source_url', 'https://www.openstreetmap.org/way/2',
    'licence', 'ODbL 1.0', 'attribution', 'Parking: © OpenStreetMap contributors (ODbL)', 'fetched_at', now(), 'detail', jsonb_build_object('parking', 'street', 'maxstay', '3 hours')))));
select test.ok('parking: lots and streets near a point, with their detail',
  (select count(*) = 2 and bool_and(x -> 'detail' <> '{}'::jsonb) from jsonb_array_elements(public.place_pois_near(43.6435, -79.3791, 1, 5)) x where x ->> 'kind' in ('parking_lot', 'street_parking')));
select test.throws('parking: an unknown kind is refused', $$insert into place_pois (kind, ref, name, lat, lng, source, source_url, licence, attribution, fetched_at) values ('car_wash', 'x', 'x', 43, -79, 'osm', 'https://x', 'ODbL', 'x', now())$$, '%check%');

-- ================================================================ 12. reviews received elsewhere
select test.ok('add a review: an Admin', (app.door(test.id('rs_admin'), '', 'admin_do', 'outside_review_add', jsonb_build_object('reviewer_name', 'Sarah K.', 'source', 'turo',
  'received_on', app.local_date(now()) - 30, 'rating', 5, 'body', 'Great car, smooth pickup.', 'vehicle_id', test.rs('c2'))) ->> 'id') is not null);
select test.ok('add a review: customer service', (app.door(test.id('rs_cs'), '', 'ops_do', 'outside_review_add', jsonb_build_object('reviewer_name', 'Omar B.', 'source', 'text_message',
  'received_on', app.local_date(now()) - 10, 'rating', 4, 'body', 'Clean and on time.', 'vehicle_id', test.rs('c2'))) ->> 'id') is not null);
select test.ok('add a review: sales', (app.door(test.id('rs_sales'), '', 'ops_do', 'outside_review_add', jsonb_build_object('reviewer_name', 'Ana Maria P.', 'source', 'phone_call',
  'received_on', app.local_date(now()) - 5, 'rating', 5, 'body', 'Easy from start to finish.')) ->> 'id') is not null);
select test.throws('add a review: not finance', $$select app.door(test.id('rs_fin'), '', 'ops_do', 'outside_review_add', '{"reviewer_name": "Li W.", "source": "email", "received_on": "2026-01-02", "rating": 5, "body": "Good."}')$$, '%Admin, customer service or sales%');
select test.throws('add a review: not a renter', $$select app.outside_review_add(test.id('rs_renter'), '{"reviewer_name": "Li W.", "source": "email", "received_on": "2026-01-02", "rating": 5, "body": "Good."}')$$, '%Admin, customer service or sales%');
select test.throws('a review: first name and last initial only', $$select app.outside_review_add(test.id('rs_admin'), '{"reviewer_name": "Li Wong", "source": "email", "received_on": "2026-01-02", "rating": 5, "body": "Good."}')$$, '%last initial%');
select test.throws('a review: never a date in the future', format($$select app.outside_review_add(test.id('rs_admin'), '{"reviewer_name": "Li W.", "source": "email", "received_on": "%s", "rating": 5, "body": "Good."}')$$, app.local_date(now()) + 2), '%future%');
select test.throws('a review: the same review twice is refused', format($$select app.outside_review_add(test.id('rs_admin'), '{"reviewer_name": "Sarah K.", "source": "turo", "received_on": "%s", "rating": 5, "body": "Great car, smooth pickup."}')$$, app.local_date(now()) - 30), '%already entered%');
select test.throws('a review: an unknown source is refused', $$select app.outside_review_add(test.id('rs_admin'), '{"reviewer_name": "Li W.", "source": "made_up", "received_on": "2026-01-02", "rating": 5, "body": "Good."}')$$, '%check%');
select test.throws('a review: the words are kept as received', $$update outside_reviews set body = 'Changed' where reviewer_name = 'Sarah K.'$$, '%as received%');
select test.throws('a review: never deleted', $$delete from outside_reviews where reviewer_name = 'Sarah K.'$$, '%never deleted%');
select test.throws('hide a review: an Admin only', format($$select app.door(test.id('rs_cs'), '', 'ops_do', 'outside_review_hide', '{"id": "%s", "reason": "abusive"}')$$, (select id from outside_reviews where reviewer_name = 'Omar B.')), '%');
select test.ok('the car''s summary: its reviews with their source, counted for the rating',
  (select (s ->> 'scope') = 'car' and (s ->> 'count')::integer = 2 and (s ->> 'average')::numeric = 4.5 and s -> 'items' @> '[{"source_label": "via Turo"}]'::jsonb from public.review_summary(test.rs('c2')) s));
select test.ok('the car''s summary: completed rentals only from 3 (none here)', (select (s -> 'rentals') = 'null'::jsonb from public.review_summary(test.rs('c2')) s));
select test.ok('a car with no review: the fleet''s reviews instead', (select (s ->> 'scope') = 'fleet' and (s ->> 'count')::integer >= 3 from public.review_summary(test.rs('c3')) s));
select app.door(test.id('rs_admin'), '', 'admin_do', 'outside_review_hide', jsonb_build_object('id', (select id from outside_reviews where reviewer_name = 'Omar B.'), 'reason', 'entered_by_mistake'));
select test.eq('a hidden review leaves the summary', (select (public.review_summary(test.rs('c2')) ->> 'count')::integer), 1);
select test.ok('the staff list: customer service and sales read it, finance does not',
  jsonb_array_length(app.door(test.id('rs_cs'), '', 'ops_read', 'outside_reviews', '{}')) >= 3);
select test.throws('the staff list: not finance', $$select app.door(test.id('rs_fin'), '', 'ops_read', 'outside_reviews', '{}')$$, '%');

-- ================================================================ 5. events
select test.ok('events: seeded from the organisers, each with a source and usual months, no guessed date',
  (select count(*) >= 15 and bool_and(source_url ~ '^https://' and starts_on is null) from seo_events));
select test.ok('events: an Admin adds one', (app.door(test.id('rs_admin'), '', 'admin_do', 'seo_event_save', jsonb_build_object('name', 'Example Fest', 'category', 'festival', 'venue', 'Example Park',
  'lat', 43.65, 'lng', -79.38, 'usual_months', 'July', 'summary', 'An example festival held each summer in the park.', 'source_name', 'Example', 'source_url', 'https://example.test/fest')) ->> 'slug') = 'example-fest');
select test.ok('events: sales sets the announced dates', (app.door(test.id('rs_sales'), '', 'ops_do', 'seo_event_save', jsonb_build_object('slug', 'example-fest', 'starts_on', '2027-07-10', 'ends_on', '2027-07-12')) ->> 'starts_on') = '2027-07-10');
select test.throws('events: not customer service', $$select app.door(test.id('rs_cs'), '', 'ops_do', 'seo_event_save', '{"slug": "example-fest", "usual_months": "June"}')$$, '%Admin or sales%');
select test.throws('events: an end before the start is refused', $$select app.seo_event_save(test.id('rs_admin'), '{"slug": "example-fest", "starts_on": "2027-07-10", "ends_on": "2027-07-01"}')$$, '%check%');
select test.throws('events: a source must be https', $$select app.seo_event_save(test.id('rs_admin'), '{"name": "Bad Source Fest", "category": "festival", "venue": "X", "lat": 43, "lng": -79, "usual_months": "May", "summary": "A festival with an insecure source page.", "source_name": "X", "source_url": "http://x"}')$$, '%check%');
select test.ok('events: a change queues the page for IndexNow', exists (select 1 from indexnow_queue where path = '/events/example-fest'));
select app.seo_event_save(test.id('rs_admin'), '{"slug": "example-fest", "is_active": false}');
select test.ok('events: a page switched off is not read', public.seo_event('example-fest') is null and public.seo_event('tiff') is not null);

-- ================================================================ 6. Turo problems, 7. tracker, 10. airports, 11. renting vs owning
select test.ok('Turo pages: five landing pages, each saying CarmaCars is not affiliated with Turo',
  (select count(*) = 5 and bool_and(copy ->> 'intro' ~ 'not affiliated with, approved or endorsed by Turo') from seo_pages where slug like 'turo-%'));
select test.ok('tracker: on by default, from Program settings', (public.tracker_product() ->> 'name') is not null and jsonb_array_length(public.tracker_product() -> 'features') >= 1);
update program_settings set tracker_product_enabled = false;
select test.ok('tracker: off hides it', public.tracker_product() is null);
update program_settings set tracker_product_enabled = true;
select test.ok('airports: the active airports, each with the standard delivery price of the cars', (select count(*) >= 1 from jsonb_array_elements(public.airport_pages())));
select test.ok('renting vs owning: the inputs come from settings and sourced rows', (select (x ->> 'apr_bps')::integer = 799 and jsonb_array_length(x -> 'costs') >= 1 from public.rent_vs_own_inputs('Cadillac', 'CTS', 2015) x));
select test.throws('renting vs owning: a sourced cost needs its https source', $$select app.server_ownership_load('{"rows": [{"component": "parking", "scope": "toronto", "monthly_cents": 20000, "source": "x", "source_url": "http://x"}]}')$$, '%source_url%');
select test.ok('delivery to a point: the distance from us and the reach', (public.delivery_to_point(43.65, -79.38) ? 'km'));

-- ================================================================ 2. languages, 9. sitemaps
select test.eq('languages: the GTA''s 18 most spoken after English', (select count(*) from seo_languages where is_active), 18::bigint);
select app.server_i18n_load('{"sources": [{"key": "rs.one", "text": "Hello {brand}"}, {"key": "rs.two", "text": "From {price} a day"}]}');
select test.ok('languages: none ready before its strings are translated', not exists (select 1 from jsonb_array_elements(public.seo_languages_state()) x where (x ->> 'ready')::boolean));
select app.server_i18n_load(jsonb_build_object('strings', jsonb_build_array(
  jsonb_build_object('lang', 'fr', 'key', 'rs.one', 'text', 'Bonjour {brand}', 'source_hash', md5('Hello {brand}')),
  jsonb_build_object('lang', 'fr', 'key', 'rs.two', 'text', 'À partir de {price} par jour', 'source_hash', md5('From {price} a day'), 'status', 'reviewed'))));
select test.ok('languages: French ready once its strings are translated', exists (select 1 from jsonb_array_elements(public.seo_languages_state()) x where x ->> 'code' = 'fr' and (x ->> 'ready')::boolean));
select test.ok('languages: the bundle has the current strings', (public.seo_i18n_bundle('fr') -> 'strings' ->> 'rs.one') = 'Bonjour {brand}');
select app.server_i18n_load(jsonb_build_object('strings', jsonb_build_array(jsonb_build_object('lang', 'fr', 'key', 'rs.two', 'text', 'Machine', 'source_hash', md5('From {price} a day')))));
select test.eq('languages: a reviewed string is never replaced by a machine one', (select text from seo_strings where lang = 'fr' and key = 'rs.two'), 'À partir de {price} par jour');
select app.server_i18n_load('{"sources": [{"key": "rs.one", "text": "Hello again {brand}"}, {"key": "rs.two", "text": "From {price} a day"}]}');
select test.ok('languages: a changed English string makes its translation stale (not ready, not in the bundle)',
  (public.seo_i18n_bundle('fr') -> 'strings' -> 'rs.one') is null and not exists (select 1 from jsonb_array_elements(public.seo_languages_state()) x where x ->> 'code' = 'fr' and (x ->> 'ready')::boolean));
select test.ok('languages: the missing list names what to translate', (select jsonb_array_length(app.server_i18n_load('{"missing": true}') -> 'missing') > 0));
select test.ok('sitemaps: the families file lists the events, airports and hubs',
  (select bool_or(x ->> 'path' = '/events/tiff') and bool_or(x ->> 'path' like '/airport-car-rental/%') and bool_or(x ->> 'path' = '/events') from jsonb_array_elements(public.sitemap_families()) x));
select test.eq('sitemaps: no language version is listed while none is ready', jsonb_array_length(public.sitemap_languages() -> 'languages'), 0);
update program_settings set seo_i18n_min_coverage_bps = 5000;
select test.ok('sitemaps: a ready language is listed (the coverage is a setting)', exists (select 1 from jsonb_array_elements(public.sitemap_languages() -> 'languages') x where x ->> 'code' = 'fr'));
update program_settings set seo_i18n_min_coverage_bps = 9000;
delete from seo_string_sources where key like 'rs.%';
