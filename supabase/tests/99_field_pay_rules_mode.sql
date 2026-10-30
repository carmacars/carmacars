-- 99: field pay, vehicle class rules, a signed car's Management Mode (migration 0165,
-- docs/changes/2026-10-25-field-pay-class-rules-mode.md). Clock in and out and the hours the office enters (reason and log,
-- overlap, locked periods); the pay period; the pay run (hours times rate, overtime and vacation pay when switched on, the
-- approved commissions, approve, record the payment by hand, the statement, its email, the CSV); who may do what; the class
-- rules screen (validation, audit, the test); a Management Mode change (at the owner's request: at once or on its date; against
-- the owner: a signature and the notice period; cancel, and the owner's email). Fixtures start with "fp", "cr" and "md".
select test.suite('99 field pay, class rules, management mode');
grant usage on schema test to service_role;
create function test.fp_do(p_user text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;
create function test.fp_read(p_user text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_read', p_name, p) $$;
create function test.fp_at(p_day date, p_hour numeric) returns timestamptz language sql stable as $$ select app.local_midnight(p_day) + make_interval(mins => (p_hour * 60)::integer) $$;
create function test.fp_shift(p_staff text, p_day date, p_from numeric, p_to numeric, p_note text default null) returns jsonb language sql as $$
  select test.fp_do('fp_fleet', 'field_shift_add', jsonb_build_object('staff', test.id(p_staff), 'started_at', test.fp_at(p_day, p_from), 'ended_at', test.fp_at(p_day, p_to), 'note', p_note)) $$;
create table test.fp (k text primary key, v jsonb);
create function test.fpv(p text) returns jsonb language sql stable as $$ select v from test.fp where k = p $$;
-- the previous pay period (ended), and the current one
create function test.fp_prev() returns date language sql stable as $$ select (select period_start from app.fp_period(app.today())) - 14 $$;
create function test.fp_cur() returns date language sql stable as $$ select period_start from app.fp_period(app.today()) $$;

select test.mk_user('fp_admin', 'admin');
select test.mk_user('fp_fleet', 'va', 'fleet');
select test.mk_user('fp_fin', 'va', 'finance');
select test.mk_user('fp_cs', 'va', 'cs');
select test.mk_user('fp_ann', 'field');
select test.mk_user('fp_bob', 'field');
select test.mk_user('fp_cy', 'field');
select test.mk_user('fp_other', 'renter');
select test.mk_owner('fp_own');
select test.mk_vehicle('FPV', 'fp_own');
select test.mk_renter('fp_ren');

-- ================================================================ 1. settings and the period
select test.eq('settings: CA$18.00 an hour, overtime off, vacation pay off, a 16 hour shift at most',
  (select format('%s %s %s %s', field_default_hourly_cents, field_overtime_on, field_vacation_pay_bps, field_shift_max_hours) from program_settings order by effective_from desc limit 1), '1800 f 0 16');
select test.ok('settings: the anchor is a Sunday before today (the most recent one when the migration ran)',
  (select field_pay_anchor is not null and field_pay_anchor <= current_date and extract(dow from field_pay_anchor) = 0 from program_settings order by effective_from desc limit 1));
select test.eq('period: two weeks from the anchor; the day before the anchor is the end of the one before',
  (select (a.period_start = anchor) || '/' || (a.period_end = anchor + 13) || '/' || (b.period_start = anchor - 14) || '/' || (b.period_end = anchor - 1) || '/' || (c.period_start = anchor + 14)
     from (select (app.settings()).field_pay_anchor as anchor) x, app.fp_period(x.anchor) a, app.fp_period(x.anchor - 1) b, app.fp_period(x.anchor + 14) c), 'true/true/true/true/true');
select test.eq('period: a day belongs to one period', (select count(*) from generate_series(0, 30) d, app.fp_period(app.today() - d) p where app.today() - d between p.period_start and p.period_end), 31::bigint);

-- ================================================================ 2. clock in and out
select test.throws('clock in: field staff only', $$select test.fp_do('fp_cs', 'field_clock_in')$$, 'Only field staff');
select test.throws('clock in: not an Admin either', $$select test.fp_do('fp_admin', 'field_clock_in')$$, 'Only field staff');
select test.throws('clock out when not clocked in', $$select test.fp_do('fp_ann', 'field_clock_out')$$, 'not clocked in');
insert into test.fp select 'in', test.fp_do('fp_ann', 'field_clock_in', '{"note": "Starting at the shop"}');
select test.eq('clock in: an open shift with the note, from the clock', (test.fpv('in') ->> 'open') || '/' || (test.fpv('in') ->> 'note') || '/' || (test.fpv('in') ->> 'source'), 'true/Starting at the shop/clock');
select test.throws('clock in twice is refused', $$select test.fp_do('fp_ann', 'field_clock_in')$$, 'already clocked in');
select test.eq('one open shift per person, however it is written', (select count(*) from field_shifts where staff_id = test.id('fp_ann') and ended_at is null), 1::bigint);
select test.throws('the database refuses a second open shift', format($$insert into field_shifts (staff_id, started_at, source) values (%L, now() - interval '1 minute', 'manual')$$, test.id('fp_ann')));
-- a job finished two hours into the shift is listed with it
update field_shifts set started_at = now() - interval '3 hours' where staff_id = test.id('fp_ann') and ended_at is null;
select test.fp_do('fp_ann', 'field_clock_out', '{"note": "All done"}') is not null;
insert into field_jobs (kind, vehicle_id, assigned_to, scheduled_at, status, started_at, completed_at, booking_id)
values ('handover', test.id('vehicle:FPV'), test.id('fp_ann'), now() - interval '2 hours', 'done', now() - interval '130 minutes', now() - interval '2 hours', null);
select test.eq('clock out: closed, the two notes kept, about three hours',
  (select (ended_at is not null) || '/' || note || '/' || (round(extract(epoch from ended_at - started_at) / 3600) = 3) from field_shifts where staff_id = test.id('fp_ann')), 'true/Starting at the shop / All done/true');
select test.eq('the field portal lists the jobs done in the shift', (select jsonb_array_length(x -> 'jobs') || '/' || (x #>> '{jobs,0,kind}') from jsonb_array_elements(test.fp_read('fp_ann', 'field_hours') -> 'recent') x limit 1), '1/handover');
select test.eq('a clocked-out person has no open shift in My hours', (test.fp_read('fp_ann', 'field_hours') -> 'open') #>> '{}' is null, true);
delete from field_jobs where assigned_to = test.id('fp_ann');
delete from field_shifts where staff_id = test.id('fp_ann');
select test.fp_do('fp_bob', 'field_clock_in') is not null;
select test.eq('an open shift shows in My hours and the office list', ((test.fp_read('fp_bob', 'field_hours') -> 'open') ->> 'open') || '/' || jsonb_array_length(test.fp_read('fp_fleet', 'field_pay') -> 'clocked_in'), 'true/1');
update field_shifts set started_at = now() - interval '20 hours' where staff_id = test.id('fp_bob') and ended_at is null;
select test.throws('a shift left open for more than 16 hours cannot be clocked out by the person', $$select test.fp_do('fp_bob', 'field_clock_out')$$, 'open more than 16 hours');
select test.fp_do('fp_fleet', 'field_shift_edit', jsonb_build_object('id', (select id from field_shifts where staff_id = test.id('fp_bob')), 'ended_at', now() - interval '12 hours', 'reason', 'Forgot to clock out; left at 6 pm'));
select test.eq('the office closes it with a reason: the log has it', (select e.action || '/' || e.reason from field_shift_edits e where e.shift_id = (select id from field_shifts where staff_id = test.id('fp_bob')) and e.action = 'edit'), 'edit/Forgot to clock out; left at 6 pm');
delete from field_shift_edits where shift_id in (select id from field_shifts where staff_id = test.id('fp_bob'));
delete from field_shifts where staff_id = test.id('fp_bob');

-- ================================================================ 3. the office enters and fixes hours
select test.throws('hours: Finance does not enter hours', format($$select test.fp_do('fp_fin', 'field_shift_add', %L)$$, jsonb_build_object('staff', test.id('fp_ann'), 'started_at', test.fp_at(test.fp_prev() + 1, 9), 'ended_at', test.fp_at(test.fp_prev() + 1, 17))), 'Fleet or an Admin');
select test.throws('hours: field staff do not edit their own', format($$select test.fp_do('fp_ann', 'field_shift_add', %L)$$, jsonb_build_object('staff', test.id('fp_ann'), 'started_at', test.fp_at(test.fp_prev() + 1, 9), 'ended_at', test.fp_at(test.fp_prev() + 1, 17))), 'Fleet or an Admin');
insert into test.fp select 'a1', test.fp_shift('fp_ann', test.fp_prev() + 1, 9, 17, 'Deliveries');
select test.eq('hours: Fleet enters a shift: manual, 8 hours, logged as added', (test.fpv('a1') ->> 'source') || '/' || (test.fpv('a1') ->> 'minutes') || '/' || (select count(*) from field_shift_edits where shift_id = (test.fpv('a1') ->> 'id')::uuid and action = 'add'), 'manual/480/1');
select test.throws('hours: overlapping hours of the same person are refused', format($$select test.fp_shift('fp_ann', %L, 16, 18)$$, test.fp_prev() + 1), 'overlap');
select test.throws('hours: a shift cannot be in the future', $$select test.fp_do('fp_fleet', 'field_shift_add', jsonb_build_object('staff', test.id('fp_ann'), 'started_at', now() + interval '2 hours', 'ended_at', now() + interval '3 hours'))$$, 'future');
select test.throws('hours: a shift is at most 16 hours', format($$select test.fp_shift('fp_ann', %L, 0, 17.5)$$, test.fp_prev() + 2), 'at most 16 hours');
select test.throws('hours: must end after it starts', format($$select test.fp_shift('fp_ann', %L, 10, 9)$$, test.fp_prev() + 2), 'end after');
select test.throws('hours: only a field staff member', format($$select test.fp_do('fp_fleet', 'field_shift_add', %L)$$, jsonb_build_object('staff', test.id('fp_cs'), 'started_at', test.fp_at(test.fp_prev() + 2, 9), 'ended_at', test.fp_at(test.fp_prev() + 2, 10))), 'field staff member');
select test.throws('edit: a reason is needed', format($$select test.fp_do('fp_fleet', 'field_shift_edit', %L)$$, jsonb_build_object('id', test.fpv('a1') ->> 'id', 'ended_at', test.fp_at(test.fp_prev() + 1, 16))), 'reason');
select test.fp_do('fp_fleet', 'field_shift_edit', jsonb_build_object('id', test.fpv('a1') ->> 'id', 'ended_at', test.fp_at(test.fp_prev() + 1, 17.5), 'reason', 'Stayed to return a car'));
select test.eq('edit: 8 hours 30 minutes now; the log keeps before and after and the reason',
  (select (select round(extract(epoch from ended_at - started_at) / 60) from field_shifts where id = (test.fpv('a1') ->> 'id')::uuid) || '/' || e.reason || '/' || (e.before ->> 'ended_at' <> e.after ->> 'ended_at')
     from field_shift_edits e where e.shift_id = (test.fpv('a1') ->> 'id')::uuid and e.action = 'edit'), '510/Stayed to return a car/true');
select test.eq('edit: an edit shows on the shift for the office', (select (x ->> 'edits') from jsonb_array_elements(test.fp_read('fp_fleet', 'field_pay', jsonb_build_object('date', test.fp_prev() + 1)) -> 'shifts') x limit 1), '1');
insert into test.fp select 'a2', test.fp_shift('fp_ann', test.fp_prev() + 2, 10, 12);
select test.throws('void: a reason is needed', format($$select test.fp_do('fp_fleet', 'field_shift_void', %L)$$, jsonb_build_object('id', test.fpv('a2') ->> 'id')), 'reason');
select test.fp_do('fp_fleet', 'field_shift_void', jsonb_build_object('id', test.fpv('a2') ->> 'id', 'reason', 'Entered twice'));
select test.eq('void: kept, never deleted; logged; not counted', (select (voided_at is not null) from field_shifts where id = (test.fpv('a2') ->> 'id')::uuid) || '/' || (select count(*) from field_shift_edits where shift_id = (test.fpv('a2') ->> 'id')::uuid)
  || '/' || (app.fp_figures(test.id('fp_ann'), test.fp_prev(), test.fp_prev() + 13) ->> 'minutes_total'), 'true/2/510');
select test.ok('the log of an edit has no way out: field staff read only their own shifts, nobody reads the log through the table',
  not has_table_privilege('authenticated', 'field_shift_edits', 'insert') and not has_table_privilege('authenticated', 'field_shifts', 'update'));

-- ================================================================ 4. the figures
select test.fp_shift('fp_bob', test.fp_prev() + 3, 8, 13.5);       -- 5 h 30 min
select test.fp_do('fp_admin', 'field_pay_rate_set', jsonb_build_object('staff', test.id('fp_bob'), 'rate_cents', 2000, 'reason', 'Two years with us'));
select test.throws('rate: Fleet does not set a rate', format($$select test.fp_do('fp_fleet', 'field_pay_rate_set', %L)$$, jsonb_build_object('staff', test.id('fp_bob'), 'rate_cents', 2500, 'reason', 'x')), 'Admin');
select test.throws('rate: a reason is needed', format($$select test.fp_do('fp_admin', 'field_pay_rate_set', %L)$$, jsonb_build_object('staff', test.id('fp_bob'), 'rate_cents', 2500)), 'why');
select test.throws('rate: a sensible rate', format($$select test.fp_do('fp_admin', 'field_pay_rate_set', %L)$$, jsonb_build_object('staff', test.id('fp_bob'), 'rate_cents', 90000, 'reason', 'x')), 'between');
select test.eq('rate: Ann has the default 18.00, Bob his own 20.00', app.fp_rate(test.id('fp_ann')) || '/' || app.fp_rate(test.id('fp_bob')), '1800/2000');
select test.eq('figures: Ann 8 h 30 min at 18.00 is 153.00; Bob 5 h 30 min at 20.00 is 110.00; no overtime',
  (app.fp_figures(test.id('fp_ann'), test.fp_prev(), test.fp_prev() + 13) ->> 'wage_cents') || '/' || (app.fp_figures(test.id('fp_bob'), test.fp_prev(), test.fp_prev() + 13) ->> 'wage_cents')
  || '/' || (app.fp_figures(test.id('fp_ann'), test.fp_prev(), test.fp_prev() + 13) ->> 'minutes_overtime'), '15300/11000/0');
-- overtime: off by default; on, hours past 44 in a seven-day week of the period
select test.fp_shift('fp_cy', test.fp_prev() + d, 8, 18) from generate_series(1, 5) d;   -- 50 hours in the first week
select test.eq('overtime off: 50 hours are all regular', (app.fp_figures(test.id('fp_cy'), test.fp_prev(), test.fp_prev() + 13) ->> 'minutes_regular') || '/' || (app.fp_figures(test.id('fp_cy'), test.fp_prev(), test.fp_prev() + 13) ->> 'wage_cents'), '3000/90000');
update program_settings set field_overtime_on = true;
select test.eq('overtime on: 44 regular hours and 6 at one and a half times (the weeks are the seven days of the period)',
  (app.fp_figures(test.id('fp_cy'), test.fp_prev(), test.fp_prev() + 13) ->> 'minutes_regular') || '/' || (app.fp_figures(test.id('fp_cy'), test.fp_prev(), test.fp_prev() + 13) ->> 'minutes_overtime') || '/'
  || (app.fp_figures(test.id('fp_cy'), test.fp_prev(), test.fp_prev() + 13) ->> 'wage_cents') || '/' || (app.fp_figures(test.id('fp_cy'), test.fp_prev(), test.fp_prev() + 13) ->> 'overtime_cents'), '2640/360/79200/16200');
update program_settings set field_overtime_on = false;
-- commissions: approved before the period ended are in; a clawback nets against them; not approved are out
select test.mk_booking('FP-1', 'FPV', 'fp_ren', '2026-10-01 10:00', '2026-10-03 10:00');
select test.mk_booking('FP-2', 'FPV', 'fp_ren', '2026-10-05 10:00', '2026-10-07 10:00');
insert into staff_commissions (booking_id, staff_id, kind, scheme, month, rental_days, base_cents, rate_bps, amount_cents, status, approved_at)
values (test.id('booking:FP-1'), test.id('fp_ann'), 'commission', 'flat', date '2026-10-01', 2, 36000, 1000, 3600, 'approved', app.local_midnight(test.fp_prev() + 3)),
       (test.id('booking:FP-2'), test.id('fp_ann'), 'commission', 'flat', date '2026-10-01', 2, 20000, 1000, 2000, 'pending_approval', null);
select test.eq('commissions: the approved one counts, the one waiting for approval does not', app.fp_commissions(test.id('fp_ann'), test.fp_prev() + 13) ->> 'cents', '3600');
update program_settings set field_vacation_pay_bps = 400;
select test.eq('vacation pay 4% when switched on: on wages and commissions, 153.00 + 36.00 is 7.56', app.fp_line_values(test.id('fp_ann'), test.fp_prev(), test.fp_prev() + 13) ->> 'vacation_cents', '756');
update program_settings set field_vacation_pay_bps = 0;
select test.eq('vacation pay is off: nothing added', app.fp_line_values(test.id('fp_ann'), test.fp_prev(), test.fp_prev() + 13) ->> 'vacation_cents', '0');

-- ================================================================ 5. the pay run
select test.throws('pay run: an Admin only (Fleet no)', format($$select test.fp_do('fp_fleet', 'field_pay_run_start', %L)$$, jsonb_build_object('date', test.fp_prev())), 'Admin');
select test.throws('pay run: Finance no (an Admin approves pay)', format($$select test.fp_do('fp_fin', 'field_pay_run_start', %L)$$, jsonb_build_object('date', test.fp_prev())), 'Admin');
select test.throws('pay run: a period that has not started', format($$select test.fp_do('fp_admin', 'field_pay_run_start', %L)$$, jsonb_build_object('date', test.fp_cur() + 14)), 'not started');
select test.eq('read: the pay run before it is started shows the figures as they stand',
  (select jsonb_array_length(x -> 'lines') || '/' || (x #>> '{totals,gross_cents}') from (select test.fp_read('fp_admin', 'field_pay', jsonb_build_object('date', test.fp_prev())) x) y), '3/119900');
select test.eq('read: Fleet sees hours, no pay (no lines, no rates)', (select (x ->> 'lines') is null and (x #>> '{staff,0,rate_cents}') is null and jsonb_array_length(x -> 'shifts') = 7 from (select test.fp_read('fp_fleet', 'field_pay', jsonb_build_object('date', test.fp_prev())) x) y), true);
select test.throws('read: field staff do not read the pay run', $$select test.fp_read('fp_ann', 'field_pay')$$, 'Fleet or an Admin');
select test.throws('read: Finance does not either', $$select test.fp_read('fp_fin', 'field_pay')$$, 'Fleet or an Admin');
insert into test.fp select 'run', test.fp_do('fp_admin', 'field_pay_run_start', jsonb_build_object('date', test.fp_prev() + 5));
select test.eq('pay run: a draft for the whole period with a line for each person with hours or commissions',
  (test.fpv('run') ->> 'status') || '/' || (select count(*) from field_pay_lines where run_id = (test.fpv('run') ->> 'run_id')::uuid) || '/' || (select sum(gross_cents) from field_pay_lines where run_id = (test.fpv('run') ->> 'run_id')::uuid), 'draft/3/119900');
select test.eq('pay run: starting it again gives the same run', test.fp_do('fp_admin', 'field_pay_run_start', jsonb_build_object('date', test.fp_prev())) ->> 'run_id', test.fpv('run') ->> 'run_id');
select test.eq('pay run: Ann 8.5 hours at 18.00 plus the commission; Bob 5.5 hours at 20.00; Cy 50 hours at 18.00',
  (select string_agg(u.full_name || ':' || l.wage_cents || ':' || l.commission_cents || ':' || l.gross_cents, ',' order by u.full_name) from field_pay_lines l join users u on u.id = l.staff_id where l.run_id = (test.fpv('run') ->> 'run_id')::uuid),
  'Fp Ann:15300:3600:18900,Fp Bob:11000:0:11000,Fp Cy:90000:0:90000');
insert into test.fp select 'cur', test.fp_do('fp_admin', 'field_pay_run_start', jsonb_build_object('date', app.today()));
select test.throws('approve: not before the period has ended', format($$select test.fp_do('fp_admin', 'field_pay_run_approve', %L)$$, jsonb_build_object('run_id', test.fpv('cur') ->> 'run_id')), 'approve it after that day');
select test.fp_do('fp_admin', 'field_pay_run_void', jsonb_build_object('run_id', test.fpv('cur') ->> 'run_id', 'reason', 'Started by mistake'));
select test.eq('a draft can be withdrawn; the period may be started again', (select status from field_pay_runs where id = (test.fpv('cur') ->> 'run_id')::uuid) || '/' || (test.fp_do('fp_admin', 'field_pay_run_start', '{}') ->> 'status'), 'void/draft');
-- someone still clocked in blocks the approval
select test.fp_do('fp_bob', 'field_clock_in');
update field_shifts set started_at = app.local_midnight(test.fp_cur() - 1) + interval '20 hours' where staff_id = test.id('fp_bob') and ended_at is null;
select test.throws('approve: someone still clocked in', format($$select test.fp_do('fp_admin', 'field_pay_run_approve', %L)$$, jsonb_build_object('run_id', test.fpv('run') ->> 'run_id')), 'Still clocked in');
delete from field_shifts where staff_id = test.id('fp_bob') and ended_at is null;
select test.throws('record a payment before the approval', format($$select test.fp_do('fp_admin', 'field_pay_line_paid', %L)$$, jsonb_build_object('line_id', (select id from field_pay_lines where run_id = (test.fpv('run') ->> 'run_id')::uuid limit 1), 'method', 'cash')), 'Approve the pay run');
select test.fp_do('fp_admin', 'field_pay_run_approve', jsonb_build_object('run_id', test.fpv('run') ->> 'run_id'));
select test.eq('approve: frozen, statements numbered', (select status from field_pay_runs where id = (test.fpv('run') ->> 'run_id')::uuid) || '/' || (select count(*) filter (where statement_number like 'PS-%') from field_pay_lines where run_id = (test.fpv('run') ->> 'run_id')::uuid), 'approved/3');
select test.throws('approved: the period''s shifts are locked (edit)', format($$select test.fp_do('fp_fleet', 'field_shift_edit', %L)$$, jsonb_build_object('id', test.fpv('a1') ->> 'id', 'ended_at', test.fp_at(test.fp_prev() + 1, 17), 'reason', 'later')), 'approved');
select test.throws('approved: nor can hours be added in it', format($$select test.fp_shift('fp_ann', %L, 6, 7)$$, test.fp_prev() + 6), 'approved');
select test.throws('approved: nor removed', format($$select test.fp_do('fp_fleet', 'field_shift_void', %L)$$, jsonb_build_object('id', test.fpv('a1') ->> 'id', 'reason', 'later')), 'approved');
select test.throws('approving twice', format($$select test.fp_do('fp_admin', 'field_pay_run_approve', %L)$$, jsonb_build_object('run_id', test.fpv('run') ->> 'run_id')), 'already approved');
-- the statement
select test.eq('statement: the facts: the person, the period, hours, amounts, the commission line',
  (select (f #>> '{person,name}') || '/' || (f ->> 'minutes_total') || '/' || (f ->> 'wage_cents') || '/' || (f ->> 'commission_cents') || '/' || (f ->> 'gross_cents') || '/' || jsonb_array_length(f -> 'shifts') || '/' || (f #>> '{commissions,0,booking}') || '/' || (f ->> 'final')
     from (select app.pdf_facts('pay_statement', (select id::text from field_pay_lines where staff_id = test.id('fp_ann') and run_id = (test.fpv('run') ->> 'run_id')::uuid)) f) x), 'Fp Ann/510/15300/3600/18900/1/FP-1/true');
select test.eq('statement: who may download: the person, an Admin, Finance; not another field staff member, not customer service',
  (select string_agg(app.file_access(test.id(u), 'pay_statement', (select id::text from field_pay_lines where staff_id = test.id('fp_ann') and run_id = (test.fpv('run') ->> 'run_id')::uuid))::text, ',' order by u)
     from unnest(array['fp_admin', 'fp_ann', 'fp_bob', 'fp_cs', 'fp_fin']) u), 'true,true,false,false,true');
select test.eq('statement: the person sees theirs in My hours', (select jsonb_array_length(test.fp_read('fp_ann', 'field_hours') -> 'statements') || '/' || (test.fp_read('fp_ann', 'field_hours') #>> '{statements,0,statement_number}' like 'PS-%')), '1/true');
select test.eq('csv: an Admin gets one row per person', jsonb_array_length(test.fp_read('fp_admin', 'field_pay_csv', jsonb_build_object('run_id', test.fpv('run') ->> 'run_id')) -> 'rows'), 3);
select test.throws('csv: Fleet no', format($$select test.fp_read('fp_fleet', 'field_pay_csv', %L)$$, jsonb_build_object('run_id', test.fpv('run') ->> 'run_id')), 'Admin');
-- payment recorded by hand
select test.throws('payment: e-Transfer needs its reference', format($$select test.fp_do('fp_admin', 'field_pay_line_paid', %L)$$, jsonb_build_object('line_id', (select id from field_pay_lines where staff_id = test.id('fp_ann') and run_id = (test.fpv('run') ->> 'run_id')::uuid), 'method', 'e_transfer')), 'reference');
select test.throws('payment: Fleet does not record payments', format($$select test.fp_do('fp_fleet', 'field_pay_line_paid', %L)$$, jsonb_build_object('line_id', (select id from field_pay_lines where staff_id = test.id('fp_ann') and run_id = (test.fpv('run') ->> 'run_id')::uuid), 'method', 'cash')), 'Admin');
select test.fp_do('fp_admin', 'field_pay_line_paid', jsonb_build_object('line_id', (select id from field_pay_lines where staff_id = test.id('fp_ann') and run_id = (test.fpv('run') ->> 'run_id')::uuid), 'method', 'e_transfer', 'reference', 'CAFP1234'));
select test.eq('payment: paid, the commission paid with it on one pay statement payout, the run still approved',
  (select l.status || '/' || l.reference || '/' || (select c.status from staff_commissions c where c.booking_id = test.id('booking:FP-1')) || '/' || po.method || '/' || po.amount_cents || '/' || (po.pay_period = date '2026-10-01' or po.pay_period = date_trunc('month', test.fp_prev() + 13)::date)
     || '/' || (select status from field_pay_runs where id = l.run_id)
     from field_pay_lines l join staff_commission_payouts po on po.id = l.payout_id where l.staff_id = test.id('fp_ann') and l.run_id = (test.fpv('run') ->> 'run_id')::uuid), 'paid/CAFP1234/paid/pay_statement/3600/true/approved');
select test.eq('payment: the commission waiting for approval is untouched', (select status from staff_commissions where booking_id = test.id('booking:FP-2')), 'pending_approval');
select test.throws('payment: only once', format($$select test.fp_do('fp_admin', 'field_pay_line_paid', %L)$$, jsonb_build_object('line_id', (select id from field_pay_lines where staff_id = test.id('fp_ann') and run_id = (test.fpv('run') ->> 'run_id')::uuid), 'method', 'cash')), 'already recorded');
select test.fp_do('fp_admin', 'field_pay_line_paid', jsonb_build_object('line_id', (select id from field_pay_lines where staff_id = test.id('fp_bob') and run_id = (test.fpv('run') ->> 'run_id')::uuid), 'method', 'cash'));
select test.throws('a run with a payment cannot be withdrawn', format($$select test.fp_do('fp_admin', 'field_pay_run_void', %L)$$, jsonb_build_object('run_id', test.fpv('run') ->> 'run_id', 'reason', 'x')), 'payment recorded');
select test.fp_do('fp_admin', 'field_pay_line_paid', jsonb_build_object('line_id', (select id from field_pay_lines where staff_id = test.id('fp_cy') and run_id = (test.fpv('run') ->> 'run_id')::uuid), 'method', 'bank_transfer', 'reference', 'BANK-FP-9'));
select test.eq('the run is paid when every line is', (select status from field_pay_runs where id = (test.fpv('run') ->> 'run_id')::uuid), 'paid');
select test.eq('payment: audit entries for the run, its approval and each payment', (select count(*) from audit_log where action in ('field_pay_run_start', 'field_pay_run_approve', 'field_pay_line_paid') and entity_id in (select id::text from field_pay_runs union select id::text from field_pay_lines)), 7::bigint);
-- the email
select test.eq('email: one pay statement email for each payment, to the person', (select count(*) from app_events where code = 'staff_pay_statement' and entity_id in (select id from field_pay_lines where run_id = (test.fpv('run') ->> 'run_id')::uuid)), 3::bigint);
select test.eq('email: the figures; the recipient is the staff member',
  (select (x ->> 'gross_total') || '/' || (x ->> 'period_label' = app.fp_period_label(test.fp_prev())) || '/' || (x ->> 'payout_method') || '/' || (x ->> 'payout_reference') || '/' || jsonb_array_length(x -> 'pay_lines') || '/' || (x ->> 'hours_url') || '/' || (select r.email from app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'staff_pay_statement')) r)
     from app_events e cross join lateral app.notification_payload('staff_pay_statement', e, '{}') x where e.code = 'staff_pay_statement' and e.entity_id = (select id from field_pay_lines where staff_id = test.id('fp_ann') and run_id = (test.fpv('run') ->> 'run_id')::uuid)),
  '$189.00/true/e-Transfer/CAFP1234/2/https://carmacars.ca/staff/field/hours/fp_ann@example.test');
select test.fp_do('fp_admin', 'field_pay_line_email', jsonb_build_object('line_id', (select id from field_pay_lines where staff_id = test.id('fp_ann') and run_id = (test.fpv('run') ->> 'run_id')::uuid)));
select test.eq('email: Send again makes another', (select count(*) from app_events where code = 'staff_pay_statement' and entity_id in (select id from field_pay_lines where run_id = (test.fpv('run') ->> 'run_id')::uuid)), 4::bigint);
select test.eq('email: it is in the catalogue as a staff email for field staff', (select audience || '/' || category from notification_catalogue where code = 'staff_pay_statement'), 'staff_field/transactional');
select test.ok('the functions are not callable from the browser', not has_function_privilege('authenticated', 'app.field_clock_in(uuid, jsonb)', 'execute') and not has_function_privilege('anon', 'app.field_pay_line_paid(uuid, jsonb)', 'execute'));

-- ================================================================ 6. vehicle class rules
select test.throws('rules: an Admin only', $$select test.fp_read('fp_cs', 'class_rules')$$, 'Admin');
select test.eq('rules: the rows that exist and the classes', (select jsonb_array_length(x -> 'rules') > 50 and jsonb_array_length(x -> 'classes') = 6 from (select test.fp_read('fp_admin', 'class_rules') x) y), true);
select test.throws('rules: a rule needs a condition', $$select test.fp_do('fp_admin', 'class_rule_save', '{"rank": 5, "class": "luxury", "note": "Everything"}')$$, 'at least one condition');
select test.throws('rules: a pattern that does not compile', $$select test.fp_do('fp_admin', 'class_rule_save', '{"rank": 5, "make": "crbrand", "model_re": "^(abc", "class": "luxury", "note": "Broken"}')$$, 'not a valid pattern');
select test.throws('rules: the rank', $$select test.fp_do('fp_admin', 'class_rule_save', '{"rank": 0, "make": "crbrand", "class": "luxury", "note": "Rank"}')$$, 'rank');
select test.throws('rules: the class', $$select test.fp_do('fp_admin', 'class_rule_save', '{"rank": 5, "make": "crbrand", "class": "supercar", "note": "Class"}')$$, 'Choose the class');
select test.throws('rules: a note', $$select test.fp_do('fp_admin', 'class_rule_save', '{"rank": 5, "make": "crbrand", "class": "luxury", "note": "x"}')$$, 'note');
select test.throws('rules: years old needs the older class', $$select test.fp_do('fp_admin', 'class_rule_save', '{"rank": 5, "make": "crbrand", "class": "luxury", "aged_years": 8, "note": "Aged"}')$$, 'older car gets');
select test.throws('rules: the older class differs', $$select test.fp_do('fp_admin', 'class_rule_save', '{"rank": 5, "make": "crbrand", "class": "luxury", "aged_years": 8, "aged_class": "luxury", "note": "Aged"}')$$, 'same');
select test.throws('rules: years old in range', $$select test.fp_do('fp_admin', 'class_rule_save', '{"rank": 5, "make": "crbrand", "class": "luxury", "aged_years": 99, "aged_class": "premium", "note": "Aged"}')$$, 'from 1 to 60');
select test.throws('rules: Customer service cannot add one', $$select test.fp_do('fp_cs', 'class_rule_save', '{"rank": 5, "make": "crbrand", "class": "luxury", "note": "Nope"}')$$, 'Admin');
insert into test.fp select 'rule', test.fp_do('fp_admin', 'class_rule_save', '{"rank": 5, "make": "CR-Brand", "model_re": "^zeta", "class": "exotic", "aged_years": 10, "aged_class": "luxury", "note": "A Crbrand Zeta"}');
select test.eq('rules: added; the make is as a rule reads it', (test.fpv('rule') ->> 'make_key') || '/' || (test.fpv('rule') ->> 'class') || '/' || (test.fpv('rule') ->> 'is_active') || '/' || (test.fpv('rule') ->> 'aged_class'), 'crbrand/exotic/true/luxury');
select test.eq('rules: the test: a new Zeta is exotic by that rule; a ten year old one luxury; another model of the make, the default',
  (test.fp_do('fp_admin', 'class_rule_test', jsonb_build_object('year', extract(year from app.today())::int, 'make', 'CR-Brand', 'model', 'Zeta 1')) ->> 'class') || '/'
  || (test.fp_do('fp_admin', 'class_rule_test', jsonb_build_object('year', extract(year from app.today())::int - 11, 'make', 'CR-Brand', 'model', 'Zeta 1')) ->> 'class') || '/'
  || (test.fp_do('fp_admin', 'class_rule_test', jsonb_build_object('year', extract(year from app.today())::int, 'make', 'CR-Brand', 'model', 'Other')) ->> 'class'), 'exotic/luxury/standard');
select test.eq('rules: a new car takes it (the VIN-first inference reads the table)', app.infer_vehicle_class(extract(year from app.today())::int, 'CR-Brand', 'Zeta 9') ->> 'class', 'exotic');
select test.eq('rules: the test says why', test.fp_do('fp_admin', 'class_rule_test', jsonb_build_object('make', 'CR-Brand', 'model', 'Zeta 1')) ->> 'why', 'Exotic: A Crbrand Zeta');
select test.fp_do('fp_admin', 'class_rule_save', jsonb_build_object('id', test.fpv('rule') ->> 'id', 'rank', 5, 'make', 'crbrand', 'model_re', '^zeta', 'class', 'premium', 'note', 'A Crbrand Zeta, premium', 'is_active', true));
select test.eq('rules: changed', app.infer_vehicle_class(extract(year from app.today())::int, 'CR-Brand', 'Zeta 9') ->> 'class', 'premium');
select test.fp_do('fp_admin', 'class_rule_save', jsonb_build_object('id', test.fpv('rule') ->> 'id', 'rank', 5, 'make', 'crbrand', 'model_re', '^zeta', 'class', 'premium', 'note', 'A Crbrand Zeta, premium', 'is_active', false));
select test.eq('rules: switched off, it no longer decides', app.infer_vehicle_class(extract(year from app.today())::int, 'CR-Brand', 'Zeta 9') ->> 'class', 'standard');
select test.fp_do('fp_admin', 'class_rule_delete', jsonb_build_object('id', test.fpv('rule') ->> 'id'));
select test.eq('rules: deleted', (select count(*) from vehicle_class_rules where id = (test.fpv('rule') ->> 'id')::uuid), 0::bigint);
select test.eq('rules: every change is in the audit log (add, two changes, delete), with before and after',
  (select string_agg(action, ',' order by at) || '/' || count(*) filter (where before is not null) from audit_log where entity_table = 'vehicle_class_rules' and action like 'class_rule_%' and entity_id = test.fpv('rule') ->> 'id'),
  'class_rule_add,class_rule_change,class_rule_change,class_rule_delete/3');
select test.ok('rules: only an Admin writes the table (row level security); the delete is the screen''s alone',
  (select relrowsecurity from pg_class where oid = 'public.vehicle_class_rules'::regclass) and not has_table_privilege('authenticated', 'vehicle_class_rules', 'delete'));

-- ================================================================ 7. a signed car's Management Mode
select test.mk_user('md_admin', 'admin');
select test.mk_owner('md_own');
select test.mk_vehicle('MDA', 'md_own', 'managed', 45000, 2500, 3500);
select test.mk_vehicle('MDB', 'md_own', 'self_managed', 45000, 2500, 0);
select test.mk_vehicle('MDC', 'md_own', 'managed', 45000, 2500, 3500);
select test.mk_vehicle('MDD', 'md_own', 'managed', 45000, 2500, 3500);
select test.mk_vehicle('MDS', 'md_own', 'managed', 0, 0, 1000, date '2026-09-01', true);
create function test.md_do(p jsonb) returns jsonb language sql as $$ select public.door(test.id('md_admin'), null, 'ops_do', 'car_mode_change', p) $$;
create function test.md_car(p_label text) returns jsonb language sql as $$
  select x from jsonb_array_elements(public.door(test.id('md_admin'), null, 'ops_read', 'car_terms', jsonb_build_object('vehicle_id', test.id('vehicle:' || p_label))) -> 'cars') x limit 1 $$;
select test.throws('mode: an Admin only', format($$select public.door(%L, null, 'ops_do', 'car_mode_change', %L)$$, test.id('fp_fleet'), jsonb_build_object('vehicle_id', test.id('vehicle:MDA'), 'management_mode', 'self_managed')), 'Admin');
select test.throws('mode: a shareholder car has fixed terms', format($$select test.md_do(%L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:MDS'), 'management_mode', 'self_managed')), 'fixed terms');
select test.throws('mode: choose the mode', format($$select test.md_do(%L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:MDA'))), 'Choose the new Management Mode');
select test.throws('mode: not the mode it already has', format($$select test.md_do(%L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:MDA'), 'management_mode', 'managed')), 'already');
select test.eq('mode: the car page offers it with the options and the notice days', (test.md_car('MDA') #>> '{mode_change,may}') || '/' || (jsonb_array_length(test.md_car('MDA') #> '{mode_change,options,self_managed}') > 0) || '/' || (test.md_car('MDA') #>> '{mode_change,notice_days}'), 'true/true/30');
-- at the owner's request, a lower share: no signature, no notice period
insert into test.fp select 'prev1', test.md_do(jsonb_build_object('vehicle_id', test.id('vehicle:MDA'), 'management_mode', 'self_managed', 'owner_requested', true, 'preview', true));
select test.eq('mode: the review: the owner asked and nothing is higher: no signature, from today; nothing written',
  (test.fpv('prev1') ->> 'needs_signature') || '/' || (test.fpv('prev1') ->> 'effective_from' = app.today()::text) || '/' || (test.fpv('prev1') ->> 'done') || '/' || (select count(*) from vehicle_term_changes where vehicle_id = test.id('vehicle:MDA')), 'false/true/false/0');
select test.throws('mode: the reason is needed', format($$select test.md_do(%L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:MDA'), 'management_mode', 'self_managed', 'owner_requested', true)), 'reason');
select test.throws('mode: it cannot be back-dated', format($$select test.md_do(%L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:MDA'), 'management_mode', 'self_managed', 'owner_requested', true, 'reason', 'x y z', 'effective_from', app.today() - 1)), 'earliest date');
insert into test.fp select 'now', test.md_do(jsonb_build_object('vehicle_id', test.id('vehicle:MDA'), 'management_mode', 'self_managed', 'owner_requested', true, 'reason', 'The owner will run the rentals herself'));
select test.eq('mode: applied at once: the car is Self-Managed, its schedule says so with no management fee, the fee history too, countersigned',
  (select v.management_mode || '/' || s.management_mode || '/' || s.revenue_share_bps || '/' || (s.signed_at is not null) || '/' || (select h.revenue_share_bps from app.vehicle_terms(v.id, app.today()) h) || '/' || c.status || '/' || (c.countersignature like 'Signed electronically for %')
     from vehicles v join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null join vehicle_term_changes c on c.vehicle_id = v.id and c.kind = 'mode_change' where v.id = test.id('vehicle:MDA')),
  'self_managed/self_managed/0/true/0/applied/true');
select test.eq('mode: the old schedule is kept as superseded', (select count(*) from vehicle_schedules where vehicle_id = test.id('vehicle:MDA')), 2::bigint);
select test.eq('mode: the car page says the new mode and keeps the history', (test.md_car('MDA') ->> 'mode') || '/' || (select x ->> 'label' || ':' || (x ->> 'mode_after') from jsonb_array_elements(test.md_car('MDA') -> 'changes') x where x ->> 'kind' = 'mode_change'), 'self_managed/Management Mode change:self_managed');
select test.eq('mode: the owner is emailed the notice (no signature needed), the notice document exists, and the recipient is the owner',
  (select (x ->> 'needs_signature') || '/' || (x ->> 'mode_before') || '/' || (x ->> 'mode_after') || '/' || (x #>> '{fee_changes,0,label}') || '/' || (x ->> 'vehicle_name' = app.vehicle_name(test.id('vehicle:MDA'))) || '/'
          || (select r.email from app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'owner_mode_change_notice')) r limit 1)
     from app_events e cross join lateral app.notification_payload('owner_mode_change_notice', e, '{"audience": "owner"}') x where e.code = 'owner_mode_change_notice' and e.entity_id = (test.fpv('now') ->> 'change_id')::uuid),
  'false/Managed/Self-Managed/Management Mode/true/md_own@example.test');
select test.eq('mode: the notice PDF facts name the change', (select (f ->> 'title') || '/' || (f #>> '{lines,0,after}') from (select app.pdf_facts('terms_notice', (test.fpv('now') ->> 'change_id')) f) x), 'Notice of a change of Management Mode/Self-Managed');
-- against the owner: a signature and the notice period
insert into test.fp select 'prev2', test.md_do(jsonb_build_object('vehicle_id', test.id('vehicle:MDB'), 'management_mode', 'managed', 'owner_requested', true, 'preview', true));
select test.eq('mode: self-managed to managed raises the management fee: the owner signs, 30 days notice',
  (test.fpv('prev2') ->> 'needs_signature') || '/' || (test.fpv('prev2') ->> 'earliest' = (app.today() + 30)::text) || '/' || (test.fpv('prev2') #>> '{lines,1,label}'), 'true/true/Management fee (Revenue Share)');
select test.throws('mode: not before the notice period', format($$select test.md_do(%L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:MDB'), 'management_mode', 'managed', 'owner_requested', true, 'reason', 'Owner asked', 'effective_from', app.today() + 10)), 'earliest date');
insert into test.fp select 'sign', test.md_do(jsonb_build_object('vehicle_id', test.id('vehicle:MDB'), 'management_mode', 'managed', 'owner_requested', true, 'reason', 'The owner asked us to take over the rentals', 'revenue_share_bps', 3000));
select test.eq('mode: waiting for the owner: the car is still Self-Managed; the change awaits a signature, 30 days out',
  (select v.management_mode || '/' || c.status || '/' || (c.effective_from = app.today() + 30) || '/' || c.revenue_share_bps || '/' || c.new_management_mode from vehicles v join vehicle_term_changes c on c.vehicle_id = v.id and c.kind = 'mode_change' where v.id = test.id('vehicle:MDB')), 'self_managed/awaiting_signature/true/3000/managed');
select test.ok('mode: the text the owner signs says the mode', (select (app.schedule_change_text((test.fpv('sign') ->> 'change_id')::uuid) ->> 'text') like '%Management Mode: Managed (was Self-Managed)%'));
select test.eq('mode: the owner is emailed once and told to sign', (select count(*) from app_events where code = 'owner_mode_change_notice' and entity_id = (test.fpv('sign') ->> 'change_id')::uuid), 1::bigint);
select test.throws('mode: nothing else while it waits', format($$select test.md_do(%L)$$, jsonb_build_object('vehicle_id', test.id('vehicle:MDB'), 'management_mode', 'turo_only', 'owner_requested', true, 'reason', 'x y z')), 'waiting for the owner');
select test.eq('mode: the owner''s page lists it with a cancel for the Admin', (select (x ->> 'can_cancel') || '/' || (x ->> 'status') from jsonb_array_elements(test.md_car('MDB') -> 'changes') x where x ->> 'kind' = 'mode_change'), 'true/awaiting_signature');
-- signed on paper: the schedule carries the mode, the fees begin on the date, the car moves on its date
select public.door(test.id('md_admin'), null, 'ops_do', 'schedule_change_admin', jsonb_build_object('change_id', test.fpv('sign') ->> 'change_id', 'do', 'paper'));
select test.eq('mode: signed: the new schedule says Managed; the car stays Self-Managed until the date',
  (select s.management_mode || '/' || v.management_mode || '/' || s.revenue_share_bps || '/' || (select min(h.effective_from) = app.today() + 30 from vehicle_fee_history h where h.vehicle_id = v.id and h.effective_from > app.today())
     from vehicles v join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null where v.id = test.id('vehicle:MDB')), 'managed/self_managed/3000/true');
select test.eq('mode: the job does nothing before the date', app.job_mode_changes(), '0 changes applied, 0 cars moved to their new mode');
update vehicle_term_changes set effective_from = app.today() where id = (test.fpv('sign') ->> 'change_id')::uuid;
insert into test.fp select 'job1', to_jsonb(app.job_mode_changes());
select test.eq('mode: on its date the job moves the car', (test.fpv('job1') #>> '{}') || '/' || (select management_mode || ':' || onboarding_method from vehicles where id = test.id('vehicle:MDB')), '0 changes applied, 1 cars moved to their new mode/managed:transfer');
-- the owner's request with nothing higher, dated ahead: noticed now, applied by the job on the date
insert into test.fp select 'later', test.md_do(jsonb_build_object('vehicle_id', test.id('vehicle:MDC'), 'management_mode', 'turo_only', 'owner_requested', true, 'reason', 'The owner moves the car to Turo only', 'effective_from', app.today() + 5));
select test.eq('mode: dated ahead: noticed, the car unchanged, no schedule yet; Turo-Only means no Fees',
  (select v.management_mode || '/' || c.status || '/' || c.insurance_fee_cents || c.tracker_fee_cents || c.revenue_share_bps || '/' || (select count(*) from vehicle_schedules where vehicle_id = v.id) || '/' || c.new_onboarding_method
     from vehicles v join vehicle_term_changes c on c.vehicle_id = v.id and c.kind = 'mode_change' where v.id = test.id('vehicle:MDC')), 'managed/noticed/000/1/none');
select test.eq('mode: the car page says what is coming', (test.md_car('MDC') #>> '{mode_next,mode}') || '/' || (test.md_car('MDC') #>> '{mode_next,status}'), 'turo_only/noticed');
update vehicle_term_changes set effective_from = app.today() where id = (test.fpv('later') ->> 'change_id')::uuid;
insert into test.fp select 'job2', to_jsonb(app.job_mode_changes());
select test.eq('mode: on the date the job issues the schedule and moves the car', (test.fpv('job2') #>> '{}') || '/' || (select v.management_mode || ':' || v.onboarding_method || ':' || s.management_mode || ':' || s.insurance_fee_cents from vehicles v join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null where v.id = test.id('vehicle:MDC')),
  '1 changes applied, 0 cars moved to their new mode/turo_only:none:turo_only:0');
-- a change CarmaCars starts is against the owner even when the fees fall
insert into test.fp select 'prev3', test.md_do(jsonb_build_object('vehicle_id', test.id('vehicle:MDD'), 'management_mode', 'self_managed', 'preview', true));
select test.eq('mode: not asked for by the owner: a signature and the notice period', (test.fpv('prev3') ->> 'needs_signature') || '/' || (test.fpv('prev3') ->> 'earliest' = (app.today() + 30)::text), 'true/true');
-- cancel: before it starts, the owner is emailed
insert into test.fp select 'n1', test.md_do(jsonb_build_object('vehicle_id', test.id('vehicle:MDD'), 'management_mode', 'self_managed', 'reason', 'CarmaCars stops managing this car'));
select test.eq('cancel: the awaiting change is withdrawn (the car page) and the owner told', (select public.door(test.id('md_admin'), null, 'ops_do', 'car_terms_cancel', jsonb_build_object('change_id', test.fpv('n1') ->> 'change_id', 'reason', 'Agreed to stay as we are')) ->> 'cancelled'), 'true');
select test.eq('cancel: the change is cancelled with its reason; the car is as it was',
  (select c.status || '/' || c.cancelled_reason || '/' || v.management_mode from vehicle_term_changes c join vehicles v on v.id = c.vehicle_id where c.id = (test.fpv('n1') ->> 'change_id')::uuid), 'cancelled/Agreed to stay as we are/managed');
select test.eq('cancel: the owner is emailed: what was going to change, that their terms stay; the recipient is the owner',
  (select (x ->> 'effective_date' <> '') || '/' || (x #>> '{fee_changes,0,label}') || '/' || (select r.email from app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'owner_fee_change_cancelled')) r limit 1)
     from app_events e cross join lateral app.notification_payload('owner_fee_change_cancelled', e, '{"audience": "owner"}') x where e.code = 'owner_fee_change_cancelled' and e.entity_id = (test.fpv('n1') ->> 'change_id')::uuid), 'true/Management Mode/md_own@example.test');
insert into test.fp select 'n2', test.md_do(jsonb_build_object('vehicle_id', test.id('vehicle:MDD'), 'management_mode', 'self_managed', 'owner_requested', true, 'reason', 'The owner asked', 'effective_from', app.today() + 7));
select test.fp_do('md_admin', 'car_terms_cancel', jsonb_build_object('change_id', test.fpv('n2') ->> 'change_id', 'reason', 'The owner changed their mind'));
select test.eq('cancel: a scheduled (noticed) mode change is cancelled too, and the owner told',
  (select c.status || '/' || (select count(*) from app_events e where e.code = 'owner_fee_change_cancelled' and e.entity_id = c.id) from vehicle_term_changes c where c.id = (test.fpv('n2') ->> 'change_id')::uuid), 'cancelled/1');
select test.throws('cancel: a reason is needed', format($$select test.fp_do('md_admin', 'car_terms_cancel', %L)$$, jsonb_build_object('change_id', test.fpv('n2') ->> 'change_id')), 'Give the reason');
-- a noticed fee change cancelled also tells the owner (it never did)
select test.fp_do('md_admin', 'car_terms_change', jsonb_build_object('vehicle_id', test.id('vehicle:MDD'), 'insurance_fee_cents', 50000, 'raise_from', app.today() + 40, 'reason', 'Fleet premium renewal'));
select test.eq('cancel: a noticed higher fee is cancelled', (select (test.fp_do('md_admin', 'car_terms_cancel', jsonb_build_object('change_id', c.id, 'reason', 'Renewal came in lower')) ->> 'cancelled') from vehicle_term_changes c where c.vehicle_id = test.id('vehicle:MDD') and c.kind = 'fee_notice' and c.status = 'noticed'), 'true');
select test.eq('cancel: the owner is emailed about it too, with the fee line',
  (select (x #>> '{fee_changes,0,label}') || '/' || (x #>> '{fee_changes,0,before}') || '/' || (x #>> '{fee_changes,0,after}') from app_events e cross join lateral app.notification_payload('owner_fee_change_cancelled', e, '{}') x
    where e.code = 'owner_fee_change_cancelled' and e.entity_id = (select id from vehicle_term_changes where vehicle_id = test.id('vehicle:MDD') and kind = 'fee_notice')),
  'Insurance Fee, monthly, before HST/$450.00/$500.00');
select test.eq('cancel: one email per cancelled change (the three of this file)', (select count(*) from app_events where code = 'owner_fee_change_cancelled' and entity_id in (select id from vehicle_term_changes where vehicle_id = test.id('vehicle:MDD'))), 3::bigint);
select test.ok('mode: the three emails and both owner texts are in the catalogue', (select count(*) from notification_catalogue where code in ('owner_mode_change_notice', 'owner_fee_change_cancelled', 'staff_pay_statement')) = 3
  and (select count(*) from sms_templates where code in ('owner_mode_change_notice', 'owner_fee_change_cancelled')) = 2);
