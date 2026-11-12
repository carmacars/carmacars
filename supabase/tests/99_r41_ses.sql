-- 99: Amazon SES first (2570, release 41). SES sends first while the sender has its keys (seen in the last hour), the
-- Program setting email_ses_enabled is on and today's SES sends are under email_ses_daily_max (200 in the sandbox); then
-- Resend's free plan (Cloudflare only with email_cloudflare_enabled, off by default, 2600). SES's day adds to the day's
-- capacity; its sends never count as Resend's. Marketing never goes through SES unless email_ses_marketing is on (off by
-- default): the marketing allowance (2600) is Resend's free capacity less what booking email used of it through the
-- fallback. Fixtures start with "zses"; every address is example.test.
select test.suite('99 r41 Amazon SES first (2570), email route (2600)');

update program_settings set cf_email_enabled = false, email_cloudflare_enabled = false, notify_resend_daily_budget = 100, notify_daily_cap = 300;
create temp table zses_code as select code from notification_catalogue where audience = 'renter' and has_email and is_enabled and category = 'transactional'
  and code not like '%reminder%' order by code limit 1;
-- every other email of the earlier suites out of the way, and their sends of today on a far past day
create temp table zses_others as select id, send_after from notification_outbox where status in ('queued', 'delayed');
update notification_outbox o set send_after = timestamptz '2035-01-01' from zses_others e where e.id = o.id;
create temp table zses_sent0 as select id, sent_at, status, locked_at from notification_outbox
  where (status = 'sent' and sent_at > now() - interval '40 days') or status = 'sending';
update notification_outbox set sent_at = now() - interval '400 days', status = 'sent' where id in (select id from zses_sent0);
create or replace function test.zses_sent(p_key text, p_provider text) returns void language sql as $$
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, sent_at, provider_id, send_after)
  select code, 'transactional', 1, 'renter', 'zses@example.test', 'Zses', '{}'::jsonb, 'zses-' || p_key, 'sent', now(), p_provider, now() from zses_code $$;
create or replace function test.zses_queue(p_key text) returns void language sql as $$
  insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, send_after)
  select code, 'transactional', 2, 'renter', 'zses.' || p_key || '@example.test', 'Zses', '{}'::jsonb, 'zses-q-' || p_key, 'queued', now() - interval '1 minute' from zses_code $$;

-- ================================================================ settings
select test.eq('settings: SES on, 200 a day by default (the sandbox), never marketing by default',
  (select string_agg(column_name || '=' || column_default, ',' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('email_ses_enabled', 'email_ses_daily_max', 'email_ses_marketing')),
  'email_ses_daily_max=200,email_ses_enabled=true,email_ses_marketing=false');
update program_settings set email_ses_enabled = true, email_ses_daily_max = 200, email_ses_marketing = false;
select test.eq('2600: Cloudflare sending is off by default',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'email_cloudflare_enabled'), 'false');
update program_settings set cf_email_enabled = true;
select test.eq('2600: Cloudflare set up but email_cloudflare_enabled off: no budget, not tried, the banner says off',
  format('%s|%s|%s', app.cf_email_left(), app.cf_email_try(), app.cf_email_setup() ->> 'state'), '0|f|off');
update program_settings set cf_email_enabled = false;

-- ================================================================ without keys nothing changes
update email_provider_state set ses_seen_at = null, ses_ok_at = null, ses_failed_at = null, ses_error = null;
select test.eq('no SES keys seen: nothing left, not tried', format('%s|%s', app.ses_email_left(), app.ses_email_try()), '0|f');
select test.eq('no SES keys seen: the day''s capacity is Cloudflare''s and Resend''s as before', app.email_day_cap(), app.email_day_cap_pre2570());
update email_provider_state set ses_seen_at = now() - interval '2 hours';
select test.eq('keys seen over an hour ago: not tried', app.ses_email_left(), 0);

-- ================================================================ keys seen: SES first, 200 a day
create temp table zses_before as select app.email_day_cap_pre2570() cap0, app.marketing_daily_max() mkt0, app.outbox_sent_today() resend0;
select test.eq('the sender reports its keys: SES may send 200 today', (public.server_ses_email_result('{"seen": true}') ->> 'ses_left')::integer, 200);
select test.eq('the day''s capacity is SES''s 200 on top', app.email_day_cap() - (select cap0 from zses_before), 200);
select test.eq('2600: marketing stays off SES and Cloudflare: its allowance is Resend''s free capacity (100), none of it used by booking email yet',
  app.marketing_daily_max(), 100);
update program_settings set email_ses_marketing = true;
select test.eq('with email_ses_marketing on: SES''s day is added to it',
  app.marketing_daily_max(), 300);
select test.eq('and the sender is told', (public.server_email_budgets() ->> 'ses_marketing')::boolean, true);
update program_settings set email_ses_marketing = false;
select test.eq('off again: the sender keeps marketing off SES', (public.server_email_budgets() ->> 'ses_marketing')::boolean, false);
select test.zses_sent('s1', 'ses:0100abc');
select test.eq('an SES send counts against SES''s day', app.ses_email_left(), 199);
select test.eq('and never as Resend''s', app.outbox_sent_today(), (select resend0 from zses_before));
select test.eq('and it takes nothing off the marketing allowance', app.marketing_daily_max(), 100);
select test.zses_sent('f0', 're_zses_f0');
select test.eq('2600: a booking email Resend sent after an SES refusal takes one off the marketing allowance', app.marketing_daily_max(), 99);
delete from notification_outbox where dedupe_key = 'zses-f0';
select test.eq('the sender''s budgets', (select format('%s|%s|%s', b ->> 'ses_used', b ->> 'ses_left', b ->> 'resend_used') from (select public.server_email_budgets() b) x), '1|199|0');
select test.eq('Settings > Usage: SES 1 of 200, sending through SES, Resend 0',
  (select format('%s of %s|%s|%s', p ->> 'ses_today', p ->> 'ses_day_budget', p ->> 'limited_by', p ->> 'resend_today') from (select app.email_pace() p) x), '1 of 200|ses|0');
select test.eq('the booking page''s email box says SES', app.email_capacity() ->> 'limited_by', 'ses');

-- the claim: with Cloudflare off and Resend's day used, SES's turn still claims (at most what SES has left)
select test.zses_sent('r' || g, 're_zses' || g) from generate_series(1, 100) g;
select test.eq('2600: Resend''s day used by booking email leaves marketing nothing', app.marketing_daily_max(), 0);
select test.zses_queue('q' || g) from generate_series(1, 5) g;
update program_settings set email_ses_daily_max = 4;
select test.eq('SES''s turn: the claim takes what SES has left (3 of 5), Resend''s day used', (select count(*) from app.outbox_claim(20, now())), 3::bigint);
update notification_outbox set status = 'sent', sent_at = now(), provider_id = 'ses:zses-' || id where dedupe_key like 'zses-q-%' and status = 'sending';
select test.eq('SES''s day used: SES is not tried', format('%s|%s', app.ses_email_left(), app.ses_email_try()), '0|f');
select test.eq('the rest wait (Resend''s day is used too)', (select count(*) from app.outbox_claim(20, now())), 0::bigint);
update program_settings set email_ses_daily_max = 200;

-- an account-level refusal: SES rests 15 minutes
select public.server_ses_email_result('{"ok": false, "error": "SES 403 InvalidSignatureException: bad keys"}');
select test.eq('after an account-level refusal SES rests', format('%s|%s', app.ses_email_try(), app.email_pace() ->> 'ses_error'), 'f|SES 403 InvalidSignatureException: bad keys');
update email_provider_state set ses_failed_at = now() - interval '16 minutes';
select test.eq('after 15 minutes SES is tried again', app.ses_email_try(), true);
update program_settings set email_ses_enabled = false;
select test.eq('switched off in Program settings: not tried, nothing in the capacity', format('%s|%s', app.ses_email_try(), app.ses_email_left()), 'f|0');
update program_settings set email_ses_enabled = true;

-- ================================================================ the message and the fallback note
select test.zses_queue('m1');
update notification_outbox set status = 'sending', locked_at = now() where dedupe_key = 'zses-q-m1';
select app.outbox_mark_sent((select id from notification_outbox where dedupe_key = 'zses-q-m1'), 'ses:0100m1', 'text');
select test.eq('an SES send is recorded as provider ses', (select m.provider || '|' || m.provider_ref from messages m join notification_outbox o on o.message_id = m.id where o.dedupe_key = 'zses-q-m1'), 'ses|ses:0100m1');
select app.outbox_note_ses_fallback((select id from notification_outbox where dedupe_key = 'zses-r1'), 'SES 400 MessageRejected: Email address is not verified.');
select app.outbox_note_ses_fallback((select id from notification_outbox where dedupe_key = 'zses-s1'), 'never on an SES send');
select test.eq('an email Resend sent after an SES refusal says why', (select status_reason from notification_outbox where dedupe_key = 'zses-r1'),
  'sent through Resend after an SES refusal: SES 400 MessageRejected: Email address is not verified.');
select test.eq('never on an SES send', (select status_reason from notification_outbox where dedupe_key = 'zses-s1'), null::text);

-- ================================================================ roles
select test.eq('the sender''s SES functions are the server''s only',
  has_function_privilege('authenticated', 'public.server_ses_email_result(jsonb)', 'execute') or has_function_privilege('anon', 'public.server_ses_email_result(jsonb)', 'execute')
  or has_function_privilege('authenticated', 'public.server_outbox_note_ses_fallback(uuid, text)', 'execute') or has_function_privilege('authenticated', 'app.ses_email_try(timestamptz)', 'execute'), false);
select test.eq('the service role may report', has_function_privilege('service_role', 'public.server_ses_email_result(jsonb)', 'execute'), true);

-- back as the suites expect
delete from notification_outbox where dedupe_key like 'zses-%';
update notification_outbox o set sent_at = c.sent_at, status = c.status, locked_at = c.locked_at from zses_sent0 c where c.id = o.id;
update notification_outbox o set send_after = e.send_after from zses_others e where e.id = o.id;
update email_provider_state set ses_seen_at = null, ses_ok_at = null, ses_failed_at = null, ses_error = null;
