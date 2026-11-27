-- 99: CarmaCars Rewards emails and notices, and the birthday and holiday rewards by tier (migrations 3000, 3001;
-- docs/changes/2026-11-14-r48-rewards-notices.md). Fixtures start with "rn48"; addresses are example.test.
select test.suite('99 r48 rewards notices');
update rewards_settings set notices_enabled = true, birthday_reward_enabled = true, holiday_reward_enabled = true;
update program_settings set notify_merge_window_minutes = 0, notify_repeat_window_minutes = 0 where id = (app.settings()).id;
select test.mk_user('rn48_admin', 'admin');
select test.mk_user('rn48_cs', 'va', 'cs');
select test.mk_owner('rn48_o');
select test.mk_vehicle('RN48A', 'rn48_o');
select test.mk_vehicle('RN48B', 'rn48_o');
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area) values
  (test.id('vehicle:RN48A'), 'rn48-a', 'Rewards notices car A', 'published', 'Leslieville'),
  (test.id('vehicle:RN48B'), 'rn48-b', 'Rewards notices car B', 'published', 'Leslieville');
-- only the Rewards events are turned into emails here (the earlier suites leave many events of their own unprocessed)
create function test.rn48_process() returns integer language sql as $$
  update app_events set processed_at = now(), process_note = 'skipped by 99_r48_rewards_notices' where processed_at is null and code not like 'renter\_rewards\_%';
  select app.process_events(1000);
$$;
create function test.rn48_events(p_code text, p_renter text) returns integer language sql stable as $$
  select count(*)::int from app_events where code = p_code and entity_id = test.id('renter:' || p_renter) $$;
create function test.rn48_ev(p_code text, p_renter text) returns app_events language sql stable as $$
  select * from app_events where code = p_code and entity_id = test.id('renter:' || p_renter) order by id desc limit 1 $$;
create function test.rn48_earn(p_renter text, p_points integer, p_key text, p_action text default 'adjust') returns void language sql as $$
  insert into reward_ledger (renter_id, points, kind, action, source_key, reason) values (test.id('renter:' || p_renter), p_points, 'earn', p_action, 'rn48:' || p_key, 'Test points') $$;
create function test.rn48_rental(p jsonb) returns text language sql immutable as $$
  select string_agg((x ->> 'charge_type') || ':' || (x ->> 'amount_cents'), ',' order by x ->> 'charge_type') from jsonb_array_elements(coalesce(p -> 'lines', '[]'::jsonb)) x
   where x ->> 'charge_type' in ('rental_charge', 'occasion_discount', 'price_limit') $$;

-- ================================================================ 1. welcome: the account, or the first confirmed booking (once)
select test.mk_renter('rn48_r');
-- 3050: the account's welcome goes when its address is confirmed (as renter_account_created), to a renter-only account
select test.eq('no welcome before the address is confirmed', test.rn48_events('renter_rewards_welcome', 'rn48_r'), 0);
update users set email_verified_at = now() where id = test.id('rn48_r');
select test.eq('welcome: when the account is confirmed', test.rn48_events('renter_rewards_welcome', 'rn48_r'), 1);
-- 3050: an owner who applied (a renter record at sign-up, then the owner record) gets no Rewards welcome when confirmed
select test.mk_renter('rn48_ow');
insert into owners (user_id, owner_type, legal_name, email, status) values (test.id('rn48_ow'), 'individual', 'Rn48 Ow', 'rn48_ow@example.test', 'lead');
insert into user_roles (user_id, role) values (test.id('rn48_ow'), 'owner') on conflict do nothing;
update users set email_verified_at = now() where id = test.id('rn48_ow');
select test.eq('an owner applicant: no Rewards welcome at sign-up or when confirmed', test.rn48_events('renter_rewards_welcome', 'rn48_ow'), 0);
-- a renter record linked to a confirmed renter-only account later (an earlier request) gets it then
select test.mk_renter('rn48_lk', false);
select test.mk_user('rn48_lk', 'renter');
update users set email_verified_at = now() where id = test.id('rn48_lk');
update renters set user_id = test.id('rn48_lk') where id = test.id('renter:rn48_lk');
select test.eq('welcome: a record linked to a confirmed renter account', test.rn48_events('renter_rewards_welcome', 'rn48_lk'), 1);
select test.mk_booking('CC-RN4801', 'RN48A', 'rn48_r', to_char(now() + interval '40 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '42 days', 'YYYY-MM-DD 10:00'), 'confirmed');
select test.eq('welcome: once only (the first booking after it sends nothing more)', test.rn48_events('renter_rewards_welcome', 'rn48_r'), 1);
select test.mk_renter('rn48_g', false);
select test.eq('a renter without an account: no welcome yet', test.rn48_events('renter_rewards_welcome', 'rn48_g'), 0);
select test.mk_booking('CC-RN4802', 'RN48A', 'rn48_g', to_char(now() + interval '50 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '52 days', 'YYYY-MM-DD 10:00'), 'confirmed');
select test.eq('welcome: on the first confirmed booking', test.rn48_events('renter_rewards_welcome', 'rn48_g'), 1);
select test.rn48_process();
select test.eq('the welcome email: queued with every value, and the in-app notice',
  (select status || ':' || cardinality(missing_variables) || ':' || (jsonb_array_length(payload -> 'ways') > 0) || ':' || (payload ->> 'tier_name') from notification_outbox
     where code = 'renter_rewards_welcome' and renter_id = test.id('renter:rn48_r'))
  || '/' || (select count(*) from notifications where code = 'renter_rewards_welcome' and user_id = test.id('rn48_r')), 'queued:0:true:Member/1');

-- ================================================================ 2. points earned: one email for everything earned at once
select test.mk_booking('CC-RN4803', 'RN48A', 'rn48_r', to_char(now() - interval '45 days', 'YYYY-MM-DD 10:00'), to_char(now() - interval '42 days', 'YYYY-MM-DD 10:00'), 'returned', 30000);
update bookings set status = 'closed' where id = test.id('booking:CC-RN4803');
select test.eq('a rental closes: one points email listing every award of it',
  (select count(*)::text from app_events where code = 'renter_rewards_points' and entity_id = test.id('renter:rn48_r'))
  || '/' || (select jsonb_array_length(payload -> 'earned') from test.rn48_ev('renter_rewards_points', 'rn48_r'))::text
  || '/' || (select (payload ->> 'points_earned') from test.rn48_ev('renter_rewards_points', 'rn48_r')),
  '1/' || (select count(*) from reward_ledger where booking_id = test.id('booking:CC-RN4803') and kind = 'earn')::text || '/'
  || app.rewards_fmt_points((select sum(points)::int from reward_ledger where booking_id = test.id('booking:CC-RN4803') and kind = 'earn')));
select test.rn48_process();
select test.eq('the points email: queued, nothing missing, the balance read when it goes, and the in-app notice',
  (select status || ':' || cardinality(missing_variables) || ':' || (payload ->> 'points_balance') from notification_outbox where code = 'renter_rewards_points' and renter_id = test.id('renter:rn48_r'))
  || '/' || (select count(*) from notifications where code = 'renter_rewards_points' and user_id = test.id('rn48_r')),
  'queued:0:' || app.rewards_fmt_points(app.rewards_balance(test.id('renter:rn48_r'))) || '/1');
select test.ok('it is transactional: no unsubscribe link', (select category = 'transactional' and unsubscribe_token is null from notification_outbox where code = 'renter_rewards_points' and renter_id = test.id('renter:rn48_r')));
select public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_action_save', '{"code": "social_instagram", "enabled": true}'::jsonb);
select test.rn48_earn('rn48_r', 50, 'social', 'social_instagram');
select test.eq('a follow on social media: no email', (select count(*)::int from app_events where code = 'renter_rewards_points' and entity_id = test.id('renter:rn48_r')), 1);
update bookings set do_not_email = true where id = test.id('booking:CC-RN4801');
select test.mk_booking('CC-RN4804', 'RN48B', 'rn48_g', to_char(now() - interval '35 days', 'YYYY-MM-DD 10:00'), to_char(now() - interval '33 days', 'YYYY-MM-DD 10:00'), 'returned', 20000);
update bookings set do_not_email = true where id = test.id('booking:CC-RN4804');
update bookings set status = 'closed' where id = test.id('booking:CC-RN4804');
select test.eq('a booking marked Do not email: its points are not emailed', test.rn48_events('renter_rewards_points', 'rn48_g'), 0);

-- ================================================================ 3. a higher tier, the nudge near a tier, the free day
select test.mk_renter('rn48_t');
select test.rn48_earn('rn48_t', 1100, 't1');
select test.eq('1,100 points: Gold, and one tier email naming it', (select tier_code from reward_accounts where renter_id = test.id('renter:rn48_t'))
  || '/' || test.rn48_events('renter_rewards_tier_up', 'rn48_t') || '/' || ((test.rn48_ev('renter_rewards_tier_up', 'rn48_t')).payload ->> 'tier_code'), 'gold/1/gold');
select test.rn48_earn('rn48_t', 10, 't2');
select test.eq('more points in Gold: no second tier email', test.rn48_events('renter_rewards_tier_up', 'rn48_t'), 1);
select test.rn48_process();
-- 5113 turned the Instant Book perk off (it is the Complete profile rule now): Gold has no enabled perk, so the list is empty
select test.eq('the tier email names Gold and lists its enabled perks (none: Instant Book is off)', (select (payload ->> 'tier_name') || ':' || jsonb_array_length(payload -> 'perks') from notification_outbox where code = 'renter_rewards_tier_up' and renter_id = test.id('renter:rn48_t')),
  'Gold:0');
-- a rental that ends 13,000 points short of Platinum (15,000): within 20%, a nudge two days later
select test.rn48_earn('rn48_t', 11000, 't3');
select test.mk_booking('CC-RN4805', 'RN48A', 'rn48_t', to_char(now() - interval '45 days', 'YYYY-MM-DD 10:00'), to_char(now() - interval '42 days', 'YYYY-MM-DD 10:00'), 'returned', 30000);
update bookings set status = 'closed' where id = test.id('booking:CC-RN4805');
select test.eq('close to the next tier after a rental: the nudge, sent later',
  test.rn48_events('renter_rewards_near_tier', 'rn48_t') || '/' || (((test.rn48_ev('renter_rewards_near_tier', 'rn48_t')).payload ->> '_send_after')::timestamptz > now() + interval '47 hours'), '1/true');
select test.rn48_process();
select test.eq('the nudge is marketing: its unsubscribe link, and it waits', (select category || ':' || (payload ->> 'unsubscribe_url' like '%token=%') || ':' || (send_after > now() + interval '47 hours') || ':' || (payload ->> 'next_tier')
  from notification_outbox where code = 'renter_rewards_near_tier' and renter_id = test.id('renter:rn48_t')), 'marketing:true:true:Platinum');
select test.rn48_earn('rn48_t', 60000, 't4');
select test.eq('Black: the free day code is made and its email links to a booking with it applied',
  test.rn48_events('renter_rewards_free_day', 'rn48_t') || '/' || (select count(*) from promo_codes where renter_id = test.id('renter:rn48_t') and source = 'rewards_free_day'), '1/1');
select test.rn48_process();
select test.eq('the free day email: its code and the booking link', (select (payload ->> 'book_url') = rtrim((app.settings()).notify_base_url, '/') || '/book?promo=' || (payload ->> 'free_day_code')
  from notification_outbox where code = 'renter_rewards_free_day' and renter_id = test.id('renter:rn48_t')), true);

-- ================================================================ 4. the hourly job
-- points ending in 5 days: the 7-day reminder once
select test.mk_renter('rn48_e');
insert into reward_ledger (renter_id, points, kind, action, source_key, reason, created_at) values
  (test.id('renter:rn48_e'), 800, 'earn', 'adjust', 'rn48:e1', 'Test points', now() - interval '12 months' + interval '5 days');
update reward_accounts set reminded_for = (select max(created_at) from reward_ledger where renter_id = test.id('renter:rn48_e')) where renter_id = test.id('renter:rn48_e');
select app.job_rewards_notices(date_trunc('day', now()) + interval '15 hours');
select app.job_rewards_notices(date_trunc('day', now()) + interval '16 hours');
select test.eq('7 days before the points end: one reminder', test.rn48_events('renter_rewards_expiring_7d', 'rn48_e'), 1);
-- the free day ending: 30 days, then 7
update promo_codes set valid_until = now() + interval '20 days' where renter_id = test.id('renter:rn48_t') and source = 'rewards_free_day';
select app.job_rewards_notices();
update promo_codes set valid_until = now() + interval '5 days' where renter_id = test.id('renter:rn48_t') and source = 'rewards_free_day';
select app.job_rewards_notices();
select app.job_rewards_notices();
select test.eq('an unused free day: 30 days before, then 7', test.rn48_events('renter_rewards_free_day_ending', 'rn48_t'), 2);
-- points waiting: the last rental 42 days ago, nothing coming up (rn48_r has a booking coming up; rn48_t does not)
select app.job_rewards_notices(((now() at time zone 'America/Toronto')::date::timestamp + interval '11 hours') at time zone 'America/Toronto');
select test.eq('points waiting 30 days after the last rental, not with a booking coming up',
  test.rn48_events('renter_rewards_waiting', 'rn48_t') || '/' || test.rn48_events('renter_rewards_waiting', 'rn48_r'), '1/0');
select app.job_rewards_notices(((now() at time zone 'America/Toronto')::date::timestamp + interval '1 day 11 hours') at time zone 'America/Toronto');
select test.eq('and not again within 60 days', test.rn48_events('renter_rewards_waiting', 'rn48_t'), 1);
-- the statement on the 1st, for a balance; never at night
select app.job_rewards_notices((date_trunc('month', now() at time zone 'America/Toronto') + interval '1 month 3 hours') at time zone 'America/Toronto');
select test.eq('the 1st at 3:00: no statement yet', test.rn48_events('renter_rewards_statement', 'rn48_t'), 0);
select app.job_rewards_notices((date_trunc('month', now() at time zone 'America/Toronto') + interval '1 month 9 hours 30 minutes') at time zone 'America/Toronto');
select app.job_rewards_notices((date_trunc('month', now() at time zone 'America/Toronto') + interval '1 month 10 hours 30 minutes') at time zone 'America/Toronto');
select app.job_rewards_notices((date_trunc('month', now() at time zone 'America/Toronto') + interval '1 month 11 hours 30 minutes') at time zone 'America/Toronto');
select test.eq('the 1st: one statement for the month just ended, with its points',
  test.rn48_events('renter_rewards_statement', 'rn48_t') || '/' || ((test.rn48_ev('renter_rewards_statement', 'rn48_t')).payload ->> 'month_label')
  || '/' || ((test.rn48_ev('renter_rewards_statement', 'rn48_t')).payload ->> 'has_entries'),
  '1/' || to_char(date_trunc('month', now() at time zone 'America/Toronto'), 'FMMonth YYYY') || '/true');
-- the switch: off, and the job sends nothing of it
select test.throws('only an Admin switches a Rewards email', $$select public.door(test.id('rn48_cs'), null, 'admin_do', 'rewards_notice_set', '{"code": "renter_rewards_waiting", "enabled": false}'::jsonb)$$, null);
select test.throws('a Rewards email only', $$select public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_notice_set', '{"code": "renter_booking_confirmed", "enabled": false}'::jsonb)$$, 'Rewards email');
select public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_notice_set', '{"code": "renter_rewards_tier_up", "enabled": false}'::jsonb);
select test.mk_renter('rn48_off');
select test.rn48_earn('rn48_off', 1200, 'off1');
select test.eq('switched off: no tier email', test.rn48_events('renter_rewards_tier_up', 'rn48_off'), 0);
select public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_notice_set', '{"code": "renter_rewards_tier_up", "enabled": true}'::jsonb);
select test.eq('logged', (select count(*)::int from audit_log where action = 'rewards_notice_set' and entity_id = 'renter_rewards_tier_up'), 2);
-- an unsubscribed renter: marketing skipped, transactional still goes
update users set marketing_unsubscribed_at = now() where id = test.id('rn48_t');
select app.job_rewards_notices((date_trunc('month', now() at time zone 'America/Toronto') + interval '2 months 10 hours 30 minutes') at time zone 'America/Toronto');
select test.rn48_process();
select test.eq('unsubscribed: the next statement is not sent, and no in-app notice for it',
  (select status || ':' || status_reason from notification_outbox where code = 'renter_rewards_statement' and renter_id = test.id('renter:rn48_t') order by created_at desc limit 1)
  || '/' || (select count(*) from notifications n join app_events e on e.id = n.event_id where n.code = 'renter_rewards_statement' and n.user_id = test.id('rn48_t') and e.payload ->> 'month_label' <> ((test.rn48_ev('renter_rewards_statement', 'rn48_t')).payload ->> 'month_label')),
  'skipped:no marketing consent/0');
update users set marketing_unsubscribed_at = null where id = test.id('rn48_t');

-- the Admin's list: every Rewards email with its switch and counts of 30 days
update notification_outbox set status = 'sent', sent_at = now() where code = 'renter_rewards_points' and renter_id = test.id('renter:rn48_r');
create temp table rn48_l as select public.door(test.id('rn48_admin'), null, 'admin_read', 'rewards', '{}'::jsonb) v;
select test.eq('Settings > Rewards lists the twelve Rewards emails, with their counts',
  (select jsonb_array_length(v -> 'notices' -> 'items') from rn48_l) || '/' ||
  (select (x ->> 'sent_30d') || ':' || ((x ->> 'notices_30d')::int = (select count(*) from notifications where code = 'renter_rewards_points' and created_at > now() - interval '30 days')) || ':' || (x ->> 'enabled')
     from rn48_l, jsonb_array_elements(v -> 'notices' -> 'items') x where x ->> 'code' = 'renter_rewards_points'),
  '12/' || (select count(*) from notification_outbox where code = 'renter_rewards_points' and status = 'sent' and sent_at > now() - interval '30 days')::text || ':true:true');
select test.ok('the twelve, starting with the welcome', (select jsonb_array_length(v -> 'notices' -> 'items') = 12 and v -> 'notices' -> 'items' -> 0 ->> 'code' = 'renter_rewards_welcome' from rn48_l));

-- ================================================================ 5. birthday and holiday rewards in the price
select test.eq('the holidays by their rules: Good Friday, Victoria Day, Thanksgiving 2027',
  (select string_agg(on_date::text, ',' order by on_date) from app.reward_holidays_between('2027-03-20', '2027-10-20') where code in ('good_friday', 'victoria_day', 'thanksgiving')),
  '2027-03-26,2027-05-24,2027-10-11');
select test.eq('a Monday holiday''s window is the weekend before it', (select w_from || ' ' || w_to from app.reward_holidays_between('2027-05-24', '2027-05-24') where code = 'victoria_day'), '2027-05-22 2027-05-24');
select test.eq('the tiers'' defaults: Gold off, Platinum 10%, Black 20%', (select string_agg(code || ':' || birthday_bps || '/' || holiday_bps, ',' order by min_points) from reward_tiers where active and code <> 'member'),
  'gold:0/0,platinum:1000/1000,black:2000/2000');
-- rn48_b: Gold, born 5 May (the licence); rn48_m: a Member
select test.mk_renter('rn48_b');
select test.rn48_earn('rn48_b', 1200, 'b1');
select test.mk_renter('rn48_m');
select test.ok('Gold by default: no birthday or holiday reward', app.rewards_occasion(test.id('renter:rn48_b'), '2027-05-08 14:00+00') is null
  and app.rewards_occasion(test.id('renter:rn48_b'), '2026-12-25 15:00+00') is null);
-- the rest of this part: an Admin gives Gold 10% (Change on its tier)
update reward_tiers set birthday_bps = 1000, holiday_bps = 1000 where code = 'gold';
select test.eq('a pickup 3 days from the birthday: Gold''s 10%', app.rewards_occasion(test.id('renter:rn48_b'), '2027-05-08 14:00+00') ->> 'label', 'Birthday reward ' || chr(8722) || '10%');
select test.ok('8 days from it: none', app.rewards_occasion(test.id('renter:rn48_b'), '2027-05-13 14:00+00') is null);
select test.ok('a Member: none', app.rewards_occasion(test.id('renter:rn48_m'), '2027-05-05 14:00+00') is null);
select test.eq('Christmas Day: the holiday reward', app.rewards_occasion(test.id('renter:rn48_b'), '2026-12-25 15:00+00') ->> 'kind', 'holiday');
-- not stacked: the bigger wins
update reward_tiers set holiday_bps = 1500 where code = 'gold';
update renters set date_of_birth = null, birthday_month = 12, birthday_day = 24 where id = test.id('renter:rn48_m');
select test.rn48_earn('rn48_m', 1200, 'm1');
select test.eq('a birthday on a holiday: one reward, the bigger', app.rewards_occasion(test.id('renter:rn48_m'), '2026-12-25 15:00+00') ->> 'label', 'Holiday reward ' || chr(8722) || '15%');
update reward_tiers set holiday_bps = 1000 where code = 'gold';
select test.eq('a tie: the birthday', app.rewards_occasion(test.id('renter:rn48_m'), '2026-12-25 15:00+00') ->> 'kind', 'birthday');
-- the quote of the signed-in renter shows the line: 3 days at $100, 10% off the rental charge
select set_config('request.jwt.claim.sub', test.id('rn48_b')::text, false);
select test.eq('the quote: a line Birthday reward of 10% of the rental charge',
  test.rn48_rental(app.price_quote(test.id('vehicle:RN48A'), '2027-05-04 14:00+00', '2027-05-07 14:00+00', '{}'::jsonb)), 'occasion_discount:-3000,rental_charge:30000');
select set_config('request.jwt.claim.sub', '', false);
select test.ok('a visitor not signed in: no line', test.rn48_rental(app.price_quote(test.id('vehicle:RN48A'), '2027-05-04 14:00+00', '2027-05-07 14:00+00', '{}'::jsonb)) = 'rental_charge:30000');
-- never below the car's lowest daily price: at $95 a day, the discount stops at $5 a day
update vehicles set price_min_daily_cents = 9500 where id = test.id('vehicle:RN48B');
select set_config('request.jwt.claim.sub', test.id('rn48_b')::text, false);
select test.eq('the car''s lowest daily price: the reward stops there, no limit line',
  test.rn48_rental(app.price_quote(test.id('vehicle:RN48B'), '2027-05-04 14:00+00', '2027-05-07 14:00+00', '{}'::jsonb)), 'occasion_discount:-1500,rental_charge:30000');
select set_config('request.jwt.claim.sub', '', false);
-- never on an insurer's booking or an Owner Booking
select test.ok('an insurer''s booking or an Owner Booking: no line',
  app.price_lines_occasion('{"rental_charge_cents": 30000, "lines": [{"charge_type": "rental_charge", "amount_cents": 30000}]}'::jsonb, '{"insurer_billed": true, "occasion": {"kind": "birthday", "bps": 1000}}'::jsonb) ->> 'occasion_label' is null
  and app.price_lines_occasion('{"rental_charge_cents": 30000, "lines": [{"charge_type": "rental_charge", "amount_cents": 30000}]}'::jsonb, '{"booking_type": "owner", "occasion": {"kind": "birthday", "bps": 1000}}'::jsonb) ->> 'occasion_label' is null);
-- a request locks it on the booking and the booking's lines carry it
select test.mk_booking('CC-RN4806', 'RN48A', 'rn48_b', '2027-05-04 10:00', '2027-05-07 10:00', 'requested');
select app.reprice_booking(test.id('booking:CC-RN4806'));
select test.eq('a request locks the reward; the booking''s lines carry it',
  (select occasion_kind || ':' || occasion_bps from bookings where id = test.id('booking:CC-RN4806')) || '/' ||
  (select sum(amount_cents)::text from booking_line_items where booking_id = test.id('booking:CC-RN4806') and charge_type = 'occasion_discount' and voided_at is null),
  'birthday:1000/-3000');
select test.mk_booking('CC-RN4807', 'RN48A', 'rn48_m', '2027-05-04 10:00', '2027-05-07 10:00', 'requested');
select test.ok('a Member''s request locks none', (select occasion_kind is null and occasion_locked_at is not null from bookings where id = test.id('booking:CC-RN4807')));

-- ================================================================ 6. the birthday and holiday notices
select set_config('request.jwt.claim.sub', test.id('rn48_m')::text, false);
select test.throws('a real month and day', $$select public.rewards_mine_birthday(2, 30)$$, 'real month and day');
select public.rewards_mine_birthday(12, 24, null);
select test.eq('the Rewards page shows the birthday and the tier''s percents',
  (public.my_rewards() -> 'birthday' ->> 'label') || '/' || (public.my_rewards() -> 'birthday' ->> 'from_licence') || '/' || (public.my_rewards() -> 'occasions' ->> 'birthday_pct'),
  'December 24/false/10%');
select set_config('request.jwt.claim.sub', '', false);
-- 16 Dec at 11:00: 8 days before the birthday (14 or less), 9 days before the Christmas weekend (10 or less)
select app.job_rewards_notices('2026-12-16 11:00'::timestamp at time zone 'America/Toronto');
select app.job_rewards_notices('2026-12-16 12:00'::timestamp at time zone 'America/Toronto');
select test.eq('14 days or less before the birthday: one birthday email, with the reward and the window',
  test.rn48_events('renter_rewards_birthday', 'rn48_m') || '/' || ((test.rn48_ev('renter_rewards_birthday', 'rn48_m')).payload ->> 'reward_pct') || '/' || ((test.rn48_ev('renter_rewards_birthday', 'rn48_m')).payload ->> 'window_from'),
  '1/10%/Thu, Dec 17, 2026');
select test.eq('the Christmas weekend 9 days away: one holiday email (Boxing Day joins it) to Gold and up only',
  test.rn48_events('renter_rewards_holiday', 'rn48_m') || '/' || test.rn48_events('renter_rewards_holiday', 'rn48_e')
  || '/' || ((test.rn48_ev('renter_rewards_holiday', 'rn48_m')).payload ->> 'holiday_name') || '/' || ((test.rn48_ev('renter_rewards_holiday', 'rn48_m')).payload ->> 'window_to'),
  '1/0/Christmas Day/Mon, Dec 28, 2026');
select test.rn48_process();
select test.eq('the birthday and holiday emails are marketing, with nothing missing',
  (select string_agg(category || ':' || cardinality(missing_variables), ',' order by code) from notification_outbox where renter_id = test.id('renter:rn48_m') and code in ('renter_rewards_birthday', 'renter_rewards_holiday')),
  'marketing:0,marketing:0');
-- no Rewards email or notice is left with a tag: every merge value the subject, the preheader and the template read is filled
select test.eq('no leftover {{tag}}: every Rewards email has every value, and no notice shows a tag',
  (select count(*) from notification_outbox o join notification_catalogue c on c.code = o.code
    where o.code like 'renter\_rewards\_%' and (cardinality(o.missing_variables) > 0
       or exists (select 1 from regexp_matches(c.subject || ' ' || coalesce(c.preheader, ''), '\{\{\s*([a-z0-9_]+)\s*\}\}', 'g') m where not o.payload ? m[1])))
  || '/' || (select count(*) from notifications where code like 'renter\_rewards\_%' and (title ~ '\{\{' or coalesce(body, '') ~ '\{\{'))
  || '/' || (select count(distinct code) from notification_outbox where code = any (app.rewards_notice_codes())), '0/0/11');
-- the Admin sets a tier's percents and the holidays
select public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_occasion_tier_save', '{"code": "gold", "birthday_bps": 500, "enabled": true}'::jsonb);
select test.eq('a tier''s birthday percent changed', app.rewards_occasion(test.id('renter:rn48_b'), '2027-05-05 14:00+00') ->> 'bps', '500');
select public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_occasion_tier_save', '{"code": "gold", "birthday_bps": 1000}'::jsonb);
select test.eq('a holiday added by its rule shows its next date',
  (select x #>> '{next,on}' from jsonb_array_elements(public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_holiday_save',
     '{"name": "Remembrance Day", "kind": "fixed", "month": 11, "day": 11}'::jsonb) -> 'holidays') x where x ->> 'code' = 'remembrance_day') is not null, true);
select test.throws('a holiday needs its date rule', $$select public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_holiday_save', '{"name": "No date", "kind": "fixed"}'::jsonb)$$, 'date rule');
select public.door(test.id('rn48_admin'), null, 'admin_do', 'rewards_holiday_save', '{"code": "remembrance_day", "remove": true}'::jsonb);
select test.throws('only an Admin edits them', $$select public.door(test.id('rn48_cs'), null, 'admin_do', 'rewards_occasion_save', '{"holiday_enabled": false}'::jsonb)$$, null);

update vehicles set price_min_daily_cents = null where id = test.id('vehicle:RN48B');
update rewards_settings set notices_enabled = false, birthday_reward_enabled = false, holiday_reward_enabled = false;
