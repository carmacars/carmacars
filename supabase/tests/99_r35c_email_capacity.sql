-- 99: the day's email figure (1501). While Cloudflare Email Service has not sent, the sending cap is Resend's budget and
-- the read says why (no binding, off, refused) and what both together give; once Cloudflare sent, the cap is both; a
-- daily limit in Program settings lower than both is named as the limit. The booking page's email box carries the same.
select test.suite('99 r35c email capacity');

update program_settings set notify_daily_cap = 300, notify_cf_daily_budget = 200, notify_resend_daily_budget = 100, cf_email_enabled = true;
update email_provider_state set cf_ok_at = null, cf_failed_at = now() - interval '1 hour', cf_error = 'no EMAIL binding on the Worker (Email Service not set up)';
delete from notification_outbox where provider_id like 'cf:%';

select test.eq('no binding: the cap is Resend''s 100, the capacity 300, limited to Resend',
  (select format('%s|%s|%s', p ->> 'day_cap', p ->> 'capacity', p ->> 'limited_by') from (select app.email_pace() p) x), '100|300|resend_only');
select test.ok('the reason names the missing binding and the repository variable',
  (select app.email_pace() ->> 'cf_reason') ilike '%EMAIL binding%CF_EMAIL_BINDING%');

update program_settings set cf_email_enabled = false;
select test.ok('switched off: the reason says so', (select app.email_pace() ->> 'cf_reason') ilike '%turned off%');
update program_settings set cf_email_enabled = true;

update email_provider_state set cf_ok_at = now(), cf_failed_at = null, cf_error = null;
select test.eq('Cloudflare sent: the cap is both, no reason',
  (select format('%s|%s|%s|%s', p ->> 'day_cap', p ->> 'capacity', p ->> 'limited_by', coalesce(p ->> 'cf_reason', 'none')) from (select app.email_pace() p) x), '300|300|combined|none');

update program_settings set notify_daily_cap = 150;
select test.eq('a lower daily limit in Program settings is named as the limit',
  (select format('%s|%s|%s', p ->> 'day_cap', p ->> 'capacity', p ->> 'limited_by') from (select app.email_pace() p) x), '150|150|setting');
update program_settings set notify_daily_cap = 300;

select test.eq('the functions are the server''s only', has_function_privilege('authenticated', 'app.email_capacity(timestamptz)', 'execute'), false);
