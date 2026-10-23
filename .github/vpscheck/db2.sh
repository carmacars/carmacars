#!/usr/bin/env bash
# After the sequence fix (15:52 UTC): cron failures, API errors, writes.
source .github/vpscheck/common.sh
FIX='2026-10-23 15:52:00+00'
say "== cron runs since go-live: total, failed; failed since the fix"
q <<SQL | sayf
select count(*), count(*) filter (where status='failed'), count(*) filter (where status='failed' and start_time >= '$FIX') from cron.job_run_details where start_time >= '$SINCE';
select j.jobname, d.status, to_char(d.start_time at time zone 'UTC','HH24:MI'), left(regexp_replace(coalesce(d.return_message,''),'\s+',' ','g'),200) from cron.job_run_details d join cron.job j using (jobid) where d.start_time >= '$SINCE' and d.status <> 'succeeded' order by d.start_time;
select 'active jobs never run since go-live', string_agg(j.jobname || ' (' || j.schedule || ')', ', ') from cron.job j where j.active and not exists (select 1 from cron.job_run_details d where d.jobid=j.jobid and d.start_time >= '$SINCE');
select 'capture ok since fix', count(*) from cron.job_run_details d join cron.job j using (jobid) where j.jobname='carmacars-capture' and d.start_time >= '$FIX' and d.status='succeeded';
SQL
say "== rows since go-live / since the fix"
for t in app_events audit_log notification_outbox status_history booking_events; do
  say "$t: $(q <<<"select count(*) || ' / ' || count(*) filter (where created_at >= '$FIX') from $t where created_at >= '$SINCE'" | tail -1 | cut -c1-100)"
done
say "outbox since the fix: $(q <<<"select coalesce(string_agg(status||'='||n, ' '),'none') from (select status, count(*) n from notification_outbox where created_at >= '$FIX' group by 1) x" | tail -1)"
say "== kong 4xx/5xx since the fix, by path"
vps_ssh "sudo /opt/carmacars/bin/dc logs --no-color --no-log-prefix --since 2026-10-23T15:52:00Z kong 2>&1" | grep -E '" (4[0-9]{2}|5[0-9]{2}) ' | grep -oE '"(GET|POST|PATCH|DELETE|PUT|HEAD) [^ ?]+[^"]*" [0-9]{3}' | sed -E 's/\?[^ ]*//; s#/(object|sign)/(public|authenticated|sign)?/?([a-z-]+)/.*" #/\1/\2/\3/… " #; s/[0-9a-f]{8}-[0-9a-f-]{27}/<uuid>/g' | sort | uniq -c | sort -rn | head -25 | sayf
say "== function grants (authenticated) for the 403 RPCs"
q <<'SQL' | sayf
select p.proname, has_function_privilege('authenticated', p.oid, 'execute'), has_function_privilege('anon', p.oid, 'execute'), p.prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('partner_agreement_state','owner_portal_home','record_cookie_notice','server_view_as_start','server_indexnow_sent','server_indexnow_claim');
select 'public functions not executable by authenticated', count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and not has_function_privilege('authenticated', p.oid, 'execute');
select 'public functions not executable by service_role', count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and not has_function_privilege('service_role', p.oid, 'execute');
SQL
say "== placeholder svg now: $(code_time "$API/storage/v1/object/public/vehicle-public/vehicles/toyota-corolla-side.svg")"
flush db2
