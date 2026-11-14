-- 99: migration 2863 (release 45): a townhall that did not happen counts nobody absent. A meeting nobody attended is
-- recorded as not held; one that was held counts its absences; an Admin says a past one did not happen (absences
-- cleared) or cancels an upcoming one (no reminders, not held once over); only held meetings lock anyone out.
-- Fixtures "thn"; example.test only.
select test.suite('99 r45 townhall not held (2863)');

select test.mk_user('thn_admin', 'admin');
select test.mk_user('thn_cs', 'va', 'cs');
select test.mk_user('thn_fleet', 'va', 'fleet');
update staff_profiles set functions = array[va_function::text] where user_id in (test.id('thn_cs'), test.id('thn_fleet'));
create function test.thn(p_user text, p_call text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
delete from townhall_meetings;
delete from townhall_attendance;

-- the townhall two days ago at 10:00
update program_settings set townhall_weekday = extract(isodow from app.today() - 2)::int, townhall_time = '10:00';
create temp table thn_m as select app.townhall_next(now() - interval '3 days') m;
grant select on thn_m to public;
select test.ok('the meeting is two days ago', (select m < now() - interval '1 day' and m > now() - interval '3 days' from thn_m));

-- nobody attended: not held, nobody absent
select app.job_townhall(now());
select test.eq('nobody attended: recorded as not held, nobody absent', (select not_held || '|' || cardinality(absent) from townhall_meetings, thn_m where meeting_at = m), 'true|0');
select test.eq('so nobody has a miss on the staff list', (test.thn('thn_admin', 'admin_read', 'staff_access_facts') -> test.id('thn_fleet')::text ->> 'townhalls_missed'), '0');

-- held: one person checked in, the other is absent
delete from townhall_meetings;
insert into townhall_attendance (meeting_at, user_id, method) select m, test.id('thn_cs'), 'checkin' from thn_m;
select app.job_townhall(now());
select test.eq('held: the absent one counts', (select not_held || '|' || (test.id('thn_fleet') = any (absent)) || '|' || (test.id('thn_cs') = any (absent)) from townhall_meetings, thn_m where meeting_at = m), 'false|true|false');
select test.eq('the Admin''s page lists it as held, 1 there, 1 missed', (select (x ->> 'held') || '|' || (x ->> 'attended') || '|' || (x ->> 'missed')
  from jsonb_array_elements(test.thn('thn_admin', 'ops_read', 'townhall') #> '{meetings,past}') x, thn_m where (x ->> 'meeting_at')::timestamptz = m), 'true|1|1');

-- "This townhall did not happen"
select test.throws('only an Admin says so', format($$ select test.thn('thn_cs', 'admin_do', 'townhall_not_held', %L) $$, (select jsonb_build_object('meeting_at', m) from thn_m)), null);
select test.eq('an Admin says it did not happen: its absence cleared', (test.thn('thn_admin', 'admin_do', 'townhall_not_held', (select jsonb_build_object('meeting_at', m, 'reason', 'The call link was down') from thn_m)) ->> 'cleared'), '1');
select test.eq('recorded as not held with the reason', (select not_held || '|' || cardinality(absent) || '|' || not_held_reason from townhall_meetings, thn_m where meeting_at = m), 'true|0|The call link was down');
select test.ok('no absence alert of it is left unread', not exists (select 1 from notifications n join app_events e on e.id = n.event_id, thn_m
  where n.read_at is null and e.payload ->> 'kind' = 'townhall_absent:absent:' || to_char(m, 'YYYYMMDDHH24MI')));
select test.throws('a townhall still to come is cancelled, not "did not happen"', $$ select test.thn('thn_admin', 'admin_do', 'townhall_not_held', jsonb_build_object('meeting_at', now() + interval '2 days')) $$, 'cancel it instead');

-- only held meetings lock anyone out
delete from townhall_meetings;
insert into townhall_meetings (meeting_at, absent) values (now() - interval '14 days', array[test.id('thn_fleet')]);
insert into townhall_meetings (meeting_at, absent, not_held) values (now() - interval '10 days', '{}', true);
select test.eq('a missed one, then one not held: nobody locked', app.townhall_lockouts(now()), 0);

-- cancel an upcoming one
create temp table thn_next as select app.townhall_next(now() + interval '1 day') m;
grant select on thn_next to public;
select test.throws('a reason is needed to cancel', format($$ select test.thn('thn_admin', 'admin_do', 'townhall_cancel', %L) $$, (select jsonb_build_object('meeting_at', m) from thn_next)), 'reason');
select test.thn('thn_admin', 'admin_do', 'townhall_cancel', (select jsonb_build_object('meeting_at', m, 'reason', 'Holiday week') from thn_next));
select test.eq('no reminder for a cancelled townhall', (select app.townhall_reminders(m - interval '10 minutes') from thn_next), 0);
select test.ok('the page shows it cancelled', (select bool_or((x ->> 'cancelled')::boolean) from jsonb_array_elements(test.thn('thn_admin', 'ops_read', 'townhall') #> '{meetings,upcoming}') x));
select test.thn('thn_admin', 'admin_do', 'townhall_cancel', (select jsonb_build_object('meeting_at', m, 'on', false) from thn_next));
select test.ok('back on: the reminder goes again', (select app.townhall_reminders(m - interval '10 minutes') from thn_next) > 0);
select test.thn('thn_admin', 'admin_do', 'townhall_cancel', (select jsonb_build_object('meeting_at', m, 'reason', 'Holiday week') from thn_next));
insert into townhall_attendance (meeting_at, user_id, method) select m, test.id('thn_cs'), 'checkin' from thn_next;
select app.job_townhall((select m + interval '2 hours' from thn_next));
select test.eq('once over, a cancelled one is not held, even with a check-in', (select not_held || '|' || cardinality(absent) || '|' || not_held_reason from townhall_meetings, thn_next where meeting_at = m),
  'true|0|Cancelled: Holiday week');

-- the settings back as the other suites expect them
delete from townhall_cancellations;
update program_settings set townhall_weekday = 3, townhall_time = '13:00';
