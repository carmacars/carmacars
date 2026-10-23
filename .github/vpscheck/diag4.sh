#!/usr/bin/env bash
source .github/vpscheck/common.sh
say "== record_cookie_notice in a rolled-back transaction (why 409)"
q <<'SQL' | sayf
\set ON_ERROR_STOP 0
begin;
select app.record_cookie_notice('vpscheck-unknown-visitor', '2026-10-21', 'CA-ON', 'vpscheck');
rollback;
begin;
select app.record_cookie_notice((select visitor_id::text from cookie_consents order by created_at desc limit 1), '2026-10-21', 'CA-ON', 'vpscheck');
rollback;
select 'cookie_consents since go-live', count(*) from cookie_consents where created_at >= '2026-10-23 15:15+00';
select conname, pg_get_constraintdef(oid) from pg_constraint where conrelid = 'cookie_consents'::regclass and contype in ('f','u');
SQL
say "== install health-local (cron check) and run it"
vps_scp infra/vps/bin/health-local /tmp/health-local.new && vps_ssh "sudo install -m 755 /tmp/health-local.new /opt/carmacars/bin/health-local && rm -f /tmp/health-local.new && sudo /opt/carmacars/bin/health-local | jq -c '{ok, problems, cron_failed_30m}'" 2>&1 | sayf
say "== cron since the fix"
q <<'SQL' | sayf
select count(*), count(*) filter (where status='failed') from cron.job_run_details where start_time >= '2026-10-23 15:52+00';
select j.jobname, d.status, to_char(d.start_time at time zone 'UTC','HH24:MI') from cron.job_run_details d join cron.job j using (jobid) where j.jobname in ('carmacars-capture','carmacars-fleet-recount','carmacars-fleet-report-prepare','carmacars-returns-accrue','carmacars-statements-draft','carmacars-owner-invoices','carmacars-usage','carmacars-deposits-due','carmacars-expiry-watch','carmacars-commission-month','carmacars-task-hygiene') and d.start_time >= '2026-10-23 15:15+00' order by 3;
select 'app_events since fix', count(*) from app_events where created_at >= '2026-10-23 15:52+00';
select 'outbox since fix', coalesce(string_agg(status||'='||n,' '),'none') from (select status, count(*) n from notification_outbox where created_at >= '2026-10-23 15:52+00' group by 1) x;
SQL
flush diag4
