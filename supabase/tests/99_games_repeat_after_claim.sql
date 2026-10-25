-- 99: people who win a prize can play again on a later visit (migration 0172). The wait after a claim
-- (game_replay_after_claim_days, 1 by default; 0: one code ever): within it no game and no new code for the same browser,
-- email, phone or account, with again_after and words saying when; after it a fresh play and a new code for the same
-- person; plays from before the claim are left behind; a visitor known only through their own claim is not "known",
-- one known by a booking request, the chat or as a renter still is; a repeat claim joins the open Sales task; the leads
-- show the same person; the report counts people beside claims; an account opened later takes every claim of its email;
-- the terms. Fixtures start with "gra".
select test.suite('99 games repeat after claim');

select test.mk_user('gra_admin', 'admin');
select test.mk_renter('gra_rita');
select test.mk_renter('gra_bea');
create or replace function test.gravid(p text) returns uuid language sql immutable as $$ select md5('gravid:' || p)::uuid $$;
create or replace function test.grasid(p text) returns uuid language sql immutable as $$ select md5('grasid:' || p)::uuid $$;
create or replace function test.grastart(p text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select public.game_start(jsonb_build_object('vid', test.gravid(p), 'sid', test.grasid(p), 'device', 'phone', 'path', '/cars/gra-car', 'trigger', 'pages', 'seen', '[]'::jsonb) || p_extra) $$;
create or replace function test.graclaim_token(p_token text, p text, p_email text, p_phone text default null, p_cars integer default 5) returns jsonb language sql as $$
  select app.server_game_claim(jsonb_build_object('token', p_token, 'sid', test.grasid(p), 'first_name', 'Gray ' || p, 'email', p_email, 'phone', p_phone,
    'cars_viewed', p_cars, 'pages_viewed', p_cars + 2, 'seconds', 120)) $$;
create or replace function test.graclaim(p text, p_email text, p_phone text default null, p_cars integer default 5) returns jsonb language sql as $$
  select test.graclaim_token(test.grastart(p) ->> 'token', p, p_email, p_phone, p_cars) $$;
-- a day and an hour go by for everything this browser and this email claimed
create or replace function test.graback(p text, p_email text) returns void language sql as $$
  update game_claims set created_at = created_at - interval '25 hours' where visitor_id = test.gravid(p) or email = p_email $$;
delete from app.rate_limit_hits where key like 'game-%';
-- the plays below are claimed whatever they drew: without the replay prize (0171: never claimed)
update program_settings set game_prizes = app.game_prizes_real(game_prizes);
-- the marketing wording as the seed stores it (the content seed does not run in the tests)
insert into site_content_blocks (block_key, page, kind, body, data)
values ('legal.marketing_opt_in', 'legal', 'text', 'Yes, send me CarmaCars offers and news by email and text message. I can unsubscribe at any time. Sent by CarmaCars{{mailingAddress}}, {{contactEmail}}.', '{"version": "October 19, 2026"}')
on conflict (block_key) do nothing;
create temp table gra (n text primary key, v jsonb);
grant all on gra to public;

-- ================================================================ 1. the setting
select test.eq('the wait after a claim: 1 day by default', (app.settings()).game_replay_after_claim_days, 1);
select test.throws('from 0 to 90 days', $$update program_settings set game_replay_after_claim_days = 91$$, 'check');
select test.eq('the game''s terms: one code a day per person',
  app.game_terms_text() like '%One use, on one booking, within 7 days. One code a day per person, email, phone and device. Not combinable with other promo codes.', true);
select test.eq('one claim per email, phone and device is no longer a unique index (the code still is)',
  (select string_agg(indexname, ' ' order by indexname) from pg_indexes where tablename = 'game_claims' and indexdef like 'CREATE UNIQUE%'),
  'game_claims_pkey game_claims_play_id_key game_claims_promo_code_id_key');

-- ================================================================ 2. within the wait
insert into gra values ('a1', test.graclaim('a', 'gra.ann@example.test', '647-555-0172'));
select test.eq('the claim: a code, and when they can play again (a day later)',
  (select (v ->> 'ok') || ' ' || ((v ->> 'again_after')::timestamptz = c.created_at + interval '1 day')::text from gra, game_claims c where n = 'a1' and c.email = 'gra.ann@example.test'), 'true true');
select test.eq('the same browser: no game for now, and again_after',
  (select (r ->> 'reason') || ' ' || ((r ->> 'again_after')::timestamptz = (select created_at + interval '1 day' from game_claims where email = 'gra.ann@example.test'))::text
     from (select test.grastart('a') r) x), 'claimed true');
insert into gra values ('b1', test.graclaim('b', 'gra.ann@example.test'));
select test.eq('the same email on another browser: refused with the day they can play again, and the code goes to that inbox again',
  (select (v ->> 'error') || ' ' || (v ->> 'message' like 'This email already has a code. We sent it to that inbox again. You can play again after %')::text || ' ' || (v ? 'again_after')::text || ' ' || (v ? 'code')::text from gra where n = 'b1')
  || ' ' || (select count(*) from app_events where code = 'renter_game_code' and entity_id = (select id from game_claims where email = 'gra.ann@example.test')), 'email_used true true false 2');
select test.eq('the same phone with another email: refused',
  (select (r ->> 'error') || ' ' || (r ->> 'message' like 'This mobile number already has a code. You can play again after %')::text from (select test.graclaim('c', 'gra.other@example.test', '+1 647 555 0172') r) x), 'phone_used true');
insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at) values (test.gravid('a'), 'dice', '{"key": "pct10", "percent_bps": 1000, "weight": 25}', '/', 'pages', now());
select test.eq('the same browser with another email (a play it still holds): refused',
  (select (r ->> 'error') || ' ' || (r ->> 'message' like 'A code was already claimed on this device. You can play again after %')::text
     from (select test.graclaim_token((select token from game_plays where visitor_id = test.gravid('a') and claimed_at is null), 'a', 'gra.third@example.test') r) x), 'device_used true');
delete from game_plays where visitor_id = test.gravid('a') and claimed_at is null;
select test.eq('still one claim for that person', (select count(*) from game_claims where email = 'gra.ann@example.test' or visitor_id = test.gravid('a')), 1::bigint);

-- ================================================================ 3. after the wait: a fresh play and a new code
select test.graback('a', 'gra.ann@example.test');
select test.eq('known only through their own claim (the claim''s email on their visit, identified by the game): not "known"',
  (select string_agg(coalesce(identified_by, '-') || ' ' || coalesce(known_email, '-'), ', ') from visitor_sessions where visitor_id = test.gravid('a'))
  || ' ' || app.game_known_visitor(test.gravid('a'))::text, 'game gra.ann@example.test false');
insert into gra values ('a2', test.grastart('a'));
select test.eq('a day later the same browser plays again: a new play, never one from before the claim, not shown yet',
  (select (v ->> 'ok') || ' ' || coalesce(v ->> 'saved', 'none') || ' ' || (v ->> 'revealed') || ' '
          || ((select created_at from game_plays where token = v ->> 'token') > (select max(created_at) from game_claims where visitor_id = test.gravid('a')))::text
     from gra where n = 'a2'), 'true none false true');
insert into gra values ('a3', test.graclaim_token((select v ->> 'token' from gra where n = 'a2'), 'a', 'gra.ann@example.test', '647-555-0172'));
select test.eq('and wins another code with the same email, phone and browser',
  (select v ->> 'ok' from gra where n = 'a3') || ' ' || (select count(*) from game_claims where email = 'gra.ann@example.test') || ' '
  || (select count(distinct promo_code_id) from game_claims where email = 'gra.ann@example.test'), 'true 2 2');
select test.eq('each code single use, on one booking, its own 7 days; the earlier one still valid',
  (select string_agg(format('%s %s %s', pc.max_uses, pc.is_active, (pc.valid_until > now())), ', ' order by c.created_at)
     from game_claims c join promo_codes pc on pc.id = c.promo_code_id where c.email = 'gra.ann@example.test'), '1 t t, 1 t t');
select test.eq('then the wait again', test.grastart('a') ->> 'reason', 'claimed');

-- the Sales task: one for the person while it is open, with the new code in it
select test.eq('the repeat claim joins the open Sales task (no second task), which names the new code',
  (select count(distinct task_id) from game_claims where email = 'gra.ann@example.test')::text || ' '
  || (select count(*) from tasks where task_type = 'game_lead_follow_up' and related_id in (select id from game_claims where email = 'gra.ann@example.test'))::text || ' '
  || (select (t.detail like '%Another code: ' || (select v ->> 'code' from gra where n = 'a3') || '%')::text from tasks t where t.id = (select task_id from game_claims where email = 'gra.ann@example.test' limit 1)),
  '1 1 true');
-- the task done: the next claim raises a new one
update tasks set status = 'done', completed_at = now() where id = (select task_id from game_claims where email = 'gra.ann@example.test' limit 1);
select test.graback('a', 'gra.ann@example.test');
insert into gra values ('a4', test.graclaim('a', 'gra.ann@example.test'));
select test.eq('once that task is done, the next claim raises its own',
  (select v ->> 'ok' from gra where n = 'a4') || ' ' || (select count(distinct task_id) from game_claims where email = 'gra.ann@example.test'), 'true 2');

-- the leads: the same person
select test.eq('the leads: the 1st, 2nd and 3rd code of the same person',
  (select string_agg((r ->> 'claim_no') || '/' || (r ->> 'claims_total'), ' ' order by (r ->> 'claim_no')::int)
     from jsonb_array_elements(app.game_leads(test.id('gra_admin'), '{"q": "gra.ann@example.test"}') -> 'rows') r), '1/3 2/3 3/3');
select test.eq('the report: every claim counted, and the people beside them',
  (select ((r ->> 'claims')::int - (r ->> 'people')::int >= 2)::text from (select app.game_report(test.id('gra_admin'), '{"days": 30}') r) x), 'true');

-- ================================================================ 4. known otherwise: as before
-- a booking request
select test.graclaim('req', 'gra.req@example.test');
insert into visitor_sessions (id, visitor_id, known_email, identified_by) values (gen_random_uuid(), test.gravid('req'), 'gra.req@example.test', 'request');
select test.graback('req', 'gra.req@example.test');
select test.eq('known through a booking request: no new game on the site after the wait', test.grastart('req') ->> 'reason', 'known');
-- the chat, with another email
select test.graclaim('chat', 'gra.chat@example.test');
insert into visitor_sessions (id, visitor_id, known_email, identified_by) values (gen_random_uuid(), test.gravid('chat'), 'gra.chat.other@example.test', 'chat');
select test.graback('chat', 'gra.chat@example.test');
select test.eq('known through the chat: no new game', test.grastart('chat') ->> 'reason', 'known');
-- a renter's email: the claim links the renter
select test.graclaim('rit', 'gra_rita@example.test');
select test.graback('rit', 'gra_rita@example.test');
select test.eq('a renter (the claim''s email is a renter''s): no new game on the site', test.grastart('rit') ->> 'reason', 'known');
-- the link of the code email (identified by the email link, with the claim's email): still only the game
select test.graclaim('link', 'gra.link@example.test');
insert into visitor_sessions (id, visitor_id, known_email, identified_by) values (gen_random_uuid(), test.gravid('link'), 'gra.link@example.test', 'email_link');
select test.graback('link', 'gra.link@example.test');
select test.eq('known through the code email''s link: plays again', test.grastart('link') ->> 'ok', 'true');
-- the bare account the game's own form opened for a brand-new email (contact capture 0090): the claim links its renter
insert into users (id, email, full_name) values (test.id('gra_cap'), 'gra.cap@example.test', 'Cap');
insert into user_roles (user_id, role) values (test.id('gra_cap'), 'renter');
insert into renters (id, user_id, legal_name, email) values (test.id('renter:gra_cap'), test.id('gra_cap'), 'Cap', 'gra.cap@example.test');
insert into capture_accounts (user_id, opened_by_capture, brand_new, opened_form, visitor_id) values (test.id('gra_cap'), true, true, 'game', test.gravid('cap'));
select test.graclaim('cap', 'gra.cap@example.test');
select test.graback('cap', 'gra.cap@example.test');
select test.eq('the renter the game''s own form opened (no booking) is not "a renter": plays again',
  (select string_agg(distinct (renter_id = test.id('renter:gra_cap'))::text, ' ') from visitor_sessions where visitor_id = test.gravid('cap')) || ' ' || (test.grastart('cap') ->> 'ok'), 'true true');
update capture_accounts set opened_form = 'chat' where user_id = test.id('gra_cap');
select test.eq('opened by the chat instead: a renter known otherwise, no new game', app.game_known_visitor(test.gravid('cap')), true);
-- an email typed somewhere else before the claim (the visit already known): stays known
insert into visitor_sessions (id, visitor_id, known_email) values (test.grasid('pre'), test.gravid('pre'), 'gra.pre@example.test');
insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at) values (test.gravid('pre'), 'coin', '{"key": "pct5", "percent_bps": 500, "weight": 54}', '/', 'pages', now());
select test.eq('a visit already known by email keeps its saved prize and claims it',
  test.graclaim_token((select token from game_plays where visitor_id = test.gravid('pre')), 'pre', 'gra.pre@example.test') ->> 'ok', 'true');
select test.graback('pre', 'gra.pre@example.test');
select test.eq('the claim does not say the game identified a visit already known: no new game after the wait',
  (select coalesce(identified_by, '-') from visitor_sessions where id = test.grasid('pre')) || ' ' || (test.grastart('pre') ->> 'reason'), '- known');

-- ================================================================ 5. a replay prize from before the claim stays behind
insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at, created_at)
values (test.gravid('rp'), 'wheel', '{"key": "replay", "replay": true, "weight": 15}', '/', 'pages', now() - interval '3 days', now() - interval '3 days');
insert into game_plays (visitor_id, game, prize, path, trigger, revealed_at, created_at)
values (test.gravid('rp'), 'coin', '{"key": "pct10", "percent_bps": 1000, "weight": 25}', '/', 'pages', now(), now());
select test.graclaim_token((select token from game_plays where visitor_id = test.gravid('rp') and game = 'coin'), 'rp', 'gra.rp@example.test');
update game_claims set created_at = now() - interval '2 days' where email = 'gra.rp@example.test';
select test.eq('after the wait, a replay prize won before the claim is not played again; a fresh play instead',
  (test.grastart('rp', jsonb_build_object('replay_of', (select token from game_plays where visitor_id = test.gravid('rp') and game = 'wheel'))) ->> 'reason') || ' '
  || (select coalesce(r ->> 'saved', 'none') || ' ' || (r ->> 'revealed') from (select test.grastart('rp') r) x), 'replay_used none false');

-- ================================================================ 6. the request-to-book form: the account's claims
insert into gra values ('bk1', public.server_game_start(jsonb_build_object('vid', test.gravid('bea'), 'context', 'booking'), test.id('gra_bea')));
insert into gra values ('bk2', app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from gra where n = 'bk1'), 'first_name', ''), test.id('gra_bea')));
select test.eq('a renter claims in the request-to-book form, then waits a day there too (on any browser)',
  (select v ->> 'ok' from gra where n = 'bk2') || ' '
  || (select (r ->> 'reason') || ' ' || (r ? 'again_after')::text from (select public.server_game_start(jsonb_build_object('vid', test.gravid('bea2'), 'context', 'booking'), test.id('gra_bea')) r) x),
  'true claimed true');
insert into game_plays (visitor_id, game, prize, path, trigger, context, user_id, revealed_at)
values (test.gravid('bea3'), 'dice', '{"key": "pct10", "percent_bps": 1000, "weight": 25}', '/book/gra-car', 'booking', 'booking', test.id('gra_bea'), now());
select test.eq('the account cannot claim another play within the wait',
  (select (r ->> 'error') || ' ' || (r ->> 'message' like 'Your account already has a code. You can play again after %')::text
     from (select app.server_game_claim(jsonb_build_object('token', (select token from game_plays where user_id = test.id('gra_bea') and claimed_at is null order by created_at desc limit 1), 'first_name', ''), test.id('gra_bea')) r) x),
  'claimed true');
update game_claims set created_at = created_at - interval '25 hours' where email = 'gra_bea@example.test';
insert into gra values ('bk4', public.server_game_start(jsonb_build_object('vid', test.gravid('bea2'), 'context', 'booking'), test.id('gra_bea')));
insert into gra values ('bk5', app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from gra where n = 'bk4'), 'first_name', ''), test.id('gra_bea')));
select test.eq('a day later: a game in the form again, and a second code',
  (select v ->> 'ok' from gra where n = 'bk4') || ' ' || (select v ->> 'ok' from gra where n = 'bk5') || ' '
  || (select count(*) from game_claims where email = 'gra_bea@example.test'), 'true true 2');

-- ================================================================ 7. an account opened later takes every claim of its email
select test.graclaim('late', 'gra_late@example.test');
select test.graback('late', 'gra_late@example.test');
select app.server_game_claim(jsonb_build_object('token', test.grastart('late') ->> 'token', 'sid', test.grasid('late'), 'first_name', 'Lee', 'email', 'gra_late@example.test', 'marketing', true));
select test.mk_user('gra_late', 'renter');
select test.eq('an account opened later: both claims linked, the consent of the latest claim that gave it',
  (select count(*) from game_claims where email = 'gra_late@example.test' and user_id = test.id('gra_late'))::text || ' '
  || (select marketing_opt_in::text from users where id = test.id('gra_late')), '2 true');

-- ================================================================ 8. the setting at 0: one code ever, as before
update program_settings set game_replay_after_claim_days = 0;
select test.eq('at 0: no game again, with no day to come back',
  (select (r ->> 'reason') || ' ' || (r ? 'again_after')::text from (select test.grastart('link') r) x), 'claimed false');
select test.eq('at 0: the same email is refused for good ("One per person.")',
  (select (r ->> 'error') || ' ' || (r ->> 'message') from (select test.graclaim('zero', 'gra.ann@example.test') r) x),
  'email_used This email already has a code. We sent it to that inbox again. One per person.');
select test.eq('at 0: the terms say one per person', app.game_terms_text() like '%within 7 days. One per person, email, phone and device. Not combinable%', true);
update program_settings set game_replay_after_claim_days = 3;
select test.eq('at 3: the terms say every 3 days, and a claim a day old still waits',
  (app.game_terms_text() like '%One code every 3 days per person, email, phone and device.%')::text || ' ' || (test.grastart('link') ->> 'reason'), 'true claimed');
update program_settings set game_replay_after_claim_days = 1;

-- ================================================================ 9. a fresh play draws from the whole table
update program_settings set game_prizes = default;
select test.eq('300 new visitors: another go comes up among their first prizes (0171 meant it; it never did)',
  (select count(*) filter (where (r -> 'prize' ->> 'replay')::boolean) between 10 and 100 from (select test.grastart('fresh' || i) r from generate_series(1, 300) i) x), true);
delete from app.rate_limit_hits where key like 'game-%';

-- ================================================================ 10. privileges
select test.eq('privileges: the new checks are the server''s',
  has_function_privilege('anon', 'app.game_again_after(timestamptz)', 'execute')::text || ' ' || has_function_privilege('authenticated', 'app.game_used(text, text, timestamptz)', 'execute')::text || ' '
  || has_function_privilege('anon', 'app.game_known_visitor(uuid)', 'execute')::text || ' ' || has_function_privilege('service_role', 'app.game_again_words(timestamptz)', 'execute')::text,
  'false false false true');
