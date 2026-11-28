-- 99: R51 managers (migration 5201, REQ-131; docs/changes/2026-11-27-r51-staff.md). An Admin marks a manager and assigns
-- staff; the manager reads their team, read only, and nobody else's. Fixtures "mg51".
select test.suite('99 r51 managers: Admin sets managers and teams, a manager reads their team only');

select test.mk_user('mg51_admin', 'admin');
select test.mk_user('mg51_boss', 'va', 'sales');
select test.mk_user('mg51_rep', 'va', 'sales');
select test.mk_user('mg51_field', 'field');
select test.mk_user('mg51_other', 'va', 'cs');
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;

-- ================================================================ 1. Admin sets them
select test.throws('assign to someone who is not a manager', $$select pg_temp.dr('mg51_admin', 'admin_do', 'staff_team_set', jsonb_build_object('user_id', test.id('mg51_rep'), 'manager_id', test.id('mg51_boss')))$$, '%manager first%');
select test.eq('Admin marks a manager', pg_temp.dr('mg51_admin', 'admin_do', 'staff_manager_set', jsonb_build_object('user_id', test.id('mg51_boss'), 'manager', true)) ->> 'manager', 'true');
select test.eq('Admin assigns a rep', pg_temp.dr('mg51_admin', 'admin_do', 'staff_team_set', jsonb_build_object('user_id', test.id('mg51_rep'), 'manager_id', test.id('mg51_boss'))) ->> 'changed', 'true');
select test.eq('Admin assigns a field person', pg_temp.dr('mg51_admin', 'admin_do', 'staff_team_set', jsonb_build_object('user_id', test.id('mg51_field'), 'manager_id', test.id('mg51_boss'))) ->> 'changed', 'true');
select test.throws('nobody manages themself', $$select pg_temp.dr('mg51_admin', 'admin_do', 'staff_team_set', jsonb_build_object('user_id', test.id('mg51_boss'), 'manager_id', test.id('mg51_boss')))$$, '%themself%');
-- no loop: the rep becomes a manager; the boss cannot be put under the rep
select pg_temp.dr('mg51_admin', 'admin_do', 'staff_manager_set', jsonb_build_object('user_id', test.id('mg51_rep'), 'manager', true));
select test.throws('a team cannot loop back', $$select pg_temp.dr('mg51_admin', 'admin_do', 'staff_team_set', jsonb_build_object('user_id', test.id('mg51_boss'), 'manager_id', test.id('mg51_rep')))$$, '%loop%');
select pg_temp.dr('mg51_admin', 'admin_do', 'staff_manager_set', jsonb_build_object('user_id', test.id('mg51_rep'), 'manager', false));
select test.throws('staff cannot set managers', $$select app.staff_manager_set(test.id('mg51_boss'), jsonb_build_object('user_id', test.id('mg51_other')))$$);
select test.eq('both are told: the manager and the member',
  (select count(*) from app_events where payload ->> 'rule' = 'team_changed' and entity_id = test.id('mg51_rep') and payload ->> 'kind' like 'team_changed:joined%')
  || '/' || (select count(*) from app_events where payload ->> 'rule' = 'team_changed' and entity_id = test.id('mg51_rep') and payload ->> 'kind' like 'team_changed:manager%'), '1/1');
select test.eq('the roles say manager and the team size', (select (r ->> 'manager') || '/' || (r ->> 'team_size') from (select app.my_roles(test.id('mg51_boss')) r) x), 'true/2');
select test.eq('a member is not a manager', app.my_roles(test.id('mg51_rep')) ->> 'manager', 'false');
select test.eq('Admin''s staff list names the manager',
  (select pg_temp.dr('mg51_admin', 'admin_read', 'staff_teams') -> 'people' -> test.id('mg51_rep')::text ->> 'manager'), app.staff_display_name(test.id('mg51_boss')));

-- ================================================================ 2. what the manager reads
insert into staff_clock_entries (user_id, started_at, ended_at, source) values (test.id('mg51_rep'), now() - interval '3 hours', now() - interval '1 hour', 'clock');
insert into field_jobs (kind, vehicle_id, assigned_to, scheduled_at, status) select 'detail', id, test.id('mg51_field'), now() + interval '1 day', 'scheduled' from vehicles limit 1;
create temp table mg51_t as select pg_temp.dr('mg51_boss', 'ops_read', 'my_team') j;
select test.eq('the team: both members, nobody else', (select string_agg(x ->> 'id', ',' order by x ->> 'id') from mg51_t, jsonb_array_elements(j -> 'members') x),
  (select string_agg(u::text, ',' order by u::text) from unnest(array[test.id('mg51_rep'), test.id('mg51_field')]) u));
select test.eq('hours in the last 7 days', (select (x ->> 'minutes_7d')::int from mg51_t, jsonb_array_elements(j -> 'members') x where x ->> 'id' = test.id('mg51_rep')::text), 120);
select test.eq('field jobs open', (select (x ->> 'jobs_open')::int from mg51_t, jsonb_array_elements(j -> 'members') x where x ->> 'id' = test.id('mg51_field')::text), 1);
select test.ok('academy and pay owed are there', (select bool_and(x ? 'academy' and x -> 'pay' ? 'commission_cents' and x -> 'pay' ? 'pay_lines_cents') from mg51_t, jsonb_array_elements(j -> 'members') x));
select test.ok('no pay details, address or contact in the team read',
  (select j::text !~ '(account_no|transit|home_address|example\.test|\+1647)' from mg51_t));
select test.lives('one member: the scorecard, jobs, hours and activity', $$select pg_temp.dr('mg51_boss', 'ops_read', 'team_member', jsonb_build_object('user_id', test.id('mg51_rep')))$$);
select test.ok('one member: the parts', (select x ? 'scorecard' and x ? 'jobs' and x ? 'clock' and x ? 'activity' from (select pg_temp.dr('mg51_boss', 'ops_read', 'team_member', jsonb_build_object('user_id', test.id('mg51_rep'))) x) q));
select test.throws('someone not on the team is refused', $$select pg_temp.dr('mg51_boss', 'ops_read', 'team_member', jsonb_build_object('user_id', test.id('mg51_other')))$$, '%Not on your team%');
select test.throws('a non-manager has no team', $$select pg_temp.dr('mg51_other', 'ops_read', 'my_team')$$, '%Only a manager%');
select test.throws('a member cannot read their manager', $$select pg_temp.dr('mg51_rep', 'ops_read', 'team_member', jsonb_build_object('user_id', test.id('mg51_boss')))$$, '%Not on your team%');

-- ================================================================ 3. no longer a manager: the team is unassigned
select pg_temp.dr('mg51_admin', 'admin_do', 'staff_manager_set', jsonb_build_object('user_id', test.id('mg51_boss'), 'manager', false));
select test.eq('unmarked: the team is unassigned', (select count(*) from staff_profiles where manager_id = test.id('mg51_boss')), 0::bigint);
select test.throws('unmarked: the team read is refused', $$select pg_temp.dr('mg51_boss', 'ops_read', 'my_team')$$, '%Only a manager%');
select test.eq('the browser roles cannot call the reads', has_function_privilege('authenticated', 'app.team_member_read(uuid, jsonb)', 'execute'), false);
