-- 99: Cloudflare email first (1750, the owner's rule of 2026-11-11). Sending whenever Cloudflare sent in the last 48 hours;
-- a problem only without such a send, with the real reason. Each Toronto day Cloudflare sends first up to its daily
-- budget (100), never past the month's included 3,000; then Resend's free 100; when both are used the emails wait by
-- priority. No hourly hold, never a paid send. Fixtures start with "cff"; every address is example.test.
select test.suite('99 r35 email cloudflare first');

update program_settings set cf_email_enabled = true, cf_email_monthly_included = 3000, cf_email_daily_budget = 100,
                            notify_daily_cap = 300, notify_cf_daily_budget = 200, notify_resend_daily_budget = 100, notify_class_limits = '{97,95,90,80,60}';
select test.eq('Cloudflare''s daily budget is 100 by default (3,000 a month spread over the month)',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'cf_email_daily_budget'), '100');
select test.eq('no paid sending setting exists', (select count(*) from information_schema.columns where table_name = 'program_settings' and column_name like '%paid_ok%'), 0::bigint);
create temp table cff_code as select code from notification_catalogue where audience = 'renter' and has_email and is_enabled and category = 'transactional'
  and code not like '%reminder%' order by code limit 1;
-- every other email of the earlier suites out of the way (a far day of their own), their Cloudflare and Resend sends uncounted
create temp table cff_others as select id, send_after, status, status_reason from notification_outbox where status in ('queued', 'delayed');
update notification_outbox o set send_after = timestamptz '2035-01-01' from cff_others e where e.id = o.id;
create temp table cff_sent0 as select id, provider_id, sent_at from notification_outbox where status = 'sent' and sent_at > now() - interval '40 days';
update notification_outbox set sent_at = sent_at - interval '400 days' where id in (select id from cff_sent0);
create or replace function test.cff_sent(p_key text, p_provider text, p_at timestamptz, p_reason text default null) returns void language sql as $$
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, status_reason, sent_at, provider_id, send_after)
  select code, 'transactional', 1, 'renter', 'cff@example.test', 'Cff', '{}'::jsonb, 'cff-' || p_key, 'sent', p_reason, p_at, p_provider, p_at from cff_code $$;
create or replace function test.cff_queue(p_key text, p_priority integer) returns void language sql as $$
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, send_after)
  select code, 'transactional', p_priority, 'renter', 'cff.' || p_key || '@example.test', 'Cff', '{}'::jsonb, 'cff-q-' || p_key, 'queued', now() - interval '1 minute' from cff_code $$;
-- the sender: claim and send, through Cloudflare while it may (as send-outbox decides), else Resend
create or replace function test.cff_run(p_limit integer) returns integer language plpgsql as $$
declare v_cf boolean := app.cf_email_try(); v_ids uuid[];
begin
  select array_agg(c.id) into v_ids from app.outbox_claim(p_limit, now()) c;
  update notification_outbox o set status = 'sent', sent_at = now(), provider_id = case when v_cf then 'cf:' else 're_' end || o.id where o.id = any (coalesce(v_ids, '{}'));
  return coalesce(array_length(v_ids, 1), 0);
end $$;

-- ================================================================ 1. the status
-- the live case: the provider row without a success, an old binding refusal on it, and Cloudflare sending anyway
update email_provider_state set cf_ok_at = null, cf_failed_at = now() - interval '3 days', cf_error = 'Cloudflare 503: no EMAIL binding on the Worker (Email Service not set up)';
select test.cff_sent('s1', 'cf:cff-1', now() - interval '2 hours');
select test.eq('a Cloudflare send in the last 48 hours: sending, no reason, no setup steps',
  (select format('%s|%s', c ->> 'state', coalesce(c ->> 'reason', 'none')) from (select app.cf_email_setup() c) x), 'ok|none');
select test.eq('the pace read says the same', (select format('%s|%s', p ->> 'cf_state', p ->> 'cf_counted') from (select app.email_pace() p) x), 'ok|true');
select test.eq('the banner rows carry the same state', app.cf_email_counted(), true);
select test.ok('a lone refusal 15 minutes ago does not make it "not sending" while Cloudflare sent today',
  (select app.cf_email_setup() ->> 'state' = 'ok' from (select app.server_cf_email_result('{"ok": false, "error": "Cloudflare 502: busy"}')) z));

-- no send in 48 hours, the binding missing: a problem, with Cloudflare's own words
update notification_outbox set sent_at = now() - interval '3 days' where dedupe_key = 'cff-s1';
update email_provider_state set cf_ok_at = null, cf_failed_at = now() - interval '1 hour', cf_error = 'Cloudflare 503: no EMAIL binding on the Worker (Email Service not set up)';
select test.eq('no send in 48 hours, binding missing: absent', app.cf_email_setup() ->> 'state', 'absent');
select test.ok('the reason quotes Cloudflare''s error', (app.cf_email_setup() ->> 'reason') ilike '%EMAIL binding%Cloudflare said: Cloudflare 503%');
update email_provider_state set cf_error = 'Cloudflare 502: sender domain not verified';
select test.eq('another refusal: failing, with that error', (select format('%s|%s', c ->> 'state', c ->> 'reason') from (select app.cf_email_setup() c) x),
  'failing|Cloudflare refused the last email: Cloudflare 502: sender domain not verified');
-- the provider row gone (as live): the sender's next result puts it back
delete from email_provider_state;
select test.ok('a success with no provider row recreates it', (app.server_cf_email_result('{"ok": true}') ->> 'cf_ok_at') is not null);
select test.eq('and the status is sending', app.cf_email_setup() ->> 'state', 'ok');
update program_settings set cf_email_enabled = false;
select test.ok('switched off: off, and says so', (select c ->> 'state' = 'off' and c ->> 'reason' ilike '%turned off%' from (select app.cf_email_setup() c) x));
update program_settings set cf_email_enabled = true;

-- ================================================================ 2. Cloudflare's day: 100, no hourly hold
update email_provider_state set cf_ok_at = now() - interval '1 hour', cf_failed_at = null, cf_error = null;
delete from notification_outbox where dedupe_key like 'cff-%';
select test.cff_queue('d' || g, 2) from generate_series(1, 130) g;
select test.eq('the first run of the minute takes 50 through Cloudflare', test.cff_run(50), 50);
select test.eq('the next takes the other 50 of Cloudflare''s day at once (no hourly hold)', test.cff_run(80), 50);
select test.eq('100 through Cloudflare today', (select count(*) from notification_outbox where dedupe_key like 'cff-q-d%' and provider_id like 'cf:%'), 100::bigint);
select test.eq('Cloudflare''s day is used: none left, the sender goes to Resend', format('%s|%s', app.cf_email_left(), app.cf_email_try()), '0|f');
select test.eq('the sender''s budget says the same', (public.server_email_budgets() ->> 'cf_left')::integer, 0);
select test.eq('the 101st email of the day goes through Resend', (select test.cff_run(1)), 1);
select test.ok('it is a Resend send', (select count(*) = 1 from notification_outbox where dedupe_key like 'cff-q-d%' and provider_id like 're_%'));
select test.eq('the rest go through Resend at once too (no hourly hold)', test.cff_run(50), 29);
select test.eq('Settings > Usage: Cloudflare 100 of 100, Resend 30 of 100',
  (select format('%s of %s|%s of %s', p ->> 'cf_today', p ->> 'cf_day_budget', p ->> 'resend_today', p ->> 'resend_day_budget') from (select app.email_pace() p) x), '100 of 100|30 of 100');

-- ================================================================ 3. both used: held by priority
select test.cff_sent('r' || g, 're_cff' || g, now()) from generate_series(1, 60) g;
-- Resend 90 today: a low-priority email waits, a booking email goes
select test.cff_queue('low1', 5);
select test.cff_queue('book1', 1);
select test.eq('the 191st: the booking email goes, the low-priority one waits', test.cff_run(10), 1);
select test.eq('which one went, which waits', (select string_agg(dedupe_key || ':' || status || ':' || coalesce(status_reason, ''), ',' order by dedupe_key)
  from notification_outbox where dedupe_key in ('cff-q-low1', 'cff-q-book1')), 'cff-q-book1:sent:,cff-q-low1:delayed:daily email limit');
select test.cff_sent('r' || g, 're_cff' || g, now()) from generate_series(61, 69) g;
-- 100 + 100: both used, the booking email waits too, for tomorrow (Cloudflare has nothing left today)
select test.cff_queue('book2', 1);
select test.eq('the 201st: held, the booking email too once both are used', test.cff_run(10), 0);
select test.eq('it waits for the day''s limit', (select status || ':' || status_reason from notification_outbox where dedupe_key = 'cff-q-book2'), 'delayed:daily email limit');
select test.ok('until midnight, not 15 minutes', (select send_after > now() + interval '15 minutes' or send_after = app.local_midnight(app.local_date(now()) + 1)
  from notification_outbox where dedupe_key = 'cff-q-book2'));

-- ================================================================ 4. the month is never exceeded
delete from notification_outbox where dedupe_key like 'cff-%';
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, sent_at, provider_id, send_after)
select c.code, 'transactional', 1, 'renter', 'cff.m' || g || '@example.test', 'Cff', '{}'::jsonb, 'cff-month-' || g, 'sent',
       app.local_midnight(app.month_start(app.local_date(now()))) + make_interval(secs => g / 1000.0), 'cf:cff-m' || g, now()
  from cff_code c, generate_series(1, 2990) g where app.local_date(now()) > app.month_start(app.local_date(now()));
-- (on the 1st of the month the 2,990 would be today's: the month check below then reads its own day)
select test.ok('2,990 sent this month: Cloudflare has 10 left, not its day''s 100',
  app.local_date(now()) = app.month_start(app.local_date(now())) or app.cf_email_left() = 10);
select test.cff_queue('m' || g, 2) from generate_series(1, 30) g;
select test.cff_run(50);
select test.ok('never past 3,000', app.cf_emails_month() <= 3000);
select test.ok('at 3,000 the sender does not try Cloudflare', app.local_date(now()) = app.month_start(app.local_date(now())) or app.cf_email_try() = false);
select test.cff_run(5);
select test.ok('the 3,001st goes through Resend, not Cloudflare',
  app.local_date(now()) = app.month_start(app.local_date(now()))
  or (app.cf_emails_month() = 3000 and (select count(*) from notification_outbox where dedupe_key like 'cff-q-m%' and provider_id like 're_%') = 5));
select test.ok('Settings > Usage shows the month against 3,000', (select (p ->> 'cf_included')::integer = 3000 and (p ->> 'cf_month')::integer <= 3000 from (select app.email_pace() p) x));
delete from notification_outbox where dedupe_key like 'cff-%';

-- ================================================================ 5. within Cloudflare's day, Resend only after a Cloudflare error
update email_provider_state set cf_ok_at = now(), cf_failed_at = null, cf_error = null;
select test.cff_sent('s1', 'cf:cff-1', now());
select test.eq('Cloudflare working: the sender tries Cloudflare', app.cf_email_try(), true);
select app.server_cf_email_result('{"ok": false, "error": "Cloudflare 502: upstream timeout"}');
select test.eq('after a Cloudflare error: Resend (Cloudflare rests 15 minutes)', app.cf_email_try(), false);
select test.eq('and back after the rest', app.cf_email_try(now() + interval '16 minutes'), true);
select test.cff_sent('r1', 're_cff1', now());
select app.outbox_note_cf_fallback((select id from notification_outbox where dedupe_key = 'cff-s1'), 'Cloudflare 502: upstream timeout');
select app.outbox_note_cf_fallback((select id from notification_outbox where dedupe_key = 'cff-r1'), 'Cloudflare 502: upstream timeout');
select test.eq('an email Resend sent after the error says why', (select status_reason from notification_outbox where dedupe_key = 'cff-r1'),
  'sent through Resend after a Cloudflare error: Cloudflare 502: upstream timeout');
select test.eq('the note goes on a Resend email only, never a Cloudflare one',
  (select count(*) from notification_outbox where dedupe_key = 'cff-s1' and status_reason is not null), 0::bigint);
select test.eq('Settings > Usage counts it', (app.email_pace() ->> 'fallback_today')::integer, 1);
update email_provider_state set cf_ok_at = now(), cf_failed_at = null, cf_error = null;
select test.eq('no error, under the month: Cloudflare', app.cf_email_try(), true);

-- ================================================================ 6. release of the held emails
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, status_reason, send_after)
select code, 'transactional', 2, 'renter', 'cff.h' || r || '@example.test', 'Cff', '{}'::jsonb, 'cff-hold-' || r, 'delayed', r, now() + interval '8 hours'
  from cff_code, unnest(array['daily email limit', 'paced across the day', 'outside the marketing hours']) r;
select test.ok('it releases', app.email_release_held() >= 2);
select test.eq('the pace and the old caps release; marketing hours stay', (select count(*) from notification_outbox where dedupe_key like 'cff-hold-%' and status = 'queued'), 2::bigint);
select test.eq('the one left is the marketing hours', (select string_agg(status_reason, ',') from notification_outbox where dedupe_key like 'cff-hold-%' and status = 'delayed'), 'outside the marketing hours');

-- ================================================================ roles
select test.eq('the sender''s functions are the server''s only',
  has_function_privilege('authenticated', 'app.email_release_held(timestamptz)', 'execute') or has_function_privilege('authenticated', 'public.server_outbox_note_cf_fallback(uuid, text)', 'execute')
  or has_function_privilege('anon', 'public.server_email_budgets()', 'execute') or has_function_privilege('authenticated', 'app.cf_email_try(timestamptz)', 'execute'), false);
select test.eq('an Admin reads the status through the door only', has_function_privilege('authenticated', 'app.cf_email_setup(timestamptz)', 'execute'), false);

-- back as the suites expect (helpers.sql: Cloudflare off)
delete from notification_outbox where dedupe_key like 'cff-%';
update notification_outbox o set sent_at = c.sent_at from cff_sent0 c where c.id = o.id;
update notification_outbox o set send_after = e.send_after, status = e.status, status_reason = e.status_reason from cff_others e where e.id = o.id;
update program_settings set cf_email_enabled = false;
