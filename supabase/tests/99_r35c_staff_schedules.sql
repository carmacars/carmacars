-- 99: staff schedules (1502). The role defaults (customer service, Finance, Fleet), a person's own schedule set by an
-- Admin, the scheduled days and hours (weekdays and days of the month), lateness from the first clock-in, the clock-in
-- reminder's start, the duty board, and who may change them. Fixtures start with "ssx"; addresses are example.test.
select test.suite('99 r35c staff schedules');

select test.mk_user('ssx_admin', 'admin');
select test.mk_user('ssx_cs', 'va', 'cs');
select test.mk_user('ssx_fin', 'va', 'finance');
select test.mk_user('ssx_fleet', 'va', 'fleet');
update staff_profiles set functions = array[va_function::text] where user_id in (test.id('ssx_cs'), test.id('ssx_fin'), test.id('ssx_fleet'));

-- ================================================================ 1. the role defaults
select test.eq('three role defaults, no person in them',
  (select string_agg(function || ':' || array_to_string(weekdays, '') || '/' || array_to_string(month_days, ',') || ' ' || to_char(start_time, 'HH24:MI') || '-' || to_char(end_time, 'HH24:MI') || ' +' || extra_days_per_week, '; ' order by function)
     from staff_schedules where user_id is null),
  'cs:134567/ 08:00-18:00 +0; finance:135/10,15 10:00-19:00 +1; fleet:123456/ 11:00-21:00 +0');
select test.eq('Finance starts on Wednesday 2026-11-11', (select starts_on from staff_schedules where function = 'finance' and user_id is null), date '2026-11-11');

-- Tuesday 2026-11-17: customer service is off, Fleet and Finance (not a Finance day) differ
select test.eq('customer service: Tuesday off, Wednesday 8:00 to 18:00 Toronto',
  format('%s|%s', (select count(*) from app.staff_shifts_on(test.id('ssx_cs'), date '2026-11-17')),
         (select to_char(starts_at at time zone 'America/Toronto', 'HH24:MI') || '-' || to_char(ends_at at time zone 'America/Toronto', 'HH24:MI') from app.staff_shifts_on(test.id('ssx_cs'), date '2026-11-18'))),
  '0|08:00-18:00');
select test.eq('Fleet: Sunday off, Saturday 11:00 to 21:00',
  format('%s|%s', (select count(*) from app.staff_shifts_on(test.id('ssx_fleet'), date '2026-11-22')), (select count(*) from app.staff_shifts_on(test.id('ssx_fleet'), date '2026-11-21'))), '0|1');
select test.eq('Finance: Monday, Wednesday, Friday, and the 10th and the 15th even on a weekend; not before it starts',
  format('%s %s %s %s %s %s', (select count(*) from app.staff_shifts_on(test.id('ssx_fin'), date '2026-11-16')), (select count(*) from app.staff_shifts_on(test.id('ssx_fin'), date '2026-11-17')),
         (select count(*) from app.staff_shifts_on(test.id('ssx_fin'), date '2026-11-15')), (select count(*) from app.staff_shifts_on(test.id('ssx_fin'), date '2026-12-10')),
         (select count(*) from app.staff_shifts_on(test.id('ssx_fin'), date '2026-11-10')), (select count(*) from app.staff_shifts_on(test.id('ssx_fin'), date '2026-11-13'))),
  '1 0 1 1 0 1');
select test.eq('the clock-in reminder starts from the schedule (Fleet, 11:00)',
  to_char(app.va_clock_start(test.id('ssx_fleet'), date '2026-11-18') at time zone 'America/Toronto', 'HH24:MI'), '11:00');
select test.eq('no reminder on a day off', app.va_clock_start(test.id('ssx_cs'), date '2026-11-17'), null::timestamptz);

-- ================================================================ 2. lateness
insert into staff_clock_entries (user_id, started_at, ended_at, created_by)
values (test.id('ssx_cs'), timestamp '2026-11-18 08:25' at time zone 'America/Toronto', timestamp '2026-11-18 17:00' at time zone 'America/Toronto', test.id('ssx_cs')),
       (test.id('ssx_fleet'), timestamp '2026-11-18 11:05' at time zone 'America/Toronto', timestamp '2026-11-18 20:00' at time zone 'America/Toronto', test.id('ssx_fleet'));
select test.eq('25 minutes after the start is late (grace 10)',
  (select format('%s|%s', s ->> 'late', s ->> 'late_minutes') from (select app.staff_day_status(test.id('ssx_cs'), date '2026-11-18', timestamp '2026-11-18 19:00' at time zone 'America/Toronto') s) x), 'true|25');
select test.eq('5 minutes after is within the grace', (select app.staff_day_status(test.id('ssx_fleet'), date '2026-11-18', timestamp '2026-11-18 21:30' at time zone 'America/Toronto') ->> 'late'), 'false');
select test.eq('Finance not clocked in on a scheduled day, after its end: absent',
  (select app.staff_day_status(test.id('ssx_fin'), date '2026-11-18', timestamp '2026-11-18 20:00' at time zone 'America/Toronto') ->> 'absent'), 'true');
select test.eq('on shift inside the hours, not after', format('%s %s', app.staff_on_shift(test.id('ssx_cs'), timestamp '2026-11-18 12:00' at time zone 'America/Toronto'),
  app.staff_on_shift(test.id('ssx_cs'), timestamp '2026-11-18 18:30' at time zone 'America/Toronto')), 't f');

-- ================================================================ 3. a person's own schedule, the rules
select test.throws('customer service cannot change a schedule',
  format('select app.door(%L, %L, %L, %L, %L::jsonb)', test.id('ssx_cs'), 'aal2', 'ops_do', 'staff_schedule_save', '{"function": "cs", "weekdays": [1], "start": "09:00", "end": "17:00"}'), 'Admin');
select test.throws('the end is after the start',
  format('select app.door(%L, %L, %L, %L, %L::jsonb)', test.id('ssx_admin'), 'aal2', 'admin_do', 'staff_schedule_save', '{"function": "cs", "weekdays": [1], "start": "18:00", "end": "08:00"}'), 'after the start');
select test.throws('a person who does not hold the role',
  format('select app.door(%L, %L, %L, %L, %L::jsonb)', test.id('ssx_admin'), 'aal2', 'admin_do', 'staff_schedule_save',
         jsonb_build_object('function', 'fleet', 'user_id', test.id('ssx_cs'), 'weekdays', '[1]'::jsonb, 'start', '09:00', 'end', '17:00')), 'does not hold');
create temp table ssx_own as select app.door(test.id('ssx_admin'), 'aal2', 'admin_do', 'staff_schedule_save',
  jsonb_build_object('function', 'cs', 'user_id', test.id('ssx_cs'), 'weekdays', '2,3', 'start', '12:00', 'end', '20:00')) as v;
select test.eq('the person''s own schedule replaces the role''s for them only',
  format('%s|%s', (select to_char(starts_at at time zone 'America/Toronto', 'HH24:MI') from app.staff_shifts_on(test.id('ssx_cs'), date '2026-11-17')),
         (select to_char(start_time, 'HH24:MI') from staff_schedules where function = 'cs' and user_id is null)), '12:00|08:00');
select test.eq('the staff member reads their own week (7 days) and the role defaults',
  (select format('%s|%s', jsonb_array_length(v -> 'my_week'), jsonb_array_length(v -> 'defaults')) from (select app.door(test.id('ssx_cs'), 'aal2', 'ops_read', 'staff_schedules') v) x), '7|3');
select test.eq('only an Admin sees everyone''s own schedules', (select app.door(test.id('ssx_cs'), 'aal2', 'ops_read', 'staff_schedules') -> 'own'), 'null'::jsonb);
select test.throws('a role default is never removed',
  format('select app.door(%L, %L, %L, %L, %L::jsonb)', test.id('ssx_admin'), 'aal2', 'admin_do', 'staff_schedule_clear', jsonb_build_object('id', (select id from staff_schedules where function = 'cs' and user_id is null))), 'default');
select app.door(test.id('ssx_admin'), 'aal2', 'admin_do', 'staff_schedule_clear', jsonb_build_object('id', (select v ->> 'id' from ssx_own)));
select test.eq('removed: the role''s default applies again', (select count(*) from app.staff_shifts_on(test.id('ssx_cs'), date '2026-11-17')), 0::bigint);
select test.ok('the duty board lists the office staff', (select count(*) from jsonb_array_elements(app.staff_duty_board()) b where b ->> 'user_id' in (test.id('ssx_cs')::text, test.id('ssx_fin')::text, test.id('ssx_fleet')::text)) = 3);
