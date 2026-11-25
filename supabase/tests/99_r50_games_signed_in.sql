-- 99: the discount game on the site is for signed-in people too (migration 5040). A signed-in renter plays on the site and
-- claims with their account (no name or email typed): the code is tied to their user and renter and shows in My discounts;
-- the wait after a claim counts the account; they are never "known" away; Play again stays for visitors who are not signed
-- in. Staff and admin play the preview but no code is ever issued, enforced in the database. Fixtures start with "gsi".
select test.suite('99 r50 games signed in');

select test.mk_user('gsi_admin', 'admin');
select test.mk_user('gsi_cs', 'va', 'cs');
select test.mk_user('gsi_sales', 'va', 'sales');
select test.mk_user('gsi_field', 'field');
select test.mk_renter('gsi_rita');
select test.mk_renter('gsi_ben');
create or replace function test.sgvid(p text) returns uuid language sql immutable as $$ select md5('sgvid:' || p)::uuid $$;
create or replace function test.sgstart(p text, p_user uuid default null, p_extra jsonb default '{}') returns jsonb language sql as $$
  select public.server_game_start(jsonb_build_object('vid', test.sgvid(p), 'device', 'desktop', 'path', '/cars/sg-car', 'trigger', 'pages', 'seen', '[]'::jsonb) || p_extra, p_user) $$;
create or replace function test.sgclaim(p_token text, p_user uuid, p_extra jsonb default '{}') returns jsonb language sql as $$
  select app.server_game_claim(jsonb_build_object('token', p_token) || p_extra, p_user) $$;
delete from app.rate_limit_hits where key like 'game-%';
delete from game_claims; delete from game_plays;
-- the plays below are claimed whatever they drew: without the replay prize
update program_settings set game_prizes = app.game_prizes_real(game_prizes);
create temp table sg (n text primary key, v jsonb);
grant all on sg to public;

-- ================================================================ 1. a signed-in renter plays on the site
insert into sg values ('r1', test.sgstart('r1', test.id('gsi_rita')));
select test.eq('a signed-in renter plays on the site, with their account named',
  (select (v ->> 'ok') || ' ' || (v ->> 'context') || ' ' || (v -> 'account' ->> 'email') || ' ' || (v -> 'account' ->> 'first') from sg where n = 'r1'), 'true site gsi_rita@example.test Gsi');
select test.eq('the play is the site''s, with the account', (select context || ' ' || trigger || ' ' || (user_id = test.id('gsi_rita')) from game_plays where token = (select v ->> 'token' from sg where n = 'r1')), 'site pages true');
select test.eq('the same account on the same browser again: the same play', (test.sgstart('r1', test.id('gsi_rita')) ->> 'token') = (select v ->> 'token' from sg where n = 'r1'), true);
select test.eq('Play again on a saved prize is for visitors who are not signed in', (test.sgstart('r1', test.id('gsi_rita'), jsonb_build_object('again_of', (select v ->> 'token' from sg where n = 'r1'))) ->> 'reason'), 'again_not_found');
-- a visitor known by their email (a chat, a link) who is signed in is still welcome: the account is the identity
insert into visitor_sessions (id, visitor_id, known_email, identified_by, user_id) values (md5('sgsid:known')::uuid, test.sgvid('known'), 'gsi_ben@example.test', 'email_link', test.id('gsi_ben'));
select test.eq('a signed-in renter on a browser the site knows still plays', test.sgstart('known', test.id('gsi_ben')) ->> 'ok', 'true');
select test.eq('the same browser not signed in is still left alone (known)', public.game_start(jsonb_build_object('vid', test.sgvid('known'))) ->> 'reason', 'known');
select test.eq('a visitor not signed in still plays on the site', public.game_start(jsonb_build_object('vid', test.sgvid('anon'), 'device', 'phone', 'path', '/', 'trigger', 'pages')) ->> 'ok', 'true');
select test.login(test.id('gsi_rita'));
select test.eq('the browser''s own call, signed in, plays too', public.game_start(jsonb_build_object('vid', test.sgvid('r2'), 'device', 'phone', 'path', '/', 'trigger', 'pages')) ->> 'ok', 'true');
select test.logout();

-- ================================================================ 2. one tap: the claim uses the account
insert into sg values ('c1', test.sgclaim((select v ->> 'token' from sg where n = 'r1'), test.id('gsi_rita')));
select test.eq('a claim with only the token: a code, the account''s email, "Rita" style first name from the account',
  (select (v ->> 'ok') || ' ' || (v ->> 'email') || ' ' || (length(v ->> 'code') > 0)::text from sg where n = 'c1'), 'true gsi_rita@example.test true');
select test.eq('the claim is tied to the user and the renter, with the account''s first name',
  (select (user_id = test.id('gsi_rita'))::text || ' ' || (renter_id = test.id('renter:gsi_rita'))::text || ' ' || first_name || ' ' || email from game_claims where email = 'gsi_rita@example.test'),
  'true true Gsi gsi_rita@example.test');
select test.eq('a second tap, with another email typed, makes no second code',
  (select (v ->> 'ok') || ' ' || (v ? 'code')::text from (select test.sgclaim((select v ->> 'token' from sg where n = 'r1'), test.id('gsi_rita'), '{"email": "other@example.test"}') v) x), 'false false');
select test.eq('only one claim exists for the account', (select count(*) from game_claims where user_id = test.id('gsi_rita')), 1::bigint);
select test.eq('the code is in My discounts (account and rewards), as a game prize, open',
  (select (d ->> 'code') = (select v ->> 'code' from sg where n = 'c1') and d ->> 'kind' = 'game' and d ->> 'status' = 'open'
     from jsonb_array_elements(app.my_discounts(test.id('gsi_rita'))) d limit 1), true);
select test.eq('the code is single use for this renter and expires', (select pc.max_uses || ' ' || pc.once_per_renter || ' ' || (pc.valid_until > now())::text from promo_codes pc join game_claims c on c.promo_code_id = pc.id where c.user_id = test.id('gsi_rita')), '1 true true');
select test.eq('the account on another browser: no game, with again_after (the wait after a claim)',
  (select (r ->> 'reason') || ' ' || (r ? 'again_after')::text from (select test.sgstart('r3', test.id('gsi_rita')) r) x), 'claimed true');
select test.eq('another renter is not held back', test.sgstart('r4', test.id('gsi_ben')) ->> 'ok', 'true');

-- ================================================================ 3. staff see it and play it, and never get a code
select test.eq('admin, a sales rep, a support rep and field staff play the site''s game',
  (test.sgstart('a1', test.id('gsi_admin')) ->> 'ok') || ' ' || (test.sgstart('a2', test.id('gsi_sales')) ->> 'ok') || ' ' || (test.sgstart('a3', test.id('gsi_cs')) ->> 'ok') || ' ' || (test.sgstart('a4', test.id('gsi_field')) ->> 'ok'),
  'true true true true');
select test.eq('staff''s play carries their account', (test.sgstart('a1', test.id('gsi_admin')) -> 'account' ->> 'email'), 'gsi_admin@example.test');
select test.eq('the request-to-book form still turns staff away', test.sgstart('b1', test.id('gsi_admin'), '{"context": "booking"}') ->> 'reason', 'staff');
select count(*) as before_claims, (select count(*) from promo_codes where source = 'discount_game') as before_codes, (select count(*) from leads where source = 'discount_game') as before_leads from game_claims \gset
select test.eq('staff''s claim says it is a preview, and nothing is made',
  (select (v ->> 'error') || ' | ' || (v ->> 'message') from (select test.sgclaim(test.sgstart('a1', test.id('gsi_admin')) ->> 'token', test.id('gsi_admin'), '{"first_name": "Admin", "email": "gsi_admin@example.test"}') v) x),
  'staff | Staff can''t use game codes: this is a preview of what visitors see.');
select test.eq('every staff role gets the same words and no code',
  (select string_agg((test.sgclaim(test.sgstart('a' || n, u) ->> 'token', u) ->> 'error'), ' ' order by n) from (values (2, test.id('gsi_sales')), (3, test.id('gsi_cs')), (4, test.id('gsi_field'))) t(n, u)), 'staff staff staff');
select test.eq('no claim, no promo code and no lead were made for staff',
  (select (count(*) - :before_claims) from game_claims) || ' ' || ((select count(*) from promo_codes where source = 'discount_game') - :before_codes) || ' ' || ((select count(*) from leads where source = 'discount_game') - :before_leads), '0 0 0');
select test.eq('staff''s plays stay unclaimed', (select count(*) from game_plays where user_id in (test.id('gsi_admin'), test.id('gsi_sales'), test.id('gsi_cs'), test.id('gsi_field')) and claimed_at is not null), 0::bigint);
select test.eq('staff can play again and again: no wait, no claim to wait for', test.sgstart('a1', test.id('gsi_admin')) ->> 'ok', 'true');
select test.eq('staff cannot get a code by typing a visitor''s email either',
  test.sgclaim(test.sgstart('a1', test.id('gsi_admin')) ->> 'token', test.id('gsi_admin'), '{"first_name": "X", "email": "someone@example.test"}') ->> 'error', 'staff');

-- ================================================================ 4. the rest is as before
select test.eq('a play that does not exist is refused for a signed-in renter', test.sgclaim('nope', test.id('gsi_ben')) ->> 'error', 'not_found');
select test.eq('a visitor not signed in still claims with a name and an email',
  (select (r ->> 'ok') from (select app.server_game_claim(jsonb_build_object('token', public.game_start(jsonb_build_object('vid', test.sgvid('anon2'), 'device', 'phone', 'path', '/', 'trigger', 'pages')) ->> 'token',
     'first_name', 'Ann', 'email', 'sg.ann@example.test')) r) x), 'true');
select test.eq('the staff check is the server''s only: not open to the browser',
  (select string_agg(has_function_privilege(r, 'app.game_is_staff(uuid)', 'execute')::text || has_function_privilege(r, 'app.server_game_claim(jsonb, uuid)', 'execute')::text, ' ' order by r)
     from unnest(array['anon', 'authenticated', 'service_role']) r), 'falsefalse falsefalse truetrue');
select test.eq('the new function has pg_temp last in its search_path', (select proconfig::text from pg_proc where oid = 'app.game_is_staff(uuid)'::regprocedure), '{"search_path=public, app, pg_temp"}');
