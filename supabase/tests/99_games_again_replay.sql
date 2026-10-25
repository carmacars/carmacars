-- 99: the discount game comes back and one prize is another go (migration 0171). The default prize table with the replay
-- prize (live rows and the column default), the table check, the terms; Play again: the second play is another game with
-- a prize drawn without the replay, one per replay prize, only for this visitor's revealed and unclaimed replay prize,
-- outside the start limit; a replay prize is never claimed and never the saved discount (a revealed one not used yet
-- comes back as saved, to play again); a closed game comes back (the prize is kept game_dismiss_days, 14); the report;
-- privileges. Fixtures start with "ga".
select test.suite('99 games again: pop up again, play again');

select test.mk_user('gar_admin', 'admin');
create or replace function test.gavid(p text) returns uuid language sql immutable as $$ select md5('gavid:' || p)::uuid $$;
create or replace function test.gastart(p text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select public.game_start(jsonb_build_object('vid', test.gavid(p), 'device', 'phone', 'path', '/cars/ga-car', 'trigger', 'pages', 'seen', '[]'::jsonb) || p_extra) $$;
-- a play of this visitor with the replay prize, revealed (the game played to its end)
create or replace function test.gareplay(p text, p_game text default 'wheel', p_revealed boolean default true) returns text language sql as $$
  insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at, created_at)
  values (test.gavid(p), p_game, '{"key": "replay", "replay": true, "weight": 15}', '/cars/ga-car', 'pages', case when p_revealed then now() end, clock_timestamp())
  returning token $$;
delete from app.rate_limit_hits where key like 'game-%';
create temp table ga (n text primary key, v jsonb);
grant all on ga to public;

-- ================================================================ 1. the prize table
select test.eq('the default table: 5% 54, 10% 25, another go 15, 15% 4, $50 3+ days 1, 25% 0.6, $100 4+ days 0.3, a free day 0.1 (100 in all)',
  (select string_agg(app.game_prize_label(x) || ' ' || (x ->> 'weight'), ', ' order by o) || ' | ' || sum((x ->> 'weight')::numeric)
     from jsonb_array_elements((app.settings()).game_prizes) with ordinality t(x, o)),
  '5% off 54, 10% off 25, another go 15, 15% off 4, $50 off 1, 25% off 0.6, $100 off 0.3, 1 free day 0.1 | 100.0');
create or replace function test.ga_default() returns jsonb language plpgsql as $$
declare v jsonb;
begin
  execute 'select ' || (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'game_prizes') into v;
  return v;
end $$;
select test.eq('every settings row has it, and the live table is the column default',
  (select count(*) from program_settings where not exists (select 1 from jsonb_array_elements(game_prizes) x where app.game_prize_is_replay(x)))::text || ' '
  || ((app.settings()).game_prizes = test.ga_default())::text, '0 true');
select test.eq('the column default carries the replay prize',
  (select column_default like '%"replay": true%' from information_schema.columns where table_name = 'program_settings' and column_name = 'game_prizes'), true);
select test.eq('the table check: a replay with a value, a false replay, two replays, a replay alone are refused; one replay with a discount is fine',
  app.game_prizes_ok('[{"key": "r", "replay": true, "percent_bps": 500, "weight": 1}, {"key": "a", "percent_bps": 500, "weight": 1}]')::text || ' '
  || app.game_prizes_ok('[{"key": "r", "replay": false, "weight": 1}, {"key": "a", "percent_bps": 500, "weight": 1}]')::text || ' '
  || app.game_prizes_ok('[{"key": "r", "replay": true, "weight": 1}, {"key": "s", "replay": true, "weight": 1}, {"key": "a", "percent_bps": 500, "weight": 1}]')::text || ' '
  || app.game_prizes_ok('[{"key": "r", "replay": true, "weight": 1}]')::text || ' '
  || app.game_prizes_ok('[{"key": "a", "percent_bps": 500, "weight": 3}, {"key": "r", "replay": true, "weight": 1}]')::text,
  'false false false false true');
select test.throws('the database refuses a table of only the replay prize', $$update program_settings set game_prizes = '[{"key": "replay", "replay": true, "weight": 1}]'$$, 'check');
select test.eq('words: "another go", "REPLAY" on a wheel slice, "Play again" nowhere as a discount',
  app.game_prize_label('{"key": "replay", "replay": true, "weight": 15}') || ' | ' || app.game_prize_short('{"key": "replay", "replay": true, "weight": 15}'), 'another go | REPLAY');
select test.eq('the terms name the replay prize for what it is',
  app.game_terms_text(),
  'Prizes: 5%, 10%, 15% or 25% off, or $50 off 3+ day rentals, or $100 off 4+ day rentals, or 1 free day on 3+ day rentals, or another go (a second game, which always ends in a discount). The chances differ: most players win 5% off. Off the rental charge only, up to $75 per code (25% off: up to $150, 1 free day: up to $150). One use, on one booking, within 7 days. One code a day per person, email, phone and device. Not combinable with other promo codes.');
select test.eq('the draw without the replay keeps the others'' order and odds',
  (select string_agg(x ->> 'key', ' ' order by o) from jsonb_array_elements(app.game_prizes_real((app.settings()).game_prizes)) with ordinality t(x, o)),
  'pct5 pct10 pct15 amt50 pct25 amt100 day1');
select test.eq('10,000 first draws: the replay about 15 in 100',
  (select count(*) filter (where k = 'replay') between 1350 and 1650 from (select app.game_draw((app.settings()).game_prizes) ->> 'key' as k from generate_series(1, 10000)) x), true);
select test.eq('the browser sees which prize is the replay', (select string_agg(x ->> 'key', ' ') from jsonb_array_elements(app.game_play_json((select g from game_plays g limit 0)) -> 'prizes') x where (x ->> 'replay')::boolean), 'replay');

-- ================================================================ 2. play again
insert into ga values ('t1', to_jsonb(test.gareplay('a', 'wheel')));
insert into ga values ('a2', test.gastart('a', jsonb_build_object('replay_of', (select v #>> '{}' from ga where n = 't1'))));
select test.eq('Play again: a second play, another game, a discount, marked as the second game',
  (select (v ->> 'ok') || ' ' || (v ->> 'second') || ' ' || ((v ->> 'game') <> 'wheel')::text || ' ' || (v -> 'prize' ->> 'replay') || ' ' || coalesce(v ->> 'saved', 'none') || ' ' || (v ->> 'revealed') from ga where n = 'a2'),
  'true true true false none false');
select test.eq('the first play is marked replayed and the second points to it',
  (select (o.replayed_at is not null)::text || ' ' || (s.replay_of = o.id)::text || ' ' || s.context || ' ' || s.trigger
     from game_plays o join game_plays s on s.token = (select v ->> 'token' from ga where n = 'a2') where o.token = (select v #>> '{}' from ga where n = 't1')),
  'true true site pages');
select test.eq('Play again twice: refused, no third play',
  (test.gastart('a', jsonb_build_object('replay_of', (select v #>> '{}' from ga where n = 't1'))) ->> 'reason') || ' ' || (select count(*) from game_plays where visitor_id = test.gavid('a')),
  'replay_used 2');
select test.eq('another visitor''s replay prize: refused',
  test.gastart('other', jsonb_build_object('replay_of', test.gareplay('owner'))) ->> 'reason', 'replay_not_found');
select test.eq('not revealed yet (the game was not played to its end): refused',
  test.gastart('unrev', jsonb_build_object('replay_of', test.gareplay('unrev', 'coin', false))) ->> 'reason', 'replay_used');
insert into ga values ('cl', to_jsonb(test.gareplay('cl')));
update game_plays set claimed_at = now() where token = (select v #>> '{}' from ga where n = 'cl');
select test.eq('a play marked claimed: refused', test.gastart('cl', jsonb_build_object('replay_of', (select v #>> '{}' from ga where n = 'cl'))) ->> 'reason', 'replay_used');
insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at) values (test.gavid('disc'), 'dice', '{"key": "pct10", "percent_bps": 1000, "weight": 25}', '/', 'pages', now());
select test.eq('a discount prize is not a replay: refused',
  test.gastart('disc', jsonb_build_object('replay_of', (select token from game_plays where visitor_id = test.gavid('disc')))) ->> 'reason', 'replay_used');
select test.eq('an unknown token: refused', test.gastart('a', '{"replay_of": "nope"}') ->> 'reason', 'replay_not_found');
select test.eq('a site replay prize is not played again in the request-to-book form',
  public.server_game_start(jsonb_build_object('vid', test.gavid('ctx'), 'context', 'booking', 'replay_of', test.gareplay('ctx')), null) ->> 'reason', 'replay_not_found');
insert into game_plays (visitor_id, game, prize, path, trigger, context, revealed_at)
values (test.gavid('bk'), 'cups', '{"key": "replay", "replay": true, "weight": 15}', '/book/ga-car', 'booking', 'booking', now());
select test.eq('in the request-to-book form its own replay prize plays again (the site''s server passes it)',
  (select (r ->> 'ok') || ' ' || (r ->> 'context') || ' ' || (r ->> 'second') || ' ' || (r ->> 'game' <> 'cups')::text
     from (select public.server_game_start(jsonb_build_object('vid', test.gavid('bk'), 'context', 'booking', 'replay_of', (select token from game_plays where visitor_id = test.gavid('bk'))), null) r) y),
  'true booking true true');
-- the second play's prize: never the replay, and always another game (200 visitors)
do $$
declare
  i int;
  r jsonb;
  t text;
begin
  for i in 1..200 loop
    t := test.gareplay('many' || i, (array['wheel', 'coin', 'dice', 'slots'])[1 + i % 4]);
    r := test.gastart('many' || i, jsonb_build_object('replay_of', t));
    insert into ga values ('m' || i, r || jsonb_build_object('first', (array['wheel', 'coin', 'dice', 'slots'])[1 + i % 4]));
  end loop;
end $$;
select test.eq('200 second plays: all started, none the replay prize, none the same game as the first, the discounts drawn by their odds',
  (select count(*) filter (where v ->> 'ok' = 'true')::text || ' ' || count(*) filter (where (v -> 'prize' ->> 'replay')::boolean)::text || ' '
          || count(*) filter (where v ->> 'game' = v ->> 'first')::text || ' ' || (count(*) filter (where v -> 'prize' ->> 'key' = 'pct5') > 90)::text
     from ga where n like 'm%'), '200 0 0 true');
-- the start limit: a visitor at the limit still gets the second game
insert into ga values ('lim', to_jsonb(test.gareplay('lim')));
select app.rate_limit('game-start:' || test.gavid(v), 10, interval '1 hour') from unnest(array['lim', 'lim3']) v, generate_series(1, 12);
select test.eq('at the start limit: no new game, but Play again works',
  (test.gastart('lim3') ->> 'reason') || ' ' || (test.gastart('lim', jsonb_build_object('replay_of', (select v #>> '{}' from ga where n = 'lim'))) ->> 'ok'), 'limited true');
delete from app.rate_limit_hits where key like 'game-%';

-- ================================================================ 3. never claimed, never the saved discount
insert into ga values ('c1', to_jsonb(test.gareplay('claim')));
select test.eq('a replay prize is never claimed',
  (select (r ->> 'ok') || ' ' || (r ->> 'error') from (select app.server_game_claim(jsonb_build_object('token', (select v #>> '{}' from ga where n = 'c1'), 'first_name', 'Gil', 'email', 'ga.claim@example.test')) r) x)
  || ' ' || (select count(*) from game_claims where email = 'ga.claim@example.test'), 'false replay 0');
select test.eq('the site''s claim door refuses it too',
  public.server_game_claim(jsonb_build_object('token', (select v #>> '{}' from ga where n = 'c1'), 'first_name', 'Gil', 'email', 'ga.claim@example.test'), null) ->> 'error', 'replay');
select test.eq('a revealed replay not used yet comes back as saved, to play again (the same play)',
  (select (r ->> 'saved') || ' ' || (r -> 'prize' ->> 'replay') || ' ' || ((r ->> 'token') = (select v #>> '{}' from ga where n = 'c1'))::text from (select test.gastart('claim') r) x), 'true true true');
select test.eq('the dry check names no saved discount for it',
  coalesce(public.server_game_start(jsonb_build_object('vid', test.gavid('claim'), 'context', 'site', 'dry', true), null) ->> 'saved', 'none'), 'none');
-- known by email after the win: the replay prize stays theirs (as a saved prize)
insert into visitor_sessions (id, visitor_id, known_email) values (gen_random_uuid(), test.gavid('claim'), 'ga.claim@example.test');
select test.eq('known by email after winning another go: it still comes back', test.gastart('claim') ->> 'saved', 'true');
insert into ga values ('c2', test.gastart('claim', jsonb_build_object('replay_of', (select v #>> '{}' from ga where n = 'c1'))));
select test.eq('and plays again', (select v ->> 'ok' from ga where n = 'c2'), 'true');
select test.eq('the second game closed before its prize: it comes back as it was (known by email or not), the same discount, not a new replay',
  (select (r ->> 'ok') || ' ' || ((r ->> 'token') = (select v ->> 'token' from ga where n = 'c2'))::text || ' ' || coalesce(r ->> 'saved', 'none')
     from (select test.gastart('claim', jsonb_build_object('seen', jsonb_build_array((select v ->> 'game' from ga where n = 'c2')))) r) x), 'true true none');
select public.game_reveal((select token from game_plays where visitor_id = test.gavid('claim') order by created_at desc limit 1));
select test.eq('the second game played to its prize: that discount is the saved prize, claimable',
  (select (r ->> 'saved') || ' ' || (r -> 'prize' ->> 'replay') || ' ' || (r -> 'prize' ->> 'label') = 'true false ' || (select v -> 'prize' ->> 'label' from ga where n = 'c2') from (select test.gastart('claim') r) x), true);
select test.eq('the dry check names that discount',
  public.server_game_start(jsonb_build_object('vid', test.gavid('claim'), 'context', 'site', 'dry', true), null) ->> 'saved', (select v -> 'prize' ->> 'label' from ga where n = 'c2'));
select test.eq('and it is claimed',
  app.server_game_claim(jsonb_build_object('token', (select token from game_plays where visitor_id = test.gavid('claim') order by created_at desc limit 1), 'first_name', 'Gil', 'email', 'ga.claim@example.test')) ->> 'ok', 'true');
select test.eq('after the claim: not again that day (0172), not even Play again', test.gastart('claim', jsonb_build_object('replay_of', test.gareplay('claim'))) ->> 'reason', 'claimed');
-- a replay used whose second play has gone (a visitor's latest play is the replay again): no second replay from it
insert into ga values ('u1', to_jsonb(test.gareplay('used')));
select test.gastart('used', jsonb_build_object('replay_of', (select v #>> '{}' from ga where n = 'u1')));
delete from game_plays where visitor_id = test.gavid('used') and replay_of is not null;
select test.eq('a replay already used is not saved and not drawn again',
  (select coalesce(r ->> 'saved', 'none') || ' ' || (r -> 'prize' ->> 'replay') from (select test.gastart('used') r) x), 'none false');

-- ================================================================ 4. it comes back
select test.eq('the prize is kept 14 days (game_dismiss_days, not a wait after a close)', (app.settings()).game_dismiss_days, 14);
insert into ga values ('cb', test.gastart('back'));
select test.eq('a game closed before its prize: on the next visit a game again (another game, the same prize)',
  (select (r ->> 'ok') || ' ' || ((r ->> 'game') <> (select v ->> 'game' from ga where n = 'cb'))::text || ' ' || ((r -> 'prize' ->> 'key') = (select v -> 'prize' ->> 'key' from ga where n = 'cb'))::text
     from (select test.gastart('back', jsonb_build_object('seen', jsonb_build_array((select v ->> 'game' from ga where n = 'cb')))) r) x), 'true true true');
insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at) values (test.gavid('won'), 'slots', '{"key": "pct10", "percent_bps": 1000, "weight": 25}', '/', 'pages', now());
select test.eq('a prize won and not claimed: every later show is that prize, saved (the card pops up with it), no new play',
  (select string_agg(r ->> 'saved', ' ') from (select test.gastart('won') r from generate_series(1, 3)) x) || ' ' || (select count(*) from game_plays where visitor_id = test.gavid('won')),
  'true true true 1');
update game_plays set created_at = now() - interval '15 days' where visitor_id = test.gavid('won');
select test.eq('after the 14 days the saved prize ends: a new game', (select coalesce(r ->> 'saved', 'none') || ' ' || (r ->> 'revealed') from (select test.gastart('won') r) x), 'none false');

-- ================================================================ 5. the report
select test.eq('the report: a Play again row with its plays, no claims, and the second games',
  (select (x ->> 'plays')::int > 200 and (x ->> 'claims')::int = 0 and (r ->> 'replays')::int >= 200
     from (select app.game_report(test.id('gar_admin'), '{"days": 30}') r) y, jsonb_array_elements(r -> 'by_prize') x where x ->> 'prize' = 'Play again'), true);
select test.eq('every prize row has its plays', (select bool_and(x ? 'plays') from jsonb_array_elements(app.game_report(test.id('gar_admin'), '{}') -> 'by_prize') x), true);
select test.eq('the leads read works with replay plays about', jsonb_typeof(app.game_leads(test.id('gar_admin'), '{}') -> 'rows'), 'array');

-- ================================================================ 6. privileges
select test.eq('privileges: the core and the claim stay with the service role; the browser''s doors as before; the replay check for the settings check',
  has_function_privilege('anon', 'app.game_start_core(jsonb, uuid)', 'execute')::text || ' ' || has_function_privilege('anon', 'app.server_game_claim(jsonb, uuid)', 'execute')::text || ' '
  || has_function_privilege('authenticated', 'app.server_game_claim_pre0171(jsonb, uuid)', 'execute')::text || ' ' || has_function_privilege('anon', 'app.game_prizes_real(jsonb)', 'execute')::text || ' '
  || has_function_privilege('anon', 'public.game_start(jsonb)', 'execute')::text || ' ' || has_function_privilege('authenticated', 'app.game_prize_is_replay(jsonb)', 'execute')::text || ' '
  || has_function_privilege('service_role', 'app.server_game_claim(jsonb, uuid)', 'execute')::text,
  'false false false false true true true');
