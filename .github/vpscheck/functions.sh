#!/usr/bin/env bash
# 5. Edge Functions from pg_cron through Kong; the outbox end to end (one test email to rent@carmacars.ca).
source .github/vpscheck/common.sh
keys
say "== cron jobs that call functions: name | schedule | active | url | runs ok/failed since go-live"
q <<SQL | sayf
select j.jobname, j.schedule, j.active, substring(j.command from 'https?://[^'' ]+'),
  count(d.*) filter (where d.status='succeeded'), count(d.*) filter (where d.status='failed')
from cron.job j left join cron.job_run_details d on d.jobid=j.jobid and d.start_time >= '$SINCE'
where j.command ilike '%functions/v1%' or j.command ilike '%net.http%' group by 1,2,3,4 order by 1;
SQL
say "== function answers (pg_net) since go-live, by body shape"
q <<SQL | sayf
select status_code, left(regexp_replace(coalesce(content,error_msg,''), '[0-9]+', 'n', 'g'), 120), count(*), to_char(max(created) at time zone 'UTC','HH24:MI')
from net._http_response where created >= '$SINCE' group by 1,2 order by 3 desc limit 20;
SQL
say "== functions without token (expect 403/401) and kong route"
for f in send-outbox owner-debit calendar-sync; do say "$f no token: $(code_time -X POST "$API/functions/v1/$f")"; done
say "== outbox since go-live: status | count | last"
q <<SQL | sayf
select status, count(*), to_char(max(coalesce(sent_at, created_at)) at time zone 'UTC','HH24:MI') from notification_outbox where created_at >= '$SINCE' or sent_at >= '$SINCE' group by 1 order by 2 desc;
select 'queued and due, oldest age min', count(*), coalesce(round(extract(epoch from now() - min(send_after))/60),0) from notification_outbox where status='queued' and send_after <= now();
select 'failed since go-live, errors', left(regexp_replace(coalesce(last_error,''),'[0-9]+','n','g'),160), count(*) from notification_outbox where status='failed' and created_at >= '$SINCE' group by 2;
SQL
say "== test email through the outbox to rent@carmacars.ca (code staff_site_alert, dedupe vpscheck|$RUN)"
q <<SQL | sayf
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, send_after)
values ('staff_site_alert', 'transactional', 1, 'staff_admin', 'rent@carmacars.ca', 'CarmaCars',
  jsonb_build_object('check_label', 'TEST - server switch check (ignore)', 'alert_detail', 'Test email sent by the post-switch check of api.carmacars.ca. No action needed.',
    'alert_advice', 'Nothing to do: this is a test.', 'alert_opened', to_char(now() at time zone 'America/Toronto', 'Mon DD HH24:MI'), 'failures', 'none'),
  'vpscheck|$RUN', 'queued', now()) returning 'inserted', id;
SQL
for i in $(seq 1 24); do
  st=$(q <<<"select status || ' ' || coalesce(provider_id,'-') || ' attempts=' || attempts || ' ' || coalesce(left(last_error,160),'') from notification_outbox where dedupe_key='vpscheck|$RUN'")
  case "$st" in sent*|failed*|suppressed*|skipped*) break ;; esac
  sleep 10
done
say "outbox row after $((i*10))s: $st"
pid=$(awk '{print $2}' <<<"$st")
RK=$(vps_secret RESEND_API_KEY); [ -n "$RK" ] || RK=$(vault deploy_resend_api_key)
if [ -n "$pid" ] && [ "$pid" != - ]; then
  sleep 20
  say "resend: $(curl -sS --max-time 20 "https://api.resend.com/emails/$pid" -H "Authorization: Bearer $RK" | jq -c '{last_event, subject, created_at}' 2>&1 | cut -c1-200)"
fi
say "cleanup: $(q <<<"delete from notification_outbox where dedupe_key='vpscheck|$RUN' returning 'deleted'" 2>&1 | tail -1 | cut -c1-200)"
flush functions
