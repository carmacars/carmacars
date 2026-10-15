-- 27: the email daily cap made safe for the provider's free plan (migration 0043): Supabase Auth's own emails
-- counted, the classes leaving room for them, the 80% warning in the portal, the provider's 429 held without
-- spending an attempt, a final failure told to the Admins, and the day's use on Admin > Today. Fixtures start with "ec".
select test.suite('27 email cap');
create or replace function test.ec_at(p text) returns timestamptz language sql immutable as $$ select (p::timestamp at time zone 'America/Toronto') $$;

select test.mk_user('ec_admin', 'admin');

-- ================================================================ 1. settings
select test.eq('settings: customer emails stop at 97, owners 95, staff 90, digests 80, marketing 60; the warning at 80%; sign-in emails counted',
  (select array_to_string(notify_class_limits, ',') || '/' || notify_daily_cap || '/' || notify_cap_warn_bps || '/' || notify_count_auth_emails from app.settings()),
  '97,95,90,80,60/100/8000/true');
select test.eq('settings: the two portal notices exist and send no email',
  (select string_agg(code || ':' || has_email, ',' order by code) from notification_catalogue where code in ('staff_email_cap_warning', 'staff_email_failed')),
  'staff_email_cap_warning:false,staff_email_failed:false');

-- ================================================================ 2. Supabase Auth's emails
select test.eq('auth: no auth.users table (a plain database) counts 0', app.auth_emails_today(test.ec_at('2032-03-02 12:00')), 0);
-- the shape of Supabase's auth.users, only the columns read
create table auth.users (id uuid primary key, email text, confirmation_sent_at timestamptz, recovery_sent_at timestamptz,
                         email_change_sent_at timestamptz, reauthentication_sent_at timestamptz, invited_at timestamptz);
insert into auth.users (id, email, invited_at, confirmation_sent_at, recovery_sent_at) values
  (gen_random_uuid(), 'ec1@example.test', test.ec_at('2032-03-02 09:00'), test.ec_at('2032-03-02 09:00'), test.ec_at('2032-03-02 10:00'));
insert into auth.users (id, email, recovery_sent_at, email_change_sent_at) values
  (gen_random_uuid(), 'ec2@example.test', test.ec_at('2032-03-01 23:30'), test.ec_at('2032-03-02 13:00'));
select test.eq('auth: an invitation (two columns, one instant) and a reset today count 2; yesterday''s reset and a later send do not',
  app.auth_emails_today(test.ec_at('2032-03-02 12:00')), 2);
select test.eq('auth: the day is the Toronto day', app.auth_emails_today(test.ec_at('2032-03-03 00:30')), 0);

-- a clean outbox for the cap
update notification_outbox set status = 'sent', sent_at = timestamptz '2020-01-01 12:00+00' where status in ('queued', 'delayed', 'sending');
select test.eq('auth: the day''s total counts the outbox and the sign-in emails', app.outbox_sent_today(test.ec_at('2032-03-02 12:00')), 2);
update program_settings set notify_count_auth_emails = false;
select test.eq('auth: switched off, sign-in emails are not counted', app.auth_emails_today(test.ec_at('2032-03-02 12:00')), 0);
update program_settings set notify_count_auth_emails = true;

-- ================================================================ 3. the classes and the warning
insert into program_settings select (jsonb_populate_record(null::program_settings, to_jsonb(app.settings()) || jsonb_build_object(
  'id', gen_random_uuid(), 'effective_from', '2032-03-01', 'notify_daily_cap', 10, 'notify_class_limits', array[9, 9, 8, 7, 5]))).*;
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key, created_at, send_after)
select c, 'transactional', p, 'renter', 'ec' || p || '_' || lpad(n::text, 2, '0') || '@example.test', '{}', 'eccap:' || p || ':' || n,
       now() + make_interval(secs => p * 100 + n), test.ec_at('2032-03-02 08:00')
  from (values (1, 'renter_offer_ready'), (4, 'staff_weekly_summary')) v(p, c), generate_series(1, 9) n
 where p = 1 or n <= 2;
select test.eq('classes: with 2 sign-in emails sent, a cap of 10 and customer emails stopping at 9: seven customer emails go, no digest',
  (select count(*) filter (where code = 'renter_offer_ready') || '/' || count(*) filter (where code = 'staff_weekly_summary')
     from app.outbox_claim(100, test.ec_at('2032-03-02 12:00'))), '7/0');
select test.eq('classes: the rest waits for midnight with its reason, never dropped',
  (select count(*) || '/' || string_agg(distinct status_reason, ',') || '/' || bool_and(send_after = test.ec_at('2032-03-03 00:00'))
     from notification_outbox where dedupe_key like 'eccap:%' and status = 'delayed'), '4/daily email limit/true');
select test.eq('warning: none before the day reached 80%',
  (select count(*) from notifications where code = 'staff_email_cap_warning' and user_id = test.id('ec_admin')), 0::bigint);
select app.outbox_claim(100, test.ec_at('2032-03-02 12:01'));
select test.eq('warning: at 9 of 10 (80% is 8) the Admin has one portal notice naming the count and the sign-in emails',
  (select count(*) || '/' || bool_and(title = 'Email use is at 90% of today''s limit' and body like '9 of 10 emails today (2 from sign-in emails)%' and url like '%/admin/messages')
     from notifications where code = 'staff_email_cap_warning' and user_id = test.id('ec_admin')), '1/true');
select app.outbox_claim(100, test.ec_at('2032-03-02 12:05'));
select test.eq('warning: not repeated the same day',
  (select count(*) from notifications where code = 'staff_email_cap_warning' and user_id = test.id('ec_admin')), 1::bigint);
select test.eq('warning: no email is queued about it',
  (select count(*) from notification_outbox where code in ('staff_email_cap_warning', 'staff_email_failed')), 0::bigint);

-- ================================================================ 4. the provider's 429
create temp table ec_r (k text primary key, v text);
insert into ec_r select 'defer', app.outbox_defer(id, 'held by the email provider''s rate limit', test.ec_at('2032-03-02 12:02'), test.ec_at('2032-03-02 12:01'))
  from notification_outbox where dedupe_key = 'eccap:1:1';
select test.eq('provider rate limit: the row is held a minute and the attempt is given back',
  (select v from ec_r where k = 'defer') || '/' ||
  (select status || '/' || attempts || '/' || (send_after = test.ec_at('2032-03-02 12:02')) from notification_outbox where dedupe_key = 'eccap:1:1'),
  'delayed/delayed/0/true');
select test.eq('provider rate limit: a row not being sent is left alone',
  (select app.outbox_defer(id, 'x', test.ec_at('2032-03-02 12:05')) from notification_outbox where dedupe_key = 'eccap:1:1'), 'delayed');
select app.outbox_defer(id, 'the email provider''s daily limit', test.ec_at('2032-03-03 00:00'), test.ec_at('2032-03-02 12:03'))
  from notification_outbox where dedupe_key = 'eccap:1:2';
select test.eq('provider daily limit: held until midnight, counted as held, and the Admins told in the portal (once that day)',
  (select status || '/' || (send_after = test.ec_at('2032-03-03 00:00')) from notification_outbox where dedupe_key = 'eccap:1:2') || '/' ||
  (select count(*) from notifications where code = 'staff_email_cap_reached' and user_id = test.id('ec_admin') and dedupe_key like 'staff_email_cap_reached:2032-03-02|%'),
  'delayed/true/1');

-- ================================================================ 5. a final failure is told
insert into ec_r select 'retry', app.outbox_mark_failed(id, 'timeout', false, test.ec_at('2032-03-02 12:04')) from notification_outbox where dedupe_key = 'eccap:1:3';
select test.eq('failure: a first failure is retried and tells nobody',
  (select v from ec_r where k = 'retry') || '/' ||
  (select count(*) from notifications where code = 'staff_email_failed' and user_id = test.id('ec_admin')), 'retry/0');
insert into ec_r select 'failed', app.outbox_mark_failed(id, 'Resend 422: invalid address', true, test.ec_at('2032-03-02 12:04')) from notification_outbox where dedupe_key = 'eccap:1:4';
select test.eq('failure: refused for good, the row fails and the Admin gets a notice naming the email, the address and the reason',
  (select v from ec_r where k = 'failed') || '/' ||
  (select count(*) || '/' || bool_and(body like 'renter_offer_ready to ec1_04@example.test: Resend 422: invalid address%' and entity = 'notification_outbox')
     from notifications where code = 'staff_email_failed' and user_id = test.id('ec_admin')), 'failed/1/true');
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key, status, attempts)
values ('renter_review_request', 'marketing', 5, 'renter', 'ecm@example.test', '{}', 'eccap:mkt', 'sending', 3);
select app.outbox_mark_failed(id, 'timeout', false, test.ec_at('2032-03-02 12:05')) from notification_outbox where dedupe_key = 'eccap:mkt';
select test.eq('failure: a marketing email that fails tells nobody',
  (select status from notification_outbox where dedupe_key = 'eccap:mkt') || '/' ||
  (select count(*) from notifications where code = 'staff_email_failed' and user_id = test.id('ec_admin')), 'failed/1');

-- ================================================================ 6. the day's use
select test.eq('usage: total, sign-in emails, cap, warning point and held count in one object',
  (select (u ->> 'auth') || '/' || (u ->> 'cap') || '/' || (u ->> 'warn_at') || '/' || ((u ->> 'held')::int >= 5) || '/' || ((u ->> 'total')::int = (u ->> 'outbox')::int + (u ->> 'auth')::int)
     from (select app.email_usage(test.ec_at('2032-03-02 12:10')) u) x), '2/10/8/true/true');
delete from program_settings where effective_from = date '2032-03-01';
select test.eq('dashboard: Admin > Today carries the day''s use and an alert for the emails that failed today',
  (select (d ? 'email') || '/' || ((d -> 'email' ->> 'cap')::int = 100) || '/' ||
          exists (select 1 from jsonb_array_elements(d -> 'alerts') a where a ->> 'field' = 'email' and a ->> 'message' like '%failed today%')
     from (select app.admin_dashboard(test.id('ec_admin')) d) x), 'true/true/true');

select test.eq('dashboard: Admin > Email reads the same use through the Admin door',
  (select (u ? 'total') and (u ? 'held') and (u ->> 'cap')::int = 100 from (select app.admin_read(test.id('ec_admin'), 'email_usage') u) x), true);

-- ================================================================ 7. privileges
select test.eq('privileges: only the server may defer, fail or read the usage',
  (select bool_or(has_function_privilege('authenticated', p, 'execute')) || '/' || bool_and(has_function_privilege('service_role', p, 'execute'))
     from unnest(array['app.outbox_defer(uuid,text,timestamptz,timestamptz)', 'app.outbox_mark_failed(uuid,text,boolean,timestamptz)',
                       'app.email_usage(timestamptz)', 'app.auth_emails_today(timestamptz)']::regprocedure[]) p), 'false/true');

drop table auth.users;
update notification_outbox set status = 'sent', sent_at = timestamptz '2020-01-01 12:00+00' where dedupe_key like 'eccap:%' and status in ('queued', 'delayed', 'sending');
