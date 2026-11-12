-- 99: Rewards tiers with perks (migration 2421, release 40). Fixtures start with "r40".
select test.suite('99 r40 reward tiers');
select test.mk_user('r40_admin', 'admin');
select test.mk_user('r40_cs', 'va', 'cs');
select test.mk_owner('r40_owner');
select test.mk_vehicle('r40_car', 'r40_owner');
insert into vehicle_listings (vehicle_id, slug, headline, status, home_area) values (test.id('vehicle:r40_car'), 'r40-test-car', 'Rewards test car', 'published', 'Leslieville');
select test.mk_renter('r40_mia');
select test.mk_renter('r40_pat');
select test.mk_renter('r40_bea');
create function test.r40_earn(p_renter text, p_points integer, p_key text) returns void language sql as $$
  insert into reward_ledger (renter_id, points, kind, action, source_key, reason) values (test.id('renter:' || p_renter), p_points, 'earn', 'adjust', 'r40:' || p_key, 'Test points');
  select app.rewards_sync_tier(test.id('renter:' || p_renter))::text from (select 1) x;
$$;

-- 1. points earned in 12 months decide the tier; below Gold there is none; redeeming never drops it
select test.eq('three tiers, by points', (select string_agg(code || ':' || min_points, ',' order by min_points) from reward_tiers where active and code <> 'member'), 'gold:1000,platinum:15000,black:60000');
select test.eq('no tier discount any more', (select max(discount_bps) from reward_tiers), 0);
select set_config('request.jwt.claim.sub', test.id('r40_mia')::text, false);
select test.ok('a Member: no tier, 1,000 points to Gold, the three tiers with their perks',
  (public.my_rewards() -> 'ladder' ->> 'tier_code') is null and (public.my_rewards() -> 'next_tier' ->> 'points_needed')::int = 1000
  and jsonb_array_length(public.my_rewards() -> 'ladder' -> 'tiers') = 3
  and (public.my_rewards() -> 'ladder' -> 'tiers' -> 0 -> 'perks' -> 0 ->> 'code') = 'instant_book');
select test.r40_earn('r40_mia', 1200, 'mia1');
select test.eq('1,200 points: Gold', public.my_rewards() -> 'ladder' ->> 'tier_code', 'gold');
insert into reward_ledger (renter_id, points, kind, action, source_key, reason) values (test.id('renter:r40_mia'), -1000, 'redeem', 'redeem', 'r40:mia-redeem', 'Test redeem');
select test.eq('redeeming 1,000 keeps Gold (points earned count, not the balance)', public.my_rewards() -> 'ladder' ->> 'tier_code', 'gold');
select set_config('request.jwt.claim.sub', '', false);
select test.ok('Gold has Instant Book, not Any car', app.rewards_has_perk(test.id('renter:r40_mia'), 'instant_book') and not app.rewards_has_perk(test.id('renter:r40_mia'), 'any_car'));
select test.eq('Instant Book reads the tier', app.instant_book_check(test.id('renter:r40_mia')) ->> 'eligible', 'true');
update renters set instant_book_revoked_at = now(), instant_book_revoked_reason = 'Test' where id = test.id('renter:r40_mia');
select test.eq('an Admin''s revoke still wins over the tier', app.instant_book_check(test.id('renter:r40_mia')) ->> 'reason', 'Taken away by an Admin: Test');
update renters set instant_book_revoked_at = null, instant_book_revoked_reason = null where id = test.id('renter:r40_mia');

-- 2. Platinum: any car, any time: taken dates become a priority request with an urgent Fleet task; nothing else moves
select test.r40_earn('r40_pat', 16000, 'pat1');
select test.mk_booking('R40-TAKEN', 'r40_car', 'r40_bea', to_char(now() + interval '30 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '34 days', 'YYYY-MM-DD 10:00'), 'confirmed');
create function test.r40_req(p_renter text) returns jsonb language sql stable as $$
  select jsonb_build_object('request_key', 'r40-key-' || p_renter, 'vehicle_id', test.id('vehicle:r40_car'),
    'pickup_at', date_trunc('day', now() + interval '31 days') + interval '15 hours', 'return_at', date_trunc('day', now() + interval '33 days') + interval '15 hours',
    'booking_type', 'standard', 'coverage_option', 2,
    'renter', jsonb_build_object('full_name', initcap(replace(p_renter, '_', ' ')), 'date_of_birth', '1990-05-05', 'email', p_renter || '@example.test', 'mobile', '647-555-0199', 'licence_class', 'G', 'licence_issuer', 'ON'),
    'consents', jsonb_build_object('terms', jsonb_build_object('accepted', true, 'version', 't', 'text', 'I agree.'), 'privacy', jsonb_build_object('accepted', true, 'version', 'p', 'text', 'I agree.')))
$$;
create table test.r40 (k text primary key, v jsonb);
insert into test.r40 select 'pat', app.submit_booking_request(test.r40_req('r40_pat'), null, null, test.id('r40_pat'));
insert into test.r40 select 'mia', app.submit_booking_request(test.r40_req('r40_mia'), null, null, test.id('r40_mia'));
select test.eq('Platinum on taken dates: a priority request due within 4 hours',
  (select (v ->> 'any_car') || '/' || (v ->> 'conflict_at_submit') from test.r40 where k = 'pat')
  || '/' || (select (any_car_priority)::text || '/' || (abs(extract(epoch from any_car_due_at - now() - interval '4 hours')) < 120)::text from bookings where id = (select (v ->> 'booking_id')::uuid from test.r40 where k = 'pat')),
  'true/true/true/true');
select test.eq('an urgent Fleet task, due at the response target',
  (select queue || '/' || priority || '/' || task_type from tasks where dedupe_key = 'any_car:' || (select v ->> 'booking_id' from test.r40 where k = 'pat')), 'fleet/urgent/any_car_request');
select test.eq('Gold on taken dates: an ordinary request', (select coalesce(v ->> 'any_car', 'none') from test.r40 where k = 'mia'), 'none');
select test.eq('the confirmed booking on those dates is untouched', (select status::text from bookings where id = test.id('booking:R40-TAKEN')), 'confirmed');
update bookings set status = 'declined' where id = (select (v ->> 'booking_id')::uuid from test.r40 where k = 'pat');
select test.eq('answered (declined): the Fleet task closes', (select status from tasks where dedupe_key = 'any_car:' || (select v ->> 'booking_id' from test.r40 where k = 'pat')), 'done');
select set_config('request.jwt.claim.sub', test.id('r40_pat')::text, false);
select test.eq('the car page knows a Platinum renter may request taken dates', public.my_any_car() ->> 'any_car', 'true');
select set_config('request.jwt.claim.sub', '', false);
select test.eq('a visitor may not', public.my_any_car() ->> 'any_car', 'false');

-- 3. Black: one free day a year, a one-time code CarmaCars pays for; Black keeps Gold's and Platinum's perks
select test.r40_earn('r40_bea', 61000, 'bea1');
select test.ok('Black keeps every perk', app.rewards_has_perk(test.id('renter:r40_bea'), 'instant_book') and app.rewards_has_perk(test.id('renter:r40_bea'), 'any_car') and app.rewards_has_perk(test.id('renter:r40_bea'), 'free_day'));
select test.eq('the free day code: one day, the renter''s own, once, a year, company funded',
  (select free_days || '/' || (renter_id = test.id('renter:r40_bea'))::text || '/' || max_uses || '/' || company_funded::text || '/' || (valid_until > now() + interval '364 days')::text
     from promo_codes where id = (select free_day_promo_id from reward_accounts where renter_id = test.id('renter:r40_bea'))), '1/true/1/true/true');
select app.rewards_sync_tier(test.id('renter:r40_bea'));
select test.eq('one code a year, not one per visit', (select count(*) from promo_codes where renter_id = test.id('renter:r40_bea') and source = 'rewards_free_day'), 1::bigint);
select test.mk_booking('R40-FREE', 'r40_car', 'r40_bea', '2026-03-01 10:00', '2026-03-04 10:00', 'closed', 30000);
select app.compute_booking_split(test.id('booking:R40-FREE'));
create table test.r40_split as select owner_payout_cents, company_share_cents from booking_splits where booking_id = test.id('booking:R40-FREE');
update bookings set promo_code_id = (select free_day_promo_id from reward_accounts where renter_id = test.id('renter:r40_bea')), promo_discount_cents = 10000 where id = test.id('booking:R40-FREE');
select test.mk_line('R40-FREE', 'promo_discount', -10000);
select app.compute_booking_split(test.id('booking:R40-FREE'));
select test.ok('the free day leaves the owner''s payout as it was; CarmaCars'' share pays the whole day',
  (select s.owner_payout_cents = o.owner_payout_cents and abs((o.company_share_cents - s.company_share_cents) - 10000) <= 1
     from booking_splits s, test.r40_split o where s.booking_id = test.id('booking:R40-FREE')),
  (select format('before %s/%s after %s/%s', o.owner_payout_cents, o.company_share_cents, s.owner_payout_cents, s.company_share_cents) from booking_splits s, test.r40_split o where s.booking_id = test.id('booking:R40-FREE')));

-- 4. Admin > Rewards: thresholds in order, perks moved or reworded, the response time
select test.throws('thresholds go up the ladder',
  format($$select public.door(%L, 'aal2', 'admin_do', 'rewards_tier_save', '{"code": "platinum", "min_points": 500}'::jsonb)$$, test.id('r40_admin')), 'more points than the one below');
select test.throws('only an Admin', format($$select public.door(%L, 'aal2', 'admin_do', 'rewards_perk_save', '{"code": "any_car", "enabled": false}'::jsonb)$$, test.id('r40_cs')));
select public.door(test.id('r40_admin'), 'aal2', 'admin_do', 'rewards_perk_save', '{"code": "any_car", "tier_code": "black", "label": "Any car, any time"}'::jsonb);
select test.eq('a perk moved up to Black: Platinum loses it', app.rewards_has_perk(test.id('renter:r40_pat'), 'any_car')::text, 'false');
select public.door(test.id('r40_admin'), 'aal2', 'admin_do', 'rewards_perk_save', '{"code": "any_car", "tier_code": "platinum"}'::jsonb);
select public.door(test.id('r40_admin'), 'aal2', 'admin_do', 'rewards_settings_save', '{"any_car_response_hours": 6}'::jsonb);
select test.eq('the response time is a setting', (app.rewards()).any_car_response_hours, 6);
select test.ok('Admin > Rewards reads the tiers, perks and open priority requests',
  (select jsonb_array_length(r -> 'tiers') = 3 and jsonb_array_length(r -> 'perks') = 3 and r ? 'any_car_open' from (select public.door(test.id('r40_admin'), 'aal2', 'admin_read', 'rewards', '{}'::jsonb) r) x));
update rewards_settings set any_car_response_hours = 4;

-- 5. Your discounts (2423): every code the renter holds, with what it gives, its status and the booking it went on
insert into promo_codes (code, description, amount_cents, valid_until, max_uses, once_per_renter, renter_id, source)
values ('PTSR40TEST', 'Test points code', 500, now() + interval '10 days', 1, true, test.id('renter:r40_bea'), 'rewards');
select test.eq('an open points code: unused, with its days left',
  (select x ->> 'kind' || '/' || (x ->> 'status') || '/' || (x ->> 'days_left') from jsonb_array_elements(app.my_discounts(test.id('r40_bea'))) x where x ->> 'code' = 'PTSR40TEST'), 'points/open/10');
insert into promo_redemptions (promo_code_id, booking_id, renter_id, discount_cents, status, redeemed_at)
values ((select free_day_promo_id from reward_accounts where renter_id = test.id('renter:r40_bea')), test.id('booking:R40-FREE'), test.id('renter:r40_bea'), 10000, 'redeemed', now());
select test.eq('the free day, used: on which booking',
  (select x ->> 'kind' || '/' || (x ->> 'status') || '/' || (x ->> 'booking_number') from jsonb_array_elements(app.my_discounts(test.id('r40_bea'))) x where x ->> 'kind' = 'free_day'), 'free_day/used/R40-FREE');
select test.eq('open codes first', (app.my_discounts(test.id('r40_bea')) -> 0 ->> 'status'), 'open');
select test.eq('someone else''s codes are not listed', (select count(*) from jsonb_array_elements(app.my_discounts(test.id('r40_mia'))) x where x ->> 'code' = 'PTSR40TEST'), 0::bigint);
