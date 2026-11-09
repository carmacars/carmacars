-- 99: the Live map's speed (migration 1080, docs/changes/2026-11-08-r35-live-map-speed-stripe-link.md). On a database
-- seeded like a busy site (20,000 visits, 200,000 visit events, 3,000 renters, 3,000 leads and contact captures, 5,000
-- games) the whole read stays within its budget, its lookups use their indexes, the map's functions run without the JIT
-- compiler, each layer reads alone, a layer that fails is named while the others are drawn, and the roles read in one
-- statement (app.person_tags_many) answer as app.person_tags does. Fixtures start with "lms"; every address is example.test.
-- The seeded rows are removed at the end.
select test.suite('99 r35l live map speed');
select test.mk_user('lms_admin', 'admin');

-- ================================================================ the seed
insert into renters (id, legal_name, date_of_birth, mobile, email, identity_status, city)
select md5('lms-renter:' || i)::uuid, 'Lms Renter ' || i, date '1990-05-05', '416' || lpad((5550000 + i)::text, 7, '0'), 'lms.renter' || i || '@example.test', 'verified',
       (array['Toronto', 'Mississauga', 'Brampton', 'Oakville'])[1 + i % 4]
  from generate_series(1, 3000) i;
insert into visitor_sessions (id, visitor_id, renter_id, consent, city, started_at, last_seen_at, page_views, geo_lat, geo_lng, device, current_path, score, ended_at)
select md5('lms-sid:' || i)::uuid, md5('lms-vid:' || (i % 8000))::uuid, case when i % 5 = 0 then md5('lms-renter:' || (1 + i % 3000))::uuid end, 'analytics',
       (array['Toronto', 'Mississauga', 'Brampton', 'Oakville'])[1 + i % 4],
       now() - make_interval(mins => (i * 4) % 86400) - interval '10 minutes', now() - make_interval(mins => (i * 4) % 86400),
       1 + i % 12, case when i % 4 <> 0 then 43.4 + (i % 70) / 100.0 end, case when i % 4 <> 0 then -79.9 + (i % 90) / 100.0 end,
       (array['phone', 'desktop', 'tablet'])[1 + i % 3], '/cars', i % 100, case when i > 20 then now() - make_interval(mins => (i * 4) % 86400) end
  from generate_series(1, 20000) i;
insert into visitor_events (session_id, at, kind, path)
select md5('lms-sid:' || (1 + i % 20000))::uuid, now() - make_interval(mins => ((1 + i % 20000) * 4) % 86400) - make_interval(secs => i % 500),
       (array['page_view', 'car_view', 'search', 'page_leave'])[1 + i % 4], '/cars'
  from generate_series(1, 200000) i;
insert into leads (id, kind, name, email, created_at)
select md5('lms-lead:' || i)::uuid, 'contact', 'Lms Lead ' || i, 'lms.lead' || i || '@example.test', now() - make_interval(hours => i % 1400) from generate_series(1, 3000) i;
insert into contact_captures (visitor_id, form, ref, name, email, lead_id, last_at, done_at)
select md5('lms-vid:' || (i % 8000))::uuid, (array['contact', 'booking_request', 'owner_lead'])[1 + i % 3], 'lms' || i, 'Lms Capture ' || i, 'lms.capture' || i || '@example.test',
       case when i <= 3000 then md5('lms-lead:' || i)::uuid end, now() - make_interval(hours => i % 1400), case when i <= 3000 then now() end
  from generate_series(1, 6000) i;
insert into game_plays (visitor_id, game, prize, created_at)
select md5('lms-vid:' || (i % 8000))::uuid, (app.game_kinds())[1], '{"label": "10% off"}'::jsonb, now() - make_interval(hours => i % 1400) from generate_series(1, 5000) i;
analyze renters; analyze visitor_sessions; analyze visitor_events; analyze leads; analyze contact_captures; analyze game_plays;

-- ================================================================ 1. within the budget
create or replace function test.lms_ms(p jsonb) returns numeric language plpgsql as $$
declare t timestamptz := clock_timestamp(); v jsonb;
begin
  v := app.live_map(test.id('lms_admin'), p);
  if v is null then return -1; end if;
  return round(extract(epoch from clock_timestamp() - t) * 1000);
end $$;
select test.lms_ms('{}');   -- the first call plans the functions
-- the target is half a second on a developer's machine (about 0.3 s with photos on the cars); the budget leaves room for a slow CI runner
select test.ok('1080: the whole map reads within 2 seconds on a busy site (it took 47 before)', test.lms_ms('{}') between 0 and 2000, format('%s ms', test.lms_ms('{}')));
select test.ok('1080: the pins layer alone within 2 seconds', test.lms_ms('{"part": "pins"}') between 0 and 2000);
select test.ok('1080: the KPI tiles and the fleet layer alone within 200 ms', test.lms_ms('{"part": "kpi"}') between 0 and 200 and test.lms_ms('{"part": "fleet"}') between 0 and 200,
  format('kpi %s ms, fleet %s ms', test.lms_ms('{"part": "kpi"}'), test.lms_ms('{"part": "fleet"}')));
select test.eq('1080: the read still keeps at most 500 pins', jsonb_array_length(app.live_map(test.id('lms_admin'), '{}') -> 'pins') <= 500, true);

-- ================================================================ 2. the lookups use their indexes
create or replace function test.lms_plan(p_sql text, p_seqscan boolean default true) returns text language plpgsql as $$
declare v text;
begin
  if not p_seqscan then set local enable_seqscan = off; end if;
  execute 'explain (format json) ' || p_sql into v;
  if not p_seqscan then set local enable_seqscan = on; end if;
  return v;
end $$;
select test.ok('1080: a lead''s capture by its index',
  test.lms_plan(format('select x.visitor_id from contact_captures x where x.lead_id = %L order by x.last_at desc limit 1', md5('lms-lead:7')::uuid)) like '%contact_captures_lead_idx%');
select test.ok('1080: a renter''s latest visit by its index',
  test.lms_plan(format('select s.last_seen_at from visitor_sessions s where s.renter_id = %L order by s.last_seen_at desc limit 1', md5('lms-renter:5')::uuid)) like '%visitor_sessions_renter_seen_idx%');
select test.ok('1080: a person by a lowered email and by a phone, by their indexes',
  test.lms_plan($$select id from renters where lower(btrim(coalesce(email, ''))) = any (array['lms.renter9@example.test'])$$) like '%renters_email_key_idx%'
  and test.lms_plan($$select id from renters where app.phone_e164(mobile) = any (array['+14165550009'])$$) like '%renters_phone_key_idx%'
  and test.lms_plan($$select id from owners where app.phone_e164(phone) = any (array['+14165550009'])$$, false) like '%owners_phone_key_idx%'
  and test.lms_plan($$select id from owners where lower(btrim(coalesce(email, ''))) = any (array['x@example.test'])$$, false) like '%owners_email_key_idx%');
select test.ok('1080: the KPI tiles'' counts by their indexes',
  test.lms_plan($$select count(*) from bookings b where b.booked_at >= now() - interval '1 day'$$, false) like '%bookings_booked_at_idx%'
  and test.lms_plan($$select count(*) from bookings b where b.confirmed_at >= now() - interval '1 day'$$, false) like '%bookings_confirmed_at_idx%'
  and test.lms_plan($$select sum(amount_cents) from payments x where x.status = 'succeeded' and x.processed_at >= now() - interval '1 day'$$, false) like '%payments_processed_ok_idx%');
select test.eq('1080: the map''s functions run without the JIT compiler',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('live_map', 'live_map_pre0470', 'live_map_pre0400', 'live_map_pre0283', 'staff_live_map', 'person_tags', 'person_tags_many', 'live_visitors')
      and 'jit=off' = any (coalesce(p.proconfig, '{}'))), 8::bigint);

-- ================================================================ 3. a layer at a time; a failed layer is named, the others drawn
select test.eq('1080: one layer: the KPI tiles alone',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(app.live_map(test.id('lms_admin'), '{"part": "kpi"}')) k where k in ('kpi', 'pins', 'fleet', 'totals')), 'kpi');
select test.eq('1080: one layer: the pins (and their totals) alone',
  (select string_agg(k, ',' order by k) from jsonb_object_keys(app.live_map(test.id('lms_admin'), '{"part": "pins"}')) k where k in ('kpi', 'pins', 'fleet', 'totals')), 'pins,totals');
select test.eq('1080: the whole map names no failed layer', app.live_map(test.id('lms_admin'), '{}') -> 'failed', '[]'::jsonb);
select test.throws('1080: a layer that does not exist is refused', $$select app.live_map(test.id('lms_admin'), '{"part": "cars"}')$$, 'kpi, pins or fleet');
select test.mk_renter('lms_rita');
select test.throws('1080: still Admins only', $$select app.live_map(test.id('lms_rita'), '{"part": "kpi"}')$$, 'Only an Admin');
-- the fleet layer fails (its view is missing for a moment): the pins and the tiles are still there
alter view app.vehicle_positions rename to vehicle_positions_lms;
select set_config('test.lms_map', app.live_map(test.id('lms_admin'), '{}')::text, false);
alter view app.vehicle_positions_lms rename to vehicle_positions;
select test.eq('1080: a failed layer is named; the others are drawn',
  format('%s %s %s %s', current_setting('test.lms_map')::jsonb -> 'failed', jsonb_array_length(current_setting('test.lms_map')::jsonb -> 'pins') > 0,
         current_setting('test.lms_map')::jsonb ? 'kpi', current_setting('test.lms_map')::jsonb ? 'fleet'), '["fleet"] t t f');
select test.eq('1080: the fleet layer is back once it can be read', app.live_map(test.id('lms_admin'), '{"part": "fleet"}') -> 'failed', '[]'::jsonb);

-- ================================================================ 4. the same answers as before
create temp table lms_people as
with x as (select jsonb_build_object('user', null, 'renter', id, 'email', email, 'phone', mobile) j from (select * from renters order by created_at desc, id limit 400) r
           union all select jsonb_build_object('user', null, 'renter', id, 'email', email, 'phone', mobile) from (select * from renters where email not like 'lms.renter%' order by id limit 300) r
           union all select jsonb_build_object('user', user_id, 'renter', null, 'email', email, 'phone', phone) from (select * from owners order by id limit 200) o
           union all select jsonb_build_object('user', user_id, 'renter', null, 'email', null, 'phone', null) from (select * from user_roles order by user_id limit 100) u
           union all select jsonb_build_object('user', null, 'renter', null, 'email', email, 'phone', phone) from (select * from investors order by id limit 50) iv
           union all select jsonb_build_object('user', null, 'renter', null, 'email', email, 'phone', phone) from (select * from partners order by id limit 50) pa
           union all select jsonb_build_object('user', null, 'renter', null, 'email', email, 'phone', null) from (select * from leads where kind = 'owner_program' limit 50) l
           union all select jsonb_build_object('user', null, 'renter', null, 'email', 'nobody.lp@example.test', 'phone', '(647) 555-0100'))
select row_number() over () as n, j from x;
create temp table lms_many as select app.person_tags_many((select jsonb_agg(j order by n) from lms_people)) as a;
select test.eq('1080: the roles of many people at once are those of app.person_tags, person by person',
  (select count(*) filter (where app.person_tags(nullif(j ->> 'user', '')::uuid, nullif(j ->> 'renter', '')::uuid, j ->> 'email', j ->> 'phone') is distinct from (select a -> (p.n - 1)::integer from lms_many))
     from lms_people p), 0::bigint);
select test.ok('1080: and some of them have roles (the check means something)',
  (select count(*) from jsonb_array_elements((select a from lms_many)) x where jsonb_array_length(x -> 'roles') > 0) > 100);
select test.eq('1080: a car''s studio cover is the first of its studio photos',
  (select count(*) from vehicles v where app.vehicle_studio_cover(v.id) is distinct from app.vehicle_studio_photos(v.id) -> 0), 0::bigint);
select test.eq('1080: a car''s map photo is as before (its cover, else its first sample photo)',
  (select count(*) from vehicles v
    where app.live_map_car_photo(v.id) is distinct from
          coalesce((select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text, 'sample', false)
                      from vehicle_photos ph where ph.vehicle_id = v.id and ph.is_cover and ph.is_public and ph.status = 'approved' and ph.replaced_at is null
                       and ph.processed_path is not null limit 1),
                   (app.vehicle_sample_photos(v.id) -> 0) || jsonb_build_object('sample', true))), 0::bigint);
select test.ok('1080: the new functions are the service role''s only',
  not has_function_privilege('authenticated', 'app.person_tags_many(jsonb)', 'execute') and not has_function_privilege('anon', 'app.live_map_car_photo(uuid)', 'execute')
  and has_function_privilege('service_role', 'app.person_tags_many(jsonb)', 'execute'));

-- ================================================================ the seed leaves
delete from game_plays where visitor_id in (select md5('lms-vid:' || i)::uuid from generate_series(0, 7999) i);
delete from contact_captures where ref like 'lms%' and email like 'lms.capture%@example.test';
delete from leads where id in (select md5('lms-lead:' || i)::uuid from generate_series(1, 3000) i);
delete from visitor_sessions where id in (select md5('lms-sid:' || i)::uuid from generate_series(1, 20000) i);
delete from renters where id in (select md5('lms-renter:' || i)::uuid from generate_series(1, 3000) i);
