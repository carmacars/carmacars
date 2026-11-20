-- 99: release 48 CM, comms (3110). A text that cannot go falls back to email and says so; Quo out of credits pauses
-- texts (every due text falls back, one probe every 30 minutes) with one Admin alert a day; stale and irrelevant texts are
-- dropped and refilling the credits sends nothing stale. Phone alerts stay on (lost devices recorded, the browser's own
-- re-subscribe, refused only after the person's Turn off). Suspended staff get only the suspension and restored emails;
-- the restore link asks the Admins; Unlock restores. Fixtures start with "zcm"; every address is example.test.
select test.suite('99 r48 CM comms: text fallback, no stale texts, alerts stay on, staff suspension (3110)');

select test.mk_renter('zcm_rita');
select test.mk_user('zcm_admin', 'admin');
select test.mk_user('zcm_sam', 'va', 'sales');
select test.mk_user('zcm_quiet', 'va', 'cs');
create temp table zcm_t as select (app.phone_thread_for('+16475550177')).id as thread_id;
update phone_threads set renter_id = test.id('renter:zcm_rita') where id = (select thread_id from zcm_t);
-- every text of the earlier suites out of the way (a far future send time), the provider state clean
create temp table zcm_others as select id, send_after from phone_outbox where status = 'queued';
update phone_outbox o set send_after = timestamptz '2035-01-01' from zcm_others x where x.id = o.id;
-- texts the earlier suites left sending are not claimed again here (claimed again only after 10 minutes)
create temp table zcm_sending as select id, locked_at from phone_outbox where status = 'sending';
update phone_outbox o set locked_at = now() - interval '6 seconds' from zcm_sending x where x.id = o.id;
update phone_provider_state set quo_failed_at = null, quo_ok_at = null, quo_probe_at = null, quo_error = null;
update program_settings set text_stale_minutes = 120, text_retry_paused_minutes = 30;

create or replace function test.zcm_text(p_label text, p_age interval default '0 minutes', p_kind text default 'booking', p_booking uuid default null, p_code text default null)
returns uuid language plpgsql as $$
declare v uuid := test.id('zcm-text:' || p_label);
begin
  insert into phone_outbox (id, thread_id, to_number, body, kind, renter_id, booking_id, sms_kind, dedupe_key)
  values (v, (select thread_id from zcm_t), '+16475550177', 'ZCM text ' || p_label, p_kind, test.id('renter:zcm_rita'), p_booking, p_code, 'zcm:' || p_label);
  update phone_outbox set status = 'queued', send_after = now() - p_age, created_at = now() - p_age, locked_at = null where id = v;
  return v;
end $$;
create or replace function test.zcm_status(p_label text) returns text language sql as $$
  select status || '|' || coalesce(status_reason, '') from phone_outbox where id = test.id('zcm-text:' || p_label) $$;
create or replace function test.zcm_claimed(p jsonb) returns text language sql as $$
  select coalesce(string_agg(replace(x ->> 'body', 'ZCM text ', ''), ',' order by x ->> 'body'), '') from jsonb_array_elements(coalesce(p -> 'texts', '[]'::jsonb)) x
   where x ->> 'body' like 'ZCM text %' $$;
create or replace function test.zcm_alerts() returns bigint language sql as $$
  select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'texts_not_sending' $$;

-- ================================================================ settings
select test.eq('settings: stale after 2 hours, a probe every 30 minutes, staff suspended after 5 days (warned on day 3)',
  (select string_agg(column_name || '=' || column_default, ',' order by column_name) from information_schema.columns
    where table_name = 'program_settings' and column_name in ('text_stale_minutes', 'text_retry_paused_minutes', 'staff_inactive_lock_days', 'staff_inactive_warn_days')),
  'staff_inactive_lock_days=5,staff_inactive_warn_days=3,text_retry_paused_minutes=30,text_stale_minutes=120');
select test.ok('the inactivity days count from the release at the earliest (grace from set)', (select staff_inactive_grace_from is not null from program_settings limit 1));

-- ================================================================ 1. Quo out of credits: the text falls back to email, texts pause, one alert
select test.zcm_text('a');
select test.eq('a due text is claimed', test.zcm_claimed(app.server_phone_due(20)), 'a');
select app.server_phone_sent(jsonb_build_object('id', test.id('zcm-text:a'), 'ok', false, 'error', 'Quo 402: insufficient prepaid credits', 'permanent', true));
select test.ok('Quo 402: the text is not sent and says it fell back to email', test.zcm_status('a') like 'failed|not sent: fell back to email%');
select test.eq('its email is on its way (text_fell_back, to the renter''s address, once)',
  (select count(*) || '|' || max(payload ->> 'signer_email') from app_events where code = 'text_fell_back' and dedupe_key = 'text_fell_back:' || test.id('zcm-text:a')), '1|zcm_rita@example.test');
select test.ok('texts are paused (Quo refused for its account)', app.quo_paused());
select test.eq('the Admins got one alert', test.zcm_alerts(), 1::bigint);

-- while paused nothing is tried: every due text falls back at once (no probe within 30 minutes of the last)
update phone_provider_state set quo_probe_at = now();
select test.zcm_text('b');
select test.zcm_text('c');
create temp table zcm_due1 as select app.server_phone_due(20) as r;
select test.eq('paused: nothing is claimed', (select test.zcm_claimed(r) || '|' || (r ->> 'paused') from zcm_due1), '|true');
select test.ok('paused: both due texts fell back to email', test.zcm_status('b') like 'skipped|not sent: fell back to email%' and test.zcm_status('c') like 'skipped|not sent: fell back to email%');
select test.eq('another refusal the same day: still one alert (deduplicated)',
  (select test.zcm_alerts() from (select app.texts_alert('Quo 402: insufficient prepaid credits')) x), 1::bigint);

-- ================================================================ 2. never a late text
select test.zcm_text('stale', '3 hours');
select app.server_phone_due(20);
select test.ok('a text queued 3 hours ago is dropped as stale', test.zcm_status('stale') like 'skipped|not sent: stale%');
select test.eq('a stale text gets no late email either', (select count(*) from app_events where dedupe_key = 'text_fell_back:' || test.id('zcm-text:stale')), 0::bigint);

select test.mk_owner('zcm_olive');
select test.mk_vehicle('zcm_car', 'zcm_olive');
select test.mk_booking('ZCM-1', 'zcm_car', 'zcm_rita', to_char((now() + interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'cancelled');
select test.zcm_text('reminder', '0 minutes', 'notify', test.id('booking:ZCM-1'), 'renter_pickup_soon');
select test.ok('a reminder for a cancelled booking is no longer relevant', app.text_drop_reason((select o from phone_outbox o where o.id = test.id('zcm-text:reminder'))) like 'not sent: no longer relevant%');

-- ================================================================ 3. the credits come back: nothing stale goes
update phone_outbox set status = 'skipped', status_reason = 'zcm: out of the way' where id = test.id('zcm-text:reminder');
select test.zcm_text('waiting_long', '150 minutes');
update phone_provider_state set quo_probe_at = now() - interval '31 minutes';
create temp table zcm_due2 as select app.server_phone_due(20) as r;
select test.eq('the probe after 30 minutes: the stale text is dropped, nothing is claimed (nothing fresh waits)',
  (select test.zcm_claimed(r) || '|' || (r ->> 'probe') from zcm_due2), '|true');
select test.ok('the long-waiting text was dropped, not sent', test.zcm_status('waiting_long') like 'skipped|not sent: stale%');
-- credits refilled: the next fresh text is the probe, it goes, the pause ends
update phone_provider_state set quo_probe_at = now() - interval '31 minutes';
select test.zcm_text('fresh');
create temp table zcm_due3 as select app.server_phone_due(20) as r;
select test.eq('refilled: only the fresh text is claimed', (select test.zcm_claimed(r) from zcm_due3), 'fresh');
select app.server_phone_sent(jsonb_build_object('id', test.id('zcm-text:fresh'), 'ok', true, 'quo_id', 'zcm-quo-fresh'));
select test.ok('a text that goes ends the pause', not app.quo_paused());
select test.eq('refilling the credits sent nothing stale: every older text is failed or skipped, none sent',
  (select string_agg(status, ',' order by dedupe_key) from phone_outbox where dedupe_key in ('zcm:a', 'zcm:b', 'zcm:c', 'zcm:stale', 'zcm:waiting_long')), 'failed,skipped,skipped,skipped,skipped');
select test.eq('after the pause, the queue claims as before (one more fresh text)',
  (select test.zcm_claimed(app.server_phone_due(20)) from (select test.zcm_text('after')) x), 'after');

-- a refusal that is not the account's (a bad number): that text falls back, texts do not pause
select app.server_phone_sent(jsonb_build_object('id', test.id('zcm-text:after'), 'ok', false, 'error', 'Quo 400: invalid number', 'permanent', true));
select test.ok('any refusal that ends a text: fell back to email, no pause', test.zcm_status('after') like 'failed|not sent: fell back to email%' and not app.quo_paused());

-- ================================================================ 4. phone alerts stay on
create temp table zcm_ep as select 'https://fcm.googleapis.com/fcm/send/zcm-' || md5('zcm') as ep,
  rpad('B', 87, 'x') as p256dh, rpad('a', 22, 'x') as auth;
select app.push_subscribe(test.id('zcm_sam'), jsonb_build_object('endpoint', ep, 'p256dh', p256dh, 'auth', auth, 'portal', 'staff', 'device', 'Chrome on Windows')) from zcm_ep;
do $$ begin perform set_config('app.push_lost_reason', 'expired', true); delete from push_subscriptions where user_id = test.id('zcm_sam'); end $$;
select test.eq('a device the push service dropped is recorded as expired, and the card says so',
  (select (s -> 'lost' ->> 'reason') || '|' || (s ->> 'turned_off_here') from (select app.push_state(test.id('zcm_sam'), (select ep from zcm_ep)) s) x), 'expired|false');
select test.eq('the browser subscribes again by itself: on, and the lost device resolved',
  (select (s ->> 'this_device') || '|' || coalesce(s ->> 'lost', 'none') from (select app.push_subscribe(test.id('zcm_sam'), jsonb_build_object('endpoint', ep, 'p256dh', p256dh, 'auth', auth, 'portal', 'staff', 'auto', true)) s from zcm_ep) x),
  'true|none');
select app.push_unsubscribe(test.id('zcm_sam'), jsonb_build_object('endpoint', (select ep from zcm_ep)));
select test.eq('after the person''s own Turn off, the browser''s own re-subscribe is refused',
  (select (s ->> 'auto_refused') || '|' || (s ->> 'this_device') from (select app.push_subscribe(test.id('zcm_sam'), jsonb_build_object('endpoint', ep, 'p256dh', p256dh, 'auth', auth, 'auto', true)) s from zcm_ep) x),
  'true|false');
select test.eq('their own Turn on works again',
  (select s ->> 'this_device' from (select app.push_subscribe(test.id('zcm_sam'), jsonb_build_object('endpoint', ep, 'p256dh', p256dh, 'auth', auth)) s from zcm_ep) x), 'true');
select app.push_subscribe(test.id('zcm_quiet'), jsonb_build_object('endpoint', ep, 'p256dh', p256dh, 'auth', auth)) from zcm_ep;
select test.eq('another person signing in on the device: recorded for the first person (another_person)',
  (select reason from push_lost where user_id = test.id('zcm_sam') order by at desc, id desc limit 1), 'another_person');

-- ================================================================ 5. suspension: one email set, the restore link, Unlock
create or replace function test.zcm_mail(p_user text, p_code text, p_key text) returns text language sql as $$
  insert into notification_outbox (code, category, priority, audience, recipient_user_id, to_address, payload, dedupe_key, status)
  values (p_code, 'transactional', 2, 'staff_va_sales', test.id(p_user), p_user || '@example.test', '{}'::jsonb, 'zcm-mail:' || p_key, 'queued')
  returning status || '|' || coalesce(status_reason, '') $$;
update staff_profiles set inactive_locked_at = now(), lock_reason = 'inactivity' where user_id = test.id('zcm_sam');
select test.eq('suspended: the suspension email with its restore link, once',
  (select count(*) || '|' || bool_and(payload ->> 'restore_url' like '%/staff-restore?t=%') from app_events where code = 'staff_access_suspended' and entity_id = test.id('zcm_sam')), '1|true');
select test.ok('the restore link is the account''s token', (select restore_token is not null from staff_profiles where user_id = test.id('zcm_sam')));
select test.eq('suspended: any other staff email is suppressed', test.zcm_mail('zcm_sam', 'staff_inactivity_warning', 's1'), 'suppressed|not sent: staff access suspended');
select test.eq('suspended: the suspension email itself goes', test.zcm_mail('zcm_sam', 'staff_access_suspended', 's2'), 'queued|');
select test.eq('a bad restore link: the same answer, nothing recorded',
  (select (public.server_staff_restore_request(gen_random_uuid()) ->> 'ok') || '|' || (select count(*) from staff_restore_requests where user_id = test.id('zcm_sam'))), 'true|0');
select public.server_staff_restore_request((select restore_token from staff_profiles where user_id = test.id('zcm_sam')));
select public.server_staff_restore_request((select restore_token from staff_profiles where user_id = test.id('zcm_sam')));
select test.eq('the restore link asks once (one open request, one Admin alert)',
  (select count(*) from staff_restore_requests where user_id = test.id('zcm_sam') and decided_at is null) || '|' ||
  (select count(*) from app_events where code like 'staff_alert_%' and payload ->> 'rule' = 'staff_restore_requested' and entity_id = test.id('zcm_sam')), '1|1');
select test.eq('after a refused sign-in the restore token is given back', public.server_staff_restore_token(test.id('zcm_sam')), (select restore_token from staff_profiles where user_id = test.id('zcm_sam')));
select app.staff_unlock(test.id('zcm_admin'), jsonb_build_object('user_id', test.id('zcm_sam')));
select test.eq('Unlock: restored email, the request closed as restored, the link gone',
  (select count(*) from app_events where code = 'staff_access_restored' and entity_id = test.id('zcm_sam')) || '|' ||
  (select decision from staff_restore_requests where user_id = test.id('zcm_sam')) || '|' ||
  (select coalesce(restore_token::text, 'none') from staff_profiles where user_id = test.id('zcm_sam')), '1|restored|none');
select test.eq('restored: staff emails go again', test.zcm_mail('zcm_sam', 'staff_inactivity_warning', 's3'), 'queued|');
create temp table zcm_locked0 as select user_id from staff_profiles where inactive_locked_at is not null;
create temp table zcm_job as select app.job_staff_inactivity(now()) as r;
select test.eq('the inactivity job counts from the release: nobody is suspended by it today',
  (select count(*) from staff_profiles sp where sp.inactive_locked_at is not null and sp.user_id not in (select user_id from zcm_locked0)
      and sp.lock_reason = 'inactivity'), 0::bigint);

-- ================================================================ 6. staff notifications turned off
update users set staff_notices_off = true where id = test.id('zcm_quiet');
select test.eq('notices off: staff email suppressed', test.zcm_mail('zcm_quiet', 'staff_inactivity_warning', 'q1'), 'suppressed|not sent: staff notifications turned off');
select test.eq('notices off: not even the suspension email', test.zcm_mail('zcm_quiet', 'staff_access_suspended', 'q2'), 'suppressed|not sent: staff notifications turned off');
select test.ok('an Admin is never blocked', app.staff_notice_block(test.id('zcm_admin'), 'staff_inactivity_warning') is null);

-- ================================================================ 7. the emails are built
select app.process_events(100000);
select test.eq('the fallback, suspension and restored emails are built for the outbox',
  (select string_agg(distinct code, ',' order by code) from notification_outbox where code in ('text_fell_back', 'staff_access_suspended', 'staff_access_restored')
     and (to_address like 'zcm%' or recipient_user_id in (test.id('zcm_sam'), test.id('zcm_rita')))),
  'staff_access_restored,staff_access_suspended,text_fell_back');

-- ================================================================ clean up: the earlier suites' texts back as they were
update phone_outbox o set send_after = x.send_after from zcm_others x where x.id = o.id;
update phone_outbox o set locked_at = x.locked_at from zcm_sending x where x.id = o.id;
update phone_provider_state set quo_failed_at = null, quo_ok_at = null, quo_probe_at = null, quo_error = null;
