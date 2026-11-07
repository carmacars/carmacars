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
create temp table sta_s as select id, alert_money_threshold_cents, alert_escalate_minutes, alert_escalate_enabled, alert_brief_enabled,
  sms_quiet_hours, sms_quiet_from_hour, sms_quiet_until_hour, alert_burst_count, notify_lead_burst_count from program_settings;
-- the quiet hours and the grouping as shipped (earlier files may have changed them); restored at the end
update program_settings set sms_quiet_hours = true, sms_quiet_from_hour = 21, sms_quiet_until_hour = 8, alert_burst_count = 50, notify_lead_burst_count = 50;
create or replace function test.sta_who(p_code text, p_like text) returns text language sql stable as $$
  select coalesce(string_agg(l, ',' order by l), 'none') from (select distinct replace(replace(u.email, '@example.test', ''), '@carmacars.ca', '') l
    from notifications n join users u on u.id = n.user_id where n.code = p_code and n.title like p_like and (u.email like 'sta\_%@example.test' or u.email = 'verify-sa-fleet@carmacars.ca')) x $$;
create or replace function test.sta_sub(p_label text, p_user uuid, p_portal text) returns jsonb language sql as $$
  select app.push_subscribe(p_user, jsonb_build_object('endpoint', 'https://push.example.test/send/' || p_label,
    'p256dh', 'B' || repeat('A', 86), 'auth', repeat('Q', 22), 'portal', p_portal, 'device', 'iPhone')) $$;

-- the rule table and the three notices
select test.eq('rules: every rule is wired (0465, 0466), the lead rules are fixed',
  (select count(*) filter (where wired) > 85 and count(*) filter (where not wired) = 0 and bool_and(fixed) filter (where rule in ('staff_lead_new', 'staff_request_unfinished', 'staff_owner_lead_new', 'staff_hot_visitor')) from staff_alert_rules), true);
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
select app.sa_booking_alert(b) from bookings b where booking_number = 'CC-SA001';
select test.mk_booking('CC-SA003', 'sta_car', 'sta_rita', '2031-05-01 10:00', '2031-05-03 10:00', 'on_rent');
select app.sa_booking_alert(b) from bookings b where booking_number = 'CC-SA003';
select test.mk_booking('CC-SA004', 'sta_car', 'sta_rita', '2031-06-01 10:00', '2031-06-03 10:00', 'returned');
select app.sa_booking_alert(b) from bookings b where booking_number = 'CC-SA004';
select app.process_events(1000);
select test.eq('booking steps: car out and back (Admin and fleet on duty), closed (digest), each naming the booking, car and renter',
  test.sta_who('staff_alert_normal', 'Car going out: CC-SA003%') || '/' || test.sta_who('staff_alert_normal', 'Car back: CC-SA004%') || '/' || test.sta_who('staff_alert_digest', 'Booking closed: CC-SA001%'),
  'sta_admin,sta_fleet/sta_admin,sta_fleet/sta_admin');

select test.eq('the line names the renter and links the booking',
  (select title || ' | ' || url from notifications where user_id = test.id('sta_admin') and title like 'Car going out: CC-SA003%') ~ 'CC-SA003, .*, Sta Rita \| .*/admin/bookings/CC-SA003$', true);
select test.mk_booking('CC-SA002', 'sta_car', 'sta_rita', '2031-04-01 10:00', '2031-04-03 10:00', 'no_show');
select app.sa_booking_alert(b) from bookings b where booking_number = 'CC-SA002';
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
  (select count(*) from app_events where code = 'staff_alert_urgent' and payload ->> 'rule' = 'sent:renter_late_return_first'
      and payload ->> 'booking_id' = (select id::text from bookings where booking_number = 'CC-SA001')), 1::bigint);

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

-- 0464: the tracker, the AI interview and the data health meet the rule table

select app.tracker_alert('speeding', null, test.id('vehicle:sta_car'), null, now(), 43.7, -79.4, 160, 'Speeding: sta car', 'detail', 'sta:speed1');
select app.tracker_alert('left_zone', null, test.id('vehicle:sta_car'), null, now(), 43.7, -79.4, 50, 'Left the zone: sta car', 'detail', 'sta:zone1');
select app.process_events(1000);
update staff_alert_rules set enabled = false where rule = 'tracker_zone';
select app.tracker_alert('left_ontario', null, test.id('vehicle:sta_car'), null, now(), 43.7, -79.4, 50, 'Left Ontario: sta car', 'detail', 'sta:ont1');
select app.process_events(1000);
select test.eq('tracker: speeding reaches the Admin and fleet staff as before (urgent, topic alerts)',
  (select count(distinct n.user_id) from notifications n where n.code in ('staff_tracker_alert', 'staff_tracker_alert_fleet') and n.title = 'Speeding: sta car' and n.body = 'detail'
     and n.user_id in (test.id('sta_admin'), test.id('sta_fleet'))), 2::bigint);
select test.eq('tracker: a rule that is on still sends', (select count(*) > 0 from notifications where code in ('staff_tracker_alert', 'staff_tracker_alert_fleet') and title like 'Left the zone: sta car%'), true);
select test.eq('tracker: the rule turned off makes no notice for its kinds (the zone and Ontario)', (select count(*) from notifications where code in ('staff_tracker_alert', 'staff_tracker_alert_fleet') and title like 'Left Ontario: sta car%'), 0::bigint);
update staff_alert_rules set enabled = true where rule = 'tracker_zone';
select test.eq('tracker: every kind has a wired rule', (select count(*) from staff_alert_rules where rule like 'tracker\_%' and wired), 5::bigint);
select test.eq('data health and usage are in the app only (0465): no push topic, digest tier',
  coalesce((select push_topic from notification_catalogue where code = 'staff_data_health'), 'none') || '/' || (select tier from staff_alert_rules where rule = 'usage_80'), 'none/digest');
insert into job_applications (role_id, status, full_name, email) select id, 'interviewed', 'Sta Applicant', 'sta_applicant@example.test' from hiring_roles where slug = 'va-customer-service';
insert into ai_interviews (application_id, role_id, questions, state, expires_at, interview_score, recommendation)
  select a.id, a.role_id, '[]'::jsonb, 'submitted', now() + interval '3 days', 72, 'live_call' from job_applications a where a.email = 'sta_applicant@example.test';
update ai_interviews set state = 'scored' where application_id = (select id from job_applications where email = 'sta_applicant@example.test');
select app.process_events(1000);
select test.eq('interview scored: one normal alert to the Admin, with the score and the suggestion',
  (select string_agg(n.body, '|') from notifications n join users u on u.id = n.user_id where n.code = 'staff_alert_normal' and n.title = 'AI interview scored: Sta Applicant' and u.email = 'sta_admin@example.test'),
  '72 of 100, suggests a live call.');

select app.request_account_deletion(test.id('sta_rita'), 'moving away');
select app.process_events(1000);
select test.eq('delete my account: an urgent alert to the Admin with the reason',
  (select string_agg(n.title || ' / ' || n.body, '|') from notifications n where n.code = 'staff_alert_urgent' and n.user_id = test.id('sta_admin') and n.title like 'Account deletion asked:%'),
  'Account deletion asked: Sta Rita / moving away. Settle anything open, reply within 30 days.');

insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed)
  select test.id('sta_field'), s.id, 9, 10, 9000, true from academy_sections s order by s.slug limit 1;
select app.process_events(1000);
select test.eq('academy: a passed quiz is a line of the Admin digest, never a push',
  (select count(*) from staff_digest_items where line like 'Quiz passed: %' and line like '%Field%') || '/' || (select count(*) from notifications where code = 'staff_alert_digest' and user_id = test.id('sta_admin') and title like 'Quiz passed:%'), '1/1');

-- ================================================================ 0465: every alert with data is wired (a sample of each group)
update program_settings set alert_burst_count = 50;
create or replace function test.sta_at(p interval) returns text language sql stable as $$ select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_vehicle('sta_car2', 'sta_owner');
-- bookings: confirmed (the first booking of a car is a win), cancelled, return with less fuel and more km
select test.mk_booking('CC-SA010', 'sta_car2', 'sta_rita', test.sta_at('90 minutes'), test.sta_at('3 days'), 'confirmed');
select app.sa_booking_alert(b) from bookings b where booking_number = 'CC-SA010';
select test.mk_booking('CC-SA011', 'sta_car2', 'sta_rita', test.sta_at('20 days'), test.sta_at('22 days'), 'confirmed');
create or replace function test.sta_as(p_number text, p_status booking_status) returns void language plpgsql as $$
declare b bookings;
begin
  select * into b from bookings where booking_number = p_number;
  b.status := p_status;
  perform app.sa_booking_alert(b);
end $$;
select test.sta_as('CC-SA011', 'cancelled');
select app.process_events(1000);
select test.eq('bookings: the first booking of a car is a win, a second one is not',
  (select count(*) from app_events where payload ->> 'rule' = 'win_first_booking' and entity_id = test.id('vehicle:sta_car2')), 1::bigint);
select test.eq('bookings: a cancellation reaches the Admin and fleet on duty', test.sta_who('staff_alert_normal', 'Booking cancelled: CC-SA011%'), 'sta_admin,sta_fleet');
update bookings set fuel_out_pct = 100, fuel_in_pct = 60, odometer_out_km = 1000, odometer_in_km = 9000 where booking_number = 'CC-SA011';
select app.process_events(1000);
select test.eq('field: fuel and km off at return',
  (select body from notifications where user_id = test.id('sta_admin') and title like 'Check the return: CC-SA011%'), 'Fuel 40% lower than at pickup; 7600 km over the 400 km allowed.');
-- an extension asked carries Approve and Decline; a change asked by the renter
insert into booking_extensions (booking_id, seq, status, previous_return_at, new_return_at, previous_days, new_days, previous_rental_charge_cents, new_rental_charge_cents, rental_difference_cents, total_cents)
  select id, 1, 'requested', return_at, return_at + interval '2 days', 3, 5, 30000, 50000, 20000, 22600 from bookings where booking_number = 'CC-SA010';
insert into booking_change_requests (booking_id, requested_by_role, changes, note) select id, 'renter', '{"return_at": "later"}', 'Can I bring it back Sunday?' from bookings where booking_number = 'CC-SA010';
select app.process_events(1000);
select test.eq('bookings: extension asked and change asked reach the Admin',
  test.sta_who('staff_alert_normal', 'Extension asked: CC-SA010%') || '/' || test.sta_who('staff_alert_normal', 'Change asked: CC-SA010%'), 'sta_admin/sta_admin');
-- money: a deposit hold failed and a card declined near the pickup are urgent
insert into deposits (id, booking_id, amount_cents, method, status) select test.id('sta_dep'), id, 100000, 'card_hold', 'pending' from bookings where booking_number = 'CC-SA010';
update deposits set status = 'failed' where id = test.id('sta_dep');
insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status)
  select test.id('sta_pay_dec'), b.id, b.renter_id, 'booking_total', 'charge', 'card', 45000, 'failed' from bookings b where booking_number = 'CC-SA010';
insert into payment_attempts (payment_id, attempt_no, outcome, decline_code) values (test.id('sta_pay_dec'), 1, 'declined', 'insufficient_funds');
select app.process_events(1000);
select test.eq('money: deposit hold failed and card declined at pickup are urgent',
  test.sta_who('staff_alert_urgent', 'Deposit hold failed: CC-SA010%') || '/' || test.sta_who('staff_alert_urgent', 'Card declined at pickup: CC-SA010%'), 'sta_admin/sta_admin,sta_fleet');
-- documents: the agreement not signed 2 hours before pickup is urgent; insurance proof missing 24 hours before
select test.eq('documents: the scheduled checks find the unsigned agreement and the missing insurance', app.sa_scheduled() >= 2, true);
select app.process_events(1000);
select test.eq('documents: agreement unsigned (urgent, Admin and customer service on duty) and insurance missing (normal)',
  test.sta_who('staff_alert_urgent', 'Agreement not signed: CC-SA010%') || '/' || test.sta_who('staff_alert_normal', 'Insurance proof missing: CC-SA010%'), 'sta_admin/sta_admin');
-- customers: complaint words in chat, unsubscribe (digest), text STOP (digest)
insert into chat_conversations (id, token, visitor_id, name, email, status) values (test.id('sta_chat'), 'sta-chat-token', test.id('sta_visitor'), 'Sta Visitor', 'sta_visitor@example.test', 'human');
insert into chat_messages (conversation_id, sender, body) values (test.id('sta_chat'), 'visitor', 'The car was dirty and I want a refund');
insert into chat_messages (conversation_id, sender, body) values (test.id('sta_chat'), 'visitor', 'Also it smells');
insert into email_suppressions (email, reason, scope) values ('sta_unsub@example.test', 'unsubscribe', 'marketing'), ('verify-sa-unsub@carmacars.ca', 'unsubscribe', 'marketing');
insert into sms_opt_out_log (number, action, source) values ('+16475550198', 'stop', 'sms');
select app.process_events(1000);
select test.eq('customers: complaint words once per conversation a day, unsubscribe and STOP as digest lines (a test address never)',
  (select count(*) from notifications where user_id = test.id('sta_admin') and title like 'Complaint words in chat:%') || '/' ||
  (select count(*) from notifications where user_id = test.id('sta_admin') and code = 'staff_alert_digest' and (title like 'Unsubscribed%' or title = 'Texted STOP')), '1/2');
-- fleet: service due (digest), car unpublished
update vehicle_service_items set status = 'due_soon', next_due_on = current_date + 5 where vehicle_id = test.id('vehicle:sta_car2') and item_code = 'oil_filter';
insert into vehicle_listings (vehicle_id, status, slug) values (test.id('vehicle:sta_car2'), 'published', 'sta-car-two');
update vehicle_listings set status = 'paused', unpublished_reason = 'Owner asked' where vehicle_id = test.id('vehicle:sta_car2');
select app.process_events(1000);
select test.eq('fleet: service due is a digest line, a paused car a normal alert',
  (select count(*) from notifications where user_id = test.id('sta_admin') and code = 'staff_alert_digest' and title like 'Due soon: oil filter%') || '/' ||
  (select count(*) from notifications where user_id = test.id('sta_admin') and code = 'staff_alert_normal' and title like 'Car paused:%'), '1/1');
-- owners: notice and a banking change are urgent (the first account is the set-up, not a change)
insert into vehicle_exits (vehicle_id, initiated_by, reason, notice_received_at, notice_ends_on, exit_date) values (test.id('vehicle:sta_car2'), 'owner', 'Selling the car', now(), current_date + 60, current_date + 60);
insert into owner_payout_accounts (owner_id, method, account_holder, account_last4) values (test.id('owner:sta_owner'), 'bank_transfer', 'Sta Owner', '1111');
update owner_payout_accounts set is_current = false where owner_id = test.id('owner:sta_owner');
insert into owner_payout_accounts (owner_id, method, account_holder, account_last4) values (test.id('owner:sta_owner'), 'bank_transfer', 'Sta Owner', '2222');
select app.process_events(1000);
select test.eq('owners: notice and a changed account are urgent, the first account is not',
  (select count(*) from notifications where user_id = test.id('sta_admin') and code = 'staff_alert_urgent' and (title like 'Owner gave notice:%' or title like 'Owner banking changed:%')), 2::bigint);
-- hiring: interview link expired, hired
insert into job_applications (id, role_id, status, full_name, email) select test.id('sta_app2'), id, 'interviewed', 'Sta Applicant Two', 'sta_applicant2@example.test' from hiring_roles where slug = 'va-customer-service';
insert into ai_interviews (application_id, role_id, questions, state, expires_at) select a.id, a.role_id, '[]'::jsonb, 'sent', now() + interval '1 day' from job_applications a where a.id = test.id('sta_app2');
update ai_interviews set state = 'expired' where application_id = test.id('sta_app2');
update job_applications set status = 'hired' where id = test.id('sta_app2');
select app.process_events(1000);
select test.eq('hiring: link expired and offer accepted reach the Admin',
  test.sta_who('staff_alert_normal', 'Interview link expired: Sta Applicant Two%') || '/' || test.sta_who('staff_alert_normal', 'Offer accepted: Sta Applicant Two%'), 'sta_admin/sta_admin');
-- the academy: a failed quiz twice
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed) select test.id('sta_cs'), s.id, 2, 10, 2000, false from academy_sections s order by s.slug limit 1;
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed) select test.id('sta_cs'), s.id, 3, 10, 3000, false from academy_sections s order by s.slug limit 1;
select app.process_events(1000);
select test.eq('academy: a quiz failed twice is one normal alert', (select count(*) from notifications where user_id = test.id('sta_admin') and title like 'Quiz failed twice: Sta Cs%'), 1::bigint);
-- staff: Sales late for their block
select test.mk_user('sta_sales', 'va', 'sales');
insert into sales_availability (staff_id, day, from_minute, until_minute)
  values (test.id('sta_sales'), app.local_date(now()), greatest(0, app.local_hour(now()) * 60 - 30), least(1439, app.local_hour(now()) * 60 + 120));
select app.sa_scheduled();
select app.process_events(1000);
select test.eq('staff: Sales who did not start their block (when the block started 15 minutes ago or more)',
  -- the block starts at 00:00 in the first hour after midnight: late once 15 minutes of it have gone
  (select count(*) from notifications where user_id = test.id('sta_admin') and title = 'Not started: Sta Sales')
    = case when (extract(hour from now() at time zone 'America/Toronto') * 60 + extract(minute from now() at time zone 'America/Toronto'))
                - greatest(0, app.local_hour(now()) * 60 - 30) >= 15 then 1 else 0 end, true);
-- wins: an owner's first payout
insert into payouts (id, payee_type, owner_id, kind, amount_cents, method, scheduled_for, status, approved_by) values (test.id('sta_po1'), 'owner', test.id('owner:sta_owner'), 'other', 80000, 'bank_transfer', current_date, 'sent', test.id('sta_admin'));
update payouts set status = 'paid', paid_at = now() where id = test.id('sta_po1');
select app.process_events(1000);
select test.eq('wins: an owner''s first payout is a digest line', (select count(*) from notifications where user_id = test.id('sta_admin') and code = 'staff_alert_digest' and title like 'First payout:%'), 1::bigint);
-- test accounts: a test renter's booking makes nothing
select test.mk_renter('sta_vt');
update renters set email = 'verify-sa-renter@carmacars.ca' where id = test.id('renter:sta_vt');
select test.mk_booking('CC-SA012', 'sta_car', 'sta_vt', test.sta_at('30 days'), test.sta_at('32 days'), 'confirmed');
select test.sta_as('CC-SA012', 'cancelled');
select app.process_events(1000);
select test.eq('test accounts: a test renter''s booking makes no alert', (select count(*) from app_events where code like 'staff\_alert\_%' and entity_id = test.id('booking:CC-SA012')), 0::bigint);

-- ================================================================ 0466: quiet hours, focus, device topics, buttons, snooze, escalation, grouping
select test.eq('quiet hours: default 21:00 to 8:00 (no row: the normal tier only); my own hours move the time',
  (select app.alert_quiet_end(test.id('sta_fleet'), timestamptz '2031-01-10 23:30 America/Toronto') = app.sms_quiet_end(timestamptz '2031-01-10 23:30 America/Toronto')), true);
select app.server_set_alert_prefs(test.id('sta_fleet'), '{"quiet_on": true, "quiet_from": 1320, "quiet_until": 420}');
select test.eq('quiet hours: 22:00 to 7:00 saved', (select app.alert_quiet_end(test.id('sta_fleet'), timestamptz '2031-01-10 23:30 America/Toronto') = timestamptz '2031-01-11 07:00 America/Toronto')
  || '/' || (select app.alert_quiet_end(test.id('sta_fleet'), timestamptz '2031-01-10 21:30 America/Toronto') = timestamptz '2031-01-10 21:30 America/Toronto'), 'true/true');
select test.sta_sub('sta_fleet1', test.id('sta_fleet'), 'staff');
select test.sta_sub('sta_fleet2', test.id('sta_fleet'), 'staff');
select app.server_set_alert_prefs(test.id('sta_fleet'), '{"focus_minutes": 60}');
select test.eq('focus: on for an hour', (app.server_alert_prefs(test.id('sta_fleet')) ->> 'focus_until') is not null, true);
select app.staff_alert('booking_out', 'sa', test.id('sta_f1'), 'on_rent', 'Car going out: sa focus', 'b');
select app.staff_alert('booking_no_show', 'sa', test.id('sta_f2'), 'no_show', 'No-show: sa focus', 'b', '{"call": "+16475550199"}');
select app.process_events(1000);
select test.eq('focus: only the urgent alert reaches the phone; both are in the feed',
  (select count(distinct o.notification_id) from push_outbox o where o.user_id = test.id('sta_fleet')) || '/' ||
  (select count(*) from jsonb_array_elements(app.server_alert_feed(test.id('sta_fleet'), 200, 'all')) x where x ->> 'title' like '%sa focus'), '1/2');
select test.eq('buttons: the urgent no-show carries Call and Mark picked up (two at most); the payload has the notice id',
  (select string_agg(a ->> 'action', ',') from push_outbox o, jsonb_array_elements(o.actions) a where o.user_id = test.id('sta_fleet') and o.subscription_id = (select id from push_subscriptions where endpoint like '%/sta_fleet1')), 'call,picked_up');
select test.eq('buttons: a request offers Send offer; an extension Approve and Decline; urgent adds Snooze',
  (select string_agg(a ->> 'title', ',') from jsonb_array_elements(app.alert_actions('staff_booking_request_new', '{}', '/staff/bookings/CC-1', false)) a) || '|' ||
  (select string_agg(a ->> 'title', ',') from jsonb_array_elements(app.alert_actions('staff_alert_normal', '{"rule": "extension_paid", "decide": true}', '/admin/bookings/CC-1?tab=changes', false)) a) || '|' ||
  (select string_agg(a ->> 'title', ',') from jsonb_array_elements(app.alert_actions('staff_alert_urgent', '{"rule": "job_late"}', '/staff/field', true)) a),
  'Send offer|Approve,Decline|Snooze 30 min');
select app.server_set_alert_prefs(test.id('sta_fleet'), '{"focus_minutes": 0}');
-- a device's own topics: one device turns bookings off, the other keeps the person's choice
select app.server_push_device_topics(test.id('sta_fleet'), 'https://push.example.test/send/sta_fleet2', array['alerts']);
select app.staff_alert('booking_out', 'sa', test.id('sta_f3'), 'on_rent', 'Car going out: sa device', 'b');
select app.process_events(1000);
select test.eq('device topics: only the device that keeps bookings gets the alert',
  (select string_agg(replace(ps.endpoint, 'https://push.example.test/send/', ''), ',') from push_outbox o join push_subscriptions ps on ps.id = o.subscription_id
    join notifications n on n.id = o.notification_id where n.title = 'Car going out: sa device' and n.user_id = test.id('sta_fleet')), 'sta_fleet1');
select test.eq('device topics: in the state of that device', (app.push_state(test.id('sta_fleet'), 'https://push.example.test/send/sta_fleet2') -> 'device_topics')::text, '["alerts"]');
-- snooze: the alert comes again in 30 minutes and its escalation waits
select test.eq('snooze: 30 minutes',
  (select app.server_alert_snooze(test.id('sta_fleet'), n.id, 30) between now() + interval '29 minutes' and now() + interval '31 minutes' from notifications n where n.user_id = test.id('sta_fleet') and n.title = 'No-show: sa focus'), true);
select test.eq('snooze: the phone alert is queued again for then',
  (select bool_and(o.status = 'queued' and o.send_after > now() + interval '29 minutes') from push_outbox o join notifications n on n.id = o.notification_id where n.title = 'No-show: sa focus' and n.user_id = test.id('sta_fleet')), true);
-- the feed: unread count, urgent filter, mark read
select test.eq('feed: unread and urgent', app.server_alert_unread(test.id('sta_fleet')) >= 3 and jsonb_array_length(app.server_alert_feed(test.id('sta_fleet'), 50, 'urgent')) >= 1, true);
select test.eq('feed: mark all read', app.server_alert_read(test.id('sta_fleet'), null) >= 3, true);
select test.eq('feed: nothing unread after', app.server_alert_unread(test.id('sta_fleet')), 0);
select test.eq('feed: someone else''s alerts are never in it', (select bool_and(x ->> 'id' not in (select id::text from notifications where user_id <> test.id('sta_cs'))) from jsonb_array_elements(app.server_alert_feed(test.id('sta_cs'), 200, 'all')) x), true);
-- escalation: first to the next person on duty of the rule's function, then the Admins
update program_settings set alert_escalate_minutes = 1;
insert into chat_staff_prefs (user_id, last_seen_at) values (test.id('sta_fleet2'), now()) on conflict (user_id) do update set last_seen_at = now();
update notifications set created_at = now() - interval '5 minutes', read_at = null, snoozed_until = null where user_id = test.id('sta_fleet') and title = 'No-show: sa focus';
select app.job_staff_alerts();
select app.process_events(1000);
select test.eq('escalation: unopened, it goes to the next fleet person on duty first (not the Admin yet)',
  test.sta_who('staff_alert_urgent', 'Passed to you: No-show: sa focus%') || '/' || test.sta_who('staff_alert_urgent', 'Not opened: No-show: sa focus%'), 'sta_fleet2/none');
update notifications set created_at = now() - interval '5 minutes' where user_id = test.id('sta_fleet') and title = 'No-show: sa focus';
select app.job_staff_alerts();
select app.process_events(1000);
select test.eq('escalation: still unopened after the time again, the Admins', test.sta_who('staff_alert_urgent', 'Not opened: No-show: sa focus%'), 'sta_admin');
-- grouping: a burst of one normal rule pushes once as a group; each stays in the feed (the refunds earlier suites issued in
-- the last minutes are outside the window, so the burst counts this one only)
update app_events set created_at = created_at - interval '1 day' where code like 'staff_alert_%' and payload ->> 'rule' = 'refund_issued';
update program_settings set alert_burst_count = 3;
select app.staff_alert('refund_issued', 'sa', test.id('sta_g' || g), 'paid', 'Refund issued: sa burst ' || g, 'b') from generate_series(1, 6) g;
select app.process_events(1000);
select test.eq('grouping: six alerts in the feed, three pushed alone and one group alert',
  (select count(*) from notifications where user_id = test.id('sta_admin') and title like 'Refund issued: sa burst%') || '/' ||
  (select count(*) from push_outbox o join notifications n on n.id = o.notification_id where n.user_id = test.id('sta_admin') and n.title like 'Refund issued: sa burst%') || '/' ||
  (select count(*) from notifications where user_id = test.id('sta_admin') and title like '4 or more alerts: Refund issued%'), '6/3/1');
update program_settings set alert_burst_count = 50;
-- a lead's phone alert has the Call button (the lead's number)
insert into leads (id, kind, name, phone, email, message, source) values (test.id('sta_lead'), 'contact', 'Sta Lead', '4165550177', 'sta_lead@example.test', 'Hi', 'web');
select app.process_events(1000);
select test.eq('buttons: a new lead calls the lead (the Call page of the site, the number in it)',
  (select a ->> 'url' from push_outbox o join notifications n on n.id = o.notification_id, jsonb_array_elements(o.actions) a
    where n.user_id = test.id('sta_admin') and n.code = 'staff_lead_new' and n.entity_id = test.id('sta_lead') and a ->> 'action' = 'call' limit 1), '/alerts/call?to=4165550177');
-- sign-in security: an Admin's new device; a burst of failed sign-ins
select app.server_sign_in_event(jsonb_build_object('user_id', test.id('sta_admin'), 'email', 'sta_admin@example.test', 'ok', true, 'device', 'Chrome on Mac', 'country', 'CA'));
select app.server_sign_in_event(jsonb_build_object('user_id', test.id('sta_admin'), 'email', 'sta_admin@example.test', 'ok', true, 'device', 'Chrome on Mac', 'country', 'CA'));
select app.server_sign_in_event(jsonb_build_object('user_id', test.id('sta_admin'), 'email', 'sta_admin@example.test', 'ok', true, 'device', 'Firefox on Windows', 'country', 'RU'));
select app.server_sign_in_event(jsonb_build_object('email', 'sta_admin@example.test', 'ok', false, 'device', 'curl', 'country', 'US')) from generate_series(1, 6);
select app.server_sign_in_event(jsonb_build_object('email', 'verify-sa-admin@carmacars.ca', 'ok', false)) from generate_series(1, 6);
select app.process_events(1000);
select test.eq('sign-in: the first sign-in and the known device are quiet; a new device and country is urgent',
  (select count(*) from notifications where user_id = test.id('sta_admin') and code = 'staff_alert_urgent' and title like 'Admin sign-in from a new%'), 1::bigint);
select test.eq('sign-in: 5 failed on one address is one urgent alert; a test address is never counted',
  (select count(*) from notifications where user_id = test.id('sta_admin') and title like '_ failed sign-ins on one account'), 1::bigint);
select app.server_deploy_result('{"status": "failure", "sha": "abc1234def", "environment": "production"}');
select test.eq('deploy: the result reaches the Admins', (select count(*) from app_events where payload ->> 'rule' = 'deploy_result' and payload ->> 'alert_title' = 'Deploy failed (production)'), 1::bigint);
select test.eq('rpc: the feed and settings are for the server only', has_function_privilege('authenticated', 'public.server_alert_feed(uuid, integer, text)', 'execute'), false);

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
delete from push_outbox where notification_id in (select id from notifications where code in ('staff_tracker_alert', 'staff_tracker_alert_fleet'));
delete from notifications where code in ('staff_tracker_alert', 'staff_tracker_alert_fleet');
delete from app_events where code in ('staff_tracker_alert', 'staff_tracker_alert_fleet');
delete from tracker_alerts where dedupe_key like 'sta:%';
delete from job_applications where email = 'sta_applicant@example.test';
delete from tasks where task_type = 'account_deletion' and related_table = 'account_deletion_requests' and related_id in (select id from account_deletion_requests where user_id = test.id('sta_rita'));
delete from account_deletion_requests where user_id = test.id('sta_rita');
delete from academy_attempts where user_id = test.id('sta_field');
-- 0465 and 0466 fixtures
update program_settings p set alert_burst_count = s.alert_burst_count, notify_lead_burst_count = s.notify_lead_burst_count, sms_quiet_hours = s.sms_quiet_hours,
  sms_quiet_from_hour = s.sms_quiet_from_hour, sms_quiet_until_hour = s.sms_quiet_until_hour from sta_s s where s.id = p.id;
delete from staff_alert_prefs where user_id in (select id from users where email like 'sta\_%@example.test');
delete from sign_in_events where email like 'sta\_%@example.test' or user_id in (select id from users where email like 'sta\_%@example.test');
delete from sales_availability where staff_id = test.id('sta_sales');
delete from chat_messages where conversation_id = test.id('sta_chat');
delete from chat_conversations where id = test.id('sta_chat');
delete from email_suppressions where email like 'sta\_%@example.test' or email = 'verify-sa-unsub@carmacars.ca';
delete from sms_opt_out_log where number = '+16475550198';
delete from leads where id = test.id('sta_lead');
