-- 99: the prize that pops up again is a chance to play again (migration 0176). The setting game_saved_again_days (1 by
-- default; 0: off); a saved prize's answer says whether Play again may start; Play again (again_of) starts another kind of
-- game with a new draw; the better prize is kept and the other play closed (never claimed, never the saved prize again);
-- once a visit and once a Toronto day (next day: allowed again); another go waits for its second game; only the
-- visitor's own open saved discount; known visitors no; the claim refuses a closed play; privileges. Fixtures start with
-- "grp".
select test.suite('99 games repop: play again on a saved prize');

select test.mk_user('grp_admin', 'admin');
create or replace function test.grpvid(p text) returns uuid language sql immutable as $$ select md5('grpvid:' || p)::uuid $$;
create or replace function test.grpsid(p text) returns uuid language sql immutable as $$ select md5('grpsid:' || p)::uuid $$;
create or replace function test.grpstart(p text, p_extra jsonb default '{}', p_sid text default null) returns jsonb language sql as $$
  select public.game_start(jsonb_build_object('vid', test.grpvid(p), 'sid', test.grpsid(coalesce(p_sid, p)), 'device', 'phone', 'path', '/cars/grp-car', 'trigger', 'pages', 'seen', '[]'::jsonb) || p_extra) $$;
-- a saved prize of this visitor: played to its end (revealed), not claimed
create or replace function test.grpsaved(p text, p_prize jsonb, p_game text default 'wheel') returns text language sql as $$
  insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at, created_at)
  values (test.grpvid(p), p_game, p_prize, '/cars/grp-car', 'pages', now() - interval '1 hour', clock_timestamp() - interval '1 hour')
  returning token $$;
create or replace function test.grpagain(p text, p_token text, p_sid text default null) returns jsonb language sql as $$
  select test.grpstart(p, jsonb_build_object('again_of', p_token), p_sid) $$;
create or replace function test.grpclaim(p_token text, p text, p_email text) returns jsonb language sql as $$
  select app.server_game_claim(jsonb_build_object('token', p_token, 'sid', test.grpsid(p), 'first_name', 'Grp ' || p, 'email', p_email, 'cars_viewed', 1, 'pages_viewed', 2, 'seconds', 60)) $$;
-- the Play again plays of this visitor made yesterday (Toronto), whatever the clock says
create or replace function test.grpyesterday(p text) returns void language sql as $$
  update game_plays set created_at = ((app.today() - 1)::timestamp + interval '12 hours') at time zone app.tz()
   where visitor_id = test.grpvid(p) and again_of is not null $$;
delete from app.rate_limit_hits where key like 'game-%';
insert into site_content_blocks (block_key, page, kind, body, data)
values ('legal.marketing_opt_in', 'legal', 'text', 'Yes, send me CarmaCars offers and news by email and text message. I can unsubscribe at any time. Sent by CarmaCars{{mailingAddress}}, {{contactEmail}}.', '{"version": "October 19, 2026"}')
on conflict (block_key) do nothing;
create temp table grp (n text primary key, v jsonb);
grant all on grp to public;
create temp table grp_prizes as select id, game_prizes from program_settings;
grant all on grp_prizes to public;

-- ================================================================ 1. the setting and the values
select test.eq('Play again on a saved prize: once a day by default', (app.settings()).game_saved_again_days, 1);
select test.throws('from 0 to 30 days', $$update program_settings set game_saved_again_days = 31$$, 'check');
select test.eq('the value of a prize on an average 4-day rental: 15% beats 10% beats 5%; $50 off 3+ days beats 10%; another go is 0; $100 off 5+ days is 0 on 4 days',
  (app.game_prize_value('{"key": "a", "percent_bps": 1500, "weight": 1}') > app.game_prize_value('{"key": "b", "percent_bps": 1000, "weight": 1}'))::text || ' '
  || (app.game_prize_value('{"key": "b", "percent_bps": 1000, "weight": 1}') > app.game_prize_value('{"key": "c", "percent_bps": 500, "weight": 1}'))::text || ' '
  || (app.game_prize_value('{"key": "d", "amount_cents": 5000, "min_days": 3, "weight": 1}') >= app.game_prize_value('{"key": "b", "percent_bps": 1000, "weight": 1}'))::text || ' '
  || app.game_prize_value('{"key": "replay", "replay": true, "weight": 1}')::text || ' '
  || app.game_prize_value('{"key": "e", "amount_cents": 10000, "min_days": 5, "weight": 1}')::text,
  'true true true 0 0');

-- ================================================================ 2. the saved prize says Play again may start
insert into grp values ('a_saved', to_jsonb(test.grpsaved('a', '{"key": "pct10", "percent_bps": 1000, "weight": 25}', 'wheel')));
select test.eq('the saved prize, and Play again may start',
  (select (r ->> 'saved') || ' ' || (r -> 'prize' ->> 'label') || ' ' || (r -> 'again' ->> 'ok') from (select test.grpstart('a') r) x), 'true 10% off true');

-- ================================================================ 3. Play again: the new prize is better
update program_settings set game_prizes = '[{"key": "pct15", "percent_bps": 1500, "weight": 1}]';
insert into grp values ('a_again', test.grpagain('a', (select v #>> '{}' from grp where n = 'a_saved')));
select test.eq('a new play: another kind of game, a new draw (15% off), the new prize kept',
  (select (v ->> 'ok') || ' ' || ((v ->> 'game') <> 'wheel')::text || ' ' || (v -> 'prize' ->> 'label') || ' ' || coalesce(v ->> 'revealed', '-') || ' '
          || (v -> 'keep' ->> 'from') || ' ' || ((v -> 'keep' ->> 'token') = (v ->> 'token'))::text || ' ' || (v -> 'keep' ->> 'other') from grp where n = 'a_again'),
  'true true 15% off false new true 10% off');
select test.eq('the saved play is closed, the new one marks where it came from',
  (select (dropped_at is not null)::text from game_plays where token = (select v #>> '{}' from grp where n = 'a_saved')) || ' '
  || (select (again_of = (select id from game_plays where token = (select v #>> '{}' from grp where n = 'a_saved')))::text || ' ' || (dropped_at is null)::text
        from game_plays where token = (select v ->> 'token' from grp where n = 'a_again')), 'true true true');
select test.eq('the closed play is never claimed',
  (select (r ->> 'error') from (select test.grpclaim((select v #>> '{}' from grp where n = 'a_saved'), 'a', 'grp.ann@example.test') r) x), 'kept_other');
select public.game_reveal((select v ->> 'token' from grp where n = 'a_again'));
select test.eq('the open prize is the new one (one open prize): saved, 15% off, Play again not again today',
  (select (r ->> 'saved') || ' ' || (r -> 'prize' ->> 'label') || ' ' || (r ->> 'token' = (select v ->> 'token' from grp where n = 'a_again'))::text || ' ' || (r -> 'again' ->> 'ok')
     from (select test.grpstart('a') r) x), 'true 15% off true false');
insert into grp values ('a_twice', test.grpagain('a', (select v ->> 'token' from grp where n = 'a_again')));
select test.eq('once a day: refused, again from the start of tomorrow (Toronto)',
  (select (v ->> 'ok') || ' ' || (v ->> 'reason') || ' ' || ((v ->> 'again_after')::timestamptz = ((app.today() + 1)::timestamp at time zone app.tz()))::text from grp where n = 'a_twice'),
  'false again_limited true');
select test.eq('no third play', (select count(*) from game_plays where visitor_id = test.grpvid('a')), 2::bigint);

-- ================================================================ 4. the next day: allowed again, but once a visit
select test.grpyesterday('a');
select test.eq('the next day, in the same visit (session): still refused, without a day',
  (select (r ->> 'reason') || ' ' || (r ? 'again_after')::text from (select test.grpagain('a', (select v ->> 'token' from grp where n = 'a_again')) r) x), 'again_limited false');
update program_settings set game_prizes = '[{"key": "pct5", "percent_bps": 500, "weight": 1}]';
insert into grp values ('a_next', test.grpagain('a', (select v ->> 'token' from grp where n = 'a_again'), 'a-next-visit'));
select test.eq('the next day on a new visit: a new game; 5% off is worse, so the 15% off is kept and the new play closed',
  (select (v ->> 'ok') || ' ' || (v -> 'prize' ->> 'label') || ' ' || (v -> 'keep' ->> 'from') || ' ' || (v -> 'keep' -> 'prize' ->> 'label') || ' '
          || ((v -> 'keep' ->> 'token') = (select v2 ->> 'token' from (select v as v2 from grp where n = 'a_again') y))::text || ' ' || (v -> 'keep' ->> 'other') from grp where n = 'a_next'),
  'true 5% off saved 15% off true 5% off');
select test.eq('the new play is closed; the 15% off is still the open prize',
  (select (dropped_at is not null)::text from game_plays where token = (select v ->> 'token' from grp where n = 'a_next')) || ' '
  || (select (r -> 'prize' ->> 'label') || ' ' || (r ->> 'saved') from (select test.grpstart('a', '{}', 'a-next-visit') r) x), 'true 15% off true');
insert into grp values ('a_claim', test.grpclaim((select v ->> 'token' from grp where n = 'a_again'), 'a', 'grp.ann@example.test'));
select test.eq('the kept prize is claimed: 15% off', (select (v ->> 'ok') || ' ' || (v ->> 'prize_label') from grp where n = 'a_claim'), 'true 15% off');

-- ================================================================ 5. a tie keeps the saved prize
insert into grp values ('b_saved', to_jsonb(test.grpsaved('b', '{"key": "pct5", "percent_bps": 500, "weight": 54}', 'dice')));
insert into grp values ('b_again', test.grpagain('b', (select v #>> '{}' from grp where n = 'b_saved')));
select test.eq('the same prize again: the saved one stays (never two open prizes)',
  (select (v -> 'keep' ->> 'from') || ' ' || ((v -> 'keep' ->> 'token') = (select v2 #>> '{}' from (select v as v2 from grp where n = 'b_saved') y))::text from grp where n = 'b_again')
  || ' ' || (select count(*) from game_plays where visitor_id = test.grpvid('b') and claimed_at is null and dropped_at is null), 'saved true 1');

-- ================================================================ 6. another go: its second game against the saved prize
update program_settings set game_prizes = '[{"key": "replay", "replay": true, "weight": 1000000}, {"key": "pct25", "percent_bps": 2500, "max_cents": 15000, "weight": 0.000001}]';
insert into grp values ('c_saved', to_jsonb(test.grpsaved('c', '{"key": "pct10", "percent_bps": 1000, "weight": 25}', 'coin')));
insert into grp values ('c_again', test.grpagain('c', (select v #>> '{}' from grp where n = 'c_saved')));
select test.eq('another go: no prize kept yet, the saved one still open',
  (select (v -> 'prize' ->> 'replay') || ' ' || (v ? 'keep')::text from grp where n = 'c_again') || ' '
  || (select (dropped_at is null)::text from game_plays where token = (select v #>> '{}' from grp where n = 'c_saved')), 'true false true');
select public.game_reveal((select v ->> 'token' from grp where n = 'c_again'));
insert into grp values ('c_second', test.grpstart('c', jsonb_build_object('replay_of', (select v ->> 'token' from grp where n = 'c_again'))));
select test.eq('its second game (25% off, drawn without the replay) against the saved 10% off: the new prize kept, the saved play closed',
  (select (v -> 'prize' ->> 'label') || ' ' || (v -> 'keep' ->> 'from') || ' ' || (v -> 'keep' ->> 'other') from grp where n = 'c_second') || ' '
  || (select (dropped_at is not null)::text from game_plays where token = (select v #>> '{}' from grp where n = 'c_saved')), '25% off new 10% off true');
update program_settings ps set game_prizes = g.game_prizes from grp_prizes g where g.id = ps.id;

-- ================================================================ 7. only the visitor's own open saved discount
insert into grp values ('d_saved', to_jsonb(test.grpsaved('d', '{"key": "pct10", "percent_bps": 1000, "weight": 25}')));
insert into game_plays (visitor_id, game, prize, path, trigger) values (test.grpvid('g'), 'dice', '{"key": "pct10", "percent_bps": 1000, "weight": 25}', '/', 'pages');
insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at) values (test.grpvid('h'), 'dice', '{"key": "replay", "replay": true, "weight": 15}', '/', 'pages', now());
select test.eq('another visitor''s prize, an unknown token, a play not revealed, another go: again_not_found',
  (test.grpagain('e', (select v #>> '{}' from grp where n = 'd_saved')) ->> 'reason') || ' ' || (test.grpagain('d', 'nope') ->> 'reason') || ' '
  || (test.grpagain('g', (select token from game_plays where visitor_id = test.grpvid('g'))) ->> 'reason') || ' '
  || (test.grpagain('h', (select token from game_plays where visitor_id = test.grpvid('h'))) ->> 'reason'),
  'again_not_found again_not_found again_not_found again_not_found');
select test.eq('the request-to-book form has no Play again on a saved prize',
  (select public.server_game_start(jsonb_build_object('vid', test.grpvid('d'), 'context', 'booking', 'again_of', (select v #>> '{}' from grp where n = 'd_saved'))) ->> 'reason'), 'again_not_found');
-- known by email (a booking request's email on their visit): no new game, Play again included
insert into visitor_sessions (id, visitor_id, known_email, identified_by) values (gen_random_uuid(), test.grpvid('d'), 'grp.dora@example.test', 'request');
select test.eq('a visitor known by email keeps the prize, without Play again',
  (select (r -> 'again' ->> 'ok') from (select test.grpstart('d') r) x) || ' ' || (test.grpagain('d', (select v #>> '{}' from grp where n = 'd_saved')) ->> 'reason'), 'false known');

-- ================================================================ 8. the setting at 0: no Play again
insert into grp values ('i_saved', to_jsonb(test.grpsaved('i', '{"key": "pct10", "percent_bps": 1000, "weight": 25}')));
update program_settings set game_saved_again_days = 0;
select test.eq('at 0: the saved prize without Play again, and a refusal without a day',
  (select (r -> 'again' ->> 'ok') from (select test.grpstart('i') r) x) || ' '
  || (select (r ->> 'reason') || ' ' || (r ? 'again_after')::text from (select test.grpagain('i', (select v #>> '{}' from grp where n = 'i_saved')) r) x), 'false again_limited false');
update program_settings set game_saved_again_days = 1;

-- ================================================================ 9. privileges
select test.eq('privileges: the new checks are the server''s; the browser''s door as before',
  has_function_privilege('anon', 'app.game_keep_better(uuid, uuid)', 'execute')::text || ' ' || has_function_privilege('authenticated', 'app.game_saved_again_after(uuid, uuid)', 'execute')::text || ' '
  || has_function_privilege('anon', 'app.game_prize_value(jsonb)', 'execute')::text || ' ' || has_function_privilege('anon', 'app.server_game_claim(jsonb, uuid)', 'execute')::text || ' '
  || has_function_privilege('anon', 'public.game_start(jsonb)', 'execute')::text,
  'false false false false true');
