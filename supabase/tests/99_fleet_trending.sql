-- 99: the fleet's Trending order (migration 0352). The score from views, photos looked through, prices seen, requests,
-- offers and bookings over the last days, with the premium boost; the hourly job writes it; the website's fleet read
-- follows it with the Hot badge on the first cars; an Admin's pin leads whatever the score; the search pages' read keeps
-- 0126's order. Fixtures start with "tr".
select test.suite('99 fleet trending');
select test.mk_user('tr_admin', 'admin');
select test.mk_user('tr_cs', 'va', 'cs');

create temp table tr_cars (label text, id uuid);
grant all on tr_cars to public;
insert into tr_cars select 'plain', (app.vehicle_add(test.id('tr_admin'), jsonb_build_object('supply_type', 'company', 'plate', 'TRA 001', 'year', 2021, 'make', 'Kia', 'model', 'Forte', 'class', 'economy', 'rates', jsonb_build_object('daily', 4100))) ->> 'vehicle_id')::uuid;
insert into tr_cars select 'busy', (app.vehicle_add(test.id('tr_admin'), jsonb_build_object('supply_type', 'company', 'plate', 'TRA 002', 'year', 2022, 'make', 'Toyota', 'model', 'Corolla', 'class', 'economy', 'rates', jsonb_build_object('daily', 4200))) ->> 'vehicle_id')::uuid;
insert into tr_cars select 'luxe', (app.vehicle_add(test.id('tr_admin'), jsonb_build_object('supply_type', 'company', 'plate', 'TRA 003', 'year', 2024, 'make', 'Mercedes-Benz', 'model', 'S-Class', 'class', 'luxury', 'rates', jsonb_build_object('daily', 29900))) ->> 'vehicle_id')::uuid;
create function test.tr(p text) returns uuid language sql stable as $$ select id from tr_cars where label = p $$;
-- on the site (cars added without photos wait as drafts; the fixture publishes them)
update vehicle_listings set status = 'published', first_published_at = coalesce(first_published_at, now()) where vehicle_id in (select id from tr_cars);
-- the plain car is the cheapest, so 0126's order puts it first; the busy one had 120 views and 3 requests this week
insert into vehicle_interest_daily (vehicle_id, day, views, viewers, requests, quotes)
values (test.tr('busy'), app.local_date(now()) - 1, 120, 80, 3, 10), (test.tr('busy'), app.local_date(now()) - 30, 5000, 3000, 0, 0);

select test.ok('the score: the busy car above the luxury car (signals), the luxury car above the plain one (the premium boost)',
  (select (select score from app.fleet_trending_scores() where vehicle_id = test.tr('busy')) > (select score from app.fleet_trending_scores() where vehicle_id = test.tr('luxe'))
      and (select score from app.fleet_trending_scores() where vehicle_id = test.tr('luxe')) > (select score from app.fleet_trending_scores() where vehicle_id = test.tr('plain'))));
select test.ok('the score: signals older than the 14 days do not count (the 5,000 views of a month ago)',
  (select score from app.fleet_trending_scores() where vehicle_id = test.tr('busy')) < 1000);
select test.ok('the job writes the scores, and again only what changed', app.job_fleet_trending() >= 3 and app.job_fleet_trending() = 0);

create function test.tr_order() returns text language sql stable as $$
  select string_agg(c.label, ',' order by (r ->> 'trend_rank')::integer) from app.public_fleet_trending('{}') r join tr_cars c on c.id = (r ->> 'vehicle_id')::uuid $$;
select test.eq('the website''s fleet: Trending first', test.tr_order(), 'busy,luxe,plain');
select test.eq('public.fleet is that order', (select string_agg(c.label, ',' order by o) from public.fleet('{}') with ordinality f(r, o) join tr_cars c on c.id = (f.r ->> 'vehicle_id')::uuid), 'busy,luxe,plain');
select test.ok('the search pages keep 0126''s order (the cheapest first): an hourly score never rewrites them',
  (select string_agg(c.label, ',' order by o) from app.public_fleet('{}') with ordinality f(r, o) join tr_cars c on c.id = (f.r ->> 'vehicle_id')::uuid) = 'plain,busy,luxe');
-- Hot: the first fleet_hot_count cars (other suites' cars may lead the whole fleet: the count is set to the busy car's place)
update program_settings set fleet_hot_count = least(12, (select (r ->> 'trend_rank')::integer from app.public_fleet_trending('{}') r where (r ->> 'vehicle_id')::uuid = test.tr('busy')));
select test.eq('Hot: the busy car, not the ones after it', (select string_agg(c.label, ',') from app.public_fleet_trending('{}') r join tr_cars c on c.id = (r ->> 'vehicle_id')::uuid where (r ->> 'hot')::boolean), 'busy');

-- an Admin pins the plain car to the top
select test.throws('pin: only an Admin', $$select app.door(test.id('tr_cs'), '', 'admin_do', 'fleet_pin', jsonb_build_object('vehicle_id', test.tr('plain'), 'rank', 1))$$, '%');
select app.door(test.id('tr_admin'), '', 'admin_do', 'fleet_pin', jsonb_build_object('vehicle_id', test.tr('plain'), 'rank', 1));
select test.eq('pinned: the plain car leads', test.tr_order(), 'plain,busy,luxe');
select test.ok('pinned: in the audit log', exists (select 1 from audit_log where action = 'fleet_pin' and entity_id = test.tr('plain')::text));
select app.door(test.id('tr_admin'), '', 'admin_do', 'fleet_pin', jsonb_build_object('vehicle_id', test.tr('plain'), 'rank', ''));
select test.eq('unpinned: back to Trending', test.tr_order(), 'busy,luxe,plain');

-- the weights are a setting: no premium boost, and the luxury car falls behind the plain one only by its signals
update program_settings set fleet_trending_weights = fleet_trending_weights || '{"premium": 0}';
select app.job_fleet_trending();
select test.ok('weights: without the premium boost the luxury car scores as the plain one',
  (select score from app.fleet_trend where vehicle_id = test.tr('luxe')) = (select score from app.fleet_trend where vehicle_id = test.tr('plain')));
