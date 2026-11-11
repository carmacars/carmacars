-- 99: email volume (migration 0583, 1750): the day's budgets (Cloudflare's, then Resend's), no hourly pace (1750), and staff alerts in one digest per person (urgent ones on their own, 3 an hour at most).
-- Fixtures start with "ev"; every address is example.test.
select test.suite('99 email volume');

-- ================================================================ the daily cap (1750: Cloudflare's day, then Resend's)
create temp table ev_code as select code from notification_catalogue where audience = 'renter' and has_email and is_enabled and category = 'transactional' order by code limit 1;
-- the providers' budgets as shipped (an earlier test file may have left a dated settings row with other values)
update program_settings set notify_daily_cap = 300, cf_email_daily_budget = 100, notify_resend_daily_budget = 100, cf_email_monthly_included = 3000;
select test.eq('Cloudflare switched off (the suites): Resend''s 100', app.email_day_cap(), 100);
-- 0900: switched on for this file (off for the suites, helpers.sql)
update program_settings set cf_email_enabled = true;
update email_provider_state set cf_failed_at = null, cf_error = null;
create temp table ev_cfmonth as select id from notification_outbox where provider_id like 'cf:%' and sent_at > now() - interval '40 days';
update notification_outbox set sent_at = sent_at - interval '400 days' where id in (select id from ev_cfmonth);
select test.eq('switched on: Cloudflare''s 100 then Resend''s 100', app.email_day_cap(), 200);
update program_settings set notify_daily_cap = 50;
select test.eq('the Admin setting lowers Resend''s part', app.email_day_cap(), 150);
update program_settings set notify_daily_cap = 300;

-- ================================================================ 300 held emails released at once: the day's budgets, no hourly pace
-- a day of its own (far ahead), every other email of the suite already gone
create temp table ev_others as select id, send_after from notification_outbox where status in ('queued', 'delayed');
update notification_outbox o set send_after = timestamptz '2035-01-01' from ev_others e where e.id = o.id;
create temp table ev_t as select (date '2031-03-04' + time '09:00') at time zone 'America/Toronto' as t0;
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, status_reason, send_after)
select c.code, 'transactional', 1 + (g % 3), 'renter', 'ev.r' || g || '@example.test', 'Ev ' || g, '{}'::jsonb, 'ev-held-' || g, 'delayed', 'daily email limit', (select t0 from ev_t) - interval '1 hour'
  from ev_code c, generate_series(1, 300) g;
create temp table ev_hours (h integer, n integer);
do $$
declare h integer; v_now timestamptz; n integer; v_ids uuid[]; v_cf boolean;
begin
  for h in 0..2 loop
    v_now := (select t0 from ev_t) + make_interval(hours => h);
    -- the sender runs every minute: four runs of 50 within the hour, through Cloudflare while it may, else Resend
    for k in 0..3 loop
      v_cf := app.cf_email_try(v_now + make_interval(mins => k * 15));
      select array_agg(c.id) into v_ids from app.outbox_claim(50, v_now + make_interval(mins => k * 15)) c;
      update notification_outbox o set status = 'sent', sent_at = v_now + make_interval(mins => k * 15),
             provider_id = case when v_cf then 'cf:ev-' else 're_ev-' end || o.id where o.id = any (coalesce(v_ids, '{}'));
    end loop;
    select count(*) into n from notification_outbox where dedupe_key like 'ev-held-%' and status = 'sent' and sent_at >= v_now and sent_at < v_now + interval '1 hour';
    insert into ev_hours values (h, n);
  end loop;
end $$;
select test.eq('Cloudflare''s 100 go first', (select count(*) from notification_outbox where dedupe_key like 'ev-held-%' and provider_id like 'cf:%'), 100::bigint);
select test.ok('then Resend''s, no hourly pace: the first hour sends more than 43', (select n > 43 from ev_hours where h = 0), (select string_agg(n::text, ',' order by h) from ev_hours));
select test.ok('never more than the day''s two budgets', (select count(*) <= 200 from notification_outbox where dedupe_key like 'ev-held-%' and status = 'sent'));
select test.eq('none failed; the rest wait', (select count(*) from notification_outbox where dedupe_key like 'ev-held-%' and status = 'failed'), 0::bigint);
select test.ok('customers first (priority 1 before 3)',
  (select min(sent_at) from notification_outbox where dedupe_key like 'ev-held-%' and priority = 1) <= (select coalesce(min(sent_at), 'infinity') from notification_outbox where dedupe_key like 'ev-held-%' and priority = 3));
select test.ok('the low classes wait first once Resend''s part runs low',
  (select count(*) from notification_outbox where dedupe_key like 'ev-held-%' and priority = 3 and status <> 'sent')
  >= (select count(*) from notification_outbox where dedupe_key like 'ev-held-%' and priority = 1 and status <> 'sent'));

update notification_outbox o set send_after = e.send_after from ev_others e where e.id = o.id;
delete from notification_outbox where dedupe_key like 'ev-held-%';
update notification_outbox set sent_at = sent_at + interval '400 days' where id in (select id from ev_cfmonth);

-- ================================================================ staff inboxes
select test.mk_user('ev_admin', 'admin');
select test.mk_user('ev_quiet', 'admin');
update users set staff_email_digest = 'off' where id = test.id('ev_quiet');
create or replace function test.ev_staff(p_user text, p_code text, p_key text) returns text language sql as $$
  insert into notification_outbox (code, category, priority, audience, recipient_user_id, to_address, to_name, payload, dedupe_key, status, send_after)
  values (p_code, 'transactional', 3, 'staff_admin', test.id(p_user), p_user || '@example.test', 'Ev', jsonb_build_object('booking_number', 'EV-1', 'amount', '$10.00', 'vehicle_name', 'Ev car', 'review_rating', '5'),
          'ev-staff-' || p_key, 'queued', now())
  returning status || ':' || coalesce(status_reason, '') $$;
select test.eq('an alert that is not urgent goes into the digest, not an email', test.ev_staff('ev_admin', 'staff_review_received', 'r1'), 'skipped:in the staff email digest');
select test.eq('a payment declined goes at once', test.ev_staff('ev_admin', 'staff_payment_failed', 'p1'), 'queued:urgent');
select test.ev_staff('ev_admin', 'staff_payment_failed', 'p2');
select test.ev_staff('ev_admin', 'staff_payment_failed', 'p3');
select test.eq('a 4th urgent one in the hour joins the digest', test.ev_staff('ev_admin', 'staff_payment_failed', 'p4'), 'skipped:in the staff email digest');
select test.eq('the digest holds both, with their lines', (select count(*) || ':' || bool_and(line <> '') from staff_email_digest_items where user_id = test.id('ev_admin') and digested_at is null), '2:true');
select test.ok('one digest email for the person', app.staff_email_digests(now()) >= 1);
select test.ok('it carries the mailing address every email shows', (select payload ? 'company_address' from notification_outbox where code = 'staff_digest_hourly' and recipient_user_id = test.id('ev_admin')));
select test.eq('it is queued with the two alerts', (select (payload ->> 'digest_count') || ':' || status from notification_outbox where code = 'staff_digest_hourly' and recipient_user_id = test.id('ev_admin')), '2:queued');
select test.ev_staff('ev_admin', 'staff_review_received', 'r2');
select app.staff_email_digests(now() + interval '10 minutes');
select test.eq('within the hour: no second digest', (select count(*) from notification_outbox where code = 'staff_digest_hourly' and recipient_user_id = test.id('ev_admin')), 1::bigint);
select app.staff_email_digests(now() + interval '61 minutes');
select test.eq('an hour later: the next one', (select count(*) from notification_outbox where code = 'staff_digest_hourly' and recipient_user_id = test.id('ev_admin')), 2::bigint);
select test.ev_staff('ev_quiet', 'staff_review_received', 'q1');
select app.staff_email_digests(now());
select test.ok('Off: no digest email, the alert is marked done (in-app and phone only)',
  not exists (select 1 from notification_outbox where code = 'staff_digest_hourly' and recipient_user_id = test.id('ev_quiet'))
  and not exists (select 1 from staff_email_digest_items where user_id = test.id('ev_quiet') and digested_at is null));
select test.throws('the choice is hourly, daily or off', format($$select app.door(%L, 'aal2', 'admin_do', 'my_staff_digest_save', '{"digest": "weekly"}')$$, test.id('ev_admin')), 'Hourly digest');
select test.eq('the person sets it', (app.door(test.id('ev_admin'), 'aal2', 'admin_do', 'my_staff_digest_save', '{"digest": "daily"}') ->> 'digest'), 'daily');

-- ================================================================ staff emails in plain words (C4)
select test.mk_owner('ev_olga');
select test.mk_user('ev_fin', 'va', 'finance');
select test.mk_user('ev_sales', 'va', 'sales');
create or replace function test.ev_debit(p_kind text, p_reason text default null) returns jsonb language plpgsql as $$
declare v bigint := app.ntf_emit('staff_owner_debit_exception', 'owner', test.id('owner:ev_olga'), 'ev-' || p_kind || '-' || coalesce(p_reason, ''),
                                 jsonb_build_object('owner_id', test.id('owner:ev_olga'), 'exception', p_kind, 'reason', p_reason));
begin
  return (select app.notification_payload('staff_owner_debit_exception', e, '{}'::jsonb) from app_events e where e.id = v);
end $$;
create temp table ev_dx as select k, test.ev_debit(k, r) j from (values ('no_mandate', null), ('mandate_revoked', null), ('amount_changed', 'x'),
  ('returned', 'Account closed'), ('blocked', 'automatic debits are off in settings')) v(k, r);
select test.eq('the subject says what and why: no bank debit set up',
  (select app.render_text(c.subject, j) from ev_dx, notification_catalogue c where k = 'no_mandate' and c.code = 'staff_owner_debit_exception'), 'Can''t collect $0.00 from Ev Olga: no bank debit set up');
select test.eq('the reasons in the owner guide''s words', (select string_agg(j ->> 'reason_plain', ' | ' order by k) from ev_dx),
  'amount went up after the notice | automatic debits are turned off | owner cancelled the debit at their bank | no bank debit set up | the bank sent the payment back (account closed)');
select test.eq('one button that fixes it', (select string_agg(j ->> 'fix_label', ' | ' order by k) from ev_dx),
  'Send a new notice | Open Program settings | Send the sign-up link | Send the sign-up link | Open the invoice');
select test.ok('the sign-up button opens the Debits tab on that owner', (select j ->> 'fix_url' like '%/admin/owner-money?tab=debits&owner=' || test.id('owner:ev_olga') || '&fix=setup' from ev_dx where k = 'no_mandate'));
select test.ok('the body says what is happening in one sentence',
  (select app.render_text('We were going to take {{debit_total}} from {{owner_name}}''s bank on {{debit_date}} for {{debit_for}}, and we can''t: {{reason_plain}}.', j)
     like 'We were going to take $0.00 from Ev Olga''s bank on % for the open invoices, and we can''t: no bank debit set up.' from ev_dx where k = 'no_mandate'));
select test.ok('no staff email subject or preheader uses the system''s words',
  not exists (select 1 from notification_catalogue where code like 'staff\_%' and in_catalogue
                 and (subject || ' ' || coalesce(preheader, '')) ~* '\m(exception|mandate|outbox|fingerprint|webhook|run key)\M'));
-- the fix: the sign-up link again, by Finance or an Admin
select test.throws('Sales do not send it', format($$select app.door(%L, 'aal2', 'ops_do', 'owner_debit_setup_link', %L)$$, test.id('ev_sales'), jsonb_build_object('owner', test.id('owner:ev_olga'))), 'Finance or an Admin');
select test.eq('Finance sends the owner the sign-up link',
  (app.door(test.id('ev_fin'), 'aal2', 'ops_do', 'owner_debit_setup_link', jsonb_build_object('owner', test.id('owner:ev_olga'))) ->> 'message'), 'Sign-up link sent to Ev Olga');
select test.eq('the owner''s set-up email is on its way', (select count(*) from app_events where code = 'owner_debit_setup_needed' and entity_id = test.id('owner:ev_olga')), 1::bigint);
-- 0900: switched off, Cloudflare's budget does not count (and the suites after this one start with it off, helpers.sql)
update program_settings set cf_email_enabled = false;
select test.eq('Cloudflare switched off: only Resend''s budget counts', app.email_day_cap(), (select least(s.notify_daily_cap, s.notify_resend_daily_budget) + app.cf_emails_today() from app.settings_base(app.local_date(now())) s));
