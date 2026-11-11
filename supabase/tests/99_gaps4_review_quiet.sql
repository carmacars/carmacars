-- 99: review ask before the booking ends (1870), renter text quiet hours 1 am to 5 am with urgent exemptions (1871), staff quiet hours for
-- staff emails and texts (1872). Fixtures start with "g4"; addresses are example.test.
select test.suite('99 gaps4 review quiet');
update program_settings set review_program_enabled = true;
select test.mk_user('g4_admin', 'admin');
select test.mk_user('g4_cs', 'va', 'cs');
select test.mk_owner('g4_owner');
select test.mk_vehicle('g4_car', 'g4_owner');
select test.mk_vehicle('g4_car2', 'g4_owner');
select test.mk_vehicle('g4_car3', 'g4_owner');
select test.mk_vehicle('g4_car4', 'g4_owner');
select test.mk_vehicle('g4_car5', 'g4_owner');
select test.mk_vehicle('g4_car6', 'g4_owner');
select test.mk_vehicle('g4_car7', 'g4_owner');
select test.mk_vehicle('g4_car8', 'g4_owner');
select test.mk_vehicle('g4_car9', 'g4_owner');
select test.mk_vehicle('g4_car10', 'g4_owner');
select test.mk_vehicle('g4_car11', 'g4_owner');
select test.mk_vehicle('g4_car12', 'g4_owner');
select test.mk_renter('g4_maya');
select test.mk_renter('g4_unsub');
create or replace function test.g4t(p text) returns timestamptz language sql immutable as $$ select p::timestamp at time zone 'America/Toronto' $$;
create or replace function test.g4b(p text) returns uuid language sql immutable as $$ select test.id('booking:' || p) $$;
create or replace function test.g4ev(p_code text, p text) returns bigint language sql volatile as $$ select count(*) from app_events where code = p_code and entity_id = test.g4b(p) $$;

-- ================================================================ 1. the soft ask on the last full day
select test.eq('settings: the soft ask is on, the day before the return',
  (select format('%s %s', review_preask_enabled, review_preask_days_before) from program_settings order by effective_from desc limit 1), 't 1');
select test.mk_booking('G4-1', 'g4_car', 'g4_maya', '2026-11-02 10:00', '2026-11-05 10:00', 'on_rent');
select test.eq('soft ask: before the last full day it is the plain check-in', app.review_step(test.g4b('G4-1'), test.g4t('2026-11-03 10:05')), 'checkin');
select test.mk_booking('G4-2', 'g4_car2', 'g4_maya', '2026-11-02 10:00', '2026-11-05 10:00', 'on_rent');
select test.eq('soft ask: the last full day before 9 am waits', coalesce(app.review_step(test.g4b('G4-2'), test.g4t('2026-11-04 08:00')), 'none'), 'none');
select test.eq('soft ask: the last full day inside the hours', app.review_step(test.g4b('G4-2'), test.g4t('2026-11-04 09:30')), 'preask');
select test.eq('soft ask: once, and it counts as the check-in',
  test.g4ev('renter_review_preask', 'G4-2') || '/' || coalesce(app.review_step(test.g4b('G4-2'), test.g4t('2026-11-04 12:00')), 'none') || '/'
  || ((select checkin_sent_at is not null and preask_sent_at is not null from review_requests where booking_id = test.g4b('G4-2'))), '1/none/true');
select test.eq('soft ask: the email has the review link and the text names the points',
  (select app.notification_payload('renter_review_preask', e, '{}'::jsonb) ->> 'review_url' from app_events e where e.code = 'renter_review_preask' and e.entity_id = test.g4b('G4-2'))
  ~ '^https://.*/review/[0-9a-f-]{36}$' || ' ' || (select body like '%review%' and body like '%Rewards points%' and body like '%{{link}}%' from sms_templates where code = 'renter_review_preask'), 'true true');
select test.eq('soft ask: the email is in the catalogue with the review link and the button''s variables',
  (select preheader like '%Rewards points%' and variables @> '[{"name": "review_url"}]'::jsonb and variables @> '[{"name": "review_done_url"}]'::jsonb and category = 'marketing' from notification_catalogue where code = 'renter_review_preask'), true);
-- someone who reviewed already: nothing, and nothing more later
select test.mk_booking('G4-3', 'g4_car3', 'g4_maya', '2026-11-02 10:00', '2026-11-05 10:00', 'on_rent');
select test.eq('soft ask: staff marked the renter as reviewed', app.door(test.id('g4_admin'), 'aal2', 'ops_do', 'review_mark_reviewed', '{"booking":"G4-3"}') ->> 'stopped', 'true');
select test.eq('soft ask: never to someone who reviewed', app.review_step(test.g4b('G4-3'), test.g4t('2026-11-04 10:00')) || '/' || test.g4ev('renter_review_preask', 'G4-3'), 'stopped:staff_marked_reviewed/0');
-- an unsubscribed renter
select test.mk_booking('G4-4', 'g4_car4', 'g4_unsub', '2026-11-02 10:00', '2026-11-05 10:00', 'on_rent');
update users set marketing_unsubscribed_at = now() where id = test.id('g4_unsub');
select test.eq('soft ask: never after an unsubscribe', test.g4ev('renter_review_preask', 'G4-4') || '/' || coalesce(app.review_step(test.g4b('G4-4'), test.g4t('2026-11-04 10:00')), 'none') || '/' || test.g4ev('renter_review_preask', 'G4-4'), '0/checkin/0');
-- a short rental has no check-in and no soft ask
select test.mk_booking('G4-5', 'g4_car6', 'g4_maya', '2026-11-10 10:00', '2026-11-11 10:00', 'on_rent');
select test.eq('soft ask: a one-day rental gets none', coalesce(app.review_step(test.g4b('G4-5'), test.g4t('2026-11-10 12:00')), 'none'), 'none');
-- off switch
update program_settings set review_preask_enabled = false;
select test.mk_booking('G4-6', 'g4_car5', 'g4_maya', '2026-11-02 10:00', '2026-11-05 10:00', 'on_rent');
select test.eq('soft ask: off in the settings, the check-in goes instead', app.review_step(test.g4b('G4-6'), test.g4t('2026-11-04 10:00')), 'checkin');
update program_settings set review_preask_enabled = true;
-- the after-return sequence still follows, and stops once a review exists
select test.mk_booking('G4-7', 'g4_car', 'g4_maya', '2026-11-12 10:00', '2026-11-15 10:00', 'returned');
select test.eq('after return: the request at +1 h', app.review_step(test.g4b('G4-7'), test.g4t('2026-11-15 11:01')), 'ask');
select test.eq('after return: the reminder at +24 h', app.review_step(test.g4b('G4-7'), test.g4t('2026-11-16 11:30')), 'reminder');
update bookings set status = 'closed' where id = test.g4b('G4-7');
insert into reviews (booking_id, renter_id, vehicle_id, rating, title) values (test.g4b('G4-7'), test.id('renter:g4_maya'), test.id('vehicle:g4_car'), 4, 'Good');
select test.eq('after return: the final follow-up is skipped once a review exists', app.review_step(test.g4b('G4-7'), test.g4t('2026-11-22 11:30')) || '/' || test.g4ev('renter_review_final', 'G4-7'), 'stopped:onsite_review/0');
select test.eq('after return: a booking asked and reviewed in between gets no reminder',
  (select status from review_requests where booking_id = test.g4b('G4-7')), 'stopped');

-- ================================================================ 2. renter texts: quiet hours 1 am to 5 am
select test.eq('quiet hours default to 1 to 5',
  (select format('%s %s %s', sms_quiet_hours, sms_quiet_from_hour, sms_quiet_until_hour) from program_settings order by effective_from desc limit 1), 't 1 5');
select test.eq('quiet hours: 2 am waits for 5 am, 12:30 am and 5 am and 11 pm go now',
  to_char(app.sms_quiet_end(test.g4t('2026-11-10 02:00')) at time zone 'America/Toronto', 'DD HH24:MI') || ' '
  || to_char(app.sms_quiet_end(test.g4t('2026-11-10 00:30')) at time zone 'America/Toronto', 'DD HH24:MI') || ' '
  || to_char(app.sms_quiet_end(test.g4t('2026-11-10 05:00')) at time zone 'America/Toronto', 'DD HH24:MI') || ' '
  || to_char(app.sms_quiet_end(test.g4t('2026-11-10 23:00')) at time zone 'America/Toronto', 'DD HH24:MI'), '10 05:00 10 00:30 10 05:00 10 23:00');
select test.mk_booking('G4-8', 'g4_car7', 'g4_maya', to_char((now() + interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '8 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
select test.mk_booking('G4-9', 'g4_car8', 'g4_maya', to_char((now() - interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
select test.mk_booking('G4-10', 'g4_car9', 'g4_maya', to_char((now() - interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() - interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
select test.eq('urgent: not for a booking days away', app.sms_renter_urgent('renter_return_reminder', test.g4b('G4-8'), false), false);
select test.eq('urgent: a return today', app.sms_renter_urgent('renter_return_reminder', test.g4b('G4-9'), false), true);
select test.eq('urgent: overdue', app.sms_renter_urgent('renter_return_reminder', test.g4b('G4-10'), false), true);
select test.eq('urgent: a sign-in or signing code, and a template marked urgent',
  app.sms_renter_urgent('renter_signing_code', null, false)::text || app.sms_renter_urgent('account_sign_in_link', null, false)::text || app.sms_renter_urgent('x', null, true)::text, 'truetruetrue');
select test.eq('urgent: a pickup today', (select app.sms_renter_urgent('x', test.mk_booking('G4-11', 'g4_car10', 'g4_maya', to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed'), false)), true);
-- through the outbox: quiet now (from this hour to the next)
update program_settings set sms_alerts_enabled = true, phone_enabled = true, sms_default_with_phone = 'both', signin_phone_us_allowed = false,
  sms_quiet_hours = true, sms_quiet_from_hour = app.local_hour(now()), sms_quiet_until_hour = (app.local_hour(now()) + 1) % 24;
update users set phone = '+16475550390', phone_verified_at = now() where id = test.id('g4_maya');
select app.set_notify_channel(test.id('g4_maya'), 'both');
create or replace function test.g4mail(p_code text, p_key text, p_booking text) returns notification_outbox language sql as $$
  insert into notification_outbox (code, category, priority, audience, recipient_user_id, to_address, renter_id, booking_id, payload, dedupe_key, status)
  values (p_code, (select category from notification_catalogue where code = p_code), 1, 'renter', test.id('g4_maya'), 'g4_maya@example.test', test.id('renter:g4_maya'),
          test.g4b(p_booking), jsonb_build_object('first_name', 'Maya', 'booking_number', p_booking, 'vehicle_name', '2023 Test Car', 'return_time', '10:00 am', 'pickup_time', '10:00 am',
            'pickup_date', 'Fri, Oct 30, 2026', 'return_date', 'Sat, Oct 31, 2026'), p_key, 'queued')
  returning * $$;
select test.g4mail('renter_return_reminder', 'g4-a', 'G4-8');
select test.g4mail('renter_return_reminder', 'g4-b', 'G4-9');
select test.g4mail('renter_return_reminder', 'g4-c', 'G4-10');
select test.eq('in the quiet hours: a text for a booking days away waits for the end',
  (select send_after > now() + interval '1 second' and send_after <= now() + interval '1 hour' from phone_outbox where dedupe_key = 'sms:g4-a'), true);
select test.eq('...a text for a return today goes now', (select send_after <= now() and urgent from phone_outbox where dedupe_key = 'sms:g4-b'), true);
select test.eq('...an overdue rental''s text goes now', (select send_after <= now() and urgent from phone_outbox where dedupe_key = 'sms:g4-c'), true);
select test.eq('...the held text is not claimed by the job yet',
  (select count(*) from jsonb_array_elements(app.server_phone_due() -> 'texts') x where x ->> 'id' = (select id::text from phone_outbox where dedupe_key = 'sms:g4-a')), 0::bigint);
update phone_outbox set send_after = now() - interval '1 second' where dedupe_key = 'sms:g4-a';
select test.eq('...after the quiet hours the held text is sent (due for the job)',
  (select count(*) from jsonb_array_elements(app.server_phone_due() -> 'texts') x where x ->> 'id' = (select id::text from phone_outbox where dedupe_key = 'sms:g4-a')), 1::bigint);
update program_settings set sms_quiet_hours = false;

-- ================================================================ 3. staff: quiet hours hold staff emails and texts
select test.mk_user('g4_staff', 'va', 'cs');
select test.mk_user('g4_plain', 'va', 'cs');
update users set phone = '+16475550391', phone_verified_at = now() where id = test.id('g4_staff');
update users set phone = '+16475550392', phone_verified_at = now() where id = test.id('g4_plain');
insert into staff_alert_prefs (user_id, quiet_on, quiet_from, quiet_until)
values (test.id('g4_staff'), true, (app.local_hour(now()) * 60), ((app.local_hour(now()) + 1) % 24) * 60);
create or replace function test.g4staff(p_code text, p_key text, p_user text, p_payload jsonb default '{}'::jsonb) returns notification_outbox language sql as $$
  insert into notification_outbox (code, category, priority, audience, recipient_user_id, to_address, payload, dedupe_key, status)
  values (p_code, (select category from notification_catalogue where code = p_code), 1, (select audience from notification_catalogue where code = p_code), test.id(p_user),
          p_user || '@example.test', p_payload, p_key, 'queued')
  returning * $$;
create temp table g4_codes as
  select (select code from notification_catalogue where audience like 'staff\_%' and not is_digest and coalesce(push_topic, '') not in ('alerts', 'leads') and code not like 'staff_alert%' order by code limit 1) as normal,
         (select code from notification_catalogue where audience like 'staff\_%' and push_topic = 'alerts' order by code limit 1) as urgent,
         (select code from notification_catalogue where audience like 'staff\_%' and is_digest order by code limit 1) as digest;
select test.ok('staff fixtures: a normal, an urgent and a digest code exist', (select normal is not null and urgent is not null and digest is not null from g4_codes));
select test.g4staff((select normal from g4_codes), 'g4-s1', 'g4_staff');
select test.g4staff((select normal from g4_codes), 'g4-s2', 'g4_staff');
select test.g4staff((select urgent from g4_codes), 'g4-s3', 'g4_staff');
select test.g4staff((select digest from g4_codes), 'g4-s4', 'g4_staff');
select test.g4staff((select normal from g4_codes), 'g4-s5', 'g4_plain');
select test.eq('staff email in their quiet hours: held until the end, all at the same moment',
  (select count(distinct send_after) = 1 and min(send_after) > now() + interval '1 second' and max(send_after) <= now() + interval '1 hour 1 minute'
     from notification_outbox where dedupe_key in ('g4-s1', 'g4-s2')), true);
select test.eq('...an urgent staff email goes now', (select send_after <= now() from notification_outbox where dedupe_key = 'g4-s3'), true);
select test.eq('...a digest (the summary itself) goes now', (select send_after <= now() from notification_outbox where dedupe_key = 'g4-s4'), true);
select test.eq('...a person without quiet hours turned on gets it now', (select send_after <= now() from notification_outbox where dedupe_key = 'g4-s5'), true);
select test.eq('staff email: the held ones are not due yet, they are after the end',
  (select count(*) from notification_outbox where dedupe_key in ('g4-s1', 'g4-s2') and send_after <= now()) || '/'
  || (select count(*) from notification_outbox where dedupe_key in ('g4-s1', 'g4-s2') and send_after <= now() + interval '2 hours'), '0/2');
select test.eq('staff quiet hold: outside the quiet hours it is the time itself',
  app.staff_quiet_hold(test.id('g4_staff'), (select normal from g4_codes), '{}'::jsonb, now() + interval '3 hours'), now() + interval '3 hours');
-- staff texts
select app.phone_outbox_put('+16475550391', 'CarmaCars: usage test', 'staff', null, null, 'usage_alert', null, 'g4-t1');
select app.phone_outbox_put('+16475550392', 'CarmaCars: usage test', 'staff', null, null, 'usage_alert', null, 'g4-t2');
select app.phone_outbox_put('+16475550391', 'CarmaCars: urgent test', 'staff', null, null, 'staff_alert_urgent', null, 'g4-t3');
select test.eq('staff text in their quiet hours waits for the end; an urgent one and a person without quiet hours go now',
  (select send_after > now() + interval '1 second' from phone_outbox where dedupe_key = 'g4-t1') || ' '
  || (select send_after <= now() from phone_outbox where dedupe_key = 'g4-t2') || ' '
  || (select send_after <= now() from phone_outbox where dedupe_key = 'g4-t3'), 'true true true');
select test.eq('staff text: a reply typed by a person is never held',
  (select send_after <= now() from app.phone_outbox_put('+16475550391', 'Hello', 'staff', null, null, null, null, 'g4-t4', now(), 'sending', test.id('g4_staff'))), true);
-- role check: the new functions are not callable by signed-in users
select test.ok('the quiet-hours functions are for the server only',
  not has_function_privilege('authenticated', 'app.staff_quiet_hold(uuid, text, jsonb, timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'app.sms_renter_urgent(text, uuid, boolean, timestamptz)', 'execute')
  and not has_function_privilege('anon', 'app.staff_notice_urgent(text, jsonb)', 'execute'));
