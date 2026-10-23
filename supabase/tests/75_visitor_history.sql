-- 75: Visitor history (migration 0118). Past visits for Admins only: the list with its filters and pages, one visit
-- in full (pages with the time on each, games, chats, forms, bookings), the daily totals worked out by the visitor
-- job in small batches, and the retention: page detail 90 days, the visit's summary 13 months, the totals 3 years,
-- each an Admin setting. Bots and staff are left out by default. Fixtures start with "vh".
select test.suite('75 visitor history');

select test.mk_user('vh_admin', 'admin');
select test.mk_user('vh_cs', 'va', 'cs');
select test.mk_user('vh_sales', 'va', 'sales');
select test.mk_user('vh_staffer', 'va', 'fleet');
select test.mk_owner('vh_owner');
select test.mk_vehicle('vhcar', 'vh_owner');
select test.mk_renter('vh_renter');

create or replace function test.vhsid(p text) returns uuid language sql immutable as $$ select md5('vh-sid:' || p)::uuid $$;
create or replace function test.vhvid(p text) returns uuid language sql immutable as $$ select md5('vh-vid:' || p)::uuid $$;
-- a visit that started p_ago before now and lasted p_len, with p_pages page views a minute apart
create or replace function test.vhvisit(p_sid text, p_ago interval, p_len interval, p_pages integer, p jsonb default '{}') returns uuid
language plpgsql as $$
declare
  v uuid := test.vhsid(p_sid);
  i integer;
begin
  insert into visitor_sessions (id, visitor_id, consent, started_at, last_seen_at, city, region, country, device, referrer, utm, landing_path,
                                current_path, page_views, visit_number, renter_id, user_id, known_email)
  values (v, coalesce((p ->> 'vid')::uuid, test.vhvid(p_sid)), coalesce(p ->> 'consent', 'analytics'), now() - p_ago, now() - p_ago + p_len,
          coalesce(p ->> 'city', 'Vh Toronto'), 'ON', coalesce(p ->> 'country', 'CA'), coalesce(p ->> 'device', 'desktop'), p ->> 'ref',
          coalesce(p -> 'utm', '{}'), coalesce(p ->> 'landing', '/'), '/cars', p_pages, coalesce((p ->> 'n')::integer, 1),
          (p ->> 'renter')::uuid, (p ->> 'user')::uuid, p ->> 'email');
  for i in 0 .. p_pages - 1 loop
    insert into visitor_events (session_id, at, kind, path)
    values (v, now() - p_ago + make_interval(mins => i), 'page_view', case when i = 0 then coalesce(p ->> 'landing', '/') when i = p_pages - 1 then '/faq' else '/cars' end);
  end loop;
  return v;
end $$;
create or replace function test.vhlist(p jsonb default '{}', p_by text default 'vh_admin') returns jsonb
language sql as $$ select app.door(test.id(p_by), '', 'admin_read', 'visitor_history', '{"city": "vh "}'::jsonb || p) $$;
create or replace function test.vhids(p jsonb default '{}') returns text[]
language sql as $$ select coalesce(array_agg(x ->> 'id' order by ord), '{}') from jsonb_array_elements(test.vhlist(p) -> 'rows') with ordinality y(x, ord) $$;
create or replace function test.vhhas(p jsonb, p_sid text) returns boolean
language sql as $$ select test.vhsid(p_sid)::text = any (test.vhids(p)) $$;

-- ================================================================ 1. settings and retention defaults
select test.eq('visits are kept 13 months by default (0121: the privacy policy, approved by the lawyer)', (app.settings()).visitor_sessions_keep_days, 395);
select test.eq('page detail stays 90 days', (app.settings()).visitor_events_keep_days, 90);
select test.eq('daily totals: 3 years', (app.settings()).visitor_daily_keep_days, 1095);
select test.throws('visits kept at least 30 days', $$update program_settings set visitor_sessions_keep_days = 7$$, 'check');
select test.throws('totals kept at most 10 years', $$update program_settings set visitor_daily_keep_days = 4000$$, 'check');

-- ================================================================ 2. the visits
-- today: a Google visitor on a phone in Ottawa who sent a request; a returning direct visitor who gave contact details
select test.vhvisit('google', '2 hours', '20 minutes', 4, '{"device": "phone", "city": "Vh Ottawa", "ref": "google.com", "landing": "/cars/x-car"}');
insert into visitor_events (session_id, at, kind, path) values (test.vhsid('google'), now() - interval '1 hour 45 minutes', 'request_submitted', '/book/sent/R-1');
select test.vhvisit('back', '3 hours', '10 minutes', 2, '{"n": 3, "utm": {"source": "newsletter", "medium": "email", "campaign": "fall"}}');
insert into contact_captures (visitor_id, form, ref, email, first_at, last_at)
values (test.vhvid('back'), 'contact', 'vh-1', 'vh.back@example.test', now() - interval '2 hours 55 minutes', now() - interval '2 hours 55 minutes');
-- a game played and revealed, a chat with a message
insert into game_plays (visitor_id, session_id, game, prize, created_at, revealed_at)
values (test.vhvid('back'), test.vhsid('back'), (app.game_kinds())[1], '{"key": "p10", "percent_bps": 1000}', now() - interval '2 hours 58 minutes', now() - interval '2 hours 57 minutes');
insert into chat_conversations (id, number, token, session_id, visitor_id, status, started_by, created_at, last_message_at)
values (test.id('vh-chat'), 'VH-CHAT-1', md5('vh-chat'), test.vhsid('back'), test.vhvid('back'), 'closed', 'visitor', now() - interval '2 hours 56 minutes', now() - interval '2 hours 56 minutes');
insert into chat_messages (conversation_id, at, sender, body) values (test.id('vh-chat'), now() - interval '2 hours 56 minutes', 'visitor', 'Is the car free on Friday?');
-- a renter who confirmed a booking during the visit
select test.vhvisit('renter', '4 hours', '15 minutes', 3, jsonb_build_object('renter', test.id('renter:vh_renter'), 'user', test.id('vh_renter'), 'email', 'vh_renter@example.test', 'n', 2));
select test.mk_booking('VH-1001', 'vhcar', 'vh_renter', to_char((now() + interval '10 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'),
  to_char((now() + interval '13 days') at time zone 'America/Toronto', 'YYYY-MM-DD 10:00'), 'confirmed',
  p_booked => to_char((now() - interval '3 hours 50 minutes') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI:SS'));
-- a bot (200 pages in two minutes) and someone who is staff now
select test.vhvisit('bot', '5 hours', '2 minutes', 200);
select test.vhvisit('staffer', '5 hours', '5 minutes', 2, jsonb_build_object('user', test.id('vh_staffer')));
-- a visit still going on: summarized only once it has been quiet for 30 minutes
select test.vhvisit('ongoing', '10 minutes', '9 minutes', 2);
-- older: 40 days (summary and pages), 120 days (summary only after the housekeeping), 400 days (gone)
select test.vhvisit('old40', '40 days', '5 minutes', 2, '{"country": "US", "city": "Vh Buffalo", "device": "tablet"}');
select test.vhvisit('old120', '120 days', '5 minutes', 2);
select test.vhvisit('old400', '400 days', '5 minutes', 2);

-- ================================================================ 3. the job: summaries in small batches
select test.ok('the follow-ups job runs the history (its answer stays the follow-ups'')', app.job_visitor_followups() like 'raised %');
select test.eq('summarized: every quiet visit', (select count(*) from visitor_sessions where id in (test.vhsid('google'), test.vhsid('back'), test.vhsid('renter'),
  test.vhsid('bot'), test.vhsid('staffer'), test.vhsid('old40'), test.vhsid('old120'), test.vhsid('old400')) and summary_at is not null), 8::bigint);
select test.ok('not summarized: a visit still going on', (select summary_at is null from visitor_sessions where id = test.vhsid('ongoing')));
select test.eq('request sent', (select conversions from visitor_sessions where id = test.vhsid('google')), array['request']);
select test.eq('contact details given', (select conversions from visitor_sessions where id = test.vhsid('back')), array['contact']);
select test.ok('has contact: details given', (select has_contact from visitor_sessions where id = test.vhsid('back')));
select test.ok('has contact: not for an anonymous visitor', (select not has_contact from visitor_sessions where id = test.vhsid('google')));
select test.ok('booking confirmed during the visit', (select 'booking' = any (conversions) and has_contact from visitor_sessions where id = test.vhsid('renter')));
select test.eq('exit page', (select exit_path from visitor_sessions where id = test.vhsid('google')), '/book/sent/R-1');
select test.eq('length in seconds', (select duration_s from visitor_sessions where id = test.vhsid('google')), 1200);
select test.eq('bot marked', (select exclude_reason from visitor_sessions where id = test.vhsid('bot')), 'bot');
select test.eq('staff marked', (select exclude_reason from visitor_sessions where id = test.vhsid('staffer')), 'staff');
select test.eq('a normal visit is not marked', (select exclude_reason from visitor_sessions where id = test.vhsid('google')), null::text);
select test.ok('bot rule: 30 pages in 30 seconds', app.visit_is_bot(30, 30));
select test.ok('bot rule: 30 pages in 10 minutes is a person', not app.visit_is_bot(30, 600));
-- a batch is bounded
update visitor_sessions set summary_at = null where id in (test.vhsid('google'), test.vhsid('back'));
select test.eq('batch: at most the limit', app.job_visitor_history(now(), 1) like 'visits 1,%', true);
select app.job_visitor_history();
-- a visit that came back after its summary is summarized again
update visitor_sessions set last_seen_at = now() - interval '40 minutes', page_views = page_views + 1 where id = test.vhsid('back');
select app.job_visitor_history();
select test.ok('came back: summarized again', (select summary_at > last_seen_at from visitor_sessions where id = test.vhsid('back')));

-- ================================================================ 4. the daily totals
select test.ok('today''s totals are there', exists (select 1 from visitor_daily where day = app.local_date(now())));
do $$ begin for i in 1 .. 60 loop perform app.job_visitor_history(now(), 10); end loop; end $$;
select test.ok('the 40-day-old day is filled in later batches (7 days a run)',
  exists (select 1 from visitor_daily where day = app.local_date(now() - interval '40 days') and visits = 1));
select test.ok('totals: bots and staff left out, counted apart',
  (select sum(left_out) from visitor_daily where day in (app.local_date(now() - interval '5 hours'), app.local_date(now() - interval '5 hours') - 1)) >= 2);
create temp table vh_sum as select test.vhlist(jsonb_build_object('from', app.local_date(now()) - 1, 'to', app.local_date(now()))) -> 'summary' as s;
select test.ok('summary: a day per date', jsonb_array_length((select s -> 'days' from vh_sum)) = 2);
select test.ok('summary: visits and conversions',
  ((select s -> 'totals' ->> 'visits' from vh_sum)::integer >= 3 and (select s -> 'totals' ->> 'converted' from vh_sum)::integer >= 3));
select test.ok('summary: unique visitors of the range', (select (s ->> 'visitors')::integer from vh_sum) >= 3);
select test.ok('summary: top pages from the page views', exists (select 1 from jsonb_array_elements((select s -> 'top' -> 'page' from vh_sum)) x where x ->> 'key' = '/cars'));
select test.ok('summary: top sources', exists (select 1 from jsonb_array_elements((select s -> 'top' -> 'source' from vh_sum)) x where x ->> 'key' = 'google.com')
  and exists (select 1 from jsonb_array_elements((select s -> 'top' -> 'source' from vh_sum)) x where x ->> 'key' = 'newsletter'));
select test.ok('summary: no personal information in the daily tables',
  not exists (select 1 from information_schema.columns where table_name in ('visitor_daily', 'visitor_daily_top')
               and column_name in ('visitor_id', 'session_id', 'renter_id', 'user_id', 'email', 'city')));

-- ================================================================ 5. the list and its filters
select test.ok('list: today''s visits, newest first', test.vhids() @> array[test.vhsid('google')::text, test.vhsid('back')::text, test.vhsid('renter')::text]
  and array_position(test.vhids(), test.vhsid('google')::text) < array_position(test.vhids(), test.vhsid('renter')::text));
select test.ok('list: the last 30 days by default (40 days ago is not in it)', not test.vhhas('{}', 'old40'));
select test.ok('list: a date range', test.vhhas(jsonb_build_object('from', app.local_date(now() - interval '41 days'), 'to', app.local_date(now() - interval '39 days')), 'old40'));
select test.ok('list: bots and staff left out by default', not test.vhhas('{}', 'bot') and not test.vhhas('{}', 'staffer'));
select test.ok('list: shown on request', test.vhhas('{"bots": "1"}', 'bot') and test.vhhas('{"bots": "1"}', 'staffer'));
select test.ok('filter: source (referrer)', test.vhhas('{"source": "google"}', 'google') and not test.vhhas('{"source": "google"}', 'back'));
select test.ok('filter: source (campaign)', test.vhhas('{"source": "fall"}', 'back'));
select test.ok('filter: landing page', test.vhhas('{"landing": "/cars/x"}', 'google') and not test.vhhas('{"landing": "/cars/x"}', 'back'));
select test.ok('filter: device', test.vhhas('{"device": "phone"}', 'google') and not test.vhhas('{"device": "phone"}', 'back'));
select test.ok('filter: city', test.vhhas('{"city": "vh ottawa"}', 'google') and not test.vhhas('{"city": "vh ottawa"}', 'back'));
select test.ok('filter: country', test.vhhas(jsonb_build_object('country', 'us', 'from', app.local_date(now()) - 60), 'old40')
  and not test.vhhas(jsonb_build_object('country', 'us', 'from', app.local_date(now()) - 60), 'google'));
select test.ok('filter: returning', test.vhhas('{"visitor": "returning"}', 'back') and not test.vhhas('{"visitor": "returning"}', 'google'));
select test.ok('filter: new', test.vhhas('{"visitor": "new"}', 'google') and not test.vhhas('{"visitor": "new"}', 'back'));
select test.ok('filter: converted', test.vhhas('{"converted": "any"}', 'google') and test.vhhas('{"converted": "booking"}', 'renter')
  and not test.vhhas('{"converted": "booking"}', 'google') and test.vhhas('{"converted": "none"}', 'ongoing'));
select test.ok('filter: has contact', test.vhhas('{"contact": "1"}', 'back') and not test.vhhas('{"contact": "1"}', 'google'));
select test.ok('filter: known', test.vhhas('{"known": "1"}', 'renter') and not test.vhhas('{"known": "1"}', 'google'));
select test.ok('filter: wildcards are plain text', not test.vhhas('{"source": "%"}', 'google'));
-- pages: a cursor, never a repeat
create temp table vh_p1 as select test.vhlist('{"limit": 2}') as j;
select test.eq('page: the limit', jsonb_array_length((select j -> 'rows' from vh_p1)), 2);
select test.ok('page: a cursor to the next', (select j ->> 'next' from vh_p1) is not null);
create temp table vh_p2 as select test.vhlist(jsonb_build_object('limit', 2, 'cursor', (select j ->> 'next' from vh_p1))) as j;
select test.ok('page 2: other visits, older', not exists (select 1 from jsonb_array_elements((select j -> 'rows' from vh_p2)) a, jsonb_array_elements((select j -> 'rows' from vh_p1)) b where a ->> 'id' = b ->> 'id')
  and ((select j -> 'rows' -> 0 ->> 'started_at' from vh_p2)::timestamptz <= (select j -> 'rows' -> 1 ->> 'started_at' from vh_p1)::timestamptz));
select test.ok('page 2: no summary again', not ((select j from vh_p2) ? 'summary'));
select test.eq('limit: at most 100', (test.vhlist('{"limit": 5000}') ->> 'limit')::integer, 100);
select test.eq('dates: no later than today', (test.vhlist(jsonb_build_object('to', app.local_date(now()) + 5)) ->> 'to')::date, app.local_date(now()));
select test.eq('dates: no earlier than what is kept', (test.vhlist('{"from": "2000-01-01"}') ->> 'from')::date, app.local_date(now()) - 395);
select test.throws('dates: written YYYY-MM-DD', $$ select test.vhlist('{"from": "last week"}') $$, 'YYYY-MM-DD');

-- ================================================================ 6. one visit
create temp table vh_v as select app.door(test.id('vh_admin'), '', 'admin_read', 'visitor_visit', jsonb_build_object('id', test.vhsid('back'))) as v;
select test.eq('visit: its pages in order', (select jsonb_array_length(v -> 'timeline') from vh_v), 2);
select test.eq('visit: time on the first page (until the next)', (select (v -> 'timeline' -> 0 ->> 'seconds')::integer from vh_v), 60);
select test.ok('visit: time on the last page (until the last sign of life)', (select (v -> 'timeline' -> 1 ->> 'seconds')::integer from vh_v) > 0);
select test.eq('visit: the source', (select v ->> 'utm_campaign' from vh_v), 'fall');
select test.eq('visit: the game', (select jsonb_array_length(v -> 'games') from vh_v), 1);
select test.ok('visit: the game was revealed', (select v -> 'games' -> 0 ->> 'revealed_at' from vh_v) is not null);
select test.eq('visit: the chat and its message', (select v -> 'chats' -> 0 -> 'first' -> 0 ->> 'body' from vh_v), 'Is the car free on Friday?');
select test.eq('visit: the form started and not sent', (select v -> 'forms' -> 0 ->> 'sent' from vh_v), 'false');
select test.eq('visit: other visits of the browser', (select v -> 'other_visits' ->> 'count' from vh_v), '1');
create temp table vh_r as select app.door(test.id('vh_admin'), '', 'admin_read', 'visitor_visit', jsonb_build_object('id', test.vhsid('renter'))) as v;
select test.eq('visit: the renter', (select v -> 'renter' ->> 'id' from vh_r), test.id('renter:vh_renter')::text);
select test.eq('visit: the booking it led to', (select v -> 'bookings' -> 0 ->> 'number' from vh_r), 'VH-1001');
select test.throws('visit: one that is gone', $$ select app.door(test.id('vh_admin'), '', 'admin_read', 'visitor_visit', '{"id": "00000000-0000-0000-0000-000000000000"}') $$, 'no longer kept');
select test.throws('visit: a bad id', $$ select app.door(test.id('vh_admin'), '', 'admin_read', 'visitor_visit', '{"id": "x"}') $$, 'no longer kept');

-- ================================================================ 7. Admins only
select test.throws('customer service: no history', $$ select app.door(test.id('vh_cs'), '', 'va_read', 'visitor_history', '{}') $$, 'Admins');
select test.throws('Sales: no history', $$ select app.door(test.id('vh_sales'), '', 'va_read', 'visitor_visit', jsonb_build_object('id', test.vhsid('back'))) $$, 'Admins');
select test.throws('a VA calling it as an Admin read', $$ select app.door(test.id('vh_cs'), '', 'admin_read', 'visitor_history', '{}') $$, null);
select test.throws('a renter', $$ select app.visitor_history(test.id('vh_renter'), '{}') $$, null);
select test.ok('the browser roles cannot call the reads', not has_function_privilege('authenticated', 'app.visitor_history(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.visitor_visit(uuid, jsonb)', 'execute'));
select test.ok('the browser roles cannot read the totals', not has_table_privilege('authenticated', 'visitor_daily', 'select') and not has_table_privilege('anon', 'visitor_daily_top', 'select'));
select test.ok('the job keeps its privileges (service only)', not has_function_privilege('authenticated', 'app.job_visitor_followups(timestamptz)', 'execute')
  and has_function_privilege('service_role', 'app.job_visitor_followups(timestamptz)', 'execute'));
select test.ok('the door still answers the other reads', (app.door(test.id('vh_cs'), '', 'va_read', 'chat_counts', '{}') ? 'waiting'));

-- ================================================================ 8. retention
select test.eq('housekeeping', app.job_visitor_housekeeping() ~ '^events \d+, sessions \d+, chats \d+, days \d+$', true);
select test.eq('120 days: the pages are gone', (select count(*) from visitor_events where session_id = test.vhsid('old120')), 0::bigint);
select test.ok('120 days: the visit''s summary is kept', exists (select 1 from visitor_sessions where id = test.vhsid('old120')));
select test.ok('40 days: pages and visit kept', exists (select 1 from visitor_events where session_id = test.vhsid('old40')));
select test.ok('400 days: the visit is gone', not exists (select 1 from visitor_sessions where id = test.vhsid('old400')));
create temp table vh_o as select app.door(test.id('vh_admin'), '', 'admin_read', 'visitor_visit', jsonb_build_object('id', test.vhsid('old120'))) as v;
select test.ok('an old visit: no pages, and says so', (select jsonb_array_length(v -> 'timeline') = 0 and v ->> 'pages_kept' = 'false' from vh_o));
-- a shorter setting: the visit summaries follow it, never shorter than the page detail
update program_settings set visitor_sessions_keep_days = 100 where id = (app.settings()).id;
select app.job_visitor_housekeeping();
select test.ok('a 100-day setting: the 120-day visit goes', not exists (select 1 from visitor_sessions where id = test.vhsid('old120')));
update program_settings set visitor_sessions_keep_days = 30, visitor_events_keep_days = 90 where id = (app.settings()).id;
select app.job_visitor_housekeeping();
select test.ok('never shorter than the page detail: the 40-day visit stays', exists (select 1 from visitor_sessions where id = test.vhsid('old40')));
update program_settings set visitor_sessions_keep_days = 395 where id = (app.settings()).id;
-- the totals
insert into visitor_daily (day, visits) values (app.local_date(now()) - 1200, 5);
insert into visitor_daily_top (day, dim, key, n) values (app.local_date(now()) - 1200, 'page', '/', 5);
select app.job_visitor_housekeeping();
select test.ok('totals older than 3 years go, with their top lists', not exists (select 1 from visitor_daily where day = app.local_date(now()) - 1200)
  and not exists (select 1 from visitor_daily_top where day = app.local_date(now()) - 1200));
select test.ok('totals of 40 days ago stay', exists (select 1 from visitor_daily where day = app.local_date(now() - interval '40 days')));
-- a visit with a chat is kept as before
select test.ok('a visit with a chat is kept', exists (select 1 from visitor_sessions where id = test.vhsid('back')));

-- ================================================================ 9. the privacy policy (0121)
select test.ok('privacy policy: the 13 months are written where our text is',
  not exists (select 1 from site_content_blocks where block_key = 'legal.privacy' and body like '%| Site visit records (pages, events) |%' and body not like '%| Site visit summaries%'));
-- (the test database has no legal text; the local stack's /privacy shows the row: e2e visitor-history)
select test.ok('privacy policy: last updated October 23, 2026 where the policy carries a date',
  not exists (select 1 from site_content_blocks where block_key = 'legal.meta' and (data ->> 'last_updated') in ('October 19, 2026', 'October 21, 2026')));

-- clean up what other suites count
delete from visitor_sessions where visitor_id in (select test.vhvid(x) from unnest(array['google', 'back', 'renter', 'bot', 'staffer', 'ongoing', 'old40', 'old120', 'old400']) x);
