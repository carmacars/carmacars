-- 99: release 35 part Z (migration 0970, docs/changes/2026-11-08-r35-fleet-calls-alerts.md): Fleet collects payments and
-- has its own phone lane and the caller pop-up, Sales sees customer numbers masked, the Twilio Call button's log and
-- minutes, one staff alert per booking moment and the renter's overdue chase, the quiet hours summary, and one alert per
-- hire with Hire from any stage. Fixtures start with "rz"; every address is example.test.
select test.suite('99 r35z fleet, sales numbers, calls, one alert per moment');
update app_events set processed_at = now() where processed_at is null;
create temp table rz_ps as select id, late_chase_grace_minutes g, notify_not_back_minutes nb, require_staff_two_step t from program_settings;
update program_settings set late_chase_grace_minutes = 15, notify_not_back_minutes = 15, require_staff_two_step = false where id is not null;

select test.mk_user('rz_admin', 'admin');
select test.mk_user('rz_cs', 'va', 'cs');
select test.mk_user('rz_fleet', 'va', 'fleet');
select test.mk_user('rz_sales', 'va', 'sales');
select test.mk_user('rz_fin', 'va', 'finance');
select test.mk_user('rz_field', 'field');
update users set phone = '+16475550161' where id = test.id('rz_sales');
update users set phone = '+16475550162' where id = test.id('rz_field');
select test.mk_owner('rz_own');
select test.mk_vehicle('RZA', 'rz_own');
select test.mk_vehicle('RZB', 'rz_own');
select test.mk_renter('rz_rita');
select test.mk_renter('rz_quiet');
update renters set mobile = '(647) 555-0199', legal_name = 'Rz Rita' where id = test.id('renter:rz_rita');
update renters set mobile = '(416) 555-0177' where id = test.id('renter:rz_quiet');
create function test.rzt(p_offset interval) returns text language sql stable as $$
  select to_char((now() + p_offset) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
-- on rent, due back 30 minutes ago, with a return check-in for the field staff member
select test.mk_booking('RZ-1', 'RZA', 'rz_rita', test.rzt('-2 days'), test.rzt('-30 minutes'), 'on_rent');
insert into field_jobs (id, kind, booking_id, vehicle_id, assigned_to, scheduled_at, place)
values (test.id('job:rz-1'), 'return_check_in', test.id('booking:RZ-1'), test.id('vehicle:RZA'), test.id('rz_field'), (select return_at from bookings where booking_number = 'RZ-1'), '1 Example Street, Toronto');
-- a renter with nothing coming: the customer service lane
select test.mk_booking('RZ-OLD', 'RZB', 'rz_quiet', '2025-01-05 10:00', '2025-01-07 10:00', 'closed');

-- ================================================================ 1. Fleet collects payments, never refunds
select test.eq('Fleet: may start card payments and pay links, and charge the saved card; customer service may not charge it',
  app.card_collect_allowed(test.id('rz_fleet'))::text || '/' || app.user_collects_money(test.id('rz_fleet'))::text || '/' || app.user_collects_money(test.id('rz_cs'))::text, 'true/true/false');
select test.ok('Fleet: the saved card and the deposit hold on it check app.user_collects_money',
  (select bool_and(pg_get_functiondef(p.oid) like '%app.user_collects_money(p_by)%') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('card_charge_begin_pre0680', 'deposit_hold_saved_begin')));
select test.ok('Fleet: captures, releases and refunds stay with Finance',
  (select bool_and(pg_get_functiondef(p.oid) not like '%user_collects_money%') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('hold_action_finish', 'request_refund', 'refund_approve') and p.prokind = 'f'));
select test.ok('Fleet: cash above the single limit is refused, within it allowed (Finance checks it)',
  app.booking_payment_allowed(test.id('rz_fleet'), 5000) like '%above your single limit%');
update staff_profiles set single_limit_cents = 50000 where user_id = test.id('rz_fleet');
select test.ok('Fleet: within its single limit', app.booking_payment_allowed(test.id('rz_fleet'), 5000) is null);
select test.eq('Fleet: records cash on a booking', (app.door(test.id('rz_fleet'), 'aal2', 'ops_do', 'manual_payment_record',
  jsonb_build_object('booking', 'RZ-1', 'method', 'cash', 'amount_cents', 5000, 'received_on', app.today()::text, 'purpose', 'post_rental')) ->> 'ok'), 'true');
select test.eq('Fleet: Finance gets a To do to check it', (select count(*) from tasks where task_type = 'fleet_payment_check' and booking_id = test.id('booking:RZ-1') and queue = 'finance'), 1::bigint);
select test.throws('Fleet: never voids it', format($$select app.door(%L, 'aal2', 'ops_do', 'manual_payment_void', %L)$$, test.id('rz_fleet'),
  jsonb_build_object('id', (select id from manual_payments where booking_id = test.id('booking:RZ-1') limit 1), 'reason', 'test')), '');

-- ================================================================ 2. the Fleet lane and the pop-up
select test.eq('lane: a car on rent is Fleet''s, nothing coming is customer service''s',
  app.phone_lane(test.id('renter:rz_rita')) || '/' || app.phone_lane(test.id('renter:rz_quiet')), 'fleet/cs');
select test.lives('pop-up: Fleet gets it', format($$select app.door(%L, 'aal2', 'va_read', 'caller_live', '{}')$$, test.id('rz_fleet')));
select test.throws('pop-up: Sales does not', format($$select app.door(%L, 'aal2', 'va_read', 'caller_live', '{}')$$, test.id('rz_sales')), '%Admins, customer service and Fleet%');
select app.server_phone_event(jsonb_build_object('type', 'call.ringing', 'event_id', 'EVRZ1', 'call_id', 'ACRZ1', 'quo_id', 'ACRZ1', 'direction', 'in',
  'their_number', '+16475550199', 'at', now(), 'status', null));
select test.eq('pop-up: a call about a car on rent rings for Fleet first, not customer service while Fleet is on duty',
  (select count(*) from jsonb_array_elements(app.door(test.id('rz_fleet'), 'aal2', 'va_read', 'caller_live', '{}') -> 'calls') x where x ->> 'number' = '+16475550199')
  || '/' || (select count(*) from jsonb_array_elements(app.door(test.id('rz_cs'), 'aal2', 'va_read', 'caller_live', '{}') -> 'calls') x where x ->> 'number' = '+16475550199' and x ->> 'lane' = 'fleet'),
  '1/1');
insert into chat_staff_prefs (user_id, last_seen_at) values (test.id('rz_fleet'), now()) on conflict (user_id) do update set last_seen_at = now();
select test.eq('pop-up: with Fleet on duty, customer service does not get a fresh Fleet call',
  (select count(*) from jsonb_array_elements(app.door(test.id('rz_cs'), 'aal2', 'va_read', 'caller_live', '{}') -> 'calls') x where x ->> 'number' = '+16475550199')::text, '0');
select app.server_phone_event(jsonb_build_object('type', 'call.completed', 'event_id', 'EVRZ1done', 'call_id', 'ACRZ1', 'quo_id', 'ACRZ1', 'direction', 'in',
  'their_number', '+16475550199', 'at', now(), 'status', 'missed', 'missed', true));
select test.eq('a missed call about a car on rent: the call-back To do is Fleet''s',
  coalesce((select queue from tasks where task_type = 'phone_missed_call' and renter_id = test.id('renter:rz_rita') order by created_at desc limit 1), 'none'), 'fleet');
select test.lives('texts: Fleet opens the inbox (its lane)', format($$select app.door(%L, 'aal2', 'va_read', 'phone_inbox', '{}')$$, test.id('rz_fleet')));
select test.eq('texts: the thread says its lane', (select x ->> 'lane' from jsonb_array_elements(app.door(test.id('rz_admin'), 'aal2', 'admin_read', 'phone_inbox', '{}') -> 'threads') x where x ->> 'number' = '+16475550199'), 'fleet');

-- ================================================================ 3. Sales sees numbers masked
select test.eq('mask: the display', app.phone_mask_display('(647) 555-0199'), '(647) ' || chr(8226) || chr(8226) || chr(8226) || '-' || chr(8226) || chr(8226) || '99');
select test.eq('mask: a number inside text, our own number kept, booking numbers and dates untouched',
  app.mask_phone_text(test.id('rz_sales'), 'Call 647-555-0199 or +1 416 555 0177, us at +16475550100, RZ-1 on 2026-11-08 10:00', '+16475550100'),
  'Call (647) •••-••99 or (416) •••-••77, us at +16475550100, RZ-1 on 2026-11-08 10:00');
select test.eq('Sales: the renter search by phone finds the renter, the number masked',
  (select x ->> 'mobile' from jsonb_array_elements(app.door(test.id('rz_sales'), 'aal2', 'va_read', 'phone_renter_search', '{"q": "647 555 0199"}')) x where x ->> 'name' = 'Rz Rita'),
  '(647) •••-••99');
select test.eq('customer service and Fleet: the full number',
  (select x ->> 'mobile' from jsonb_array_elements(app.door(test.id('rz_cs'), 'aal2', 'va_read', 'phone_renter_search', '{"q": "Rz Rita"}')) x limit 1)
  || '/' || (select x ->> 'mobile' from jsonb_array_elements(app.door(test.id('rz_fleet'), 'aal2', 'va_read', 'phone_renter_search', '{"q": "Rz Rita"}')) x limit 1),
  '(647) 555-0199/(647) 555-0199');
select test.eq('Sales: the platform Call and Text find the number on the server', app.server_phone_unmask(test.id('rz_sales'), '{"masked": "(647) •••-••99"}'), '+16475550199');
select test.throws('Sales: a masked number never shown to this person is not found', format($$select app.server_phone_unmask(%L, '{"masked": "(905) •••-••11"}')$$, test.id('rz_sales')), '%Open the record again%');
insert into notifications (user_id, code, title, body, url, dedupe_key) values (test.id('rz_sales'), 'staff_alert_urgent', 'New lead: Rz Lee, 905-555-0111', 'Call +19055550111 now', '/staff/leads', 'rz:lead1');
select test.eq('Sales: the in-app alert carries the number masked', (select title || ' / ' || body from notifications where user_id = test.id('rz_sales') and title like 'New lead: Rz Lee%'),
  'New lead: Rz Lee, (905) •••-••11 / Call (905) •••-••11 now');
update renters set mobile = '(647) •••-••99' where id = test.id('renter:rz_rita');
select test.eq('a masked number is never saved over the real one', (select mobile from renters where id = test.id('renter:rz_rita')), '(647) 555-0199');
select test.throws('reveal: only an Admin', format($$select app.door(%L, 'aal2', 'va_do', 'phone_reveal', '{"masked": "(647) •••-••99"}')$$, test.id('rz_cs')), '%Only an Admin%');
select test.eq('reveal: an Admin gets the number', (app.door(test.id('rz_admin'), 'aal2', 'admin_do', 'phone_reveal', '{"masked": "(647) •••-••99", "reason": "Sales asked"}') ->> 'number'), '+16475550199');
select test.eq('reveal: audited', (select count(*) from audit_log where action = 'phone_reveal' and actor_user_id = test.id('rz_admin')), 1::bigint);

-- ================================================================ 4. the Call button (Twilio): the log and the minutes
select test.throws('calls: the staff member''s own cell is needed', format($$select app.server_twilio_call_start(%L)$$, jsonb_build_object('user_id', test.id('rz_cs'), 'number', '+16475550199')), '%own cell number%');
create temp table rz_call as select (app.server_twilio_call_start(jsonb_build_object('user_id', test.id('rz_sales'), 'number', '+16475550199', 'booking_number', 'RZ-1')) ->> 'id')::uuid id;
select test.eq('calls: the TwiML needs the customer and our number', (select (app.server_twilio_call_get(id) ->> 'to') from rz_call), '+16475550199');
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'started', 'call_sid', 'CA' || repeat('1', 32))) from rz_call;
select app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'staff_answered')) from rz_call;
select test.eq('calls: the customer leg completed after 125 s', (select (app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'dial', 'status', 'completed', 'duration', '125')) ->> 'outcome') from rz_call), 'connected');
select test.eq('calls: logged on the renter''s and the booking''s history',
  (select count(*) from phone_activity a where a.kind = 'call' and a.direction = 'out' and a.duration_seconds = 125 and a.booking_id = test.id('booking:RZ-1')
               and a.renter_id = test.id('renter:rz_rita') and a.sent_by = test.id('rz_sales')), 1::bigint);
select test.eq('calls: the staff leg ending after that changes nothing', (select (app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'staff', 'status', 'completed', 'duration', '140')) ->> 'done') from rz_call), 'true');
select test.eq('calls: the rep''s outbound minutes', app.sales_call_minutes(test.id('rz_sales'), now() - interval '1 hour', now() + interval '1 minute'), 2.1);
select test.eq('calls: on the Sales home', (app.door(test.id('rz_sales'), 'aal2', 'va_read', 'my_call_minutes', '{}') ->> 'today'), '2.1');
create temp table rz_call2 as select (app.server_twilio_call_start(jsonb_build_object('user_id', test.id('rz_sales'), 'number', '+16475550199')) ->> 'id')::uuid id;
select test.eq('calls: a staff phone not answered is logged as such, no minutes',
  (select (app.server_twilio_call_event(jsonb_build_object('id', id, 'kind', 'staff', 'status', 'no-answer', 'duration', '0')) ->> 'outcome') from rz_call2)
  || '/' || app.sales_call_minutes(test.id('rz_sales'), now() - interval '1 hour', now() + interval '1 minute'), 'your phone was not answered/2.1');

-- ================================================================ 5. one staff alert per booking moment
select app.notify_booking_staff(now());
select app.notify_booking_staff(now() + interval '1 minute');
select test.eq('not back: one alert for the booking and its return time, none of the old two',
  (select count(*) from app_events where code = 'staff_alert_urgent' and payload ->> 'rule' = 'booking_not_back' and entity_id = test.id('booking:RZ-1'))
  || '/' || (select count(*) from app_events where code in ('staff_not_back', 'staff_not_back_admin') and entity_id = test.id('booking:RZ-1')), '1/0');
select test.ok('not back: it says the return time, the reminder and the return check-in',
  (select payload ->> 'alert_title' from app_events where code = 'staff_alert_urgent' and payload ->> 'rule' = 'booking_not_back' and entity_id = test.id('booking:RZ-1'))
    ~ '^RZ-1 not back: due .*, renter not reminded yet, return check-in not started$');
select app.process_events(1000);
select test.eq('not back: the Admin, the field staff member of the return and Fleet, once each',
  (select string_agg(replace(u.email, '@example.test', ''), ',' order by u.email) from notifications n join users u on u.id = n.user_id
    where n.code = 'staff_alert_urgent' and n.title like 'RZ-1 not back%' and u.email like 'rz\_%'), 'rz_admin,rz_field,rz_fleet');
select test.eq('not back: Call and Open on the phone alert',
  (select string_agg(x ->> 'action', ',') from jsonb_array_elements(app.alert_actions('staff_alert_urgent', '{"rule": "booking_not_back", "call": "+16475550199"}', '/admin/bookings/RZ-1', true)) x), 'call,open');
select test.eq('not back: one text to the field staff member', (select count(*) from phone_outbox where to_number = '+16475550162' and booking_id = test.id('booking:RZ-1') and body like 'CarmaCars: RZ-1 not back%'), 1::bigint);
select test.eq('job late: the late return check-in is in the "not back" alert, not its own', (select count(*) from field_jobs j where j.id = test.id('job:rz-1') and app.job_late_folded(j.kind, j.booking_id, now()))::text, '1');
insert into notification_outbox (code, category, priority, audience, to_address, to_name, booking_id, entity, entity_id, payload, dedupe_key, status)
values ('renter_late_return_first', 'transactional', 3, 'renter', 'rz_rita@example.test', 'Rz Rita', test.id('booking:RZ-1'), 'booking', test.id('booking:RZ-1'), '{}'::jsonb, 'rz:mirror', 'queued');
select test.eq('a copy of a renter message is no staff alert of its own',
  (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'sent:renter_late_return_first' and payload ->> 'booking_id' = test.id('booking:RZ-1')::text), 0::bigint);

-- the renter's chase: the grace, "returning now", the return job, the tracker
select test.eq('chase: waits the grace, then goes',
  app.renter_chase_paused(test.id('booking:RZ-1'), (select return_at + interval '5 minutes' from bookings where booking_number = 'RZ-1'))::text
  || '/' || app.renter_chase_paused(test.id('booking:RZ-1'), now())::text, 'true/false');
select test.eq('chase: the reminders job sends nothing inside the grace',
  (select count(*) from app_events where code = 'renter_return_due' and entity_id = test.id('booking:RZ-1'))::text, '0');
select test.lives('returning now: customer service marks it', format($$select app.door(%L, 'aal2', 'va_do', 'late_returning_now', %L)$$, test.id('rz_cs'), jsonb_build_object('booking', 'RZ-1')));
select test.eq('returning now: the chase stops', app.renter_chase_paused(test.id('booking:RZ-1'), now())::text, 'true');
select app.notify_reminders(now());
select test.eq('returning now: no late notice to the renter', (select count(*) from app_events where code = 'renter_late_return_first' and entity_id = test.id('booking:RZ-1'))::text, '0');
update bookings set returning_now_at = null where booking_number = 'RZ-1';
update field_jobs set status = 'in_progress' where id = test.id('job:rz-1');
select test.eq('the return job started: the chase stops', app.renter_chase_paused(test.id('booking:RZ-1'), now())::text, 'true');
update field_jobs set status = 'scheduled' where id = test.id('job:rz-1');
select test.throws('returning now: Sales may not', format($$select app.door(%L, 'aal2', 'va_do', 'late_returning_now', %L)$$, test.id('rz_sales'), jsonb_build_object('booking', 'RZ-1')), '%mark a car returning%');

-- ================================================================ 6. quiet hours: one summary
insert into push_subscriptions (id, user_id, endpoint, p256dh, auth, kind) values (test.id('rz_sub'), test.id('rz_fleet'), 'https://push.example.test/send/rz', 'B' || repeat('A', 86), repeat('Q', 22), 'web');
insert into push_outbox (subscription_id, user_id, code, title, url, send_after, quiet_hold, created_at)
values (test.id('rz_sub'), test.id('rz_fleet'), 'staff_alert_normal', 'Car going out: RZ-1', '/staff/bookings/RZ-1', now() - interval '1 minute', true, now() - interval '9 hours'),
       (test.id('rz_sub'), test.id('rz_fleet'), 'staff_alert_normal', 'Car back: RZ-2', '/staff/bookings/RZ-2', now() - interval '1 minute', true, now() - interval '8 hours'),
       (test.id('rz_sub'), test.id('rz_fleet'), 'staff_alert_urgent', 'Urgent: RZ-3', '/staff/bookings/RZ-3', now() - interval '1 minute', false, now() - interval '8 hours');
select test.eq('quiet hours: one summary', app.push_quiet_summary(now()), 1);
select test.eq('quiet hours: the held alerts are in it, the urgent one goes on its own',
  (select count(*) from push_outbox where subscription_id = test.id('rz_sub') and status = 'queued' and code <> 'staff_late_return_alert')
  || '/' || (select count(*) from push_outbox where subscription_id = test.id('rz_sub') and status = 'skipped' and last_error = 'in the quiet hours summary'), '2/2');
select test.ok('quiet hours: the summary lists them newest first', (select title = 'While your alerts were quiet: 2 alerts' and body like '%Car back: RZ-2; Car going out: RZ-1%'
  from push_outbox where subscription_id = test.id('rz_sub') and code = 'staff_quiet_summary'));

-- ================================================================ 7. hiring: one alert per hire, Hire from the referred stage
insert into job_applications (role_id, status, full_name, email, phone, score, work_mode, referred_role_id)
select r.id, 'referred', 'Rae Example', 'rae@rz.example.test', '+639170000771', 70, r.work_mode, (select f.id from hiring_roles f where f.slug = 'va-fleet-operations')
  from hiring_roles r where r.slug = 'va-customer-service';
create function test.rz_app() returns job_applications language sql stable as $$ select * from job_applications where email = 'rae@rz.example.test' $$;
select test.eq('Hire from the referred stage: the preview allows it', (app.door(test.id('rz_admin'), 'aal2', 'admin_read', 'hire_preview', jsonb_build_object('id', (test.rz_app()).id, 'function', 'fleet')) ->> 'can_hire'), 'true');
select test.mk_user('rz_rae', 'va', 'fleet');
select test.eq('Hire from the referred stage: hired into the role chosen in the form, no booking link email',
  (select x ->> 'function' from (select app.door(test.id('rz_admin'), 'aal2', 'admin_do', 'hire_onboard',
     jsonb_build_object('id', (test.rz_app()).id, 'user_id', test.id('rz_rae'), 'function', 'fleet', 'start_on', (app.today() + 2)::text, 'pay_cents', 40000)) x) y)
  , 'fleet');
select test.eq('Hire from the referred stage: hired, and no booking link email',
  (test.rz_app()).status || '/' || (select count(*) from app_events where code in ('applicant_invite', 'applicant_invited') and payload ->> 'email' = 'rae@rz.example.test'), 'hired/0');
select app.process_events(1000);
select test.eq('one-step Hire: no "set their function and first day" alert, one alert with the role, the start and the training',
  (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'applicant_hired' and payload ->> 'alert_title' like 'Offer accepted: Rae%')
  || '/' || (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'applicant_hired'
               and payload ->> 'alert_title' like 'Rae Example hired as Fleet, starts %, training not started' and payload ->> 'path_admin' = '/admin/academy/staff/' || test.id('rz_rae'))::text, '0/1');
-- the older flow: hired without one-step Hire, the function and first day still to set
insert into job_applications (role_id, status, full_name, email, phone, score, work_mode)
select r.id, 'interviewed', 'Old Example', 'old@rz.example.test', '+639170000772', 80, r.work_mode from hiring_roles r where r.slug = 'va-customer-service';
select test.mk_user('rz_old', 'va', 'cs');
-- (the rubric's decision trigger is held as one-step Hire holds it)
select set_config('app.hiring_decide', 'on', false);
select app.hiring_hire(test.id('rz_admin'), jsonb_build_object('id', (select id from job_applications where email = 'old@rz.example.test'), 'user_id', test.id('rz_old')));
select set_config('app.hiring_decide', '', false);
select app.process_events(1000);
select test.eq('older flow: the alert stays and links to the candidate',
  (select payload ->> 'path_admin' from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'applicant_hired' and payload ->> 'alert_title' = 'Offer accepted: Old Example'),
  '/admin/hiring/' || (select id from job_applications where email = 'old@rz.example.test'));

update program_settings s set late_chase_grace_minutes = x.g, notify_not_back_minutes = x.nb, require_staff_two_step = x.t from rz_ps x where s.id = x.id;
