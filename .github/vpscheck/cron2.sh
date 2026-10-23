#!/usr/bin/env bash
source .github/vpscheck/common.sh
q <<'SQL' | sayf
select to_char(now() at time zone 'UTC','HH24:MI'), current_setting('cron.timezone', true);
select count(*), count(*) filter (where status='failed'), count(*) filter (where status='failed' and start_time >= '2026-10-23 15:52+00') from cron.job_run_details where start_time >= '2026-10-23 15:15+00';
select j.jobname, d.status, to_char(d.start_time at time zone 'UTC','HH24:MI') from cron.job_run_details d join cron.job j using (jobid) where j.jobname in ('carmacars-owner-invoices','carmacars-usage','carmacars-deposits-due','carmacars-statements-draft','carmacars-returns-accrue','carmacars-expiry-watch') and d.start_time >= '2026-10-23 15:15+00' order by 3;
select 'never run since go-live', string_agg(j.jobname || ' ' || j.schedule, '; ') from cron.job j where j.active and not exists (select 1 from cron.job_run_details d where d.jobid=j.jobid and d.start_time >= '2026-10-23 15:15+00');
select 'last run before go-live of those', string_agg(j.jobname || '@' || to_char((select max(start_time) from cron.job_run_details d where d.jobid=j.jobid) at time zone 'UTC','MM-DD HH24:MI'), '; ') from cron.job j where j.active and not exists (select 1 from cron.job_run_details d where d.jobid=j.jobid and d.start_time >= '2026-10-23 15:15+00');
select 'app_events since fix', count(*) from app_events where created_at >= '2026-10-23 15:52+00';
select 'outbox since fix', coalesce(string_agg(status||'='||n,' '),'none') from (select status, count(*) n from notification_outbox where created_at >= '2026-10-23 15:52+00' group by 1) x;
SQL
flush cron2
