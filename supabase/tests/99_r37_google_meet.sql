-- 99: release 37 (migration 2303): the interview call link. Not connected: Jitsi, nothing waits. Connected: a booked or
-- moved video call waits for its Google Meet link (its confirmation email held), the job's answer puts the Meet link on the
-- call and into the email, a failure keeps Jitsi, a cancelled call deletes the event; only an Admin sees or changes the
-- connection; the job's functions are the server's only. Fixtures "r37m"; addresses are example.test.
select test.suite('99 r37 google meet (2303)');

select test.mk_user('r37m_admin', 'admin');
select test.mk_user('r37m_cs', 'va', 'cs');
insert into interview_days (id, day, start_time, end_time) values (test.id('day:r37m'), current_date + 3, '10:00', '12:00');
insert into interview_slots (id, day_id, starts_at, ends_at) values
  (test.id('slot:r37m1'), test.id('day:r37m'), now() + interval '3 days', now() + interval '3 days 15 minutes'),
  (test.id('slot:r37m2'), test.id('day:r37m'), now() + interval '4 days', now() + interval '4 days 15 minutes');
insert into job_applications (id, role_id, full_name, email) values
  (test.id('app:r37m1'), (select id from hiring_roles where slug = 'va-customer-service'), 'Remy Example', 'remy@example.test'),
  (test.id('app:r37m2'), (select id from hiring_roles where slug = 'va-customer-service'), 'Rita Example', 'rita@example.test');
create function pg_temp.book(p_app text, p_slot text) returns void language sql as
$$ update job_applications set slot_id = test.id(p_slot), meet_url = 'https://meet.jit.si/CarmaCars-' || substr(md5(random()::text), 1, 16) where id = test.id('app:' || p_app) $$;
create function pg_temp.mail(p_app text) returns uuid language sql as
$$ insert into notification_outbox (code, category, priority, audience, to_address, entity, entity_id, payload, dedupe_key)
   values ('applicant_booked', 'transactional', 1, 'applicant', 'x@example.test', 'job_application', test.id('app:' || p_app), jsonb_build_object('meet_url', 'https://meet.jit.si/x'), 'r37m:' || gen_random_uuid())
   returning id $$;

-- not connected
select pg_temp.book('r37m1', 'slot:r37m1');
select test.eq('not connected: the call keeps its Jitsi link and nothing waits', (select format('%s %s', meet_url like 'https://meet.jit.si/%', meet_sync is null) from job_applications where id = test.id('app:r37m1')), 't t');
create temp table r37m0 as select pg_temp.mail('r37m1') id;
select test.ok('and its email is not held', (select send_after < now() + interval '1 minute' from notification_outbox where id = (select id from r37m0)));
select test.eq('the job is not due', (app.server_jobs_due() ->> 'meet')::boolean, false);

-- connected
update calendar_google_link set status = 'connected', account_email = 'calendar@example.test';
select pg_temp.book('r37m2', 'slot:r37m1');
select test.eq('connected: a booked call waits for its Meet event (Jitsi kept as the fallback)', (select format('%s %s', meet_sync, meet_url like 'https://meet.jit.si/%') from job_applications where id = test.id('app:r37m2')), 'create t');
create temp table r37mm as select pg_temp.mail('r37m2') id;
select test.ok('its confirmation email waits', (select send_after > now() + interval '5 minutes' from notification_outbox where id = (select id from r37mm)));
select test.eq('the job is due', (app.server_jobs_due() ->> 'meet')::boolean, true);
select test.eq('the job sees the call with its times', (select c ->> 'sync' from jsonb_array_elements(public.server_hiring_meet_due() -> 'calls') c where (c ->> 'id')::uuid = test.id('app:r37m2')), 'create');
select test.throws('only a Google Meet link is taken', format($$select public.server_hiring_meet_done(jsonb_build_object('id', %L, 'ok', true, 'event_id', 'ev1', 'meet_url', 'https://evil.example.test/x'))$$, test.id('app:r37m2')), 'Not a Google Meet');
select public.server_hiring_meet_done(jsonb_build_object('id', test.id('app:r37m2'), 'ok', true, 'event_id', 'ev1', 'meet_url', 'https://meet.google.com/abc-defg-hij'));
select test.eq('the Meet link replaces Jitsi on the call', (select format('%s %s %s %s', meet_url, meet_provider, meet_event_id, meet_sync is null) from job_applications where id = test.id('app:r37m2')),
  'https://meet.google.com/abc-defg-hij google ev1 t');
select test.ok('and in its email, which goes at once', (select payload ->> 'meet_url' = 'https://meet.google.com/abc-defg-hij' and send_after <= now() from notification_outbox where id = (select id from r37mm)));
-- moved: the same event is moved
select pg_temp.book('r37m2', 'slot:r37m2');
select test.eq('a moved call moves its event', (select meet_sync from job_applications where id = test.id('app:r37m2')), 'update');
select public.server_hiring_meet_done(jsonb_build_object('id', test.id('app:r37m2'), 'ok', false, 'error', 'quota'));
select test.ok('a failure keeps the Jitsi link and records the error', (select meet_url like 'https://meet.jit.si/%' and meet_sync is null and meet_error = 'quota' from job_applications where id = test.id('app:r37m2'))
  and (select last_error = 'quota' from calendar_google_link));
update job_applications set meet_event_id = 'ev1' where id = test.id('app:r37m2');
update job_applications set slot_id = null, meet_url = null where id = test.id('app:r37m2');
select test.eq('a cancelled call deletes its event', (select meet_sync from job_applications where id = test.id('app:r37m2')), 'delete');
select public.server_hiring_meet_done(jsonb_build_object('id', test.id('app:r37m2'), 'ok', true));
select test.ok('deleted', (select meet_event_id is null and meet_sync is null from job_applications where id = test.id('app:r37m2')));

-- who
select test.ok('an Admin reads the connection: Google is the provider', (select public.door(test.id('r37m_admin'), 'aal2', 'admin_read', 'calendar_google_state', '{}'::jsonb) ->> 'provider' = 'google'));
select test.throws('staff do not', $$select public.door(test.id('r37m_cs'), 'aal2', 'admin_read', 'calendar_google_state', '{}'::jsonb)$$, null);
select test.throws('staff do not disconnect it', $$select public.door(test.id('r37m_cs'), 'aal2', 'admin_do', 'calendar_google_disconnect', '{}'::jsonb)$$, null);
select test.ok('the job''s functions are the server''s only', not has_function_privilege('authenticated', 'public.server_hiring_meet_done(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_hiring_meet_due()', 'execute') and not has_function_privilege('anon', 'app.calendar_google_token()', 'execute'));
select test.ok('the token is never in a table', not exists (select 1 from information_schema.columns where table_name = 'calendar_google_link' and column_name like '%token%'));
update calendar_google_link set status = 'not_connected', account_email = null;
select test.eq('disconnected: Jitsi again', (select public.door(test.id('r37m_admin'), 'aal2', 'admin_read', 'calendar_google_state', '{}'::jsonb) ->> 'provider'), 'jitsi');
