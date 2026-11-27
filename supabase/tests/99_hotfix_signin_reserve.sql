-- 99: hotfix of November 23 2026 (migration 3410): the daily email reserve, the sign-in text and email-limit alerts, the
-- sign-in page's sms_ok, and an Admin's coverage approval by hand (BR-3). Fixtures start with "hfs".
select test.suite('99 hotfix sign-in and email reserve');

-- ---------------------------------------------------------------- the classes
select test.eq('the email classes: alerts, booking and account email, owners, and what can wait',
  app.email_class('staff_site_alert', 'transactional', 3) || ',' || app.email_class('renter_offer_ready', 'transactional', 1) || ',' ||
  app.email_class('owner_fee_invoice', 'transactional', 2) || ',' || app.email_class('applicant_referred', 'transactional', 2) || ',' ||
  app.email_class('staff_digest_hourly', 'transactional', 4) || ',' || app.email_class('marketing_weekly', 'marketing', 5) || ',' ||
  app.email_class('renter_offer_reminder', 'transactional', 1),
  'alert,top,mid,low,low,low,low');

-- ---------------------------------------------------------------- the reserve
create temp table hfs_ps as select id, notify_daily_cap, notify_resend_daily_budget, email_low_class_stop_pct, email_auth_reserve, email_reserve_from_cap, notify_count_auth_emails from program_settings;
-- a small day: 20 emails (no SES, no Cloudflare), the sign-in service's reserve 2, low classes stop at 60%
update program_settings set notify_daily_cap = 20, notify_resend_daily_budget = 20, email_low_class_stop_pct = 60, email_auth_reserve = 2,
  email_reserve_from_cap = 10, notify_count_auth_emails = false;
-- what other files left waiting is set aside for this file and put back at its end (later files count on it)
create temp table hfs_waiting as select id, status, status_reason, send_after, locked_at from notification_outbox where status in ('queued', 'delayed', 'sending');
update notification_outbox set status = 'skipped', status_reason = 'hfs: set aside' where id in (select id from hfs_waiting);
-- the day starts empty: what earlier files sent today counts as sent two days ago
create temp table hfs_today as select id, sent_at from notification_outbox where status = 'sent' and sent_at >= app.local_midnight(app.local_date(now()));
update notification_outbox set sent_at = now() - interval '2 days' where id in (select id from hfs_today);
select test.eq('the day''s cap for the test is 20', app.email_day_cap(now()), 20);
select test.eq('with email_reserve_from_cap at 10 the reserve is on for this 20-email day',
  (select (app.email_reserve(now()) ->> 'on') from (select 1) x), 'true');
-- 12 already sent today: the low classes are at their stop (60% of 20)
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key, status, sent_at, channel)
select 'renter_offer_ready', 'transactional', 1, 'renter', 'hfs_sent' || g || '@example.test', '{}', 'hfs:sent:' || g, 'sent', now() - interval '1 minute', 'email'
  from generate_series(1, 12) g;
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key, channel) values
  ('applicant_referred', 'transactional', 2, 'applicant', 'hfs_low@example.test', '{}', 'hfs:low', 'email'),
  ('renter_offer_ready', 'transactional', 1, 'renter', 'hfs_top@example.test', '{}', 'hfs:top', 'email');
create temp table hfs_claimed as select c.code from app.outbox_claim(20, now()) c;
select test.eq('at 60% of the cap a hiring email waits for the reserve...',
  (select status || ':' || status_reason from notification_outbox where dedupe_key = 'hfs:low'), 'delayed:held for booking and sign-in email (daily reserve)');
select test.ok('...and is due again within 20 minutes, never past midnight',
  (select send_after <= now() + interval '20 minutes' from notification_outbox where dedupe_key = 'hfs:low'));
select test.ok('...while the booking email is not held by the reserve',
  (select coalesce(status_reason, '') <> 'held for booking and sign-in email (daily reserve)' from notification_outbox where dedupe_key = 'hfs:top'));
-- booking email stops 2 short of the cap (the sign-in service's own emails)
update notification_outbox set status = 'sent', sent_at = now(), locked_at = null, status_reason = null where dedupe_key = 'hfs:top';
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key, status, sent_at, channel)
select 'renter_offer_ready', 'transactional', 1, 'renter', 'hfs_more' || g || '@example.test', '{}', 'hfs:more:' || g, 'sent', now() - interval '1 minute', 'email'
  from generate_series(1, 5) g;
insert into notification_outbox (code, category, priority, audience, to_address, payload, dedupe_key, channel) values
  ('renter_offer_ready', 'transactional', 1, 'renter', 'hfs_top2@example.test', '{}', 'hfs:top2', 'email');
select count(*) from app.outbox_claim(20, now());
select test.eq('at 18 of 20 a booking email waits too: the last 2 are kept for sign-in',
  (select status from notification_outbox where dedupe_key = 'hfs:top2'), 'delayed');
select test.eq('...and the email-limit site check fails', (select app.uptime_internal(now()) ->> 'email_full'), 'true');
select test.eq('...an open alert for it', (select count(*) from site_alerts where check_key = 'email_cap' and resolved_at is null), 1::bigint);
-- more room (SES or Cloudflare switched on): the held emails go at once
update program_settings set notify_daily_cap = 100, notify_resend_daily_budget = 100;
select count(*) from app.outbox_claim(20, now());
select test.eq('with room again the held emails are sent at once, the hiring one included',
  (select string_agg(status, ',' order by dedupe_key) from notification_outbox where dedupe_key in ('hfs:low', 'hfs:top2')), 'sending,sending');
select app.uptime_internal(now());
select test.eq('...and the email-limit alert closes', (select count(*) from site_alerts where check_key = 'email_cap' and resolved_at is null), 0::bigint);

-- ---------------------------------------------------------------- sign-in texts
delete from app.auth_sms_log where true;
select test.eq('no failed texts: texts work', (app.sms_signin_failing() ->> 'failing') || '/' || (public.server_email_capped() ->> 'sms_ok'), 'false/true');
insert into app.auth_sms_log (phone, status, reason, created_at)
select '+16475550' || (100 + g), 'failed', 'Quo 402: not enough prepaid credits', now() - make_interval(mins => g) from generate_series(1, 3) g;
select test.eq('3 failed in a row: failing, and the sign-in page is told texts do not work',
  (app.sms_signin_failing() ->> 'failing') || '/' || (public.server_email_capped() ->> 'sms_ok'), 'true/false');
select app.uptime_internal(now());
select test.eq('...an open alert for it', (select count(*) from site_alerts where check_key = 'sms_signin' and resolved_at is null), 1::bigint);
select test.ok('...which the site check raises at once (Admin To do and the alert email, like the backup check)',
  position('''sms_signin'', ''email_cap''' in pg_get_functiondef('app.uptime_notify(timestamptz)'::regprocedure)) > 0);
insert into app.auth_sms_log (phone, status, created_at) values ('+16475550200', 'sent', now());
select test.eq('one text sent: texts work again', app.sms_signin_failing() ->> 'failing', 'false');

-- ---------------------------------------------------------------- BR-3: coverage approved by hand
select test.mk_user('hfs_admin', 'admin');
select test.mk_user('hfs_cs', 'va', 'cs');
select test.mk_owner('hfs_olive');
select test.mk_vehicle('hfs_car', 'hfs_olive');
select test.mk_renter('hfs_rena');
select test.mk_booking('HFS-1', 'hfs_car', 'hfs_rena', test.fut('2026-12-20 10:00'), test.fut('2026-12-22 10:00'), 'pending_payment', 20000);
update bookings set coverage_option = 1, coverage_confirmed_at = null where id = test.id('booking:HFS-1');
select test.throws('only an Admin approves coverage by hand',
  format('select app.coverage_confirm_admin(%L, %L)', test.id('hfs_cs'), jsonb_build_object('booking', test.id('booking:HFS-1'), 'reason', 'Checked by email')), 'Only an Admin');
select test.throws('a reason is needed',
  format('select app.coverage_confirm_admin(%L, %L)', test.id('hfs_admin'), jsonb_build_object('booking', test.id('booking:HFS-1'))), 'Say why');
select test.throws('own policy: the policy details are needed',
  format('select app.coverage_confirm_admin(%L, %L)', test.id('hfs_admin'), jsonb_build_object('booking', test.id('booking:HFS-1'), 'reason', 'Checked by email')), 'Give the insurer');
select test.eq('the OPCF 27 pages are missing before', cardinality(app.opcf27_missing(test.id('booking:HFS-1'))) > 0, true);
select app.coverage_confirm_admin(test.id('hfs_admin'), jsonb_build_object('booking', 'HFS-1', 'reason', 'The renter emailed the policy; OPCF 27 checked',
  'insurer_name', 'Intact', 'policy_number', 'P-123', 'policy_expiry', '2027-06-30'));
select test.eq('approved by hand: the booking''s coverage is confirmed with a confirmed proof',
  (select (b.coverage_confirmed_at is not null)::text || '/' || cp.status || '/' || cp.policy_number from bookings b join coverage_proofs cp on cp.booking_id = b.id
    where b.id = test.id('booking:HFS-1')), 'true/confirmed/P-123');
select test.eq('...so the pay page no longer asks for the insurance pages', cardinality(app.opcf27_missing(test.id('booking:HFS-1'))), 0);
select test.eq('...the history says it was by hand, with the reason',
  (select count(*) from booking_events e where e.booking_id = test.id('booking:HFS-1') and e.note like 'Coverage approved by hand by an Admin: The renter emailed%'), 1::bigint);
select test.eq('...and the audit log has it', (select count(*) from audit_log where action = 'coverage_confirmed_by_hand' and entity_id = test.id('booking:HFS-1')::text), 1::bigint);
select test.eq('the door routes it (ops_do coverage_confirm_admin), for an Admin only',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'door_pre3410'), 1::bigint);
select test.eq('no browser role calls the new functions',
  (select count(*) from unnest(array['app.coverage_confirm_admin(uuid, jsonb)', 'app.email_reserve(timestamptz)', 'app.sms_signin_failing(timestamptz)']) f,
          unnest(array['anon', 'authenticated']) r where has_function_privilege(r, f::regprocedure, 'execute')), 0::bigint);

select app.uptime_record('sms_signin', true); select app.uptime_record('email_cap', true);
update notification_outbox set sent_at = now() - interval '3 days' where dedupe_key like 'hfs:%' and sent_at is not null;
-- leave nothing waiting for the files after this one (the alert emails this file caused, its own test emails)
update notification_outbox set status = 'skipped', status_reason = 'hfs: cleared'
 where status in ('queued', 'delayed', 'sending') and (dedupe_key like 'hfs:%' or code in ('staff_site_alert', 'staff_site_recovered'));
update notification_outbox o set status = w.status, status_reason = w.status_reason, send_after = w.send_after, locked_at = w.locked_at
  from hfs_waiting w where w.id = o.id;
update notification_outbox o set sent_at = t.sent_at from hfs_today t where t.id = o.id;
update program_settings p set notify_daily_cap = h.notify_daily_cap, notify_resend_daily_budget = h.notify_resend_daily_budget,
  email_low_class_stop_pct = h.email_low_class_stop_pct, email_auth_reserve = h.email_auth_reserve, email_reserve_from_cap = h.email_reserve_from_cap, notify_count_auth_emails = h.notify_count_auth_emails from hfs_ps h where h.id = p.id;
