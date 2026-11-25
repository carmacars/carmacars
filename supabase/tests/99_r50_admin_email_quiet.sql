-- 99: the Admin's inbox goes quiet (migrations 5051 and 5052, docs/changes/2026-11-25-r50-admin-email-quiet.md): only what
-- needs an Admin now emails at once; everything else is one daily digest at 7:00 (counted, grouped by type, links,
-- skipped when empty); an Admin's own email switch is respected; staff are unchanged; a booked live interview and an
-- urgent To do email the Admins; website crash To do's are one per error, close after 24 quiet hours, and the old ones
-- fold into one per error. Fixtures "aeq_".
select test.suite('99 r50 admin email quiet: urgent now, the rest in one daily digest, crash To do''s grouped');
select test.mk_user('aeq_admin', 'admin');
select test.mk_user('aeq_cs', 'va', 'cs');
select test.mk_user('aeq_sales', 'va', 'sales');
select test.mk_user('aeq_admin_off', 'admin');
select test.mk_user('aeq_admin_nosys', 'admin');
update users set staff_email_digest = 'off' where id = test.id('aeq_admin_off');
insert into notify_prefs (subject_kind, subject_id, type, push, email, sms) values ('user', test.id('aeq_admin_nosys'), 'staff_system', true, false, true);
select test.mk_owner('aeq_owner');
select test.mk_vehicle('AEQV', 'aeq_owner');
select test.mk_renter('aeq_renter');
create function test.aeq_t(p interval) returns text language sql stable as $$ select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
select test.mk_booking('AEQ-1', 'AEQV', 'aeq_renter', test.aeq_t(interval '3 days'), test.aeq_t(interval '6 days'), 'confirmed');
select test.mk_booking('AEQ-2', 'AEQV', 'aeq_renter', test.aeq_t(interval '20 days'), test.aeq_t(interval '22 days'), 'requested');

create function test.aeq_mail(p_user text, p_code text, p_key text, p_booking uuid default null) returns text language sql as $$
  insert into notification_outbox (code, category, priority, audience, recipient_user_id, booking_id, to_address, to_name, payload, dedupe_key, status, send_after)
  values (p_code, 'transactional', 3, 'staff_admin', test.id(p_user), p_booking, p_user || '@example.test', 'Aeq',
          jsonb_build_object('booking_number', 'AEQ-1', 'amount', '$10.00', 'vehicle_name', 'Aeq car', 'review_rating', '5', 'refund_amount', '$5.00'),
          'aeq-' || p_key, 'queued', now())
  returning status || ':' || coalesce(status_reason, '') $$;

-- ================================================================ the defaults
select test.eq('a new Admin starts on the daily digest', (select staff_email_digest from users where id = test.id('aeq_admin')), 'daily');
select test.eq('staff keep the hourly default', (select staff_email_digest from users where id = test.id('aeq_cs')), 'hourly');

-- ================================================================ what needs an Admin now
select test.ok('a card dispute', app.admin_email_now('staff_dispute_opened', '{}', null));
select test.ok('a failed payment on a confirmed booking', app.admin_email_now('staff_payment_failed', '{}', test.id('booking:AEQ-1')));
select test.ok('not a failed payment on a request', not app.admin_email_now('staff_payment_failed', '{}', test.id('booking:AEQ-2')));
select test.ok('a request to book no salesperson holds', app.admin_email_now('staff_request_waiting', jsonb_build_object('booking_id', test.id('booking:AEQ-2')), null));
update bookings set sales_claim_by = test.id('aeq_sales'), sales_claim_at = now() where id = test.id('booking:AEQ-2');
select test.ok('not once a salesperson holds it', not app.admin_email_now('staff_request_waiting', '{}', test.id('booking:AEQ-2')));
select test.ok('a security alert (the site down)', app.admin_email_now('staff_site_alert', '{}', null));
select test.ok('not a new review', not app.admin_email_now('staff_review_received', '{}', null));

-- ================================================================ the gate
select test.eq('a dispute goes to the Admin at once', test.aeq_mail('aeq_admin', 'staff_dispute_opened', 'd1'), 'queued:urgent');
select test.eq('a failed payment on a confirmed booking goes at once', test.aeq_mail('aeq_admin', 'staff_payment_failed', 'p1', test.id('booking:AEQ-1')), 'queued:urgent');
select test.eq('a new review waits for the daily digest', test.aeq_mail('aeq_admin', 'staff_review_received', 'r1'), 'skipped:in the Admin daily digest');
select test.eq('so does a second one', test.aeq_mail('aeq_admin', 'staff_review_received', 'r2'), 'skipped:in the Admin daily digest');
select test.eq('a refund issued too', test.aeq_mail('aeq_admin', 'staff_refund_issued', 'f1'), 'skipped:in the Admin daily digest');
select test.eq('the morning digest of the Admins folds in too', test.aeq_mail('aeq_admin', 'staff_digest_morning_admin', 'm1'), 'skipped:in the Admin daily digest');
select test.eq('staff are unchanged: their alert goes into their own digest', test.aeq_mail('aeq_cs', 'staff_review_received', 'c1'), 'skipped:in the staff email digest');
select test.eq('the Admin''s lines wait', (select count(*) from staff_email_digest_items where user_id = test.id('aeq_admin') and digested_at is null), 4::bigint);

-- an Admin who switches a type's email on gets each one on its own
select app.notify_prefs_save('user', test.id('aeq_admin'), '{"type": "staff_customers", "channel": "email", "on": true}'::jsonb, test.id('aeq_admin'));
select test.ok('the switch is recorded as a choice', (select email_set_at is not null from notify_prefs where subject_id = test.id('aeq_admin') and type = 'staff_customers'));
select test.eq('then a new review comes on its own', test.aeq_mail('aeq_admin', 'staff_review_received', 'r3'), 'queued:chosen');
select test.ok('the page shows it on', exists (select 1 from jsonb_path_query(app.notify_prefs_state('user', test.id('aeq_admin'), 'admin'), '$.groups[*].types[*] ? (@.code == "staff_customers" && @.email == true)')));
select test.ok('the page shows another type off (in the digest)', exists (select 1 from jsonb_path_query(app.notify_prefs_state('user', test.id('aeq_admin'), 'admin'), '$.groups[*].types[*] ? (@.code == "staff_money" && @.email == false)')));
select test.ok('the Admin page says the rules', app.notify_prefs_state('user', test.id('aeq_admin'), 'admin') ? 'admin_email');
select app.notify_prefs_save('user', test.id('aeq_admin'), '{"type": "staff_customers", "channel": "email", "on": false}'::jsonb, test.id('aeq_admin'));
select test.eq('switched off again: back to the digest', test.aeq_mail('aeq_admin', 'staff_review_received', 'r4'), 'skipped:in the Admin daily digest');
-- a type switched off before this release stays off: no email, no digest line
insert into notify_prefs (subject_kind, subject_id, type, push, email, sms) values ('user', test.id('aeq_admin'), 'staff_money', true, false, true);
select test.eq('an email the Admin turned off stays off', test.aeq_mail('aeq_admin', 'staff_refund_issued', 'f2'), 'suppressed:not sent: turned off in notification preferences');

-- ================================================================ the daily digest
create temp table aeq_seven as select ((app.today() + 1)::timestamp + time '07:05') at time zone 'America/Toronto' as at7,
                                      ((app.today() + 1)::timestamp + time '06:30') at time zone 'America/Toronto' as at6;
select app.admin_email_digests((select at6 from aeq_seven));
select test.eq('before 7:00: nothing', (select count(*) from notification_outbox where code = 'staff_digest_hourly' and recipient_user_id = test.id('aeq_admin') and coalesce(status_reason, '') <> 'urgent'), 0::bigint);
select app.admin_email_digests((select at7 from aeq_seven));
create temp table aeq_d as select payload from notification_outbox where code = 'staff_digest_hourly' and recipient_user_id = test.id('aeq_admin') and coalesce(status_reason, '') <> 'urgent';
select test.eq('at 7:00: one digest', (select count(*) from aeq_d), 1::bigint);
select test.eq('it counts every line', (select payload ->> 'digest_count' from aeq_d), '5');
select test.ok('grouped by type, with the counts', (select payload ->> 'digest_summary' from aeq_d) like '5 alerts by type: %Customers and reviews 3%');
select test.ok('one line per kind, with how many more', (select payload -> 'items' from aeq_d)::text like '%more like it%');
select test.ok('each line has its link', not exists (select 1 from aeq_d, jsonb_array_elements(payload -> 'items') i where coalesce(i ->> 'url', '') = '' and i ->> 'line' like 'New review%'));
select test.eq('one line per kind', (select jsonb_array_length(payload -> 'items') from aeq_d), 3);
select test.eq('the next is tomorrow', (select payload ->> 'digest_next' from aeq_d), 'tomorrow 7:00 am');
select test.eq('the lines are marked sent', (select count(*) from staff_email_digest_items where user_id = test.id('aeq_admin') and digested_at is null), 0::bigint);
select test.eq('empty: skipped', app.admin_email_digests((select at7 from aeq_seven) + interval '1 day'), 0);

-- at most 3 at once an hour per Admin (two went above); the rest wait for the digest
select test.eq('a third urgent one in the hour goes at once', test.aeq_mail('aeq_admin', 'staff_dispute_opened', 'd2'), 'queued:urgent');
select test.eq('a fourth waits for the digest', test.aeq_mail('aeq_admin', 'staff_dispute_opened', 'd3'), 'skipped:in the Admin daily digest');

-- ================================================================ needs you now, with no email of its own
select app.raise_task(p_type => 'aeq_check', p_title => 'Aeq urgent thing', p_queue => 'admin', p_priority => 'urgent', p_dedupe => 'aeq_urgent');
select test.ok('an urgent To do emails the Admins at once', exists (select 1 from notification_outbox o where o.recipient_user_id = test.id('aeq_admin')
  and o.dedupe_key like 'admin_now|task:%' and o.status = 'queued' and o.status_reason = 'urgent' and o.payload ->> 'digest_summary' = 'Needs you now: Urgent To do: Aeq urgent thing'));
select app.raise_task(p_type => 'aeq_check', p_title => 'Aeq normal thing', p_queue => 'admin', p_priority => 'normal', p_dedupe => 'aeq_normal');
select test.eq('with no "next digest" time', (select o.payload ->> 'digest_next' from notification_outbox o where o.recipient_user_id = test.id('aeq_admin') and o.dedupe_key like 'admin_now|task:%' limit 1), '');
select test.ok('not to an Admin whose alert emails are off', not exists (select 1 from notification_outbox o where o.recipient_user_id = test.id('aeq_admin_off') and o.dedupe_key like 'admin_now|%'));
select test.ok('not to an Admin who switched that kind''s email off', not exists (select 1 from notification_outbox o where o.recipient_user_id = test.id('aeq_admin_nosys') and o.dedupe_key like 'admin_now|task:%'));
select test.ok('a normal To do does not', not exists (select 1 from notification_outbox o where o.recipient_user_id = test.id('aeq_admin') and o.payload ->> 'digest_summary' like '%Aeq normal thing%'));
update tasks set priority = 'urgent' where dedupe_key = 'aeq_normal' and status = 'open';
select test.ok('raised to urgent: it emails', exists (select 1 from notification_outbox o where o.recipient_user_id = test.id('aeq_admin') and o.payload ->> 'digest_summary' like '%Aeq normal thing%'));
select app.staff_alert('live_call_booked', 'hiring_alert', test.id('aeq_app'), 'booked:1', 'Live call booked: Aeq Applicant, Thu 2:00 pm', 'Driver', '{"path_admin": "/admin/hiring"}');
select test.ok('a booked live interview emails the Admins', exists (select 1 from notification_outbox o where o.recipient_user_id = test.id('aeq_admin')
  and o.dedupe_key like 'admin_now|live_call_booked:%' and o.status_reason = 'urgent' and o.payload::text like '%/admin/hiring%'));
select test.ok('staff get no such email', not exists (select 1 from notification_outbox o where o.recipient_user_id = test.id('aeq_cs') and o.dedupe_key like 'admin_now|%'));

-- ================================================================ 5052: crash To do's, one per error
create temp table aeq_msg as select 'Minified React error #441; visit https://react.dev/errors/441?args[]=aeq for the full message' as m441,
                                    'Minified React error #418; visit https://react.dev/errors/418 for the full message' as m418;
select test.eq('the signature drops the address and the page, keeps the error code',
  app.client_error_signature('Error at /cars/aeq-123 line 42: Minified React error #441; visit https://react.dev/errors/441'), 'Error at <path> line N: Minified React error #441; visit <url>');
select public.server_client_error(jsonb_build_object('message', (select m441 from aeq_msg), 'path', '/cars/aeq-one', 'ua', 'Mozilla/5.0 (iPhone) Version/26 Safari/604.1', 'visitor', 'aeqvisitor1'));
select public.server_client_error(jsonb_build_object('message', (select m441 from aeq_msg), 'path', '/buy/aeq-two', 'ua', 'Mozilla/5.0 Chrome/150', 'visitor', 'aeqvisitor2'));
select public.server_client_error(jsonb_build_object('message', (select m441 from aeq_msg), 'path', '/cars/aeq-one', 'ua', 'Mozilla/5.0 Chrome/150', 'visitor', 'aeqvisitor2'));
select public.server_client_error(jsonb_build_object('message', (select m418 from aeq_msg), 'path', '/cars/aeq-one', 'ua', 'Mozilla/5.0 Chrome/150', 'visitor', 'aeqvisitor2'));
create temp table aeq_g as select g.*, t.title, t.status from crash_groups g join tasks t on t.id = g.task_id where g.message like 'Minified React error #4%aeq%' or g.message = (select m418 from aeq_msg);
select test.eq('one open To do for #441 across pages, one for #418', (select count(*) from aeq_g where status = 'open'), 2::bigint);
select test.eq('the count of reports', (select reports from aeq_g where message = (select m441 from aeq_msg)), 3);
select test.eq('the pages, each once', (select pages from aeq_g where message = (select m441 from aeq_msg)), array['/cars/aeq-one', '/buy/aeq-two']);
select test.ok('the title says how many and where', (select title from aeq_g where message = (select m441 from aeq_msg)) like 'Website crash (3 times on 2 pages): Minified React error #441%');
select test.eq('no per-page To do', (select count(*) from tasks where task_type = 'site_alert' and status = 'open' and title like 'Website crash on /cars/aeq%'), 0::bigint);
select test.eq('not closed after 23 quiet hours', app.crash_todos_sweep(now() + interval '23 hours'), 0);
update tasks set status = 'in_progress' where id = (select task_id from aeq_g where message = (select m418 from aeq_msg)) and status = 'open';
select test.ok('closed after 24 quiet hours', app.crash_todos_sweep(now() + interval '25 hours') >= 1);
select test.eq('one someone is working on stays', (select status from tasks where id = (select task_id from aeq_g where message = (select m418 from aeq_msg))), 'in_progress');
select test.ok('a crash To do is never urgent', not exists (select 1 from tasks t join crash_groups g on g.task_id = t.id where t.priority = 'urgent' and t.created_at > now() - interval '1 minute'));
select test.eq('with the note', (select completion_note from tasks where id = (select task_id from aeq_g where message = (select m441 from aeq_msg))), 'No new reports for 24 hours');
select public.server_client_error(jsonb_build_object('message', (select m441 from aeq_msg), 'path', '/cars/aeq-three', 'visitor', 'aeqvisitor1'));
select test.eq('a later report opens a new one', (select count(*) from tasks t join crash_groups g on g.task_id = t.id where t.status = 'open' and g.message = (select m441 from aeq_msg)), 1::bigint);

-- the old To do's (one per page and day, 2895's words) fold into one per error
update tasks set status = 'done', completed_at = now(), completion_note = 'aeq reset'
 where task_type = 'site_alert' and status in ('open', 'in_progress') and id in (select task_id from crash_groups where message in ((select m441 from aeq_msg), (select m418 from aeq_msg)));
insert into tasks (queue, task_type, title, detail, priority, dedupe_key, created_at) values
  ('admin', 'site_alert', 'Website crash on /cars/aeq-a (3 times, 1 person): Minified React error #441; visit https://react.dev/errors/441?args[]=a for the full',
   'A page of the site failed in the browser. Page: /cars/aeq-a. Error: Minified React error #441; visit https://react.dev/errors/441?args[]=a for the full message. Today: 3 times, 1 person (first at 09:00 AM). Browsers: Chrome 150.', 'urgent', 'client_error:aeqa', now() - interval '3 hours'),
  ('admin', 'site_alert', 'Website crash on /buy/aeq-b: Minified React error #441; visit https://react.dev/errors/441?args[]=b for the full',
   'A page of the site failed in the browser. Page: /buy/aeq-b. Error: Minified React error #441; visit https://react.dev/errors/441?args[]=b for the full message. Today: 1 time, 1 person (first at 10:00 AM). Browsers: Chrome 150.', 'high', 'client_error:aeqb', now() - interval '1 hour'),
  ('admin', 'site_alert', 'Website crash on /cars/aeq-c (2 times, 1 person): Minified React error #418; visit https://react.dev/errors/418 for the full',
   'A page of the site failed in the browser. Page: /cars/aeq-c. Error: Minified React error #418; visit https://react.dev/errors/418 for the full message. Today: 2 times, 1 person (first at 11:00 AM). Browsers: Chrome 150.', 'high', 'client_error:aeqc', now() - interval '2 hours');
create temp table aeq_before as select count(*) as n from notification_outbox;
select app.crash_todos_fold();
select test.eq('the fold sends no email', (select count(*) from notification_outbox), (select n from aeq_before));
select test.eq('and changes no priority (the merged one was urgent, still is)', (select priority from tasks where dedupe_key = 'client_error:aeqa'), 'urgent');
select test.eq('the newest #441 is kept', (select status from tasks where id = (select id from tasks where title like 'Website crash%' and detail like '%/buy/aeq-b%' order by created_at limit 1)), 'open');
select test.eq('with both counts added', (select g.reports from crash_groups g join tasks t on t.id = g.task_id where t.detail like '%/buy/aeq-b%' and t.status = 'open'), 4);
select test.ok('and both pages', (select g.pages from crash_groups g join tasks t on t.id = g.task_id where t.detail like '%/buy/aeq-b%' and t.status = 'open') @> array['/cars/aeq-a', '/buy/aeq-b']);
select test.ok('the older one is closed, merged into the kept one', (select completion_note from tasks where dedupe_key = 'client_error:aeqa') like 'Merged into Website crash (4 times on 2 pages)%');
select test.eq('a different error stays its own To do', (select status from tasks where dedupe_key like 'client_error_sig:%' and detail like '%/cars/aeq-c%'), 'open');
select test.eq('a repeat of the error adds to the kept To do', (select public.server_client_error(jsonb_build_object('message', 'Minified React error #441; visit https://react.dev/errors/441?args[]=z for the full message', 'path', '/cars/aeq-d', 'visitor', 'aeqvisitor3'))), 'ok');
select test.eq('still one open #441 To do', (select count(*) from tasks t join crash_groups g on g.task_id = t.id where t.status = 'open' and g.signature = app.client_error_signature((select m441 from aeq_msg))), 1::bigint);

-- ================================================================ grants
select test.ok('the functions are the server''s only', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('admin_email_now', 'admin_email_gate', 'admin_now_email', 'admin_email_digests', 'crash_todos_sweep', 'crash_todos_fold', 'client_error_signature')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))));
