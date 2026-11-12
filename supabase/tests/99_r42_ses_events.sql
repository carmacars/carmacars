-- 99: SES bounce and complaint events (2630, release 42). The route /api/ses/events reports a permanent bounce or a complaint
-- by the SES message id (provider id 'ses:<id>') and the address; the address is suppressed for every email and the server's
-- wrapper is the server's only. Fixtures start with "zbnc"; every address is example.test.
select test.suite('99 r42 SES bounce and complaint events (2630)');

insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, sent_at, provider_id, send_after)
select code, 'transactional', 1, 'renter', 'zbnc1@example.test', 'Zbnc', '{}'::jsonb, 'zbnc-1', 'sent', now(), 'ses:zbnc-msg-1', now()
  from notification_catalogue where audience = 'renter' and has_email and is_enabled and category = 'transactional' order by code limit 1;
select public.server_outbox_record_bounce('ses:zbnc-msg-1', 'bounce', 'Permanent/General: 550 no such user', 'ZBNC1@example.test');
select test.eq('a permanent bounce suppresses the address for every email',
  (select scope || ':' || reason from email_suppressions where email = 'zbnc1@example.test' and lifted_at is null), 'all:bounce');
select public.server_outbox_record_bounce('ses:zbnc-msg-1', 'bounce', 'again', 'zbnc1@example.test');
select test.eq('a repeated report adds no second row', (select count(*) from email_suppressions where email = 'zbnc1@example.test' and lifted_at is null), 1::bigint);
select public.server_outbox_record_bounce('ses:unknown-id', 'complaint', 'abuse', 'zbnc2@example.test');
select public.server_outbox_record_bounce('ses:zbnc-msg-1', 'complaint', 'abuse', 'zbnc3@example.test');
select test.eq('a message id that is not ours, or an address that email was not sent to, suppresses nothing',
  (select count(*) from email_suppressions where email in ('zbnc2@example.test', 'zbnc3@example.test')), 0::bigint);
select public.server_outbox_record_bounce('ses:zbnc-msg-1', 'complaint', 'abuse', 'zbnc1@example.test');
select test.eq('a complaint about our email adds the complaint scope row or keeps the active one',
  (select count(*) from email_suppressions where email = 'zbnc1@example.test' and lifted_at is null), 1::bigint);
select test.eq('only the server may report',
  has_function_privilege('authenticated', 'public.server_outbox_record_bounce(text, text, text, text)', 'execute')
  or has_function_privilege('anon', 'public.server_outbox_record_bounce(text, text, text, text)', 'execute'), false);
select test.eq('the service role may report', has_function_privilege('service_role', 'public.server_outbox_record_bounce(text, text, text, text)', 'execute'), true);

delete from email_suppressions where email like 'zbnc%@example.test';
delete from notification_outbox where dedupe_key like 'zbnc-%';
