-- 99: phone and browser alerts (Web Push, migration 0300). Fixtures start with "pu"; the endpoints are example.test.
select test.suite('99 push alerts');
select test.mk_user('pu_admin', 'admin');
select test.mk_user('pu_cs', 'va', 'cs');
select test.mk_user('pu_field', 'field');
select test.mk_owner('pu_owner');
select test.mk_renter('pu_rita');
select test.mk_renter('pu_ron');

create or replace function test.pu_sub(p_label text, p_user uuid, p_portal text default 'renter') returns jsonb
language sql as $$ select app.push_subscribe(p_user, jsonb_build_object('endpoint', 'https://push.example.test/send/' || p_label,
  'p256dh', 'B' || repeat('A', 86), 'auth', repeat('Q', 22), 'portal', p_portal, 'device', 'iPhone')) $$;
create or replace function test.pu_sub_id(p_label text) returns uuid
language sql stable as $$ select id from push_subscriptions where endpoint = 'https://push.example.test/send/' || p_label $$;
create or replace function test.pu_notice(p_label text, p_user uuid, p_code text, p_url text default null) returns uuid
language sql as $$ insert into notifications (id, user_id, code, title, body, url, dedupe_key)
  values (test.id('pu_n:' || p_label), p_user, p_code, 'Title ' || p_label, 'Body ' || p_label, p_url, 'pu:' || p_label) returning id $$;

-- ================================================================== the catalogue
select test.eq('every notice that may alert has a topic (93; 0370: the live chat message instead of the chat waiting email), and none of the sign-in links, codes or digests',
  (select count(*) filter (where push_topic is not null) || '/' || count(*) filter (where push_topic is not null and (code like 'account_%' or code like '%signing_code'
     or code like 'staff_digest_%' or code = 'renter_continue_request' or category = 'marketing')) from notification_catalogue), '93/0');
select test.eq('the four the owner named alert: a new request, a payment, a handover, a message',
  (select string_agg(push_topic, ',' order by code) from notification_catalogue where code in ('staff_booking_request_new', 'owner_payment_received', 'renter_pickup_details', 'renter_staff_message')),
  'payments,handovers,messages,requests');

-- ================================================================== defaults per portal
select test.eq('defaults: admin', array_to_string(app.push_topics(test.id('pu_admin')), ','), 'requests,payments,messages,alerts');
select test.eq('defaults: staff', array_to_string(app.push_topics(test.id('pu_cs')), ','), 'requests,bookings,messages,alerts');
select test.eq('defaults: field (their jobs and pay)', array_to_string(app.push_topics(test.id('pu_field')), ','), 'handovers,payments');
select test.eq('defaults: owner', array_to_string(app.push_topics(test.id('pu_owner')), ','), 'requests,bookings,payments,alerts,documents');
select test.eq('defaults: renter (everything)', array_length(app.push_topics(test.id('pu_rita')), 1), 7);

-- ================================================================== subscribe and unsubscribe
select test.throws('an address that is not https is refused', $$select app.push_subscribe(test.id('pu_rita'), '{"endpoint": "http://push.example.test/x", "p256dh": "x", "auth": "y"}')$$, 'cannot use');
select test.throws('keys that are not the browser''s are refused', $$select app.push_subscribe(test.id('pu_rita'), '{"endpoint": "https://push.example.test/x", "p256dh": "short", "auth": "y"}')$$, 'push_subscriptions');
select test.eq('a device turned on: listed as this device', (test.pu_sub('rita1', test.id('pu_rita')) -> 'devices' -> 0 ->> 'this'), 'true');
select test.eq('the state says this device is on', app.push_state(test.id('pu_rita'), 'https://push.example.test/send/rita1') ->> 'this_device', 'true');
select test.pu_sub('shared', test.id('pu_ron'));
select test.pu_sub('shared', test.id('pu_rita'));
select test.eq('one device, one person: the browser now alerts the person signed in',
  (select user_id from push_subscriptions where endpoint = 'https://push.example.test/send/shared'), test.id('pu_rita'));
select app.push_unsubscribe(test.id('pu_rita'), '{"endpoint": "https://push.example.test/send/shared"}');
select test.eq('unsubscribe removes only that device', (select count(*) filter (where endpoint like '%/shared') || '/' || count(*) filter (where endpoint like '%/rita1') from push_subscriptions), '0/1');
select test.eq('someone else''s device cannot be removed', (select count(*) from push_subscriptions where endpoint like '%/rita1') ||
  (app.push_unsubscribe(test.id('pu_ron'), jsonb_build_object('id', test.pu_sub_id('rita1'))) ->> 'role') || (select count(*) from push_subscriptions where endpoint like '%/rita1'), '1renter1');

-- ================================================================== topics
select test.eq('topics: unknown ones are dropped, the choice is kept', (app.push_set_topics(test.id('pu_cs'), array['messages', 'nonsense', 'alerts']) ->> 'topics'), '["alerts", "messages"]');
select test.eq('topics: the choice replaces the defaults', array_to_string(app.push_topics(test.id('pu_cs')), ','), 'alerts,messages');

-- ================================================================== the send path from the notices
select test.pu_sub('admin1', test.id('pu_admin'), 'admin');
select test.pu_sub('admin2', test.id('pu_admin'), 'admin');
select app.emit_event('staff_job_failed', 'job', test.id('pu_job'), '{"job_name": "Push test job", "job_run_date": "today", "job_effect": "Nothing ran."}', 'staff_job_failed:pu');
select app.process_events(100000);
select test.eq('an event (a job failed) alerts each device of each admin it reached, urgent and at once (one alert per notice per device)',
  (select count(*) || '/' || coalesce(bool_and(urgent), true) || '/' || coalesce(bool_and(send_after <= now()), true) from push_outbox where user_id = test.id('pu_admin') and code = 'staff_job_failed'),
  (select (2 * count(*)) || '/true/true' from notifications where user_id = test.id('pu_admin') and code = 'staff_job_failed'));
select test.ok('the job-failed event reached admins as in-app notices (the push follows them)', exists (select 1 from app_events where dedupe_key = 'staff_job_failed:pu' and processed_at is not null));
delete from push_outbox where user_id = test.id('pu_admin') and code = 'staff_job_failed';
select test.pu_notice('adm_alert', test.id('pu_admin'), 'staff_incident_reported', (app.settings()).notify_base_url || '/admin/incidents/INC-1');
select test.eq('a notice with a topic the person keeps: one urgent alert per device, now, with a path on this site',
  (select count(*) || '/' || bool_and(urgent) || '/' || bool_and(send_after <= now()) || '/' || min(url) from push_outbox where notification_id = test.id('pu_n:adm_alert')), '2/true/true//admin/incidents/INC-1');
select test.pu_notice('adm_book', test.id('pu_admin'), 'owner_booking_changed');
select test.eq('a topic the person does not keep (an admin and booking changes): no alert', (select count(*) from push_outbox where notification_id = test.id('pu_n:adm_book')), 0::bigint);
select test.pu_notice('adm_code', test.id('pu_admin'), 'account_sign_in_link');
select test.eq('a sign-in link never goes by push', (select count(*) from push_outbox where notification_id = test.id('pu_n:adm_code')), 0::bigint);
select test.pu_notice('owner_none', test.id('pu_owner'), 'owner_payment_received');
select test.eq('no device: nothing queued', (select count(*) from push_outbox where notification_id = test.id('pu_n:owner_none')), 0::bigint);
select test.pu_notice('rita_pay', test.id('pu_rita'), 'renter_payment_receipt', 'https://elsewhere.example.test/x');
select test.eq('a customer''s alert that is not urgent waits for the end of the text quiet hours; a foreign link opens the portal',
  (select (send_after = app.sms_quiet_end(created_at)) || '/' || urgent || '/' || url from push_outbox where notification_id = test.id('pu_n:rita_pay')), 'true/false//');
select test.eq('push_path: our own links become paths', app.push_path((app.settings()).notify_base_url || '/account/trips/CC-1?x=1'), '/account/trips/CC-1?x=1');
select test.eq('push_path: a protocol-relative link opens the portal', app.push_path('//evil.example.test/x'), '/');

-- ================================================================== sending: claim and answers
update push_outbox set send_after = now() - interval '1 minute' where user_id in (test.id('pu_admin'), test.id('pu_rita'));
update notifications set read_at = now() where id = test.id('pu_n:rita_pay');
select test.ok('something is waiting', app.server_push_waiting());
create temp table pu_due as select d.value as d from jsonb_array_elements(app.server_push_due(200)) d;
select test.eq('a notice read in the portal before its push went is not pushed',
  (select status || '/' || last_error from push_outbox where notification_id = test.id('pu_n:rita_pay')), 'skipped/read before it was sent');
select test.eq('the claim hands the endpoint, the keys and the payload', (select count(*) from pu_due where d ->> 'endpoint' like '%/admin%' and d ? 'p256dh' and d ? 'auth' and d -> 'payload' ? 'title'), 2::bigint);
select test.eq('claimed rows are sending', (select count(*) from push_outbox where user_id = test.id('pu_admin') and status = 'sending' and attempts = 1), 2::bigint);
select test.eq('the answers are applied',
  (app.server_push_result(jsonb_build_object('results', jsonb_build_array(
     jsonb_build_object('id', (select d ->> 'id' from pu_due where d ->> 'endpoint' like '%/admin1'), 'outcome', 'sent'),
     jsonb_build_object('id', (select d ->> 'id' from pu_due where d ->> 'endpoint' like '%/admin2'), 'outcome', 'gone')))))::text,
  '{"gone": 1, "sent": 1, "retry": 0, "failed": 0}');
select test.eq('sent: recorded on the alert and the device', (select o.status || '/' || (s.last_sent_at is not null) from push_outbox o join push_subscriptions s on s.id = o.subscription_id
  where s.endpoint like '%/admin1' and o.code = 'staff_incident_reported'), 'sent/true');
select test.eq('404 or 410: the device unsubscribed, its subscription is deleted', (select count(*) from push_subscriptions where endpoint like '%/admin2'), 0::bigint);

-- retry and refusals
select app.push_test(test.id('pu_admin'));
select test.throws('a second test alert within 30 seconds waits', $$select app.push_test(test.id('pu_admin'))$$, 'on its way');
create temp table pu_due2 as select d.value as d from jsonb_array_elements(app.server_push_due(200)) d where d -> 'payload' ->> 'code' = 'push_test';
select app.server_push_result(jsonb_build_object('results', jsonb_build_array(jsonb_build_object('id', (select d ->> 'id' from pu_due2 limit 1), 'outcome', 'retry', 'error', 'HTTP 503'))));
select test.eq('a busy push service: tried again in 5 minutes', (select status || '/' || (send_after > now() + interval '4 minutes') || '/' || last_error from push_outbox where code = 'push_test' and user_id = test.id('pu_admin')), 'queued/true/HTTP 503');
update push_subscriptions set refusals = 2 where endpoint like '%/admin1';
update push_outbox set send_after = now() - interval '1 second' where code = 'push_test' and user_id = test.id('pu_admin');
create temp table pu_due3 as select d.value as d from jsonb_array_elements(app.server_push_due(200)) d where d -> 'payload' ->> 'code' = 'push_test';
select app.server_push_result(jsonb_build_object('results', jsonb_build_array(jsonb_build_object('id', (select d ->> 'id' from pu_due3 limit 1), 'outcome', 'refused', 'error', 'HTTP 403'))));
select test.eq('the third refusal in a row (a key change) ends the subscription', (select count(*) from push_subscriptions where user_id = test.id('pu_admin')), 0::bigint);

-- ================================================================== the switch and privileges
create temp table pu_s as select id, push_enabled from program_settings;
update program_settings set push_enabled = false;
select test.pu_sub('rita2', test.id('pu_rita'));
select test.pu_notice('rita_off', test.id('pu_rita'), 'renter_offer_ready');
select test.eq('switched off: nothing is queued and nothing is handed out',
  (select count(*) from push_outbox where notification_id = test.id('pu_n:rita_off')) || '/' || app.server_push_due(10)::text, '0/[]');
update program_settings p set push_enabled = s.push_enabled from pu_s s where s.id = p.id;
select test.ok('the push functions are not callable from a browser',
  not has_function_privilege('authenticated', 'public.server_push_due(integer)', 'execute') and not has_function_privilege('anon', 'public.server_push_subscribe(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'app.push_subscribe(uuid, jsonb)', 'execute') and has_function_privilege('service_role', 'public.server_push_result(jsonb)', 'execute'));
select set_config('request.jwt.claim.sub', test.id('pu_rita')::text, false);
set role authenticated;
select test.eq('row security: a signed-in renter reads no subscription, choice or alert (not even her own; the server reads them)',
  (select count(*) from push_subscriptions) + (select count(*) from push_preferences) + (select count(*) from push_outbox), 0::bigint);
reset role;
select set_config('request.jwt.claim.sub', '', false);
select test.ok('the privacy policy: the alerts paragraph after the text alerts one (where the live policy has our text)',
  coalesce((select body like '%we then reach you by email. Message and data rates may apply.%If you turn on alerts on a phone or computer%delete them when you turn alerts off%'
     from site_content_blocks where block_key = 'legal.privacy'), true)
  or not exists (select 1 from site_content_blocks where block_key = 'legal.privacy' and body like '%Message and data rates may apply.%'));
