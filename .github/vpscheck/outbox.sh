#!/usr/bin/env bash
# The outbox end to end: one test email to rent@carmacars.ca through send-outbox and Resend.
source .github/vpscheck/common.sh
keys
say "== test email through the outbox to rent@carmacars.ca (code staff_site_alert, dedupe vpscheck|$RUN)"
q <<SQL | sayf
insert into notification_outbox (code, category, priority, audience, to_address, to_name, payload, dedupe_key, status, send_after)
values ('staff_site_alert', 'transactional', 1, 'staff_admin', 'rent@carmacars.ca', 'CarmaCars',
  jsonb_build_object('check_label', 'TEST - server switch check (ignore)', 'alert_detail', 'Test email sent by the post-switch check of api.carmacars.ca. No action needed.',
    'alert_advice', 'Nothing to do: this is a test.', 'alert_opened', to_char(now() at time zone 'America/Toronto', 'Mon DD HH24:MI'), 'failures', 'none', 'company_address', 'CarmaCars, Toronto, Ontario'),
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
flush outbox
