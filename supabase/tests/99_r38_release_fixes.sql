-- 99: release 38's fixes (migration 2360): the WhatsApp confirmation as its own fact, what each person is waiting on, the
-- Admin's confirm-and-approve, and the offer of a person who is never credited. Fixtures start with "r38"; example.test.
select test.suite('99 r38 release fixes');

select test.mk_user('r38_admin', 'admin');
select test.mk_user('r38_fleet', 'va', 'fleet');
select test.mk_user('r38_hire', 'va', 'sales');
select test.mk_user('r38_cs', 'va', 'cs');
update staff_profiles set onboarding_exempt = false where user_id in (test.id('r38_hire'), test.id('r38_cs'));

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.st(p_user text) returns jsonb language sql as $$ select app.staff_onboarding_state(test.id(p_user)) $$;
create function pg_temp.asked(p_user text) returns bigint language sql as
$$ select count(*) from tasks where task_type = 'approve_onboarding' and related_id = test.id(p_user) $$;

-- ---------------------------------------------------------------- A. WhatsApp marked at step 1 changes nothing else
select pg_temp.dr('r38_admin', 'ops_do', 'staff_whatsapp_mark', jsonb_build_object('user', test.id('r38_hire'), 'joined', true));
select test.eq('A marked at step 1: the WhatsApp step is done', (pg_temp.st('r38_hire') ->> 'whatsapp')::boolean, true);
select test.eq('A marked at step 1: the academy and the agreement are unchanged',
  (pg_temp.st('r38_hire') ->> 'academy') || '/' || (pg_temp.st('r38_hire') ->> 'agreement') || '/' || (pg_temp.st('r38_hire') ->> 'step'), 'false/false/academy');
select test.eq('A marked at step 1: still held', app.staff_fully_onboarded(test.id('r38_hire')), false);
select test.eq('A marked at step 1: no approval asked', pg_temp.asked('r38_hire'), 0::bigint);
select test.ok('A waiting on: the academy and the agreement, not WhatsApp',
  (select bool_and(x not like 'WhatsApp%') and bool_or(x like 'Academy%') and bool_or(x = 'Staff agreement signature')
     from jsonb_array_elements_text(pg_temp.st('r38_hire') -> 'waiting_on') x));
select test.throws('A confirm and approve: refused before the agreement, saying what is missing',
  format('select pg_temp.dr(%L, %L, %L, %L::jsonb)', 'r38_admin', 'ops_do', 'staff_whatsapp_approve', jsonb_build_object('user', test.id('r38_hire'))), 'Waiting on');

insert into academy_waivers (user_id, waived_by, reason) values (test.id('r38_hire'), test.id('r38_admin'), 'Passed elsewhere');
select test.eq('A after the academy: the agreement next', pg_temp.st('r38_hire') ->> 'step', 'agreement');
select test.eq('A after the academy: still no approval asked', pg_temp.asked('r38_hire'), 0::bigint);
update staff_profiles set agreement_waived_at = now(), agreement_waived_by = test.id('r38_admin'), agreement_waived_reason = 'Signed on paper' where user_id = test.id('r38_hire');
select test.eq('A after the agreement: the early WhatsApp counts, waiting for approval', pg_temp.st('r38_hire') ->> 'step', 'approval');
select test.eq('A after the agreement: the approval is asked once', pg_temp.asked('r38_hire'), 1::bigint);
select test.eq('A waiting on: the approval', pg_temp.st('r38_hire') -> 'waiting_on', '["Approval by an Admin or a Fleet VA"]'::jsonb);
select test.ok('A Fleet sees the person with what is missing',
  exists (select 1 from jsonb_array_elements(pg_temp.dr('r38_fleet', 'va_read', 'staff_onboarding_approvals')) x
           where x ->> 'user_id' = test.id('r38_hire')::text and x ->> 'step' = 'approval' and x -> 'waiting_on' ? 'Approval by an Admin or a Fleet VA'));

-- taken back at the approval step: back to the WhatsApp step, the earlier steps kept
select pg_temp.dr('r38_admin', 'ops_do', 'staff_whatsapp_mark', jsonb_build_object('user', test.id('r38_hire'), 'joined', false));
select test.eq('A taken back: the WhatsApp step, academy and agreement kept', (pg_temp.st('r38_hire') ->> 'step') || '/' || (pg_temp.st('r38_hire') ->> 'academy') || '/' || (pg_temp.st('r38_hire') ->> 'agreement'), 'whatsapp/true/true');
select test.ok('A taken back: listed for Fleet, waiting on the WhatsApp groups',
  exists (select 1 from jsonb_array_elements(pg_temp.dr('r38_fleet', 'va_read', 'staff_onboarding_approvals')) x
           where x ->> 'user_id' = test.id('r38_hire')::text and x ->> 'step' = 'whatsapp' and x -> 'waiting_on' ? 'WhatsApp CarmaCars Team group confirmation'));

-- ---------------------------------------------------------------- B. an Admin confirms the groups and approves in one step
select test.throws('B Fleet cannot confirm and approve', format('select pg_temp.dr(%L, %L, %L, %L::jsonb)', 'r38_fleet', 'ops_do', 'staff_whatsapp_approve', jsonb_build_object('user', test.id('r38_hire'))), 'Admin');
select pg_temp.dr('r38_admin', 'ops_do', 'staff_whatsapp_approve', jsonb_build_object('user', test.id('r38_hire')));
select test.eq('B onboarded', app.staff_fully_onboarded(test.id('r38_hire')), true);
select test.ok('B audited', exists (select 1 from audit_log where action = 'staff_whatsapp_confirmed_and_approved' and entity_id = test.id('r38_hire')::text and actor_user_id = test.id('r38_admin')));
select test.eq('B nothing missing', pg_temp.st('r38_hire') -> 'waiting_on', '[]'::jsonb);

-- ---------------------------------------------------------------- C. the r37 tables follow the rules
select test.ok('C channel bookings are audited', exists (select 1 from pg_trigger where tgname = 'audit_channel_bookings'));
select test.eq('C no browser session deletes a bug report', has_table_privilege('authenticated', 'public.bug_reports', 'delete'), false);

-- ---------------------------------------------------------------- D. a person never credited is not asked who found the client
select test.eq('D customer service is never credited', app.credit_blocked(test.id('r38_cs')), true);
