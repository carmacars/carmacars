-- 99: email volume (migration 0583): one daily cap for every provider, at most the even pace plus 30 an hour whatever is
-- released at once, and staff alerts in one digest per person (urgent ones on their own, 3 an hour at most).
-- Fixtures start with "ev"; every address is example.test.
select test.suite('99 email volume');

-- ================================================================ the daily cap
select test.eq('Cloudflare has never sent: the cap is Resend''s 100', (select case when app.cf_email_ever_sent() then -1 else app.email_day_cap() end), 100);
create temp table ev_code as select code from notification_catalogue where audience = 'renter' and has_email and is_enabled and category = 'transactional' order by code limit 1;
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, sent_at, provider_id, send_after)
select code, 'transactional', 1, 'renter', 'ev.cf@example.test', 'Ev Cf', '{}'::jsonb, 'ev-cf-sent', 'sent', now() - interval '3 days', 'cf:ev-test', now() - interval '3 days' from ev_code;
-- the providers' budgets as shipped (an earlier test file may have left a dated settings row with other values)
update program_settings set notify_daily_cap = 300, notify_cf_daily_budget = 200, notify_resend_daily_budget = 100;
-- 0900: Cloudflare's budget counts while Cloudflare Email Service is switched on (off for the suites, helpers.sql)
update program_settings set cf_email_enabled = true;
select test.eq('once Cloudflare has sent: 300 (the setting, within the providers'' 200 + 100)', app.email_day_cap(), 300);
update program_settings set notify_daily_cap = 250;
select test.eq('the Admin setting lowers it', app.email_day_cap(), 250);
update program_settings set notify_daily_cap = 300;
select test.eq('the pace: 300 a day, at most 13 + 30 an hour', (select (p ->> 'day_cap') || '/' || (p ->> 'hour_cap') from (select app.email_pace() p) x), '300/43');

-- ================================================================ 300 held emails released at once spread out
-- a day of its own (far ahead), every other email of the suite already gone
create temp table ev_others as select id, send_after from notification_outbox where status in ('queued', 'delayed');
update notification_outbox o set send_after = timestamptz '2035-01-01' from ev_others e where e.id = o.id;
create temp table ev_t as select (date '2031-03-04' + time '09:00') at time zone 'America/Toronto' as t0;
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, status_reason, send_after)
select c.code, 'transactional', 1 + (g % 3), 'renter', 'ev.r' || g || '@example.test', 'Ev ' || g, '{}'::jsonb, 'ev-held-' || g, 'delayed', 'daily email limit', (select t0 from ev_t) - interval '1 hour'
  from ev_code c, generate_series(1, 300) g;
create temp table ev_hours (h integer, n integer);
do $$
declare h integer; v_now timestamptz; n integer; v_ids uuid[];
begin
  for h in 0..11 loop
    v_now := (select t0 from ev_t) + make_interval(hours => h);
    -- the sender runs every minute: four runs of 50 within the hour, sent by Cloudflare (Resend's own cap of 0018 does
    -- not hold them: only the day's cap and the hour's pace do)
    for k in 0..3 loop
      select array_agg(c.id) into v_ids from app.outbox_claim(50, v_now + make_interval(mins => k * 15)) c;
      update notification_outbox o set status = 'sent', sent_at = v_now + make_interval(mins => k * 15), provider_id = 'cf:ev-' || o.id where o.id = any (coalesce(v_ids, '{}'));
    end loop;
    select count(*) into n from notification_outbox where dedupe_key like 'ev-held-%' and status = 'sent' and sent_at >= v_now and sent_at < v_now + interval '1 hour';
    insert into ev_hours values (h, n);
  end loop;
end $$;
select test.ok('no hour sends more than 43 (300 released at once)', (select max(n) <= 43 from ev_hours), (select string_agg(n::text, ',' order by h) from ev_hours));
select test.ok('they still go out, hour after hour', (select count(*) >= 6 from ev_hours where n > 0));
select test.eq('none failed; the rest wait', (select count(*) from notification_outbox where dedupe_key like 'ev-held-%' and status = 'failed'), 0::bigint);
select test.ok('the first hours went to customers first (priority 1 before 2 and 3)',
  (select min(sent_at) from notification_outbox where dedupe_key like 'ev-held-%' and priority = 1) <= (select min(sent_at) from notification_outbox where dedupe_key like 'ev-held-%' and priority = 3));

update notification_outbox o set send_after = e.send_after from ev_others e where e.id = o.id;

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
select test.eq('Cloudflare switched off: only Resend''s budget counts', app.email_day_cap(), (select least(s.notify_daily_cap, s.notify_resend_daily_budget) from app.settings_base(app.local_date(now())) s));
