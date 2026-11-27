-- 99: R50 hotfix 2, comms (5090). Texts recover by themselves once Quo has credits again: the "Sign-in codes by text"
-- check clears when any text goes through Quo after the failures; a sign-in code refused for credits pauses the texts
-- and one that goes ends the pause; while paused a due text waits for the probe (up to text_retry_paused_minutes) and
-- goes once the probe went. Fixtures start with "zrh2"; every number is a 555 number.
select test.suite('99 r50 hotfix 2: texts recover after Quo credits return (5090)');

select test.mk_renter('zrh2_rita');
create temp table zrh2_t as select (app.phone_thread_for('+16475550188')).id as thread_id;
update phone_threads set renter_id = test.id('renter:zrh2_rita') where id = (select thread_id from zrh2_t);
-- the earlier suites' texts out of the way, the provider state clean
create temp table zrh2_others as select id, send_after from phone_outbox where status = 'queued';
update phone_outbox o set send_after = timestamptz '2035-01-01' from zrh2_others x where x.id = o.id;
update phone_provider_state set quo_failed_at = null, quo_ok_at = null, quo_probe_at = null, quo_error = null where id;
update program_settings set text_stale_minutes = 120, text_retry_paused_minutes = 30 where true;

create or replace function test.zrh2_text(p_label text, p_age interval default '0 minutes') returns uuid language plpgsql as $$
declare v uuid := test.id('zrh2-text:' || p_label);
begin
  insert into phone_outbox (id, thread_id, to_number, body, kind, renter_id, dedupe_key)
  values (v, (select thread_id from zrh2_t), '+16475550188', 'ZRH2 text ' || p_label, 'booking', test.id('renter:zrh2_rita'), 'zrh2:' || p_label);
  update phone_outbox set status = 'queued', send_after = now() - p_age, created_at = now() - p_age, locked_at = null where id = v;
  return v;
end $$;
create or replace function test.zrh2_status(p_label text) returns text language sql as $$
  select status || '|' || coalesce(status_reason, '') from phone_outbox where id = test.id('zrh2-text:' || p_label) $$;
create or replace function test.zrh2_claimed(p jsonb) returns text language sql as $$
  select coalesce(string_agg(replace(x ->> 'body', 'ZRH2 text ', ''), ',' order by x ->> 'body'), '') from jsonb_array_elements(coalesce(p -> 'texts', '[]'::jsonb)) x
   where x ->> 'body' like 'ZRH2 text %' $$;
-- a sign-in code the site asked for (status sending), then Quo's answer for it
create or replace function test.zrh2_code(p_label text, p_ok boolean, p_error text default null) returns jsonb language plpgsql as $$
begin
  insert into app.auth_sms_log (id, phone, status) values (test.id('zrh2-code:' || p_label), '+16475550189', 'sending');
  return app.server_auth_sms_result(jsonb_build_object('log_id', test.id('zrh2-code:' || p_label), 'ok', p_ok, 'error', p_error, 'quo_id', case when p_ok then 'zrh2-' || p_label end));
end $$;

-- ================================================================ 1. the sign-in check follows any text that went
delete from app.auth_sms_log where true;
insert into app.auth_sms_log (phone, status, reason, created_at)
select '+16475550' || (190 + g), 'failed', 'Quo 402: The organization does not have enough prepaid credits to send the message', now() - make_interval(secs => g / 1000.0)
  from generate_series(1, 3) g;
select test.eq('3 sign-in codes refused for credits: failing, the sign-in page puts the password first',
  (app.sms_signin_failing() ->> 'failing') || '/' || (public.server_email_capped() ->> 'sms_ok'), 'true/false');
select app.uptime_internal(now());
select test.eq('...and the site check says so', (select status <> 'ok' from uptime_checks where key = 'sms_signin'), true);

-- the credits are back: a booking text goes through Quo (no new sign-in code was asked for)
select test.zrh2_text('booking');
select test.eq('a due text is claimed', test.zrh2_claimed(app.server_phone_due(20)), 'booking');
select app.server_phone_sent(jsonb_build_object('id', test.id('zrh2-text:booking'), 'ok', true, 'quo_id', 'zrh2-quo-booking'));
select test.eq('a text that went after the failures: sign-in texts work again, the page offers codes again',
  (app.sms_signin_failing() ->> 'failing') || '/' || (public.server_email_capped() ->> 'sms_ok'), 'false/true');
select app.uptime_internal(now());
select test.eq('...and the site check is green on its next round (it no longer repeats the old failures)', (select status from uptime_checks where key = 'sms_signin'), 'ok');
select test.ok('the newest failure is still named for the record', app.sms_signin_failing() ->> 'last_failed_at' is not null and app.sms_signin_failing() ->> 'last_sent_at' is not null);

-- ================================================================ 2. sign-in codes pause and resume the texts
select test.zrh2_code('refused', false, 'Quo 402: The organization does not have enough prepaid credits to send the message');
select test.ok('a sign-in code refused for credits pauses the texts', app.quo_paused());
select test.eq('the refusal is kept with the pause', (select quo_error from phone_provider_state where id) like 'Quo 402:%', true);
select test.zrh2_code('bad_number', false, 'Quo 400: invalid number');
select test.ok('a refusal that is not the account''s changes nothing (still paused, no new error)', app.quo_paused() and (select quo_error from phone_provider_state where id) like 'Quo 402:%');
select test.zrh2_code('went', true);
select test.ok('a sign-in code that goes ends the pause', not app.quo_paused());

-- ================================================================ 3. while paused a due text waits, then goes once the probe went
select test.zrh2_text('refused');
select test.eq('not paused: the text is claimed', test.zrh2_claimed(app.server_phone_due(20)), 'refused');
select app.server_phone_sent(jsonb_build_object('id', test.id('zrh2-text:refused'), 'ok', false, 'error', 'Quo 402: insufficient prepaid credits', 'permanent', true));
select test.ok('a booking text refused for credits pauses the texts and falls back itself', app.quo_paused() and test.zrh2_status('refused') like 'failed|not sent: fell back to email%');
update phone_provider_state set quo_probe_at = now() where id;
select test.zrh2_text('young');
select test.zrh2_text('old', '31 minutes');
create temp table zrh2_due1 as select app.server_phone_due(20) as r;
select test.eq('paused, no probe due: nothing is claimed', (select test.zrh2_claimed(r) || '|' || (r ->> 'paused') from zrh2_due1), '|true');
select test.eq('the young text waits for the credits (not emailed)', test.zrh2_status('young'), 'queued|');
select test.ok('the text that waited 30 minutes fell back to email', test.zrh2_status('old') like 'skipped|not sent: fell back to email%');

-- the probe is due: the oldest waiting text is tried, it goes, the pause ends, the rest go on the next run
select test.zrh2_text('second');
update phone_outbox set send_after = now() - interval '5 minutes', created_at = now() - interval '5 minutes' where id = test.id('zrh2-text:young');
update phone_provider_state set quo_probe_at = now() - interval '31 minutes' where id;
create temp table zrh2_due2 as select app.server_phone_due(20) as r;
select test.eq('the probe takes the oldest waiting text only', (select test.zrh2_claimed(r) || '|' || (r ->> 'probe') from zrh2_due2), 'young|true');
select app.server_phone_sent(jsonb_build_object('id', test.id('zrh2-text:young'), 'ok', true, 'quo_id', 'zrh2-quo-young'));
select test.ok('the probe went: the pause ends', not app.quo_paused());
select test.eq('the text that waited goes on the next run', test.zrh2_claimed(app.server_phone_due(20)), 'second');
select test.eq('the probe was sent as a text, not emailed', test.zrh2_status('young'), 'sent|');

-- ================================================================ 4. access
select test.ok('the new functions are not open to browsers',
  not has_function_privilege('anon', 'app.quo_last_sent(timestamptz)', 'execute') and not has_function_privilege('authenticated', 'app.quo_last_sent(timestamptz)', 'execute')
  and not has_function_privilege('authenticated', 'app.server_auth_sms_result(jsonb)', 'execute') and has_function_privilege('service_role', 'app.server_auth_sms_result(jsonb)', 'execute'));

update phone_provider_state set quo_failed_at = null, quo_ok_at = null, quo_probe_at = null, quo_error = null where id;
update phone_outbox o set send_after = x.send_after from zrh2_others x where x.id = o.id and o.status = 'queued';
delete from app.auth_sms_log where phone like '+1647555019%' or phone = '+16475550189';
