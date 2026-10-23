-- 75: the daily cap on Google Maps calls (migration 0113). One budget a SKU a Toronto calendar day, counted through
-- app.rate_limit; the website's call public.server_maps_take is for the service role only. The program settings it
-- changes are put back at the end.
select test.suite('75 maps daily cap');

create temp table mc_set as select maps_daily_cap_autocomplete a, maps_daily_cap_place_details p, maps_daily_cap_routes r
  from program_settings where effective_from = (select effective_from from app.settings());
select test.eq('the default cap: 320 a day for each SKU (31 days inside Google''s free 10,000)',
  (select format('%s %s %s', a, p, r) from mc_set), '320 320 320');
delete from app.rate_limit_hits where key like 'maps:%';

-- ---------------------------------------------------------------- the cap
update program_settings set maps_daily_cap_autocomplete = 2, maps_daily_cap_routes = 1, maps_daily_cap_place_details = 0
 where effective_from = (select effective_from from app.settings());
select test.eq('autocomplete: the first call of the day is allowed', public.server_maps_take('autocomplete'), true);
select test.eq('autocomplete: the second (the cap) is allowed', public.server_maps_take('autocomplete'), true);
select test.eq('autocomplete: the third is over the cap', public.server_maps_take('autocomplete'), false);
select test.eq('autocomplete: and stays over', public.server_maps_take('autocomplete'), false);
select test.eq('routes has its own budget', public.server_maps_take('routes'), true);
select test.eq('routes: over its cap of 1', public.server_maps_take('routes'), false);
select test.eq('a cap of 0: never call Google, nothing counted', public.server_maps_take('place_details'), false);
select test.eq('today''s counters', app.maps_usage_today() - 'day', '{"autocomplete": 4, "place_details": 0, "routes": 2}'::jsonb);
select test.eq('the key carries the Toronto date', (select count(*)::int from app.rate_limit_hits where key = 'maps:autocomplete:' || to_char(app.today(), 'YYYY-MM-DD')), 1);
select test.throws('an unknown SKU is refused', $$select public.server_maps_take('geocode')$$, 'Unknown maps SKU');
select test.throws('a null SKU is refused', $$select public.server_maps_take(null)$$, 'Unknown maps SKU');

-- ---------------------------------------------------------------- the Toronto day
-- 19:30 and 20:30 Toronto on October 22 (EDT) fall either side of midnight UTC: one day, one count
update program_settings set maps_daily_cap_autocomplete = 2 where effective_from = (select effective_from from app.settings());
delete from app.rate_limit_hits where key like 'maps:%';
select test.eq('19:30 Toronto: allowed', app.maps_take('autocomplete', timestamptz '2026-10-22 19:30-04'), true);
select test.eq('20:30 Toronto (past midnight UTC): allowed, same count', app.maps_take('autocomplete', timestamptz '2026-10-22 20:30-04'), true);
select test.eq('23:59 Toronto: over the cap (midnight UTC did not start the count again)', app.maps_take('autocomplete', timestamptz '2026-10-22 23:59-04'), false);
select test.eq('00:01 Toronto the next day: a new budget', app.maps_take('autocomplete', timestamptz '2026-10-23 00:01-04'), true);
select test.eq('the next day''s first call removed the earlier day''s counter',
  (select string_agg(key || '=' || hits, ',') from app.rate_limit_hits where key like 'maps:autocomplete:%'), 'maps:autocomplete:2026-10-23=1');
select test.eq('the counters are out of reach of the hourly purge (their own first call of a day removes them)',
  (select bool_and(window_start + window_length > now() + interval '100 years') from app.rate_limit_hits where key like 'maps:%'), true);

-- ---------------------------------------------------------------- who may call it
select test.eq('server_maps_take: service role only',
  format('%s %s %s', has_function_privilege('anon', 'public.server_maps_take(text)', 'execute'),
         has_function_privilege('authenticated', 'public.server_maps_take(text)', 'execute'),
         has_function_privilege('service_role', 'public.server_maps_take(text)', 'execute')), 'f f t');
set role anon;
select test.throws('anon cannot take from the maps budget', $$select public.server_maps_take('autocomplete')$$, 'permission denied');
select test.throws('anon cannot call the inner function', $$select app.maps_take('autocomplete')$$, 'permission denied');
reset role;
set role authenticated;
select test.throws('a signed-in user cannot take from the maps budget', $$select public.server_maps_take('autocomplete')$$, 'permission denied');
reset role;

-- ---------------------------------------------------------------- put back
update program_settings s set maps_daily_cap_autocomplete = m.a, maps_daily_cap_place_details = m.p, maps_daily_cap_routes = m.r
  from mc_set m where s.effective_from = (select effective_from from app.settings());
delete from app.rate_limit_hits where key like 'maps:%';
drop table mc_set;
