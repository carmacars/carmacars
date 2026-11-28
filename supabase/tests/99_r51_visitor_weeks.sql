-- 99: the visitors week by week for the connector (5211, REQ-140): Admin only, admin:read, weeks start Monday, the daily
-- totals summed, unique browsers counted once a week with bots left out. Fixtures start with "vw". Its own visits and days only.
select test.suite('99 r51 visitor weeks');
create temp table vw_ps as select id, api_access_enabled e, api_calls_per_minute n from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;
select test.mk_user('vw_admin', 'admin');
select test.mk_user('vw_cs', 'va', 'cs');
create function test.vw_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'utf8')), 'hex') $$;
select app.api_key_create(test.id('vw_admin'), test.id('vw_admin'), 'Read', array['admin:read'], test.vw_h('cc_live_vw_read'), 'cc_live_vwr_');

-- this week: two days of totals; the same browser twice, another once, a bot left out
create temp table vw_mon as select date_trunc('week', app.today())::date d;
insert into visitor_daily (day, visits, visitors, new_visits, page_views, signups, bookings)
select d, 1000, 900, 700, 3000, 5, 2 from vw_mon
on conflict (day) do update set visits = visitor_daily.visits + 1000, new_visits = visitor_daily.new_visits + 700, page_views = visitor_daily.page_views + 3000,
  signups = visitor_daily.signups + 5, bookings = visitor_daily.bookings + 2;
create temp table vw_before as select coalesce((app.visitor_weeks(test.id('vw_admin')) -> 'weeks' -> 0 ->> 'unique_browsers')::integer, 0) n;
insert into visitor_sessions (id, visitor_id, started_at) values
  (md5('vw:s1')::uuid, md5('vw:b1')::uuid, now()), (md5('vw:s2')::uuid, md5('vw:b1')::uuid, now()), (md5('vw:s3')::uuid, md5('vw:b2')::uuid, now());
insert into visitor_sessions (id, visitor_id, started_at, exclude_reason) values (md5('vw:s4')::uuid, md5('vw:b3')::uuid, now(), 'bot');

create temp table vw_r as select app.api_call(test.vw_h('cc_live_vw_read'), 'visitor_weeks', '{"weeks": 4}', 'test') r;
select test.eq('ok through the connector', (select r ->> 'ok' from vw_r), 'true');
select test.eq('4 weeks, newest first, Mondays', (select jsonb_array_length(r #> '{result,weeks}') || ' ' || (r #>> '{result,weeks,0,week_of}') || ' ' || extract(isodow from (r #>> '{result,weeks,3,week_of}')::date)
  from vw_r), '4 ' || (select d from vw_mon) || ' 1');
select test.eq('this week is in progress', (select r #>> '{result,weeks,0,in_progress}' from vw_r), 'true');
select test.ok('the daily totals are summed', (select (r #>> '{result,weeks,0,visits}')::integer >= 1000 and (r #>> '{result,weeks,0,signups}')::integer >= 5 from vw_r));
select test.eq('a browser counts once a week, a bot not at all', (select (r #>> '{result,weeks,0,unique_browsers}')::integer - (select n from vw_before) from vw_r), 2);
select test.eq('the call is logged', (select count(*) from api_calls where tool = 'visitor_weeks' and ok and user_id = test.id('vw_admin')), 1::bigint);
select test.throws('staff cannot read it', format('select app.visitor_weeks(%L)', test.id('vw_cs')), 'Only an Admin reads the visitors');
select test.ok('server only', not has_function_privilege('authenticated', 'app.visitor_weeks(uuid, jsonb)', 'execute'));

delete from visitor_sessions where id in (md5('vw:s1')::uuid, md5('vw:s2')::uuid, md5('vw:s3')::uuid, md5('vw:s4')::uuid);
update visitor_daily set visits = visits - 1000, new_visits = new_visits - 700, page_views = page_views - 3000, signups = signups - 5, bookings = bookings - 2 where day = (select d from vw_mon);
update program_settings p set api_access_enabled = s.e, api_calls_per_minute = s.n from vw_ps s where p.id = s.id;
