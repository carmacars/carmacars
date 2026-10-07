-- 0015_scheduled_jobs.sql
-- The scheduled jobs that are pure SQL, run by pg_cron inside the database.
-- Source: docs/architecture.md section 5; docs/decisions/0001-zero-fixed-fee-stack.md.
--
-- pg_cron runs on UTC. A job that belongs to a Toronto time is scheduled every hour; its wrapper
-- function below decides whether it is the right Toronto date and hour, and claims a row in
-- job_runs (job_name, run_key) so the same business day or month cannot run twice. A daylight
-- saving change or a retry therefore changes nothing.
--
-- Scheduled here (each calls a function from migrations 0001 to 0014):
--   fleet-recount         Monday from 08:00              app.fleet_count()
--   fleet-report-prepare  business day before the 1st    app.build_fleet_report()
--   returns-accrue        the 1st from 06:00             app.accrue_investment_returns()
--   statements-draft      5 days before the payout date  app.build_owner_statement() per Owner
--   owner-invoices        the billing date (15th)        app.generate_owner_invoices()
--
-- NOT scheduled here. Each needs an outside call (Stripe, email, the file store), so it runs in
-- an Edge Function, built with the app:
--   late-returns, payment-retries, reminders, deposit-holds, retention, expiry-watch, reconcile,
--   month-open (sending the fleet report, interest on overdue charges), payouts,
--   owner-billing (submitting the debits, T24, paying investor returns), debit-results, debit-retry.
-- NOT scheduled here either. Pure SQL, but the function is not written yet (a later migration,
-- with the app): holds-expire, deposits-due.

-- ---------------------------------------------------------------- claiming and closing a run
-- Returns the job_runs id when this call owns the run, null when the key has already run or is
-- running. A run that failed may be claimed again.
create or replace function app.job_claim(p_job text, p_key text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  insert into job_runs (job_name, run_key) values (p_job, p_key)
  on conflict (job_name, run_key) do update
     set status = 'running', started_at = now(), finished_at = null, error = null
   where job_runs.status = 'failed'
  returning id into v_id;
  return v_id;
end $$;

create or replace function app.job_succeed(p_run uuid, p_summary jsonb) returns void
language sql security definer set search_path = public, app as $$
  update job_runs set status = 'succeeded', finished_at = now(), summary = p_summary, error = null where id = p_run
$$;

-- Marks the run failed and raises one urgent admin task for it (not one per retry).
create or replace function app.job_fail(p_run uuid, p_error text, p_summary jsonb default null) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  j job_runs;
begin
  update job_runs set status = 'failed', finished_at = now(), error = p_error, summary = p_summary
   where id = p_run returning * into j;
  if not exists (select 1 from tasks where related_table = 'job_runs' and related_id = p_run
                    and task_type = 'job_failed' and status in ('open', 'in_progress', 'waiting')) then
    insert into tasks (queue, task_type, title, detail, priority, related_table, related_id)
    values ('admin', 'job_failed', format('Scheduled job %s failed for %s', j.job_name, j.run_key), p_error,
            'urgent', 'job_runs', p_run);
  end if;
end $$;

-- The Toronto hour (0 to 23) of an instant.
create or replace function app.local_hour(p_at timestamptz) returns integer
language sql immutable as $$ select extract(hour from (p_at at time zone 'America/Toronto'))::integer $$;

-- ---------------------------------------------------------------- the wrappers
-- Each takes the instant to judge by (now, unless a test or an admin catching up a missed day
-- passes another) and returns 'not_due', 'already_run', 'succeeded' or 'failed'.

-- Each Monday from 08:00: count the fleet, and the fleet less cars under exit notice; warn an
-- admin at the warning level (11) or fewer. Procedure 20, step 5.
create or replace function app.job_fleet_recount(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_set program_settings := app.settings(app.local_date(p_now));
  v_run uuid;
  v_all integer;
  v_less integer;
  v_warn boolean;
begin
  if extract(isodow from v_day) <> 1 or app.local_hour(p_now) < 8 then return 'not_due'; end if;
  v_run := app.job_claim('fleet-recount', v_day::text);
  if v_run is null then return 'already_run'; end if;
  begin
    v_all := app.fleet_count(v_day, false);
    v_less := app.fleet_count(v_day, true);
    v_warn := v_less <= v_set.fleet_warning_count;
    insert into fleet_counts (counted_on, on_policy, less_exit_notice, min_required, warned_admin)
    values (v_day, v_all, v_less, v_set.min_fleet_count, v_warn)
    on conflict (counted_on) do update
       set on_policy = excluded.on_policy, less_exit_notice = excluded.less_exit_notice,
           min_required = excluded.min_required, warned_admin = excluded.warned_admin;
    if v_warn then
      insert into tasks (queue, task_type, title, detail, procedure_no, priority, escalated, escalated_at, escalation_reason)
      values ('admin', 'fleet_minimum',
              case when v_less < v_set.min_fleet_count then 'Fleet is below the franchise minimum' else 'Fleet is at the franchise warning level' end,
              format('Monday recount on %s: %s vehicles on the Fleet Policy, %s less those under exit notice. Minimum %s.',
                     v_day, v_all, v_less, v_set.min_fleet_count),
              20, 'urgent', true, now(), 'count under 10 or about to be');
    end if;
    perform app.job_succeed(v_run, jsonb_build_object('counted_on', v_day, 'on_policy', v_all,
                                                      'less_exit_notice', v_less, 'warned_admin', v_warn));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- The last business day before the 1st, from 08:00: prepare next month's franchisor fleet
-- report. Sending it on the 1st is an email, so that step is not here. Procedure 20.
create or replace function app.job_fleet_report_prepare(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_month date := (app.month_start(app.local_date(p_now)) + interval '1 month')::date;   -- the report's month
  v_prepare date := (app.month_start(app.local_date(p_now)) + interval '1 month')::date - 1;
  v_run uuid;
  v_report uuid;
begin
  while not app.is_business_day(v_prepare) loop v_prepare := v_prepare - 1; end loop;
  if v_day <> v_prepare or app.local_hour(p_now) < 8 then return 'not_due'; end if;
  v_run := app.job_claim('fleet-report-prepare', to_char(v_month, 'YYYY-MM'));
  if v_run is null then return 'already_run'; end if;
  begin
    v_report := app.build_fleet_report(v_month);
    perform app.job_succeed(v_run, (select jsonb_build_object('report_month', r.report_month, 'fleet_report_id', r.id,
                                             'vehicle_count', r.vehicle_count, 'meets_minimum', r.meets_minimum)
                                      from fleet_reports r where r.id = v_report));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- The 1st from 06:00: accrue last month's investor Returns.
create or replace function app.job_returns_accrue(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_month date := (app.month_start(app.local_date(p_now)) - interval '1 month')::date;   -- the Return Month
  v_run uuid;
  v_n integer;
begin
  if extract(day from v_day) <> 1 or app.local_hour(p_now) < 6 then return 'not_due'; end if;
  v_run := app.job_claim('returns-accrue', to_char(v_month, 'YYYY-MM'));
  if v_run is null then return 'already_run'; end if;
  begin
    v_n := app.accrue_investment_returns(v_month);
    perform app.job_succeed(v_run, jsonb_build_object('return_month', v_month, 'returns_accrued', v_n));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- Five days before the payout date (the 5th when payouts are on the 10th), from 06:00: draft
-- last month's statement for every Owner with a vehicle in the program, and ask an admin to
-- approve the run before the payout date. One Owner's failure does not stop the others; the
-- run is then marked failed, and a retry rebuilds the drafts. Owner specification, section 5.
create or replace function app.job_statements_draft(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_month date := (app.month_start(app.local_date(p_now)) - interval '1 month')::date;   -- the statement month
  v_payout date := app.payout_date((app.month_start(app.local_date(p_now)) - interval '1 month')::date);
  v_run uuid;
  r record;
  v_built integer := 0;
  v_errors jsonb := '{}'::jsonb;
  v_summary jsonb;
begin
  if v_day <> v_payout - 5 or app.local_hour(p_now) < 6 then return 'not_due'; end if;
  v_run := app.job_claim('statements-draft', to_char(v_month, 'YYYY-MM'));
  if v_run is null then return 'already_run'; end if;
  begin
    for r in select o.id from owners o
              where o.status in ('active', 'in_default', 'exited')
                and exists (select 1 from vehicles v where v.owner_id = o.id and v.enrollment_date is not null)
                -- a statement already approved, paid or voided for the month is left alone
                and not exists (select 1 from owner_statements s
                                 where s.owner_id = o.id and s.statement_month = v_month and s.status <> 'draft')
                -- an Owner who has left and already has a final statement gets no more
                and not (o.status = 'exited' and exists (select 1 from owner_statements s
                                 where s.owner_id = o.id and s.is_final and s.status in ('approved', 'paid')))
              order by o.id
    loop
      begin
        perform app.build_owner_statement(r.id, v_month);
        v_built := v_built + 1;
      exception when others then
        v_errors := v_errors || jsonb_build_object(r.id::text, sqlerrm);
      end;
    end loop;
    v_summary := jsonb_build_object('statement_month', v_month, 'statements_built', v_built, 'errors', v_errors);
    if v_built > 0 and not exists (select 1 from tasks where related_table = 'job_runs' and related_id = v_run
                                      and task_type = 'approve_owner_statements') then
      insert into tasks (queue, task_type, title, detail, priority, due_at, related_table, related_id)
      values ('admin', 'approve_owner_statements',
              format('Approve the owner statements for %s', to_char(v_month, 'FMMonth YYYY')),
              format('%s draft statements are ready. Approve the run before the payout on %s.', v_built, v_payout),
              'high', app.local_midnight(v_payout), 'job_runs', v_run);
    end if;
    if v_errors <> '{}'::jsonb then
      perform app.job_fail(v_run, format('%s statement(s) could not be built; see summary', (select count(*) from jsonb_object_keys(v_errors))), v_summary);
      return 'failed';
    end if;
    perform app.job_succeed(v_run, v_summary);
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- The billing date (the 15th) from 06:00: one draft invoice per vehicle. Submitting the debits
-- and sending T24 need Stripe and email, so that step (owner-billing) is not here.
-- Owner specification, sections 1 and 9.
create or replace function app.job_owner_invoices(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_day date := app.local_date(p_now);
  v_month date := app.month_start(app.local_date(p_now));
  v_run uuid;
  v_n integer;
begin
  if v_day <> app.billing_date(v_month) or app.local_hour(p_now) < 6 then return 'not_due'; end if;
  v_run := app.job_claim('owner-invoices', to_char(v_month, 'YYYY-MM'));
  if v_run is null then return 'already_run'; end if;
  begin
    v_n := app.generate_owner_invoices(v_month);
    perform app.job_succeed(v_run, jsonb_build_object('period_month', v_month, 'invoices_created', v_n));
    return 'succeeded';
  exception when others then
    perform app.job_fail(v_run, sqlerrm);
    return 'failed';
  end;
end $$;

-- ---------------------------------------------------------------- privileges
-- For the server and the scheduler only; never a browser session.
revoke execute on function
  app.job_claim(text, text), app.job_succeed(uuid, jsonb), app.job_fail(uuid, text, jsonb),
  app.job_fleet_recount(timestamptz), app.job_fleet_report_prepare(timestamptz), app.job_returns_accrue(timestamptz),
  app.job_statements_draft(timestamptz), app.job_owner_invoices(timestamptz)
  from public, anon, authenticated;
grant execute on function
  app.job_claim(text, text), app.job_succeed(uuid, jsonb), app.job_fail(uuid, text, jsonb), app.local_hour(timestamptz),
  app.job_fleet_recount(timestamptz), app.job_fleet_report_prepare(timestamptz), app.job_returns_accrue(timestamptz),
  app.job_statements_draft(timestamptz), app.job_owner_invoices(timestamptz)
  to service_role;

-- ---------------------------------------------------------------- the schedule (pg_cron)
-- Does nothing where pg_cron is not available (a plain local or test database), or where it is
-- installed on the server but cannot be created in this database.
-- cron.schedule() with a job name replaces a job of the same name, so this block can run again.
do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: no jobs scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): no jobs scheduled', sqlerrm;
    return;
  end;
  -- every hour, UTC; the wrapper decides whether it is the Toronto day and hour
  perform cron.schedule('carmacars-fleet-recount',        '2 * * * *',  'select app.job_fleet_recount()');
  perform cron.schedule('carmacars-fleet-report-prepare', '4 * * * *',  'select app.job_fleet_report_prepare()');
  perform cron.schedule('carmacars-returns-accrue',       '6 * * * *',  'select app.job_returns_accrue()');
  perform cron.schedule('carmacars-statements-draft',     '8 * * * *',  'select app.job_statements_draft()');
  perform cron.schedule('carmacars-owner-invoices',       '10 * * * *', 'select app.job_owner_invoices()');
end $$;
