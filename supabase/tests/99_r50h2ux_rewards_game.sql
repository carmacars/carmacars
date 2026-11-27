-- 99: R50 hotfix 2 UX (5151; docs/changes/2026-11-27-r50h2-ux.md). The games inside Rewards: a renter, an owner and a staff
-- member each play; the prize is points from the Admin's table, never a discount code; the day's cap (game_max_per_day, 1
-- when that is 0); the games' switch; points go to the renter rewards account once, and wait for one when there is none; a
-- test account plays but is never credited; only the portals the person belongs to. Fixtures "r5rg".
select test.suite('99 r50 hotfix 2 UX: the games inside Rewards');
select test.mk_renter('r5rg_renter');
select test.mk_owner('r5rg_owner');
select test.mk_user('r5rg_field', 'field');
select test.mk_user('r5rg_test', 'renter');
insert into renters (id, user_id, legal_name, email, identity_status) values (test.id('renter:r5rg_test'), test.id('r5rg_test'), 'R5rg Test', 'r5rg_test@example.test', 'pending');
update users set email = 'verify-r5rg@carmacars.ca' where id = test.id('r5rg_test');
create function test.r5rg(p_user text, p_action text, p_portal text) returns jsonb language sql as $$ select public.server_rewards_game(test.id(p_user), p_action, jsonb_build_object('portal', p_portal)) $$;
-- one play a day (the site's 0 means no cap there; Rewards then allows 1)
update program_settings set game_max_per_day = 0, game_enabled = true, rewards_game_on = true where id = (app.settings()).id;

-- ================================================================ 1. a renter
create temp table r5rg_codes as select count(*) n from promo_codes;
create temp table r5rg_p1 as select test.r5rg('r5rg_renter', 'play', 'renter') v;
select test.ok('the prize is from the points table', (select (v #>> '{prize,points}')::int in (select (x ->> 'points')::int from jsonb_array_elements((app.settings()).rewards_game_prizes) x) from r5rg_p1));
select test.ok('a game of the site''s games', (select v ->> 'game' in (select key from jsonb_each_text((app.settings()).game_weights) where value::numeric > 0) from r5rg_p1));
select test.eq('the points are on the renter''s rewards account', app.rewards_balance(test.id('renter:r5rg_renter')), (select (v #>> '{prize,points}')::int from r5rg_p1));
select test.eq('once, by its play', (select count(*) from reward_ledger where renter_id = test.id('renter:r5rg_renter') and action = 'game'), 1::bigint);
select test.eq('no discount code is made: no money leaves', (select count(*) from promo_codes), (select n from r5rg_codes));
select test.eq('no plays left today', (select (v ->> 'left')::int from r5rg_p1), 0);
select test.throws('a second play today is refused', $$select test.r5rg('r5rg_renter', 'play', 'renter')$$, '%come back tomorrow%');
select app.rewards_game_bank(test.id('r5rg_renter'));
select test.eq('banking again adds nothing', (select count(*) from reward_ledger where renter_id = test.id('renter:r5rg_renter') and action = 'game'), 1::bigint);
-- yesterday's play does not count today
update reward_game_plays set day = day - 1 where user_id = test.id('r5rg_renter');
select test.lives('a new day, a new play', $$select test.r5rg('r5rg_renter', 'play', 'renter')$$);
select test.eq('the points add up', app.rewards_balance(test.id('renter:r5rg_renter')), (select sum(points)::int from reward_game_plays where user_id = test.id('r5rg_renter')));

-- the cap follows game_max_per_day when it is set
update program_settings set game_max_per_day = 3 where id = (app.settings()).id;
select test.eq('with game_max_per_day 3, two more today', (test.r5rg('r5rg_renter', 'state', 'renter') ->> 'left')::int, 2);
update program_settings set game_max_per_day = 0 where id = (app.settings()).id;

-- ================================================================ 2. an owner and a staff member, with no renter account
create temp table r5rg_o as select test.r5rg('r5rg_owner', 'play', 'owner') v;
select test.ok('an owner plays from the owner portal', (select (v #>> '{prize,points}')::int > 0 from r5rg_o));
select test.eq('with no renter account the points wait on the play', (test.r5rg('r5rg_owner', 'state', 'owner') ->> 'waiting')::int, (select (v #>> '{prize,points}')::int from r5rg_o));
select test.lives('a field staff member plays from the staff portal', $$select test.r5rg('r5rg_field', 'play', 'staff')$$);
select test.throws('a staff member cannot play as an owner', $$select test.r5rg('r5rg_field', 'play', 'owner')$$, '%Not permitted%');
select test.throws('a renter cannot play as staff', $$select test.r5rg('r5rg_renter', 'state', 'staff')$$, '%Not permitted%');
-- the owner gets a renter account: the points join it by themselves
insert into renters (id, user_id, legal_name, email, identity_status) values (test.id('renter:r5rg_owner'), test.id('r5rg_owner'), 'R5rg Owner', 'r5rg_owner@example.test', 'pending');
select test.eq('nothing waits once the account exists', (test.r5rg('r5rg_owner', 'state', 'owner') ->> 'waiting')::int, 0);
select test.eq('the waiting points are on it', app.rewards_balance(test.id('renter:r5rg_owner')), (select (v #>> '{prize,points}')::int from r5rg_o));

-- ================================================================ 3. a test account and the switches
select test.lives('a test account plays', $$select test.r5rg('r5rg_test', 'play', 'renter')$$);
select test.eq('but is never credited', app.rewards_balance(test.id('renter:r5rg_test')), 0);
update reward_game_plays set day = day - 1 where user_id = test.id('r5rg_field');
update program_settings set rewards_game_on = false where id = (app.settings()).id;
select test.throws('off in Rewards: no play', $$select test.r5rg('r5rg_field', 'play', 'staff')$$, '%off%');
update program_settings set rewards_game_on = true, game_enabled = false where id = (app.settings()).id;
select test.throws('the games'' own switch holds too', $$select test.r5rg('r5rg_field', 'play', 'staff')$$, '%off%');
update program_settings set game_enabled = true where id = (app.settings()).id;
select test.throws('a prize table with a points value over 1000 is refused', $$update program_settings set rewards_game_prizes = '[{"key":"big","weight":1,"points":5000}]' where id = (app.settings()).id$$);
select test.ok('no browser role may call it', not has_function_privilege('authenticated', 'public.server_rewards_game(uuid, text, jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.server_rewards_game(uuid, text, jsonb)', 'execute'));
