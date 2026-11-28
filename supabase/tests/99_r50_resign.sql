-- 99: staff resign themselves (migrations 5020 and 5021, docs/changes/2026-11-25-r50-resign.md): resign and withdraw,
-- only the person (or an Admin) acts, the jobs and shifts after the last day go back to the queue, one offboarding To do,
-- the emails, the Admin's last day change and End access, the job that ends the access after the last day, the immediate
-- end for someone in onboarding, the connector's list_staff. Fixtures "rs50".
select test.suite('99 r50 resign: resign, withdraw, who may act, shifts back to the queue, one To do, the job, onboarding');
-- process_events() takes the oldest notify_event_batch (500) events: the events earlier files left unprocessed (in a slice, a
-- backlog of some thousands) would hold this file's emails back. They are not this file's: mark them done first.
update app_events set processed_at = now(), process_note = 'test: left by an earlier file' where processed_at is null;
select test.mk_user('rs50_admin', 'admin');
select test.mk_user('rs50_fin', 'va', 'finance');
select test.mk_user('rs50_field', 'field', null, 'driver');
select test.mk_user('rs50_cs', 'va', 'cs');
select test.mk_user('rs50_onb', 'va', 'fleet');
update staff_profiles set started_on = app.today() - 200 where user_id in (test.id('rs50_field'), test.id('rs50_cs'), test.id('rs50_fin'));
-- rs50_onb is still in onboarding (not exempt, not approved)
update staff_profiles set onboarding_exempt = false, onboarding_approved_at = null, started_on = app.today() where user_id = test.id('rs50_onb');
select test.mk_owner('rs50_o');
select test.mk_vehicle('RS50A', 'rs50_o');
create function test.rs50_at(p_days integer, p_hour text default '10:00') returns timestamptz language sql stable as $$
  select ((app.today() + p_days)::text || ' ' || p_hour)::timestamp at time zone 'America/Toronto' $$;
create function test.rs50_r(p_user text) returns staff_resignations language sql stable as $$
  select * from staff_resignations where user_id = test.id(p_user) order by created_at desc limit 1 $$;
-- shifts on days 3 and 12, jobs on days 3 and 12
insert into field_shift_slots (id, starts_at, ends_at, capacity) values
  (test.id('rs50_slot3'), test.rs50_at(3, '09:00'), test.rs50_at(3, '17:00'), 2), (test.id('rs50_slot12'), test.rs50_at(12, '09:00'), test.rs50_at(12, '17:00'), 2),
  (test.id('rs50_slot13'), test.rs50_at(13, '09:00'), test.rs50_at(13, '17:00'), 2);
insert into field_shift_plans (id, slot_id, staff_id, starts_at, ends_at) values
  (test.id('rs50_plan3'), test.id('rs50_slot3'), test.id('rs50_field'), test.rs50_at(3, '09:00'), test.rs50_at(3, '17:00')),
  (test.id('rs50_plan12'), test.id('rs50_slot12'), test.id('rs50_field'), test.rs50_at(12, '09:00'), test.rs50_at(12, '17:00'));
insert into field_jobs (id, kind, vehicle_id, assigned_to, scheduled_at, place) values
  (test.id('rs50_job3'), 'detail', test.id('vehicle:RS50A'), test.id('rs50_field'), test.rs50_at(3, '11:00'), 'Office'),
  (test.id('rs50_job12'), 'detail', test.id('vehicle:RS50A'), test.id('rs50_field'), test.rs50_at(12, '11:00'), 'Office');

-- ================================================================ 1. the facts
select test.eq('the form''s last day is today plus the notice (7 days)', (app.staff_resign_facts(test.id('rs50_field')) ->> 'default_last_day')::date, app.today() + 7);
select test.eq('an established staff member cannot leave today: tomorrow at the earliest', (app.staff_resign_facts(test.id('rs50_field')) ->> 'earliest')::date, app.today() + 1);
select test.eq('someone in onboarding may leave today', (app.staff_resign_facts(test.id('rs50_onb')) ->> 'can_today')::boolean, true);
select test.eq('an Admin is not staff here', app.staff_resign_facts(test.id('rs50_admin')) ->> 'staff', 'false');
select test.ok('the final pay words follow the field agreement and the pay period', app.staff_resign_facts(test.id('rs50_field')) #>> '{words,final_pay_text}' like '%vacation pay%pay period that ends%');
select test.ok('a VA''s final pay follows the VA agreement', app.staff_resign_facts(test.id('rs50_cs')) #>> '{words,final_pay_text}' like '%approved time%commissions%');

-- ================================================================ 2. only the person (or an Admin)
select test.throws('another staff member cannot resign for someone', format($$select app.door(%L, 'aal1', 'ops_do', 'staff_resign', jsonb_build_object('user_id', %L))$$, test.id('rs50_cs'), test.id('rs50_field')), 'Only the person themselves or an Admin');
select test.throws('a last day of today is refused for an established staff member', format($$select app.staff_resign(%L, jsonb_build_object('last_day', app.today()))$$, test.id('rs50_field')), 'at the earliest');
select test.throws('a last day beyond 120 days is refused', format($$select app.staff_resign(%L, jsonb_build_object('last_day', app.today() + 200))$$, test.id('rs50_field')), 'within 120 days');

-- ================================================================ 3. resign
select app.door(test.id('rs50_field'), 'aal1', 'ops_do', 'staff_resign', jsonb_build_object('last_day', app.today() + 7, 'reason', 'Moving to another city'));
select test.eq('the resignation is recorded, pending', (test.rs50_r('rs50_field')).status, 'pending');
select test.eq('with the last day', (test.rs50_r('rs50_field')).last_day, app.today() + 7);
select test.eq('the reason', (test.rs50_r('rs50_field')).reason, 'Moving to another city');
select test.eq('who recorded it: themselves', (test.rs50_r('rs50_field')).created_by, test.id('rs50_field'));
select test.ok('audited', exists (select 1 from audit_log where action = 'staff_resign' and entity_id = (test.rs50_r('rs50_field')).id::text));
select test.eq('they keep their access until the last day', (select status from users where id = test.id('rs50_field')), 'active');
select test.throws('one pending resignation a person', format($$select app.staff_resign(%L, '{}'::jsonb)$$, test.id('rs50_field')), 'already in');

-- the shifts and jobs after the last day go back to the queue; before it they stay
select test.ok('the shift after the last day is cancelled', (select cancelled_at is not null from field_shift_plans where id = test.id('rs50_plan12')));
select test.ok('the shift before the last day stays theirs', (select cancelled_at is null from field_shift_plans where id = test.id('rs50_plan3')));
select test.eq('the job after the last day is unassigned', (select assigned_to from field_jobs where id = test.id('rs50_job12')), null::uuid);
select test.eq('the job before the last day stays theirs', (select assigned_to from field_jobs where id = test.id('rs50_job3')), test.id('rs50_field'));
select test.eq('what went back is on the record', (test.rs50_r('rs50_field')).released ->> 'shifts', '1');
select test.throws('no new shift after their last day', format($$select app.field_shift_book(%L, %L, %L)$$, test.id('rs50_field'), test.id('rs50_slot13'), test.id('rs50_field')), 'after your last day');
select test.throws('no job after their last day', format($$select app.assign_field_job(%L, %L, %L)$$, test.id('rs50_job12'), test.id('rs50_field'), test.id('rs50_admin')), 'after their last day');

-- one To do
select test.eq('one offboarding To do', (select count(*) from tasks where task_type = 'staff_offboarding' and related_id = (test.rs50_r('rs50_field')).id), 1::bigint);
select app.staff_resign_task((test.rs50_r('rs50_field')).id);
select test.eq('raised again, still one', (select count(*) from tasks where task_type = 'staff_offboarding' and related_id = (test.rs50_r('rs50_field')).id), 1::bigint);
select test.ok('it lists final pay, keys, the jobs to reassign and what to hand back', (select detail like '%Final pay%Keys, cards and equipment%Field jobs to reassign: % open%To hand back%' from tasks where id = (test.rs50_r('rs50_field')).task_id));
select test.eq('in the Admin queue', (select queue from tasks where id = (test.rs50_r('rs50_field')).task_id), 'admin');

-- the emails
select test.eq('the person''s confirmation', (select count(*) from app_events where code = 'staff_resignation_confirmed' and payload ->> 'recipient_user_id' = test.id('rs50_field')::text), 1::bigint);
select test.ok('it covers final pay, what to return and how to withdraw',
  (select payload ->> 'final_pay_text' like '%pay period%' and payload ->> 'return_text' like '%key%' and payload ->> 'withdraw_text' like '%Withdraw my resignation%'
     from app_events where code = 'staff_resignation_confirmed' and payload ->> 'recipient_user_id' = test.id('rs50_field')::text));
select test.eq('the Admins'' alert', (select count(*) from app_events where code = 'staff_resignation_received' and entity_id = test.id('rs50_field')), 1::bigint);
select app.process_events();
select test.ok('the Admin gets the alert', exists (select 1 from notification_outbox o where o.code = 'staff_resignation_received' and o.recipient_user_id = test.id('rs50_admin')));
select test.ok('Finance gets it too (final pay)', exists (select 1 from notification_outbox o where o.code = 'staff_resignation_received' and o.recipient_user_id = test.id('rs50_fin')));
select test.ok('the person gets the confirmation', exists (select 1 from notification_outbox o where o.code = 'staff_resignation_confirmed' and o.recipient_user_id = test.id('rs50_field')));
select test.eq('never a text', (select count(*) from notification_catalogue where code like 'staff_resignation_%' and no_text), 3::bigint);

-- the Admin side: list_staff and Staff and roles
select test.eq('list_staff shows the resignation', app.api_staff_row(test.id('rs50_field')) #>> '{resignation,status}', 'resigning');
select test.eq('Staff and roles reads it', app.staff_resignations_read(test.id('rs50_admin'), '{}'::jsonb) #>> array[test.id('rs50_field')::text, 'last_day'], (app.today() + 7)::text);
select test.throws('only an Admin reads every resignation', format($$select app.staff_resignations_read(%L, '{}'::jsonb)$$, test.id('rs50_cs')), null);

-- ================================================================ 4. withdraw
select test.throws('another staff member cannot withdraw it', format($$select app.staff_resign_withdraw(%L, jsonb_build_object('user_id', %L))$$, test.id('rs50_cs'), test.id('rs50_field')), 'Only the person themselves or an Admin');
select app.door(test.id('rs50_field'), 'aal1', 'ops_do', 'staff_resign_withdraw', '{}'::jsonb);
select test.eq('withdrawn', (test.rs50_r('rs50_field')).status, 'withdrawn');
select test.eq('the To do closes', (select status from tasks where id = (test.rs50_r('rs50_field')).task_id), 'cancelled');
select test.eq('the Admins are told', (select count(*) from app_events where code = 'staff_resignation_withdrawn' and entity_id = test.id('rs50_field')), 1::bigint);
select test.throws('nothing left to withdraw', format($$select app.staff_resign_withdraw(%L, '{}'::jsonb)$$, test.id('rs50_field')), 'no resignation');
select test.eq('they can book that shift again', (app.field_shift_book(test.id('rs50_field'), test.id('rs50_slot13'), test.id('rs50_field')) ->> 'id') is not null, true);

-- ================================================================ 5. an Admin records one, changes the last day, the job ends it
select app.staff_resign(test.id('rs50_admin'), jsonb_build_object('user_id', test.id('rs50_cs'), 'last_day', app.today() + 10, 'reason', 'Resigned by email'));
select test.eq('an Admin records a resignation for someone', (test.rs50_r('rs50_cs')).created_by, test.id('rs50_admin'));
select test.throws('only an Admin changes the last day', format($$select app.staff_resign_last_day(%L, jsonb_build_object('user', %L, 'last_day', app.today() + 2))$$, test.id('rs50_cs'), test.id('rs50_cs')), null);
select app.door(test.id('rs50_admin'), 'aal2', 'admin_do', 'staff_resign_last_day', jsonb_build_object('user', test.id('rs50_cs'), 'last_day', app.today() + 2));
select test.eq('the last day moves earlier', (test.rs50_r('rs50_cs')).last_day, app.today() + 2);
select test.eq('still one To do, with the new day', (select count(*) from tasks where task_type = 'staff_offboarding' and related_id = (test.rs50_r('rs50_cs')).id), 1::bigint);
select test.ok('the To do''s title follows', (select title like '%' || app.fmt_day(app.today() + 2) || '%' from tasks where id = (test.rs50_r('rs50_cs')).task_id));
select test.ok('the person is sent the update', exists (select 1 from app_events where code = 'staff_resignation_confirmed' and payload ->> 'recipient_user_id' = test.id('rs50_cs')::text and (payload ->> 'is_update')::boolean));
select test.eq('the job does nothing before the last day has passed', app.job_staff_resignations(now()), 0);
select test.eq('the job ends the access the day after the last day', app.job_staff_resignations(now() + interval '3 days'), 1);
select test.eq('ended', (test.rs50_r('rs50_cs')).status, 'ended');
select test.eq('their access is ended like End access', (select status from users where id = test.id('rs50_cs')), 'suspended');
select test.eq('ended on the last day', (select ended_on from staff_profiles where user_id = test.id('rs50_cs')), app.today());
select test.eq('they stay in Staff and roles as Resigned', app.api_staff_row(test.id('rs50_cs')) #>> '{resignation,status}', 'resigned');
select test.eq('the job does it once', app.job_staff_resignations(now() + interval '3 days'), 0);
select test.throws('no withdrawing after the access ended', format($$select app.staff_resign_withdraw(%L, '{}'::jsonb)$$, test.id('rs50_cs')), 'no resignation');

-- End access on a pending resignation closes it
select app.staff_resign(test.id('rs50_fin'), jsonb_build_object('last_day', app.today() + 7));
select app.admin_do(test.id('rs50_admin'), 'staff_end', jsonb_build_object('user', test.id('rs50_fin')));
select test.eq('End access ends a pending resignation', (test.rs50_r('rs50_fin')).status, 'ended');
select test.eq('with the last day today', (test.rs50_r('rs50_fin')).last_day, app.today());
select test.eq('and the access', (select is_active from staff_profiles where user_id = test.id('rs50_fin')), false);
select test.throws('End access still refuses your own', format($$select app.admin_do(%L, 'staff_end', jsonb_build_object('user', %L))$$, test.id('rs50_admin'), test.id('rs50_admin')), 'your own access');

-- ================================================================ 6. onboarding: today ends the access at once
select test.eq('the person in onboarding is in onboarding', (app.staff_resign_facts(test.id('rs50_onb')) ->> 'in_onboarding')::boolean, true);
select app.door(test.id('rs50_onb'), 'aal1', 'ops_do', 'staff_resign', jsonb_build_object('last_day', app.today()));
select test.eq('resigning today in onboarding ends the access at once', (select status from users where id = test.id('rs50_onb')), 'suspended');
select test.eq('the resignation is ended', (test.rs50_r('rs50_onb')).status, 'ended');
select test.ok('the confirmation says the access has ended', exists (select 1 from app_events where code = 'staff_resignation_confirmed' and payload ->> 'recipient_user_id' = test.id('rs50_onb')::text and payload ->> 'access_ends' like 'Now%'));
select test.eq('still one To do for the Admins', (select count(*) from tasks where task_type = 'staff_offboarding' and related_id = (test.rs50_r('rs50_onb')).id), 1::bigint);

-- ================================================================ 7. security
select test.eq('every resign function runs for the server only', (select string_agg(p.proname, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and (p.proname like 'staff_resign%' or p.proname in ('staff_access_end', 'job_staff_resignations'))
    and (has_function_privilege('authenticated', p.oid, 'execute') or not has_function_privilege('service_role', p.oid, 'execute'))), null::text);
select test.ok('the record is closed to the browser roles', not has_table_privilege('authenticated', 'staff_resignations', 'select') and not has_table_privilege('anon', 'staff_resignations', 'select'));
