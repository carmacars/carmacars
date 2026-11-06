-- 99: hotfix r27b (migration 0534): remote assistant applicants still invited to book a call, or whose booked call time
-- passed, get the AI interview once with the apology email; a past call is No show first; in-person roles and a call
-- still ahead are left alone; the "no interview day" warning leaves the remote roles out. Fixtures start with "rta";
-- example.test addresses only.
select test.suite('99 remote applicants to the AI interview');
update app_events set processed_at = now() where processed_at is null;

create or replace function test.rta_app(p_k text, p_role text, p_status text, p_slot uuid default null) returns uuid language sql as $$
  insert into job_applications (role_id, status, full_name, email, score, work_mode, slot_id, invited_at)
  select r.id, p_status, initcap(p_k) || ' Tester', p_k || '@rta.example.test', 90, r.work_mode, p_slot, now() - interval '3 days'
    from hiring_roles r where r.slug = p_role
  returning id $$;
create or replace function test.rta(p_k text) returns job_applications language sql stable as $$ select * from job_applications where email = p_k || '@rta.example.test' $$;

insert into interview_days (day, start_time, end_time, mode, note) values (app.local_date(now()) - 1, '08:00', '10:00', 'phone', 'rta past'), (app.local_date(now()) + 2, '08:00', '10:00', 'phone', 'rta ahead');
insert into interview_slots (day_id, starts_at, ends_at)
  select d.id, (d.day + time '08:00') at time zone 'America/Toronto', (d.day + time '08:15') at time zone 'America/Toronto' from interview_days d where d.note in ('rta past', 'rta ahead')
  on conflict do nothing;
create temp table rta_slots as
  select (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'rta past' order by s.starts_at limit 1) past,
         (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'rta ahead' order by s.starts_at limit 1) ahead;

select test.rta_app('rtainv', 'va-customer-service', 'invited');
select test.rta_app('rtapast', 'va-fleet-operations', 'booked', (select past from rta_slots));
select test.rta_app('rtaahead', 'sales-remote', 'booked', (select ahead from rta_slots));
select test.rta_app('rtafield', 'sales-in-person', 'invited');
select test.ok('the fixtures have their slots', (select past is not null and ahead is not null from rta_slots));

create temp table rta_n as select app.hiring_remote_to_ai() n;
select test.ok('the invited and the past booked remote applicants are moved (at least these two)', (select n >= 2 from rta_n));
select test.eq('invited: now the AI interview', (test.rta('rtainv')).status || '/' || (select state from ai_interviews where application_id = (test.rta('rtainv')).id), 'invited/sent');
select test.eq('a past call: invited for the AI interview, the slot given back', (test.rta('rtapast')).status || '/' || coalesce((test.rta('rtapast')).slot_id::text, 'none'), 'invited/none');
select test.ok('a past call was marked No show first (logged)', exists (select 1 from audit_log where action = 'hiring_no_show_auto' and entity_id = (test.rta('rtapast')).id::text));
select test.eq('a call still ahead is left alone', (test.rta('rtaahead')).status || '/' || (select count(*) from ai_interviews where application_id = (test.rta('rtaahead')).id), 'booked/0');
select test.eq('in-person roles keep their calls', (test.rta('rtafield')).status || '/' || (select count(*) from ai_interviews where application_id = (test.rta('rtafield')).id), 'invited/0');
select app.process_events();
select test.eq('one apology email each, through the outbox, no no-show email',
  (select count(*) from notification_outbox where code = 'applicant_ai_interview_sorry' and to_address in ('rtainv@rta.example.test', 'rtapast@rta.example.test'))
  || '/' || (select count(*) from notification_outbox where to_address like 'rta%@rta.example.test' and code not in ('applicant_ai_interview_sorry')), '2/0');
select test.ok('the email carries the personal interview link',
  (select bool_and(payload ->> 'interview_url' like '%/careers/interview/%') from notification_outbox where code = 'applicant_ai_interview_sorry' and to_address like 'rta%@rta.example.test'));
select test.eq('run again: nothing more', app.hiring_remote_to_ai(), 0);
select app.process_events();
select test.eq('still one email each', (select count(*) from notification_outbox where code = 'applicant_ai_interview_sorry' and to_address like 'rta%@rta.example.test'), 2::bigint);
select test.eq('each move is kept once', (select count(*) from hiring_ai_moves m join job_applications a on a.id = m.application_id where a.email like 'rta%@rta.example.test'), 2::bigint);
select test.ok('the warning leaves the remote roles out',
  not exists (select 1 from jsonb_array_elements(app.hiring_waiting_by_role()) x join hiring_roles r on r.slug = x ->> 'slug' where r.remote and r.staff_kind = 'va'));
select test.ok('browsers cannot run it', not has_function_privilege('authenticated', 'app.hiring_remote_to_ai(timestamptz)', 'execute')
  and not has_function_privilege('anon', 'app.hiring_remote_to_ai(timestamptz)', 'execute'));
