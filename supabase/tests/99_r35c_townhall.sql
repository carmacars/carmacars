-- 99: the townhall's 30-minute run (1505): the sections with their minutes, stories submitted and picked, social figures,
-- the recording link, the call link on every portal, attendance (a join counts once confirmed, an Admin marks), and the
-- lock after two townhalls missed in a row until an Admin restores the person. Fixtures start with "thx"; example.test.
select test.suite('99 r35c townhall');

select test.mk_user('thx_admin', 'admin');
select test.mk_user('thx_cs', 'va', 'cs');
select test.mk_user('thx_fleet', 'va', 'fleet');
update staff_profiles set functions = array[va_function::text] where user_id in (test.id('thx_cs'), test.id('thx_fleet'));
create function test.thx(p_user text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

-- ================================================================ 1. the run
select test.eq('30 minutes in all, every section in order', (select sum((s ->> 'minutes')::int) from jsonb_array_elements(app.townhall_slides((date_trunc('week', app.today()::timestamp))::date)) s), 30::bigint);
select test.eq('the sections the owner asked for, in order',
  (select string_agg(s ->> 'key', ',' order by o) from jsonb_array_elements(app.townhall_slides((date_trunc('week', app.today()::timestamp))::date)) with ordinality t(s, o)),
  'opener,hires,story,funnel,social,fleet,investors,investmoney,owners,topcars,toprevenue,insurer,leaderboard,dev,people');
select test.eq('the townhall runs 30 minutes', (app.settings()).townhall_minutes, 30);
select test.eq('the funnel has its five steps', (select string_agg(p ->> 'label', ', ') from jsonb_array_elements(app.townhall_slides((date_trunc('week', app.today()::timestamp))::date)) s, jsonb_array_elements(s -> 'points') p where s ->> 'key' = 'funnel'),
  'Leads generated, Contacted, Offers submitted, Requested back, Closed');

-- ================================================================ 2. stories, social figures, the recording
select test.throws('a story needs a few words', $$select test.thx('thx_cs', 'ops_do', 'townhall_story_submit', '{"body": "lol"}')$$, 'few sentences');
create temp table thx_story as select test.thx('thx_cs', 'ops_do', 'townhall_story_submit', '{"body": "A renter returned the car with a goat in the back seat, asleep."}') as v;
select test.throws('staff cannot pick the story', format($$select test.thx('thx_fleet', 'ops_do', 'townhall_story_pick', %L)$$, jsonb_build_object('id', (select v ->> 'id' from thx_story))), 'Admin');
select test.thx('thx_admin', 'admin_do', 'townhall_story_pick', jsonb_build_object('id', (select v ->> 'id' from thx_story)));
select test.thx('thx_admin', 'admin_do', 'townhall_social_save', '{"platform": "instagram", "followers": 1200, "posts": 4}');
select app.townhall_build((date_trunc('week', app.today()::timestamp))::date - 7, test.id('thx_admin'));
select test.ok('the deck shows the story picked this week',
  (select bool_or(s ->> 'key' = 'story' and (s -> 'lines' ->> 0) like '%goat%') from jsonb_array_elements(test.thx('thx_fleet', 'ops_read', 'townhall') #> '{deck,slides}') s));
select test.throws('a recording link is https', format($$select test.thx('thx_admin', 'admin_do', 'townhall_recording', %L)$$, jsonb_build_object('deck', (select id from townhall_decks order by week_of desc limit 1), 'url', 'ftp://x')), 'https');
select test.thx('thx_admin', 'admin_do', 'townhall_recording', jsonb_build_object('deck', (select id from townhall_decks order by week_of desc limit 1), 'url', 'https://video.example.test/townhall-1'));
select test.eq('every portal sees the recording', (select v #>> '{deck,recording_url}' from (select test.thx('thx_cs', 'ops_read', 'townhall') v) x), 'https://video.example.test/townhall-1');
select test.ok('the call link read works on every portal', test.thx('thx_cs', 'ops_read', 'townhall_link') ? 'next_at');

-- ================================================================ 3. attendance and the lock
update program_settings set townhall_weekday = extract(isodow from app.today())::int, townhall_time = to_char((now() + interval '5 minutes') at time zone 'America/Toronto', 'HH24:MI');
select test.thx('thx_cs', 'ops_do', 'townhall_attend', '{"method": "join"}');
select test.eq('a join alone does not count yet', app.townhall_attended(app.townhall_next(now()), test.id('thx_cs')), false);
select test.thx('thx_cs', 'ops_do', 'townhall_attend', '{"method": "confirm"}');
select test.eq('confirmed: it counts', app.townhall_attended(app.townhall_next(now()), test.id('thx_cs')), true);
select test.throws('staff cannot mark others', format($$select test.thx('thx_cs', 'ops_do', 'townhall_mark', %L)$$, jsonb_build_object('user_id', test.id('thx_fleet'), 'present', true)), 'Admin');
select test.thx('thx_admin', 'admin_do', 'townhall_mark', jsonb_build_object('user_id', test.id('thx_fleet'), 'present', true));
select test.eq('an Admin marks someone present', app.townhall_attended(app.townhall_next(now()), test.id('thx_fleet')), true);

-- two closed meetings both missed by Fleet: locked; customer service attended one: not locked
delete from townhall_meetings;
insert into townhall_meetings (meeting_at, absent) values (now() - interval '14 days', array[test.id('thx_fleet'), test.id('thx_cs')]), (now() - interval '7 days', array[test.id('thx_fleet')]);
select test.eq('two in a row: one person locked', app.townhall_lockouts(now()), 1);
select test.eq('Fleet is locked, for the townhall', (select lock_reason from staff_profiles where user_id = test.id('thx_fleet')), 'townhall');
select test.eq('customer service is not', (select inactive_locked_at is null from staff_profiles where user_id = test.id('thx_cs')), true);
select test.throws('the locked person cannot open the portal, and is told why', $$select test.thx('thx_fleet', 'ops_read', 'townhall_link')$$, 'two townhalls');
select test.eq('the staff list says why', test.thx('thx_admin', 'admin_read', 'staff_access_facts') -> test.id('thx_fleet')::text ->> 'lock_reason', 'townhall');
select test.thx('thx_admin', 'admin_do', 'staff_unlock', jsonb_build_object('user_id', test.id('thx_fleet')));
select test.eq('an Admin restores them; the reason is cleared', (select coalesce(lock_reason, 'none') || '|' || (inactive_locked_at is null) from staff_profiles where user_id = test.id('thx_fleet')), 'none|true');
select test.eq('not locked again for the same two meetings', app.townhall_lockouts(now()), 0);

-- the settings back as the other suites expect them
update program_settings set townhall_weekday = 3, townhall_time = '13:00';
