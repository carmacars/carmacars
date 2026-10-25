-- 67: discount games and the chat greeting (migration 0100). The owner's defaults, live and as column defaults; no daily
-- cap; a prize already seen comes back as saved (never a game to play again, never a new win, no new draw); a dry
-- check says so; a booking request in progress stops the site's games but not the booking form's; eleven games, never
-- the same one twice in a row; the chat greeting by page (the car, the service, none in the portals) and the chat's first
-- message is the greeting the visitor saw; privileges. Fixtures start with "g3".
select test.suite('67 discount games 3 and the chat greeting');

create or replace function test.g3vid(p text) returns uuid language sql immutable as $$ select md5('g3vid:' || p)::uuid $$;
create or replace function test.g3start(p text, p_seen text[] default '{}', p_ctx text default 'site', p_dry boolean default false) returns jsonb
language sql as $$
  select case when p_ctx = 'site' and not p_dry
              then public.game_start(jsonb_build_object('vid', test.g3vid(p), 'device', 'phone', 'path', '/cars/g3-car', 'trigger', 'pages', 'seen', to_jsonb(p_seen)))
              else public.server_game_start(jsonb_build_object('vid', test.g3vid(p), 'device', 'phone', 'path', '/book/g3-car', 'context', p_ctx, 'seen', to_jsonb(p_seen), 'dry', p_dry), null) end $$;
delete from app.rate_limit_hits where key like 'game-%' or key like 'chat-%';

-- ================================================================ 1. settings
select test.eq('live values: the 2nd page view or 30 seconds, exit intent on (0101); after a close the 3rd page view or 2 minutes; 4 a visit; no daily cap; the greeting after 45 seconds',
  (select format('%s/%s/%s %s/%s %s %s %s', game_trigger_car_pages, game_trigger_seconds, game_exit_intent, game_reshow_car_pages, game_reshow_seconds,
                 game_max_per_visit, game_max_per_day, chat_greeting_seconds) from (select (app.settings()).*) s), '2/30/t 3/120 4 0 45');
select test.eq('every settings row moved, not only the current one',
  (select count(*) from program_settings where game_trigger_car_pages <> 2 or game_trigger_seconds <> 30 or game_reshow_car_pages <> 3 or game_reshow_seconds <> 120
      or game_max_per_visit <> 4 or game_max_per_day <> 0 or not game_exit_intent or chat_greeting_seconds <> 45), 0::bigint);
select test.eq('the column defaults are the owner''s too',
  (select string_agg(column_name || '=' || split_part(column_default, '::', 1), ' ' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('game_trigger_car_pages', 'game_trigger_seconds', 'game_exit_intent', 'game_reshow_car_pages', 'game_reshow_seconds',
                                                         'game_max_per_visit', 'game_max_per_day', 'chat_greeting_seconds')),
  'chat_greeting_seconds=45 game_exit_intent=true game_max_per_day=0 game_max_per_visit=4 game_reshow_car_pages=3 game_reshow_seconds=120 game_trigger_car_pages=2 game_trigger_seconds=30');
select test.eq('the browser''s settings', public.game_cfg() - 'on' - 'booking',
  '{"exit": true, "seconds": 30, "car_pages": 2, "per_day": 0, "per_visit": 4, "reshow_pages": 3, "reshow_seconds": 120}'::jsonb);
select test.throws('a daily cap above 50 is refused', $$update program_settings set game_max_per_day = 51$$, 'check');
select test.throws('a negative daily cap is refused', $$update program_settings set game_max_per_day = -1$$, 'check');
select test.eq('the greeting''s words: 0060''s replaced, the car and service greeting new',
  (select chat_greeting_text || ' | ' || chat_greeting_topic_text from (select (app.settings()).*) s),
  'Hi! Looking for a car? Ask me anything: prices, delivery, or what you need to rent. | Hi! Questions about {topic}? Ask me anything: prices, availability, or how to book.');

-- ================================================================ 2. the prize only as a game's outcome
-- the play below is claimed whatever it drew: without the replay prize (0171: never claimed; 99_games_again_replay.sql)
update program_settings set game_prizes = app.game_prizes_real(game_prizes);
create temp table g3 (n int primary key, v jsonb);
grant all on g3 to public;
insert into g3 values (1, test.g3start('a'));
select test.eq('a first play: a game to play, not revealed, not saved', (select (v ->> 'ok') || ' ' || (v ->> 'revealed') || ' ' || coalesce(v ->> 'saved', 'none') from g3 where n = 1), 'true false none');
select test.eq('the dry check before the reveal: nothing saved', test.g3start('a', '{}', 'booking', true) ->> 'saved', null::text);
select public.game_reveal((select v ->> 'token' from g3 where n = 1));
-- the browser lost its list of games (another tab, cleared storage): it asks again with nothing seen
insert into g3 values (2, test.g3start('a'));
select test.eq('after the reveal the same play comes back as saved, never as a game to play',
  (select (v ->> 'saved') || ' ' || ((v ->> 'token') = (select x.v ->> 'token' from g3 x where x.n = 1)) || ' ' || ((v -> 'prize' ->> 'key') = (select x.v -> 'prize' ->> 'key' from g3 x where x.n = 1)) from g3 where n = 2),
  'true true true');
insert into g3 values (3, test.g3start('a', array[(select v ->> 'game' from g3 where n = 1)]));
select test.eq('with the game remembered too: saved, no new play, no new draw',
  (select (v ->> 'saved') || ' ' || (select count(*) from game_plays where visitor_id = test.g3vid('a')) from g3 where n = 3), 'true 1');
select test.eq('the dry check of the booking form names the saved prize', test.g3start('a', '{}', 'booking', true) ->> 'saved',
  (select app.game_prize_label(prize) from game_plays where visitor_id = test.g3vid('a')));
select test.eq('in the booking form a visitor not signed in gets the saved prize too (no game, no new play)',
  (select (r ->> 'saved') || ' ' || (select count(*) from game_plays where visitor_id = test.g3vid('a')) from (select test.g3start('a', '{}', 'booking') r) x), 'true 1');
select test.eq('the saved prize is claimed with its token as any other',
  app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from g3 where n = 2), 'first_name', 'Gia', 'email', 'g3.a@example.test')) ->> 'ok', 'true');
select test.eq('after the claim: never again', test.g3start('a') ->> 'reason', 'claimed');
-- not revealed: the reuse of 0081 is unchanged (the same page again before the browser showed it)
insert into g3 values (4, test.g3start('b'));
select test.eq('not revealed and not shown yet: the same play again, still to play',
  (select ((v ->> 'token') = (select x.v ->> 'token' from g3 x where x.n = 4)) || ' ' || (v ->> 'revealed') || ' ' || coalesce(v ->> 'saved', 'none') from (select test.g3start('b') v) y), 'true false none');
select test.eq('closed before the reveal: the next show is another game with the same prize, still to play',
  (select ((v ->> 'game') <> (select x.v ->> 'game' from g3 x where x.n = 4)) || ' ' || ((v -> 'prize' ->> 'key') = (select x.v -> 'prize' ->> 'key' from g3 x where x.n = 4)) || ' ' || coalesce(v ->> 'saved', 'none')
     from (select test.g3start('b', array[(select v ->> 'game' from g3 where n = 4)]) v) y), 'true true none');

update program_settings set game_prizes = default;

-- ================================================================ 3. a booking request in progress
insert into contact_captures (visitor_id, form, ref, email, page) values (test.g3vid('busy'), 'booking_request', 'g3-draft', 'g3.busy@example.test', '/book/g3-car');
select test.eq('a booking request in progress: no game on the site', test.g3start('busy') ->> 'reason', 'in_progress');
select test.eq('the request-to-book form keeps its own game', test.g3start('busy', '{}', 'booking') ->> 'ok', 'true');
update contact_captures set last_at = now() - interval '31 days' where visitor_id = test.g3vid('busy');
select test.eq('a request left a month ago no longer stops the games', test.g3start('busy') ->> 'ok', 'true');

-- ================================================================ 4. eleven games, never the same twice in a row
select test.eq('eleven games, the five new ones on at the same weight',
  array_to_string(app.game_kinds(), ' ') || ' | ' || (select string_agg(k || '=' || ((app.settings()).game_weights ->> k), ' ' order by k) from unnest(array['coin', 'dice', 'drop', 'mystery', 'slots']) k),
  'wheel scratch blackjack cups plinko pack coin dice slots drop mystery | coin=1 dice=1 drop=1 mystery=1 slots=1');
select test.throws('a game not known is still refused', $$update program_settings set game_weights = '{"roulette": 1}'$$, 'check');
insert into game_plays (visitor_id, game, prize, path, trigger) values (test.g3vid('rot'), 'coin', '{"key": "pct5", "percent_bps": 500, "weight": 69}', '/', 'pages');
select test.eq('a browser that forgot its round never gets the game it was shown last',
  (select bool_and(app.game_next_kind(test.g3vid('rot'), null, '{}', null) <> 'coin') from generate_series(1, 300)), true);
select test.eq('a full round in the browser starts again, never with the last game',
  (select bool_and(app.game_next_kind(test.g3vid('rot'), null, app.game_kinds(), 'coin') <> 'coin') from generate_series(1, 300)), true);
do $$
declare i int; v_seen text[] := '{}'; r jsonb; v_last text;
begin
  for i in 1..30 loop
    delete from app.rate_limit_hits where key like 'game-%';
    r := test.g3start('round', v_seen);
    if r ->> 'game' = v_last then raise warning 'g3: the same game twice in a row: %', v_last; end if;
    insert into g3 values (100 + i, r);
    v_last := r ->> 'game';
    v_seen := case when cardinality(v_seen) + 1 >= 11 then array[v_last] else v_seen || v_last end;
  end loop;
end $$;
select test.eq('30 shows to one visitor: every game in the first eleven, never the same twice in a row',
  (select count(distinct v ->> 'game') from g3 where n between 101 and 111)::text || ' '
  || (select count(*) from g3 a join g3 b on b.n = a.n + 1 where a.n between 101 and 129 and a.v ->> 'game' = b.v ->> 'game')::text, '11 0');
update program_settings set game_weights = '{"wheel": 0, "scratch": 0, "blackjack": 0, "cups": 0, "plinko": 0, "pack": 0, "coin": 0, "dice": 1, "slots": 0, "drop": 0, "mystery": 0}';
select test.eq('only one game on: it repeats (nothing else to show)', app.game_next_kind(test.g3vid('rot'), null, '{}', 'dice'), 'dice');
update program_settings set game_weights = '{"wheel": 1, "scratch": 1, "blackjack": 1, "cups": 1, "plinko": 1, "pack": 1, "coin": 1, "dice": 1, "slots": 1, "drop": 1, "mystery": 1}';

-- ================================================================ 5. the chat greeting
select test.mk_owner('g3_own');
select test.mk_vehicle('G3V', 'g3_own');
update vehicles set year = 2021, make = 'Mercedes-Benz', model = 'A220' where id = test.id('vehicle:G3V');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at) values (test.id('vehicle:G3V'), 'g3-a220', 'Mercedes A220', 'published', now());
select test.eq('the browser hears when (45 seconds) without the beacon', (public.chat_greeting('/faq') ->> 'after')::int, 45);
select test.eq('on a car page: the car', (public.chat_greeting('/cars/g3-a220') ->> 'text'), 'Hi! Questions about the 2021 Mercedes-Benz A220? Ask me anything: prices, availability, or how to book.');
select test.eq('on the service pages: the service',
  (public.chat_greeting('/chauffeur') ->> 'text') || ' | ' || (public.chat_greeting('/detailing/ceramic/toronto') ->> 'text') || ' | ' || (public.chat_greeting('/body-shop') ->> 'text'),
  'Hi! Questions about our chauffeur service? Ask me anything: prices, availability, or how to book. | Hi! Questions about our car detailing? Ask me anything: prices, availability, or how to book. | Hi! Questions about our body shop? Ask me anything: prices, availability, or how to book.');
select test.eq('elsewhere on the site, and on a car page of a car not on the site: the general greeting',
  (public.chat_greeting('/') ->> 'text') || ' | ' || (public.chat_greeting('/cars/no-such-car?x=1') ->> 'text'),
  'Hi! Looking for a car? Ask me anything: prices, delivery, or what you need to rent. | Hi! Looking for a car? Ask me anything: prices, delivery, or what you need to rent.');
select test.eq('never in the portals, sign-in, booking, checkout or payment pages',
  (select count(*) from unnest(array['/account', '/account/bookings/CC-1', '/owner/cars', '/admin', '/va/live', '/field', '/investor', '/sign-in', '/book/g3-a220', '/checkout', '/pay/x', '/account/bookings/CC-1/pay', '/my-request/x']) p
    where (public.chat_greeting(p) ->> 'text') is not null), 0::bigint);
update program_settings set chat_greeting_seconds = 0;
select test.eq('the greeting off (0 seconds): none', public.chat_greeting('/'), '{"after": 0, "text": null}'::jsonb);
update program_settings set chat_greeting_seconds = 45, chat_greeting_topic_text = 'Questions about {topic}? We are here.';
select test.eq('the car and service greeting is Admin''s words', (public.chat_greeting('/chauffeur') ->> 'text'), 'Questions about our chauffeur service? We are here.');
update program_settings set chat_greeting_topic_text = 'Hi! Questions about {topic}? Ask me anything: prices, availability, or how to book.';
insert into g3 values (200, app.server_chat_open(jsonb_build_object('vid', test.g3vid('chat'), 'page', '/faq', 'greeting', 'true', 'greeting_page', '/cars/g3-a220')));
select test.eq('a reply opens the chat with the greeting the visitor saw (its page) as the first message, from CarmaCars',
  (select (v ->> 'ok') || ' ' || (v -> 'messages' -> 0 ->> 'sender') || ' ' || (v -> 'messages' -> 0 ->> 'body') from g3 where n = 200),
  'true ai Hi! Questions about the 2021 Mercedes-Benz A220? Ask me anything: prices, availability, or how to book.');
select test.eq('the conversation says it began from the greeting', (select started_by from chat_conversations where token = (select v ->> 'token' from g3 where n = 200)), 'greeting');
insert into g3 values (201, app.server_chat_open(jsonb_build_object('vid', test.g3vid('chat2'), 'page', '/how-it-works', 'greeting', 'true')));
select test.eq('without its page: the greeting of the page the chat opens on',
  (select v -> 'messages' -> 0 ->> 'body' from g3 where n = 201), 'Hi! Looking for a car? Ask me anything: prices, delivery, or what you need to rent.');
select test.eq('a chat opened without the greeting has no first message from it',
  jsonb_array_length(app.server_chat_open(jsonb_build_object('vid', test.g3vid('chat3'), 'page', '/faq')) -> 'messages'), 0);

-- ================================================================ 6. privileges
select test.eq('the browser may ask for the greeting; the inner functions are the server''s only',
  has_function_privilege('anon', 'public.chat_greeting(text)', 'execute')::text || ' '
  || has_function_privilege('anon', 'app.chat_greeting_for(text)', 'execute')::text || ' '
  || has_function_privilege('authenticated', 'app.game_start_core(jsonb, uuid)', 'execute')::text || ' '
  || has_function_privilege('anon', 'app.game_next_kind(uuid, uuid, text[], text)', 'execute')::text,
  'true false false false');
