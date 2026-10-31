-- 99: the Live map (migration 0242). One read for Admins (admin_read live_map): a pin per person with its type (the most
-- advanced wins, the others listed), where it is (the visit's rounded position, else the renter's home city, else the
-- visit's city, else nowhere), the car looked at last with its photo and price, the KPI tiles, and the fleet layer's
-- seam (empty until trackers report). The beacon records the visit's position rounded to 0.01 degree. Fixtures start
-- with "lm"; every address is example.test.
select test.suite('99 live map');

select test.mk_user('lm_admin', 'admin');
select test.mk_user('lm_cs', 'va', 'cs');
select test.mk_owner('lm_owner');
select test.mk_vehicle('lm_car1', 'lm_owner');
select test.mk_vehicle('lm_car2', 'lm_owner');
select test.mk_renter('lm_rita');
select test.mk_renter('lm_omar');
select test.mk_renter('lm_paula');
select test.mk_renter('lm_quinn');
update renters set city = 'Lmtown' where id = test.id('renter:lm_quinn');
-- a city of the places table (0095), as the places workflow loads them
insert into places (kind, flags, lat, lng, slug, name, country) values (5, 32, 43.9, -79.1, 'lmtown-on', 'Lmtown', 'CA');

create or replace function test.lmt(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:00') $$;
-- rita is on rent; omar has a confirmed booking ahead; paula has a request; quinn rented before
select test.mk_booking('LM-1', 'lm_car1', 'lm_rita', test.lmt('-2 days'), test.lmt('3 days'), 'on_rent');
select test.mk_booking('LM-2', 'lm_car2', 'lm_omar', test.lmt('5 days'), test.lmt('8 days'), 'confirmed');
update bookings set confirmed_at = now() - interval '1 hour' where id = test.id('booking:LM-2');
select test.mk_booking('LM-3', 'lm_car2', 'lm_paula', test.lmt('12 days'), test.lmt('14 days'), 'requested');
update bookings set booked_at = now() where id = test.id('booking:LM-3');
select test.mk_booking('LM-4', 'lm_car1', 'lm_quinn', test.lmt('-20 days'), test.lmt('-17 days'), 'closed');

-- ================================================================ 1. the beacon records the visit's position, rounded
create or replace function test.lmsid(p text) returns uuid language sql immutable as $$ select md5('lm-sid:' || p)::uuid $$;
create or replace function test.lmvid(p text) returns uuid language sql immutable as $$ select md5('lm-vid:' || p)::uuid $$;
select public.track_ingest(jsonb_build_object('sid', test.lmsid('anon'), 'vid', test.lmvid('anon'), 'consent', 'analytics', 'device', 'desktop',
  'events', '[{"k": "page_view", "path": "/cars/lm"}]'::jsonb),
  '{"city": "Mississauga", "region": "ON", "country": "CA", "lat": "43.58904", "lon": "-79.64412"}'::jsonb);
-- the car it viewed (as the car page's beacon records it)
update visitor_sessions set cars_viewed = array[test.id('vehicle:lm_car2'), test.id('vehicle:lm_car1')] where id = test.lmsid('anon');
select test.eq('the beacon: the visit''s position is kept rounded to 0.01 degree (about 1 km)',
  (select geo_lat || ' ' || geo_lng from visitor_sessions where id = test.lmsid('anon')), '43.59 -79.64');
select public.track_ingest(jsonb_build_object('sid', test.lmsid('junk'), 'vid', test.lmvid('junk'), 'consent', 'analytics', 'events', '[{"k": "page_view", "path": "/"}]'::jsonb),
  '{"city": "Toronto", "lat": "not a number", "lon": "999"}'::jsonb);
select test.eq('the beacon: a position that is not a number in range is left empty',
  (select coalesce(geo_lat::text, '-') || ' ' || coalesce(geo_lng::text, '-') from visitor_sessions where id = test.lmsid('junk')), '- -');
select test.eq('app.geo_round: rounds, refuses junk and out of range',
  format('%s %s %s', app.geo_round('-79.3871', 180), coalesce(app.geo_round('91', 90)::text, 'null'), coalesce(app.geo_round('1e5', 180)::text, 'null')), '-79.39 null null');

-- rita is on the site now too (her session, with a position); quinn came back to the site (no position, home city known).
-- Every fixture is from now(), so it is among the newest even when the earlier suites left more than the 500 pins kept.
insert into visitor_sessions (id, visitor_id, renter_id, consent, city, last_seen_at, started_at, page_views, geo_lat, geo_lng, score, score_reasons)
values (test.lmsid('rita'), test.lmvid('rita'), test.id('renter:lm_rita'), 'analytics', 'Toronto', now(), now() - interval '10 minutes', 6, 43.65, -79.38,
        40, '[{"kind": "pickup_soon", "label": "Pickup soon", "why": "Pickup tomorrow", "weight": 25}]'),
       (test.lmsid('quinn'), test.lmvid('quinn'), test.id('renter:lm_quinn'), 'analytics', 'Nowhere Lm', now() - interval '6 days', now(), 3, null, null, null, '[]');
update visitor_sessions set ended_at = now() where id = test.lmsid('quinn');

-- a form sent from a browser with a position; contact typed into the request form and not sent (no position anywhere)
insert into leads (id, kind, name, email, created_at) values (test.id('lead:lm'), 'contact', 'Lena Lead', 'lm.lena@example.test', now());
insert into visitor_sessions (id, visitor_id, consent, city, last_seen_at, started_at, geo_lat, geo_lng, ended_at)
values (test.lmsid('lena'), test.lmvid('lena'), 'analytics', 'Oakville', now(), now() - interval '3 hours', 43.45, -79.68, now());
insert into contact_captures (visitor_id, form, ref, name, email, lead_id, done_at, done_reason)
values (test.lmvid('lena'), 'contact', 'lm-lead', 'Lena Lead', 'lm.lena@example.test', test.id('lead:lm'), now() - interval '3 hours', 'sent');
insert into contact_captures (visitor_id, form, ref, name, email, phone)
values (test.lmvid('dora'), 'booking_request', 'lm-draft', 'Dora Draft', 'lm.dora@example.test', '4165550142');
-- a game played and claimed by the anonymous visitor of section 1
insert into game_plays (visitor_id, session_id, game, prize, created_at) values (test.lmvid('anon'), test.lmsid('anon'), 'wheel', '{"key": "pct10", "percent_bps": 1000}', now());

-- ================================================================ 2. the read: Admins only
select test.throws('the map is for Admins: customer service is refused',
  format('select app.door(%L, %L, %L, %L)', test.id('lm_cs'), 'aal2', 'admin_read', 'live_map'));
select test.throws('the map is for Admins: a renter is refused',
  format('select app.door(%L, %L, %L, %L)', test.id('lm_rita'), 'aal2', 'admin_read', 'live_map'));
create temp table s99lm as select app.door(test.id('lm_admin'), 'aal2', 'admin_read', 'live_map') as v;
create or replace function test.lm() returns jsonb language sql stable as $$ select v from pg_temp.s99lm $$;
create or replace function test.lmpin(p_where text, p_val text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(test.lm() -> 'pins') x where x ->> p_where = p_val limit 1 $$;

select test.ok('the door still answers the other reads (live_visitors)', app.door(test.id('lm_admin'), 'aal2', 'admin_read', 'live_visitors') ? 'now');
select test.eq('one pin per person: rita (on rent and on the site) is one pin', (select count(*) from jsonb_array_elements(test.lm() -> 'pins') x where x ->> 'renter_id' = test.id('renter:lm_rita')::text), 1::bigint);

-- ================================================================ 3. types, positions, people
select test.eq('on rent: the most advanced type wins, the session is listed, online, at the visit''s position',
  (select format('%s %s %s %s,%s %s', p ->> 'type', p -> 'types' ? 'session', p ->> 'online', p ->> 'lat', p ->> 'lng', p ->> 'precision') from (select test.lmpin('renter_id', test.id('renter:lm_rita')::text) p) x),
  'on_rent t true 43.65,-79.38 visit');
select test.eq('on rent: the booking, the car rented (with its price) and the Live visitors score and reasons',
  (select format('%s %s %s %s %s', p ->> 'booking_number', p #>> '{car,how}', p #>> '{car,daily_cents}', p #>> '{facts,live_score}', p #>> '{facts,reasons,0,label}')
     from (select test.lmpin('renter_id', test.id('renter:lm_rita')::text) p) x),
  'LM-1 on_rent 10000 40 Pickup soon');
select test.eq('on rent: the renter''s name, email and phone (masking is the website''s job)',
  (select format('%s %s %s', p ->> 'name', p ->> 'email', p ->> 'phone') from (select test.lmpin('renter_id', test.id('renter:lm_rita')::text) p) x),
  'Lm Rita lm_rita@example.test 647-555-0199');
select test.eq('booking: confirmed and ahead; no visit, no home city: not on the map',
  (select format('%s %s %s', p ->> 'type', p ->> 'booking_number', coalesce(p ->> 'lat', 'none')) from (select test.lmpin('renter_id', test.id('renter:lm_omar')::text) p) x),
  'booking LM-2 none');
select test.eq('request: requested in the last 30 days', (select test.lmpin('renter_id', test.id('renter:lm_paula')::text) ->> 'type'), 'request');
select test.eq('previous renter: placed at the centre of the home city (places), not the visit''s unknown city',
  (select format('%s %s %s,%s %s', p ->> 'type', p ->> 'precision', p ->> 'lat', p ->> 'lng', p #>> '{facts,past}') from (select test.lmpin('renter_id', test.id('renter:lm_quinn')::text) p) x),
  'previous home_city 43.9,-79.1 1');
select test.eq('form sent: the enquiry, placed through the browser''s visit',
  (select format('%s %s %s %s %s', p ->> 'type', p ->> 'name', p ->> 'detail', p ->> 'precision', p ->> 'city') from (select test.lmpin('name', 'Lena Lead') p) x),
  'lead Lena Lead Contact form visit Oakville');
select test.eq('unfinished form: the request form, with the phone typed; nowhere to place it',
  (select format('%s %s %s %s', p ->> 'type', p ->> 'detail', p ->> 'phone', coalesce(p ->> 'precision', 'none')) from (select test.lmpin('name', 'Dora Draft') p) x),
  'draft Started the booking request 4165550142 none');
select test.eq('game: played by the anonymous visitor on the site now; the car viewed last, its photo (sample when none)',
  (select format('%s %s %s %s %s %s', p ->> 'type', p ->> 'online', p #>> '{facts,game}', p #>> '{car,how}', p #>> '{car,id}' = test.id('vehicle:lm_car1')::text, (p #> '{car,photo}') is not null)
     from (select x from jsonb_array_elements(test.lm() -> 'pins') x where x ->> 'session_id' = test.lmsid('anon')::text) y(p)),
  'game true true viewed t t');
select test.eq('the visitor on the site with a junk position: a session pin, no position, the city kept',
  (select format('%s %s %s', p ->> 'type', coalesce(p ->> 'lat', 'none'), p ->> 'city') from (select x from jsonb_array_elements(test.lm() -> 'pins') x where x ->> 'session_id' = test.lmsid('junk')::text) y(p)),
  'session none Toronto');
select test.ok('totals per type count every person (before the cap): at least the fixtures of each kind',
  (select bool_and(coalesce((test.lm() -> 'totals' ->> k)::integer, 0) >= 1) from unnest(array['on_rent', 'booking', 'request', 'previous', 'lead', 'draft', 'game', 'session']) k));
select test.eq('the cap: limit 2 keeps the current ones first (on rent or booked)',
  (select count(*) from jsonb_array_elements(app.live_map(test.id('lm_admin'), '{"limit": 2}') -> 'pins') x where x ->> 'type' in ('on_rent', 'booking')), 2::bigint);

-- ================================================================ 4. the tiles and the fleet layer
select test.eq('KPI: on the site now, requests today, bookings confirmed this week, on rent now',
  (select format('%s %s %s %s', k ->> 'active_now', k ->> 'requests_today', k ->> 'bookings_week', k ->> 'on_rent_now') from (select test.lm() -> 'kpi' k) x),
  format('%s %s %s %s', (select count(*) from visitor_sessions where last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and ended_at is null and exclude_reason is null),
         (select count(*) from bookings where booked_at >= app.local_midnight(app.local_date(now())) and booking_type <> 'owner'),
         (select count(*) from bookings where confirmed_at >= app.local_midnight(date_trunc('week', app.local_date(now()))::date) and booking_type <> 'owner'),
         (select count(*) from bookings where status = 'on_rent' and booking_type <> 'owner')));
select test.ok('KPI: money collected this month is a number', jsonb_typeof(test.lm() #> '{kpi,collected_month_cents}') = 'number');
select test.eq('the fleet layer: a car without a tracker reporting is not on it', (select count(*) from jsonb_array_elements(test.lm() -> 'fleet') f where f ->> 'vehicle_id' = test.id('vehicle:lm_car1')::text), 0::bigint);
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at) values (test.id('trk:lm'), 'LM-TRK-1', test.id('vehicle:lm_car1'), 'installed', now());
insert into tracker_status (tracker_device_id, reported_at, latitude, longitude, speed_kmh, heading_deg) values (test.id('trk:lm'), now(), 43.70, -79.40, 52, 90);
select test.eq('a tracker that reports puts the car on the fleet layer: position, heading, speed, on rent, a photo',
  (select format('%s,%s %s %s %s %s', f ->> 'lat', f ->> 'lng', f ->> 'heading', f ->> 'speed', f ->> 'status', (f -> 'photo') is not null)
     from jsonb_array_elements(app.live_map(test.id('lm_admin')) -> 'fleet') f where f ->> 'vehicle_id' = test.id('vehicle:lm_car1')::text),
  '43.7,-79.4 90 52 on_rent t');
update tracker_status set reported_at = now() - interval '8 days' where tracker_device_id = test.id('trk:lm');
select test.eq('a position older than 7 days is left out', (select count(*) from app.vehicle_positions where vehicle_id = test.id('vehicle:lm_car1')), 0::bigint);
select test.ok('privileges: only the server runs app.live_map and reads app.vehicle_positions',
  not has_function_privilege('anon', 'app.live_map(uuid, jsonb)', 'execute') and not has_function_privilege('authenticated', 'app.live_map(uuid, jsonb)', 'execute')
  and not has_table_privilege('authenticated', 'app.vehicle_positions', 'select') and has_function_privilege('service_role', 'app.live_map(uuid, jsonb)', 'execute'));
