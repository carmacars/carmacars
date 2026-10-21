-- 0074_cpu_and_storage.sql
-- Database growth and the Worker's idle cron ticks (docs/changes/2026-10-21-cpu-and-storage.md).
--
--   1. The audit log keeps what changed. public.audit_log was 161 MB for about 23,000 rows: every UPDATE stored the
--      whole row twice, and most updates changed nothing (the notification catalogue's refresh rewrote 9,026 rows,
--      5,975 of them identical; the search snapshots stamped seo_pages 3,300 times). From now on an UPDATE keeps only the
--      columns that changed (before and after), an UPDATE that changed nothing but updated_at or snapshot_at is not
--      logged, and a single value larger than 4 KB (an email template, a guide section, a page snapshot) is kept as its
--      md5 and size. INSERT and DELETE still keep the whole row (with the same 4 KB rule); the redacted tables
--      (card and bank secrets) still log the change without values. Money, bookings, owners, agreements, payouts,
--      users and roles stay audited exactly as before: only the shape of an UPDATE row changes. The existing rows are
--      not touched (a legal record); docs/sql/2026-10-21-audit-compaction.sql is an optional one-time compaction.
--   2. Two noisy system tables leave the audit: guide_reads (a counter of guide opens per person) and app_events (the
--      internal event queue: each event is written, then stamped processed). Neither holds money, pricing, a booking's
--      status or a person's details; the work each event does is audited where it lands.
--   3. pg_cron's own run history (cron.job_run_details, one row per job run, about 5,000 a day) is kept 7 days, by a
--      daily job (the uptime job's 14-day purge stays as a second line).
--   4. public.server_jobs_due(): the Worker's five-minute cron tick asks it before loading the app for the listing
--      pipeline and the search job (web/src/lib/edge/cron-gate.ts), so an idle tick costs one small call instead of
--      about a second of the Worker's CPU. It answers true whenever the job could find work (an over-estimate is
--      harmless: the job then runs as before).

-- ================================================================ 1. the audit row
-- A value larger than 4 KB as its md5 and size (top-level values of the row; the row's other values unchanged).
create or replace function app.audit_compact(p jsonb) returns jsonb
language sql immutable set search_path = public, app as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then p
    else (select coalesce(jsonb_object_agg(e.key,
            case when octet_length(e.value::text) > 4096
                 then jsonb_build_object('omitted', 'larger than 4 KB', 'md5', md5(e.value::text), 'bytes', octet_length(e.value::text))
                 else e.value end), '{}'::jsonb)
          from jsonb_each(p) e) end
$$;

-- Columns that only stamp a write: an UPDATE changing nothing else is not a change.
create or replace function app.audit_quiet_columns() returns text[]
language sql immutable as $$ select array['updated_at', 'snapshot_at'] $$;

create or replace function app.audit_row() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_id text;
  v_row jsonb;
  v_old jsonb;
  v_before jsonb;
  v_after jsonb;
  v_redact boolean := coalesce(tg_argv[0], '') = 'redact';
begin
  if tg_op = 'DELETE' then v_row := to_jsonb(old); else v_row := to_jsonb(new); end if;
  -- most tables key on id; a few key on the parent (booking_id, payment_id, ...)
  v_id := coalesce(v_row ->> 'id', v_row ->> 'booking_id', v_row ->> 'payment_id', v_row ->> 'code',
                   v_row ->> 'user_id', v_row ->> 'vehicle_id');
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    -- the columns that changed, before and after
    select jsonb_object_agg(n.key, o.value), jsonb_object_agg(n.key, n.value)
      into v_before, v_after
      from jsonb_each(v_row) n left join jsonb_each(v_old) o on o.key = n.key
     where o.value is distinct from n.value;
    -- nothing changed, or only the write stamps: not logged
    if v_after is null or not exists (select 1 from jsonb_object_keys(v_after) k where k <> all (app.audit_quiet_columns())) then
      return new;
    end if;
  elsif tg_op = 'INSERT' then
    v_after := v_row;
  else
    v_before := v_row;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (app.uid(), tg_op, tg_table_name, v_id,
          -- tables holding processor tokens or bank numbers pass 'redact': the change is logged, the values are not
          case when not v_redact then app.audit_compact(v_before) end,
          case when not v_redact then app.audit_compact(v_after) end);
  return coalesce(new, old);
end $$;

-- ================================================================ 2. two noisy system tables leave the audit
drop trigger if exists audit_guide_reads on public.guide_reads;
drop trigger if exists audit_app_events on public.app_events;

-- app.attach_audit() (0013) as before, with the two tables on its list of tables it leaves alone
create or replace function app.attach_audit() returns integer
language plpgsql as $$
declare
  t record;
  n integer := 0;
  v_skip text[] := array[
    'audit_log', 'status_history', 'data_access_log', 'job_runs',   -- logs
    'tracker_status',                                               -- telemetry, overwritten continuously
    'condition_report_photos', 'vehicle_photos', 'photo_jobs',      -- media bookkeeping
    'messages', 'incident_events',                                  -- already append-only records
    'guide_reads', 'app_events'                                     -- open counters and the internal event queue (0074)
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
revoke execute on function app.attach_audit() from public;
revoke all on function app.audit_compact(jsonb) from public, anon, authenticated;
revoke all on function app.audit_quiet_columns() from public, anon, authenticated;
grant execute on function app.audit_compact(jsonb) to service_role;
grant execute on function app.audit_quiet_columns() to service_role;

-- ================================================================ 3. pg_cron's run history: 7 days
create or replace function app.job_cron_history_purge() returns text
language plpgsql security definer set search_path = public, app as $$
declare
  n bigint := 0;
begin
  if to_regclass('cron.job_run_details') is null then return 'no pg_cron'; end if;
  execute $q$delete from cron.job_run_details where end_time < now() - interval '7 days'$q$;
  get diagnostics n = row_count;
  return format('%s runs removed', n);
end $$;
revoke all on function app.job_cron_history_purge() from public, anon, authenticated;
grant execute on function app.job_cron_history_purge() to service_role;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-cron-history-purge', '29 4 * * *', $q$select app.job_cron_history_purge()$q$);
  end if;
end $$;

-- ================================================================ 4. does the cron tick have work?
-- listing: a job the claim would take (queued and due, or running past its lock); seo: anything the search job's
-- claim could take or send (the car copy scan first, as the claim does), or a running item left behind.
create or replace function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_listing boolean;
  v_seo boolean;
begin
  v_listing := exists (select 1 from listing_jobs x
                        where (x.status = 'queued' and x.next_attempt_at <= now())
                           or (x.status = 'running' and x.locked_at < now() - make_interval(mins => ps.listing_job_lock_minutes)));
  perform app.car_copy_scan();
  v_seo := exists (select 1 from car_copy c where c.status in ('pending', 'failed') and c.next_attempt_at <= now())
        or exists (select 1 from seo_pages p where p.is_active and p.status in ('pending', 'failed') and p.next_attempt_at <= now())
        or exists (select 1 from articles a where a.status in ('pending', 'failed') and a.next_attempt_at <= now())
        or exists (select 1 from seo_pages p where p.status = 'running' and p.locked_at < now() - interval '10 minutes')
        or exists (select 1 from articles a where a.status = 'running' and a.locked_at < now() - interval '10 minutes')
        or (ps.indexnow_enabled and exists (select 1 from indexnow_queue q where q.sent_at is null and q.attempts < 5));
  return jsonb_build_object('listing', v_listing, 'seo', v_seo);
end $$;
create or replace function public.server_jobs_due() returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.server_jobs_due() $$;
revoke all on function app.server_jobs_due() from public, anon, authenticated;
revoke all on function public.server_jobs_due() from public, anon, authenticated;
grant execute on function app.server_jobs_due() to service_role;
grant execute on function public.server_jobs_due() to service_role;
