-- 99: payroll (1503). Salaried office staff are paid monthly x 12 / 26 every two weeks (by the days employed), field staff
-- keep their hours and rate; Finance prepares the run (start, adjust, send for approval), only an Admin approves and records
-- the payments (one by one or all at once); nothing is paid by itself; each person reads their own pay stubs.
-- Fixtures start with "prx"; every address is example.test; amounts are made up.
select test.suite('99 r35c payroll');

create function test.prx_do(p_user text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;
create function test.prx_read(p_user text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_read', p_name, p) $$;
-- two periods back: the field pay suite (0165) uses the last and the current periods
create function test.prx_prev() returns date language sql stable as $$ select (select period_start from app.fp_period(app.today())) - 28 $$;

select test.mk_user('prx_admin', 'admin');
select test.mk_user('prx_cs', 'va', 'cs');
select test.mk_user('prx_fleet', 'va', 'fleet');
select test.mk_user('prx_fin', 'va', 'finance');
select test.mk_user('prx_new', 'va', 'cs');
select test.mk_user('prx_ann', 'field');
update staff_profiles set functions = array[va_function::text] where user_id in (test.id('prx_cs'), test.id('prx_fleet'), test.id('prx_fin'), test.id('prx_new'));
-- the new hire started on the 8th day of the period: 7 of 14 days
update staff_profiles set started_on = test.prx_prev() + 7 where user_id = test.id('prx_new');
update program_settings set va_salary_defaults = '{"cs": 35000, "fleet": 40000}'::jsonb, va_salary_currency = 'USD';
-- field hours in the period: 8 hours
select test.prx_do('prx_admin', 'field_shift_add', jsonb_build_object('staff', test.id('prx_ann'), 'started_at', app.local_midnight(test.prx_prev() + 2) + interval '9 hours',
  'ended_at', app.local_midnight(test.prx_prev() + 2) + interval '17 hours'));
insert into staff_clock_entries (user_id, started_at, ended_at, created_by)
values (test.id('prx_cs'), app.local_midnight(test.prx_prev() + 1) + interval '8 hours', app.local_midnight(test.prx_prev() + 1) + interval '18 hours', test.id('prx_cs'));

-- ================================================================ 1. the salary
select test.eq('biweekly: monthly x 12 / 26 (role default 350.00 -> 161.54)', (app.pay_salary_period(test.id('prx_cs'), test.prx_prev(), test.prx_prev() + 13) ->> 'cents')::bigint, 16154::bigint);
select test.eq('a hire in the middle of the period: 7 of 14 days', (app.pay_salary_period(test.id('prx_new'), test.prx_prev(), test.prx_prev() + 13) ->> 'cents')::bigint, 8077::bigint);
select test.eq('no salary set for the role (Finance): nothing', (app.pay_salary_period(test.id('prx_fin'), test.prx_prev(), test.prx_prev() + 13) ->> 'cents')::bigint, 0::bigint);
select test.throws('Finance cannot set a salary', format($$select test.prx_do('prx_fin', 'payroll_salary_set', %L)$$, jsonb_build_object('staff', test.id('prx_fin'), 'monthly_cents', 50000, 'reason', 'raise')), 'Admin');
select test.throws('a salary change needs its reason', format($$select test.prx_do('prx_admin', 'payroll_salary_set', %L)$$, jsonb_build_object('staff', test.id('prx_fin'), 'monthly_cents', 20000)), 'why');
select test.eq('an Admin sets a person''s own salary (Finance 200.00)', (test.prx_do('prx_admin', 'payroll_salary_set', jsonb_build_object('staff', test.id('prx_fin'), 'monthly_cents', 20000, 'reason', 'hired at this rate')) ->> 'monthly_cents')::integer, 20000);

-- ================================================================ 2. Finance prepares
select test.throws('customer service cannot start the payroll', format($$select test.prx_do('prx_cs', 'field_pay_run_start', %L)$$, jsonb_build_object('date', test.prx_prev())), 'Finance or an Admin');
create temp table prx_run as select test.prx_do('prx_fin', 'field_pay_run_start', jsonb_build_object('date', test.prx_prev())) as v;
select test.eq('Finance started the run: a draft', (select v ->> 'status' from prx_run), 'draft');
select test.eq('the lines: four salaried people in USD, the field person in CAD with 8 hours',
  (select string_agg(coalesce(u.email, '') || ':' || l.currency || ':' || l.gross_cents, ' ' order by u.email) from field_pay_lines l join users u on u.id = l.staff_id
    where l.run_id = (select (v ->> 'run_id')::uuid from prx_run) and u.email like 'prx\_%'),
  format('prx_ann@example.test:CAD:%s prx_cs@example.test:USD:16154 prx_fin@example.test:USD:9231 prx_fleet@example.test:USD:18462 prx_new@example.test:USD:8077', 8 * app.fp_rate(test.id('prx_ann'))));
select test.eq('the clocked hours are on the salaried line, for the record', (select clock_minutes from field_pay_lines where staff_id = test.id('prx_cs') and run_id = (select (v ->> 'run_id')::uuid from prx_run)), 600);
select test.throws('an adjustment needs its reason', format($$select test.prx_do('prx_fin', 'payroll_adjust', %L)$$, jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run), 'staff', test.id('prx_cs'), 'amount_cents', 2500)), 'reason');
select test.prx_do('prx_fin', 'payroll_adjust', jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run), 'staff', test.id('prx_cs'), 'amount_cents', 2500, 'reason', 'KPI bonus'));
select test.prx_do('prx_fin', 'field_pay_run_refresh', jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run)));
select test.eq('the adjustment stays through a refresh', (select format('%s|%s', adjustment_cents, gross_cents) from field_pay_lines where staff_id = test.id('prx_cs') and run_id = (select (v ->> 'run_id')::uuid from prx_run)), '2500|18654');
select test.throws('Finance cannot approve', format($$select test.prx_do('prx_fin', 'field_pay_run_approve', %L)$$, jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run))), 'Admin');
select test.eq('Finance sends it for approval', test.prx_do('prx_fin', 'payroll_submit', jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run))) ->> 'prepared', 'true');
select test.ok('the Admins are alerted', exists (select 1 from app_events e where e.payload::text like '%payroll_ready%'));
select test.eq('Finance reads the payroll: its lines and totals by currency',
  (select format('%s|%s', (select count(*) from jsonb_array_elements(v -> 'lines') l where l ->> 'name' like 'Prx %'), (select string_agg(t ->> 'currency', ',') from jsonb_array_elements(v -> 'totals') t))
     from (select test.prx_read('prx_fin', 'payroll', jsonb_build_object('date', test.prx_prev())) v) x), '5|CAD,USD');
select test.throws('Fleet cannot read the payroll', $$select test.prx_read('prx_fleet', 'payroll')$$, 'Finance or an Admin');

-- ================================================================ 3. an Admin approves and records the payments
select test.prx_do('prx_admin', 'field_pay_run_approve', jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run)));
select test.eq('approved: every line numbered, nothing paid by itself',
  (select format('%s|%s', bool_and(statement_number is not null), count(*) filter (where status = 'paid')) from field_pay_lines where run_id = (select (v ->> 'run_id')::uuid from prx_run)), 't|0');
select test.throws('adjustments change only on a draft', format($$select test.prx_do('prx_admin', 'payroll_adjust', %L)$$, jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run), 'staff', test.id('prx_cs'), 'amount_cents', 100, 'reason', 'late')), 'draft');
select test.eq('the staff member reads their stub once approved',
  (select format('%s|%s', jsonb_array_length(s -> 'stubs'), s -> 'stubs' -> 0 ->> 'currency') from (select test.prx_read('prx_cs', 'my_pay_stubs') s) x), '1|USD');
select test.eq('another staff member''s stubs are not in theirs', (select count(*) from jsonb_array_elements(test.prx_read('prx_cs', 'my_pay_stubs') -> 'stubs') x where x ->> 'staff_id' <> test.id('prx_cs')::text), 0::bigint);
select test.throws('Finance cannot record payments', format($$select test.prx_do('prx_fin', 'payroll_pay_all', %L)$$, jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run), 'method', 'e_transfer', 'reference', 'BATCH')), 'Admin');
select test.eq('an Admin records every payment at once', (test.prx_do('prx_admin', 'payroll_pay_all', jsonb_build_object('run_id', (select v ->> 'run_id' from prx_run), 'method', 'e_transfer', 'reference', 'BATCH-1')) ->> 'paid')::integer,
  (select count(*)::integer from field_pay_lines where run_id = (select (v ->> 'run_id')::uuid from prx_run)));
select test.eq('the run is paid, each reference carries the statement number',
  (select format('%s|%s', (select status from field_pay_runs where id = (select (v ->> 'run_id')::uuid from prx_run)), bool_and(reference = 'BATCH-1 ' || statement_number))
     from field_pay_lines where run_id = (select (v ->> 'run_id')::uuid from prx_run)), 'paid|t');
select test.eq('the pay statement email goes to an office staff member too, with the salary line in US dollars',
  (select (select r.email from app.notification_recipients(e, (select c from notification_catalogue c where c.code = 'staff_pay_statement')) r) || '|' || (x ->> 'gross_total') || '|' || (x -> 'pay_lines' -> 0 ->> 'what' like 'Salary for the two weeks%')
     from app_events e cross join lateral app.notification_payload('staff_pay_statement', e, '{}') x
    where e.code = 'staff_pay_statement' and e.entity_id = (select id from field_pay_lines where staff_id = test.id('prx_cs') and run_id = (select (v ->> 'run_id')::uuid from prx_run))),
  'prx_cs@example.test|US' || app.fmt_money(18654) || '|true');
select test.ok('the stub''s PDF facts carry the salary and the currency',
  (select (f ->> 'salary_cents')::bigint = 16154 and f ->> 'currency' = 'USD' from (select app.pdf_facts('pay_statement', (select id::text from field_pay_lines where staff_id = test.id('prx_cs') and run_id = (select (v ->> 'run_id')::uuid from prx_run))) f) x));

-- the settings back as the other suites expect them
update program_settings set va_salary_defaults = '{}'::jsonb;
