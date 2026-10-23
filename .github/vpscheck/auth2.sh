#!/usr/bin/env bash
# Phone code through the site's path (the request recorded first, as the sign-in form does), and the site's Google start.
source .github/vpscheck/common.sh
keys
SH=(-H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H 'content-type: application/json')
AH=(-H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H 'content-type: application/json')
say "== site Google start"
curl -sS -o /dev/null -D "$RUNNER_TEMP/h1" --max-time 20 "$SITE/auth/oauth?provider=google"
say "site /auth/oauth: $(grep -iE '^(HTTP|location)' "$RUNNER_TEMP/h1" | tr -d '\r' | sed -E 's/(code_challenge|state)=[^&]+/\1=…/g' | paste -sd' ' | cut -c1-300)"
loc=$(grep -i '^location' "$RUNNER_TEMP/h1" | tr -d '\r' | cut -d' ' -f2-)
if [[ "$loc" == https://api.carmacars.ca/* ]]; then
  curl -sS -o /dev/null -D "$RUNNER_TEMP/h2" --max-time 20 "$loc"
  l2=$(grep -i '^location' "$RUNNER_TEMP/h2" | tr -d '\r' | cut -d' ' -f2-)
  say "-> $(head -1 "$RUNNER_TEMP/h2" | tr -d '\r') host=$(cut -d/ -f3 <<<"$l2") redirect_uri=$(grep -oE 'redirect_uri=[^&]+' <<<"$l2" | sed 's/%3A/:/g; s#%2F#/#g')"
fi
say "== phone code through the site's path, to the company number"
U=$(curl -sS --max-time 20 -X POST "$API/auth/v1/admin/users" "${SH[@]}" -d "{\"phone\":\"${PHONE#+}\",\"phone_confirm\":true,\"user_metadata\":{\"full_name\":\"VPS Check (temporary)\"}}")
uid=$(jq -r '.id // empty' <<<"$U"); say "temp phone user: ${uid:+made}${uid:-$(jq -c . <<<"$U" | cut -c1-160)}"
say "server_signin_phone_request: $(curl -sS --max-time 20 -X POST "$API/rest/v1/rpc/server_signin_phone_request" "${SH[@]}" -d "{\"p\":{\"phone\":\"$PHONE\",\"ip\":\"127.0.0.1\",\"kind\":\"code\",\"purpose\":\"sign_in\",\"user_id\":null}}" -w ' HTTP %{http_code}' | cut -c1-200)"
T=$(date -u +%H:%M:%S)
say "otp at $T: $(curl -sS --max-time 30 -X POST "$API/auth/v1/otp" "${AH[@]}" -d "{\"phone\":\"$PHONE\",\"create_user\":false,\"channel\":\"sms\"}" -w ' HTTP %{http_code}' | cut -c1-240)"
sleep 5
say "sms log rows (last 10 min): $(q <<<"select coalesce(string_agg(coalesce(status::text,'')||':'||coalesce(left(reason,80),''), ', '),'none') from (select * from app.auth_sms_log where created_at > now() - interval '10 minutes' order by created_at desc limit 5) x" 2>&1 | tail -1 | cut -c1-300)"
[ -n "$uid" ] && say "delete temp user: $(code_time -X DELETE "$API/auth/v1/admin/users/$uid" "${SH[@]}")"
flush auth2
