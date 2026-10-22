-- 72: the fixes of the live audit of October 22 (migration 0104). Site health with no HTTP status, IndexNow's back-off
-- and batch limits, one title and heading per partner car, the gearbox capitals, colours in proper case, sample cars
-- never featured, the address of a car waiting for its trim, the budget alarm, stale duplicate flags, and the import
-- caps of the database plan. Fixtures start with "a3".
select test.suite('72 audit 3 fixes');

-- ---------------------------------------------------------------- 1. site health
select test.lives('a page answer with no HTTP status is recorded', $$select app.uptime_page_result('home', null, null, null, false, 'Failure when receiving data from the peer', 3766, now())$$);
select test.ok('it is a failure, with pg_net''s reason',
  (select not ok and detail like 'No answer: Failure when receiving data from the peer%' from uptime_results where check_key = 'home' and at between now() - interval '5 minutes' and now() order by at desc limit 1));
select test.ok('a result with no "ok" at all is a failure', app.uptime_record('home', null, null, null, null, now()) is not null
  and (select not ok from uptime_results where check_key = 'home' and at between now() - interval '5 minutes' and now() order by at desc limit 1));
select test.ok('a good answer is still ok', app.uptime_page_result('home', 200, '{}', '<html></html>', false, null, 40, now()) in ('ok', 'recovered'));

-- the job with pg_net: a probe whose answer has no status, a probe never answered, a probe stuck for an hour
create schema if not exists net;
create table net._http_response (id bigint primary key, status_code integer, content_type text, headers jsonb, content text, timed_out boolean, error_msg text, created timestamptz not null default now());
create sequence net.a3_ids start 900000;
create function net.http_get(url text, params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds integer default 5000) returns bigint
language sql as $$ select nextval('net.a3_ids') $$;
delete from uptime_probes;
insert into uptime_probes (request_id, check_key, url, sent_at) values
  (18152, 'home', 'https://carmacars.ca/', now() - interval '2 minutes'),
  (18153, 'car_page', 'https://carmacars.ca/cars/x', now() - interval '5 minutes'),
  (18154, 'health', 'https://carmacars.ca/api/health', now() - interval '1 hour');
insert into net._http_response (id, status_code, timed_out, error_msg, created) values (18152, null, false, 'Failure when receiving data from the peer', now() - interval '1 minute');
select test.lives('the job runs with an answer that has no status', $$select app.job_uptime(now())$$);
select test.eq('every probe of the last round is collected (the answered, the unanswered, the stuck)',
  (select count(*) from uptime_probes where request_id in (18152, 18153, 18154)), 0::bigint);
select test.ok('the page with no status: a failed check with its reason',
  (select not ok and detail like 'No answer: Failure%' from uptime_results where check_key = 'home' and at between now() - interval '5 minutes' and now() order by at desc limit 1));
select test.ok('the page never answered: a failed check', (select not ok and detail = 'No answer within 3 minutes' from uptime_results where check_key = 'car_page' and at between now() - interval '5 minutes' and now() order by at desc limit 1));
insert into uptime_probes (request_id, check_key, url, sent_at) values (18155, 'home', 'https://carmacars.ca/', now() - interval '20 minutes');
delete from net._http_response;
select app.job_uptime(now());
select test.eq('a probe older than 15 minutes is dropped', (select count(*) from uptime_probes where request_id = 18155), 0::bigint);
delete from uptime_probes;
drop schema net cascade;

-- ---------------------------------------------------------------- 2. IndexNow
update program_settings set indexnow_enabled = true, indexnow_batch = 2 where id = (app.settings()).id;
update site_settings set indexnow_key = md5('a3') where indexnow_key is null;
delete from indexnow_queue;
update indexnow_sweep set backoff_until = null, backoff_s = 0, sent_today = 0;
insert into indexnow_queue (path, reason, queued_at) values ('/a3/one', 'a3', now() - interval '3 minutes'), ('/a3/two', 'a3', now() - interval '2 minutes'), ('/a3/three', 'a3', now() - interval '1 minute');
select test.eq('the batch size holds: 2 of 3 addresses', app.server_seo_claim('a3', 0) #> '{indexnow,paths}', '["/a3/one", "/a3/two"]'::jsonb);
select app.server_indexnow_sent('{"paths": ["/a3/one", "/a3/two"], "status": 429, "error": "TooManyRequests"}');
select test.eq('a 429 spends no attempt', (select string_agg(path || ':' || attempts || ':' || last_status, ' ' order by path) from indexnow_queue where path in ('/a3/one', '/a3/two')),
  '/a3/one:0:429 /a3/two:0:429');
select test.ok('a 429 pauses the whole queue until tomorrow (Toronto)',
  (select backoff_until > now() + interval '1 minute' and (backoff_until at time zone 'America/Toronto')::date = (now() at time zone 'America/Toronto')::date + 1 from indexnow_sweep));
select test.eq('while it waits nothing is claimed', app.server_seo_claim('a3', 0) #> '{indexnow,paths}', '[]'::jsonb);
select test.eq('while it waits the tick does not run the job for IndexNow alone',
  (select count(*) from indexnow_queue where sent_at is null) > 0 and not exists (select 1 from car_copy c where c.status in ('pending', 'failed') and c.next_attempt_at <= now())
    and not exists (select 1 from seo_pages p where p.is_active and p.status in ('pending', 'failed') and p.next_attempt_at <= now())
    and not exists (select 1 from articles a where a.status in ('pending', 'failed') and a.next_attempt_at <= now())
    and (app.server_jobs_due() ->> 'seo')::boolean, false);
select app.server_indexnow_report('{"status": 429, "count": 0, "retry_after": 120}');
select test.ok('a Retry-After is kept', (select backoff_until between now() + interval '100 seconds' and now() + interval '140 seconds' from indexnow_sweep));
update indexnow_sweep set backoff_until = null, backoff_s = 0;
select app.server_indexnow_sent('{"paths": ["/a3/one", "/a3/two"], "status": 200}');
select test.ok('a 2xx sends them and counts them', (select count(*) = 2 from indexnow_queue where sent_at is not null and path like '/a3/%')
  and (select sent_today >= 2 and backoff_until is null from indexnow_sweep));
select app.server_indexnow_sent('{"paths": ["/a3/three"], "status": 400, "error": "Bad request"}');
select test.eq('another failure still spends an attempt', (select attempts from indexnow_queue where path = '/a3/three'), 1);
update program_settings set indexnow_daily_max = (select sent_today from indexnow_sweep) where id = (app.settings()).id;
update indexnow_sweep set backoff_until = null;
select test.eq('the day''s ceiling holds', app.server_seo_claim('a3', 0) #> '{indexnow,paths}', '[]'::jsonb);
update program_settings set indexnow_daily_max = 2000000, indexnow_batch = 10000, indexnow_enabled = false where id = (app.settings()).id;
delete from indexnow_queue where path like '/a3/%';
update indexnow_sweep set backoff_until = null, backoff_s = 0, last_status = null, last_error = null;

-- ---------------------------------------------------------------- 3. partner cars: one title and heading each
select test.eq('partner cars: every search title is different',
  (select count(*) - count(distinct l.seo_title) from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.supply_type = 'partner' and l.status = 'published'), 0::bigint);
select test.eq('partner cars: every heading is different',
  (select count(*) - count(distinct l.headline) from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.supply_type = 'partner' and l.status = 'published'), 0::bigint);
select test.eq('partner cars: every page mark is different among cars of one model and trim',
  (select count(*) from (select lower(v.make), lower(v.model), lower(coalesce(v.trim, '')), app.listing_seo_mark(v.id) m, count(*) n
                           from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.supply_type = 'partner' and l.status = 'published'
                          group by 1, 2, 3, 4 having count(*) > 1) x), 0::bigint);
select test.eq('two C43 AMG of different colours: the colour', app.listing_seo_mark((select v.id from vehicles v where v.partner_sheet_name = 'Mercedes C43 AMG Grey')), 'grey');
select test.ok('a partner title names the trim and no unconfirmed year',
  (select l.seo_title = 'Rent a Mercedes-Benz C-Class C43 AMG in Toronto (grey)' and l.headline = 'Mercedes-Benz C-Class C43 AMG for rent in Toronto (grey)'
     from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.partner_sheet_name = 'Mercedes C43 AMG Grey'));
select test.ok('a partner car with no twin: its trim, no mark',
  (select l.seo_title like 'Rent a Mercedes-Benz C-Class C63 S AMG in Toronto%' and l.seo_title !~ '\(' from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.partner_sheet_name = 'Mercedes C63s AMG'));
select test.ok('every search title fits 60 characters', not exists (select 1 from vehicle_listings where length(seo_title) > 60));

-- same colour too: the car code, then a short word
select test.mk_owner('a3_own');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:A3T1'), test.id('owner:a3_own'), 2024, 'Kia', 'K5 A3', 'LX', 'BLACK', 'A3T1AA', 'standard', 'available', 'managed', 'transfer', 'Sedan'),
       (test.id('vehicle:A3T2'), test.id('owner:a3_own'), 2024, 'Kia', 'K5 A3', 'LX', 'Black', 'A3T2AA', 'standard', 'available', 'managed', 'transfer', 'Sedan');
select test.eq('a colour typed in capitals is stored in proper case', (select colour from vehicles where id = test.id('vehicle:A3T1')), 'Black');
update vehicles set colour = 'DARK GREY' where id = test.id('vehicle:A3T2');
select test.eq('and on an update', (select colour from vehicles where id = test.id('vehicle:A3T2')), 'Dark Grey');
update vehicles set colour = 'Black' where id = test.id('vehicle:A3T2');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, app.listing_slug(v.id), 'x', 'published', now(), 5, 'Automatic (CVT)', 'Sedan' from vehicles v where v.id = test.id('vehicle:A3T1');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
select v.id, app.listing_slug(v.id), 'x', 'published', now(), 5, 'Automatic (CVT)', 'Sedan' from vehicles v where v.id = test.id('vehicle:A3T2');
select test.eq('same year, model and colour: the car code', app.listing_seo_mark(test.id('vehicle:A3T1')), (select car_code from vehicles where id = test.id('vehicle:A3T1')));
select test.ok('each twin its own mark', app.listing_seo_mark(test.id('vehicle:A3T1')) <> app.listing_seo_mark(test.id('vehicle:A3T2')));

-- ---------------------------------------------------------------- 5. the gearbox keeps its capitals
select test.eq('gearbox words', app.gearbox_case('5 seats, automatic (cvt). An automatic (dual-clutch) transmission.'),
  '5 seats, Automatic (CVT). An Automatic (dual-clutch) transmission.');
-- the plain copy of a car with a CVT (0061 wrote lower(transmission)), put live
select app.car_copy_apply(test.id('vehicle:A3T1'), app.car_copy_template(app.car_copy_facts(test.id('vehicle:A3T1'))), 'template');
select test.ok('copy put live: the gearbox in capitals, in the search description',
  (select seo_description like '%Automatic (CVT)%' and seo_description !~ 'automatic \(cvt\)' from vehicle_listings where vehicle_id = test.id('vehicle:A3T1')));
select test.ok('copy put live: the twin''s mark in the title and heading',
  (select seo_title like '%(' || lower(app.listing_seo_mark(test.id('vehicle:A3T1'))) || ')' or seo_title like '%(' || app.listing_seo_mark(test.id('vehicle:A3T1')) || ')'
     from vehicle_listings where vehicle_id = test.id('vehicle:A3T1')));
select test.eq('no live description has a lower-case gearbox', (select count(*) from vehicle_listings where seo_description ~ 'automatic \((cvt|dual-clutch)\)'), 0::bigint);

-- ---------------------------------------------------------------- 4. sample cars are never featured
select test.eq('no sample car is featured', (select count(*) from vehicle_listings l join vehicles v on v.id = l.vehicle_id where v.is_sample and l.is_featured), 0::bigint);
update vehicle_listings set is_featured = true where vehicle_id = (select id from vehicles where is_sample limit 1);
select test.eq('featuring a sample car is refused quietly', (select count(*) from vehicle_listings l join vehicles v on v.id = l.vehicle_id where v.is_sample and l.is_featured), 0::bigint);
update vehicle_listings set is_featured = true where vehicle_id = test.id('vehicle:A3T2');
select test.ok('a real car can still be featured', (select is_featured from vehicle_listings where vehicle_id = test.id('vehicle:A3T2')));

-- ---------------------------------------------------------------- 6. a car waiting for its trim
select test.mk_user('a3_admin', 'admin');
insert into vehicles (id, owner_id, year, make, model, trim, vin, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:A3B'), test.id('owner:a3_own'), 2019, 'Volkswagen', 'Beetle A3', null, '3VW5DAAT0KM5A3001', 'A3B001', 'standard', 'available', 'managed', 'transfer', 'Convertible');
update vehicles set trim_candidates = array['S', 'Final Edition SE', 'SE'] where id = test.id('vehicle:A3B');
-- the address it had before 0104: the trim list in it
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, first_published_at, seats, transmission, body_style)
values (test.id('vehicle:A3B'), '2019-volkswagen-beetle-a3-s-final-edition-se-se', 'x', 'published', now(), now(), 4, 'Automatic', 'Convertible');
select test.eq('waiting for the trim: year, make and model', app.listing_move_to_clean_slug(test.id('vehicle:A3B')), '2019-volkswagen-beetle-a3');
select test.eq('the old address answers 301', (select format('%s %s', status_code, to_path) from listing_redirects where from_path = '/cars/2019-volkswagen-beetle-a3-s-final-edition-se-se'),
  '301 /cars/2019-volkswagen-beetle-a3');
select app.door(test.id('a3_admin'), '', 'ops_do', 'vehicle_pick_trim', jsonb_build_object('vehicle_id', test.id('vehicle:A3B'), 'trim', 'Final Edition SE'));
select test.eq('the trim picked: the address moves again', (select slug from vehicle_listings where vehicle_id = test.id('vehicle:A3B')), '2019-volkswagen-beetle-a3-final-edition-se');
select test.eq('both older addresses lead to it', (select string_agg(to_path, ' ' order by from_path) from listing_redirects where vehicle_id = test.id('vehicle:A3B')),
  '/cars/2019-volkswagen-beetle-a3-final-edition-se /cars/2019-volkswagen-beetle-a3-final-edition-se');

-- ---------------------------------------------------------------- 8. the budget alarm
select test.eq('Worker requests and CPU warn at 70%', (select string_agg(service || ' ' || warn_bps, ', ' order by service) from usage_services where service in ('workers_requests', 'workers_cpu')),
  'workers_cpu 7000, workers_requests 7000');

-- ---------------------------------------------------------------- 10. a duplicate flag that no longer holds
insert into listing_similarity_flags (vehicle_id, other_vehicle_id, kind, score_bps, blocking, detail, first_seen_at, last_seen_at)
values (test.id('vehicle:A3T1'), test.id('vehicle:A3B'), 'copy', 7000, true, 'The copy is 70% the same (a3)', now() - interval '1 day', now() - interval '1 day');
select app.raise_task(p_type => 'listing_similarity', p_title => 'Possible duplicate (a3)', p_detail => 'a3', p_vehicle => test.id('vehicle:A3T1'), p_dedupe => 'listing_similarity:' || test.id('vehicle:A3T1'));
select app.check_listing_similarity(test.id('vehicle:A3T1'), 'all');
select test.eq('the stale flag is removed by the check', (select count(*) from listing_similarity_flags where vehicle_id = test.id('vehicle:A3T1') and kind = 'copy'), 0::bigint);
select test.eq('its task closes by itself', (select count(*) from tasks where task_type = 'listing_similarity' and vehicle_id = test.id('vehicle:A3T1') and status in ('open', 'in_progress', 'waiting')), 0::bigint);
select test.ok('and the log says why', exists (select 1 from audit_log where action = 'similarity_gone' and after ->> 'detail' = 'The copy is 70% the same (a3)'));
update vehicles set colour = 'White', plate = 'A3T1AA' where id = test.id('vehicle:A3T2');
update vehicles set colour = 'White' where id = test.id('vehicle:A3T1');
select app.check_listing_similarity(test.id('vehicle:A3T1'), 'vehicle');
select test.eq('a flag that still holds stays', (select count(*) from listing_similarity_flags where vehicle_id = test.id('vehicle:A3T1') and kind = 'specs' and status = 'open'), 1::bigint);

-- ---------------------------------------------------------------- 11. the import caps follow the database plan
select test.eq('Pro by default: both caps 6,144 MB', (select format('%s %s %s', db_plan, vpage_import_db_cap_mb, place_db_cap_mb) from program_settings where id = (app.settings()).id), 'pro 6144 6144');
select test.eq('the database allowance on Pro: 8 GB', (select included from usage_services where service = 'supabase_db'), 8589934592::numeric);
update program_settings set db_plan = 'free' where id = (app.settings()).id;
select test.eq('Free: both caps 450 MB, the allowance 500 MB',
  (select format('%s %s', vpage_import_db_cap_mb, place_db_cap_mb) from program_settings where id = (app.settings()).id) || ' ' || (select included from usage_services where service = 'supabase_db'),
  '450 450 524288000');
update program_settings set place_db_cap_mb = 5000 where id = (app.settings()).id;
select test.eq('a cap is never above the plan''s', (select place_db_cap_mb from program_settings where id = (app.settings()).id), 450);
update program_settings set db_plan = 'pro' where id = (app.settings()).id;
select test.eq('back to Pro', (select format('%s %s', vpage_import_db_cap_mb, place_db_cap_mb) from program_settings where id = (app.settings()).id), '6144 6144');

-- ---------------------------------------------------------------- tidy
update vehicle_listings set status = 'unpublished', is_featured = false where vehicle_id in (test.id('vehicle:A3T1'), test.id('vehicle:A3T2'), test.id('vehicle:A3B'));
delete from listing_similarity_flags where vehicle_id in (test.id('vehicle:A3T1'), test.id('vehicle:A3T2'), test.id('vehicle:A3B'));
