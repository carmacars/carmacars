-- 99: R50 hotfix 2, the causes behind the errors and the Data health counts of Nov 25 (migrations 5100, 5101).
-- Fixtures start with "rq50e_".
select test.suite('99 r50h2 errors and data health (5100, 5101)');

-- ---------------------------------------------------------------- 1. every function body parses (5100)
-- A migration that turns check_function_bodies off can store a body that only fails at its first call (3870's
-- comms_listing_files: "syntax error at or near )" on the connector's photo_standard). Every SQL and PL/pgSQL body in
-- public and app is validated here.
create temp table rq50e_bad (sig text, err text);
do $$
declare f record;
begin
  for f in select p.oid, p.oid::regprocedure::text sig, l.lanname from pg_proc p join pg_namespace s on s.oid = p.pronamespace join pg_language l on l.oid = p.prolang
            where s.nspname in ('public', 'app') and l.lanname in ('sql', 'plpgsql') and p.prokind = 'f' loop
    begin
      if f.lanname = 'sql' then perform fmgr_sql_validator(f.oid); else perform plpgsql_validator(f.oid); end if;
    exception when others then insert into rq50e_bad values (f.sig, left(sqlerrm, 200));
    end;
  end loop;
end $$;
select test.eq('5100: every SQL and PL/pgSQL function body in public and app parses', (select string_agg(sig || ': ' || err, '; ') from rq50e_bad), null::text);

select test.mk_user('rq50e_admin', 'admin');
select test.mk_user('rq50e_va', 'va', 'cs');
select test.mk_owner('rq50e_olive');
select test.mk_vehicle('rq50e_car', 'rq50e_olive');
select test.mk_vehicle('rq50e_car2', 'rq50e_olive');
select test.mk_renter('rq50e_rita');

-- the connector's photo_standard answers (it failed on every call since 3870)
insert into api_keys (user_id, name, prefix, key_hash, scopes)
values (test.id('rq50e_admin'), 'rq50e key', 'cc_live_rq50e', md5('rq50e-1') || md5('rq50e-2'), array['admin:read']);
select test.eq('5100: photo_standard through the connector answers ok',
  app.api_call(md5('rq50e-1') || md5('rq50e-2'), 'photo_standard', jsonb_build_object('vehicle', test.id('vehicle:rq50e_car')::text), 'rq50e') ->> 'ok', 'true');

-- ---------------------------------------------------------------- 2. pickups of cars already out (5101)
-- confirmed, pickup passed, no deposit held, no signed check-in report: the gated handover refused it
select test.mk_booking('RQ50E-1', 'rq50e_car', 'rq50e_rita', to_char((now() - interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '3 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
select test.throws('before 5101: Data health "Mark picked up" was refused for a car out with no deposit',
  format($q$select app.data_health_fix_pre5101(%L, jsonb_build_object('action', 'mark_picked_up', 'id', %L))$q$, test.id('rq50e_admin'), test.id('booking:RQ50E-1')),
  'deposit');
select test.eq('5101: Data health "Mark picked up" records it at the booked time',
  app.data_health_fix(test.id('rq50e_admin'), jsonb_build_object('action', 'mark_picked_up', 'id', test.id('booking:RQ50E-1'))) ->> 'ok', 'true');
select test.eq('5101: the booking is on rent', (select status::text from bookings where id = test.id('booking:RQ50E-1')), 'on_rent');
select test.ok('5101: what is still owed is a To do, not a refusal',
  exists (select 1 from tasks where booking_id = test.id('booking:RQ50E-1') and task_type = 'pickup_not_recorded'));
select test.eq('5101: no payment or deposit was written', (select count(*)::integer from payments where booking_id = test.id('booking:RQ50E-1') and kind <> 'charge'), 0);

-- ended, never closed, no deposit: Close records the pickup at the booked time, then the return
select test.mk_booking('RQ50E-2', 'rq50e_car2', 'rq50e_rita', to_char((now() - interval '6 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
select test.eq('5101: Close works on a booking whose pickup was never recorded',
  app.booking_close_ended(test.id('rq50e_admin'), jsonb_build_object('booking', 'RQ50E-2')) ->> 'ok', 'true');
select test.ok('5101: it is no longer confirmed', (select status::text from bookings where id = test.id('booking:RQ50E-2')) <> 'confirmed');

-- ---------------------------------------------------------------- 3. a person who leaves hands their work back (5101)
insert into tasks (id, queue, task_type, title, assigned_to, status)
values (test.id('task:rq50e'), 'cs', 'rq50e_test', 'rq50e task', test.id('rq50e_va'), 'in_progress');
insert into leads (id, kind, name, email, assigned_to, status)
values (test.id('lead:rq50e_held'), 'contact', 'Rq50e Held', 'rq50e_held@example.test', test.id('rq50e_va'), 'new');
select app.staff_access_end(test.id('rq50e_va'));
select test.eq('5101: ending access sends the open task back to its queue',
  (select coalesce(assigned_to::text, 'none') || '/' || status from tasks where id = test.id('task:rq50e')), 'none/open');
select test.eq('5101: and the lead', (select assigned_to from leads where id = test.id('lead:rq50e_held')), null::uuid);
select test.eq('5101: the Data health fixes playbook matches "Assigned to someone gone"',
  (select 'inactive_assignee' ~ match_key from heal_playbooks where key = 'data-health.autofix'), true);

-- ---------------------------------------------------------------- 4. leads not followed up: only real gaps (5101)
insert into leads (id, kind, name, email, status, pipeline_stage, followup_step, followup_stopped_at, followup_stop_reason, created_at) values
  (test.id('lead:rq50e_done'), 'owner_program', 'Rq50e Done', 'rq50e_done@example.test', 'new', 'new', 4, now() - interval '1 day', 'All follow-ups sent', now() - interval '20 days'),
  (test.id('lead:rq50e_stopped'), 'owner_program', 'Rq50e Stopped', 'rq50e_stopped@example.test', 'new', 'new', 1, now() - interval '1 day', 'Paused by hand', now() - interval '20 days');
create temp table rq50e_lf as select c -> 'items' items from jsonb_array_elements(app.data_health(now()) -> 'checks') c where c ->> 'key' = 'lead_followup';
select test.ok('5101: a lead whose follow-ups were all sent is not "not followed up"',
  not exists (select 1 from rq50e_lf, jsonb_array_elements(items) i where i ->> 'id' = test.id('lead:rq50e_done')::text));
select test.ok('5101: a lead stopped for another reason still is',
  exists (select 1 from rq50e_lf, jsonb_array_elements(items) i where i ->> 'id' = test.id('lead:rq50e_stopped')::text));

-- ---------------------------------------------------------------- 5. the daily notice only when something changed (5101)
create temp table rq50e_n1 as select (app.job_data_health(now()) ->> 'notices')::integer n;
create temp table rq50e_n2 as select (app.job_data_health(now() + interval '1 minute') ->> 'notices')::integer n;
select test.eq('5101: the same problems a second time send no second notice', (select n from rq50e_n2), 0);
select test.ok('5101: the notice has one link for each problem',
  (select bool_and(l ~ ': https?://') from notifications, regexp_split_to_table(body, E'\n') l
    where code = 'staff_data_health' and user_id = test.id('rq50e_admin')));

-- ---------------------------------------------------------------- 6. To do's close, merge and expire by themselves (5102)
-- a pickup To do on a booking whose pickup is now recorded (RQ50E-1, section 2)
insert into tasks (id, queue, task_type, title, booking_id, status) values
  (test.id('task:rq50e_pu'), 'fleet', 'pickup_unrecorded', 'rq50e pickup', test.id('booking:RQ50E-1'), 'open');
-- one booking, pickup never recorded, past its return: three To do's for one problem
select test.mk_booking('RQ50E-3', 'rq50e_car', 'rq50e_rita', to_char((now() - interval '20 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() - interval '18 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'confirmed');
insert into tasks (id, queue, task_type, title, booking_id, status, created_at) values
  (test.id('task:rq50e_f1'), 'fleet', 'pickup_unrecorded', 'rq50e f1', test.id('booking:RQ50E-3'), 'open', now() - interval '3 hours'),
  (test.id('task:rq50e_f2'), 'admin', 'late_return_admin', 'rq50e f2', test.id('booking:RQ50E-3'), 'open', now() - interval '2 hours'),
  (test.id('task:rq50e_f3'), 'fleet', 'past_trip_open', 'rq50e f3', test.id('booking:RQ50E-3'), 'open', now() - interval '1 hour'),
  (test.id('task:rq50e_old'), 'sales', 'capture_follow_up', 'rq50e old', null, 'open', now() - interval '8 days'),
  (test.id('task:rq50e_new'), 'sales', 'capture_follow_up', 'rq50e new', null, 'open', now() - interval '1 day');
create temp table rq50e_sweep as select app.job_todo_sweep() r;
select test.eq('5102: a pickup To do closes once the pickup is recorded', (select status from tasks where id = test.id('task:rq50e_pu')), 'cancelled');
select test.eq('5102: one booking''s one problem keeps one To do (past trip open)',
  (select string_agg(task_type || '=' || status, ',' order by task_type) from tasks where booking_id = test.id('booking:RQ50E-3') and title like 'rq50e f%'),
  'late_return_admin=cancelled,past_trip_open=open,pickup_unrecorded=cancelled');
select test.ok('5102: the merged ones say where they went',
  (select bool_and(completion_note like 'Merged into "rq50e f3"%') from tasks where id in (test.id('task:rq50e_f1'), test.id('task:rq50e_f2'))));
select test.eq('5102: a week-old follow-up expires, a day-old one stays',
  (select string_agg(title || '=' || status, ',' order by title) from tasks where id in (test.id('task:rq50e_old'), test.id('task:rq50e_new'))),
  'rq50e new=open,rq50e old=cancelled');

-- ---------------------------------------------------------------- 7. self-healing escalates a problem once (5102)
insert into heal_incidents (id, fingerprint, source, key, title, status, first_seen, last_seen) values
  (test.id('heal:rq50e_a'), 'rq50e:flap', 'queue', 'rq50e_flap', 'rq50e flap', 'open', now(), now());
select app.heal_escalate(test.id('heal:rq50e_a'), 'rq50e first');
update heal_incidents set status = 'healed', healed_at = now(), healed_by = 'itself' where id = test.id('heal:rq50e_a');
insert into heal_incidents (id, fingerprint, source, key, title, status, first_seen, last_seen) values
  (test.id('heal:rq50e_b'), 'rq50e:flap', 'queue', 'rq50e_flap', 'rq50e flap', 'open', now(), now());
select app.heal_escalate(test.id('heal:rq50e_b'), 'rq50e again');
select test.eq('5102: the same problem escalated again within a day makes no second To do',
  (select count(*)::integer from tasks where task_type = 'self_heal' and related_id in (test.id('heal:rq50e_a'), test.id('heal:rq50e_b'))), 1);
select test.ok('5102, 5104: and says where it was counted', (select escalation_reason ~ '(Already escalated as incident #|Counted on the open bug report BR-)' from heal_incidents where id = test.id('heal:rq50e_b')));

-- ---------------------------------------------------------------- 8. told at once: a new request, a car due back (5102)
select test.mk_booking('RQ50E-4', 'rq50e_car2', 'rq50e_rita', to_char((now() + interval '5 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '7 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'requested');
select test.ok('5102: a new request raises the Admin and Sales alert at once',
  exists (select 1 from app_events e where e.entity_id = test.id('booking:RQ50E-4') and e.code like 'staff_alert%'));
select test.mk_booking('RQ50E-5', 'rq50e_car2', 'rq50e_rita', to_char((now() - interval '2 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       to_char((now() + interval '20 minutes') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'on_rent');
-- the alerts are counted on this test's own booking: an earlier 99_ file may leave a car out that is also due back (99_r47b leaves one an hour out
-- of its return time), and app.return_due_alerts counts every car in the window (REQ-117; run 46112569166)
create function test.rq50e_told() returns integer language sql stable as $$
  select count(*)::integer from app_events e where e.entity_id = test.id('booking:RQ50E-5') and e.code like 'staff_alert%' $$;
select app.return_due_alerts(now());
select test.eq('5102: a car due back within 30 minutes is told once', test.rq50e_told(), 1);
select app.return_due_alerts(now() + interval '1 minute');
select test.eq('5102: and not twice', test.rq50e_told(), 1);
select app.return_due_alerts(now() + interval '21 minutes');
select test.eq('5102: then at the return time', test.rq50e_told(), 2);

-- ---------------------------------------------------------------- 9. one bug report per self-healing problem (5104)
insert into heal_incidents (id, fingerprint, source, key, title, status, first_seen, last_seen) values
  (test.id('heal:rq50e_c'), 'rq50e:once', 'queue', 'rq50e_once', 'rq50e once', 'open', now() - interval '3 days', now() - interval '3 days');
select app.heal_escalate(test.id('heal:rq50e_c'), 'rq50e first', now() - interval '3 days');
update heal_incidents set status = 'healed', healed_at = now() - interval '3 days', healed_by = 'itself' where id = test.id('heal:rq50e_c');
insert into heal_incidents (id, fingerprint, source, key, title, status, first_seen, last_seen) values
  (test.id('heal:rq50e_d'), 'rq50e:once', 'queue', 'rq50e_once', 'rq50e once', 'open', now(), now());
select app.heal_escalate(test.id('heal:rq50e_d'), 'rq50e again');
select test.eq('5104: the same problem days later files no second bug report',
  (select count(distinct bug_report_id)::integer from heal_incidents where id in (test.id('heal:rq50e_c'), test.id('heal:rq50e_d'))), 1);
select test.eq('5104: the open report counts it', (select (r.context ->> 'times')::integer from bug_reports r join heal_incidents h on h.bug_report_id = r.id where h.id = test.id('heal:rq50e_d')), 2);
update heal_incidents set status = 'healed', healed_at = now() - interval '2 hours', healed_by = 'itself', last_seen = now() - interval '2 hours' where id = test.id('heal:rq50e_d');
select app.heal_close_reports(now());
select test.eq('5104: the report closes by itself once the problem has been gone an hour',
  (select r.status from bug_reports r join heal_incidents h on h.bug_report_id = r.id where h.id = test.id('heal:rq50e_d')), 'fixed');
