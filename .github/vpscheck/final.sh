#!/usr/bin/env bash
source .github/vpscheck/common.sh
keys
say "== photo cache-control: server vs frozen hosted (same object)"
q <<<"select coalesce(metadata->>'cacheControl','(none)'), count(*) from storage.objects where bucket_id='vehicle-public' group by 1 order by 2 desc" | sayf
n=$(q <<<"select name from storage.objects where bucket_id='vehicle-public' and metadata->>'mimetype' like 'image/jp%' order by created_at desc limit 1" | head -1)
e=$(jq -rn --arg p "$n" '$p|split("/")|map(@uri)|join("/")')
say "server: $(curl -sS -o /dev/null -D - "$API/storage/v1/object/public/vehicle-public/$e" | grep -iE '^(HTTP|cache-control|cf-cache)' | tr -d '\r' | paste -sd' ')"
say "hosted: $(curl -sS -o /dev/null -D - "https://$SUPABASE_PROJECT_REF.supabase.co/storage/v1/object/public/vehicle-public/$e" | grep -iE '^(HTTP|cache-control|cf-cache)' | tr -d '\r' | paste -sd' ')"
say "== cron since go-live / since the fix"
q <<'SQL' | sayf
select count(*), count(*) filter (where status='failed'), count(*) filter (where status='failed' and start_time >= '2026-10-23 15:52+00') from cron.job_run_details where start_time >= '2026-10-23 15:15+00';
select 'never run since go-live', string_agg(j.jobname || ' ' || j.schedule, '; ') from cron.job j where j.active and not exists (select 1 from cron.job_run_details d where d.jobid=j.jobid and d.start_time >= '2026-10-23 15:15+00');
select 'pg_net non-2xx since go-live', count(*) from net._http_response where created >= '2026-10-23 15:15+00' and (status_code is null or status_code >= 300);
select 'pre-switch sessions refreshed since go-live', count(distinct s.id) from auth.sessions s join auth.refresh_tokens t on t.session_id = s.id where s.created_at < '2026-10-23 15:15+00' and t.created_at >= '2026-10-23 15:15+00';
select 'app_events since fix', count(*) from app_events where created_at >= '2026-10-23 15:52+00';
select 'outbox since fix', coalesce(string_agg(status||'='||n,' '),'none') from (select status, count(*) n from notification_outbox where created_at >= '2026-10-23 15:52+00' group by 1) x;
select 'webhook_events since go-live', count(*) from webhook_events where received_at >= '2026-10-23 15:15+00';
SQL
say "== kong 5xx since the fix"
vps_ssh "sudo /opt/carmacars/bin/dc logs --no-color --no-log-prefix --since 2026-10-23T15:52:00Z kong 2>&1" | grep -E '" 5[0-9]{2} ' | grep -oE '"(GET|POST|PATCH|DELETE|PUT|HEAD) [^ ?]+[^"]*" [0-9]{3}' | sed -E 's/\?[^ ]*//; s#/(object|sign)/(public|authenticated|sign)?/?([a-z-]+)/.*" #/\1/\2/\3/… " #' | sort | uniq -c | sort -rn | head -10 | sayf
flush final
