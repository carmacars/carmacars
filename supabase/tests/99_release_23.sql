-- 99: Release 23a (migrations 0220 to 0229, docs/changes/2026-11-03-*.md). IndexNow's changed pages on their own back-off
-- and first, the sweep inside the crawl scope; the CPU guard flag; usage alerts texted to the Admins; Cloudflare email
-- first; the hiring decisions sent together; remote calls confirmed or cancelled, the call method by role; the Quo texts
-- on Usage. Fixtures start with "r23".
select test.suite('99 release 23');

select test.mk_user('r23_admin', 'admin');
select test.mk_user('r23_cs', 'va', 'cs');
select test.mk_owner('r23_owner');
select test.mk_vehicle('r23_car', 'r23_owner');
select test.mk_vehicle('r23_car2', 'r23_owner');
select test.mk_renter('r23_renter');

-- ================================================================ 1. IndexNow (0220)
update program_settings set indexnow_enabled = true, indexnow_batch = 10000, indexnow_daily_max = 2000000 where id = (app.settings()).id;
update site_settings set indexnow_key = md5('r23') where indexnow_key is null;
delete from indexnow_queue where true;
update indexnow_sweep set backoff_until = null, backoff_s = 0, q_backoff_until = null, q_backoff_s = 0, streak_429 = 0, next_round_at = null,
       phase = 'priority', p_i = 0, p_pos = 0, file_i = 0, pos = -1, sent_today = 0, day = (now() at time zone 'America/Toronto')::date where id;
insert into indexnow_queue (path, reason) values ('/guides/r23-one', 'r23'), ('/cars/r23-car', 'r23');

-- the live state of October 31: the sweep refused with 429 until tomorrow
select app.server_indexnow_report('{"status": 429, "count": 10000, "error": "{\"errorCode\":\"TooManyRequests\"}"}');
select test.ok('the sweep''s 429 holds the sweep', (select backoff_until > now() from indexnow_sweep));
select test.ok('the changed pages are still claimed (their own back-off)', app.server_seo_claim('r23', 0) #> '{indexnow,paths}' @> '["/guides/r23-one", "/cars/r23-car"]'::jsonb);
select test.ok('and the tick runs the search job for them', (app.server_jobs_due() ->> 'seo')::boolean);
update indexnow_sweep set backoff_until = null, backoff_s = 0 where id;
select test.eq('the sweep waits while changed pages wait', app.server_indexnow_claim(100) ->> 'why', 'changed pages first');

select app.server_indexnow_sent('{"paths": ["/guides/r23-one", "/cars/r23-car"], "status": 429, "error": "TooManyRequests"}');
select test.ok('a 429 on the changed pages: an hour, and the sweep''s back-off untouched',
  (select q_backoff_until between now() + interval '55 minutes' and now() + interval '65 minutes' and backoff_until is null from indexnow_sweep));
select test.eq('while they wait nothing of theirs is claimed', app.server_seo_claim('r23', 0) #> '{indexnow,paths}', '[]'::jsonb);
update indexnow_sweep set q_backoff_until = null where id;
select app.server_indexnow_sent('{"paths": ["/guides/r23-one"], "status": 429}');
select test.ok('the next 429 in a row doubles the wait', (select q_backoff_s = 7200 from indexnow_sweep));
update indexnow_sweep set q_backoff_until = null where id;
select app.server_indexnow_sent('{"paths": ["/guides/r23-one", "/cars/r23-car"], "status": 202}');
select test.ok('a 2xx sends them and clears their back-off', (select q_backoff_until is null and q_backoff_s = 0 and q_last_status = 202 from indexnow_sweep)
  and not exists (select 1 from indexnow_queue where path like '%r23%' and sent_at is null));

-- the crawl scope
select test.ok('crawl scope: the trees that multiply are out',
  not app.crawl_scope_ok('/t/buffing/audi/a4/2021') and not app.crawl_scope_ok('/buy/honda') and not app.crawl_scope_ok('/cars/audi/a4/2021/s-line/toronto')
  and not app.crawl_scope_ok('/car-rental/weekly/toronto') and not app.crawl_scope_ok('/car-rental/r23-nowhere-oh') and not app.crawl_scope_ok('/places/3'));
select test.ok('crawl scope: the vehicle tree to the trim, the fleet and the guides are in',
  app.crawl_scope_ok('/cars/audi/a4/2021/s-line') and app.crawl_scope_ok('/cars/r23-car') and app.crawl_scope_ok('/guides/x') and app.crawl_scope_ok('/'));
delete from indexnow_queue where sent_at is null;
update indexnow_sweep set phase = 'places', p_i = 3 where id;
select test.eq('past the priority list the round is done: the next waits a week', app.server_indexnow_claim(100) ->> 'why', 'next round');
select test.ok('back at the start of the priority list', (select phase = 'priority' and p_pos = 0 and next_round_at > now() + interval '6 days' from indexnow_sweep));
update indexnow_sweep set next_round_at = null, streak_429 = 1, backoff_until = null where id;
select app.server_indexnow_report('{"status": 429, "count": 5}');
select test.ok('a second 429 in a row adds a day', (select streak_429 = 2 and backoff_until > now() + interval '1 day' from indexnow_sweep));
update indexnow_sweep set backoff_until = null, backoff_s = 0, streak_429 = 0, next_round_at = null, q_backoff_until = null, q_backoff_s = 0, phase = 'priority', p_pos = 0 where id;
update program_settings set indexnow_enabled = false where id = (app.settings()).id;

select test.ok('the tick says whether the CPU guard is up', (app.server_jobs_due() ? 'cpu_guard'));

-- ================================================================ 2. usage alerts texted (0221)
update users set phone = '+14165550123', phone_verified_at = now() where id = test.id('r23_admin');
delete from usage_alerts where service = 'workers_cpu';
insert into usage_alerts (service, period_start, level, used, included) values ('workers_cpu', date_trunc('month', app.local_date(now()))::date, 100, 1090000000, 30000000);
create temp table r23q as select uptime_quiet_from_hour f, uptime_quiet_until_hour u from app.settings();
update program_settings set uptime_quiet_from_hour = 0, uptime_quiet_until_hour = 0 where id = (app.settings()).id;
select app.usage_send_texts(now());
select test.ok('a 100% alert is texted to each Admin with a verified phone',
  exists (select 1 from phone_outbox where dedupe_key like 'usage_text:workers_cpu:100:%' || test.id('r23_admin')::text and body like 'CarmaCars: Website CPU time at%'));
select app.usage_send_texts(now());
select test.eq('once per figure and level a month', (select count(*) from phone_outbox where dedupe_key like 'usage_text:workers_cpu:100:%' || test.id('r23_admin')::text), 1::bigint);
select test.ok('the banner shows a figure past its allowance', jsonb_typeof(app.usage_banner(test.id('r23_admin'))) = 'array');
select test.throws('only Admins read the banner', $$ select app.usage_banner(test.id('r23_cs')) $$, 'Admin');
select test.ok('a 70% level exists for the CPU time', (select warn_bps = 7000 from usage_services where service = 'workers_cpu'));

-- ================================================================ 3. Cloudflare email first (0222)
select test.ok('the sender tries Cloudflare (on, under the month''s 3,000)', app.cf_email_try());
select test.ok('Resend''s limits hold until Cloudflare has sent', not app.cf_email_available());
select public.server_cf_email_result('{"ok": true}');
select test.ok('once it sends, Resend''s limits are lifted', app.cf_email_available());
select public.server_cf_email_result('{"ok": false, "error": "no EMAIL binding"}');
select test.ok('after a refusal it rests 15 minutes', not app.cf_email_try() and not app.cf_email_available());
update email_provider_state set cf_failed_at = now() - interval '20 minutes', cf_ok_at = null where id;
select test.ok('then it may try again', app.cf_email_try());
select test.ok('Settings > Usage counts the Cloudflare emails', exists (select 1 from usage_services where service = 'cf_email' and included = 3000));

-- ================================================================ 4. hiring decisions (0226)
insert into job_applications (role_id, status, full_name, email) select id, 'interviewed', 'R23 Field Person', 'field@r23.example.test' from hiring_roles where slug = 'field-staff';
insert into job_applications (role_id, status, full_name, email) select id, 'interviewed', 'R23 Remote Person', 'remote@r23.example.test' from hiring_roles where slug = 'va-customer-service';
create function test.r23app(p text) returns uuid language sql stable as $$ select id from job_applications where email = p $$;
insert into interview_scores (application_id, decision, interviewer) values (test.r23app('field@r23.example.test'), 'sales', test.id('r23_admin'));
insert into interview_scores (application_id, decision, interviewer) values (test.r23app('remote@r23.example.test'), 'no', test.id('r23_admin'));
select test.eq('the rubric''s Sales instead: in person for Field staff', (select r.slug from hiring_decisions d join hiring_roles r on r.id = d.sales_role_id
  where d.application_id = test.r23app('field@r23.example.test')), 'sales-in-person');
select test.eq('No is the polite decline', (select email_code from hiring_decisions where application_id = test.r23app('remote@r23.example.test')), 'applicant_declined');
select test.eq('nothing is emailed when the decision is recorded',
  (select count(*) from app_events where entity = 'job_application' and entity_id in (test.r23app('field@r23.example.test'), test.r23app('remote@r23.example.test'))), 0::bigint);
select test.eq('the list shows both waiting', (app.hiring_decisions_read(test.id('r23_admin'), '{}'::jsonb) ->> 'waiting')::integer >= 2, true);
select test.ok('Send all can be scheduled', (app.hiring_decisions_send(test.id('r23_admin'), jsonb_build_object('when', (now() + interval '2 days')::text)) ->> 'scheduled')::integer >= 2);
select app.hiring_decisions_send(test.id('r23_admin'), '{}'::jsonb);
select test.eq('sent: one email each, the statuses follow',
  (select string_agg(a.status, ',' order by a.email) from job_applications a where a.email like '%@r23.example.test'), 'referred,rejected');
select app.hiring_decisions_send(test.id('r23_admin'), '{}'::jsonb);
select test.eq('never twice', (select count(*) from app_events where entity = 'job_application' and entity_id in (test.r23app('field@r23.example.test'), test.r23app('remote@r23.example.test'))), 2::bigint);
select test.throws('a decision sent cannot be undone', $$ select app.hiring_decision_undo(test.id('r23_admin'), jsonb_build_object('id', test.r23app('remote@r23.example.test'))) $$, 'sent already');
select test.ok('the hire and no-show emails are in the catalogue', (select count(*) = 2 from notification_catalogue where code in ('applicant_hired', 'applicant_no_show')));

-- ================================================================ 5. calls by role, the remote call confirmed (0229)
insert into interview_days (day, start_time, end_time, mode, note) values (app.local_date(now()) + 1, '08:00', '20:00', 'phone', 'r23 day');
insert into interview_slots (day_id, starts_at, ends_at) select d.id, now() + interval '20 hours', now() + interval '20 hours 15 minutes' from interview_days d where d.note = 'r23 day';
insert into interview_slots (day_id, starts_at, ends_at) select d.id, now() + interval '21 hours', now() + interval '21 hours 15 minutes' from interview_days d where d.note = 'r23 day';
insert into job_applications (role_id, status, full_name, email, phone) select id, 'invited', 'R23 Video Person', 'video@r23.example.test', '+639170000000' from hiring_roles where slug = 'va-fleet-operations';
insert into job_applications (role_id, status, full_name, email, phone) select id, 'invited', 'R23 Phone Person', 'phone@r23.example.test', '+14165550188' from hiring_roles where slug = 'field-staff';
select test.eq('a remote role meets by video on a phone day', (app.hiring_book((select token from job_applications where email = 'video@r23.example.test'),
  (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'r23 day' order by s.starts_at limit 1))) ->> 'mode', 'video');
select test.ok('with its video link', (select meet_url like 'https://meet.jit.si/%' from job_applications where email = 'video@r23.example.test'));
update interview_days set mode = 'video' where note = 'r23 day';
select test.eq('an in-person role is called by phone on a video day', (app.hiring_book((select token from job_applications where email = 'phone@r23.example.test'),
  (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'r23 day' order by s.starts_at offset 1 limit 1))) ->> 'mode', 'phone');
select test.ok('without a video link', (select meet_url is null from job_applications where email = 'phone@r23.example.test'));

select app.job_hiring(now());
select test.ok('the remote call is asked to confirm (24 hours before), and gets no reminder', (select confirm_sent_at is not null and reminded_hour_at is not null
  from job_applications where email = 'video@r23.example.test')
  and exists (select 1 from app_events where code = 'applicant_confirm' and entity_id = (select id from job_applications where email = 'video@r23.example.test')));
select test.ok('the in-person call is not asked', (select confirm_sent_at is null from job_applications where email = 'phone@r23.example.test'));
select test.eq('the Calls tab says Waiting', app.hiring_confirm_state((select x from job_applications x where email = 'video@r23.example.test')), 'waiting');
select test.eq('one press confirms, no sign-in', (public.server_hiring_confirm((select token from job_applications where email = 'video@r23.example.test')) ->> 'ok'), 'true');
select test.eq('then Confirmed', app.hiring_confirm_state((select x from job_applications x where email = 'video@r23.example.test')), 'confirmed');
-- not confirmed in time: cancelled, the time opens again, one email
update job_applications set confirmed_at = null, confirm_sent_at = now() - interval '13 hours' where email = 'video@r23.example.test';
select app.job_hiring(now());
select test.ok('unconfirmed after 12 hours: cancelled, the slot free', (select status = 'invited' and slot_id is null and unconfirmed_at is not null from job_applications where email = 'video@r23.example.test'));
select test.eq('the candidate gets one short email', (select count(*) from app_events where code = 'applicant_unconfirmed' and entity_id = (select id from job_applications where email = 'video@r23.example.test')), 1::bigint);
select app.job_hiring(now());
select test.eq('never twice', (select count(*) from app_events where code = 'applicant_unconfirmed' and entity_id = (select id from job_applications where email = 'video@r23.example.test')), 1::bigint);
select test.eq('Cancelled on the Calls tab', app.hiring_confirm_state((select x from job_applications x where email = 'video@r23.example.test')), 'cancelled');

-- the Quo texts on Settings > Usage, at a cent each
select test.ok('Settings > Usage counts the Quo texts', exists (select 1 from usage_services where service = 'quo_texts' and usd_per_unit = 0.01));
select app.usage_measure('quo_texts', now());
select test.ok('measured from the texts sent', exists (select 1 from usage_readings where service = 'quo_texts'));
