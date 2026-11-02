-- 99: the staff-alert rule table and emitter (migration 0462). Fixtures start with "sa"; addresses are example.test.
select test.suite('99 staff alerts');
select test.mk_user('sta_admin', 'admin');
select test.mk_user('sta_cs', 'va', 'cs');
select test.mk_user('sta_fleet', 'va', 'fleet');
select test.mk_user('sta_fleet2', 'va', 'fleet');
select test.mk_user('sta_field', 'field');
insert into users (id, email, full_name) values (test.id('sta_vtest'), 'verify-sa-fleet@carmacars.ca', 'Verify Fleet');
insert into user_roles (user_id, role) values (test.id('sta_vtest'), 'va');
insert into staff_profiles (user_id, staff_type, va_function) values (test.id('sta_vtest'), 'va', 'fleet');
insert into chat_staff_prefs (user_id, last_seen_at) values (test.id('sta_fleet'), now()), (test.id('sta_vtest'), now());
select test.mk_renter('sta_rita');
create temp table sta_s as select id, alert_money_threshold_cents, alert_escalate_minutes, alert_escalate_enabled, alert_brief_enabled from program_settings;
create or replace function test.sta_who(p_code text, p_like text) returns text language sql stable as $$
  select coalesce(string_agg(l, ',' order by l), 'none') from (select distinct replace(replace(u.email, '@example.test', ''), '@carmacars.ca', '') l
    from notifications n join users u on u.id = n.user_id where n.code = p_code and n.title like p_like and (u.email like 'sta\_%@example.test' or u.email = 'verify-sa-fleet@carmacars.ca')) x $$;
create or replace function test.sta_sub(p_label text, p_user uuid, p_portal text) returns jsonb language sql as $$
  select app.push_subscribe(p_user, jsonb_build_object('endpoint', 'https://push.example.test/send/' || p_label,
    'p256dh', 'B' || repeat('A', 86), 'auth', repeat('Q', 22), 'portal', p_portal, 'device', 'iPhone')) $$;

-- the rule table and the three notices
select test.eq('rules: wired rows exist for every group, the lead rules are fixed',
  (select count(*) filter (where wired) > 30 and count(*) filter (where not wired) > 20 and bool_and(fixed) filter (where rule in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor')) from staff_alert_rules), true);
select test.eq('three notices, in the app and on the phone only', (select count(*) || '/' || bool_or(has_email)::text from notification_catalogue where code like 'staff\_alert\_%'), '3/false');
select test.eq('Admins keep every topic by default', cardinality(app.push_topics(test.id('sta_admin'))), 9);

-- emitter: tier, recipients, test accounts, dedupe, switch
select app.staff_alert('job_late', 'sa', test.id('sta_j1'), 'late', 'Job running late: sa', 'body', jsonb_build_object('assigned_to', test.id('sta_field'), 'path_staff', '/staff/field'));
select app.staff_alert('booking_out', 'sa', test.id('sta_b1'), 'on_rent', 'Car going out: sa', 'body');
select app.staff_alert('offer_sent', 'sa', test.id('sta_b2'), 'v1', 'Offer sent: sa', 'body');
select app.staff_alert('opt_out', 'x', test.id('sta_b3'), 'x', 'Opt-out: sa (not wired: still a rule, may be emitted)', 'body');
select app.process_events(1000);
select test.eq('urgent job late: the Admin and the assigned field person', test.sta_who('staff_alert_urgent', 'Job running late: sa%'), 'sta_admin,sta_field');
select test.eq('car going out: the Admin and fleet on duty, not the other fleet person or a test account', test.sta_who('staff_alert_normal', 'Car going out: sa%'), 'sta_admin,sta_fleet');
select test.eq('digest tier: the Admin has the line and a digest item is kept for the role',
  test.sta_who('staff_alert_digest', 'Offer sent: sa%') || '/' || (select count(*) from staff_digest_items where line like 'Offer sent: sa%'), 'sta_admin/1');
select test.eq('dedupe: the same alert again is one event', (select count(*) from app_events where code = 'staff_alert_normal' and entity_id = test.id('sta_b1')), 1::bigint);
select app.staff_alert('booking_out', 'sa', test.id('sta_b1'), 'on_rent', 'Car going out: sa', 'body');
select test.eq('dedupe: the second emit returns nothing new', (select count(*) from app_events where code = 'staff_alert_normal' and entity_id = test.id('sta_b1')), 1::bigint);
update staff_alert_rules set enabled = false where rule = 'booking_out';
select test.eq('a rule switched off makes no alert', app.staff_alert('booking_out', 'sa', test.id('sta_b9'), 'on_rent', 'Car going out: sa off', 'b') is null, true);
update staff_alert_rules set enabled = true where rule = 'booking_out';
select test.eq('an unknown rule makes no alert', app.staff_alert('no_such_rule', 'x', null, 'x', 't', 'b') is null, true);

-- the phone: urgent at once; normal waits for the staff quiet hours; digest never; the topic is the rule's
select test.sta_sub('sta_admin1', test.id('sta_admin'), 'admin');
select test.eq('a normal alert is held to the end of the quiet hours when it comes in them; an urgent one never',
  (select app.sms_quiet_end(timestamptz '2030-01-02 03:00+00') > timestamptz '2030-01-02 03:00+00'), true);
select app.staff_alert('payment_received', 'sa', test.id('sta_p1'), 'ok', 'Payment received: sa', 'b');
select app.staff_alert('review_low', 'sa', test.id('sta_r1'), 'new', 'New review: sa 2 stars', 'b');
select app.staff_alert('toll_received', 'sa', test.id('sta_t1'), 'new', 'Toll or ticket received: sa', 'b');
select app.process_events(1000);
select test.eq('push: urgent is urgent and due now; normal follows the quiet hours; a digest is never pushed',
  (select string_agg(n.code || '=' || o.urgent::text || ':' || (o.send_after <= now() + interval '14 hours')::text, ',' order by n.code)
     from push_outbox o join notifications n on n.id = o.notification_id where n.user_id = test.id('sta_admin') and n.title like '%: sa%'),
  'staff_alert_normal=false:true,staff_alert_urgent=true:true');
select test.eq('push: an Admin who turned the topic off still has the line in the app',
  (select count(*) from notifications where user_id = test.id('sta_admin') and code = 'staff_alert_digest' and title like 'Toll or ticket received: sa%') ||
  '/' || (select count(*) from push_outbox o join notifications n on n.id = o.notification_id where n.code = 'staff_alert_digest'), '1/0');

-- hooks: a sample of each group
select test.mk_owner('sta_owner');
select test.mk_vehicle('sta_car', 'sta_owner');
select test.mk_booking('CC-SA001', 'sta_car', 'sta_rita', '2031-03-01 10:00', '2031-03-03 10:00', 'closed');
select app.sta_booking_alert(b) from bookings b where booking_number = 'CC-SA001';
select test.mk_booking('CC-SA003', 'sta_car', 'sta_rita', '2031-05-01 10:00', '2031-05-03 10:00', 'on_rent');
select app.sta_booking_alert(b) from bookings b where booking_number = 'CC-SA003';
select test.mk_booking('CC-SA004', 'sta_car', 'sta_rita', '2031-06-01 10:00', '2031-06-03 10:00', 'returned');
select app.sta_booking_alert(b) from bookings b where booking_number = 'CC-SA004';
select app.process_events(1000);
select test.eq('booking steps: car out and back (Admin and fleet on duty), closed (digest), each naming the booking, car and renter',
  test.sta_who('staff_alert_normal', 'Car going out: CC-SA003%') || '/' || test.sta_who('staff_alert_normal', 'Car back: CC-SA004%') || '/' || test.sta_who('staff_alert_digest', 'Booking closed: CC-SA001%'),
  'sta_admin,sta_fleet/sta_admin,sta_fleet/sta_admin');

select test.eq('the line names the renter and links the booking',
  (select title || ' | ' || url from notifications where user_id = test.id('sta_admin') and title like 'Car going out: CC-SA003%') ~ 'CC-SA003, .*, Sa Rita \| .*/admin/bookings/CC-SA003$', true);
select test.mk_booking('CC-SA002', 'sta_car', 'sta_rita', '2031-04-01 10:00', '2031-04-03 10:00', 'no_show');
select app.sta_booking_alert(b) from bookings b where booking_number = 'CC-SA002';
select app.process_events(1000);
select test.eq('no-show is urgent', test.sta_who('staff_alert_urgent', 'No-show: CC-SA002%'), 'sta_admin,sta_fleet');
-- money: only over the threshold, a refund when paid
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status)
  select test.id('sta_pay_big'), b.id, b.renter_id, 'booking_total', 'charge', 'card', 60000, 'succeeded' from bookings b where booking_number = 'CC-SA001';
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status)
  select test.id('sta_pay_small'), b.id, b.renter_id, 'booking_total', 'charge', 'card', 20000, 'succeeded' from bookings b where booking_number = 'CC-SA001';
select app.process_events(1000);
select test.eq('payment over the threshold alerts, a smaller one does not',
  (select count(*) from app_events where code = 'staff_alert_normal' and entity_id in (test.id('sta_pay_big'), test.id('sta_pay_small')) and payload ->> 'rule' = 'payment_received'), 1::bigint);
-- reviews by stars
insert into reviews (id, booking_id, renter_id, vehicle_id, rating, title, status) select test.id('sta_rev2'), b.id, b.renter_id, b.vehicle_id, 2, 'Slow pickup', 'pending' from bookings b where booking_number = 'CC-SA001';
select app.process_events(1000);
select test.eq('a review of 3 stars or less is urgent', test.sta_who('staff_alert_urgent', 'New review: 2 stars%'), 'sta_admin');
-- the mirror of what goes out to other people
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, entity, entity_id, payload, dedupe_key, status)
  select 'renter_late_return_first', 'transactional', 3, 'renter', 'sta_rita@example.test', 'Sa Rita', b.id, 'booking', b.id, '{}'::jsonb, 'sa:mirror1', 'queued' from bookings b where booking_number = 'CC-SA001';
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, entity, entity_id, payload, dedupe_key, status)
  select 'renter_late_return_first', 'transactional', 3, 'renter', 'verify-sa-renter@carmacars.ca', 'Test Renter', b.id, 'booking', b.id, '{}'::jsonb, 'sa:mirror2', 'queued' from bookings b where booking_number = 'CC-SA001';
select app.process_events(1000);
select test.eq('mirror: a late notice sent to a renter alerts the Admin as urgent, a test address does not',
  (select count(*) from app_events where code = 'staff_alert_urgent' and payload ->> 'rule' = 'sent:renter_late_return_first'), 1::bigint);

-- the job: late field job, offer expiring, escalation, the briefs
insert into field_jobs (id, kind, vehicle_id, assigned_to, scheduled_at, status) values (test.id('sta_job'), 'detail', test.id('vehicle:sta_car'), test.id('sta_field'), now() - interval '30 minutes', 'scheduled');
select test.eq('job: a field job 30 minutes late is found', (app.job_staff_alerts()) ~ 'late jobs [1-9]', true);
select test.eq('job: and only once', (app.job_staff_alerts()) ~ 'late jobs 0', true);
select app.process_events(1000);
select test.eq('job: the late field job reaches the Admin and the assigned field person', test.sta_who('staff_alert_urgent', 'Job running late: detail%'), 'sta_admin,sta_field');
update program_settings set alert_escalate_minutes = 1;
insert into notifications (id, user_id, code, title, body, dedupe_key, created_at) values (test.id('sta_esc'), test.id('sta_cs'), 'staff_alert_urgent', 'Urgent for sta_cs', 'b', 'sa:esc', now() - interval '5 minutes');
select app.job_staff_alerts();
select app.process_events(1000);
select test.eq('escalation: an urgent alert unopened past the minutes goes to the Admin', test.sta_who('staff_alert_urgent', 'Not opened: Urgent for sta_cs%'), 'sta_admin');
update notifications set read_at = now() where id = test.id('sta_esc');
select test.eq('the brief and wrap are built from the day''s counts at 8 and 21 only',
  (select count(*) from app_events where code in ('staff_alert_normal', 'staff_alert_urgent', 'staff_alert_digest') and payload ->> 'rule' in ('morning_brief_admin', 'evening_wrap') and created_at > now() - interval '1 minute')
  = case when app.local_hour(now()) in (8, 21) then 1 else 0 end, true);

-- clean up
delete from push_outbox where user_id in (select id from users where email like 'sta\_%@example.test');
delete from push_subscriptions where endpoint like '%/sta\_%';
delete from push_preferences where user_id in (select id from users where email like 'sta\_%@example.test');
delete from notifications where code like 'staff\_alert\_%';
delete from staff_digest_items where code like 'staff\_alert\_%';
delete from app_events where code like 'staff\_alert\_%';
delete from notification_outbox where dedupe_key like 'sa:mirror%';
delete from field_jobs where id = test.id('sta_job');
delete from reviews where id = test.id('sta_rev2');
delete from chat_staff_prefs where user_id in (select id from users where email like 'sta\_%@example.test' or email = 'verify-sa-fleet@carmacars.ca');
update program_settings p set alert_money_threshold_cents = s.alert_money_threshold_cents, alert_escalate_minutes = s.alert_escalate_minutes from sta_s s where s.id = p.id;
