-- 99: R50 hotfix 2 (5091). The email meter counts Amazon SES as capacity: SES's sends never make the day look capped
-- against Resend's 100 (no false "almost out of email" warning, the sign-in page keeps email); the portal warning stays
-- quiet while SES sends. AI auto-replies answer when Workers AI's share is used and a free provider is ready.
-- Fixtures start with "zrh5"; every address is example.test.
select test.suite('99 r50 hotfix 2: email meter with SES, auto-replies past the Workers AI share (5091)');

create temp table zrh5_set as select notify_daily_cap, notify_monthly_cap, email_ses_enabled, email_ses_daily_max from program_settings limit 1;
create temp table zrh5_eps as select ses_seen_at, ses_failed_at from email_provider_state limit 1;
update program_settings set notify_daily_cap = 100, email_ses_enabled = true, email_ses_daily_max = 5000 where true;
update email_provider_state set ses_seen_at = now(), ses_failed_at = null where id;
create temp table zrh5_code as select code from notification_catalogue where audience = 'renter' and has_email and is_enabled and category = 'transactional'
  and code not like '%reminder%' order by code limit 1;
create temp table zrh5_before as select app.email_capped(now()) capped, (app.email_usage(now()) ->> 'total')::int total;

-- ================================================================ 1. 150 emails through SES today
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, sent_at, provider_id, send_after)
select (select code from zrh5_code), 'transactional', 1, 'renter', 'zrh5.' || g || '@example.test', 'Zrh5', '{}'::jsonb, 'zrh5-' || g, 'sent', now(), 'ses:zrh5-' || g, now()
  from generate_series(1, 150) g;
select test.ok('the day''s limit is the whole capacity with SES (not Resend''s 100)', (app.email_usage(now()) ->> 'cap')::int >= 5000);
select test.ok('150 SES emails are far from the warning', (app.email_usage(now()) ->> 'total')::int < (app.email_usage(now()) ->> 'warn_at')::int
  or (select total from zrh5_before) >= (app.email_usage(now()) ->> 'warn_at')::int);
select test.eq('SES''s sends do not make email capped (the sign-in page keeps email)', app.email_capped(now()), (select capped from zrh5_before));
select test.ok('the month test counts Resend''s emails only',
  position('not like ''ses:%''' in pg_get_functiondef('app.email_capped(timestamptz)'::regprocedure)) > 0);
select test.ok('the portal warning is quiet while SES sends',
  position('not app.ses_email_try(p_now)' in pg_get_functiondef('app.outbox_claim_pre0530(integer, timestamptz)'::regprocedure)) > 0);

-- SES not running (its keys not seen in the hour): the day is Resend's again, and the same sends count against it
update email_provider_state set ses_seen_at = now() - interval '2 hours' where id;
select test.ok('without SES the day''s limit falls back to the free providers', (app.email_usage(now()) ->> 'cap')::int < 5000);
update email_provider_state set ses_seen_at = now() where id;

delete from notification_outbox where dedupe_key like 'zrh5-%';
update program_settings p set notify_daily_cap = s.notify_daily_cap, notify_monthly_cap = s.notify_monthly_cap, email_ses_enabled = s.email_ses_enabled,
  email_ses_daily_max = s.email_ses_daily_max from zrh5_set s where true;
update email_provider_state e set ses_seen_at = x.ses_seen_at, ses_failed_at = x.ses_failed_at from zrh5_eps x where e.id;

-- ================================================================ 2. auto-replies past the Workers AI share
create temp table zrh5_ai as select included, enabled from usage_services where service = 'workers_ai';
create temp table zrh5_local as select * from app.ai_local_status;
update usage_services set included = 0, enabled = true where service = 'workers_ai';
delete from app.ai_local_status where true;
select test.eq('Workers AI''s share used, no free provider: no automatic answer',
  public.server_auto_reply_gate('{"channel": "email", "sender": "zrh5.ask@example.test"}') ->> 'reason', 'the free Workers AI allowance of the day is used');
insert into app.ai_local_status (id, text_ready, at) values (true, true, now());
select test.ok('Workers AI''s share used, the server''s model ready: the question is answered',
  (public.server_auto_reply_gate('{"channel": "email", "sender": "zrh5.ask@example.test"}') ->> 'allowed')::boolean);
update app.ai_local_status set text_ready = false, gemini_ready = true where id;
select test.ok('...or Gemini (an FAQ answer is not private)',
  (public.server_auto_reply_gate('{"channel": "email", "sender": "zrh5.ask@example.test"}') ->> 'allowed')::boolean);
update program_settings set auto_reply_email = false where true;
select test.eq('a channel switched off still answers nothing', public.server_auto_reply_gate('{"channel": "email", "sender": "zrh5.ask@example.test"}') ->> 'reason', 'off in Program settings');
update program_settings set auto_reply_email = true where true;

delete from app.ai_local_status where true;
insert into app.ai_local_status select * from zrh5_local;
update usage_services u set included = x.included, enabled = x.enabled from zrh5_ai x where u.service = 'workers_ai';
