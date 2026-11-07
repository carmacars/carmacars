-- 99: instant notifications (migration 0670, docs/changes/2026-11-07-r32-edge-cpu-notify.md): an urgent email is claimed
-- even when the hour's pace is used up, a paced one waits; the kick answers what is due; a push never waits for its
-- email. Fixtures start with "in"; addresses are example.test.
select test.suite('99 instant notifications');

select test.ok('a staff alert marked urgent is urgent', app.outbox_urgent('urgent', 2::smallint, now() - interval '2 hours', now()));
select test.ok('a fresh first-class customer email is urgent', app.outbox_urgent(null, 1::smallint, now() - interval '5 minutes', now()));
select test.ok('a first-class email from a held backlog is paced', not app.outbox_urgent(null, 1::smallint, now() - interval '3 hours', now()));
select test.ok('a digest is paced', not app.outbox_urgent(null, 4::smallint, now(), now()));

-- the hour's pace used up: as many emails sent in the last hour as the pace allows
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, send_after, sent_at, created_at)
select 'renter_review_request', 'transactional', 3, 'renter', 'in-sent-' || g || '@in.example.test', 'In', '{}'::jsonb, 'in-sent-' || g, 'sent',
       now() - interval '30 minutes', now() - interval '20 minutes', now() - interval '30 minutes'
  from generate_series(1, ceil(app.email_day_cap(now()) / 24.0)::integer + 31) g;
select test.ok('the hour''s pace is used up', (app.email_pace(now()) ->> 'hour_used')::int >= (app.email_pace(now()) ->> 'hour_cap')::int);

insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, status_reason, send_after, created_at)
values ('staff_payment_failed', 'transactional', 2, 'staff_admin', 'in-urgent@in.example.test', 'In', '{}'::jsonb, 'in-urgent', 'queued', 'urgent', now() - interval '1 minute', now() - interval '1 minute'),
       ('renter_review_request', 'transactional', 3, 'renter', 'in-paced@in.example.test', 'In', '{}'::jsonb, 'in-paced', 'queued', null, now() - interval '1 minute', now() - interval '2 hours');
select test.eq('one urgent email waits', app.outbox_urgent_waiting(now()), 1);
create temp table in_claim as select * from app.outbox_claim(20, now());
select test.eq('the urgent email is claimed past the pace', (select count(*)::int from in_claim where to_address = 'in-urgent@in.example.test'), 1);
select test.eq('the paced email waits for the next hour', (select count(*)::int from in_claim where to_address = 'in-paced@in.example.test'), 0);

-- the kick
create temp table in_kick as select public.server_notify_kick(null) k;
select test.eq('the kick answers what is due', (select array_to_string(array(select jsonb_object_keys(k) order by 1), ',') from in_kick), 'email,events,phone,push');
select test.eq('no push kinds: no push', (select (k ->> 'push')::boolean from in_kick), false);
select test.ok('the urgent email was claimed, so none waits', (select (k ->> 'email')::boolean = false from in_kick));

-- a push is due when its notice is written
select test.ok('a push never waits for its email''s due time', position('_send_after' in pg_get_functiondef('app.push_from_notice()'::regprocedure)) = 0);

select test.ok('only the service key may kick', not has_function_privilege('authenticated', 'public.server_notify_kick(text[])', 'execute')
  and not has_function_privilege('anon', 'public.server_notify_kick(text[])', 'execute') and has_function_privilege('service_role', 'public.server_notify_kick(text[])', 'execute'));
