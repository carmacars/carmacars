#!/usr/bin/env bash
source .github/vpscheck/common.sh
vps_scp infra/vps/bin/health-local /tmp/health-local.new && vps_ssh "sudo install -m 755 /tmp/health-local.new /opt/carmacars/bin/health-local && rm -f /tmp/health-local.new && sudo /opt/carmacars/bin/health-local | jq -c '{ok, problems, cron_jobs_failing}'" 2>&1 | sayf
q <<'SQL' | sayf
select j.jobname, d.status, to_char(d.start_time at time zone 'UTC','HH24:MI') from cron.job_run_details d join cron.job j using (jobid) where d.start_time >= '2026-10-23 15:52+00' and (d.status <> 'succeeded' or j.jobname in ('carmacars-capture','carmacars-fleet-report-prepare','carmacars-returns-accrue','carmacars-statements-draft','carmacars-owner-invoices')) order by 3;
select 'runs since fix', count(*), count(*) filter (where status='failed') from cron.job_run_details where start_time >= '2026-10-23 15:52+00';
SQL
flush hl
