#!/usr/bin/env bash
# 6. Webhooks into the site: unsigned requests answer 4xx; a Stripe event signed with the endpoint's secret (a made-up
# event type the handler ignores, no payment) is verified and claimed in webhook_events, then removed.
source .github/vpscheck/common.sh
say "== unsigned POSTs (expect 4xx, never 5xx)"
for p in /api/webhooks/stripe /api/webhooks/quo /api/webhooks/auth-sms /api/inbound/turo; do
  say "$p: $(curl -sS --max-time 20 -X POST "$SITE$p" -H 'content-type: application/json' -d '{"type":"vpscheck"}' -w ' HTTP %{http_code} %{time_total}s' | tail -c 140)"
done
say "== Stripe: signed test event (type vpscheck.test)"
WS=$(vault deploy_stripe_webhook_secret)
if [ -n "$WS" ]; then
  ts=$(date +%s)
  body=$(jq -cn --arg id "evt_vpscheck_$RUN" '{id: $id, object: "event", api_version: "2024-06-20", created: now|floor, livemode: false, type: "vpscheck.test", pending_webhooks: 0, request: {id: null, idempotency_key: null}, data: {object: {id: "vpscheck_test", object: "vpscheck"}}}')
  sig=$(printf '%s' "$ts.$body" | openssl dgst -sha256 -hmac "$WS" -hex | awk '{print $NF}')
  say "signed: $(curl -sS --max-time 30 -X POST "$SITE/api/webhooks/stripe" -H 'content-type: application/json' -H "stripe-signature: t=$ts,v1=$sig" --data-binary "$body" -w ' HTTP %{http_code} %{time_total}s' | tail -c 200)"
  say "replay: $(curl -sS --max-time 30 -X POST "$SITE/api/webhooks/stripe" -H 'content-type: application/json' -H "stripe-signature: t=$ts,v1=$sig" --data-binary "$body" -w ' HTTP %{http_code}' | tail -c 200)"
  say "wrong signature: $(curl -sS --max-time 30 -X POST "$SITE/api/webhooks/stripe" -H 'content-type: application/json' -H "stripe-signature: t=$ts,v1=00$sig" --data-binary "$body" -w ' HTTP %{http_code}' | tail -c 120)"
  q <<SQL | sayf
select 'row', event_type, processed_at is not null, left(coalesce(result::text,''),80), coalesce(error,'') from webhook_events where provider='stripe' and event_id='evt_vpscheck_$RUN';
delete from webhook_events where provider='stripe' and event_id like 'evt_vpscheck_%' returning 'deleted';
SQL
else say "no deploy_stripe_webhook_secret in the vault"; fi
say "== real deliveries since go-live"
q <<SQL | sayf
select 'webhook_events', provider, count(*), count(*) filter (where processed_at is not null), count(*) filter (where error is not null), to_char(max(received_at) at time zone 'UTC','HH24:MI') from webhook_events where received_at >= '$SINCE' group by 2;
select 'webhook_events last before go-live', provider, to_char(max(received_at) at time zone 'UTC','MM-DD HH24:MI') from webhook_events where received_at < '$SINCE' group by 2;
select 'phone_webhook_log', count(*), to_char(max(received_at) at time zone 'UTC','HH24:MI') from phone_webhook_log where received_at >= '$SINCE';
select 'phone_webhook_log last before go-live', to_char(max(received_at) at time zone 'UTC','MM-DD HH24:MI') from phone_webhook_log where received_at < '$SINCE';
SQL
SK=$(vault deploy_stripe_secret_key)
if [ -n "$SK" ]; then
  say "== Stripe's own view: webhook endpoints and recent event deliveries"
  curl -sS --max-time 20 -u "$SK:" "https://api.stripe.com/v1/webhook_endpoints?limit=10" | jq -r '.data[]? | "endpoint \(.url) status=\(.status) events=\(.enabled_events|length) livemode=\(.livemode)"' | sayf
  curl -sS --max-time 20 -u "$SK:" "https://api.stripe.com/v1/events?limit=15&created[gte]=$(date -d "$SINCE" +%s)" | jq -r '.data[]? | "event \(.type) created=\(.created|todate) pending_webhooks=\(.pending_webhooks)"' | sayf
  say "(key mode: $(cut -c1-8 <<<"$SK" | sed 's/_[A-Za-z0-9]*$//'))"
fi
QK=$(vault deploy_quo_api_key)
if [ -n "$QK" ]; then
  say "== Quo webhooks registered"
  curl -sS --max-time 20 "https://api.openphone.com/v1/webhooks" -H "Authorization: $QK" | jq -r '.data[]? | "quo webhook \(.url) status=\(.status) events=\(.events|join(","))"' | sayf
fi
flush webhooks
