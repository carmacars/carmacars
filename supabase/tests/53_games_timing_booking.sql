-- 53: discount games, sooner and again, and in the request-to-book form (migration 0081). The new settings and the
-- live values moved from the old defaults; the re-show with a game not seen yet (all five before one repeats, from the
-- browser's list and the server's plays), the same prize on every show (no new draw); the booking form: signed-in
-- renters may play and claim with their account's email, never staff, never after a claim, a visitor known by email
-- may; a dry check records nothing; privileges. Fixtures start with "g2".
select test.suite('53 discount games: timing, re-show, booking form');

select test.mk_user('g2_admin', 'admin');
select test.mk_user('g2_cs', 'va', 'cs');
select test.mk_renter('g2_rita');
select test.mk_renter('g2_ben');
create or replace function test.g2vid(p text) returns uuid language sql immutable as $$ select md5('g2vid:' || p)::uuid $$;
create or replace function test.g2start(p text, p_seen text[] default '{}', p_ctx text default 'site', p_user uuid default null, p_dry boolean default false) returns jsonb
language sql as $$
  select case when p_ctx = 'site' and p_user is null and not p_dry
              then public.game_start(jsonb_build_object('vid', test.g2vid(p), 'device', 'desktop', 'path', '/cars/g2-car', 'trigger', 'pages', 'seen', to_jsonb(p_seen)))
              else public.server_game_start(jsonb_build_object('vid', test.g2vid(p), 'device', 'desktop', 'path', '/book/g2-car', 'context', p_ctx, 'seen', to_jsonb(p_seen), 'dry', p_dry), p_user) end $$;
delete from app.rate_limit_hits where key like 'game-%';
delete from game_claims; delete from game_plays;

-- ================================================================ 1. settings
select test.eq('0100, the owner''s defaults: the 2nd page view or 30 seconds, exit intent on (0101); again on the 3rd page view or after 2 minutes; 4 a visit; the booking form on',
  (select format('%s/%s/%s %s/%s %s %s', game_trigger_car_pages, game_trigger_seconds, game_exit_intent, game_reshow_car_pages, game_reshow_seconds, game_max_per_visit, game_booking_offer)
     from (select (app.settings()).*) s), '2/30/t 3/120 4 t');
select test.eq('the column defaults are the new ones too',
  (select string_agg(column_name || '=' || column_default, ' ' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('game_trigger_car_pages', 'game_trigger_seconds', 'game_reshow_car_pages', 'game_reshow_seconds', 'game_max_per_visit')),
  'game_max_per_visit=4 game_reshow_car_pages=3 game_reshow_seconds=120 game_trigger_car_pages=2 game_trigger_seconds=30');
select test.throws('a per-visit cap of 0 is refused', $$update program_settings set game_max_per_visit = 0$$, 'check');
select test.throws('a re-show after more than an hour is refused', $$update program_settings set game_reshow_seconds = 3601$$, 'check');
select test.eq('the four prizes of 0069 stay, three rare ones join them (0081), another go at 15 from 5% (0171: 54), the $75 cap and the code length stay',
  (select string_agg(app.game_prize_label(x) || ' ' || (x ->> 'weight'), ', ' order by o) || ' | ' || (app.settings()).game_max_discount_cents || ' ' || (app.settings()).game_code_valid_days
     from jsonb_array_elements((app.settings()).game_prizes) with ordinality t(x, o)), '5% off 54, 10% off 25, another go 15, 15% off 4, $50 off 1, 25% off 0.6, $100 off 0.3, 1 free day 0.1 | 7500 7');

-- ================================================================ 2. the re-show: a game not seen yet, the same prize
-- the plays of sections 2 and 3 are claimed whatever they drew: without the replay prize (0171: never claimed; its own
-- suite is 99_games_again_replay.sql); the owner's table is back in section 5
update program_settings set game_prizes = app.game_prizes_real(game_prizes);
create temp table g2 (n int primary key, v jsonb);
grant all on g2 to public;
insert into g2 values (1, test.g2start('a'));
-- the first play's prize is set, not drawn: a common one (a random draw is rare about 1 run in 100, and the rare check
-- below reads this row as the common example); every later show of this visitor carries it
update game_plays set prize = '{"key": "pct5", "percent_bps": 500, "weight": 69}' where token = (select v ->> 'token' from g2 where n = 1);
update g2 set v = jsonb_set(v, '{prize}', (select app.game_play_json(gp) -> 'prize' from game_plays gp where gp.token = g2.v ->> 'token')) where n = 1;
select test.eq('the first show: a play', (select (v ->> 'ok') || ' ' || (v ->> 'context') from g2 where n = 1), 'true site');
select test.eq('the same page again before it was seen: the same play', (test.g2start('a') ->> 'token') = (select v ->> 'token' from g2 where n = 1), true);
do $$
declare
  i int;
  v_seen text[];
begin
  for i in 2..6 loop
    select coalesce(array_agg(v ->> 'game' order by n), '{}') into v_seen from g2 where n < i;
    -- the browser keeps a round: once all five were seen it starts again with the last one
    if cardinality(v_seen) >= 5 then v_seen := array[v_seen[cardinality(v_seen)]]; end if;
    insert into g2 values (i, test.g2start('a', v_seen));
  end loop;
end $$;
select test.eq('closed and shown again five times: five different games', (select count(distinct v ->> 'game') from g2 where n <= 5), 5::bigint);
select test.eq('the sixth is not the fifth again', (select v ->> 'game' from g2 where n = 6) <> (select v ->> 'game' from g2 where n = 5), true);
select test.eq('every show has the same prize (drawn once: closing never draws again)', (select count(distinct v -> 'prize' ->> 'key') from g2), 1::bigint);
select test.eq('each show is its own play, with one prize in the database', (select count(*) || ' ' || count(distinct prize) from game_plays where visitor_id = test.g2vid('a')), '6 1');
-- a browser that forgot its list: the server's plays still say what was shown
delete from app.rate_limit_hits where key like 'game-%';
insert into g2 values (20, test.g2start('b'));
insert into g2 values (21, test.g2start('b', array[(select v ->> 'game' from g2 where n = 20)]));
insert into g2 values (22, test.g2start('b', array[(select v ->> 'game' from g2 where n = 21)]));
select test.eq('the server remembers: a browser that kept only the last game still gets one it has not shown',
  (select v ->> 'game' from g2 where n = 22) not in ((select v ->> 'game' from g2 where n = 20), (select v ->> 'game' from g2 where n = 21))
  and (select v ->> 'token' from g2 where n = 22) <> (select v ->> 'token' from g2 where n = 21), true);
update program_settings set game_weights = '{"wheel": 1, "scratch": 1, "blackjack": 1, "cups": 1, "plinko": 0, "pack": 0}';
select test.eq('a game at weight 0 is never chosen, and the round is the four left',
  (select bool_and(app.game_next_kind(test.g2vid('w0'), null, '{}', null) not in ('plinko', 'pack')) from generate_series(1, 200))
  and app.game_next_kind(test.g2vid('w0'), null, array['wheel', 'scratch', 'blackjack'], 'blackjack') = 'cups', true);
update program_settings set game_weights = '{"wheel": 1, "scratch": 1, "blackjack": 1, "cups": 1, "plinko": 1, "pack": 1, "coin": 1, "dice": 1, "slots": 1, "drop": 1, "mystery": 1}';
select test.eq('the reveal and the claim of a re-shown play work as before',
  (public.game_reveal((select v ->> 'token' from g2 where n = 6)))::text || ' ' || (app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from g2 where n = 6),
    'first_name', 'Gina', 'email', 'g2.a@example.test')) ->> 'ok'), 'true true');
select test.eq('after the claim: not again on this browser that day (0172)', test.g2start('a', array['wheel']) ->> 'reason', 'claimed');

-- ================================================================ 3. the request-to-book form
select test.eq('the site never shows a game to someone signed in', test.g2start('r1', '{}', 'site', test.id('g2_rita')) ->> 'reason', 'signed_in');
insert into visitor_sessions (id, visitor_id, known_email, identified_by) values (md5('g2sid:known')::uuid, test.g2vid('known'), 'known.g2@example.test', 'email_link');
select test.eq('the browser cannot ask for the booking form''s rules (public.game_start ignores the context)',
  public.game_start(jsonb_build_object('vid', test.g2vid('known'), 'context', 'booking')) ->> 'reason', 'known');
select test.eq('a dry check records nothing', (select (test.g2start('r1', '{}', 'booking', test.id('g2_rita'), true) ->> 'dry') || ' ' || count(*) from game_plays where visitor_id = test.g2vid('r1')), 'true 0');
insert into g2 values (10, test.g2start('r1', '{}', 'booking', test.id('g2_rita')));
select test.eq('a signed-in renter plays in the booking form, with their account named',
  (select (v ->> 'ok') || ' ' || (v ->> 'context') || ' ' || (v -> 'account' ->> 'email') || ' ' || (v -> 'account' ->> 'first') from g2 where n = 10), 'true booking g2_rita@example.test G2');
select test.eq('the play is recorded as the booking form''s, with the account', (select context || ' ' || trigger || ' ' || (user_id = test.id('g2_rita')) from game_plays where token = (select v ->> 'token' from g2 where n = 10)), 'booking booking true');
select test.eq('on another browser the same account keeps its prize and gets another game',
  (select ((v -> 'prize' ->> 'key') = (select g.v -> 'prize' ->> 'key' from g2 g where g.n = 10)) and (v ->> 'game') <> (select g.v ->> 'game' from g2 g where g.n = 10)
     from (select test.g2start('r2', array[(select v ->> 'game' from g2 where n = 10)], 'booking', test.id('g2_rita')) as v) x), true);
select test.eq('a visitor known by email may play in the booking form', test.g2start('known', '{}', 'booking') ->> 'ok', 'true');
select test.eq('a visitor not signed in may play in the booking form', test.g2start('anon1', '{}', 'booking') ->> 'context', 'booking');
select test.eq('never staff', test.g2start('s1', '{}', 'booking', test.id('g2_cs')) ->> 'reason' || ' ' || (test.g2start('s2', '{}', 'booking', test.id('g2_admin')) ->> 'reason'), 'staff staff');
update program_settings set game_booking_offer = false;
select test.eq('the booking form''s offer can be turned off', test.g2start('anon2', '{}', 'booking') ->> 'reason', 'off');
update program_settings set game_booking_offer = true;

-- the claim
select test.eq('a signed-in renter cannot claim a play of the site', app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from g2 where n = 1), 'first_name', 'R',
  'email', 'r@example.test'), test.id('g2_rita')) ->> 'error', 'signed_in');
insert into g2 values (11, app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from g2 where n = 10), 'email', 'someone.else@example.test', 'first_name', ''), test.id('g2_rita')));
select test.eq('a signed-in renter claims with their account''s email (not one typed), linked to the account',
  (select (v ->> 'ok') || ' ' || (v ->> 'email') from g2 where n = 11) || ' ' || (select (user_id = test.id('g2_rita'))::text || ' ' || (renter_id = test.id('renter:g2_rita'))::text || ' ' || first_name from game_claims where email = 'g2_rita@example.test'),
  'true g2_rita@example.test true true G2');
select test.eq('the code keeps the rules: single use, the cap, 7 days, the minimum length of its prize',
  (select pc.max_uses || ' ' || pc.once_per_renter || ' ' || (pc.valid_until::date - pc.valid_from::date) || ' ' || coalesce(pc.max_discount_cents::text, '-') || ' ' || coalesce(pc.min_rental_days::text, '-')
     from promo_codes pc where pc.code = (select v ->> 'code' from g2 where n = 11)),
  (select '1 true 7 ' || case when p.prize ? 'percent_bps' then '7500' else '-' end || ' ' || coalesce(p.prize ->> 'min_days', '-') from game_plays p where p.token = (select v ->> 'token' from g2 where n = 10)));
select test.eq('one per person a day (0172): the account cannot play again on any browser, nor claim again, that day',
  (test.g2start('r4', '{}', 'booking', test.id('g2_rita')) ->> 'reason') || ' ' || (app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from g2 where n = 10), 'first_name', 'R'), test.id('g2_rita')) ->> 'error'),
  'claimed claimed');
select test.eq('staff cannot claim', app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from g2 where n = 10), 'first_name', 'S'), test.id('g2_cs')) ->> 'error', 'staff');
select test.eq('a visitor in the booking form claims as on the site (one per email, phone and device)',
  (app.server_game_claim(jsonb_build_object('token', test.g2start('anon1', '{}', 'booking') ->> 'token', 'first_name', 'Ann', 'email', 'g2.anon@example.test')) ->> 'ok')
  || ' ' || (app.server_game_claim(jsonb_build_object('token', test.g2start('anon3', '{}', 'booking') ->> 'token', 'first_name', 'Ann', 'email', 'g2.anon@example.test')) ->> 'error'), 'true email_used');

-- ================================================================ 4. privileges
select test.eq('privileges: the booking form''s play is the server''s; the site''s play stays open to the browser',
  has_function_privilege('anon', 'public.server_game_start(jsonb, uuid)', 'execute')::text || has_function_privilege('authenticated', 'public.server_game_start(jsonb, uuid)', 'execute')::text
  || has_function_privilege('service_role', 'public.server_game_start(jsonb, uuid)', 'execute')::text || has_function_privilege('anon', 'public.game_start(jsonb)', 'execute')::text
  || has_function_privilege('anon', 'app.game_start_core(jsonb, uuid)', 'execute')::text || has_function_privilege('anon', 'app.server_game_claim_pre0081(jsonb, uuid)', 'execute')::text,
  'falsefalsetruetruefalsefalse');
select test.eq('the privacy policy says when and where the games show where it still has our text (or the seed has not run)',
  coalesce((select (body like '%offered in the booking request form%' and body like '%which games you have seen%' and body not like '%browse several cars or stay a while%')::text
              from site_content_blocks where block_key = 'legal.privacy' and body like '%Discount games are shown%'), 'true'), 'true');

-- ================================================================ 5. the card pack and the rare prizes (0081, later the same day)
update program_settings set game_prizes = default;
select test.eq('the card pack is one of the games (0100: eleven), on at the same weight', array_to_string(app.game_kinds(), ' ') || ' | ' || ((app.settings()).game_weights ->> 'pack'),
  'wheel scratch blackjack cups plinko pack coin dice slots drop mystery | 1');
delete from app.rate_limit_hits where key like 'game-%';
do $$
declare i int; v_seen text[] := '{}'; r jsonb;
begin
  for i in 1..11 loop
    delete from app.rate_limit_hits where key like 'game-%';
    r := test.g2start('six', v_seen);
    v_seen := v_seen || (r ->> 'game');
  end loop;
end $$;
select test.eq('eleven shows: all eleven games, the pack among them', (select count(distinct game) || ' ' || bool_or(game = 'pack') from game_plays where visitor_id = test.g2vid('six')), '11 true');
select test.eq('the chances add up to 100', (select sum((x ->> 'weight')::numeric) from jsonb_array_elements((app.settings()).game_prizes) x), 100.0);
select test.eq('20,000 draws stay within statistical bounds of the table (about 4 standard deviations)',
  (select string_agg(k || '=' || (n between lo and hi)::text, ' ' order by k) from (
     select k, count(*) n from (select app.game_draw((app.settings()).game_prizes) ->> 'key' as k from generate_series(1, 20000)) x group by k) c
   join (values ('pct5', 10530, 11070), ('pct10', 4755, 5245), ('replay', 2780, 3220), ('pct15', 690, 910), ('amt50', 145, 260), ('pct25', 75, 170), ('amt100', 25, 95), ('day1', 3, 45)) b(kk, lo, hi) on b.kk = c.k),
  'amt100=true amt50=true day1=true pct10=true pct15=true pct25=true pct5=true replay=true');
select test.eq('the prize table is checked: free days with a longer minimum, a cap only on a percentage or free days, one kind',
  app.game_prizes_ok('[{"key": "d", "free_days": 1, "min_days": 3, "weight": 1}]')::text || app.game_prizes_ok('[{"key": "d", "free_days": 1, "weight": 1}]')::text
  || app.game_prizes_ok('[{"key": "d", "free_days": 3, "min_days": 3, "weight": 1}]')::text || app.game_prizes_ok('[{"key": "a", "amount_cents": 5000, "max_cents": 100, "weight": 1}]')::text
  || app.game_prizes_ok('[{"key": "p", "percent_bps": 2500, "max_cents": 15000, "weight": 1}]')::text || app.game_prizes_ok('[{"key": "p", "percent_bps": 2500, "free_days": 1, "min_days": 3, "weight": 1}]')::text,
  'truefalsefalsefalsetruefalse');
select test.eq('words: the label, the slice, what it applies to', app.game_prize_label('{"free_days": 1}') || ' | ' || app.game_prize_short('{"free_days": 1}') || ' | '
  || app.game_prize_applies('{"free_days": 1, "min_days": 3, "max_cents": 15000}') || ' | ' || app.game_prize_applies('{"percent_bps": 2500, "max_cents": 15000}') || ' | ' || app.game_prize_applies('{"percent_bps": 500}'),
  '1 free day | FREE | one day of the rental charge (the booking''s average day) of a rental of 3 days or more, up to $150.00 | the rental charge, up to $150.00 | the rental charge, up to $75.00');

-- the code applies its own cap and minimum wherever a booking is priced
insert into promo_codes (code, percent_bps, max_discount_cents, source) values ('G2-PCT25', 2500, 15000, 'test');
insert into promo_codes (code, amount_cents, min_rental_days, source) values ('G2-AMT100', 10000, 4, 'test');
insert into promo_codes (code, free_days, min_rental_days, max_discount_cents, source) values ('G2-DAY1', 1, 3, 15000, 'test');
create or replace function test.pd(p_code text, p_base bigint, p_days integer) returns bigint language sql as $$
  select app.promo_discount_cents((select id from promo_codes where code = p_code), p_base, p_days) $$;
select test.eq('caps: 25% off is $150 at most, a free day is the average day up to $150',
  test.pd('G2-PCT25', 40000, 4) || ' ' || test.pd('G2-PCT25', 100000, 5) || ' ' || test.pd('G2-DAY1', 40000, 4) || ' ' || test.pd('G2-DAY1', 100000, 4) || ' ' || test.pd('G2-DAY1', 30001, 3),
  '10000 15000 10000 15000 10000');
select test.eq('minimum days: $100 off from 4 days, the free day from 3; never more than the charge',
  test.pd('G2-AMT100', 30000, 3) || ' ' || test.pd('G2-AMT100', 30000, 4) || ' ' || test.pd('G2-DAY1', 20000, 2) || ' ' || test.pd('G2-AMT100', 8000, 4), '0 10000 0 8000');
select test.eq('a free day without the booking''s length takes nothing; the two-argument form still works for the others',
  app.promo_discount_cents((select id from promo_codes where code = 'G2-DAY1'), 40000) || ' ' || app.promo_discount_cents((select id from promo_codes where code = 'G2-PCT25'), 40000), '0 10000');
select test.throws('a code is one kind only', $$insert into promo_codes (code, percent_bps, free_days, source) values ('G2-BAD', 500, 1, 'test')$$, 'promo_codes_one_kind');
select test.eq('the prices of a booking pass its length', (select bool_and(pg_get_functiondef(f) like '%promo_discount_cents(%, v_%days)%') from unnest(array[
  'app.price_lines(jsonb)'::regprocedure, 'app.preview_extension(uuid, timestamptz, timestamptz)'::regprocedure, 'app.calendar_preview_change(uuid, jsonb, timestamptz)'::regprocedure]) f), true);

-- a rare prize won and claimed: the code carries the free day, its minimum and its cap; the browser hears it is rare
delete from app.rate_limit_hits where key like 'game-%';
insert into g2 values (30, test.g2start('rare'));
update game_plays set prize = '{"key": "day1", "free_days": 1, "min_days": 3, "max_cents": 15000, "weight": 0.1}' where token = (select v ->> 'token' from g2 where n = 30);
select test.eq('the browser hears the prize is rare (1 in 100 or less), and a common one is not',
  (test.g2start('rare') -> 'prize' ->> 'rare') || ' ' || (test.g2start('rare') -> 'prize' ->> 'label') || ' ' || (select (v -> 'prize' ->> 'rare') from g2 where n = 1), 'true 1 free day false');
insert into g2 values (31, app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from g2 where n = 30), 'first_name', 'Rae', 'email', 'g2.rare@example.test')));
select test.eq('claimed: the words and the code of the free day',
  (select (v ->> 'prize_label') || ' | ' || (v ->> 'applies_to') from g2 where n = 31) || ' | '
  || (select coalesce(pc.free_days::text, '-') || ' ' || coalesce(pc.min_rental_days::text, '-') || ' ' || coalesce(pc.max_discount_cents::text, '-') || ' ' || coalesce(pc.percent_bps::text, '-')
        from promo_codes pc where pc.code = (select v ->> 'code' from g2 where n = 31)),
  '1 free day | one day of the rental charge (the booking''s average day) of a rental of 3 days or more, up to $150.00 | 1 3 15000 -');
select test.eq('its email says the same', (select (x ->> 'prize_label') || ' | ' || (x ->> 'discount_applies_to') from (select app.notification_payload('renter_game_code',
  (select e from app_events e where e.code = 'renter_game_code' and e.entity_id = (select id from game_claims where email = 'g2.rare@example.test') limit 1), '{}'::jsonb) as x) y),
  '1 free day | one day of the rental charge (the booking''s average day) of a rental of 3 days or more, up to $150.00');
select test.eq('Admin: the report carries the average booking for the expected cost', (select (r -> 'cost_basis' ?& array['source', 'charge_cents', 'days'])::text
  from (select app.game_report(test.id('g2_admin')) as r) x), 'true');
