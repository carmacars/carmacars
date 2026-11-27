-- 99: release 50 hotfix 2 (5160 to 5163). Search Console: the sitemaps of the last run only, the searches for the
-- connector (Admins only). Hiring: the interview reminders (1 and 3 days, the day before expiry, never two within 12
-- hours, held while another email waits, none once the interview is in), the one-tap new link on an expired link, a
-- waiting reminder skipped as stale. Traction: the generic model, the app's visits, the rented days split by month, the
-- deck read (investor and Admin only). The OPCF 27 page. Fixtures start with "zr5h"; every address is example.test.
select test.suite('99 r50 hotfix 2 seo, interview reminders, traction (5160 to 5163)');
update app_events set processed_at = now() where processed_at is null;
select test.mk_user('zr5h_admin', 'admin');
select test.mk_user('zr5h_cs', 'va', 'cs');

-- ================================================================ 5160: Search Console
delete from app.gsc_sitemap_log where path like 'https://zr5h.example.test/%';
insert into app.gsc_sitemap_log (path, at, errors, is_pending, submitted) values
  ('https://zr5h.example.test/sitemap-old.xml', now() - interval '20 days', 1, true, 0),
  ('https://zr5h.example.test/sitemap-pages.xml', now() + interval '1 minute', 0, false, 40),
  ('https://zr5h.example.test/sitemap-families.xml', now() + interval '1 minute', 1, false, 0);
select test.eq('the latest sitemaps are the last run''s only: a file the property dropped no longer shows its old error',
  (select string_agg(path, ',' order by path) from app.gsc_sitemap_latest where path like 'https://zr5h.example.test/%'),
  'https://zr5h.example.test/sitemap-families.xml,https://zr5h.example.test/sitemap-pages.xml');
select test.ok('search_console_issues lists the errored file of the last run, not the dropped one',
  (select (s ->> 'sitemaps') like '%zr5h.example.test/sitemap-families.xml%' and (s ->> 'sitemaps') not like '%sitemap-old.xml%'
     from (select app.search_console_issues(test.id('zr5h_admin'), '{}'::jsonb) s) x));
delete from app.gsc_sitemap_log where path like 'https://zr5h.example.test/%';

delete from app.gsc_page_query where key like '%zr5h%';
insert into app.gsc_page_query (kind, key, clicks, impressions, ctr, position, window_end) values
  ('query', 'zr5h gps tracker toronto', 3, 400, 0.0075, 9.4, current_date), ('query', 'zr5h car rental', 10, 900, 0.011, 12.1, current_date), ('page', '/trackers/zr5h', 1, 50, 0.02, 7, current_date);
select test.eq('the searches, the most shown first, filtered by a word',
  (select string_agg(q ->> 'query', ',') from jsonb_array_elements(app.search_console_queries(test.id('zr5h_admin'), '{"contains": "zr5h"}'::jsonb) -> 'queries') q),
  'zr5h car rental,zr5h gps tracker toronto');
select test.eq('and the pages', (app.search_console_queries(test.id('zr5h_admin'), '{"contains": "zr5h"}'::jsonb) #>> '{pages,0,path}'), '/trackers/zr5h');
select test.throws('staff do not read the searches', $$select app.search_console_queries(test.id('zr5h_cs'), '{}'::jsonb)$$, 'Only an Admin');
select test.eq('the connector routes the tool through its own check (an unknown key is refused, not passed on)',
  (app.api_call('zr5h-no-such-key', 'search_console_queries', '{}'::jsonb) ->> 'ok'), 'false');
delete from app.gsc_page_query where key like '%zr5h%';

-- ================================================================ 5161: interview reminders
update program_settings set hiring_ai_interviews = true, hiring_ai_interview_days = 7, hiring_ai_reminder_hours = '{24,72}', hiring_ai_reminder_last_hours = 24,
       hiring_ai_self_renewals = 3, hiring_sms_reminders = true, phone_enabled = true;
create or replace function test.zr5h_app(p_k text, p_phone text) returns job_applications language sql as $$
  insert into job_applications (role_id, status, full_name, email, phone, score, work_mode, invited_at)
  select r.id, 'invited', initcap(p_k) || ' Tester', p_k || '@zr5h.example.test', p_phone, 90, r.work_mode, now()
    from hiring_roles r where r.slug = 'va-customer-service'
  returning * $$;
create or replace function test.zr5h_iv(p_k text, p_sent timestamptz) returns ai_interviews language sql as $$
  insert into ai_interviews (application_id, role_id, questions, sent_at, expires_at)
  select a.id, a.role_id, '[{"key":"q1","topics":[],"text":"Q1"},{"key":"q2","topics":[],"text":"Q2"}]'::jsonb, p_sent, p_sent + interval '7 days'
    from job_applications a where a.email = p_k || '@zr5h.example.test'
  returning * $$;
create or replace function test.zr5h_mails(p_k text) returns bigint language plpgsql as $$
begin
  perform app.process_events();
  return (select count(*) from notification_outbox o where o.code = 'applicant_ai_interview_reminder' and o.to_address = p_k || '@zr5h.example.test');
end $$;
select test.zr5h_app('zr5hca', '+1 416 555 0142');
select test.zr5h_app('zr5hph', '+63 917 000 0142');
select test.zr5h_app('zr5hdone', '+1 416 555 0143');
select test.zr5h_iv('zr5hca', now() - interval '25 hours');
select test.zr5h_iv('zr5hph', now() - interval '2 hours');
select test.zr5h_iv('zr5hdone', now() - interval '30 hours');
update ai_interviews set state = 'submitted', submitted_at = now() where application_id = (select id from job_applications where email = 'zr5hdone@zr5h.example.test');

create temporary table zr5h_n1 as select app.hiring_ai_nudge(now()) r;
select test.eq('a day after the link: one reminder email to the applicant who has not started', test.zr5h_mails('zr5hca'), 1::bigint);
select test.eq('two hours after the link: none yet', test.zr5h_mails('zr5hph'), 0::bigint);
select test.eq('an interview sent in: none', test.zr5h_mails('zr5hdone'), 0::bigint);
select test.eq('a text goes with it to a Canadian number',
  (select count(*) from phone_outbox where dedupe_key like 'hiring_ai_reminder:%' and to_number like '%4165550142%'), 1::bigint);
select test.ok('the email carries the one-tap link and the expiry',
  (select o.payload ->> 'interview_url' like '%/careers/interview/%' and o.payload ? 'expires_on' from notification_outbox o
    where o.code = 'applicant_ai_interview_reminder' and o.to_address = 'zr5hca@zr5h.example.test'));
select app.hiring_ai_nudge(now());
select test.eq('never two within 12 hours', test.zr5h_mails('zr5hca'), 1::bigint);
-- three days on: the second, held while another email to them still waits, sent once it has gone
update ai_interviews set reminded_at = now() - interval '13 hours', expires_at = now() + interval '4 days' - interval '1 hour', sent_at = now() - interval '3 days' - interval '1 hour'
 where application_id = (select id from job_applications where email = 'zr5hca@zr5h.example.test');
update notification_outbox set status = 'queued' where code = 'applicant_ai_interview_reminder' and to_address = 'zr5hca@zr5h.example.test';
select test.eq('held while the first still waits in the outbox', (app.hiring_ai_nudge(now()) ->> 'held')::int >= 1, true);
update notification_outbox set status = 'sent', sent_at = now() where code = 'applicant_ai_interview_reminder' and to_address = 'zr5hca@zr5h.example.test';
select app.hiring_ai_nudge(now());
select test.eq('three days after the link: the second reminder', test.zr5h_mails('zr5hca'), 2::bigint);
-- the day before it expires: the last (the second has gone out)
update notification_outbox set status = 'sent', sent_at = now() where code = 'applicant_ai_interview_reminder' and to_address = 'zr5hca@zr5h.example.test' and status <> 'sent';
update ai_interviews set reminded_at = now() - interval '13 hours', expires_at = now() + interval '20 hours'
 where application_id = (select id from job_applications where email = 'zr5hca@zr5h.example.test');
select app.hiring_ai_nudge(now());
select test.eq('the day before the link expires: the last reminder', test.zr5h_mails('zr5hca'), 3::bigint);
update notification_outbox set status = 'sent', sent_at = now() where code = 'applicant_ai_interview_reminder' and to_address = 'zr5hca@zr5h.example.test' and status <> 'sent';
update ai_interviews set reminded_at = now() - interval '13 hours' where application_id = (select id from job_applications where email = 'zr5hca@zr5h.example.test');
select app.hiring_ai_nudge(now());
select test.eq('then no more', test.zr5h_mails('zr5hca'), 3::bigint);
-- a waiting reminder whose interview is in is stale
update ai_interviews set state = 'submitted' where application_id = (select id from job_applications where email = 'zr5hca@zr5h.example.test');
select test.ok('a waiting reminder is skipped once the interview is in',
  (select app.outbox_stale_reason(o, now()) like 'stale:%' from notification_outbox o where o.code = 'applicant_ai_interview_reminder' and o.to_address = 'zr5hca@zr5h.example.test' limit 1)
  or not exists (select 1 from notification_outbox o where o.code = 'applicant_ai_interview_reminder' and o.to_address = 'zr5hca@zr5h.example.test' and o.status in ('queued', 'delayed')));
update notification_outbox set status = 'queued' where code = 'applicant_ai_interview_reminder' and to_address = 'zr5hca@zr5h.example.test';
select test.ok('stale: the interview is in',
  (select bool_and(app.outbox_stale_reason(o, now()) like 'stale: the interview is in%') from notification_outbox o where o.code = 'applicant_ai_interview_reminder' and o.to_address = 'zr5hca@zr5h.example.test'));
update notification_outbox set status = 'sent', sent_at = now() where code = 'applicant_ai_interview_reminder' and to_address = 'zr5hca@zr5h.example.test';
select test.ok('the hiring job runs the reminders', app.job_hiring(now()) ? 'ai_reminders');

-- the one-tap new link on an expired link
update ai_interviews set expires_at = now() - interval '1 hour', links_sent = 1 where application_id = (select id from job_applications where email = 'zr5hph@zr5h.example.test');
select test.eq('an expired link says it can be opened again',
  (public.server_ai_interview((select token from job_applications where email = 'zr5hph@zr5h.example.test')) ->> 'can_renew'), 'true');
select test.eq('one tap opens a new link', public.server_ai_interview_renew((select token from job_applications where email = 'zr5hph@zr5h.example.test')) ->> 'ok', 'true');
select test.ok('the link works again for the configured days, as a new link',
  (select i.expires_at > now() + interval '6 days' and i.links_sent = 2 and i.state = 'sent' from ai_interviews i join job_applications a on a.id = i.application_id where a.email = 'zr5hph@zr5h.example.test'));
select test.eq('a link still open is not renewed', public.server_ai_interview_renew((select token from job_applications where email = 'zr5hph@zr5h.example.test')) ->> 'error', 'not_renewable');
update ai_interviews set expires_at = now() - interval '1 hour', links_sent = 3 where application_id = (select id from job_applications where email = 'zr5hph@zr5h.example.test');
select test.eq('not past the links allowed (hiring_ai_self_renewals)', public.server_ai_interview_renew((select token from job_applications where email = 'zr5hph@zr5h.example.test')) ->> 'error', 'not_renewable');
select test.eq('an unknown token', public.server_ai_interview_renew('zr5h-no-such-token') ->> 'error', 'not_found');
select test.eq('a submitted interview is not renewed', public.server_ai_interview_renew((select token from job_applications where email = 'zr5hdone@zr5h.example.test')) ->> 'error', 'not_renewable');
select test.ok('the renew and the reminders are the server''s only',
  not has_function_privilege('anon', 'public.server_ai_interview_renew(text)', 'execute') and not has_function_privilege('authenticated', 'public.server_ai_interview_renew(text)', 'execute')
  and not has_function_privilege('anon', 'app.hiring_ai_nudge(timestamptz)', 'execute'));

-- ================================================================ 5162: traction
select test.eq('CarmaCars has three measures', (select string_agg(code, ',' order by sort_order) from traction_metrics where business = 'carmacars'), 'mau_web,mau_app,days_rented');
-- another business uses the same model (merch: items customized)
insert into traction_metrics (business, code, label, unit) values ('zr5hmerch', 'items_customized', 'Items customized', 'items');
insert into traction_monthly (business, code, month, value) values ('zr5hmerch', 'items_customized', date_trunc('month', now())::date, 42);
select test.eq('another business reads its own measures', (app.deck_traction('zr5hmerch') #>> '{metrics,0,months,0,value}'), '42');
select test.throws('a month is the first of the month', $$insert into traction_monthly (business, code, month, value) values ('zr5hmerch', 'items_customized', '2026-10-15', 1)$$, null);
delete from traction_metrics where business = 'zr5hmerch';

-- visits: the app's beacon marks its session
insert into visitor_sessions (id, visitor_id, started_at, last_seen_at) values
  ('51620000-0000-4000-8000-000000000001', '51620000-0000-4000-8000-0000000000a1', now(), now()),
  ('51620000-0000-4000-8000-000000000002', '51620000-0000-4000-8000-0000000000a1', now(), now()),
  ('51620000-0000-4000-8000-000000000003', '51620000-0000-4000-8000-0000000000a2', now(), now());
select app.track_ingest(jsonb_build_object('sid', '51620000-0000-4000-8000-000000000003', 'vid', '51620000-0000-4000-8000-0000000000a2', 'consent', 'analytics', 'app', '1', 'events', '[]'::jsonb), '{}'::jsonb);
select test.eq('the app''s beacon marks its session', (select via from visitor_sessions where id = '51620000-0000-4000-8000-000000000003'), 'app');
select test.eq('a website session stays web', (select via from visitor_sessions where id = '51620000-0000-4000-8000-000000000001'), 'web');
select test.ok('track_ingest still checks the per-address rate limit (the original, wrapped)', (select prosrc ~ 'public_rate_check' from pg_proc where oid = 'app.track_ingest(jsonb, jsonb)'::regprocedure));

-- rented days: a booking across two months is split; a cancelled one is not counted
select test.mk_owner('zr5h_owner');
select test.mk_vehicle('zr5h_car', 'zr5h_owner');
select test.mk_renter('zr5h_renter');
select test.mk_booking('CC-Z5H01', 'zr5h_car', 'zr5h_renter', '2026-09-29 12:00', '2026-10-03 12:00', 'closed');
select test.mk_booking('CC-Z5H02', 'zr5h_car', 'zr5h_renter', '2026-10-10 12:00', '2026-10-12 12:00', 'cancelled');
delete from traction_monthly where business = 'carmacars';
select app.traction_refresh('2026-11-27 12:00-05'::timestamptz);
select test.ok('the days of a booking are split over its months (Sept 29 noon to Oct 3 noon: 1.5 and 2.5 days)',
  (select value >= 1.5 from traction_monthly where business = 'carmacars' and code = 'days_rented' and month = '2026-09-01')
  and (select value >= 2.5 from traction_monthly where business = 'carmacars' and code = 'days_rented' and month = '2026-10-01'));
select app.traction_refresh(now());
select test.ok('the month''s distinct browsers by website and app',
  (select value >= 1 from traction_monthly where business = 'carmacars' and code = 'mau_web' and month = date_trunc('month', now() at time zone 'America/Toronto')::date)
  and (select value >= 1 from traction_monthly where business = 'carmacars' and code = 'mau_app' and month = date_trunc('month', now() at time zone 'America/Toronto')::date));
select test.ok('the visitor history job refreshes them', app.job_visitor_history(now()) is not null and exists (select 1 from traction_monthly where business = 'carmacars' and updated_at > now() - interval '1 minute'));
select test.ok('an Admin reads the deck''s traction', jsonb_array_length(public.door(test.id('zr5h_admin'), 'aal2', 'admin_read', 'deck_traction', '{}'::jsonb) -> 'metrics') = 3);
select test.throws('staff do not', $$select public.door(test.id('zr5h_cs'), 'aal2', 'investor_read', 'deck_traction', '{}'::jsonb)$$, null);
select test.ok('the tables: row-level security, nothing for visitors',
  (select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('traction_metrics', 'traction_monthly'))
  and not has_table_privilege('anon', 'traction_monthly', 'select'));
delete from visitor_sessions where id::text like '51620000-%';

-- ================================================================ 5163: the OPCF 27 page
select test.ok('the OPCF 27 landing page is published with its questions',
  (select status = 'published' and kind = 'use' and jsonb_array_length(copy -> 'faq') >= 3 and copy ->> 'h1' like '%OPCF 27%' from seo_pages where slug = 'opcf-27'));

-- ================================================================ 5165: the changed pages from the gsc workflow
update program_settings set indexnow_enabled = true;
update indexnow_sweep set q_backoff_until = null;
insert into indexnow_queue (path, reason, queued_at) values ('/zr5h-a', 'test', now() - interval '2 hours'), ('/zr5h-b', 'test', now() - interval '1 hour')
on conflict (path) do update set sent_at = null, attempts = 0, queued_at = excluded.queued_at;
select test.ok('the workflow claims the waiting changed pages, the oldest first',
  (select (c -> 'paths') ? '/zr5h-a' and (c -> 'paths') ? '/zr5h-b' from (select app.server_indexnow_changed_claim(10000) c) x));
select app.server_indexnow_sent('{"paths": ["/zr5h-a", "/zr5h-b"], "status": 200}'::jsonb);
select test.ok('and their answer marks them sent', (select bool_and(sent_at is not null) from indexnow_queue where path like '/zr5h-%'));
update indexnow_sweep set q_backoff_until = now() + interval '1 hour';
select test.eq('not while the changed pages'' back-off holds', jsonb_array_length(app.server_indexnow_changed_claim(10) -> 'paths'), 0);
update indexnow_sweep set q_backoff_until = null;
select test.ok('the server''s only', not has_function_privilege('anon', 'app.server_indexnow_changed_claim(integer)', 'execute'));
delete from indexnow_queue where path like '/zr5h-%';
