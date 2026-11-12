-- 99: the day's email figure (1501, as 1750 has it). The day is Cloudflare's daily budget (never past the month's
-- included emails) and then Resend's; the read says which one sends and, when Cloudflare is not sending, why (no
-- binding, off, refused). The booking page's email box carries the same.
select test.suite('99 r35c email capacity');

update program_settings set notify_daily_cap = 300, cf_email_daily_budget = 100, notify_resend_daily_budget = 100, cf_email_monthly_included = 3000, cf_email_enabled = true, email_cloudflare_enabled = true;
update email_provider_state set cf_ok_at = null, cf_failed_at = now() - interval '1 hour', cf_error = 'no EMAIL binding on the Worker (Email Service not set up)';
create temp table c35_cf as select id, provider_id from notification_outbox where provider_id like 'cf:%';
update notification_outbox set provider_id = 'x' || provider_id where id in (select id from c35_cf);

select test.ok('no binding and no send: the reason names the missing binding in Cloudflare''s words',
  (select app.email_pace() ->> 'cf_reason') ilike '%EMAIL binding%Cloudflare said:%');
select test.eq('Cloudflare''s day and Resend''s together make the day (Cloudflare rests 15 minutes after a refusal: none of its sends counted yet)',
  (select (p ->> 'day_cap')::integer - (p ->> 'cf_today')::integer from (select app.email_pace() p) x), 200);

update program_settings set cf_email_enabled = false;
select test.ok('switched off: the reason says so', (select app.email_pace() ->> 'cf_reason') ilike '%turned off%');
select test.eq('switched off: Resend''s day only', (select (p ->> 'day_cap')::integer from (select app.email_pace() p) x), 100);
update program_settings set cf_email_enabled = true, email_cloudflare_enabled = true;

update email_provider_state set cf_ok_at = now(), cf_failed_at = null, cf_error = null;
select test.eq('Cloudflare sends: no reason, Cloudflare''s turn',
  (select format('%s|%s', coalesce(p ->> 'cf_reason', 'none'), p ->> 'limited_by') from (select app.email_pace() p) x), 'none|cloudflare');

update program_settings set notify_daily_cap = 50;
select test.eq('a lower daily limit in Program settings lowers Resend''s part', (select (p ->> 'day_cap')::integer from (select app.email_pace() p) x), 150);
update program_settings set notify_daily_cap = 300;

update notification_outbox o set provider_id = c.provider_id from c35_cf c where c.id = o.id;
select test.eq('the functions are the server''s only', has_function_privilege('authenticated', 'app.email_capacity(timestamptz)', 'execute'), false);
update program_settings set cf_email_enabled = false;
