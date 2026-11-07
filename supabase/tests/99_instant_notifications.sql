-- 99: instant notifications (migration 0670, docs/changes/2026-11-07-r32-edge-cpu-notify.md): an urgent email is claimed
-- even when the hour's pace is used up, a paced one waits; the kick answers what is due; a push never waits for its
-- email. Fixtures start with "in"; addresses are example.test.
select test.suite('99 instant notifications');

select test.ok('a staff alert marked urgent is urgent', app.outbox_urgent('urgent', 2::smallint, now() - interval '2 hours', now()));
select test.ok('a fresh first-class customer email is urgent', app.outbox_urgent(null, 1::smallint, now() - interval '5 minutes', now()));
select test.ok('a first-class email from a held backlog is paced', not app.outbox_urgent(null, 1::smallint, now() - interval '3 hours', now()));
select test.ok('a digest is paced', not app.outbox_urgent(null, 4::smallint, now(), now()));

-- a day of its own (after every email the other suites sent, some dated ahead, so the day's cap is this suite's own),
-- the hour's pace used up
create temp table in_t as select greatest(now(), (select max(sent_at) from notification_outbox)) + interval '2 days' t;
create or replace function test.in_t() returns timestamptz language sql stable as $$ select t from in_t $$;
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, send_after, sent_at, created_at)
select 'renter_review_request', 'transactional', 3, 'renter', 'in-sent-' || g || '@in.example.test', 'In', '{}'::jsonb, 'in-sent-' || g, 'sent',
       test.in_t() - interval '30 minutes', test.in_t() - interval '20 minutes', test.in_t() - interval '30 minutes'
  from generate_series(1, ceil(app.email_day_cap(test.in_t()) / 24.0)::integer + 31) g;
select test.ok('the hour''s pace is used up, the day''s cap is not', (app.email_pace(test.in_t()) ->> 'hour_used')::int >= (app.email_pace(test.in_t()) ->> 'hour_cap')::int
  and (app.email_pace(test.in_t()) ->> 'day_used')::int < (app.email_pace(test.in_t()) ->> 'day_cap')::int);

-- (other suites leave urgent alerts queued: counted before, so the test counts its own)
create temp table in_before as select app.outbox_urgent_waiting(test.in_t()) n;
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, status_reason, send_after, created_at)
values ('staff_payment_failed', 'transactional', 2, 'staff_admin', 'in-urgent@in.example.test', 'In', '{}'::jsonb, 'in-urgent', 'queued', 'urgent', test.in_t() - interval '1 minute', test.in_t() - interval '1 minute'),
       ('renter_review_request', 'transactional', 3, 'renter', 'in-paced@in.example.test', 'In', '{}'::jsonb, 'in-paced', 'queued', null, test.in_t() - interval '1 minute', test.in_t() - interval '2 hours');
select test.eq('one more urgent email waits', app.outbox_urgent_waiting(test.in_t()) - (select n from in_before), 1);
create temp table in_claim as select * from app.outbox_claim(20, test.in_t());
select test.eq('the urgent email is claimed past the pace', (select count(*)::int from in_claim where to_address = 'in-urgent@in.example.test'), 1);
select test.eq('the paced email waits for the next hour', (select count(*)::int from in_claim where to_address = 'in-paced@in.example.test'), 0);

-- the kick
create temp table in_kick as select public.server_notify_kick(null) k;
select test.eq('the kick answers what is due', (select array_to_string(array(select jsonb_object_keys(k) order by 1), ',') from in_kick), 'email,events,phone,push');
select test.eq('no push kinds: no push', (select (k ->> 'push')::boolean from in_kick), false);
select test.ok('the kick says whether an urgent email waits', (select jsonb_typeof(k -> 'email') = 'boolean' from in_kick));
select test.eq('once claimed, no urgent email waits', app.outbox_urgent_waiting(test.in_t()), 0);

-- a push is due when its notice is written
select test.ok('a push never waits for its email''s due time', position('_send_after' in pg_get_functiondef('app.push_from_notice()'::regprocedure)) = 0);

select test.ok('only the service key may kick', not has_function_privilege('authenticated', 'public.server_notify_kick(text[])', 'execute')
  and not has_function_privilege('anon', 'public.server_notify_kick(text[])', 'execute') and has_function_privilege('service_role', 'public.server_notify_kick(text[])', 'execute'));
