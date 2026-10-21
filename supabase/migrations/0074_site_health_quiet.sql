-- 0074_site_health_quiet.sql
-- Site health, scheduled jobs: a pg_cron run that failed only because it could not start for a moment ('job startup
-- timeout', when every database connection was briefly busy, for example during a full live check) no longer shows as
-- an error once the same job has run successfully after it. A job that keeps failing, or fails for any other reason,
-- is still reported. Only the scheduled jobs query of app.uptime_internal changes.

CREATE OR REPLACE FUNCTION app.uptime_internal(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_failed integer;
  v_stuck integer;
  v_cron text;
  v_jobs text;
  b job_runs;
  v_ok_at timestamptz;
  v_stripe integer;
  v_out jsonb := '{}'::jsonb;
  v_detail text;
begin
  -- emails: failures in the last hour, or emails due 15 minutes ago and still waiting (the sender is not running)
  select count(*) into v_failed from notification_outbox where status = 'failed' and updated_at > p_now - interval '1 hour';
  select count(*) into v_stuck from notification_outbox where status = 'queued' and send_after < p_now - interval '15 minutes';
  v_detail := case when v_failed >= ps.uptime_email_failures then format('%s emails failed in the last hour', v_failed)
                   when v_stuck > 0 then format('%s emails waiting more than 15 minutes (the sender may have stopped)', v_stuck) end;
  v_out := v_out || jsonb_build_object('email', app.uptime_record('email', v_detail is null, null, null, coalesce(v_detail, 'Sending normally'), p_now));
  -- scheduled jobs: a pg_cron run that failed in the last hour, or a job run marked failed
  if to_regclass('cron.job_run_details') is not null then
    begin
      execute $q$select string_agg(distinct j.jobname, ', ') from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                  where d.status = 'failed' and d.start_time > $1 - interval '1 hour'
                    -- a run pg_cron could not start (no free connection for a moment) is only a problem if the job has
                    -- not run successfully since: the next minute's run catches up (0074)
                    and not (coalesce(d.return_message, '') ilike '%startup timeout%' and exists (
                      select 1 from cron.job_run_details n where n.jobid = d.jobid and n.status = 'succeeded' and n.start_time > d.start_time))$q$ into v_cron using p_now;
    exception when others then v_cron := null;
    end;
  end if;
  select string_agg(distinct job_name, ', ') into v_jobs from job_runs where status = 'failed' and coalesce(finished_at, started_at) > p_now - interval '1 hour';
  v_detail := nullif(concat_ws('; ', 'pg_cron: ' || v_cron, 'failed runs: ' || v_jobs), '');
  v_out := v_out || jsonb_build_object('jobs', app.uptime_record('jobs', v_detail is null, null, null, coalesce(v_detail, 'No failed run in the last hour'), p_now));
  -- the nightly backup: the last run failed, or the last good one is too old (only once a backup has run)
  select * into b from job_runs where job_name = 'backup-nightly' order by started_at desc limit 1;
  select max(coalesce(finished_at, started_at)) into v_ok_at from job_runs where job_name = 'backup-nightly' and status = 'succeeded';
  if b.id is null then
    v_out := v_out || jsonb_build_object('backup', app.uptime_record('backup', true, null, null, 'No backup recorded yet on this database', p_now));
  else
    v_detail := case when b.status = 'failed' then 'The last nightly backup failed: ' || coalesce(left(b.error, 200), 'see the backup workflow')
                     when v_ok_at is null or v_ok_at < p_now - make_interval(hours => ps.uptime_backup_max_hours)
                       then format('No good backup for more than %s hours (last: %s)', ps.uptime_backup_max_hours, coalesce(app.fmt_at(v_ok_at), 'never')) end;
    v_out := v_out || jsonb_build_object('backup', app.uptime_record('backup', v_detail is null, null, null,
      coalesce(v_detail, 'Last good backup ' || app.fmt_at(v_ok_at)), p_now));
  end if;
  -- Stripe: events that failed to process in the last hour (Stripe retries; a later success clears the error)
  select count(*) into v_stripe from webhook_events where provider = 'stripe' and error is not null and received_at > p_now - interval '1 hour';
  v_out := v_out || jsonb_build_object('stripe', app.uptime_record('stripe', v_stripe = 0, null, null,
    case when v_stripe = 0 then 'No failed Stripe event in the last hour' else format('%s Stripe events failed to process in the last hour', v_stripe) end, p_now));
  return v_out;
end $function$;
