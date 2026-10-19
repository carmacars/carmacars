-- 05: the scheduled job wrappers of migration 0015: each runs only on its Toronto day and hour,
-- once per run key in job_runs, and records what it did. pg_cron itself is not needed here:
-- the wrappers take the instant to judge by.
select test.suite('05 jobs');

create or replace function test.at(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;

-- ------------------------------------------------------------------ Toronto hour and the run key
select test.eq('J 13:00 UTC in January is 08:00 in Toronto', app.local_hour(timestamptz '2028-01-03 13:00+00'), 8);
select test.eq('J 12:00 UTC in July is 08:00 in Toronto (daylight time)', app.local_hour(timestamptz '2028-07-03 12:00+00'), 8);
select test.ok('J the first claim of a run key owns the run', app.job_claim('test-job', 'k1') is not null);
select test.eq('J and the run is recorded as running', (select status from job_runs where job_name = 'test-job' and run_key = 'k1'), 'running');
select test.eq('J a second claim of the same key gets nothing', app.job_claim('test-job', 'k1'), null::uuid);
select app.job_succeed((select id from job_runs where job_name = 'test-job' and run_key = 'k1'), '{"n": 1}');
select test.eq('J a run that succeeded cannot be claimed again', app.job_claim('test-job', 'k1'), null::uuid);
select app.job_claim('test-job', 'k2');
select app.job_fail((select id from job_runs where job_name = 'test-job' and run_key = 'k2'), 'it broke');
select app.job_fail((select id from job_runs where job_name = 'test-job' and run_key = 'k2'), 'it broke again');
select test.eq('J a failed run records the error and raises one urgent admin task, not one per failure',
  (select j.status || '/' || j.error || '/' || (select count(*) from tasks t where t.related_id = j.id and t.task_type = 'job_failed'
                                                    and t.queue = 'admin' and t.priority = 'urgent')
     from job_runs j where job_name = 'test-job' and run_key = 'k2'), 'failed/it broke again/1');
select test.ok('J a failed run may be claimed again', app.job_claim('test-job', 'k2') is not null);
select test.eq('J under the same row, running again with the error cleared',
  (select count(*) || '/' || min(status) || '/' || coalesce(min(error), 'no error') from job_runs where job_name = 'test-job' and run_key = 'k2'), '1/running/no error');

-- ------------------------------------------------------------------ fleet-recount: Monday from 08:00
delete from tasks where task_type = 'fleet_minimum';
select test.eq('J fleet-recount: Monday 07:59 is too early', app.job_fleet_recount(test.at('2028-01-03 07:59')), 'not_due');
select test.eq('J fleet-recount: Tuesday is not the day', app.job_fleet_recount(test.at('2028-01-04 09:00')), 'not_due');
select test.eq('J fleet-recount: nothing is recorded when it is not due',
  (select count(*) from job_runs where job_name = 'fleet-recount'), 0::bigint);
select test.eq('J fleet-recount: Monday 08:00 runs', app.job_fleet_recount(test.at('2028-01-03 08:00')), 'succeeded');
select test.eq('J fleet-recount: the next hour of the same Monday does not run again', app.job_fleet_recount(test.at('2028-01-03 09:00')), 'already_run');
select test.eq('J fleet-recount: the count is stored, with and without cars under exit notice',
  (select (on_policy = app.fleet_count(date '2028-01-03', false)) || '/' || (less_exit_notice = app.fleet_count(date '2028-01-03', true))
          || '/' || min_required from fleet_counts where counted_on = date '2028-01-03'), 'true/true/10');
select test.eq('J fleet-recount: an admin is warned at 11 or fewer, and only then',
  (select warned_admin = (less_exit_notice <= 11) and warned_admin = exists (select 1 from tasks where task_type = 'fleet_minimum' and queue = 'admin' and priority = 'urgent')
     from fleet_counts where counted_on = date '2028-01-03'), true);
select test.eq('J fleet-recount: the run is keyed by the Toronto date and keeps a summary',
  (select status || '/' || (summary ->> 'counted_on') from job_runs where job_name = 'fleet-recount' and run_key = '2028-01-03'), 'succeeded/2028-01-03');
select test.eq('J fleet-recount: the following Monday is a new run', app.job_fleet_recount(test.at('2028-01-10 08:00')), 'succeeded');
-- with the warning level raised above the fleet's size from June 2028, the Monday recount warns
insert into program_settings (effective_from, fleet_warning_count) values (date '2028-06-01', 1000);
select test.eq('J fleet-recount: at or under the warning level the recount runs', app.job_fleet_recount(test.at('2028-06-05 08:00')), 'succeeded');
select test.eq('J fleet-recount: and raises one urgent, escalated admin task under procedure 20',
  (select (select warned_admin from fleet_counts where counted_on = date '2028-06-05')
          || '/' || count(*) || '/' || min(priority) || '/' || bool_and(escalated) || '/' || min(procedure_no)
     from tasks where task_type = 'fleet_minimum' and queue = 'admin'), 'true/1/urgent/true/20');

-- ------------------------------------------------------------------ fleet-report-prepare: business day before the 1st
-- May 1, 2028 is a Monday, so the business day before it is Friday April 28.
select test.eq('J fleet-report: Sunday April 30 is not a business day', app.job_fleet_report_prepare(test.at('2028-04-30 09:00')), 'not_due');
select test.eq('J fleet-report: Thursday April 27 is a day early', app.job_fleet_report_prepare(test.at('2028-04-27 09:00')), 'not_due');
select test.eq('J fleet-report: Friday April 28 before 08:00 is too early', app.job_fleet_report_prepare(test.at('2028-04-28 07:00')), 'not_due');
select test.eq('J fleet-report: Friday April 28 from 08:00 prepares May', app.job_fleet_report_prepare(test.at('2028-04-28 08:30')), 'succeeded');
select test.eq('J fleet-report: the May report is prepared, as of the 1st',
  (select status || '/' || as_of || '/' || (vehicle_count = app.fleet_count(date '2028-05-01')) from fleet_reports where report_month = date '2028-05-01'), 'prepared/2028-05-01/true');
select test.eq('J fleet-report: it does not run twice for one month', app.job_fleet_report_prepare(test.at('2028-04-28 10:00')), 'already_run');
-- June 1, 2028 is a Thursday. With Wednesday May 31 a holiday, the business day before is Tuesday May 30.
insert into holidays (holiday_on, name) values (date '2028-05-31', 'Test holiday');
select test.eq('J fleet-report: a holiday is not a business day', app.job_fleet_report_prepare(test.at('2028-05-31 09:00')), 'not_due');
select test.eq('J fleet-report: so the report is prepared the day before the holiday', app.job_fleet_report_prepare(test.at('2028-05-30 09:00')), 'succeeded');
select test.eq('J fleet-report: keyed by the report month',
  (select string_agg(run_key, ',' order by run_key) from job_runs where job_name = 'fleet-report-prepare' and status = 'succeeded'), '2028-05,2028-06');

-- ------------------------------------------------------------------ returns-accrue: the 1st from 06:00
-- Ian's investment (03 flows) has July 2027 accrued; August 2027 is next.
select test.eq('J returns: the 2nd is not the day', app.job_returns_accrue(test.at('2027-09-02 06:00')), 'not_due');
select test.eq('J returns: the 1st before 06:00 is too early', app.job_returns_accrue(test.at('2027-09-01 05:59')), 'not_due');
select test.eq('J returns: the 1st from 06:00 accrues last month', app.job_returns_accrue(test.at('2027-09-01 06:00')), 'succeeded');
select test.eq('J returns: August 2027 is accrued for the investment: $500',
  (select return_cents from investment_returns where investment_id = test.id('invm:ian') and return_month = date '2027-08-01'), 50000::bigint);
select test.eq('J returns: the run is keyed by the Return Month and counts what it accrued',
  (select status || '/' || ((summary ->> 'returns_accrued')::integer >= 1) from job_runs where job_name = 'returns-accrue' and run_key = '2027-08'), 'succeeded/true');
select test.eq('J returns: it does not run twice for one month', app.job_returns_accrue(test.at('2027-09-01 07:00')), 'already_run');
-- A month out of order is refused by app.accrue_investment_return: the job fails, says why, and may be retried.
select test.eq('J returns: a month out of order fails', app.job_returns_accrue(test.at('2028-03-01 06:00')), 'failed');
select test.eq('J returns: the failure is recorded with the reason, and nothing is accrued',
  (select status || '/' || (error like '%accrued in order%') || '/' || (select count(*) from investment_returns where investment_id = test.id('invm:ian') and return_month = date '2028-02-01')
     from job_runs where job_name = 'returns-accrue' and run_key = '2028-02'), 'failed/true/0');
select test.eq('J returns: the next hourly call retries a failed run', app.job_returns_accrue(test.at('2028-03-01 07:00')), 'failed');
select test.eq('J returns: still one admin task for that run',
  (select count(*) from tasks t join job_runs j on j.id = t.related_id where j.job_name = 'returns-accrue' and j.run_key = '2028-02' and t.task_type = 'job_failed'), 1::bigint);

-- ------------------------------------------------------------------ owner-invoices: the billing date from 06:00
select test.mk_owner('jonah');
select test.mk_vehicle('J1', 'jonah', 'managed', 45000, 2500, 3500, date '2028-01-01');
select test.eq('J invoices: the 14th is not the billing date', app.job_owner_invoices(test.at('2028-03-14 09:00')), 'not_due');
select test.eq('J invoices: 09:59 UTC on the 15th is 05:59 in Toronto, too early', app.job_owner_invoices(timestamptz '2028-03-15 09:59+00'), 'not_due');
select test.eq('J invoices: 10:00 UTC on the 15th is 06:00 in Toronto: runs', app.job_owner_invoices(timestamptz '2028-03-15 10:00+00'), 'succeeded');
select test.eq('J invoices: one draft invoice for the vehicle for March 2028: $475.00 plus HST',
  (select status || '/' || (select sum(amount_cents) from owner_invoice_lines l where l.owner_invoice_id = i.id)
     from owner_invoices i where vehicle_id = test.id('vehicle:J1') and period_month = date '2028-03-01' and kind = 'monthly'), 'draft/47500');
select test.eq('J invoices: it does not run twice for one month', app.job_owner_invoices(test.at('2028-03-15 11:00')), 'already_run');
select test.eq('J invoices: so there is still one March invoice for the vehicle',
  (select count(*) from owner_invoices where vehicle_id = test.id('vehicle:J1') and period_month = date '2028-03-01'), 1::bigint);

-- ------------------------------------------------------------------ statements-draft: 5 days before the payout date
select test.eq('J statements: the 4th is not the day', app.job_statements_draft(test.at('2028-04-04 09:00')), 'not_due');
select test.eq('J statements: the 5th before 06:00 is too early', app.job_statements_draft(test.at('2028-04-05 05:00')), 'not_due');
select test.eq('J statements: the 5th from 06:00 drafts last month', app.job_statements_draft(test.at('2028-04-05 06:00')), 'succeeded');
select test.eq('J statements: a draft March 2028 statement exists for the Owner, payable on April 10',
  (select status || '/' || payout_date from owner_statements where owner_id = test.id('owner:jonah') and statement_month = date '2028-03-01'), 'draft/2028-04-10');
select test.eq('J statements: one statement per Owner with a vehicle in the program, none skipped silently',
  (select (summary ->> 'statements_built')::integer + (select count(*) from jsonb_object_keys(summary -> 'errors'))
     from job_runs where job_name = 'statements-draft' and run_key = '2028-03'),
  (select count(*)::integer from owners o where o.status in ('active', 'in_default', 'exited')
      and exists (select 1 from vehicles v where v.owner_id = o.id and v.enrollment_date is not null)
      and not (o.status = 'exited' and exists (select 1 from owner_statements s where s.owner_id = o.id and s.is_final and s.status in ('approved', 'paid')))));
select test.eq('J statements: an admin is asked to approve the run before the payout date',
  (select count(*) || '/' || min(queue) || '/' || min(due_at) from tasks where task_type = 'approve_owner_statements'
      and related_id = (select id from job_runs where job_name = 'statements-draft' and run_key = '2028-03')),
  '1/admin/' || test.at('2028-04-10 00:00'));
select test.eq('J statements: a run that succeeded does not run again',
  (select case when status = 'succeeded' then app.job_statements_draft(test.at('2028-04-05 08:00')) else 'already_run' end
     from job_runs where job_name = 'statements-draft' and run_key = '2028-03'), 'already_run');
-- an approved statement is never rebuilt by the job
select app.approve_owner_statement(
  (select id from owner_statements where owner_id = test.id('owner:jonah') and statement_month = date '2028-03-01'), test.id('admin_abbas'));
update job_runs set status = 'failed' where job_name = 'statements-draft' and run_key = '2028-03';
select app.job_statements_draft(test.at('2028-04-05 09:00'));
select test.eq('J statements: a retry leaves an approved statement alone and does not ask twice',
  (select (select status from owner_statements where owner_id = test.id('owner:jonah') and statement_month = date '2028-03-01')
          || '/' || (select count(*) from tasks where task_type = 'approve_owner_statements'
                       and related_id = (select id from job_runs where job_name = 'statements-draft' and run_key = '2028-03'))), 'approved/1');

-- ------------------------------------------------------------------ who may run them, and the schedule
select test.eq('J no job function is executable from a browser session',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname like 'job\_%'
      and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), null::text);
select test.eq('J the server may run every job function',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname like 'job\_%' and not has_function_privilege('service_role', p.oid, 'execute')), 0::bigint);
select test.ok('J without pg_cron the migrations schedule nothing; with it, the five jobs of 0015, offers-expire of 0016, notify-events of 0018, the four of 0020, the two of 0021, the two of 0023, the five of 0024, the owner debit notices of 0037 and the staff commission month of 0058',
  to_regclass('cron.job') is null
  or (select (xpath('/row/n/text()', query_to_xml($q$select count(*) as n from cron.job where jobname like 'carmacars-%'$q$, false, true, '')))[1]::text = '22'));
