-- 99: texts and emails at once, the send times, and the live To do lists (2980,
-- docs/changes/2026-11-14-r48-instant-send.md). Fixtures start with "is"; addresses and numbers are example ones.
-- The NOTIFY itself reaches only a listening connection after commit: web/scripts/listen-check.mjs checks it end to end.
select test.suite('99 r48 instant send');

-- ================================================================ the notify
select test.eq('every queue, the notices and the events notify',
  (select count(*)::int from pg_trigger t where t.tgname = 'send_notify_ins' and not t.tgisinternal
      and t.tgrelid in ('phone_outbox'::regclass, 'notification_outbox'::regclass, 'push_outbox'::regclass, 'notifications'::regclass, 'app_events'::regclass)), 5);
select test.eq('a message put back to queued notifies too',
  (select count(*)::int from pg_trigger t where t.tgname = 'send_notify_upd' and not t.tgisinternal), 3);
select test.ok('the payload is the table and the row only', position($q$tg_table_name || ':' || (r ->> 'id')$q$ in pg_get_functiondef('app.send_notify()'::regprocedure)) > 0);
select test.ok('a notify never fails a write', position('exception when others' in pg_get_functiondef('app.send_notify()'::regprocedure)) > 0);
select test.ok('the listen login exists and may log in', exists (select 1 from pg_roles where rolname = 'carmacars_listen' and rolcanlogin and not rolsuper and not rolcreaterole));
select test.ok('the listen login reads nothing of the site',
  not has_table_privilege('carmacars_listen', 'bookings', 'select') and not has_table_privilege('carmacars_listen', 'phone_outbox', 'select')
  and not has_function_privilege('carmacars_listen', 'public.server_notify_kick(text[])', 'execute'));

-- ================================================================ queued to sent
create temp table is_text as select (app.phone_outbox_put('+14165550247', 'CarmaCars: is test text', 'staff', null, null, 'is_test', null, 'is-text-1', now())).id as id;
select test.ok('a queued text has its due time', (select due_at is not null and send_ms is null from phone_outbox where id = (select id from is_text)));
update phone_outbox set status = 'sent', sent_at = due_at + interval '1.5 seconds' where id = (select id from is_text);
select test.eq('sent: the time it took', (select send_ms from phone_outbox where id = (select id from is_text)), 1500);
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, send_after, created_at)
values ('renter_review_request', 'transactional', 3, 'renter', 'is-later@is.example.test', 'Is', '{}'::jsonb, 'is-later', 'queued', now() + interval '2 hours', now());
select test.ok('an email written for later is due at its send time', (select due_at = send_after from notification_outbox where dedupe_key = 'is-later'));
update notification_outbox set status = 'sent', sent_at = send_after + interval '800 milliseconds' where dedupe_key = 'is-later';
select test.eq('its time is from when it was due, not when it was written', (select send_ms from notification_outbox where dedupe_key = 'is-later'), 800);
select test.ok('the last day''s times per channel', (public.server_send_latency(24) -> 'text' ->> 'n')::int >= 1 and (public.server_send_latency(24) -> 'email' ->> 'avg_ms') is not null);
select test.ok('only the server reads the times', not has_function_privilege('authenticated', 'public.server_send_latency(integer)', 'execute')
  and has_function_privilege('service_role', 'public.server_send_latency(integer)', 'execute'));

-- ================================================================ every email at once
-- the events the other suites left are turned into notices first (a long first kick would pass the 5 seconds below)
select public.server_notify_kick(null);
-- the sender's own call, as the deploy schedules it (cron.job is not in the test database: made for this file only)
create schema if not exists cron;
create table if not exists cron.job (jobname text, command text, active boolean);
create table if not exists test.is_sender_calls (at timestamptz);
insert into cron.job values ('carmacars-send-outbox', 'insert into test.is_sender_calls values (now())', true);
update app.notify_kick_state set at = '-infinity' where k = 'email';
-- an email that is not urgent (a review request), due now
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, send_after, created_at)
values ('renter_review_request', 'transactional', 3, 'renter', 'is-now@is.example.test', 'Is', '{}'::jsonb, 'is-now', 'queued', now() - interval '1 second', now() - interval '1 second');
select test.ok('it is not urgent', not app.outbox_urgent(null, 3::smallint, now() - interval '1 second', now()));
create temp table is_kick as select public.server_notify_kick(null) k;
select test.eq('the kick says an email is due', (select (k ->> 'email')::boolean from is_kick), true);
select test.eq('the email sender is asked at once', (select count(*)::int from test.is_sender_calls), 1);
select public.server_notify_kick(null);
select test.eq('never twice within 5 seconds', (select count(*)::int from test.is_sender_calls), 1);
update app.notify_kick_state set at = now() - interval '6 seconds' where k = 'email';
select public.server_notify_kick(null);
select test.eq('asked again after 5 seconds', (select count(*)::int from test.is_sender_calls), 2);
update notification_outbox set status = 'skipped', status_reason = 'test' where dedupe_key = 'is-now';
drop table cron.job;
drop schema cron;
drop table test.is_sender_calls;

-- ================================================================ the live To do lists
select test.mk_user('is_admin', 'admin');
select test.mk_user('is_field', 'field', null, 'driver');
select test.mk_renter('is_rita');
select test.ok('an Admin and field staff get the To do topic',
  app.server_live_topics(test.id('is_admin'), array['staff:tasks']) ? 'staff:tasks' and app.server_live_topics(test.id('is_field'), array['staff:tasks']) ? 'staff:tasks');
select test.ok('a renter does not', not (app.server_live_topics((select user_id from renters where id = test.id('renter:is_rita')), array['staff:tasks']) ? 'staff:tasks'));
select test.ok('the other topics still come with it',
  app.server_live_topics(test.id('is_admin'), array['staff:tasks', 'staff:bookings', 'user:' || test.id('is_admin')]) ?& array['staff:tasks', 'staff:bookings', 'user:' || test.id('is_admin')]);
create temp table is_ver as select coalesce((select ver from app.live_versions where topic = app.live_topic('staff:tasks')), 0) v;
select app.raise_task(p_type => 'deposit_pending_overdue', p_title => 'is live test', p_dedupe => 'is-live-1', p_queue => 'admin');
-- (the bump is made at commit: this statement is the next transaction)
select test.ok('a new To do bumps the To do topic', (select ver from app.live_versions where topic = app.live_topic('staff:tasks')) > (select v from is_ver));
select test.ok('the phone conversations bump the messages area', to_regclass('public.phone_threads') is null
  or exists (select 1 from pg_trigger where tgname = 'live_ins_public_phone_threads' or tgname = 'live_ins_phone_threads'));
