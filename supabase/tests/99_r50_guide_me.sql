-- 99: Guide me (migrations 3950, 4100): the preference (off by default), a run from start to completed or exited, one active run
-- a person, only staff and Admins, the Admin's report (completion per staff member, the drop-off step), row-level
-- security and the audit trail. Fixtures "g50".
select test.suite('99 r50 guide me: preference, runs, report, access');
select test.mk_user('g50_admin', 'admin');
select test.mk_user('g50_cs', 'va', 'cs');
select test.mk_user('g50_field', 'field');
select test.mk_user('g50_renter', 'renter');

-- ---------------------------------------------------------------- the preference
select test.eq('off by default', public.guide_me_state(test.id('g50_cs')) ->> 'on', 'false');
select test.eq('kept on', public.guide_me_do(test.id('g50_cs'), '{"op":"pref","on":true}') ->> 'on', 'true');
select test.eq('read back on', public.guide_me_state(test.id('g50_cs')) ->> 'on', 'true');
select public.guide_me_do(test.id('g50_cs'), '{"op":"pref","on":false}');
select test.eq('and off again', (select keep_on from guide_me_prefs where user_id = test.id('g50_cs')), false);
select test.eq('nothing to resume yet', public.guide_me_state(test.id('g50_cs')) -> 'run', 'null'::jsonb);

-- ---------------------------------------------------------------- a run: start, steps, completed
create temp table g50 (k text primary key, v uuid);
insert into g50 values ('a', (public.guide_me_do(test.id('g50_cs'), '{"op":"start","flow":"create-offer","portal":"va","total":8,"step":"renter"}') ->> 'id')::uuid);
select test.eq('the run is active at its first step', (select status || ':' || step_index || ':' || step_id from guide_me_runs where id = (select v from g50 where k = 'a')), 'active:0:renter');
select test.eq('it is the run to resume', public.guide_me_state(test.id('g50_cs')) -> 'run' ->> 'flow', 'create-offer');
select public.guide_me_do(test.id('g50_cs'), jsonb_build_object('op', 'step', 'run', (select v from g50 where k = 'a'), 'index', 3, 'step', 'places', 'skipped', jsonb_build_array('dates')));
select test.eq('where it stands, with the step skipped', (select step_index || ':' || step_id || ':' || array_to_string(skipped, ',') from guide_me_runs where id = (select v from g50 where k = 'a')), '3:places:dates');
select test.eq('an index past the end is held at the end', (public.guide_me_do(test.id('g50_cs'), jsonb_build_object('op', 'step', 'run', (select v from g50 where k = 'a'), 'index', 99)) ->> 'ok'), 'true');
select test.eq('held', (select step_index from guide_me_runs where id = (select v from g50 where k = 'a')), 8);
select public.guide_me_do(test.id('g50_cs'), jsonb_build_object('op', 'end', 'run', (select v from g50 where k = 'a'), 'status', 'completed', 'step', 'send'));
select test.eq('completed, with its time', (select status || ':' || (finished_at is not null) from guide_me_runs where id = (select v from g50 where k = 'a')), 'completed:true');
select test.eq('a finished run is not resumed', public.guide_me_state(test.id('g50_cs')) -> 'run', 'null'::jsonb);
select test.eq('a finished run does not change again', public.guide_me_do(test.id('g50_cs'), jsonb_build_object('op', 'end', 'run', (select v from g50 where k = 'a'), 'status', 'exited')) ->> 'status', 'completed');

-- ---------------------------------------------------------------- one active run a person; exited is the drop-off
insert into g50 values ('b', (public.guide_me_do(test.id('g50_cs'), '{"op":"start","flow":"booking-request","portal":"va","total":5,"step":"inbox"}') ->> 'id')::uuid);
insert into g50 values ('c', (public.guide_me_do(test.id('g50_cs'), '{"op":"start","flow":"create-offer","portal":"va","total":8,"step":"renter"}') ->> 'id')::uuid);
select test.eq('a new run ends the open one as exited', (select status from guide_me_runs where id = (select v from g50 where k = 'b')), 'exited');
select public.guide_me_do(test.id('g50_cs'), jsonb_build_object('op', 'end', 'run', (select v from g50 where k = 'c'), 'status', 'exited', 'index', 2, 'step', 'car'));
select test.eq('exited at its step', (select status || ':' || step_id from guide_me_runs where id = (select v from g50 where k = 'c')), 'exited:car');
select test.eq('another person''s run cannot be moved', public.guide_me_do(test.id('g50_field'), jsonb_build_object('op', 'step', 'run', (select v from g50 where k = 'c'), 'index', 5)) ->> 'reason', 'no_run');
select test.eq('field staff run their own', (public.guide_me_do(test.id('g50_field'), '{"op":"start","flow":"field-expense","portal":"field","total":7,"step":"add"}') ->> 'ok'), 'true');

-- ---------------------------------------------------------------- refused
select test.throws('someone not signed up is refused', $$ select public.guide_me_do('00000000-0000-4000-8000-000000000000', '{"op":"pref","on":true}') $$, 'Guide me is for staff');
select test.eq('nor has a state', public.guide_me_state('00000000-0000-4000-8000-000000000000'), null::jsonb);
-- 4100: renters, owners and investors keep it on and record their runs too
select test.eq('a renter keeps it on', public.guide_me_do(test.id('g50_renter'), '{"op":"pref","on":true}') ->> 'on', 'true');
select test.eq('a renter''s run, in the renter portal', (public.guide_me_do(test.id('g50_renter'), '{"op":"start","flow":"renter-sign-pay","portal":"renter","total":5,"step":"open"}') ->> 'ok'), 'true');
select test.eq('an investor portal run is allowed', (select count(*) from pg_constraint where conname = 'guide_me_runs_portal_check' and pg_get_constraintdef(oid) like '%investor%'), 1::bigint);
select test.throws('an unknown operation', $$ select public.guide_me_do(test.id('g50_cs'), '{"op":"wipe"}') $$, 'Unknown Guide me operation');
select test.throws('a workflow id that is not one', $$ select public.guide_me_do(test.id('g50_cs'), '{"op":"start","flow":"Bad Flow!","portal":"va","total":3}') $$, 'Not a Guide me event');
select test.throws('a portal that is not one', $$ select public.guide_me_do(test.id('g50_cs'), '{"op":"start","flow":"create-offer","portal":"nowhere","total":3}') $$, 'Not a Guide me event');
select test.throws('an end that is not one', $$ select public.guide_me_do(test.id('g50_cs'), jsonb_build_object('op', 'end', 'run', (select v from g50 where k = 'c'), 'status', 'deleted')) $$);

-- ---------------------------------------------------------------- the Admin's report
select test.throws('the report is for Admins', $$ select public.guide_me_report(test.id('g50_cs')) $$, 'Only an Admin');
select test.eq('completion per staff member: started, completed, stopped',
  (select (x ->> 'started') || ':' || (x ->> 'completed') || ':' || (x ->> 'exited') || ':' || (x -> 'flows')::text
     from jsonb_array_elements(public.guide_me_report(test.id('g50_admin')) -> 'staff') x where x ->> 'id' = test.id('g50_cs')::text), '3:1:2:["create-offer"]');
select test.eq('the drop-off step of a workflow',
  (select (x ->> 'started') || ':' || (x ->> 'completed') || ':' || (x -> 'drop_off' ->> 'step')
     from jsonb_array_elements(public.guide_me_report(test.id('g50_admin')) -> 'flows') x where x ->> 'flow' = 'create-offer'), '2:1:car');

-- ---------------------------------------------------------------- security and the audit trail
select test.ok('row-level security on both tables', (select bool_and(relrowsecurity) from pg_class where relname in ('guide_me_prefs', 'guide_me_runs')));
select test.eq('admin_all on both tables', (select count(*) from pg_policies where tablename in ('guide_me_prefs', 'guide_me_runs') and policyname = 'admin_all'), 2::bigint);
select test.eq('no browser role runs the functions',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.proname in ('guide_me_state', 'guide_me_do', 'guide_me_report', 'guide_me_staff')
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
select test.ok('search_path ends with pg_temp', (select bool_and(array_to_string(proconfig, ',') like '%pg_temp%') from pg_proc where proname in ('guide_me_state', 'guide_me_do', 'guide_me_report', 'guide_me_staff')));
select test.ok('runs are in the audit log', exists (select 1 from audit_log where entity_table = 'guide_me_runs' and entity_id = (select v from g50 where k = 'a')::text));
drop table g50;
