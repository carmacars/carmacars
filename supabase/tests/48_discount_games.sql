-- 48: discount games (migration 0069). Settings and the prize table, the draw, who may play (signed in, known, claimed,
-- the same play again), the claim (one per email, phone and device, the code as a promo code: single use, expiry, the
-- cap, the minimum rental length, not with another code, owner sharing in the split), the lead on Live visitors, the
-- Sales task, consent (an existing account, an account opened later, never over an unsubscribe), the emails and the
-- reminder, the leads and the report for staff, the privacy and terms text, privileges. Fixtures start with "dg".
select test.suite('48 discount games');

select test.mk_user('dg_admin', 'admin');
select test.mk_user('dg_cs', 'va', 'cs');
select test.mk_user('dg_sales', 'va', 'sales');
select test.mk_user('dg_fin', 'va', 'finance');
select test.mk_owner('dg_own');
select test.mk_vehicle('DG1', 'dg_own');
select test.mk_renter('dg_rita');
select test.mk_renter('dg_ben');
create temp table s43 (k text primary key, v jsonb);
grant all on s43 to public;
create or replace function test.s43(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s43 where k = p_k $$;
create or replace function test.vid(p text) returns uuid language sql immutable as $$ select md5('dgvid:' || p)::uuid $$;
create or replace function test.dsid(p text) returns uuid language sql immutable as $$ select md5('dgsid:' || p)::uuid $$;
create or replace function test.gstart(p text) returns jsonb language sql as $$
  select public.game_start(jsonb_build_object('vid', test.vid(p), 'sid', test.dsid(p), 'device', 'phone', 'path', '/cars/dg-car', 'trigger', 'pages')) $$;
create or replace function test.gclaim(p text, p_email text, p_phone text default null, p_cars integer default 1, p_consent boolean default false) returns jsonb
language sql as $$ select app.server_game_claim(jsonb_build_object('token', test.gstart(p) ->> 'token', 'sid', test.dsid(p), 'first_name', 'Dana ' || p,
  'email', p_email, 'phone', p_phone, 'cars_viewed', p_cars, 'pages_viewed', p_cars + 2, 'seconds', 95, 'marketing', p_consent,
    'city', 'Toronto', 'region', 'ON', 'country', 'CA')) $$;
-- the marketing wording as the seed stores it (the content seed does not run in the tests)
insert into site_content_blocks (block_key, page, kind, body, data)
values ('legal.marketing_opt_in', 'legal', 'text', 'Yes, send me CarmaCars offers and news by email and text message. I can unsubscribe at any time. Sent by CarmaCars{{mailingAddress}}, {{contactEmail}}.', '{"version": "October 19, 2026"}')
on conflict (block_key) do nothing;
-- earlier suites' plays do not count here
delete from game_claims; delete from game_plays;

-- ================================================================ 1. settings and the prize table
select test.eq('settings: on, five games at equal weights, 7 days, $75 cap, 1 car page or 15 seconds or exit intent (0081), the prize kept 14 days, 3 cars for a task, reminder 24 hours',
  (select format('%s %s %s %s %s/%s/%s %s %s %s', game_enabled, game_weights::text, game_code_valid_days, game_max_discount_cents, game_trigger_car_pages, game_trigger_seconds,
                 game_exit_intent, game_dismiss_days, game_task_min_cars, game_reminder_hours) from (select (app.settings()).*) s),
  't {"cups": 1, "pack": 1, "wheel": 1, "plinko": 1, "scratch": 1, "blackjack": 1} 7 7500 1/15/t 14 3 24');
select test.eq('the owner''s prize table (0081: three rare prizes, 5% at 69): 5% 69, 10% 25, 15% 4, $50 off 3+ days 1, 25% 0.6, $100 off 4+ days 0.3, a free day 0.1',
  (select string_agg(app.game_prize_label(x) || coalesce(' ' || (x ->> 'min_days') || '+d', '') || ' ' || (x ->> 'weight'), ', ' order by o)
     from jsonb_array_elements((app.settings()).game_prizes) with ordinality t(x, o)), '5% off 69, 10% off 25, 15% off 4, $50 off 3+d 1, 25% off 0.6, $100 off 4+d 0.3, 1 free day 3+d 0.1');
select test.eq('the prize table is checked: a weight of 0, both kinds, no kind, a duplicate key, a 60% prize',
  app.game_prizes_ok('[{"key": "a", "percent_bps": 500, "weight": 0}]')::text || app.game_prizes_ok('[{"key": "a", "percent_bps": 500, "amount_cents": 500, "weight": 1}]')::text
  || app.game_prizes_ok('[{"key": "a", "weight": 1}]')::text || app.game_prizes_ok('[{"key": "a", "percent_bps": 500, "weight": 1}, {"key": "a", "percent_bps": 600, "weight": 1}]')::text
  || app.game_prizes_ok('[{"key": "a", "percent_bps": 6000, "weight": 1}]')::text, 'falsefalsefalsefalsefalse');
select test.throws('a bad prize table is refused by the database', $$update program_settings set game_prizes = '[]'$$, 'check');
select test.throws('a game not known is refused', $$update program_settings set game_weights = '{"poker": 1}'$$, 'check');
select test.throws('all games at 0 is refused', $$update program_settings set game_weights = '{"wheel": 0}'$$, 'check');
select test.eq('the draw follows the weights: below 0.69 is 5%, to 0.94 10%, to 0.98 15%, to 0.99 $50, to 0.996 25%, to 0.999 $100, the rest a free day',
  (select string_agg(app.game_draw((app.settings()).game_prizes, r) ->> 'key', ' ' order by r) from unnest(array[0.0, 0.689, 0.69, 0.939, 0.94, 0.979, 0.98, 0.989, 0.99, 0.995, 0.996, 0.998, 0.999, 0.9999]) r),
  'pct5 pct5 pct10 pct10 pct15 pct15 amt50 amt50 pct25 pct25 amt100 amt100 day1 day1');
select test.eq('the draw of games: equal weights, by name', (select string_agg(app.game_draw((app.settings()).game_weights, r) #>> '{}', ' ' order by r) from unnest(array[0.0, 0.2, 0.4, 0.6, 0.8, 0.99]) r),
  'blackjack cups pack plinko scratch wheel');
select test.eq('10,000 draws stay near the table (5% between 66 and 72 in 100, $50 under 2.5 in 100)',
  (select (count(*) filter (where k = 'pct5') between 6600 and 7200) and (count(*) filter (where k = 'amt50') < 250)
     from (select app.game_draw((app.settings()).game_prizes) ->> 'key' as k from generate_series(1, 10000)) x), true);
select test.eq('the short terms list the prizes and say the chances differ',
  app.game_terms_text(),
  'Prizes: 5%, 10%, 15% or 25% off, or $50 off 3+ day rentals, or $100 off 4+ day rentals, or 1 free day on 3+ day rentals. The chances differ: most players win 5% off. Off the rental charge only, up to $75 per code (25% off: up to $150, 1 free day: up to $150). One use, on one booking, within 7 days. One per person, email, phone and device. Not combinable with other promo codes.');
select test.eq('the consent wording with the tokens filled from Site settings',
  (app.game_marketing_text() ->> 'text') = 'Yes, send me CarmaCars offers and news by email and text message. I can unsubscribe at any time. Sent by CarmaCars'
    || coalesce(', ' || nullif((select mailing_address from site_settings), ''), '') || ', ' || coalesce((select public_email from site_settings), '') || '.', true);
select test.eq('the browser''s settings (0081: sooner, the re-show and the booking form; 0094: 60 seconds, 6 a day)', public.game_cfg(),
  '{"on": true, "exit": true, "booking": true, "seconds": 15, "car_pages": 1, "per_day": 6, "per_visit": 3, "reshow_pages": 2, "reshow_seconds": 60}'::jsonb);

-- ================================================================ 2. who may play
select test.eq('a new visitor gets a game and a prize from the table, the terms and the consent wording', (select (r ->> 'ok') || ' ' || ((r ->> 'game') = any (app.game_kinds())) || ' ' || ((r -> 'prize' ->> 'key') in ('pct5', 'pct10', 'pct15', 'amt50'))
  || ' ' || jsonb_array_length(r -> 'prizes') || ' ' || length(r ->> 'token') || ' ' || ((r ->> 'terms') like 'Prizes:%') || ' ' || ((r ->> 'consent') like 'Yes, send me%') from (select test.gstart('a') as r) x), 'true true true 7 64 true true');
select test.eq('the same visitor again: the same play (no new draw by reloading)', (select count(distinct x ->> 'token') from (select test.gstart('a') as x from generate_series(1, 5)) y), 1::bigint);
select test.eq('one play recorded, with the device, page and trigger', (select count(*) || ' ' || min(device) || ' ' || min(path) || ' ' || min(trigger) from game_plays where visitor_id = test.vid('a')), '1 phone /cars/dg-car pages');
update game_plays set created_at = now() - interval '15 days' where visitor_id = test.vid('a');
select test.gstart('a');
select test.eq('after the dismiss period a new game is drawn', (select count(*) from game_plays g where g.visitor_id = test.vid('a')), 2::bigint);
select test.login(test.id('dg_rita'));
select test.eq('a signed-in visitor never plays', test.gstart('signed') ->> 'reason', 'signed_in');
select test.logout();
insert into visitor_sessions (id, visitor_id, known_email, identified_by) values (test.dsid('known'), test.vid('known'), 'known@example.test', 'email_link');
select test.eq('a visitor known by email never plays', test.gstart('known') ->> 'reason', 'known');
update program_settings set game_enabled = false;
select test.eq('games off: nobody plays', test.gstart('off') ->> 'reason', 'off');
update program_settings set game_enabled = true;
select test.eq('the reveal', public.game_reveal(test.gstart('a') ->> 'token'), true);
select test.eq('the reveal is recorded once', (select count(*) from game_plays where visitor_id = test.vid('a') and revealed_at is not null), 1::bigint);
select test.eq('a bad id is refused', app.game_start('{"vid": "nope"}') ->> 'reason', 'bad ids');

-- ================================================================ 3. the claim
-- force the prizes to test: 10% first
update game_plays set prize = '{"key": "pct10", "percent_bps": 1000, "weight": 25}', game = 'wheel' where visitor_id = test.vid('a') and claimed_at is null;
insert into s43 values ('a', test.gclaim('a', 'Dana.A@Example.TEST', '(647) 555-0101', 6));
select test.eq('claimed: the code, the prize and its terms', (select (v ->> 'ok') || ' ' || ((v ->> 'code') ~ '^WIN-[A-Z2-9]{4}-[A-Z2-9]{4}$') || ' ' || (v ->> 'prize_label') || ' | ' || (v ->> 'applies_to')
  from s43 where k = 'a'), 'true true 10% off | the rental charge, up to $75.00');
select test.eq('the promo code: single use, once per renter, game source, 10%, the $75 cap, expires in 7 days',
  (select format('%s %s %s %s %s %s', pc.max_uses, pc.once_per_renter, pc.source, pc.percent_bps, pc.max_discount_cents, round(extract(epoch from pc.valid_until - pc.valid_from) / 86400))
     from promo_codes pc where pc.code = test.s43('a') ->> 'code'), '1 t discount_game 1000 7500 7');
select test.eq('the claim: email in lower case, phone normalized, the visit''s figures, consent off',
  (select format('%s %s %s %s %s %s', email, phone, cars_viewed, pages_viewed, seconds_on_site, marketing_consent) from game_claims where email = 'dana.a@example.test'),
  'dana.a@example.test +16475550101 6 8 95 f');
select test.eq('the lead: discount game, the prize and code, no consent',
  (select format('%s %s %s %s %s', l.kind, l.source, l.payload ->> 'prize_label', (l.payload ->> 'code') = test.s43('a') ->> 'code', l.consent_marketing)
     from leads l join game_claims c on c.lead_id = l.id where c.email = 'dana.a@example.test'), 'other discount_game 10% off t f');
select test.eq('Live visitors: the visitor is known (essential session row, name, email, by the game)',
  (select format('%s %s %s %s', consent, known_name, known_email, identified_by) from visitor_sessions where id = test.dsid('a')), 'essential Dana a dana.a@example.test game');
select test.eq('the play is claimed and revealed', (select (claimed_at is not null) and (revealed_at is not null) from game_plays where token = (select g.token from game_plays g join game_claims c on c.play_id = g.id where c.email = 'dana.a@example.test')), true);
select test.eq('high intent (6 cars): a Sales task "Claimed 10% off, viewed 6 cars"',
  (select t.queue || ' | ' || t.title from tasks t join game_claims c on c.task_id = t.id where c.email = 'dana.a@example.test'), 'sales | Claimed 10% off, viewed 6 cars: Dana a');
select test.eq('the code email is decided at once', (select count(*) from app_events where code = 'renter_game_code' and entity_id = (select id from game_claims where email = 'dana.a@example.test')), 1::bigint);
select test.eq('after a claim the visitor never plays again', test.gstart('a') ->> 'reason', 'claimed');

-- one per email, phone and device
insert into s43 values ('b', test.gclaim('b', 'dana.a@example.test'));
select test.eq('the same email again: refused, and the code goes to that inbox again (never shown)',
  (select (v ->> 'error') || ' ' || (v ? 'code')::text from s43 where k = 'b') || ' ' || (select count(*) from app_events where code = 'renter_game_code' and entity_id = (select id from game_claims where email = 'dana.a@example.test')), 'email_used false 2');
insert into s43 values ('b2', test.gclaim('b2', 'dana.a@example.test'));
select test.eq('and only once a day', (select v ->> 'error' from s43 where k = 'b2') || ' ' || (select count(*) from app_events where code = 'renter_game_code' and entity_id = (select id from game_claims where email = 'dana.a@example.test')), 'email_used 2');
select test.eq('the same phone in another form: refused', test.gclaim('c', 'other.c@example.test', '1-647-555-0101') ->> 'error', 'phone_used');
select test.eq('a bad email, an empty name and a bad phone are refused with a message',
  (select app.server_game_claim(jsonb_build_object('token', test.gstart('d') ->> 'token', 'first_name', 'D', 'email', 'not-an-email')) ->> 'error')
  || ' ' || (select app.server_game_claim(jsonb_build_object('token', test.gstart('d') ->> 'token', 'first_name', ' ', 'email', 'd@example.test')) ->> 'error')
  || ' ' || (select app.server_game_claim(jsonb_build_object('token', test.gstart('d') ->> 'token', 'first_name', 'D', 'email', 'd@example.test', 'phone', '12')) ->> 'error'), 'email first_name phone');
select test.eq('a signed-in person cannot claim', app.server_game_claim(jsonb_build_object('token', test.gstart('e') ->> 'token', 'first_name', 'E', 'email', 'e@example.test'), test.id('dg_rita')) ->> 'error', 'signed_in');
select test.eq('an unknown play is refused', app.server_game_claim('{"token": "x", "first_name": "E", "email": "e@example.test"}') ->> 'error', 'not_found');
select test.throws('the database keeps one claim per device', $$insert into game_claims (play_id, visitor_id, first_name, email, promo_code_id, expires_at)
  select (select id from game_plays where visitor_id = test.vid('d') limit 1), test.vid('a'), 'X', 'x@example.test', (select id from promo_codes limit 1), now()$$, 'game_claims_visitor_key');

-- a low-intent claim: no task; a $50 prize; consent
update game_plays set prize = '{"key": "amt50", "amount_cents": 5000, "min_days": 3, "weight": 1}' where visitor_id = test.vid('f');
select test.gstart('f');
update game_plays set prize = '{"key": "amt50", "amount_cents": 5000, "min_days": 3, "weight": 1}' where visitor_id = test.vid('f');
insert into s43 values ('f', test.gclaim('f', 'dg_rita@example.test', null, 1, true));
select test.eq('$50 off: an amount, 3 days or more, no cap, the words', (select format('%s %s %s | %s', pc.amount_cents, pc.min_rental_days, coalesce(pc.max_discount_cents::text, 'no cap'), test.s43('f') ->> 'applies_to')
  from promo_codes pc where pc.code = test.s43('f') ->> 'code'), '5000 3 no cap | the rental charge of a rental of 3 days or more');
select test.eq('low intent (1 car): no task', (select task_id is null from game_claims where email = 'dg_rita@example.test'), true);
select test.eq('an existing renter''s email: the claim is linked to the renter and the account', (select (renter_id = test.id('renter:dg_rita')) and (user_id = test.id('dg_rita')) from game_claims where email = 'dg_rita@example.test'), true);
select test.eq('consent: the account is opted in with the claim''s words', (select u.marketing_opt_in::text || ' ' || (select count(*) from consents k where k.user_id = u.id and k.consent_code = 'marketing' and k.text_shown like 'Yes, send me%')
  from users u where u.id = test.id('dg_rita')), 'true 1');
-- an unsubscribed account is never opted in again by a game
update users set marketing_opt_in = false, marketing_unsubscribed_at = now() where id = test.id('dg_ben');
select test.gclaim('g', 'dg_ben@example.test', null, 0, true);
select test.eq('an unsubscribed account stays unsubscribed', (select marketing_opt_in from users where id = test.id('dg_ben')), false);
-- an account opened later with the same email: the consent carries over
select test.gclaim('h', 'later.h@example.test', null, 0, true);
insert into users (id, email, full_name) values (test.id('dg_later'), 'Later.H@example.test', 'Later H');
select test.eq('an account opened later takes the consent and the link', (select u.marketing_opt_in::text || ' ' || (c.user_id = u.id) from users u, game_claims c where u.id = test.id('dg_later') and c.email = 'later.h@example.test'), 'true true');

-- ================================================================ 4. the code on a booking request
-- a 2-day request: the $50 code is for 3 days or more
insert into test.rq_ids values ('dg2', app.request_booking(test.id('renter:dg_rita'), test.id('vehicle:DG1'), now() + interval '40 days', now() + interval '42 days', 'standard', null, 'web', test.id('dg_rita')));
select test.throws('a $50 code on a 2-day request is refused', format($$select app.apply_promo_code(test.b('dg2'), %L, test.id('dg_rita'))$$, test.s43('f') ->> 'code'), 'rentals of 3 days or more');
select test.eq('the public quote does not apply it to 2 days, and says why',
  (select (q -> 'promo' ->> 'applied') || ' | ' || (q -> 'promo' ->> 'problem') from (select public.quote_booking(test.id('vehicle:DG1'), now() + interval '40 days', now() + interval '42 days', jsonb_build_object('promo_code', test.s43('f') ->> 'code')) as q) x),
  'false | This code is for rentals of 3 days or more');
select test.eq('and applies it to 4 days', (select q -> 'promo' ->> 'applied' from (select public.quote_booking(test.id('vehicle:DG1'), now() + interval '50 days', now() + interval '54 days', jsonb_build_object('promo_code', test.s43('f') ->> 'code')) as q) x), 'true');
insert into test.rq_ids values ('dg4', app.request_booking(test.id('renter:dg_rita'), test.id('vehicle:DG1'), now() + interval '50 days', now() + interval '54 days', 'standard', null, 'web', test.id('dg_rita')));
select test.eq('a $50 code on a 4-day request: $50 off the rental charge', app.apply_promo_code(test.b('dg4'), test.s43('f') ->> 'code', test.id('dg_rita')), 5000::bigint);
select test.eq('the discount is a promo line of Owner Revenue: shared with the owner in the split (0016, the owner''s decision)',
  (select amount_cents || ' ' || revenue_class from booking_line_items where booking_id = test.b('dg4') and charge_type = 'promo_discount' and voided_at is null), '-5000 owner_revenue');
select test.eq('single use: the code cannot go on a second request', coalesce(app.promo_code_problem(test.s43('f') ->> 'code', test.id('renter:dg_ben'), test.b('dg2')), 'valid'), 'This code has been used up');
select test.eq('Leads: on a request, with its booking number', (select (r ->> 'status') || ' ' || ((r ->> 'booking_number') = (select booking_number from bookings where id = test.b('dg4')))
  from jsonb_array_elements(app.game_leads(test.id('dg_admin')) -> 'rows') r where r ->> 'email' = 'dg_rita@example.test'), 'on_request true');
-- not with another promo code: a booking holds one code; a second one replaces the first, never adds to it
select app.apply_promo_code(test.b('dg4'), test.s43('a') ->> 'code', test.id('dg_rita'));
select test.eq('not combinable: a second code replaces the first (one code and one discount on a booking)',
  (select count(*) from promo_redemptions where booking_id = test.b('dg4') and status <> 'released') || ' ' || (select (promo_discount_cents < 5000)::text || ' ' || (promo_code_id = (select id from promo_codes where code = test.s43('a') ->> 'code')) from bookings where id = test.b('dg4'))
  || ' ' || (select count(*) from booking_line_items where booking_id = test.b('dg4') and charge_type = 'promo_discount' and voided_at is null), '1 true true 1');
select app.apply_promo_code(test.b('dg4'), test.s43('f') ->> 'code', test.id('dg_rita'));
-- the 10% code with its cap: a 25-day rental charge above $750 takes $75 at most
insert into test.rq_ids values ('dg25', app.request_booking(test.id('renter:dg_ben'), test.id('vehicle:DG1'), now() + interval '100 days', now() + interval '125 days', 'standard', null, 'web', test.id('dg_ben')));
select test.eq('the cap: 10% of a long rental is $75.00 at most', (select least(public.calc_bps(rental_charge_cents, 1000), 7500) from bookings where id = test.b('dg25'))
  || '/' || app.apply_promo_code(test.b('dg25'), test.s43('a') ->> 'code', test.id('dg_ben')), '7500/7500');
-- confirmed: the lead is converted and the report counts the booking
select test.rq_ready('dg4');
update bookings set status = 'confirmed' where id = test.b('dg4');
select test.eq('confirmed: the code is redeemed and the lead converted', (select r.status || ' ' || l.status from promo_redemptions r join game_claims c on c.promo_code_id = r.promo_code_id join leads l on l.id = c.lead_id
  where r.booking_id = test.b('dg4')), 'redeemed converted');
select app.compute_booking_split(test.b('dg4'));
select test.eq('the split: the $50 comes off the rental charge before Owner Revenue and the 35% share',
  (select (s.rental_charge_cents = b.rental_charge_cents - 5000)::text || ' ' || (s.company_share_cents = round((b.rental_charge_cents - 5000) * 0.35)) from booking_splits s join bookings b on b.id = s.booking_id where s.booking_id = test.b('dg4')), 'true true');
-- the high-intent task closes when the code goes on a request
select test.eq('the task closes when the code is on a request', (select t.status from tasks t join game_claims c on c.task_id = t.id where c.email = 'dana.a@example.test'), 'done');
-- expiry
update promo_codes set valid_until = now() - interval '1 minute', valid_from = now() - interval '8 days' where code = test.s43('a') ->> 'code';
update game_claims set expires_at = now() - interval '1 minute' where email = 'dana.a@example.test';
select test.eq('an expired code is refused', app.promo_code_problem(test.s43('a') ->> 'code', test.id('renter:dg_rita')), 'This code has expired');

-- ================================================================ 5. the emails and the reminder
-- only this suite's emails are built here (an earlier suite may leave events about rows it removed)
update app_events set processed_at = now() where processed_at is null and code not like 'renter_game_code%';
select app.process_events(100000);
select test.eq('the code email: to the claim''s address, transactional, with the code, the prize, the terms',
  (select format('%s %s %s %s | %s | %s', o.category, o.to_address, o.payload ->> 'first_name', (o.payload ->> 'discount_code') = test.s43('f') ->> 'code', o.payload ->> 'prize_label', o.payload ->> 'discount_applies_to')
     from notification_outbox o where o.code = 'renter_game_code' and o.to_address = 'dg_rita@example.test' limit 1),
  'transactional dg_rita@example.test Dana t | $50 off | the rental charge of a rental of 3 days or more');
select test.eq('it is sent without marketing consent too', (select count(*) from notification_outbox where code = 'renter_game_code' and to_address = 'later.h@example.test' or (code = 'renter_game_code' and to_address = 'dana.a@example.test')) > 0, true);
select test.gclaim('r', 'remind.r@example.test', null, 0, false);
select test.eq('the reminder: not yet', app.job_game_reminders(), '0 reminders, 0 old plays removed');
select test.eq('24 hours before expiry: once', app.job_game_reminders(now() + interval '6 days 1 hour') || ' / ' || app.job_game_reminders(now() + interval '6 days 2 hours'),
  '3 reminders, 0 old plays removed / 0 reminders, 0 old plays removed');
select test.eq('not for a code already on a request', (select reminder_sent_at is null from game_claims where email = 'dg_rita@example.test'), true);
select app.process_events(100000);
select test.eq('the reminder email is transactional and carries the date', (select category || ' ' || (payload ->> 'discount_expires' is not null) from notification_outbox where code = 'renter_game_code_reminder' and to_address = 'remind.r@example.test'), 'transactional true');
update game_plays set created_at = now() - interval '200 days' where claimed_at is null and visitor_id = test.vid('d');
select test.eq('plays never claimed go after the visit records'' period', (select app.job_game_reminders()) like '% 1 old plays removed', true);

-- ================================================================ 6. staff: leads, the report, the next step
select test.eq('Leads: every claim, with the prize, the code''s state, consent and the visit',
  (select format('%s %s %s %s %s %s', r ->> 'prize_label', r ->> 'status', r ->> 'marketing_consent', r ->> 'cars_viewed', r ->> 'city', r ->> 'device')
     from jsonb_array_elements(app.game_leads(test.id('dg_cs')) -> 'rows') r where r ->> 'email' = 'dana.a@example.test'), '10% off on_request false 6 Toronto phone');
select test.eq('Leads: search by code', jsonb_array_length(app.game_leads(test.id('dg_sales'), jsonb_build_object('q', lower(test.s43('f') ->> 'code'))) -> 'rows'), 1);
select test.throws('Leads: not for Finance', $$select app.game_leads(test.id('dg_fin'))$$, 'Admins, customer service and Sales');
select test.eq('the report: plays, claims, codes on requests, bookings, the redemption rate, revenue and discounts',
  (select format('%s %s %s %s %s %s', (r ->> 'plays')::integer >= 8, r ->> 'claims', r ->> 'on_requests', r ->> 'bookings', (r ->> 'discount_cents'), (r ->> 'revenue_cents')::bigint > 0)
     from (select app.game_report(test.id('dg_admin')) as r) x), 't 5 2 1 5000 t');
select test.eq('the report by game and prize', (select jsonb_array_length(r -> 'by_game') || ' ' || jsonb_array_length(r -> 'by_prize') from (select app.game_report(test.id('dg_admin')) as r) x), '6 7');
select test.eq('a lead marked contacted and taken, through the door', app.door(test.id('dg_sales'), 'aal2', 'va_do', 'game_lead_update',
  jsonb_build_object('id', (select lead_id from game_claims where email = 'remind.r@example.test'), 'status', 'contacted', 'take', true)) ? 'id', true);
select test.eq('the lead is contacted and with Sales', (select l.status || ' ' || (l.assigned_to = test.id('dg_sales')) from leads l join game_claims c on c.lead_id = l.id where c.email = 'remind.r@example.test'), 'contacted true');
select test.eq('the report through the door', (app.door(test.id('dg_admin'), 'aal2', 'admin_read', 'game_report', '{"days": 7}') ->> 'days'), '7');

-- ================================================================ 7. privacy, terms, privileges
select test.eq('privileges: anon plays (settings, start, reveal, terms); the claim and the staff reads are the server''s',
  has_function_privilege('anon', 'public.game_start(jsonb)', 'execute')::text || has_function_privilege('anon', 'public.game_cfg()', 'execute')::text
  || has_function_privilege('anon', 'public.game_reveal(text)', 'execute')::text || has_function_privilege('anon', 'public.server_game_claim(jsonb, uuid)', 'execute')::text
  || has_function_privilege('anon', 'app.game_leads(uuid, jsonb)', 'execute')::text || has_function_privilege('authenticated', 'app.server_game_claim(jsonb, uuid)', 'execute')::text,
  'truetruetruefalsefalsefalse');
select test.eq('the tables are closed to the browser', has_table_privilege('anon', 'game_plays', 'select')::text || has_table_privilege('authenticated', 'game_claims', 'select')::text, 'falsefalse');
select test.eq('claims are audited', exists (select 1 from pg_trigger where tgname = 'audit_game_claims'), true);
select test.eq('the privacy policy describes the games where it still has our text (or the seed has not run)',
  coalesce((select (body like '%Discount games are shown%' and body like '%| Discount games:%' and body like '%Discount game claims%')::text from site_content_blocks where block_key = 'legal.privacy'
             and body like '%Live chat is answered first%'), 'true'), 'true');
