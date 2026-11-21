-- 99: release 48 RW (3260 to 3265): notification preferences for everyone, staff rewards, owner rewards, the content
-- calendar with approval, and the owner's tracker alerts. Fixtures start with "zrw"; every address is example.test.
select test.suite('99 r48 RW: notification preferences, staff and owner rewards, content calendar, owner tracker alerts (3260-3265)');

-- ================================================================ fixtures
select test.mk_user('zrw_admin', 'admin');
select test.mk_renter('zrw_rita');
select test.mk_renter('zrw_first');
select test.mk_owner('zrw_olga', 'ZRWOLGA1');
select test.mk_owner('zrw_newo', 'ZRWNEWO1');
select test.mk_vehicle('zrw_car', 'zrw_olga', 'managed', 45000, 2500, 3500, (current_date - interval '7 months')::date);
select test.mk_vehicle('zrw_other', 'zrw_newo', 'managed', 45000, 2500, 3500, (current_date - interval '2 months')::date);
select test.mk_user('zrw_sara', 'va', 'sales');
select test.mk_user('zrw_remo', 'va', 'cs');
select test.mk_user('zrw_fin', 'va', 'finance');
select test.mk_user('zrw_finn', 'field');
update staff_profiles set sales_work_mode = 'in_person', location_country = 'CA', agreement_waived_at = now() where user_id = test.id('zrw_sara');
update staff_profiles set location_country = 'PH', agreement_waived_at = now() where user_id = test.id('zrw_remo');
update staff_profiles set location_country = 'CA', agreement_waived_at = now() where user_id = test.id('zrw_finn');
update program_settings set staff_perk_count_from = current_date - 400, staff_perk_enabled = true, owner_reward_enabled = true, social_cal_enabled = true;
-- the staff member's own renter account (the same sign-in)
insert into renters (id, user_id, legal_name, date_of_birth, mobile, email, identity_status)
values (test.id('renter:zrw_sara'), test.id('zrw_sara'), 'Zrw Sara', date '1992-02-02', '647-555-0142', 'zrw_sara@example.test', 'verified');
insert into renters (id, user_id, legal_name, date_of_birth, mobile, email, identity_status)
values (test.id('renter:zrw_olga'), test.id('zrw_olga'), 'Zrw Olga', date '1985-03-03', '647-555-0143', 'zrw_olga@example.test', 'verified');
insert into drivers (id, renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, identity_status)
select test.id('driver:' || x), test.id('renter:' || x), true, test.id(x), initcap(replace(x, '_', ' ')), date '1990-05-05', 'L' || upper(substr(md5(x), 1, 14)), 'G', 'ON', date '2030-01-01', 'verified' from unnest(array['zrw_sara', 'zrw_olga']) x;
insert into payment_methods (id, renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
select test.id('card:' || x), test.id('renter:' || x), 'visa', '4242', initcap(replace(x, '_', ' ')), 12, 2030, true from unnest(array['zrw_sara', 'zrw_olga']) x;

create or replace function test.zrw_mail(p_code text, p_user uuid, p_key text, p_audience text default 'renter', p_payload jsonb default '{}'::jsonb) returns text
language plpgsql as $$
declare v notification_outbox;
begin
  insert into notification_outbox (code, category, priority, audience, recipient_user_id, to_address, dedupe_key, payload)
  values (p_code, 'transactional', 1, p_audience, p_user, 'zrw@example.test', 'zrw:' || p_key, p_payload) returning * into v;
  return v.status || '|' || coalesce(v.status_reason, '');
end $$;

-- ================================================================ 1. notification preferences
select test.eq('the locked types: security, legal, charges, receipts, bookings, returns, safety, staff jobs, staff onboarding (and delivery notices)',
  (select string_agg(code, ',' order by code) from notify_types where locked), 'bookings,charges,legal,receipts,returns,safety,security,staff_jobs,staff_onboarding,system');
select test.eq('every code a renter, owner, investor, partner or staff member gets belongs to a type (alerts take their rule''s; marketing keeps its own consent)',
  (select coalesce(string_agg(code, ',' order by code), '') from notification_catalogue
    where pref_type is null and audience not in ('applicant', 'insurer') and code !~ '^(marketing_|renter_comeback|renter_recovery_request|owner_recruit)' and code not in ('staff_alert_urgent', 'staff_alert_normal', 'owner_tracker_alert')), '');
select test.eq('booking confirmations, receipts, security codes and return reminders are locked types',
  (select string_agg(c.code || '=' || c.pref_type, ',' order by c.code) from notification_catalogue c where c.code in ('renter_booking_confirmed', 'renter_payment_receipt', 'account_sign_in_link', 'renter_return_reminder', 'renter_extra_charge', 'renter_agreement_ready', 'staff_field_job_assigned', 'staff_access_suspended')),
  'account_sign_in_link=security,renter_agreement_ready=legal,renter_booking_confirmed=bookings,renter_extra_charge=charges,renter_payment_receipt=receipts,renter_return_reminder=returns,staff_access_suspended=staff_onboarding,staff_field_job_assigned=staff_jobs');
select test.ok('every staff alert rule has a type; a job assigned is locked',
  not exists (select 1 from staff_alert_rules where pref_type is null) and (select pref_type from staff_alert_rules where rule = 'job_assigned') = 'staff_jobs');

-- the owners' no-new-booking rule (2620) is now a type that is off by default
select test.eq('the three owner booking emails stay off in the catalogue, and the type is off by default',
  (select count(*) filter (where not c.is_enabled and c.pref_type = 'owner_new_bookings') || '|' || (select push_default or email_default or text_default from notify_types where code = 'owner_new_bookings')
     from notification_catalogue c where c.code in ('owner_new_booking', 'owner_booking_confirmed', 'owner_booking_changed')), '3|false');
select test.ok('an owner who chose nothing is not emailed about a new booking: nothing is queued at all', test.zrw_mail('owner_new_booking', test.id('zrw_olga'), 'nb1', 'owner') is null);
select test.ok('the trip completed email still goes', test.zrw_mail('owner_trip_completed', test.id('zrw_olga'), 'tc1', 'owner') like 'queued|%');
select public.server_notify_prefs_save(test.id('zrw_olga'), jsonb_build_object('type', 'owner_new_bookings', 'channel', 'email', 'on', true, 'portal', 'owner'));
select test.eq('the change is logged', (select count(*) from audit_log where entity_table = 'notify_prefs' and at > now() - interval '1 minute') > 0, true);

-- a renter: an optional type off, a locked type never
select test.ok('rewards emails go by default', test.zrw_mail('renter_rewards_points', test.id('zrw_rita'), 'rp1') like 'queued|%');
select public.server_notify_prefs_save(test.id('zrw_rita'), jsonb_build_object('type', 'rewards', 'channel', 'email', 'on', false));
select test.ok('email off for Rewards: not sent', test.zrw_mail('renter_rewards_points', test.id('zrw_rita'), 'rp2') like 'suppressed|not sent: turned off in notification preferences%');
select test.throws('a locked type cannot be switched off', $$select public.server_notify_prefs_save(test.id('zrw_rita'), '{"type": "bookings", "channel": "email", "on": false}'::jsonb)$$, 'always sent');
select test.throws('nor a security code', $$select public.server_notify_prefs_save(test.id('zrw_rita'), '{"type": "security", "channel": "text", "on": false}'::jsonb)$$, 'always sent');
select test.ok('a booking confirmation still goes', test.zrw_mail('renter_booking_confirmed', test.id('zrw_rita'), 'bc1') like 'queued|%');
select test.throws('a type of another portal is refused', $$select public.server_notify_prefs_save(test.id('zrw_rita'), '{"type": "staff_money", "channel": "email", "on": false}'::jsonb)$$, 'Unknown notification type');
select test.eq('the page: the renter sees their groups, the locked group first, each type with its channels',
  (select (g -> 0 ->> 'name') || '|' || (g -> 0 ->> 'locked') || '|' || (select count(*) from jsonb_array_elements(g) x, jsonb_array_elements(x -> 'types') t where t ->> 'code' = 'rewards' and (t ->> 'email')::boolean = false)
     from (select public.server_notify_prefs(test.id('zrw_rita'), 'renter') -> 'groups' as g) s), 'Always sent|true|1');

-- every optional notification off (Dwight's setting, migrated): optional ones stop, locked ones stay
select public.server_notify_prefs_save(test.id('zrw_finn'), '{"all_off": true}'::jsonb);
select test.ok('all off: an optional staff email is not sent', test.zrw_mail('staff_reward_update', test.id('zrw_finn'), 'so1', 'staff_field') like 'suppressed|not sent: turned off in notification preferences%');
select test.ok('all off: a job assigned to them still goes', test.zrw_mail('staff_field_job_assigned', test.id('zrw_finn'), 'so2', 'staff_field') not like 'suppressed|not sent: turned off in notification preferences%');
select test.ok('nobody is left on the old staff_notices_off switch', not exists (select 1 from users where staff_notices_off));
select public.server_notify_prefs_save(test.id('zrw_finn'), '{"all_off": false}'::jsonb);

-- a daily summary: the optional email is held as a line, the summary carries it once
select public.server_notify_prefs_save(test.id('zrw_first'), '{"cadence": "daily"}'::jsonb);
select test.ok('daily: an optional email is held for the summary', test.zrw_mail('renter_rewards_points', test.id('zrw_first'), 'dg1') like 'suppressed|not sent: in the daily summary%');
select test.ok('daily: a receipt still goes at once', test.zrw_mail('renter_payment_receipt', test.id('zrw_first'), 'dg2') like 'queued|%');
select test.eq('one line waits', (select count(*) from notify_digest_items where user_id = test.id('zrw_first') and sent_at is null), 1::bigint);
select test.eq('the summary goes after the hour and carries the line', app.job_notify_digest((current_date + 1)::timestamp at time zone 'America/Toronto' + interval '10 hours') >= 1, true);
select test.eq('its event names the person and the count', (select payload ->> 'count_words' from app_events where code = 'notify_summary' and entity_id = test.id('zrw_first') order by id desc limit 1), '1 update');
select test.eq('nothing waits after it', (select count(*) from notify_digest_items where user_id = test.id('zrw_first') and sent_at is null), 0::bigint);
select test.throws('an unknown rhythm is refused', $$select public.server_notify_prefs_save(test.id('zrw_first'), '{"cadence": "hourly"}'::jsonb)$$, 'Choose instant');
select public.server_notify_prefs_save(test.id('zrw_first'), '{"cadence": "instant"}'::jsonb);

-- quiet hours: an optional phone alert waits for the end; push off: none; a locked one goes at once
insert into push_subscriptions (id, user_id, endpoint, kind, p256dh, auth) values (test.id('zrw-push'), test.id('zrw_rita'), 'https://push.example.test/zrw', 'web', repeat('A', 87), repeat('B', 22));
select public.server_notify_prefs_save(test.id('zrw_rita'), jsonb_build_object('quiet_on', true, 'quiet_from', 0, 'quiet_until', 1439));
insert into push_outbox (subscription_id, user_id, code, title) values (test.id('zrw-push'), test.id('zrw_rita'), 'renter_staff_message', 'ZRW quiet');
select test.ok('quiet hours: the alert waits', (select send_after > now() + interval '1 minute' from push_outbox where title = 'ZRW quiet'));
insert into push_outbox (subscription_id, user_id, code, title) values (test.id('zrw-push'), test.id('zrw_rita'), 'renter_booking_confirmed', 'ZRW locked');
select test.ok('quiet hours never hold a locked type', (select send_after <= now() + interval '1 minute' from push_outbox where title = 'ZRW locked'));
select public.server_notify_prefs_save(test.id('zrw_rita'), jsonb_build_object('type', 'messages', 'channel', 'push', 'on', false));
insert into push_outbox (subscription_id, user_id, code, title) values (test.id('zrw-push'), test.id('zrw_rita'), 'renter_staff_message', 'ZRW off');
select test.eq('push off for a type: no alert is queued', (select count(*) from push_outbox where title = 'ZRW off'), 0::bigint);
select public.server_notify_prefs_save(test.id('zrw_rita'), jsonb_build_object('quiet_on', false));

-- the text of a type switched off is not sent; the fallback email of a text that cannot go is a locked type
create temp table zrw_t as select (app.phone_thread_for('+16475550188')).id as thread_id;
insert into notification_outbox (id, code, category, priority, audience, recipient_user_id, to_address, dedupe_key) values (test.id('zrw-n1'), 'renter_rewards_points', 'transactional', 1, 'renter', test.id('zrw_rita'), 'zrw_rita@example.test', 'zrw:txt1');
select public.server_notify_prefs_save(test.id('zrw_rita'), jsonb_build_object('type', 'rewards', 'channel', 'text', 'on', false));
insert into phone_outbox (id, thread_id, to_number, body, kind, sms_kind, notification_id, dedupe_key) values (test.id('zrw-p1'), (select thread_id from zrw_t), '+16475550188', 'ZRW points', 'notify', 'renter_rewards_points', test.id('zrw-n1'), 'zrw:p1');
select test.ok('text off for a type: the text is not sent', (select status = 'skipped' and status_reason like '%text turned off in notification preferences%' from phone_outbox where id = test.id('zrw-p1')));
select test.eq('a text that falls back to email is always delivered (locked)', (select t.locked from notification_catalogue c join notify_types t on t.code = c.pref_type where c.code = 'text_fell_back'), true);

-- a referral partner: invoices are always sent
insert into referral_partners (id, kind, business_name, referral_code, email) values (test.id('zrw-partner'), 'body_shop', 'Zrw Body Shop', 'ZRWSHOP1', 'zrw.shop@example.test');
select test.ok('a partner''s page lists the locked types only', (select bool_and((t ->> 'locked')::boolean) and count(*) >= 2
  from jsonb_array_elements(public.server_partner_notify_prefs(test.id('zrw-partner')) -> 'groups') g, jsonb_array_elements(g -> 'types') t));
select test.throws('a partner cannot switch an invoice notice off', $$select public.server_partner_notify_prefs_save(test.id('zrw-partner'), '{"type": "charges", "channel": "email", "on": false}'::jsonb)$$, 'always sent');

-- the Admin's view and a change for someone else
select test.ok('the Admin sees every type and the people who changed something',
  (select jsonb_array_length(v -> 'types') >= 25 and exists (select 1 from jsonb_array_elements(v -> 'people') x where x ->> 'user_id' = test.id('zrw_rita')::text)
     from (select app.door(test.id('zrw_admin'), 'aal2', 'admin_read', 'notify_prefs', '{}'::jsonb) as v) s));
select test.throws('only an Admin', $$select app.door(test.id('zrw_sara'), 'aal2', 'admin_read', 'notify_prefs', '{}'::jsonb)$$, 'Not permitted');
select app.door(test.id('zrw_admin'), 'aal2', 'admin_do', 'notify_pref_set', jsonb_build_object('user', test.id('zrw_rita'), 'type', 'reviews', 'channel', 'email', 'on', false));
select test.eq('an Admin''s change for a person is stored with who made it', (select updated_by from notify_prefs where subject_id = test.id('zrw_rita') and type = 'reviews'), test.id('zrw_admin'));

-- ================================================================ 2. staff rewards
select test.eq('in-person Sales in Canada, onboarded: eligible', (select eligible::text || '|' || coalesce(why_not, '') from app.staff_perk_facts(test.id('zrw_sara'))), 'true|');
select test.ok('a remote assistant gets no rental perks', (select not eligible and why_not like 'Rental perks are for in-person staff in Canada%' from app.staff_perk_facts(test.id('zrw_remo'))));
select test.ok('field staff in Canada: eligible', (select eligible from app.staff_perk_facts(test.id('zrw_finn'))));
select app.staff_perk_sync(test.id('zrw_sara'));
select app.staff_perk_sync(test.id('zrw_remo'));
select test.eq('day one: a 15% code on their own renter account, paid by CarmaCars',
  (select p.percent_bps || '|' || p.company_funded || '|' || (p.renter_id = test.id('renter:zrw_sara')) || '|' || p.source from staff_perk_codes c join promo_codes p on p.id = c.promo_code_id where c.user_id = test.id('zrw_sara') and c.kind = 'discount'),
  '1500|true|true|staff_perk_discount');
select test.eq('no code for the remote assistant', (select count(*) from staff_perk_codes where user_id = test.id('zrw_remo')), 0::bigint);
select test.eq('the perks-on notice was sent once', (select count(*) from app_events where code = 'staff_reward_update' and entity_id = test.id('zrw_sara') and payload ->> 'reward_title' = 'Your staff perks are on'), 1::bigint);

-- 100 rental days booked this month: a free day, Gold, the bonus day
select test.mk_booking('ZRW-S1', 'zrw_car', 'zrw_rita', to_char(current_date + 40, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 70, 'YYYY-MM-DD') || ' 10:00', 'confirmed');
select test.mk_booking('ZRW-S2', 'zrw_other', 'zrw_rita', to_char(current_date + 40, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 70, 'YYYY-MM-DD') || ' 10:00', 'confirmed');
select test.mk_booking('ZRW-S3', 'zrw_car', 'zrw_rita', to_char(current_date + 80, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 110, 'YYYY-MM-DD') || ' 10:00', 'confirmed');
select test.mk_booking('ZRW-S4', 'zrw_other', 'zrw_rita', to_char(current_date + 80, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 90, 'YYYY-MM-DD') || ' 10:00', 'confirmed');
update bookings set sales_staff_id = test.id('zrw_sara'), sales_source = 'offer', sales_attributed_at = now(), confirmed_at = now() where booking_number in ('ZRW-S1', 'ZRW-S2', 'ZRW-S3', 'ZRW-S4');
select app.staff_perk_sync(test.id('zrw_sara'));
select test.eq('100 rental days booked this month', app.staff_perk_month_days(test.id('zrw_sara'), current_date), 100);
select test.eq('Gold: 25% off', (select app.staff_perk_tier(test.id('zrw_sara')) || '|' || p.percent_bps from staff_perk_codes c join promo_codes p on p.id = c.promo_code_id where c.user_id = test.id('zrw_sara') and c.kind = 'discount'), 'gold|2500');
select test.eq('1 free day per 100 rental days, and Gold''s bonus day', (select string_agg(source || ':' || days, ',' order by source) from staff_free_days where user_id = test.id('zrw_sara')), 'gold_bonus:1,sales_days:1');
select test.eq('two free days to use, ending in 6 months', (select app.staff_perk_balance(test.id('zrw_sara')) || '|' || bool_and(expires_at between now() + interval '5 months' and now() + interval '7 months') from staff_free_days where user_id = test.id('zrw_sara')), '2|true');
select app.staff_perk_sync(test.id('zrw_sara'));
select test.eq('syncing again gives nothing twice', (select count(*) from staff_free_days where user_id = test.id('zrw_sara')), 2::bigint);
select test.ok('the tier and the free day were announced', (select count(*) from app_events where code = 'staff_reward_update' and entity_id = test.id('zrw_sara') and (payload ->> 'reward_title' in ('You reached Gold', 'You earned a free rental day'))) = 2);

-- the card, a free-day code, and taking it back
select test.eq('the card: eligible, Gold, 2 free days, the progress toward the next',
  (select (v ->> 'eligible') || '|' || (v #>> '{discount,tier}') || '|' || (v #>> '{free_days,balance}') || '|' || (v #>> '{progress,sales,toward}') || '|' || jsonb_array_length(v -> 'rules')
     from (select app.door(test.id('zrw_sara'), 'aal2', 'ops_read', 'my_rewards', '{}'::jsonb) as v) s), 'true|gold|2|0|6');
create temp table zrw_code as select app.door(test.id('zrw_sara'), 'aal2', 'ops_do', 'my_rewards_code', '{"days": 2}'::jsonb) ->> 'issued' as code;
select test.eq('a free-day code for 2 days: one use, the staff member''s own, paid by CarmaCars',
  (select p.free_days || '|' || p.max_uses || '|' || p.company_funded || '|' || (p.renter_id = test.id('renter:zrw_sara')) from promo_codes p where p.code = (select code from zrw_code)), '2|1|true|true');
select test.eq('the days are on the code', app.staff_perk_balance(test.id('zrw_sara')), 0);
select test.throws('no more days than earned', $$select app.staff_perk_code_issue(test.id('zrw_sara'), '{"days": 1}'::jsonb)$$, 'free rental day');
select app.door(test.id('zrw_sara'), 'aal2', 'ops_do', 'my_rewards_code_cancel', jsonb_build_object('code', (select code from zrw_code)));
select test.eq('an unused code cancelled gives the days back', app.staff_perk_balance(test.id('zrw_sara')), 2);
select test.throws('the remote assistant cannot get a code', $$select app.staff_perk_code_issue(test.id('zrw_remo'), '{"days": 1}'::jsonb)$$, 'in-person staff in Canada');

-- the rules where every code is checked
create temp table zrw_disc as select p.code from staff_perk_codes c join promo_codes p on p.id = c.promo_code_id where c.user_id = test.id('zrw_sara') and c.kind = 'discount';
select test.mk_booking('ZRW-P1', 'zrw_car', 'zrw_sara', to_char(current_date + 1, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 3, 'YYYY-MM-DD') || ' 10:00', 'requested');
update bookings set requested_at = now() where booking_number = 'ZRW-P1';
select test.eq('their own last-minute request: the code works', app.promo_code_problem((select code from zrw_disc), test.id('renter:zrw_sara'), test.id('booking:ZRW-P1')), null::text);
select test.ok('someone else''s account: refused (the staff member is the driver)', app.promo_code_problem((select code from zrw_disc), test.id('renter:zrw_rita'), null) like 'A staff perk is for a rental you drive yourself%');
select test.mk_booking('ZRW-P2', 'zrw_car', 'zrw_sara', to_char(current_date + 20, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 22, 'YYYY-MM-DD') || ' 10:00', 'requested');
update bookings set requested_at = now() where booking_number = 'ZRW-P2';
select test.ok('booked weeks ahead: refused (never in the way of a paying renter)', app.promo_code_problem((select code from zrw_disc), test.id('renter:zrw_sara'), test.id('booking:ZRW-P2')) like 'Staff perks are for last-minute rentals: pick up within 48 hours%');
select test.mk_booking('ZRW-P3', 'zrw_car', 'zrw_rita', to_char(current_date + 2, 'YYYY-MM-DD') || ' 09:00', to_char(current_date + 4, 'YYYY-MM-DD') || ' 09:00', 'requested');
select test.ok('a renter asked for the car on those dates: refused', app.promo_code_problem((select code from zrw_disc), test.id('renter:zrw_sara'), test.id('booking:ZRW-P1')) like 'A renter has asked for this car%');
update bookings set status = 'declined' where booking_number = 'ZRW-P3';
update vehicles set class = 'exotic' where id = test.id('vehicle:zrw_car');
select test.eq('an exotic car: refused', app.promo_code_problem((select code from zrw_disc), test.id('renter:zrw_sara'), test.id('booking:ZRW-P1')), 'Staff perks are not for exotic cars');
update vehicles set class = 'premium' where id = test.id('vehicle:zrw_car');
delete from vehicle_class_links where vehicle_id = test.id('vehicle:zrw_car') and class_code = 'exotic';
-- a free day on a co-host owner's car while a CarmaCars or shareholder car is free: refused; with none free: allowed, the owner paid in full
create temp table zrw_cc_down as select id, status from vehicles where id <> test.id('vehicle:zrw_car') and (supply_type::text = 'company' or is_shareholder_owned) and status::text = 'available';
update vehicles set status = 'out_of_service' where id in (select id from zrw_cc_down);
create temp table zrw_free as select app.staff_perk_code_issue(test.id('zrw_sara'), '{"days": 1}'::jsonb) ->> 'issued' as code;
select test.eq('a free day on an owner''s car with no CarmaCars car free: allowed', app.promo_code_problem((select code from zrw_free), test.id('renter:zrw_sara'), test.id('booking:ZRW-P1')), null::text);
select test.mk_owner('zrw_share', 'ZRWSHAR1', null, true);
select test.mk_vehicle('zrw_sharecar', 'zrw_share', 'managed', 0, 0, 3500, date '2026-09-01', true);
select test.ok('a shareholder car free on those dates: the free day goes there first', app.promo_code_problem((select code from zrw_free), test.id('renter:zrw_sara'), test.id('booking:ZRW-P1')) like 'Free days go on a CarmaCars car first%');
update vehicles set status = 'out_of_service' where id = test.id('vehicle:zrw_sharecar');
update vehicles v set status = d.status from zrw_cc_down d where v.id = d.id;

-- used: the owner is paid as at the full rate (company_funded) and the perk is a staff benefit expense in the books
select app.apply_promo_code(test.id('booking:ZRW-P1'), (select code from zrw_disc), test.id('zrw_sara'));
select test.ok('the discount is on the request', (select promo_discount_cents > 0 from bookings where id = test.id('booking:ZRW-P1')));
select test.eq('the Admins are told a staff perk is on a request', (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'staff_perk_booking' and entity_id = test.id('booking:ZRW-P1')), 1::bigint);
update promo_redemptions set status = 'redeemed', redeemed_at = now() where booking_id = test.id('booking:ZRW-P1');
select test.eq('used: posted as a staff benefit expense (account 5300) for the amount of the discount',
  (select e.category || '|' || (e.amount_cents = r.discount_cents) || '|' || (e.staff_user_id = test.id('zrw_sara')) || '|' || (select gl_account from company_expense_categories where code = e.category)
     from promo_redemptions r join reward_postings x on x.redemption_id = r.id join company_expenses e on e.id = x.expense_id where r.booking_id = test.id('booking:ZRW-P1')), 'staff_benefit|true|true|5300');
update promo_redemptions set status = 'released', released_at = now() where booking_id = test.id('booking:ZRW-P1');
select test.eq('the code taken off: the expense is voided', (select count(*) filter (where voided_at is not null) || '|' || count(*) from company_expenses where category = 'staff_benefit' and staff_user_id = test.id('zrw_sara')), '1|1');

-- a suspension freezes the perks; they come back with the access
update staff_profiles set inactive_locked_at = now() where user_id = test.id('zrw_sara');
select test.ok('suspended: frozen', (select frozen and not eligible from app.staff_perk_facts(test.id('zrw_sara'))) and app.promo_code_problem((select code from zrw_disc), test.id('renter:zrw_sara'), null) like '%perks are frozen%');
update staff_profiles set inactive_locked_at = null where user_id = test.id('zrw_sara');
select test.ok('restored: the code works again', (select eligible from app.staff_perk_facts(test.id('zrw_sara'))) and (select p.is_active from promo_codes p where p.code = (select code from zrw_disc)));

-- field staff: 1 free day per 100 handovers
insert into field_jobs (kind, vehicle_id, assigned_to, scheduled_at, status, completed_at)
select case when g % 2 = 0 then 'handover' else 'delivery' end, test.id('vehicle:zrw_car'), test.id('zrw_finn'), now() - interval '2 days', 'done', now() - interval '1 day' from generate_series(1, 100) g;
insert into field_jobs (kind, vehicle_id, assigned_to, scheduled_at, status, completed_at) select 'detail', test.id('vehicle:zrw_car'), test.id('zrw_finn'), now() - interval '2 days', 'done', now() - interval '1 day' from generate_series(1, 30);
select app.staff_perk_sync(test.id('zrw_finn'));
select test.eq('100 handovers: one free day (a detail is not a handover)', (select app.staff_perk_total_handovers(test.id('zrw_finn')) || '|' || app.staff_perk_balance(test.id('zrw_finn'))), '100|1');
update staff_free_days set expires_at = now() - interval '1 day' where user_id = test.id('zrw_finn');
select test.eq('a free day past its 6 months is gone', app.staff_perk_balance(test.id('zrw_finn')), 0);

-- the top seller of last month: a free weekend, once
update bookings set confirmed_at = date_trunc('month', now()) - interval '10 days' where booking_number = 'ZRW-S4';
delete from staff_free_days where source = 'top_seller';
select app.job_staff_perks();
select test.eq('top seller of last month: 2 free days (a weekend), to one person', (select string_agg(user_id::text || ':' || days, ',') from staff_free_days where source = 'top_seller'), test.id('zrw_sara')::text || ':2');
select app.job_staff_perks();
select test.eq('the job run again gives no second weekend', (select count(*) from staff_free_days where source = 'top_seller'), 1::bigint);

-- the Admin's view and changes
select test.ok('the Admin sees every staff member, who is eligible and why not',
  (select exists (select 1 from jsonb_array_elements(v -> 'staff') x where x ->> 'user_id' = test.id('zrw_remo')::text and (x ->> 'eligible')::boolean = false)
      and exists (select 1 from jsonb_array_elements(v -> 'staff') x where x ->> 'user_id' = test.id('zrw_sara')::text and x ->> 'tier' in ('gold', 'silver', 'member'))
     from (select app.door(test.id('zrw_admin'), 'aal2', 'admin_read', 'staff_perks', '{}'::jsonb) as v) s));
select test.throws('staff cannot open the Admin''s view', $$select app.door(test.id('zrw_sara'), 'aal2', 'admin_read', 'staff_perks', '{}'::jsonb)$$, 'Not permitted');
select app.door(test.id('zrw_admin'), 'aal2', 'admin_do', 'staff_perk_set', jsonb_build_object('user', test.id('zrw_sara'), 'eligible', 'no', 'note', 'On leave.'));
select test.eq('an Admin switched one person''s perks off, with the reason they read', (select eligible::text || '|' || why_not from app.staff_perk_facts(test.id('zrw_sara'))), 'false|On leave.');
select app.door(test.id('zrw_admin'), 'aal2', 'admin_do', 'staff_perk_set', jsonb_build_object('user', test.id('zrw_sara'), 'eligible', ''));
select test.throws('an adjustment needs its reason', $$select app.door(test.id('zrw_admin'), 'aal2', 'admin_do', 'staff_perk_adjust', jsonb_build_object('user', test.id('zrw_finn'), 'days', 1))$$, 'Say why');
select test.eq('every number is a Program setting', (select count(*) from information_schema.columns where table_name = 'program_settings' and column_name like 'staff_perk_%'), 15::bigint);

-- ================================================================ 3. owner rewards
select app.owner_reward_sync(test.id('owner:zrw_olga'));
select test.eq('the friends-and-family code is the owner''s own code: 10% off, public, paid by CarmaCars',
  (select p.code || '|' || p.percent_bps || '|' || p.company_funded || '|' || (p.renter_id is null) from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id where c.owner_id = test.id('owner:zrw_olga') and c.kind = 'ff'), 'ZRWOLGA1|1000|true|true');
select test.eq('the fleet discount: 20% on the owner''s own renter account',
  (select p.percent_bps || '|' || (p.renter_id = test.id('renter:zrw_olga')) || '|' || p.source from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id where c.owner_id = test.id('owner:zrw_olga') and c.kind = 'fleet'), '2000|true|owner_reward_fleet');
create temp table zrw_fleet as select p.code from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id where c.owner_id = test.id('owner:zrw_olga') and c.kind = 'fleet';
select test.mk_booking('ZRW-O1', 'zrw_other', 'zrw_olga', to_char(current_date + 5, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 7, 'YYYY-MM-DD') || ' 10:00', 'requested');
select test.ok('their own car is free on those dates: the fleet discount does not apply', app.promo_code_problem((select code from zrw_fleet), test.id('renter:zrw_olga'), test.id('booking:ZRW-O1')) like 'The fleet discount is for dates your own car is on rent%');
select test.mk_booking('ZRW-O2', 'zrw_car', 'zrw_rita', to_char(current_date + 4, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 8, 'YYYY-MM-DD') || ' 10:00', 'confirmed');
select test.eq('their own car is on rent on those dates: 20% off another car', app.promo_code_problem((select code from zrw_fleet), test.id('renter:zrw_olga'), test.id('booking:ZRW-O1')), null::text);
update vehicles set class = 'exotic' where id = test.id('vehicle:zrw_other');
select test.eq('never on an exotic car', app.promo_code_problem((select code from zrw_fleet), test.id('renter:zrw_olga'), test.id('booking:ZRW-O1')), 'Owner rewards are not for exotic cars');
update vehicles set class = 'premium' where id = test.id('vehicle:zrw_other');
delete from vehicle_class_links where vehicle_id = test.id('vehicle:zrw_other') and class_code = 'exotic';
select test.ok('another person cannot use the owner''s fleet code', app.promo_code_problem((select code from zrw_fleet), test.id('renter:zrw_rita'), null) like 'An owner reward is for a rental you drive yourself%');
-- friends and family: a first rental only, never the owner's own
select test.eq('a friend''s first rental: the code works', app.promo_code_problem('ZRWOLGA1', test.id('renter:zrw_first'), null), null::text);
select test.eq('a renter who rented before: refused', app.promo_code_problem('ZRWOLGA1', test.id('renter:zrw_rita'), null), 'This code is for a first rental with CarmaCars');
select test.ok('the owner''s own account: refused', app.promo_code_problem('ZRWOLGA1', test.id('renter:zrw_olga'), null) like 'This is your own code%');
-- a friend's booking confirmed: the owner is told (the 20% kickback itself is the existing one)
select test.mk_booking('ZRW-F1', 'zrw_other', 'zrw_first', to_char(current_date + 12, 'YYYY-MM-DD') || ' 10:00', to_char(current_date + 14, 'YYYY-MM-DD') || ' 10:00', 'pending_payment', null, 'standard', 'ZRWOLGA1');
select test.eq('the code names the owner as the referrer', (select referrer_type || '|' || (referrer_owner_id = test.id('owner:zrw_olga')) from bookings where booking_number = 'ZRW-F1'), 'owner|true');

-- the merch kit: a button, the address, a To do for the Admins, shipped
select test.eq('7 months in: the kit is reached, the premium kit is not',
  (select string_agg((m ->> 'kind') || '=' || (m ->> 'reached'), ',' order by (m ->> 'months')::integer) from jsonb_array_elements(public.owner_portal_rewards(test.id('zrw_olga')) -> 'milestones') m), 'merch_kit=true,merch_kit_premium=false');
select test.eq('nothing ships by itself', (select count(*) from owner_reward_requests where owner_id = test.id('owner:zrw_olga')), 0::bigint);
select test.throws('the address is confirmed first', $$select public.owner_portal_reward_do(test.id('zrw_olga'), 'redeem_kit', '{"kind": "merch_kit", "name": "Zrw Olga"}'::jsonb)$$, 'Confirm the name');
select test.throws('the premium kit waits for 12 months', $$select public.owner_portal_reward_do(test.id('zrw_olga'), 'redeem_kit', '{"kind": "merch_kit_premium", "name": "Zrw Olga", "line1": "1 Test Lane", "city": "Toronto", "postal_code": "M5V 1A1"}'::jsonb)$$, 'after 12 months');
select public.owner_portal_reward_do(test.id('zrw_olga'), 'redeem_kit', '{"kind": "merch_kit", "name": "Zrw Olga", "line1": "1 Test Lane", "city": "Toronto", "province": "ON", "postal_code": "m5v 1a1", "size": "L"}'::jsonb);
select test.eq('redeemed: waiting to ship, with the address', (select status || '|' || ship_city || '|' || ship_postal_code || '|' || size from owner_reward_requests where owner_id = test.id('owner:zrw_olga') and kind = 'merch_kit'), 'requested|Toronto|M5V 1A1|L');
select test.throws('the same kit is not redeemed twice', $$select public.owner_portal_reward_do(test.id('zrw_olga'), 'redeem_kit', '{"kind": "merch_kit", "name": "Zrw Olga", "line1": "1 Test Lane", "city": "Toronto", "postal_code": "M5V 1A1"}'::jsonb)$$, 'already redeemed');
select test.ok('Admin > To do has the kit to ship', (select exists (select 1 from jsonb_array_elements(app.admin_todo(test.id('zrw_admin')) -> 'items') i where i ->> 'key' = 'owner_merch_ship' and (i ->> 'count')::integer >= 1)));
select test.eq('the Admins got the alert', (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'owner_merch_to_ship' and entity_id = test.id('owner:zrw_olga')), 1::bigint);
select app.door(test.id('zrw_admin'), 'aal2', 'admin_do', 'owner_reward_ship', jsonb_build_object('id', (select id from owner_reward_requests where owner_id = test.id('owner:zrw_olga') and kind = 'merch_kit'), 'tracking', 'CP123', 'cost_cents', 4000));
select test.eq('shipped: the status, the tracking, and its cost in the books (account 5310)',
  (select q.status || '|' || q.tracking || '|' || (select e.amount_cents || '|' || c.gl_account from company_expenses e join company_expense_categories c on c.code = e.category where e.owner_id = q.owner_id and e.category = 'owner_reward' and e.description like '%merch kit shipped%')
     from owner_reward_requests q where q.owner_id = test.id('owner:zrw_olga') and q.kind = 'merch_kit'), 'shipped|CP123|4000|5310');
select test.eq('the owner''s tab shows Shipped', (select m #>> '{request,status}' from jsonb_array_elements(public.owner_portal_rewards(test.id('zrw_olga')) -> 'milestones') m where m ->> 'kind' = 'merch_kit'), 'shipped');
select test.ok('the owner was told at each step (ready is not sent after redeeming)', (select count(*) from app_events where code = 'owner_reward_update' and entity_id = test.id('owner:zrw_olga') and payload ->> 'reward_title' in ('Your merch kit is on our list to ship', 'Your merch kit has shipped')) = 2);

-- refer an owner: $100 once their car has been live 30 days, a line on the statement, in the books
insert into owner_referral_links (referrer_owner_id, referred_owner_id) values (test.id('owner:zrw_olga'), test.id('owner:zrw_newo'));
insert into vehicle_listings (vehicle_id, slug, status, first_published_at, published_at) values (test.id('vehicle:zrw_other'), 'zrw-other-car', 'published', now() - interval '10 days', now() - interval '10 days')
on conflict (vehicle_id) do update set status = 'published', first_published_at = now() - interval '10 days';
select app.owner_reward_sync(test.id('owner:zrw_olga'));
select test.eq('live 10 days: no credit yet', (select count(*) from owner_reward_ledger where owner_id = test.id('owner:zrw_olga') and kind = 'refer_owner'), 0::bigint);
update vehicle_listings set first_published_at = now() - interval '31 days' where vehicle_id = test.id('vehicle:zrw_other');
select app.owner_reward_sync(test.id('owner:zrw_olga'));
select app.owner_reward_sync(test.id('owner:zrw_olga'));
select test.eq('live 31 days: a $100 credit, once: an open statement credit and an expense',
  (select count(*) || '|' || max(g.amount_cents) || '|' || max(c.kind) || '|' || max(c.status) || '|' || max(e.category) from owner_reward_ledger g join owner_credits c on c.id = g.owner_credit_id join company_expenses e on e.id = g.expense_id
    where g.owner_id = test.id('owner:zrw_olga') and g.kind = 'refer_owner'), '1|10000|reward_credit|open|owner_reward');
select test.ok('the credit''s words are the statement line', (select description like 'Owner rewards: you referred %($100.00 credit)' from owner_credits where owner_id = test.id('owner:zrw_olga') and kind = 'reward_credit'));

-- the birthday credit
insert into owner_private_details (owner_id, date_of_birth) values (test.id('owner:zrw_olga'), (app.local_date(now()) - interval '40 years')::date)
on conflict (owner_id) do update set date_of_birth = excluded.date_of_birth;
select app.owner_reward_sync(test.id('owner:zrw_olga'));
select app.owner_reward_sync(test.id('owner:zrw_olga'));
select test.eq('on the birthday: a $25 rental credit code, once a year',
  (select count(*) || '|' || max(p.amount_cents) || '|' || bool_and(p.company_funded and p.max_uses = 1) from owner_reward_codes c join promo_codes p on p.id = c.promo_code_id where c.owner_id = test.id('owner:zrw_olga') and c.kind = 'birthday'), '1|2500|true');

-- a free upgrade: the owner asks, an Admin approves
select test.throws('the owner says what happened', $$select public.owner_portal_reward_do(test.id('zrw_olga'), 'upgrade_ask', jsonb_build_object('vehicle', test.id('vehicle:zrw_car')))$$, 'Say what happened');
select public.owner_portal_reward_do(test.id('zrw_olga'), 'upgrade_ask', jsonb_build_object('vehicle', test.id('vehicle:zrw_car'), 'note', 'Scratched at a handover.'));
select test.ok('Admin > To do has the upgrade to answer', (select exists (select 1 from jsonb_array_elements(app.admin_todo(test.id('zrw_admin')) -> 'items') i where i ->> 'key' = 'owner_upgrade')));
select app.door(test.id('zrw_admin'), 'aal2', 'admin_do', 'owner_reward_upgrade_decide', jsonb_build_object('id', (select id from owner_reward_requests where owner_id = test.id('owner:zrw_olga') and kind = 'upgrade'), 'approve', 'yes', 'amount_cents', 6000));
select test.eq('approved: a one-time code for the difference', (select q.status || '|' || p.amount_cents || '|' || p.source from owner_reward_requests q join promo_codes p on p.id = q.promo_code_id where q.owner_id = test.id('owner:zrw_olga') and q.kind = 'upgrade'), 'approved|6000|owner_reward_upgrade');
select test.throws('the owner cannot answer their own request', $$select app.door(test.id('zrw_olga'), 'aal2', 'admin_do', 'owner_reward_upgrade_decide', '{}'::jsonb)$$, null);
select test.eq('the tab: codes, link, QR address and history', (select (v ->> 'on') || '|' || (v #>> '{friends,code}') || '|' || ((v #>> '{friends,link}') like '%/r/ZRWOLGA1') || '|' || (jsonb_array_length(v -> 'history') >= 4) || '|' || jsonb_array_length(v -> 'perks')
  from (select public.owner_portal_rewards(test.id('zrw_olga')) as v) s), 'true|ZRWOLGA1|true|true|2');
update owners set kind = 'partner' where id = test.id('owner:zrw_newo');
select test.eq('a partner rental company has no owner rewards', public.owner_portal_rewards(test.id('zrw_newo')) ->> 'on', 'false');
update owners set kind = 'program' where id = test.id('owner:zrw_newo');
select test.ok('the Admin''s view lists the requests and the owners', (select jsonb_array_length(v -> 'requests') >= 2 and jsonb_array_length(v -> 'owners') >= 1 from (select app.door(test.id('zrw_admin'), 'aal2', 'admin_read', 'owner_rewards', '{}'::jsonb) as v) s));

-- ================================================================ 4. the content calendar
create temp table zrw_month as select date_trunc('month', current_date + interval '2 months')::date as m;
create or replace function test.zrw_posts() returns jsonb language sql as $$
  select jsonb_build_object('month', (select m from zrw_month), 'plan', app.social_cal_plan(), 'learned', '{}'::jsonb, 'posts', jsonb_build_array(
    jsonb_build_object('slot_no', 1, 'slot_date', (select m + 2 from zrw_month), 'format', 'photo', 'pillar', 'fleet', 'kind', 'featured_car', 'channels', '["instagram","facebook_page"]'::jsonb, 'vehicle_id', test.id('vehicle:zrw_car'),
      'hook', 'ZRW hook', 'caption', 'ZRW photo caption.', 'hashtags', '["#CarmaCars","#Toronto"]'::jsonb, 'music', 'Upbeat', 'best_times', '{"instagram":"12:00","facebook_page":"09:30"}'::jsonb, 'link', 'https://carmacars.ca/cars/zrw', 'photos', '["vehicles/zrw/cover.jpg"]'::jsonb),
    jsonb_build_object('slot_no', 2, 'slot_date', (select m + 4 from zrw_month), 'format', 'story', 'pillar', 'trust', 'kind', 'requirements', 'channels', '["instagram"]'::jsonb,
      'caption', 'ZRW story caption.', 'hashtags', '[]'::jsonb, 'best_times', '{"instagram":"18:30"}'::jsonb, 'photos', '["site/zrw-story.jpg"]'::jsonb),
    jsonb_build_object('slot_no', 3, 'slot_date', (select m + 6 from zrw_month), 'format', 'reel', 'pillar', 'offers', 'kind', 'price_highlight', 'channels', '["instagram","facebook_page","tiktok"]'::jsonb, 'vehicle_id', test.id('vehicle:zrw_car'),
      'caption', 'ZRW reel caption.', 'hashtags', '["#CarmaCars"]'::jsonb, 'music', 'Bright', 'best_times', '{"instagram":"18:30","facebook_page":"19:00","tiktok":"19:00"}'::jsonb, 'photos', '["vehicles/zrw/cover.jpg"]'::jsonb))) $$;
select test.eq('a month''s calendar is stored: 3 posts waiting', public.server_social_calendar_put(test.zrw_posts()), 3);
select test.eq('written again: nothing is overwritten', public.server_social_calendar_put(test.zrw_posts()), 0);
select test.eq('Marketing is told once that it is ready to approve', (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'social_calendar_ready' and payload ->> 'kind' like '%' || to_char((select m from zrw_month), 'YYYYMM')), 1::bigint);
select test.eq('nothing is queued to publish before an approval', (select count(*) from social_queue q join social_drafts d on d.id = q.draft_id where d.month = (select m from zrw_month)), 0::bigint);
select test.eq('the calendar read: the month, its posts, the plan, Meta and the auto-reply rule',
  (select (v ->> 'label') = to_char((select m from zrw_month), 'FMMonth YYYY') and jsonb_array_length(v -> 'posts') = 3 and (v #>> '{counts,draft}') = '3' and v ? 'meta' and (v #>> '{auto_reply,rule}') like 'Comments and direct messages%'
     from (select app.door(test.id('zrw_sara'), 'aal2', 'va_read', 'social_calendar', jsonb_build_object('month', to_char((select m from zrw_month), 'YYYY-MM'), '_va', 'sales')) as v) s), true);
select test.throws('Finance is not Marketing', $$select app.door(test.id('zrw_fin'), 'aal2', 'va_read', 'social_calendar', '{"_va": "finance"}'::jsonb)$$, 'Not permitted');
select test.ok('the Admin sees the same calendar', (select jsonb_array_length(app.door(test.id('zrw_admin'), 'aal2', 'admin_read', 'social_calendar', jsonb_build_object('month', to_char((select m from zrw_month), 'YYYY-MM'))) -> 'posts') = 3));

create temp table zrw_p as select id, slot_no from social_drafts where month = (select m from zrw_month) and source = 'calendar';
-- edit, reject, restore, regenerate
select app.door(test.id('zrw_sara'), 'aal2', 'va_do', 'social_cal_save', jsonb_build_object('id', (select id from zrw_p where slot_no = 1), 'caption', 'ZRW edited caption.', 'hashtags', 'CarmaCars, #GTA rentals', '_va', 'sales'));
select test.eq('an edit: the caption, the tags tidied, marked edited', (select caption || '|' || array_to_string(hashtags, ' ') || '|' || edited from social_drafts where id = (select id from zrw_p where slot_no = 1)), 'ZRW edited caption.|#CarmaCars #GTA #rentals|true');
select test.throws('a reject says why', $$select app.social_cal_decide(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 2), 'action', 'reject'))$$, 'Say why');
select app.social_cal_decide(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 2), 'action', 'reject', 'reason', 'Off brand.'));
select test.eq('rejected, with the reason', (select status || '|' || reject_reason from social_drafts where id = (select id from zrw_p where slot_no = 2)), 'rejected|Off brand.');
select app.social_cal_save(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 2), 'regenerated', true, 'caption', 'ZRW story rewritten.', 'photos', '["site/zrw-story2.jpg"]'::jsonb));
select test.eq('regenerated: a new draft in the same slot', (select status || '|' || regenerated || '|' || caption || '|' || (photos ->> 0) from social_drafts where id = (select id from zrw_p where slot_no = 2)), 'draft|1|ZRW story rewritten.|site/zrw-story2.jpg');
select test.throws('a long dash is refused in a caption', $$select app.social_cal_save(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 2), 'caption', 'A ' || chr(8212) || ' B'))$$, 'long dash');

-- approve: the queue, per channel, at the best time; a story by hand; a reel needs its video
select app.door(test.id('zrw_sara'), 'aal2', 'va_do', 'social_cal_decide', jsonb_build_object('id', (select id from zrw_p where slot_no = 1), 'action', 'approve', '_va', 'sales'));
select test.eq('approved photo: one queue row per channel at its best time, the tags on the caption, through Meta',
  (select string_agg(q.channel || '@' || to_char(q.scheduled_at at time zone 'America/Toronto', 'HH24:MI') || ':' || q.by_hand || ':' || q.format, ',' order by q.channel) || '|' || bool_and(q.caption like 'ZRW edited caption.%#CarmaCars%')
     from social_queue q where q.draft_id = (select id from zrw_p where slot_no = 1)), 'facebook_page@09:30:false:photo,instagram@12:00:false:photo|true');
select app.social_cal_decide(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 2), 'action', 'approve'));
select test.eq('a story is posted by hand', (select string_agg(channel || ':' || by_hand, ',') from social_queue where draft_id = (select id from zrw_p where slot_no = 2)), 'instagram:true');
select test.throws('a reel needs a short video first', $$select app.social_cal_decide(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 3), 'action', 'approve'))$$, 'needs a short video');
insert into social_videos (id, vehicle_id, path, mime, seconds, bytes) values (test.id('zrw-video'), test.id('vehicle:zrw_car'), 'vehicles/' || test.id('vehicle:zrw_car') || '/social/' || test.id('zrw-video') || '.mp4', 'video/mp4', 12, 2000000);
select app.social_cal_decide(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 3), 'action', 'approve', 'music', 'A trending sound'));
select test.eq('approved reel: the video on the Page, Instagram and TikTok, with the music picked at approval',
  (select string_agg(channel || ':' || media_kind, ',' order by channel) || '|' || max(music) from social_queue where draft_id = (select id from zrw_p where slot_no = 3)), 'facebook_page:video,instagram:video,tiktok:video|A trending sound');
select test.throws('an approved post is edited only after the approval is taken back', $$select app.social_cal_save(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 1), 'caption', 'Later.'))$$, 'Take the approval back');
select app.social_cal_decide(test.id('zrw_sara'), jsonb_build_object('id', (select id from zrw_p where slot_no = 1), 'action', 'unapprove'));
select test.eq('approval taken back: its queue rows are cancelled, the post is a draft again', (select d.status || '|' || (select count(*) from social_queue q where q.draft_id = d.id and q.status <> 'cancelled') from social_drafts d where d.id = (select id from zrw_p where slot_no = 1)), 'draft|0');

-- due by hand: Marketing is told; Meta never takes a by-hand post; posted and its results; what the results teach
update social_queue set scheduled_at = now() - interval '1 minute' where draft_id in (select id from zrw_p where slot_no in (2, 3));
select app.job_social_queue();
select test.ok('due by hand (the story, TikTok, and everything while Meta is not connected): one alert each', (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'social_post_by_hand' and created_at > now() - interval '1 minute') >= 2);
select test.eq('the Worker''s claim never takes a story', (select count(*) from jsonb_array_elements(public.server_social_queue_claim()) x where x ->> 'id' in (select id::text from social_queue where by_hand)), 0::bigint);
select app.social_queue_act(test.id('zrw_sara'), jsonb_build_object('id', q.id, 'action', 'posted', 'url', 'https://www.tiktok.com/@carmacars/video/' || row_number() over ())) from social_queue q where q.draft_id in (select id from zrw_p where slot_no in (2, 3));
select test.eq('every channel posted: the calendar post is posted', (select string_agg(status, ',' order by slot_no) from social_drafts where id in (select id from zrw_p where slot_no in (2, 3))), 'posted,posted');
select app.door(test.id('zrw_sara'), 'aal2', 'va_do', 'social_stats_save', jsonb_build_object('id', (select id from social_queue where draft_id = (select id from zrw_p where slot_no = 3) and channel = 'tiktok'), 'views', 4000, 'likes', 300, 'comments', 20, 'shares', 10, 'saves', 5, '_va', 'sales'));
select app.social_stats_save(test.id('zrw_sara'), jsonb_build_object('id', (select id from social_queue where draft_id = (select id from zrw_p where slot_no = 3) and channel = 'instagram'), 'views', 2000, 'likes', 150, 'comments', 5));
select app.social_stats_save(test.id('zrw_sara'), jsonb_build_object('id', (select id from social_queue where draft_id = (select id from zrw_p where slot_no = 2)), 'views', 300, 'likes', 4));
select test.eq('results typed in for a post made by hand, with a score', (select st.source || '|' || round(app.social_score(st), 1) from social_post_stats st join social_queue q on q.id = st.queue_id where q.channel = 'tiktok' and q.draft_id = (select id from zrw_p where slot_no = 3)), 'hand|420.0');
select test.eq('the results teach the next calendar: the pillar and format that did best', (select (v ->> 'top_pillar') || '|' || (v ->> 'top_format') || '|' || (v ->> 'posts') from (select app.social_cal_learned() as v) s), 'offers|reel|3');
select test.ok('the ads job gets the calendar (plan, what was learned, the months to write) and never a calendar post as a week''s draft',
  (select (v #>> '{calendar,enabled}') = 'true' and (v #>> '{calendar,learned,top_pillar}') = 'offers' and jsonb_typeof(v #> '{calendar,months}') = 'array' and (v ->> 'drafts_enabled') = 'false'
      and not exists (select 1 from jsonb_array_elements(v -> 'due') d where d ->> 'id' in (select id::text from zrw_p))
     from (select public.server_ads_job() as v) s));
select test.eq('the week''s drafts screen keeps to its own drafts', (select count(*) from jsonb_array_elements(app.social_drafts_read(test.id('zrw_admin'), jsonb_build_object('week', (select m + 2 from zrw_month))) -> 'drafts') d where d ->> 'source' = 'calendar'), 0::bigint);

-- ================================================================ 5. the owner's tracker alerts
insert into tracker_devices (id, serial_number, status, vehicle_id, installed_at) values (test.id('zrw-dev'), 'ZRW860000000001', 'installed', test.id('vehicle:zrw_car'), now());
update program_settings set trackers_available = false;
select app.tracker_alert('offline', test.id('zrw-dev'), test.id('vehicle:zrw_car'), null, now(), 43.65, -79.38, 0, 'ZRW offline', 'Renter Rita Example, CC-1', 'zrw:off1');
select test.eq('before the trackers exist: nothing goes to the owner', (select count(*) from app_events where code = 'owner_tracker_alert' and entity_id = test.id('vehicle:zrw_car')), 0::bigint);
update program_settings set trackers_available = true;
select app.tracker_alert('offline', test.id('zrw-dev'), test.id('vehicle:zrw_car'), test.id('booking:ZRW-O2'), now(), 43.65, -79.38, 0, 'ZRW offline 2', 'Renter Zrw Rita, booking ZRW-O2', 'zrw:off2');
select test.eq('trackers live: the tracker stopped reporting, to the owner, as the tamper type',
  (select (payload ->> 'rule') || '|' || (payload ->> 'owner_id' = test.id('owner:zrw_olga')::text) from app_events where code = 'owner_tracker_alert' and entity_id = test.id('vehicle:zrw_car') order by id desc limit 1), 'tracker_tamper|true');
select test.ok('the owner''s alert names the car only: no renter, no booking',
  (select payload::text !~* '(rita|ZRW-O2|booking_id|renter)' from app_events where code = 'owner_tracker_alert' and entity_id = test.id('vehicle:zrw_car') order by id desc limit 1));
select app.tracker_alert('speeding', test.id('zrw-dev'), test.id('vehicle:zrw_car'), null, now(), 43.65, -79.38, 150, 'ZRW speed 150', null, 'zrw:sp1');
select app.tracker_alert('speeding', test.id('zrw-dev'), test.id('vehicle:zrw_car'), null, now(), 43.65, -79.38, 186, 'ZRW speed 186', null, 'zrw:sp2');
select test.eq('150 km/h is staff''s alert only; 186 km/h reaches the owner as the speed type', (select string_agg(payload ->> 'alert_title', ',') from app_events where code = 'owner_tracker_alert' and payload ->> 'rule' = 'tracker_speed'), 'Your 2023 Mercedes-Benz C 300 zrw_car was driven at 186 km/h');
select app.tracker_alert('left_ontario', test.id('zrw-dev'), test.id('vehicle:zrw_car'), null, now(), 45.5, -73.6, 90, 'ZRW left', null, 'zrw:lo1');
select test.eq('out of Ontario: possible theft', (select count(*) from app_events where code = 'owner_tracker_alert' and payload ->> 'rule' = 'tracker_theft' and entity_id = test.id('vehicle:zrw_car')), 1::bigint);
-- a tracker's own events: an impact is a crash alert; hard braking is only counted
select app.tracker_ingest(jsonb_build_object('points', jsonb_build_array(
  jsonb_build_object('device', 'ZRW860000000001', 'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'lat', 43.7, 'lng', -79.4, 'speed', 0, 'event', 'impact'),
  jsonb_build_object('device', 'ZRW860000000001', 'at', to_char((now() + interval '1 second') at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'lat', 43.7, 'lng', -79.4, 'speed', 30, 'event', 'harsh_brake'))));
select test.eq('an impact: staff''s alert and the owner''s crash alert; hard braking is counted, not sent',
  (select (select count(*) from tracker_alerts where kind = 'impact' and vehicle_id = test.id('vehicle:zrw_car')) || '|' || (select count(*) from app_events where code = 'owner_tracker_alert' and payload ->> 'rule' = 'tracker_crash')
       || '|' || (select count(*) from tracker_driving_events where vehicle_id = test.id('vehicle:zrw_car') and kind = 'harsh_brake')), '1|1|1');
-- a watched place; moving with no booking
select app.door(test.id('zrw_admin'), 'aal2', 'admin_do', 'tracker_place_save', '{"kind": "port", "name": "ZRW Port", "latitude": 43.70000, "longitude": -79.40000, "radius_m": 500}'::jsonb);
update tracker_status set latitude = 43.7001, longitude = -79.4001, speed_kmh = 0, reported_at = now() where tracker_device_id = test.id('zrw-dev');
select app.job_owner_tracker();
select test.eq('stopped at a watched port: the owner is told where', (select payload ->> 'alert_title' from app_events where code = 'owner_tracker_alert' and payload ->> 'rule' = 'tracker_place' order by id desc limit 1), 'Your 2023 Mercedes-Benz C 300 zrw_car stopped at ZRW Port');
update tracker_status set latitude = 44.2, longitude = -79.9, speed_kmh = 80, reported_at = now() where tracker_device_id = test.id('zrw-dev');
select app.job_owner_tracker();
select test.eq('moving with no booking and no staff job: possible theft, for staff and the owner',
  (select (select count(*) from tracker_alerts where kind = 'theft' and vehicle_id = test.id('vehicle:zrw_car')) || '|' || (select count(*) from app_events where code = 'owner_tracker_alert' and payload ->> 'alert_text' like 'It is moving with no active booking.%')), '1|1');
-- each alert type is the owner's switch: the critical ones on, speed and health off by default
select app.process_events(100000);
select test.eq('by default: theft and the tracker alerts are emailed, the speed alert is not (its notice stays in the portal)',
  (select string_agg(distinct (e.payload ->> 'rule') || '=' || case when o.status_reason like 'not sent: turned off in notification preferences%' then 'off' else 'on' end, ',' order by (e.payload ->> 'rule') || '=' || case when o.status_reason like 'not sent: turned off in notification preferences%' then 'off' else 'on' end)
     from notification_outbox o join app_events e on e.id = o.event_id where o.code = 'owner_tracker_alert' and o.recipient_user_id = test.id('zrw_olga')),
  'tracker_crash=on,tracker_place=on,tracker_speed=off,tracker_tamper=on,tracker_theft=on');
select test.ok('the speed alert is still a notice in the owner''s portal', exists (select 1 from notifications n where n.user_id = test.id('zrw_olga') and n.code = 'owner_tracker_alert' and n.title like '%186 km/h'));
select test.eq('the tracker types wait for the trackers: live now', (select string_agg(distinct (t ->> 'live'), ',') from jsonb_array_elements(public.server_notify_prefs(test.id('zrw_olga'), 'owner') -> 'groups') g, jsonb_array_elements(g -> 'types') t where t ->> 'code' like 'tracker_%'), 'true');
-- the weekly driving summary: only for an owner who switched it on
insert into tracker_trips (vehicle_id, started_at, ended_at, km, max_speed_kmh) values (test.id('vehicle:zrw_car'), date_trunc('week', now()) - interval '3 days' + interval '2 hours', date_trunc('week', now()) - interval '3 days' + interval '3 hours', 120.5, 130);
select test.eq('the summary is off by default: none', app.job_owner_tracker_weekly(date_trunc('week', now() at time zone 'America/Toronto') at time zone 'America/Toronto' + interval '10 hours'), 0);
delete from owner_tracker_weeklies where owner_id = test.id('owner:zrw_olga');
select public.server_notify_prefs_save(test.id('zrw_olga'), '{"type": "tracker_weekly", "channel": "email", "on": true, "portal": "owner"}'::jsonb);
select test.eq('switched on: one summary', app.job_owner_tracker_weekly(date_trunc('week', now() at time zone 'America/Toronto') at time zone 'America/Toronto' + interval '10 hours'), 1);
select test.eq('with the week''s kilometres, speeding, hard braking and late-night trips per car',
  (select (payload #>> '{cars,0,km}') || '|' || (payload #>> '{cars,0,speeding}') || '|' || (payload #>> '{cars,0,hard_braking}') || '|' || (payload #>> '{cars,0,late_night}') || '|' || (payload #>> '{cars,0,allowance}')
     from app_events where code = 'owner_tracker_weekly' and entity_id = test.id('owner:zrw_olga') order by id desc limit 1), '121 km|0|0|0|No rental days');
select test.eq('once a week', app.job_owner_tracker_weekly(date_trunc('week', now() at time zone 'America/Toronto') at time zone 'America/Toronto' + interval '11 hours'), 0);
update program_settings set trackers_available = false;

-- ================================================================ security: who may call what
select test.eq('none of the new functions is executable by a visitor or a signed-in browser session',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'public') and p.proname ~ '^(notify_pref|notify_prefs_|server_notify_prefs|server_partner_notify|staff_perk|owner_reward|owner_portal_reward|social_cal_|owner_tracker_|job_owner_|job_staff_perks|job_notify_digest|tracker_places_)'
      and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
select test.eq('every new table has row-level security and the Admin policy only',
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('notify_types', 'notify_prefs', 'notify_profiles', 'notify_digest_items', 'staff_free_days', 'staff_perk_codes', 'reward_postings', 'owner_reward_codes', 'owner_reward_ledger',
          'owner_reward_requests', 'social_calendars', 'social_post_stats', 'tracker_places', 'tracker_driving_events', 'owner_tracker_weeklies')
      and c.relrowsecurity and (select count(*) from pg_policy pl where pl.polrelid = c.oid) = 1), 15::bigint);
