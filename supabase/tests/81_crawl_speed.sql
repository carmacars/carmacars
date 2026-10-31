-- 81: crawl speed (migration 0124, docs/changes/2026-10-23-crawl-speed.md). The IndexNow sweep sends the priority list
-- first (the site's own pages, then the priority sitemap), then the place files, then the vehicle files, with one cursor;
-- the end of a round starts the priority list again; a failed claim is recorded. The search job is due while the sweep
-- has priority or place addresses. The footer's popular hubs come from the priority list. Search Console's figures are
-- stored per sitemap. No fixtures of its own beyond two log rows, removed again.
select test.suite('81 crawl speed');

-- (earlier suites send batches too: one quota, one sweep; start clean, at the priority list)
update indexnow_sweep set backoff_until = null, backoff_s = 0, file_i = 0, pos = -1, sent_today = 0, phase = 'priority', p_i = 0, p_pos = 0,
       day = (now() at time zone 'America/Toronto')::date;
update program_settings set indexnow_enabled = true, indexnow_batch = 10000, indexnow_daily_max = 2000000 where id = (app.settings()).id;
-- 0220: the changed pages go first and the sweep waits for them; this suite looks at the sweep alone
delete from indexnow_queue where sent_at is null;
update indexnow_sweep set next_round_at = null, q_backoff_until = null, streak_429 = 0 where id;

create temp table c81 as select app.server_indexnow_claim(10000) c;
select test.ok('the first batch starts with the site''s own pages (the fleet''s cars, the landing pages)',
  (select (c -> 'paths' ->> 0) = (select p.path from app.indexnow_priority_paths() p order by p.o, p.path limit 1) from c81)
  and (select count(*) from app.indexnow_priority_paths() p where p.o = 0) > 0);
select test.ok('the priority list comes whole and in its order before any other address (each address once in it)',
  (select array(select x from c81, jsonb_array_elements_text(c -> 'paths') with ordinality e(x, n) where n <= least(10000, (select count(*) from app.indexnow_priority_paths() p where app.crawl_scope_ok(p.path))) order by n)
     = array(select p.path from app.indexnow_priority_paths() p where app.crawl_scope_ok(p.path) order by p.o, p.path limit 10000))
  and (select count(distinct path) = count(*) from app.indexnow_priority_paths()));
select test.ok('the priority sitemap (0115) is in the priority list', not exists (select 1 from app.sitemap_priority_cache s where not exists (select 1 from app.indexnow_priority_paths() p where p.path = s.path)));
select test.ok('the cursor says where the batch ended (phase and the vehicle files'' place)', (select (c -> 'cursor') ?& array['phase', 'p_i', 'p_pos', 'file_i', 'pos'] from c81));

-- the answer moves the cursor
select app.server_indexnow_report(jsonb_build_object('status', 200, 'count', 5, 'cursor', jsonb_build_object('phase', 'places', 'p_i', 2, 'p_pos', 7, 'file_i', 0, 'pos', -1)));
select test.eq('a 2xx moves the cursor to the place files', (select phase || '/' || p_i || '/' || p_pos || '/' || sent_today from indexnow_sweep), 'places/2/7/5');
select app.server_indexnow_report(jsonb_build_object('status', 429, 'count', 5, 'cursor', jsonb_build_object('phase', 'vehicles', 'p_i', 0, 'p_pos', 0)));
select test.ok('a 429 keeps the cursor', (select phase = 'places' and p_i = 2 and backoff_until > now() from indexnow_sweep));
update indexnow_sweep set backoff_until = null, backoff_s = 0;
select test.ok('the job is due while the sweep has place addresses (no copy waiting needed)', (app.server_jobs_due() ->> 'seo')::boolean);

-- the place files and the vehicle files are out of the crawl scope (0220): past the priority list the round ends, and the
-- next waits a week
-- (the job check above may queue changed car pages; they go first, so clear them for the sweep's own answer)
delete from indexnow_queue where sent_at is null;
update indexnow_sweep set phase = 'places', p_i = 0, p_pos = 0 where id;
select test.ok('in the Full search scope (the default) the place phase goes on', app.server_indexnow_claim(3) ->> 'why' is distinct from 'next round');
update indexnow_sweep set phase = 'places', p_i = 0, p_pos = 0 where id;
update program_settings set search_scope = 'core' where id = (app.settings()).id;
select test.eq('in Core the place phase ends the round (out of the crawl scope)', app.server_indexnow_claim(3) ->> 'why', 'next round');
select test.ok('the next round starts with the priority list, in a week', (select phase = 'priority' and next_round_at > now() + interval '6 days' from indexnow_sweep));
update program_settings set search_scope = 'full' where id = (app.settings()).id;
update indexnow_sweep set next_round_at = null where id;

-- the end of a round
update indexnow_sweep set phase = 'vehicles', file_i = 0, pos = -1;
select app.server_indexnow_report('{"status": 200, "count": 1, "cursor": {"file_i": 9, "pos": -1}, "files": 9}');
select test.eq('the end of the vehicle files starts the next round with the priority list', (select phase || '/' || file_i || '/' || p_pos from indexnow_sweep), 'priority/0/0');
select test.eq('a cursor without a phase is the vehicle files'' (0097''s answer)',
  (select app.server_indexnow_report('{"status": 200, "count": 1, "cursor": {"file_i": 3, "pos": 5}}') ->> 'phase'), 'vehicles');

-- a failed claim is recorded and waits ten minutes
select app.server_indexnow_report('{"status": 0, "count": 0, "error": "claim: canceling statement due to statement timeout"}');
select test.ok('a failed claim is kept with its reason and waits', (select last_error like 'claim:%' and backoff_until between now() + interval '9 minutes' and now() + interval '11 minutes' from indexnow_sweep));
update indexnow_sweep set backoff_until = null, backoff_s = 0, file_i = 0, pos = -1, sent_today = 0, phase = 'priority', p_i = 0, p_pos = 0, next_round_at = null, streak_429 = 0 where id;

-- the footer's hubs
select test.ok('popular hubs: makes, models, places and services, each from the priority list',
  (select h ?& array['makes', 'models', 'places', 'services'] from (select public.seo_hub_links() h) x)
  and not exists (select 1 from (select public.seo_hub_links() h) x, lateral (select e from jsonb_array_elements(h -> 'makes') e union all select e from jsonb_array_elements(h -> 'models') e
                  union all select e from jsonb_array_elements(h -> 'places') e union all select e from jsonb_array_elements(h -> 'services') e) y
                   where not exists (select 1 from app.sitemap_priority_cache c where c.path = y.e ->> 'path') or coalesce(y.e ->> 'name', '') = ''));
select test.ok('popular hubs: at most twelve of each', (select greatest(jsonb_array_length(h -> 'makes'), jsonb_array_length(h -> 'models'), jsonb_array_length(h -> 'places'), jsonb_array_length(h -> 'services')) <= 12
  from (select public.seo_hub_links() h) x));

-- Search Console's figures
select test.eq('Search Console figures are stored per sitemap', app.gsc_sitemap_store('[{"path": "https://carmacars.ca/sitemap-priority-1.xml", "is_index": false, "is_pending": false, "errors": 0, "warnings": 0, "submitted": 10000, "indexed": 0},
  {"path": "https://carmacars.ca/sitemap-priority-1.xml", "is_index": false, "is_pending": false, "errors": 0, "warnings": 0, "submitted": 9990, "indexed": 0}]'::jsonb), 2);
select test.ok('the latest row of each', (select count(*) = 1 from app.gsc_sitemap_latest where path = 'https://carmacars.ca/sitemap-priority-1.xml'));
delete from app.gsc_sitemap_log where path = 'https://carmacars.ca/sitemap-priority-1.xml';

set role anon;
select test.ok('anon reads the popular hubs (every page''s footer)', public.seo_hub_links() is not null);
select test.throws('anon cannot store Search Console figures', $$select app.gsc_sitemap_store('[]'::jsonb)$$, 'permission denied');
select test.throws('anon cannot read the priority walk', $$select count(*) from app.indexnow_priority_paths()$$, 'permission denied');
reset role;
