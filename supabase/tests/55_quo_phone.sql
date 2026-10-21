-- 55: the Quo phone line (migration 0085). Matching a number to staff, a renter (and their booking), an owner, a lead,
-- a game claim and a chat visitor; the webhook events (texts, calls, summaries, transcripts, voicemail, duplicates,
-- another number); the missed-call rule (off by default, the text once per number per 12 hours when on, the task to the
-- person on duty or the Admins, the quiet hours); STOP and START; booking texts from the renter emails (opt-outs,
-- transactional only, the quiet hours, the STOP line once); staff reads and actions and who may use them; AI budget
-- and summaries; the cron gate; retention; the privacy policy. Fixtures start with "qp".
select test.suite('55 quo phone');

select test.mk_user('qp_admin', 'admin');
select test.mk_user('qp_cs', 'va', 'cs');
select test.mk_user('qp_sales', 'va', 'sales');
select test.mk_user('qp_fleet', 'va', 'fleet');
select test.mk_renter('qp_rita');
select test.mk_renter('qp_ron');
select test.mk_owner('qp_olga');
select test.mk_vehicle('qp_car', 'qp_olga');
update renters set mobile = '(416) 555-0101' where id = test.id('renter:qp_rita');
update renters set mobile = '416 555 0102' where id = test.id('renter:qp_ron');
update owners set phone = '+1 416-555-0103' where id = test.id('owner:qp_olga');
update users set phone = '416-555-0104' where id = test.id('qp_cs');
-- quiet hours off for the suite (section 6 tests them on their own); nobody on shift from earlier suites
update program_settings set uptime_quiet_from_hour = 0, uptime_quiet_until_hour = 0;
update chat_staff_prefs set last_seen_at = null;
select test.mk_booking('QP-1', 'qp_car', 'qp_rita', to_char((now() + interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '6 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
select test.mk_booking('QP-0', 'qp_car', 'qp_rita', '2026-01-10 10:00', '2026-01-12 10:00', 'closed');

create or replace function test.qev(p jsonb) returns jsonb language sql as $$ select app.server_phone_event(p) $$;
create or replace function test.qmsg(p_id text, p_from text, p_text text, p_type text default 'message.received') returns jsonb
language sql as $$ select app.server_phone_event(jsonb_build_object('event_id', 'ev-' || p_id, 'type', p_type, 'quo_id', p_id, 'direction', 'in',
  'their_number', p_from, 'phone_number_id', 'PNtest', 'text', p_text, 'status', 'received', 'at', now())) $$;
create or replace function test.qmissed(p_id text, p_from text) returns jsonb
language sql as $$ select app.server_phone_event(jsonb_build_object('event_id', 'ev-' || p_id, 'type', 'call.missed', 'quo_id', p_id, 'call_id', p_id,
  'direction', 'in', 'their_number', p_from, 'status', 'missed', 'missed', true, 'at', now())) $$;
create or replace function test.qthread(p_number text) returns phone_threads language sql stable as $$ select * from phone_threads where number = app.phone_e164(p_number) $$;

-- ================================================================ 1. settings and numbers
select test.eq('settings: on; missed-call text OFF by default (Quo''s own auto-reply), its task on, 12 hours, customer service; booking texts on',
  (select format('%s %s %s %s %s %s %s', phone_enabled, phone_missed_call_text_enabled, phone_missed_call_task, phone_missed_call_text_hours, phone_missed_call_queue,
                 phone_sms_booking, phone_keep_months) from (select (app.settings()).*) s), 't f t 12 cs t 12');
select test.eq('the default missed-call text, as the owner wrote it',
  (app.settings()).phone_missed_call_text, 'Sorry we missed your call. How can we help? Reply here, or book at carmacars.ca. CarmaCars');
select test.eq('numbers: written in any way, stored as E.164', app.phone_e164('(416) 555-0101') || ' ' || app.phone_e164('1-416-555-0101') || ' ' || coalesce(app.phone_e164('555-01'), 'null'),
  '+14165550101 +14165550101 null');
select test.eq('our number comes from Site settings (never written in the migration)', app.phone_our_number(), app.phone_e164((select phone from site_settings limit 1)));
select test.throws('a template with a long dash is refused', format($$update program_settings set phone_sms_offer_sent_text = 'Your offer %s CarmaCars'$$, chr(8212)), 'phone_texts');
select test.throws('a template without the brand is refused', $$update program_settings set phone_missed_call_text = 'Sorry we missed you'$$, 'phone_texts');
select test.eq('rendering fills and drops placeholders', app.phone_render('Hi {first_name}, {booking} paid {amount}. CarmaCars', '{"first_name": "Rita", "booking": "QP-1"}'),
  'Hi Rita, QP-1 paid. CarmaCars');

-- ================================================================ 2. matching
select test.eq('a renter by their mobile, with their current booking (the coming one, not the closed one)',
  (select format('%s %s %s', m ->> 'kind', m ->> 'renter_id' = test.id('renter:qp_rita')::text, m ->> 'booking_id' = test.id('booking:QP-1')::text) from (select app.phone_match('416-555-0101') m) x), 'renter t t');
select test.eq('an owner by their phone', app.phone_match('4165550103') ->> 'kind', 'owner');
select test.eq('staff come first, with their name', (select format('%s %s', m ->> 'kind', m ->> 'name') from (select app.phone_match('+14165550104') m) x), 'staff Qp Cs');
insert into leads (id, kind, name, phone) values (test.id('lead:qp'), 'contact', 'Lena Lead', '416-555-0105');
select test.eq('a lead by the phone on the lead', (select format('%s %s', m ->> 'kind', m ->> 'name') from (select app.phone_match('4165550105') m) x), 'lead Lena Lead');
insert into chat_conversations (id, token, number, status, name, phone, visitor_id)
values (test.id('chat:qp'), md5('qp-chat') || md5('qp-chat2'), 'LC-QP1', 'closed', 'Chad Chat', '416-555-0106', test.id('visitor:qp'));
insert into visitor_sessions (id, visitor_id, consent, current_path, page_views) values (test.id('session:qp'), test.id('visitor:qp'), 'analytics', '/cars', 3);
select test.eq('a chat visitor who gave this phone: a lead side match, with their browser for Live visitors',
  (select format('%s %s %s', m ->> 'kind', m ->> 'chat_id' = test.id('chat:qp')::text, m ->> 'visitor_id' = test.id('visitor:qp')::text) from (select app.phone_match('4165550106') m) x), 'lead t t');
select test.eq('an unknown number', app.phone_match('+14165550199') ->> 'kind', 'unknown');

-- ================================================================ 3. texts in
select test.qmsg('AC-qp-1', '+14165550101', 'Hi, can I pick up an hour early?');
select test.eq('a text in: one thread for the number, matched to the renter and their booking, one unread',
  (select format('%s %s %s %s', t.match_kind, t.renter_id = test.id('renter:qp_rita'), t.booking_id = test.id('booking:QP-1'), t.unread) from test.qthread('+14165550101') t), 'renter t t 1');
select test.eq('the text is kept with the renter and the booking',
  (select format('%s %s %s', a.body, a.renter_id = test.id('renter:qp_rita'), a.booking_id = test.id('booking:QP-1')) from phone_activity a where quo_id = 'AC-qp-1'),
  'Hi, can I pick up an hour early? t t');
select test.eq('the same delivery twice is applied once', (test.qmsg('AC-qp-1', '+14165550101', 'Hi, can I pick up an hour early?') ->> 'duplicate')
  || ' ' || (select count(*) from phone_activity where quo_id = 'AC-qp-1') || ' ' || (select unread from test.qthread('+14165550101')), 'true 1 1');
update quo_config set phone_number_id = 'PNcarmacars';
select test.eq('another Quo number (not the CarmaCars inbox) is ignored', test.qmsg('AC-qp-x', '+14165550101', 'x') ->> 'ignored', 'another number');
update quo_config set phone_number_id = null;
select test.eq('a delivery without an outside number is ignored', (test.qev('{"event_id": "ev-none", "type": "message.received", "quo_id": "AC-none", "text": "x"}') ->> 'ignored'), 'no outside number');
update program_settings set phone_record_texts = false;
select test.eq('texts not recorded when switched off', test.qmsg('AC-qp-off', '+14165550101', 'x') ->> 'ignored', 'not recorded');
update program_settings set phone_record_texts = true;

-- ================================================================ 4. the missed call (task on, text off by default)
-- nobody holds Finance? qp_cs holds customer service: the task goes to the customer service queue; nobody on shift: unassigned
select test.qmissed('AC-qp-m1', '+14165550199');
select test.eq('a missed call from an unknown number: a task to customer service, no text (the text-back is off by default)',
  (select format('%s %s %s', t.queue, t.assigned_to is null, t.priority) from tasks t where t.dedupe_key = 'phone_missed:' || (select id from test.qthread('+14165550199'))) || ' '
  || (select count(*) from phone_outbox where to_number = '+14165550199'), 'cs t high 0');
select test.eq('the call is marked missed and shows in Unknown callers', (select format('%s %s', a.missed, t.match_kind) from phone_activity a join phone_threads t on t.id = a.thread_id where a.quo_id = 'AC-qp-m1'), 't unknown');
-- the person on duty: customer service with the inbox open
insert into chat_staff_prefs (user_id, last_seen_at) values (test.id('qp_cs'), now()) on conflict (user_id) do update set last_seen_at = now();
update tasks set status = 'done', completed_at = now() where task_type = 'phone_missed_call';
-- the text-back switched on
update program_settings set phone_missed_call_text_enabled = true;
select test.eq('switched on: the text is sent at once from the webhook answer, with the template',
  (select x -> 'send' -> 0 ->> 'body' from (select test.qmissed('AC-qp-m2', '+14165550101') x) y), (app.settings()).phone_missed_call_text);
select test.eq('the task goes to the person on duty, with the renter and booking',
  (select format('%s %s %s', t.assigned_to = test.id('qp_cs'), t.renter_id = test.id('renter:qp_rita'), t.booking_id = test.id('booking:QP-1')) from tasks t
    where t.task_type = 'phone_missed_call' and t.status = 'open'), 't t t');
select test.eq('a second missed call within 12 hours: no second text, still one open task',
  jsonb_array_length(test.qmissed('AC-qp-m3', '+14165550101') -> 'send') || ' ' || (select count(*) from tasks where task_type = 'phone_missed_call' and status = 'open'), '0 1');
update phone_threads set last_missed_text_at = now() - interval '13 hours' where number = '+14165550101';
select test.eq('after 12 hours the next missed call texts again', jsonb_array_length(test.qmissed('AC-qp-m4', '+14165550101') -> 'send'), 1);
select test.eq('the same call reported twice (call.completed after call.missed) is one missed call',
  jsonb_array_length(test.qev(jsonb_build_object('event_id', 'ev-m4c', 'type', 'call.completed', 'quo_id', 'AC-qp-m4', 'call_id', 'AC-qp-m4', 'direction', 'in',
    'their_number', '+14165550101', 'status', 'missed', 'missed', true)) -> 'send'), 0);
select test.eq('a staff member calling in gets no text and no task',
  jsonb_array_length(test.qmissed('AC-qp-m5', '+14165550104') -> 'send') || ' ' || (select count(*) from tasks where task_type = 'phone_missed_call' and renter_id is null and title like '%Qp Cs%'), '0 0');
-- the Admins when nobody holds the function
update program_settings set phone_missed_call_queue = 'finance';
select test.qmissed('AC-qp-m6', '+14165550188');
select test.eq('nobody holds the function (finance): the Admins get the task', (select queue from tasks where dedupe_key = 'phone_missed:' || (select id from test.qthread('+14165550188'))), 'admin');
update program_settings set phone_missed_call_queue = 'cs';
-- the sent text is recorded
select app.server_phone_sent(jsonb_build_object('id', (select id from phone_outbox where dedupe_key = 'missed:' || (select id from phone_activity where quo_id = 'AC-qp-m4')), 'ok', true, 'quo_id', 'AC-qp-out-1'));
select test.eq('a sent text: outbox sent, an outgoing text on the thread', (select o.status from phone_outbox o where o.quo_message_id = 'AC-qp-out-1') || ' '
  || (select format('%s %s', direction, sms_kind) from phone_activity where quo_id = 'AC-qp-out-1'), 'sent out missed_call');
select test.qev(jsonb_build_object('event_id', 'ev-deliv', 'type', 'message.delivered', 'quo_id', 'AC-qp-out-1', 'direction', 'out', 'their_number', '+14165550101', 'status', 'delivered'));
select test.eq('Quo''s delivered event updates the same text', (select format('%s %s', status, count(*) over ()) from phone_activity where quo_id = 'AC-qp-out-1'), 'delivered 1');
update program_settings set phone_missed_call_text_enabled = false;

-- ================================================================ 5. calls: summary, transcript, voicemail; no recording
select test.qev(jsonb_build_object('event_id', 'ev-c1', 'type', 'call.completed', 'quo_id', 'AC-qp-c1', 'call_id', 'AC-qp-c1', 'direction', 'in', 'their_number', '+14165550103',
  'status', 'answered', 'answered_at', now() - interval '2 minutes', 'completed_at', now(), 'duration', 95));
select test.eq('an answered call from the owner: kept with the owner, not missed, 95 seconds, no transcript or recording (the line does not record)',
  (select format('%s %s %s %s %s', a.owner_id = test.id('owner:qp_olga'), a.missed, a.duration_seconds, a.transcript is null, jsonb_array_length(a.recordings)) from phone_activity a where quo_id = 'AC-qp-c1'),
  't f 95 t 0');
select test.eq('the owner''s timeline', (select jsonb_array_length(x -> 'items') from (select app.phone_timeline(test.id('qp_admin'), jsonb_build_object('owner_id', test.id('owner:qp_olga'))) x) y), 1);
select test.qev(jsonb_build_object('event_id', 'ev-t1', 'type', 'call.transcript.completed', 'quo_id', 'AC-qp-c1', 'call_id', 'AC-qp-c1', 'their_number', '+14165550103',
  'transcript', '[{"who": "us", "text": "CarmaCars, how can I help?"}, {"who": "them", "text": "My statement looks off."}]'::jsonb));
select test.eq('a transcript without Quo''s summary: our one-liner is due in a few minutes',
  (select summary_due_at between now() + interval '4 minutes' and now() + interval '6 minutes' from phone_activity where quo_id = 'AC-qp-c1'), true);
update phone_activity set summary_due_at = now() - interval '1 second' where quo_id = 'AC-qp-c1';
select test.eq('the job lists it with its transcript, and the cron gate says phone work is due',
  (select (x -> 'summaries' -> 0 ->> 'id') = (select id::text from phone_activity where quo_id = 'AC-qp-c1') from (select app.server_phone_due() x) y)::text || ' ' || (app.server_jobs_due() ->> 'phone'), 'true true');
select app.server_phone_summary(jsonb_build_object('id', (select id from phone_activity where quo_id = 'AC-qp-c1'), 'summary', format('Owner asked about the statement %s will check', chr(8212)), 'ok', true, 'neurons', 60));
select test.eq('our summary is kept (long dashes removed) and counted in the AI budget',
  (select ai_summary from phone_activity where quo_id = 'AC-qp-c1') || ' / ' || (app.phone_ai_budget() ->> 'neurons'), 'Owner asked about the statement , will check / 60');
select test.qev(jsonb_build_object('event_id', 'ev-s1', 'type', 'call.summary.completed', 'quo_id', 'AC-qp-c1', 'call_id', 'AC-qp-c1', 'their_number', '+14165550103',
  'summary', '["Owner asked about the October statement."]'::jsonb, 'next_steps', '["Send the corrected statement."]'::jsonb));
select test.eq('Quo''s summary comes first on the timeline', (select x -> 'items' -> 0 ->> 'summary' || ' / ' || (x -> 'items' -> 0 ->> 'summary_by') from (select app.phone_timeline(test.id('qp_admin'), jsonb_build_object('owner_id', test.id('owner:qp_olga'))) x) y),
  'Owner asked about the October statement. / quo');
select test.qev(jsonb_build_object('event_id', 'ev-v1', 'type', 'call.voicemail.completed', 'quo_id', 'AC-qp-m1', 'call_id', 'AC-qp-m1', 'their_number', '+14165550199',
  'voicemail_text', 'Call me back about a weekend rental', 'voicemail_url', 'https://recordings.example.com/v.mp3'));
select test.eq('a voicemail lands on its missed call', (select voicemail_text from phone_activity where quo_id = 'AC-qp-m1'), 'Call me back about a weekend rental');

-- ================================================================ 6. booking texts
create or replace function test.qmail(p_code text, p_key text, p_category text default 'transactional') returns void language sql as $$
  insert into notification_outbox (code, category, priority, audience, booking_id, renter_id, payload, dedupe_key)
  values (p_code, p_category, 2, 'renter', test.id('booking:QP-1'), test.id('renter:qp_rita'), '{"first_name": "Rita", "amount": "$113.00"}', p_key) $$;
delete from phone_outbox where kind = 'booking';
select test.qmail('renter_offer_ready', 'qp-mail-1');
select test.eq('an offer email: a text to the renter''s mobile, with the booking link and the STOP line on the first one',
  (select format('%s|%s|%s', to_number, status, body) from phone_outbox where dedupe_key = 'sms:qp-mail-1'),
  format('+14165550101|queued|Hi Rita, your CarmaCars offer QP-1 for the %s is ready. Review and pay: %s/account/bookings/QP-1 Reply STOP to opt out.',
         app.vehicle_name(test.id('vehicle:qp_car')), rtrim((select site_url from site_settings limit 1), '/')));
select test.qmail('renter_payment_receipt', 'qp-mail-2');
select test.eq('the next text has no STOP line; the amount comes from the email', (select body from phone_outbox where dedupe_key = 'sms:qp-mail-2'),
  'Hi Rita, we received your payment of $113.00 for booking QP-1. Thank you. CarmaCars');
select test.qmail('renter_review_request', 'qp-mail-3');
select test.eq('an email with no booking text makes none', (select count(*) from phone_outbox where dedupe_key = 'sms:qp-mail-3'), 0::bigint);
select test.qmail('renter_offer_ready', 'qp-mail-4', 'marketing');
select test.eq('a marketing email never makes a text (CASL)', (select count(*) from phone_outbox where dedupe_key = 'sms:qp-mail-4'), 0::bigint);
update program_settings set phone_sms_offer_sent = false;
select test.qmail('renter_offer_ready', 'qp-mail-5');
select test.eq('a moment switched off makes no text', (select count(*) from phone_outbox where dedupe_key = 'sms:qp-mail-5'), 0::bigint);
update program_settings set phone_sms_offer_sent = true;
update renters set sms_opt_out_at = now() where id = test.id('renter:qp_rita');
select test.qmail('renter_booking_reminder', 'qp-mail-6');
select test.eq('a renter who asked for no texts: skipped, with the reason', (select status || ': ' || status_reason from phone_outbox where dedupe_key = 'sms:qp-mail-6'), 'skipped: The renter asked for no texts');
update renters set sms_opt_out_at = null where id = test.id('renter:qp_rita');
update renters set mobile = null where id = test.id('renter:qp_ron');
select test.eq('a renter without a mobile gets no text', (select count(*) from phone_outbox where renter_id = test.id('renter:qp_ron')), 0::bigint);
-- the quiet hours: 23:00 to 7:00
update program_settings set uptime_quiet_from_hour = 23, uptime_quiet_until_hour = 7;
select test.eq('the quiet hours end at 7:00 the next morning (from 23:30) or the same morning (from 2:00)',
  to_char(app.phone_quiet_end('2026-10-21 23:30'::timestamp at time zone 'America/Toronto') at time zone 'America/Toronto', 'DD HH24:MI') || ' '
  || to_char(app.phone_quiet_end('2026-10-22 02:00'::timestamp at time zone 'America/Toronto') at time zone 'America/Toronto', 'DD HH24:MI') || ' '
  || to_char(app.phone_quiet_end('2026-10-22 12:00'::timestamp at time zone 'America/Toronto') at time zone 'America/Toronto', 'DD HH24:MI'), '22 07:00 22 07:00 22 12:00');
update program_settings set uptime_quiet_from_hour = 0, uptime_quiet_until_hour = 0;
-- the job claims what is due
select test.eq('the job claims the due texts (status sending)', (select count(*) from jsonb_array_elements(app.server_phone_due() -> 'texts') x where x ->> 'id' in
  (select id::text from phone_outbox where dedupe_key in ('sms:qp-mail-1', 'sms:qp-mail-2'))), 2::bigint);
select app.server_phone_sent(jsonb_build_object('id', (select id from phone_outbox where dedupe_key = 'sms:qp-mail-1'), 'ok', false, 'error', 'Quo 429'));
select test.eq('a send that failed for now is tried again later', (select format('%s %s', status, send_after > now()) from phone_outbox where dedupe_key = 'sms:qp-mail-1'), 'queued t');
select app.server_phone_sent(jsonb_build_object('id', (select id from phone_outbox where dedupe_key = 'sms:qp-mail-2'), 'ok', false, 'error', 'Quo 400: A2P Registration Not Approved', 'permanent', true));
select test.eq('a refusal that will not change fails at once', (select status from phone_outbox where dedupe_key = 'sms:qp-mail-2'), 'failed');

-- ================================================================ 7. STOP and START
select test.qmsg('AC-qp-stop', '+14165550101', ' stop ');
select test.eq('STOP: the number and the renter opt out; queued texts are skipped',
  (select format('%s %s', opted_out_at is not null, opt_out_source) from test.qthread('+14165550101')) || ' '
  || (select (sms_opt_out_at is not null)::text from renters where id = test.id('renter:qp_rita')) || ' ' || (select status from phone_outbox where dedupe_key = 'sms:qp-mail-1'), 't stop true skipped');
select test.throws('staff cannot text a number that opted out', format($$select app.phone_staff_do(%L, 'phone_reply', jsonb_build_object('id', %L, 'body', 'Hello'))$$,
  test.id('qp_cs'), (select id from test.qthread('+14165550101'))), 'opted out');
select test.qmsg('AC-qp-start', '+14165550101', 'START');
select test.eq('START allows texts again', (select (opted_out_at is null)::text from test.qthread('+14165550101')) || ' ' || (select (sms_opt_out_at is null)::text from renters where id = test.id('renter:qp_rita')), 'true true');
select test.qev(jsonb_build_object('event_id', 'ev-landline', 'type', 'message.failed', 'quo_id', 'AC-qp-fail', 'direction', 'out', 'their_number', '+14165550188', 'status', 'failed', 'error_code', '30006'));
select test.eq('the carrier says landline or unreachable (30006): no more texts to it', (select opt_out_source from test.qthread('+14165550188')), 'carrier');

-- ================================================================ 8. staff: reads, reply, link, lead, permissions
select test.eq('the inbox through the door (customer service): threads and Unknown callers',
  (select format('%s %s', jsonb_array_length(x -> 'threads') > 0, (x ->> 'unknown')::integer >= 1) from (select app.door(test.id('qp_cs'), '', 'va_read', 'phone_inbox', '{}') x) y), 't t');
select test.eq('the Unknown callers view lists only unmatched numbers',
  (select bool_and(e ->> 'match_kind' = 'unknown') from jsonb_array_elements(app.phone_inbox(test.id('qp_sales'), '{"view": "unknown"}') -> 'threads') e), true);
select test.throws('Fleet cannot read the phone inbox', format($$select app.door(%L, '', 'va_read', 'phone_inbox', '{}')$$, test.id('qp_fleet')), 'customer service and Sales');
select test.throws('Fleet cannot read a booking''s calls', format($$select app.phone_timeline(%L, jsonb_build_object('booking_id', %L))$$, test.id('qp_fleet'), test.id('booking:QP-1')), 'customer service and Sales');
select test.throws('a renter cannot read it', format($$select app.phone_inbox(%L, '{}')$$, test.id('qp_rita')), 'customer service and Sales');
select test.eq('privileges: no browser role may call the server functions or the staff functions directly',
  has_function_privilege('anon', 'public.server_phone_event(jsonb)', 'execute')::text || has_function_privilege('authenticated', 'public.server_phone_sent(jsonb)', 'execute')::text
  || has_function_privilege('authenticated', 'app.phone_staff_do(uuid, text, jsonb)', 'execute')::text || has_function_privilege('service_role', 'public.server_phone_event(jsonb)', 'execute')::text,
  'falsefalsefalsetrue');
select test.eq('row-level security on every new table', (select count(*) from pg_class where relname in ('phone_threads', 'phone_activity', 'phone_outbox', 'phone_webhook_log', 'quo_config') and relrowsecurity), 5::bigint);
-- a reply: queued as sending, returned for the server to send from our number
select test.eq('a reply: the text to send now, from the CarmaCars number',
  (select format('%s %s %s', x -> 'send' ->> 'to', x -> 'send' ->> 'body', x ->> 'from' = app.phone_our_number()) from (select app.door(test.id('qp_sales'), '', 'va_do', 'phone_reply',
     jsonb_build_object('id', (select id from test.qthread('+14165550101')), 'body', 'Yes, 9:00 works. CarmaCars')) x) y), '+14165550101 Yes, 9:00 works. CarmaCars t');
select test.throws('an empty reply is refused', format($$select app.phone_staff_do(%L, 'phone_reply', jsonb_build_object('id', %L, 'body', '  '))$$, test.id('qp_cs'), (select id from test.qthread('+14165550101'))), 'Write the text');
select app.phone_staff_do(test.id('qp_cs'), 'phone_read', jsonb_build_object('id', id)) from test.qthread('+14165550101');
select test.eq('read: unread back to 0', (select unread from test.qthread('+14165550101')), 0);
-- an unknown caller: create a lead, or link to a renter
select app.phone_staff_do(test.id('qp_cs'), 'phone_create_lead', jsonb_build_object('id', (select id from test.qthread('+14165550199')), 'name', 'Walt Weekend'));
select test.eq('Create lead: a phone lead with the number, the thread and its calls follow it',
  (select format('%s %s %s %s', l.kind, l.phone, t.match_kind, (select count(*) from phone_activity a where a.thread_id = t.id and a.lead_id = l.id) > 0)
     from test.qthread('+14165550199') t join leads l on l.id = t.lead_id), 'phone +14165550199 lead t');
select app.phone_staff_do(test.id('qp_cs'), 'phone_link', jsonb_build_object('id', (select id from test.qthread('+14165550188')), 'renter_id', test.id('renter:qp_ron')));
select test.eq('Link to a renter: the thread, its calls and the audit log',
  (select format('%s %s %s', t.match_kind, t.manual, (select count(*) from phone_activity a where a.thread_id = t.id and a.renter_id = test.id('renter:qp_ron')) > 0) from test.qthread('+14165550188') t)
  || ' ' || (select count(*) from audit_log where action = 'phone_link' and entity_id = (select id::text from test.qthread('+14165550188'))), 'renter t t 1');
select test.eq('the renter''s timeline and the renter search', (select jsonb_array_length(app.phone_timeline(test.id('qp_admin'), jsonb_build_object('renter_id', test.id('renter:qp_ron'))) -> 'items') > 0)::text
  || ' ' || (app.phone_renter_search(test.id('qp_cs'), '{"q": "Qp Ron"}') -> 0 ->> 'id' = test.id('renter:qp_ron')::text), 'true true');
select test.eq('the booking''s timeline holds the renter''s calls and texts', (select jsonb_array_length(app.phone_timeline(test.id('qp_cs'), jsonb_build_object('booking_id', test.id('booking:QP-1'))) -> 'items') >= 3), true);
select test.qmsg('AC-qp-chat', '+14165550106', 'hello');
select test.eq('the thread of a chat visitor shows their visit', (select (x -> 'visit' ->> 'id') = test.id('session:qp')::text from (
  select app.phone_thread(test.id('qp_cs'), jsonb_build_object('id', (select id from test.qthread('+14165550106')))) x) y), true);
select test.eq('the visitor is named on Live visitors', (select known_name from visitor_sessions where id = test.id('session:qp')), 'Chad Chat');
select test.eq('a draft: the conversation and the booking for the model, within the budget',
  (select format('%s %s', jsonb_array_length(x -> 'messages') > 0, x -> 'ai' ->> 'ok') from (select app.phone_staff_do(test.id('qp_cs'), 'phone_draft', jsonb_build_object('id', (select id from test.qthread('+14165550101')))) x) y), 't true');
update program_settings set phone_ai_daily_neurons = 10;
select test.eq('the AI allowance used: no more drafts or summaries today', app.phone_ai_budget() ->> 'ok', 'false');
update program_settings set phone_ai_daily_neurons = 1500;
select app.phone_staff_do(test.id('qp_cs'), 'phone_opt_out', jsonb_build_object('id', id, 'on', true)) from test.qthread('+14165550106');
select test.eq('opt out by staff', (select opt_out_source from test.qthread('+14165550106')), 'staff');

-- ================================================================ 9. retention and the privacy policy
insert into phone_threads (number, last_at) values ('+14165550177', now() - interval '13 months');
insert into phone_activity (thread_id, kind, direction, body, started_at) select id, 'text', 'in', 'old', now() - interval '13 months' from phone_threads where number = '+14165550177';
update phone_activity set started_at = now() - interval '13 months' where quo_id = 'AC-qp-1';
select app.job_phone_housekeeping();
select test.eq('after 12 months: an unknown number''s texts and thread are deleted; a renter''s text is kept with the rental records',
  (select count(*) from phone_threads where number = '+14165550177') || ' ' || (select count(*) from phone_activity where quo_id = 'AC-qp-1'), '0 1');
select test.ok('the privacy policy names calls and texts, their retention, and section 10',
  (select body like '%Calls and texts with our phone number:%' and body like '%| Calls and texts with our phone number, with their recordings%'
          and body like '%Calls and texts to and from our phone number go through our business phone provider%' from site_content_blocks where block_key = 'legal.privacy')
  or not exists (select 1 from site_content_blocks where block_key = 'legal.privacy' and body like '%If you give an email address in the chat%'));

update program_settings set uptime_quiet_from_hour = 23, uptime_quiet_until_hour = 7;
