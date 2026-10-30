-- 99: CarmaCars Rewards (migration 0212). Fixtures start with "rwd".
select test.suite('99 rewards');
select test.mk_user('rwd_admin', 'admin');
select test.mk_user('rwd_cs', 'va', 'cs');
select test.mk_owner('rwd_owner');
select test.mk_vehicle('rwd_car', 'rwd_owner');
select test.mk_renter('rwd_amy');
select test.mk_renter('rwd_ben');
update site_settings set google_review_link = 'https://g.page/r/test/review', social_links = coalesce(social_links, '{}'::jsonb) || '{"instagram": "https://instagram.com/x", "facebook": null}'::jsonb where singleton;

-- Amy's account and code; Ben books with Amy's link
select set_config('request.jwt.claim.sub', test.id('rwd_amy')::text, false);
select test.ok('a renter has a referral link and starts as Member', (public.my_rewards() -> 'tier' ->> 'code') = 'member' and public.my_rewards() ->> 'referral_url' like '%/r/R%');
select set_config('request.jwt.claim.sub', '', false);

-- Ben: 5 days at $100 = $500 rental charge, returned on time, referred by Amy, closes
select test.mk_booking('RWD-1', 'rwd_car', 'rwd_ben', '2026-09-01 10:00', '2026-09-06 10:00', 'returned', 50000, 'standard',
  (select referral_code from reward_accounts where renter_id = test.id('renter:rwd_amy')));
select test.mk_line('RWD-1', 'addon', 5000);
update bookings set status = 'closed' where id = test.id('booking:RWD-1');
select test.eq('a rental earns 1 point a dollar of the rental charge (add-ons not counted)',
  (select points from reward_ledger where source_key = 'rental:' || test.id('booking:RWD-1')), 500);
select test.ok('damage-free, first rental and the friend''s 250', exists (select 1 from reward_ledger where source_key = 'damage_free:' || test.id('booking:RWD-1') and points = 200)
  and exists (select 1 from reward_ledger where source_key = 'first_rental:' || test.id('renter:rwd_ben') and points = 100)
  and exists (select 1 from reward_ledger where source_key = 'referral_referred:' || test.id('renter:rwd_ben') and points = 250));
select test.eq('the referrer gets 500', app.rewards_balance(test.id('renter:rwd_amy')), 500);
select test.eq('Ben''s balance', app.rewards_balance(test.id('renter:rwd_ben')), 1050);
select app.rewards_on_close(test.id('booking:RWD-1'));
select test.eq('closing twice gives nothing more', app.rewards_balance(test.id('renter:rwd_ben')), 1050);

-- a late return with a cleaning fee is not damage-free; owner bookings earn nothing
select test.mk_booking('RWD-2', 'rwd_car', 'rwd_ben', '2026-09-10 10:00', '2026-09-20 10:00', 'returned', 100000, 'standard', null, null, '2026-09-20 13:00');
update bookings set status = 'closed' where id = test.id('booking:RWD-2');
select test.ok('late: no damage-free points', not exists (select 1 from reward_ledger where source_key = 'damage_free:' || test.id('booking:RWD-2')));
select test.ok('10+ rental days in 12 months: Silver, with its own 5% code', (select tier_code from reward_accounts where renter_id = test.id('renter:rwd_ben')) = 'silver'
  and exists (select 1 from reward_accounts a join promo_codes p on p.id = a.tier_promo_id where a.renter_id = test.id('renter:rwd_ben') and p.percent_bps = 500 and p.is_active and p.renter_id = a.renter_id));

-- a review on the site: points whatever the rating, and the review says so
insert into reviews (booking_id, renter_id, vehicle_id, rating, body) values (test.id('booking:RWD-1'), test.id('renter:rwd_ben'), test.id('vehicle:rwd_car'), 2, 'The car was late.');
select test.ok('a 2-star site review earns 100 and is labelled', (select reward_points from reviews where booking_id = test.id('booking:RWD-1'))
  and exists (select 1 from reward_ledger where source_key = 'review_site:' || test.id('booking:RWD-1') and points = 100));

-- the renter's own actions
select set_config('request.jwt.claim.sub', test.id('rwd_ben')::text, false);
select test.eq('a follow: points on the click, and the page to open', public.rewards_mine_social('instagram') ->> 'url', 'https://instagram.com/x');
select test.eq('only once per platform', (public.rewards_mine_social('instagram') ->> 'points')::int, 0);
select test.throws('a platform with no page on file', $$select public.rewards_mine_social('facebook')$$, 'No facebook page');
select test.eq('a Google review on the renter''s word', (public.rewards_mine_google_claim('RWD-1', 'Ben R') ->> 'points')::int, 100);
select test.throws('once per rental', $$select public.rewards_mine_google_claim('RWD-1', 'Ben R')$$, 'already given');
select test.throws('redeem at least the minimum', $$select public.rewards_mine_redeem(100)$$, 'at least 500');
create temp table rwd_r as select public.rewards_mine_redeem(1000) r;
select test.ok('redeem 1000 points: a $10 code of his own, one use', exists (select 1 from promo_codes p, rwd_r where p.code = rwd_r.r ->> 'code'
  and p.amount_cents = 1000 and p.max_uses = 1 and p.renter_id = test.id('renter:rwd_ben') and p.source = 'rewards'));
select test.eq('the points left (2,300 earned less 1,000)', (public.my_rewards() ->> 'balance')::int, 1300);
select test.eq('an unused code cancelled gives the points back',
  (public.rewards_mine_code_cancel((select code from promo_codes where renter_id = test.id('renter:rwd_ben') and source = 'rewards' limit 1)) ->> 'points')::int, 1000);
select set_config('request.jwt.claim.sub', '', false);

-- Admin: settings, a way to earn off, adjust, reverse with a reason
select test.throws('Admins only', format($s$select public.door(%L, 'aal2', 'admin_do', 'rewards_adjust', '{"renter": "%s", "points": 10, "reason": "x"}')$s$, test.id('rwd_cs'), test.id('renter:rwd_ben')));
select test.throws('an adjustment needs its reason', format($s$select public.door(%L, 'aal2', 'admin_do', 'rewards_adjust', '{"renter": "%s", "points": 10}')$s$, test.id('rwd_admin'), test.id('renter:rwd_ben')), 'reason');
select public.door(test.id('rwd_admin'), 'aal2', 'admin_do', 'rewards_adjust', jsonb_build_object('renter', test.id('renter:rwd_ben'), 'points', 25, 'reason', 'Sorry for the wait'));
select public.door(test.id('rwd_admin'), 'aal2', 'admin_do', 'rewards_reverse', jsonb_build_object('id', (select id from reward_ledger where source_key = 'referral_referrer:' || test.id('renter:rwd_ben')), 'reason', 'Referral fraud'));
select test.eq('a reversal takes the points back', app.rewards_balance(test.id('renter:rwd_amy')), 0);
select test.throws('not twice', format($s$select public.door(%L, 'aal2', 'admin_do', 'rewards_reverse', '{"id": "%s", "reason": "again"}')$s$, test.id('rwd_admin'),
  (select id from reward_ledger where source_key = 'referral_referrer:' || test.id('renter:rwd_ben'))), 'Already reversed');
select test.ok('the Google claims list', jsonb_array_length(public.door(test.id('rwd_admin'), 'aal2', 'admin_read', 'rewards', '{}') -> 'google_claims') = 1);
select public.door(test.id('rwd_admin'), 'aal2', 'admin_do', 'rewards_action_save', '{"code": "review_google", "enabled": false}');
select set_config('request.jwt.claim.sub', test.id('rwd_ben')::text, false);
select test.ok('a way to earn turned off leaves the page', public.my_rewards() -> 'google' = 'null'::jsonb
  and not exists (select 1 from jsonb_array_elements(public.my_rewards() -> 'actions') a where a ->> 'code' = 'review_google'));
select set_config('request.jwt.claim.sub', '', false);

-- expiry: a reminder 30 days before, then the points end
update reward_ledger set created_at = now() - interval '11 months 10 days' where renter_id = test.id('renter:rwd_ben');
select app.job_rewards();
select test.ok('the reminder email is queued once', (select count(*) from app_events where code = 'renter_rewards_expiring' and entity_id = test.id('renter:rwd_ben')) = 1);
select app.job_rewards();
select test.eq('not twice', (select count(*)::int from app_events where code = 'renter_rewards_expiring' and entity_id = test.id('renter:rwd_ben')), 1);
update reward_ledger set created_at = now() - interval '13 months' where renter_id = test.id('renter:rwd_ben');
select app.job_rewards();
select test.eq('after 12 months with nothing, the points end', app.rewards_balance(test.id('renter:rwd_ben')), 0);
