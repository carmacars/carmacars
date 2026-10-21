-- 51: discount games, sooner and again, and in the request-to-book form (migration 0076). The new settings and the
-- live values moved from the old defaults; the re-show with a game not seen yet (all five before one repeats, from the
-- browser's list and the server's plays), the same prize on every show (no new draw); the booking form: signed-in
-- renters may play and claim with their account's email, never staff, never after a claim, a visitor known by email
-- may; a dry check records nothing; privileges. Fixtures start with "g2".
select test.suite('51 discount games: timing, re-show, booking form');

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
select test.eq('sooner: 1 car page or 15 seconds, exit intent kept; again after 2 more car pages or 3 minutes; 3 a visit; the booking form on',
  (select format('%s/%s/%s %s/%s %s %s', game_trigger_car_pages, game_trigger_seconds, game_exit_intent, game_reshow_car_pages, game_reshow_seconds, game_max_per_visit, game_booking_offer)
     from (select (app.settings()).*) s), '1/15/t 2/180 3 t');
select test.eq('the column defaults are the new ones too',
  (select string_agg(column_name || '=' || column_default, ' ' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('game_trigger_car_pages', 'game_trigger_seconds', 'game_reshow_car_pages', 'game_reshow_seconds', 'game_max_per_visit')),
  'game_max_per_visit=3 game_reshow_car_pages=2 game_reshow_seconds=180 game_trigger_car_pages=1 game_trigger_seconds=15');
select test.throws('a per-visit cap of 0 is refused', $$update program_settings set game_max_per_visit = 0$$, 'check');
select test.throws('a re-show after more than an hour is refused', $$update program_settings set game_reshow_seconds = 3601$$, 'check');
select test.eq('the odds, the cap and the code length are those of 0069',
  (select string_agg(app.game_prize_label(x) || ' ' || (x ->> 'weight'), ', ' order by o) || ' | ' || (app.settings()).game_max_discount_cents || ' ' || (app.settings()).game_code_valid_days
     from jsonb_array_elements((app.settings()).game_prizes) with ordinality t(x, o)), '5% off 70, 10% off 25, 15% off 4, $50 off 1 | 7500 7');

-- ================================================================ 2. the re-show: a game not seen yet, the same prize
create temp table g2 (n int primary key, v jsonb);
grant all on g2 to public;
insert into g2 values (1, test.g2start('a'));
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
select test.eq('closed and shown again five times: all five games before one repeats', (select count(distinct v ->> 'game') from g2 where n <= 5), 5::bigint);
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
update program_settings set game_weights = '{"wheel": 1, "scratch": 1, "blackjack": 1, "cups": 1, "plinko": 0}';
select test.eq('a game at weight 0 is never chosen, and the round is the four left',
  (select bool_and(app.game_next_kind(test.g2vid('w0'), null, '{}', null) <> 'plinko') from generate_series(1, 200))
  and app.game_next_kind(test.g2vid('w0'), null, array['wheel', 'scratch', 'blackjack'], 'blackjack') = 'cups', true);
update program_settings set game_weights = '{"wheel": 1, "scratch": 1, "blackjack": 1, "cups": 1, "plinko": 1}';
select test.eq('the reveal and the claim of a re-shown play work as before',
  (public.game_reveal((select v ->> 'token' from g2 where n = 6)))::text || ' ' || (app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from g2 where n = 6),
    'first_name', 'Gina', 'email', 'g2.a@example.test')) ->> 'ok'), 'true true');
select test.eq('after the claim: never again on this browser', test.g2start('a', array['wheel']) ->> 'reason', 'claimed');

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
select test.eq('one per person: the account cannot play again on any browser, nor claim again',
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
  || has_function_privilege('anon', 'app.game_start_core(jsonb, uuid)', 'execute')::text || has_function_privilege('anon', 'app.server_game_claim_pre0076(jsonb, uuid)', 'execute')::text,
  'falsefalsetruetruefalsefalse');
select test.eq('the privacy policy says when and where the games show where it still has our text (or the seed has not run)',
  coalesce((select (body like '%offered in the booking request form%' and body like '%which games you have seen%' and body not like '%browse several cars or stay a while%')::text
              from site_content_blocks where block_key = 'legal.privacy' and body like '%Discount games are shown%'), 'true'), 'true');
