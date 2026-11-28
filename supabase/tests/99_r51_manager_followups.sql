-- 99: R51 manager follow-ups (migration 5310, REQ-138; docs/changes/2026-11-27-r51-staff.md). A manager's team needs
-- follow-ups (academy stalled, onboarding open, a missed shift or job); the manager is told, follows up with a note once
-- the Manager section is passed, overdue ones go to the Admins, and a weekly summary arrives. Fixtures "mf51".
select test.suite('99 r51 manager follow-ups: the To dos, closing them, the Manager section, overdue, the weekly summary');

select test.mk_user('mf51_admin', 'admin');
select test.mk_user('mf51_boss', 'va', 'sales');
select test.mk_user('mf51_slow', 'va', 'cs');
select test.mk_user('mf51_new', 'va', 'cs');
select test.mk_user('mf51_field', 'field');
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
update users set created_at = now() - interval '10 days', phone = '+16475550181' where id = test.id('mf51_slow');
update users set created_at = now() - interval '10 days' where id in (test.id('mf51_new'), test.id('mf51_field'));
update staff_profiles set onboarding_exempt = false where user_id = test.id('mf51_new');
select pg_temp.dr('mf51_admin', 'admin_do', 'staff_manager_set', jsonb_build_object('user_id', test.id('mf51_boss'), 'manager', true));
select pg_temp.dr('mf51_admin', 'admin_do', 'staff_team_set', jsonb_build_object('user_id', u, 'manager_id', test.id('mf51_boss')))
  from unnest(array[test.id('mf51_slow'), test.id('mf51_new'), test.id('mf51_field')]) u;

-- ================================================================ the Manager path
select test.ok('a manager has the Manager path', 'manager' = any (app.academy_paths_of(test.id('mf51_boss'))));
select test.ok('a member does not', not ('manager' = any (coalesce(app.academy_paths_of(test.id('mf51_slow')), '{}'))));
select test.eq('enrolled with 7 days before it holds them', (select gate || '/' || (lock_from > now() + interval '6 days') from academy_enrollments where user_id = test.id('mf51_boss') and path_code = 'manager'), 'true/true');
select test.ok('the section teaches and tests: 3 lessons, 5 questions', (select count(*) from academy_lessons l join academy_sections s on s.id = l.section_id where s.slug = 'manager-follow-up') = 3
  and (select count(*) from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'manager-follow-up') = 5);
select test.eq('not passed yet', app.manager_section_passed(test.id('mf51_boss')), false);

-- ================================================================ the follow-ups
-- a field shift booked and missed, a field job not started
insert into field_shift_slots (id, starts_at, ends_at, capacity) values (test.id('mf51:slot'), now() - interval '1 day 6 hours', now() - interval '1 day 2 hours', 1);
insert into field_shift_plans (id, slot_id, staff_id, starts_at, ends_at) values (test.id('mf51:plan'), test.id('mf51:slot'), test.id('mf51_field'), now() - interval '1 day 6 hours', now() - interval '1 day 2 hours');
insert into field_jobs (id, kind, vehicle_id, assigned_to, scheduled_at, status) select test.id('mf51:job'), 'detail', id, test.id('mf51_field'), now() - interval '5 hours', 'scheduled' from vehicles limit 1;
select test.eq('the job makes them', (app.job_team_followups() ->> 'made')::int >= 4, true);
select test.eq('the kinds, member by member',
  (select string_agg(app.staff_display_name(member_id) || ':' || kind, ',' order by app.staff_display_name(member_id), kind) from team_followups where manager_id = test.id('mf51_boss') and kind <> 'kpi'),
  (select string_agg(x, ',' order by x) from unnest(array[app.staff_display_name(test.id('mf51_field')) || ':academy', app.staff_display_name(test.id('mf51_field')) || ':missed_job',
     app.staff_display_name(test.id('mf51_field')) || ':missed_shift', app.staff_display_name(test.id('mf51_new')) || ':academy', app.staff_display_name(test.id('mf51_new')) || ':onboarding',
     app.staff_display_name(test.id('mf51_slow')) || ':academy']) x));
select test.eq('run again: nothing twice', (app.job_team_followups() ->> 'made')::int, 0);
select test.ok('the manager is told', exists (select 1 from app_events where payload ->> 'rule' = 'team_followup' and payload ->> 'assigned_to' = test.id('mf51_boss')::text));
select test.ok('a missed shift names the time', exists (select 1 from team_followups where kind = 'missed_shift' and ref_id = test.id('mf51:plan') and detail like 'Missed shift: %no shift clocked.'));

-- closed until the Manager section is passed
select test.eq('My team: follow-ups wait for the Manager section', (select (j ->> 'manager_passed') || '/' || jsonb_array_length(j -> 'followups') || '/' || ((j ->> 'followups_waiting')::int > 0)
  from (select pg_temp.dr('mf51_boss', 'ops_read', 'my_team') j) x), 'false/0/true');
select test.throws('closing one waits for the section', format($$select pg_temp.dr('mf51_boss', 'ops_do', 'team_followup_done', jsonb_build_object('id', %L, 'note', 'Called'))$$,
  (select id from team_followups where member_id = test.id('mf51_slow') and kind = 'academy')), '%Manager section%');
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed) select test.id('mf51_boss'), id, 5, 5, 10000, true from academy_sections where slug = 'manager-follow-up';
select test.eq('passed: the follow-ups show, with the member''s mobile for Call and Text',
  (select (j ->> 'manager_passed') || '/' || (select x ->> 'phone' from jsonb_array_elements(j -> 'followups') x where x ->> 'member_id' = test.id('mf51_slow')::text limit 1)
     from (select pg_temp.dr('mf51_boss', 'ops_read', 'my_team') j) y), 'true/+16475550181');
select test.throws('a note is needed', format($$select pg_temp.dr('mf51_boss', 'ops_do', 'team_followup_done', jsonb_build_object('id', %L))$$,
  (select id from team_followups where member_id = test.id('mf51_slow') and kind = 'academy')), '%what you agreed%');
select test.eq('followed up, with the note', pg_temp.dr('mf51_boss', 'ops_do', 'team_followup_done', jsonb_build_object('id', (select id from team_followups where member_id = test.id('mf51_slow') and kind = 'academy'), 'note', 'Called: two sections by Friday')) ->> 'ok', 'true');
select test.eq('done, kept with who and the note', (select status || '/' || note || '/' || (done_by = test.id('mf51_boss')) from team_followups where member_id = test.id('mf51_slow') and kind = 'academy'), 'done/Called: two sections by Friday/true');
select test.throws('someone else''s follow-up is refused', format($$select app.team_followup_done(test.id('mf51_slow'), jsonb_build_object('id', %L, 'note', 'x'))$$,
  (select id from team_followups where member_id = test.id('mf51_new') and kind = 'academy')), '%Not one of your%');

-- ================================================================ overdue and the weekly summary
update team_followups set due_at = now() - interval '1 hour' where member_id = test.id('mf51_new') and kind = 'onboarding';
select test.eq('overdue: escalated to the Admins once', (app.job_team_followups() ->> 'escalated')::int || '/' || (app.job_team_followups() ->> 'escalated')::int, '1/0');
select test.ok('the Admins get it', exists (select 1 from app_events where payload ->> 'rule' = 'team_followup_overdue'));
select test.eq('the weekly summary goes to the manager', app.job_team_weekly(), 1);
select test.ok('it says the team''s numbers', exists (select 1 from app_events where payload ->> 'rule' = 'team_weekly' and payload ->> 'assigned_to' = test.id('mf51_boss')::text
  and payload ->> 'alert_body' like '3 people.%Follow-ups open:%'));
select test.eq('the browser roles cannot run the jobs', has_function_privilege('authenticated', 'app.job_team_followups(timestamptz)', 'execute'), false);
