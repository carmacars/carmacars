-- 0013_audit.sql
-- Audit every change to money, pricing or status. Rather than list tables one by one (and miss
-- the next one added), every table is audited except the logs themselves and high-volume
-- telemetry. Each audit_log row carries who (app.uid()), when, the table, the row, and the
-- row before and after. Tables that hold processor tokens or bank numbers are logged without values.
-- A later migration that adds a table must call app.attach_audit() again (the test suite checks).

create or replace function app.attach_audit() returns integer
language plpgsql as $$
declare
  t record;
  n integer := 0;
  v_skip text[] := array[
    'audit_log', 'status_history', 'data_access_log', 'job_runs',   -- logs
    'tracker_status',                                               -- telemetry, overwritten continuously
    'condition_report_photos', 'vehicle_photos', 'photo_jobs',      -- media bookkeeping
    'messages', 'incident_events'                                   -- already append-only records
  ];
  v_redact text[] := array['payment_method_secrets', 'payment_processor_details', 'owner_payment_method_secrets',
                           'owner_payout_accounts', 'investor_bank_accounts'];
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and c.relname <> all (v_skip)
              and not exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit_' || c.relname)
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function app.audit_row(%s)',
                   'audit_' || t.relname, t.relname,
                   case when t.relname = any (v_redact) then quote_literal('redact') else '' end);
    n := n + 1;
  end loop;
  return n;
end $$;

do $$ begin perform app.attach_audit(); end $$;
revoke execute on function app.attach_audit() from public;
