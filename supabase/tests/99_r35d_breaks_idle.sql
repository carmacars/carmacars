-- 99: breaks and inactivity (1800). Start and End break (office staff, clocked in, one at a time, ended by clocking out),
-- the reminder of a break left open, an Admin's edit with the reason (audited), breaks per day on the timesheet, paid or
-- unpaid breaks on the payroll hours; activity kept to the minute (the beat and every action), idle stretches opened only
-- while clocked in, not on a break and within the hours, one alert and one follow-up, closed by the next activity; the
-- pauses (a linked call, the townhall); who reads the idle time (the Admins only) and the KPI. Fixtures "brk"; example.test.
select test.suite('99 r35d breaks and idle');

select test.mk_user('brk_admin', 'admin');
select test.mk_user('brk_cs', 'va', 'cs');        -- the job's person (fixed times, Wednesday 2026-11-18)
select test.mk_user('brk_live', 'va', 'cs');      -- the door's person (real time)
select test.mk_user('brk_fin', 'va', 'finance');
select test.mk_user('brk_fleet', 'va', 'fleet');
select test.mk_user('brk_sales', 'va', 'sales');
select test.mk_user('brk_field', 'field');
update staff_profiles set functions = array[va_function::text] where user_id in (test.id('brk_cs'), test.id('brk_live'), test.id('brk_fin'), test.id('brk_fleet'), test.id('brk_sales'));
create function test.brk(p_who text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, p_call, p_name, p) $$;
-- Toronto wall time on Wednesday 2026-11-18 (customer service works 8:00 to 18:00)
create function test.brk_at(p_hm text) returns timestamptz language sql immutable as $$ select ('2026-11-18 ' || p_hm)::timestamp at time zone 'America/Toronto' $$;
create function test.brk_alerts(p_who text) returns bigint language sql stable as $$
  select count(*) from app_events e where e.code like 'staff_alert_%' and e.payload ->> 'rule' = 'staff_va_idle' and e.entity_id = test.id(p_who) $$;

-- ================================================================ settings
select test.eq('the defaults: breaks paid, reminder 30, idle 10, follow-up 30, nudge 8, call grace 1, townhall grace 10, KPI 120',
  (select format('%s %s %s %s %s %s %s %s', va_breaks_paid, va_break_reminder_minutes, va_idle_alert_minutes, va_idle_followup_minutes, va_idle_nudge_minutes,
                 va_idle_call_grace_minutes, va_idle_townhall_grace_minutes, kpi_idle_minutes_week) from (select (app.settings()).*) s), 't 30 10 30 8 1 10 120');

-- ================================================================ 1. breaks through the door
select test.throws('no break before clocking in', $$select test.brk('brk_live', 'ops_do', 'va_break_start')$$, 'Clock in first');
select test.throws('Sales does not clock in, so no breaks', $$select test.brk('brk_sales', 'ops_do', 'va_break_start')$$, 'customer service, Fleet and Finance');
select test.throws('field staff neither', $$select test.brk('brk_field', 'ops_do', 'va_break_start')$$, 'customer service, Fleet and Finance');
select test.brk('brk_live', 'ops_do', 'va_clock_in');
select test.eq('clocked in: tracked, nothing about idle on their own screen',
  (select format('%s|%s|%s', v ->> 'tracking', v ? 'idle', v -> 'settings' ->> 'idle_nudge_minutes') from (select test.brk('brk_live', 'ops_read', 'va_clock') v) x), 'true|f|8');
select test.eq('Start break with an optional reason: on a break, not tracked',
  (select format('%s|%s', v -> 'break' ->> 'reason', v ->> 'tracking') from (select test.brk('brk_live', 'ops_do', 'va_break_start', '{"reason": "Lunch"}') v) x), 'Lunch|false');
select test.throws('one break at a time', $$select test.brk('brk_live', 'ops_do', 'va_break_start')$$, 'already on a break');
select test.eq('End break', (select (v -> 'break') = 'null'::jsonb and (v -> 'breaks_today' ->> 'count')::int = 1 from (select test.brk('brk_live', 'ops_do', 'va_break_end') v) x), true);
select test.throws('no break to end', $$select test.brk('brk_live', 'ops_do', 'va_break_end')$$, 'not on a break');
select test.eq('a break without a reason', (select test.brk('brk_live', 'ops_do', 'va_break_start') -> 'break' ->> 'reason'), null::text);
select test.brk('brk_live', 'ops_do', 'va_clock_out');
select test.eq('clocking out ends the open break', (select count(*) from staff_breaks where user_id = test.id('brk_live') and ended_at is null), 0::bigint);
select test.eq('activity: the door''s actions touched the person (one row, kept to the minute)', (select count(*) from staff_activity where user_id = test.id('brk_live')), 1::bigint);
select test.eq('clocked out: the beat says not tracked and writes nothing', (select test.brk('brk_live', 'ops_do', 'va_activity') ->> 'tracking'), 'false');
select test.eq('a renter''s or an Admin''s action writes no activity', (select count(*) from staff_activity where user_id = test.id('brk_admin')), 0::bigint);

-- ================================================================ 2. activity kept to the minute
insert into staff_clock_entries (user_id, started_at, created_by) values (test.id('brk_cs'), test.brk_at('09:00'), test.id('brk_cs'));
select app.va_activity_touch(test.id('brk_cs'), test.brk_at('11:00'));
select app.va_activity_touch(test.id('brk_cs'), test.brk_at('11:00:40'));
select test.eq('two beats within a minute: one write', (select last_at from staff_activity where user_id = test.id('brk_cs')), test.brk_at('11:00'));
select app.va_activity_touch(test.id('brk_cs'), test.brk_at('11:45'));
select test.eq('a minute later: written', (select last_at from staff_activity where user_id = test.id('brk_cs')), test.brk_at('11:45'));

-- ================================================================ 3. idle: one alert, one follow-up, closed by activity
select app.job_va_breaks_idle(test.brk_at('11:55'));
select test.eq('10 minutes is not more than 10: no stretch', (select count(*) from staff_idle_periods where user_id = test.id('brk_cs')), 0::bigint);
select app.job_va_breaks_idle(test.brk_at('11:57'));
select test.eq('12 minutes: a stretch from the last activity, alerted', (select format('%s|%s', started_at = test.brk_at('11:45'), alerted_at is not null) from staff_idle_periods where user_id = test.id('brk_cs')), 't|t');
select test.eq('the alert names the person, the role, since when and how long',
  (select e.payload ->> 'alert_title' from app_events e where e.payload ->> 'rule' = 'staff_va_idle' and e.entity_id = test.id('brk_cs') order by e.created_at limit 1), 'Brk Cs (Customer service) inactive since 11:45, 12 min');
select test.eq('the alert goes to the Admins', (select who from staff_alert_rules where rule = 'staff_va_idle'), '{admin}'::text[]);
select app.job_va_breaks_idle(test.brk_at('11:58'));
select app.job_va_breaks_idle(test.brk_at('12:10'));
select test.eq('no alert spam: still one alert, one stretch', format('%s|%s', test.brk_alerts('brk_cs'), (select count(*) from staff_idle_periods where user_id = test.id('brk_cs'))), '1|1');
select app.job_va_breaks_idle(test.brk_at('12:15'));
select app.job_va_breaks_idle(test.brk_at('12:20'));
select test.eq('the follow-up at 30 minutes, once', format('%s|%s', test.brk_alerts('brk_cs'), (select followup_at = test.brk_at('12:15') from staff_idle_periods where user_id = test.id('brk_cs'))), '2|t');
select app.va_activity_touch(test.id('brk_cs'), test.brk_at('12:21'));
select test.eq('back: the stretch ends at the activity (36 min)', (select format('%s|%s', ended_at = test.brk_at('12:21'), floor(extract(epoch from ended_at - started_at) / 60))
  from staff_idle_periods where user_id = test.id('brk_cs')), 't|36');
select test.eq('and no stretch is open', (select idle_id from staff_activity where user_id = test.id('brk_cs')), null::uuid);

-- ================================================================ 4. never on a break, outside the hours or clocked out
insert into staff_breaks (user_id, clock_entry_id, started_at, ended_at)
select test.id('brk_cs'), id, test.brk_at('13:00'), test.brk_at('13:40') from staff_clock_entries where user_id = test.id('brk_cs') and ended_at is null;
update staff_breaks set ended_at = null where user_id = test.id('brk_cs') and started_at = test.brk_at('13:00');
select app.job_va_breaks_idle(test.brk_at('13:25'));
select test.eq('on a break: no stretch', (select count(*) from staff_idle_periods where user_id = test.id('brk_cs')), 1::bigint);
select app.job_va_breaks_idle(test.brk_at('13:31'));
select test.eq('a break open 31 minutes: reminded once (the person and the Admins)',
  (select format('%s|%s', count(*), (select who from staff_alert_rules where rule = 'staff_break_long')) from app_events e where e.payload ->> 'rule' = 'staff_break_long' and e.entity_id = test.id('brk_cs')), '1|{assigned,admin}');
select app.job_va_breaks_idle(test.brk_at('13:35'));
select test.eq('not twice', (select count(*) from app_events e where e.payload ->> 'rule' = 'staff_break_long' and e.entity_id = test.id('brk_cs')), 1::bigint);
update staff_breaks set ended_at = test.brk_at('13:40') where user_id = test.id('brk_cs') and ended_at is null;
select app.job_va_breaks_idle(test.brk_at('13:49'));
select test.eq('the idle wait starts again at the end of the break', (select count(*) from staff_idle_periods where user_id = test.id('brk_cs')), 1::bigint);
select app.va_activity_touch(test.id('brk_cs'), test.brk_at('17:55'));
select app.job_va_breaks_idle(test.brk_at('18:20'));
select test.eq('after the scheduled hours: no stretch', (select count(*) from staff_idle_periods where user_id = test.id('brk_cs')), 1::bigint);
update staff_clock_entries set ended_at = test.brk_at('17:00') where user_id = test.id('brk_cs') and ended_at is null;
select app.job_va_breaks_idle(test.brk_at('18:30'));
select test.eq('clocked out: every stretch is closed, none open', (select count(*) from staff_idle_periods where user_id = test.id('brk_cs') and ended_at is null), 0::bigint);

-- ================================================================ 5. the pauses: a linked call, the townhall
select test.mk_user('brk_quo', 'va', 'fleet');
update staff_profiles set functions = '{fleet}' where user_id = test.id('brk_quo');
select test.throws('only an Admin sets a Quo user', $$select test.brk('brk_fleet', 'ops_do', 'staff_quo_user_set', jsonb_build_object('user_id', test.id('brk_quo'), 'quo_user_id', 'USbrk01'))$$, 'Admin');
select test.brk('brk_admin', 'admin_do', 'staff_quo_user_set', jsonb_build_object('user_id', test.id('brk_quo'), 'quo_user_id', 'USbrk01'));
insert into phone_threads (number) values ('+14165550199') on conflict do nothing;
insert into staff_clock_entries (user_id, started_at, created_by) values (test.id('brk_quo'), test.brk_at('11:00'), test.id('brk_quo'));
select app.va_activity_touch(test.id('brk_quo'), test.brk_at('11:30'));
-- a Quo call by their Quo user from 11:35, ended 11:55
insert into phone_activity (thread_id, kind, direction, quo_id, quo_user_id, started_at, ended_at)
select id, 'call', 'in', 'ACbrk01', 'USbrk01', test.brk_at('11:35'), test.brk_at('11:55') from phone_threads where number = '+14165550199';
select app.job_va_breaks_idle(test.brk_at('11:50'));
select test.eq('pause (call): on a Quo call of their user, 20 minutes after the last touch, no stretch', (select count(*) from staff_idle_periods where user_id = test.id('brk_quo')), 0::bigint);
select app.job_va_breaks_idle(test.brk_at('11:56'));
select test.eq('pause (call): a minute after the end still counts', (select count(*) from staff_idle_periods where user_id = test.id('brk_quo')), 0::bigint);
select app.job_va_breaks_idle(test.brk_at('12:05'));
select test.eq('after the call: the wait counts from the call (9 min), no stretch yet', (select count(*) from staff_idle_periods where user_id = test.id('brk_quo')), 0::bigint);
select app.job_va_breaks_idle(test.brk_at('12:08'));
select test.eq('12 minutes after the call: a stretch from 11:56', (select started_at = test.brk_at('11:56') from staff_idle_periods where user_id = test.id('brk_quo') and ended_at is null), true);
-- a call placed with the portal's Call button closes it at the call's start
insert into outbound_calls (staff_user_id, to_number, staff_number, status, started_at) values (test.id('brk_quo'), '+14165550198', '+14165550197', 'connecting', test.brk_at('12:09'));
select app.job_va_breaks_idle(test.brk_at('12:10'));
select test.eq('pause (Call button): the open stretch ends at the call''s start', (select ended_at = test.brk_at('12:09') from staff_idle_periods where user_id = test.id('brk_quo')), true);
update outbound_calls set status = 'completed', ended_at = test.brk_at('12:30') where staff_user_id = test.id('brk_quo');
-- a call linked to nobody pauses nobody
insert into phone_activity (thread_id, kind, direction, quo_id, started_at) select id, 'call', 'in', 'ACbrk02', test.brk_at('12:31') from phone_threads where number = '+14165550199';
select app.job_va_breaks_idle(test.brk_at('12:45'));
select test.eq('a call linked to nobody does not pause: a stretch (from the last activity, 12:10)', (select count(*) from staff_idle_periods where user_id = test.id('brk_quo') and ended_at is null and started_at = test.brk_at('12:10')), 1::bigint);
-- noted in the caller pop-up: linked to the person
select test.mk_renter('brk_renter', false);
insert into renter_notes (renter_id, body, author_user_id, author_name, author_role, call_id)
select test.id('renter:brk_renter'), 'Asked about the return time', test.id('brk_quo'), 'Brk Quo', 'fleet', id from phone_activity where quo_id = 'ACbrk02';
select app.job_va_breaks_idle(test.brk_at('12:46'));
select test.eq('pause (caller pop-up): a call they noted closes the stretch', (select count(*) from staff_idle_periods where user_id = test.id('brk_quo') and ended_at is null), 0::bigint);
update phone_activity set ended_at = test.brk_at('12:50') where quo_id = 'ACbrk02';
-- the townhall: Wednesday 13:00, 30 minutes, plus 10 minutes of grace, for anyone who joined or was present
insert into townhall_attendance (meeting_at, user_id, method, confirmed_at) values (test.brk_at('13:00'), test.id('brk_quo'), 'checkin', test.brk_at('13:01'));
select app.va_activity_touch(test.id('brk_quo'), test.brk_at('12:55'));
select app.job_va_breaks_idle(test.brk_at('13:20'));
select app.job_va_breaks_idle(test.brk_at('13:39'));
select test.eq('pause (townhall): no stretch from the start to the end plus the grace', (select count(*) from staff_idle_periods where user_id = test.id('brk_quo') and started_at >= test.brk_at('12:55')), 0::bigint);
select app.job_va_breaks_idle(test.brk_at('13:51'));
select test.eq('after the townhall''s grace: the wait counts from it', (select count(*) from staff_idle_periods where user_id = test.id('brk_quo') and started_at >= test.brk_at('12:55')), 1::bigint);
select test.eq('not in the townhall: no pause', (select count(*) from app.va_pause(test.id('brk_cs'), test.brk_at('13:20'))), 0::bigint);
select test.eq('the reasons', (select string_agg(reason, ',') from app.va_pause(test.id('brk_quo'), test.brk_at('13:20'))), 'townhall');
update staff_clock_entries set ended_at = test.brk_at('17:00') where user_id = test.id('brk_quo') and ended_at is null;

-- ================================================================ 6. an Admin edits a break, audited
select test.throws('the person cannot edit a break', format($$select test.brk('brk_cs', 'ops_do', 'va_break_edit', %L)$$,
  jsonb_build_object('id', (select id from staff_breaks where user_id = test.id('brk_cs')), 'ended_at', test.brk_at('13:20'), 'reason', 'Came back early'))::text, 'Only an Admin');
select test.throws('nor Finance', format($$select test.brk('brk_fin', 'ops_do', 'va_break_edit', %L)$$,
  jsonb_build_object('id', (select id from staff_breaks where user_id = test.id('brk_cs')), 'ended_at', test.brk_at('13:20'), 'reason', 'Came back early'))::text, 'Only an Admin');
select test.throws('the reason is needed', format($$select test.brk('brk_admin', 'admin_do', 'va_break_edit', %L)$$,
  jsonb_build_object('id', (select id from staff_breaks where user_id = test.id('brk_cs')), 'ended_at', test.brk_at('13:20')))::text, 'reason');
select test.throws('inside the clock entry', format($$select test.brk('brk_admin', 'admin_do', 'va_break_edit', %L)$$,
  jsonb_build_object('id', (select id from staff_breaks where user_id = test.id('brk_cs')), 'started_at', test.brk_at('08:00'), 'ended_at', test.brk_at('13:20'), 'reason', 'Wrong'))::text, 'inside its clock entry');
select test.brk('brk_admin', 'admin_do', 'va_break_edit', jsonb_build_object('id', (select id from staff_breaks where user_id = test.id('brk_cs')), 'ended_at', test.brk_at('13:20'), 'reason', 'Came back early'));
select test.eq('edited: 20 minutes, the reason kept, in the audit log with the before',
  (select format('%s|%s|%s', app.va_break_minutes(b), b.edit_reason, (select count(*) from audit_log a where a.action = 'staff_break_edited' and a.entity_id = b.id::text and a.before is not null))
     from staff_breaks b where b.user_id = test.id('brk_cs')), '20|Came back early|1');

-- ================================================================ 7. the timesheet, the payroll hours, who reads idle
select test.eq('the Admin''s timesheet: hours, breaks (count, total, longest) and idle per day',
  (select format('%s|%s|%s|%s|%s', d ->> 'minutes', d -> 'breaks' ->> 'count', d -> 'breaks' ->> 'minutes', d -> 'breaks' ->> 'longest', d -> 'idle' ->> 'minutes')
     from jsonb_array_elements(test.brk('brk_admin', 'ops_read', 'va_timesheet', '{"from": "2026-11-18", "to": "2026-11-18"}') -> 'people') p, jsonb_array_elements(p -> 'days') d
    where p ->> 'user_id' = test.id('brk_cs')::text), '480|1|20|20|36');
select test.eq('Finance''s timesheet has the breaks and no idle time',
  (select format('%s|%s|%s', d -> 'breaks' ->> 'count', d ? 'idle', p ? 'idle') from jsonb_array_elements(test.brk('brk_fin', 'ops_read', 'va_timesheet', '{"from": "2026-11-18", "to": "2026-11-18"}') -> 'people') p, jsonb_array_elements(p -> 'days') d
    where p ->> 'user_id' = test.id('brk_cs')::text), '1|f|f');
select test.throws('customer service cannot read the timesheet (anyone''s idle time)', $$select test.brk('brk_live', 'ops_read', 'va_timesheet', '{"from": "2026-11-18", "to": "2026-11-18"}')$$, 'Finance and Admin');
set role authenticated;
select set_config('request.jwt.claim.sub', test.id('brk_live')::text, false);
select test.eq('rls: a VA reads no idle stretches, breaks or activity', format('%s %s %s', test.visible('select 1 from staff_idle_periods'), test.visible('select 1 from staff_breaks'), test.visible('select 1 from staff_activity')), '-1 -1 -1');
reset role;
select test.eq('payroll hours: breaks paid, the clocked minutes', app.pay_clock_minutes(test.id('brk_cs'), date '2026-11-18', date '2026-11-18'), 480);
update program_settings set va_breaks_paid = false;
select test.eq('breaks unpaid: they come off', app.pay_clock_minutes(test.id('brk_cs'), date '2026-11-18', date '2026-11-18'), 460);
update program_settings set va_breaks_paid = true;

-- ================================================================ 8. the KPI (the Admins' board only)
select test.eq('Idle minutes on the Admin''s KPIs, against the weekly target',
  (select format('%s|%s|%s', k ->> 'unit', k ->> 'target', k ->> 'value') from jsonb_array_elements(test.brk('brk_admin', 'admin_read', 'kpi_board', '{"week": "2026-11-16"}') -> 'people') p, jsonb_array_elements(p -> 'items') k
    where p ->> 'user_id' = test.id('brk_cs')::text and k ->> 'key' = 'idle_minutes'), 'min|120|36');
select test.eq('not on the person''s own KPIs', (select count(*) from jsonb_array_elements(test.brk('brk_live', 'ops_read', 'kpi_board', '{"week": "2026-11-16"}') -> 'people') p, jsonb_array_elements(p -> 'items') k
    where k ->> 'key' = 'idle_minutes'), 0::bigint);
