-- 69: Live visitors heartbeat (migration 0103). A visitor reading one page keeps counting as on the site: the tab's
-- heartbeat updates the session (last seen, the page) with one UPDATE and no event, at most once every 10 seconds; it
-- never creates a session, follows the session's consent, ends the session when the tab closes, and carries a staff
-- invite. "On the site now" is 5 minutes by default; the heartbeat interval is a setting sent to the browser. Live
-- visitors counts visitors today and the browsers that chose necessary cookies only. Fixtures start with "hb".
select test.suite('69 live visitors heartbeat');

select test.mk_user('hb_admin', 'admin');
create or replace function test.hbsid(p text) returns uuid language sql immutable as $$ select md5('hb-sid:' || p)::uuid $$;
create or replace function test.hbvid(p text) returns uuid language sql immutable as $$ select md5('hb-vid:' || p)::uuid $$;
create or replace function test.hbpage(p_sid text, p_path text, p_consent text default 'analytics') returns jsonb
language sql as $$ select public.track_ingest(jsonb_build_object('sid', test.hbsid(p_sid), 'vid', test.hbvid(p_sid), 'consent', p_consent, 'device', 'desktop',
  'landing', p_path, 'events', jsonb_build_array(jsonb_build_object('k', 'page_view', 'path', p_path))), '{"city": "Toronto", "region": "ON", "country": "CA"}') $$;
create or replace function test.hbbeat(p_sid text, p_extra jsonb default '{}') returns jsonb
language sql as $$ select public.track_beat(jsonb_build_object('sid', test.hbsid(p_sid), 'vid', test.hbvid(p_sid)) || p_extra) $$;
create or replace function test.hblive(p_sid text) returns boolean language sql stable as $$
  select exists (select 1 from jsonb_array_elements(app.live_visitors(test.id('hb_admin')) -> 'now') x where x ->> 'id' = test.hbsid(p_sid)::text) $$;
create or replace function test.hbevents(p_sid text) returns bigint language sql stable as $$ select count(*) from visitor_events where session_id = test.hbsid(p_sid) $$;

-- ================================================================ 1. settings
select test.eq('live window: 5 minutes in the settings row', (app.settings()).visitor_live_minutes, 5);
select test.eq('live window: 5 minutes by default',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'visitor_live_minutes'), '5');
select test.eq('heartbeat: 45 seconds by default', (app.settings()).visitor_heartbeat_seconds, 45);
select test.eq('heartbeat: the interval goes to the browser with the chat settings', app.chat_public_cfg() ->> 'beat', '45');
select test.throws('heartbeat: at least 15 seconds', $$update program_settings set visitor_heartbeat_seconds = 5$$, 'check');
select test.eq('live visitors: the interval for the page', (app.live_visitors(test.id('hb_admin')) ->> 'beat_seconds'), '45');

-- ================================================================ 2. a visitor reading one page
select test.hbpage('reader', '/cars/some-car');
select test.eq('page beacon: one page view', test.hbevents('reader'), 1::bigint);
-- they have been on this page for 10 minutes: longer than the live window
update visitor_sessions set last_seen_at = now() - interval '10 minutes', started_at = now() - interval '10 minutes' where id = test.hbsid('reader');
select test.ok('without a heartbeat: not on the site now', not test.hblive('reader'));
select test.eq('heartbeat: written', test.hbbeat('reader', '{"path": "/cars/some-car?from=x"}') ->> 'seen', 'true');
select test.ok('heartbeat: last seen is now', (select last_seen_at > now() - interval '5 seconds' from visitor_sessions where id = test.hbsid('reader')));
select test.eq('heartbeat: no new event', test.hbevents('reader'), 1::bigint);
select test.eq('heartbeat: the page kept, without its query', (select current_path from visitor_sessions where id = test.hbsid('reader')), '/cars/some-car');
select test.eq('heartbeat: page views unchanged', (select page_views from visitor_sessions where id = test.hbsid('reader')), 1);
select test.ok('a heartbeat-only visitor is on the site now', test.hblive('reader'));
select test.ok('on the site now: counted in the menu window too',
  (select count(*) from visitor_sessions s where s.id = test.hbsid('reader') and s.last_seen_at > now() - make_interval(mins => (app.settings()).visitor_live_minutes) and s.ended_at is null) = 1);

-- ================================================================ 3. the rate limit
select test.eq('rate limit: a second heartbeat at once writes nothing', test.hbbeat('reader') ->> 'seen', 'false');
select test.eq('rate limit: the session is known', test.hbbeat('reader') ->> 'known', 'true');
update visitor_sessions set last_seen_at = now() - interval '11 seconds' where id = test.hbsid('reader');
select test.eq('rate limit: after 10 seconds it writes again', test.hbbeat('reader') ->> 'seen', 'true');

-- ================================================================ 4. the end of the visit
select test.eq('end: written even within 10 seconds', test.hbbeat('reader', '{"end": "1"}') ->> 'seen', 'true');
select test.ok('end: the session is ended', (select ended_at is not null from visitor_sessions where id = test.hbsid('reader')));
select test.ok('end: no longer on the site now', not test.hblive('reader'));
select test.eq('back (the page restored): the session lives again', test.hbbeat('reader') ->> 'seen', 'true');
select test.ok('back: not ended, on the site now', (select ended_at is null from visitor_sessions where id = test.hbsid('reader')) and test.hblive('reader'));

-- ================================================================ 5. consent and sessions the database does not have
select test.eq('never creates a session', test.hbbeat('stranger') ->> 'known', 'false');
select test.eq('never creates a session: no row', (select count(*) from visitor_sessions where id = test.hbsid('stranger')), 0::bigint);
select test.eq('another browser cannot touch the session',
  (public.track_beat(jsonb_build_object('sid', test.hbsid('reader'), 'vid', test.hbvid('someone-else'), 'end', '1')) ->> 'seen'), 'false');
select test.ok('another browser: the session is not ended', (select ended_at is null from visitor_sessions where id = test.hbsid('reader')));
select test.eq('bad ids', test.hbbeat('x', '{"sid": "nope"}') ->> 'ok', 'false');
-- without analytics consent the beacon keeps nothing for an anonymous visitor, so heartbeats have nothing to update
select test.hbpage('noconsent', '/cars/some-car', 'essential');
select test.eq('necessary cookies only: no session from the page beacon', (select count(*) from visitor_sessions where id = test.hbsid('noconsent')), 0::bigint);
select test.eq('necessary cookies only: the heartbeat creates none either', test.hbbeat('noconsent') ->> 'known', 'false');
-- a known customer without analytics consent (a session kept for their booking pages): last seen moves, the page does not
insert into visitor_sessions (id, visitor_id, consent, current_path, last_seen_at) values (test.hbsid('known'), test.hbvid('known'), 'essential', '/account/bookings/CC-1/offer', now() - interval '1 minute');
select test.eq('essential session: heartbeat written', test.hbbeat('known', '{"path": "/cars/other"}') ->> 'seen', 'true');
select test.eq('essential session: the page is not recorded', (select current_path from visitor_sessions where id = test.hbsid('known')), '/account/bookings/CC-1/offer');

-- ================================================================ 6. a staff invite reaches a visitor who only sends heartbeats
insert into chat_conversations (session_id, visitor_id, started_by, started_by_staff, status)
values (test.hbsid('reader'), test.hbvid('reader'), 'staff', test.id('hb_admin'), 'human');
insert into chat_messages (conversation_id, sender, staff_id, body)
select c.id, 'staff', test.id('hb_admin'), 'Hi, questions about this car?' from chat_conversations c where c.session_id = test.hbsid('reader');
update visitor_sessions set last_seen_at = now() - interval '11 seconds' where id = test.hbsid('reader');
select test.eq('invite: carried by the heartbeat', test.hbbeat('reader') -> 'invite' ->> 'message', 'Hi, questions about this car?');

-- ================================================================ 7. tracking off
update program_settings set visitor_tracking_enabled = false where id = (app.settings()).id;
select test.eq('tracking off: nothing written', test.hbbeat('reader', '{"end": "1"}') ->> 'off', 'true');
select test.ok('tracking off: the session is not ended', (select ended_at is null from visitor_sessions where id = test.hbsid('reader')));
update program_settings set visitor_tracking_enabled = true where id = (app.settings()).id;

-- ================================================================ 8. Live visitors: today
select test.hbpage('second', '/');
select test.hbpage('second-again', '/faq');
update visitor_sessions set visitor_id = test.hbvid('second') where id = test.hbsid('second-again');
select test.ok('today: visitors are browsers, visits are sessions',
  (select (x ->> 'visitors')::integer < (x ->> 'sessions')::integer from (select app.live_visitors(test.id('hb_admin')) -> 'today' x) y));
select app.record_cookie_choice('hb-cookie-1', 'necessary_only', 'v1');
select app.record_cookie_choice('hb-cookie-2', 'necessary_only', 'v1');
select app.record_cookie_choice('hb-cookie-2', 'accept_all', 'v1');
select test.eq('today: browsers that chose necessary cookies only (their latest choice)',
  (select (app.live_visitors(test.id('hb_admin')) -> 'today' ->> 'untracked')::integer) - (select count(*) from (select distinct on (c.visitor_id) c.analytics
     from cookie_consents c where c.recorded_at >= app.local_midnight(app.local_date(now())) and c.visitor_id not like 'hb-cookie-%'
     order by c.visitor_id, c.recorded_at desc, c.id desc) x where not x.analytics)::integer, 1);

-- ================================================================ 9. who may call it
select test.ok('the browser and the Worker call the public heartbeat', has_function_privilege('anon', 'public.track_beat(jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.track_beat(jsonb)', 'execute'));
select test.ok('not the app function directly', not has_function_privilege('anon', 'app.track_beat(jsonb)', 'execute'));
select test.ok('live visitors stays with the server', not has_function_privilege('anon', 'app.live_visitors(uuid, jsonb)', 'execute'));
