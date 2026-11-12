-- 99: the SEO action loop and cached-only serving by usage (migration 1860). Fixtures start with "sg"; addresses are example.test.
select test.suite('99 r35 gaps3: SEO loop and cached-only by usage');

select test.mk_user('sgl_admin', 'admin');
select test.mk_user('sgl_sales', 'va', 'sales');
select test.mk_user('sgl_cs', 'va', 'cs');

-- ---------------------------------------------------------------- settings are Program settings
select test.eq('A the goal is 5,000,000 clicks a month by default', (select seo_click_goal from program_settings limit 1), 5000000::bigint);
select test.eq('A cached-only starts at 70% of the allowance', (select usage_cached_pct from program_settings limit 1), 70);
select test.throws('A a threshold of 0% is refused', $$update program_settings set usage_cached_pct = 0$$);
select test.throws('A a goal of 0 is refused', $$update program_settings set seo_click_goal = 0$$);

-- ---------------------------------------------------------------- per-query and per-page figures
select test.eq('B the stored rows are counted', app.gsc_pages_store(jsonb_build_object('window_end', app.today() - 3, 'rows', jsonb_build_array(
  jsonb_build_object('kind', 'query', 'key', 'rent a mercedes toronto', 'clicks', 80, 'impressions', 900, 'ctr', 0.0889, 'position', 4.2),
  jsonb_build_object('kind', 'query', 'key', 'car rental pearson', 'clicks', 30, 'impressions', 4000, 'ctr', 0.0075, 'position', 9.1),
  jsonb_build_object('kind', 'page', 'key', '/cars/mercedes-c300', 'clicks', 60, 'impressions', 700, 'ctr', 0.0857, 'position', 3.0),
  jsonb_build_object('kind', 'page', 'key', '/car-rental/mississauga', 'clicks', 3, 'impressions', 18400, 'ctr', 0.0002, 'position', 11.5),
  jsonb_build_object('kind', 'page', 'key', '/buy/toyota/camry', 'clicks', 40, 'impressions', 50, 'ctr', 0.8, 'position', 2.0)))), 5);
select test.eq('B a second run replaces that kind''s rows (the pages stay)', app.gsc_pages_store(jsonb_build_object('rows', jsonb_build_array(
  jsonb_build_object('kind', 'query', 'key', 'rent a mercedes toronto', 'clicks', 81, 'impressions', 910, 'ctr', 0.089, 'position', 4.1)))), 1);
select test.eq('B the old query is gone', (select count(*) from app.gsc_page_query where kind = 'query'), 1::bigint);
select app.gsc_pages_store(jsonb_build_object('rows', jsonb_build_array(
  jsonb_build_object('kind', 'query', 'key', 'rent a mercedes toronto', 'clicks', 81, 'impressions', 910, 'ctr', 0.089, 'position', 4.1),
  jsonb_build_object('kind', 'query', 'key', 'car rental pearson', 'clicks', 30, 'impressions', 4000, 'ctr', 0.0075, 'position', 9.1))));
-- only this test's days: an earlier suite (99_r35c_investor_search) stores days from current_date, which is UTC, so after 19:00
-- Toronto its newest day is later than these and moved the 28-day window (run 43123677220)
delete from app.gsc_search_daily;
insert into app.gsc_search_daily (day, clicks, impressions, ctr, position)
  select app.today() - 3 - g, 1000 + g, 50000, 0.02, 9 from generate_series(0, 27) g
  on conflict (day) do update set clicks = excluded.clicks, impressions = excluded.impressions;

-- ---------------------------------------------------------------- the page: Admin, read only for sales, nobody else
create or replace function test.sgseo(p_user text) returns jsonb language sql as $$ select app.seo_actions(test.id(p_user)) $$;
select test.eq('C an Admin reads the goal', (test.sgseo('sgl_admin') #>> '{goal,target}')::bigint, 5000000::bigint);
select test.eq('C the 28-day clicks add up', (test.sgseo('sgl_admin') #>> '{goal,clicks_28d}')::bigint, (select sum(clicks) from app.gsc_search_daily where day > app.today() - 31 and day <= app.today() - 3));
select test.eq('C the top query leads', test.sgseo('sgl_admin') #>> '{top_queries,0,key}', 'rent a mercedes toronto');
select test.eq('C the page shown a lot and clicked little is listed', test.sgseo('sgl_admin') #>> '{low_ctr,0,key}', '/car-rental/mississauga');
select test.eq('C a page with few impressions is not listed', (select count(*) from jsonb_array_elements(test.sgseo('sgl_admin') -> 'low_ctr') x where x ->> 'key' = '/buy/toyota/camry'), 0::bigint);
select test.eq('C an Admin''s page is not read only', (test.sgseo('sgl_admin') ->> 'read_only')::boolean, false);
select test.eq('C sales reads the same page, read only', (test.sgseo('sgl_sales') ->> 'read_only')::boolean, true);
select test.eq('C sales sees the same goal', test.sgseo('sgl_sales') #>> '{goal,target}', '5000000');
select test.throws('C customer service may not read it', $$select test.sgseo('sgl_cs')$$, 'Only an Admin or sales');
select test.throws('C nobody (no user) may read it', $$select app.seo_actions(null)$$, 'Only an Admin or sales');
select test.ok('C the public function is for the server only', not has_function_privilege('authenticated', 'public.server_seo_actions(uuid)', 'execute') and has_function_privilege('service_role', 'public.server_seo_actions(uuid)', 'execute'));
select test.eq('C a lower goal changes the share', (select (app.seo_data(now(), false) #>> '{goal,share_bps}')::int > 0), true);

-- ---------------------------------------------------------------- inspected pages by sitemap, and IndexNow with a backoff
update program_settings set indexnow_enabled = true;
select test.eq('D inspected pages are stored and the not indexed ones queued', app.gsc_urls_store(jsonb_build_array(
  jsonb_build_object('path', '/cars/sg-one', 'state', 'Crawled - currently not indexed', 'bucket', 'crawled', 'sitemap', 'sitemap-vehicles-1.xml'),
  jsonb_build_object('path', '/cars/sg-two', 'state', 'Discovered - currently not indexed', 'bucket', 'discovered', 'sitemap', 'sitemap-vehicles-1.xml'),
  jsonb_build_object('path', '/cars/sg-three', 'state', 'Submitted and indexed', 'bucket', 'indexed', 'sitemap', 'sitemap-vehicles-1.xml'),
  jsonb_build_object('path', '/places/9', 'state', 'URL is unknown to Google', 'bucket', 'unknown', 'sitemap', 'sitemap-places-1.xml'),
  jsonb_build_object('path', 'https://bad.example.test/x', 'state', 'x', 'bucket', 'indexed'))) ->> 'stored', '4');
select test.eq('D three addresses went to IndexNow', (select count(*) from indexnow_queue where path in ('/cars/sg-one', '/cars/sg-two', '/places/9') and reason = 'not indexed'), 3::bigint);
select test.eq('D the indexed one did not', (select count(*) from indexnow_queue where path = '/cars/sg-three'), 0::bigint);
update indexnow_queue set sent_at = now() where path = '/cars/sg-one';
select app.gsc_urls_store(jsonb_build_array(jsonb_build_object('path', '/cars/sg-one', 'state', 'Crawled - currently not indexed', 'bucket', 'crawled')));
select test.ok('D inspected again at once: not queued again (backoff)', (select sent_at is not null from indexnow_queue where path = '/cars/sg-one'));
update app.gsc_url_inspection set next_ping_at = now() - interval '1 minute' where path = '/cars/sg-one';
select app.gsc_urls_store(jsonb_build_array(jsonb_build_object('path', '/cars/sg-one', 'state', 'Crawled - currently not indexed', 'bucket', 'crawled')));
select test.ok('D after the backoff it is queued again', (select sent_at is null from indexnow_queue where path = '/cars/sg-one'));
select test.eq('D the wait doubles', (select pings from app.gsc_url_inspection where path = '/cars/sg-one'), 2);
select test.ok('D the next send is days away', (select next_ping_at > now() + interval '1 day' from app.gsc_url_inspection where path = '/cars/sg-one'));
select test.eq('D once indexed the schedule ends', (select (app.gsc_urls_store(jsonb_build_array(jsonb_build_object('path', '/cars/sg-one', 'state', 'Submitted and indexed', 'bucket', 'indexed'))) ->> 'stored')::int), 1);
select test.ok('D no more pings after indexing', (select pings = 0 and next_ping_at is null from app.gsc_url_inspection where path = '/cars/sg-one'));
select test.eq('D the sitemaps show the crawled and discovered counts', (select (x ->> 'crawled')::int + (x ->> 'discovered')::int from jsonb_array_elements(test.sgseo('sgl_admin') -> 'by_sitemap') x where x ->> 'sitemap' = 'sitemap-vehicles-1.xml'), 1);
update program_settings set indexnow_enabled = false;
select app.gsc_urls_store(jsonb_build_array(jsonb_build_object('path', '/cars/sg-four', 'state', 'Crawled - currently not indexed', 'bucket', 'crawled')));
select test.eq('D with IndexNow off nothing is queued', (select count(*) from indexnow_queue where path = '/cars/sg-four'), 0::bigint);

-- ---------------------------------------------------------------- the weekly digest, through the outbox, within the email budget
update program_settings set uptime_alert_email = 'owner@example.test', seo_digest_on = true;
create or replace function test.sgmon(p_hour int) returns timestamptz language sql stable as $$
  select ((date_trunc('week', app.today())::date + 7) + make_interval(hours => p_hour)) at time zone 'America/Toronto' $$;
select test.eq('E not before 07:00 Monday', app.seo_digest_enqueue(test.sgmon(6)), 0);
select test.eq('E not on a Tuesday', app.seo_digest_enqueue(test.sgmon(8) + interval '1 day'), 0);
select test.eq('E Monday morning queues one', app.seo_digest_enqueue(test.sgmon(8)), 1);
select test.eq('E it goes to the alert address at the lowest priority', (select to_address || ':' || priority from notification_outbox where code = 'staff_seo_digest'), 'owner@example.test:5');
select test.ok('E it carries the goal and the queries', (select payload ->> 'goal' = '5,000,000' and payload #>> '{top_queries,0,key}' = 'rent a mercedes toronto' and payload #>> '{low_ctr,0,key}' = '/car-rental/mississauga' from notification_outbox where code = 'staff_seo_digest'));
select test.eq('E only once a week', app.seo_digest_enqueue(test.sgmon(9)), 0);
select test.eq('E one email in the outbox', (select count(*) from notification_outbox where code = 'staff_seo_digest'), 1::bigint);
delete from notification_outbox where code = 'staff_seo_digest';
update program_settings set seo_digest_on = false;
select test.eq('E off in Program settings: nothing', app.seo_digest_enqueue(test.sgmon(8)), 0);
update program_settings set seo_digest_on = true;
update program_settings set notify_daily_cap = 1;
insert into notification_outbox (code, category, priority, audience, to_address, entity, payload, missing_variables, dedupe_key, status, sent_at, send_after)
  values ('staff_seo_digest', 'transactional', 1, 'staff_admin', 'x@example.test', 'seo_digest', '{}', '{}', 'sg-cap-1', 'sent', test.sgmon(7), test.sgmon(7));
select test.eq('E the day''s email limit used: nothing is queued', app.seo_digest_enqueue(test.sgmon(8)), 0);
update program_settings set notify_daily_cap = 200;
delete from notification_outbox where dedupe_key = 'sg-cap-1';
select test.eq('E with room again it is queued', app.seo_digest_enqueue(test.sgmon(8)), 1);
select test.ok('E the catalogue has the email', exists (select 1 from notification_catalogue where code = 'staff_seo_digest' and in_catalogue and audience = 'staff_admin'));

-- ---------------------------------------------------------------- cached-only by usage
-- earlier suites record Workers requests and may switch the mode: this section starts from none, at the 70% line, and
-- counts its own audit lines
delete from usage_readings where service in ('workers_requests', 'workers_cpu');
select app.job_usage_refresh();
update program_settings set usage_cached_pct = 70, usage_cached_since = null;
create temp table sg_audit0 as select (select count(*) from audit_log where action = 'usage_cached_on') n_on, (select count(*) from audit_log where action = 'usage_cached_off') n_off;
select test.eq('F nothing used: off', app.usage_cached_check(), false);
select app.usage_record_external(('{"source": "cloudflare", "days": [{"day": "' || app.today() || '", "values": {"workers_requests": 6900000}}]}')::jsonb);
select test.eq('F 69% of the requests: still off', app.usage_cached_check(), false);
select app.usage_record_external(('{"source": "cloudflare", "days": [{"day": "' || app.today() || '", "values": {"workers_requests": 7100000}}]}')::jsonb);
select test.eq('F 71% of the requests: on', app.usage_cached_check(), true);
select test.ok('F the start is kept', (select usage_cached_since is not null from program_settings limit 1));
select test.eq('F the Worker is told (the five-minute tick)', (app.server_jobs_due() ->> 'cached_only')::boolean, true);
select test.eq('F Settings > Usage shows it', (app.usage_page(test.id('sgl_admin')) #>> '{cached_only,on}')::boolean, true);
select test.eq('F and the line', (app.usage_page(test.id('sgl_admin')) #>> '{cached_only,line_pct}')::int, 70);
select test.eq('F and how far the month is', (app.usage_page(test.id('sgl_admin')) #>> '{cached_only,share_bps}')::int, 7100);
select test.eq('F switched on once in the audit log', (select count(*) - (select n_on from sg_audit0) from audit_log where action = 'usage_cached_on'), 1::bigint);
select app.usage_cached_check();
select test.eq('F checking again does not log again', (select count(*) - (select n_on from sg_audit0) from audit_log where action = 'usage_cached_on'), 1::bigint);
update program_settings set usage_cached_pct = 80;
select test.eq('F the line is a Program setting: at 80% it is off', app.usage_cached_check(), false);
select test.ok('F and the start is cleared', (select usage_cached_since is null from program_settings limit 1));
select test.eq('F switched off in the audit log', (select count(*) - (select n_off from sg_audit0) from audit_log where action = 'usage_cached_off'), 1::bigint);
update program_settings set usage_cached_pct = 70;
select test.eq('F back on at 70%', app.usage_cached_check(), true);
select test.eq('F on the 1st of the next month it is off again', app.usage_cached_check((date_trunc('month', now() at time zone 'America/Toronto') + interval '1 month' + interval '1 hour') at time zone 'America/Toronto'), false);
select test.eq('F CPU time counts too: 75% of it', (select app.usage_record_external(('{"source": "cloudflare", "days": [{"day": "' || app.today() || '", "values": {"workers_requests": 100, "workers_cpu": ' || (select (included * 0.75)::bigint from usage_services where service = 'workers_cpu') || '}}]}')::jsonb) is not null and app.usage_cached_check()), true);
select test.ok('F the hourly job runs the check', (app.job_usage_refresh() ->> 'cached_only')::boolean);
