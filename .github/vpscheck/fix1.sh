#!/usr/bin/env bash
# Fixes: GoTrue SMTP password (535 at Resend), stored files missing on disk (copied again from the frozen hosted project).
source .github/vpscheck/common.sh
keys
say "== SMTP password"
RK=$(vault deploy_resend_api_key)
cur=$(vps_ssh "sudo grep -E '^GOTRUE_SMTP_PASS=' /opt/carmacars/supabase/auth.env | cut -d= -f2- | tr -d \"'\" | cut -c1-3")
say "vault key: ${RK:+present} prefix-ok=$([[ "$RK" == re_* ]] && echo yes || echo no) resend /domains: $(curl -sS -o /dev/null -w '%{http_code}' https://api.resend.com/domains -H "Authorization: Bearer $RK"); auth.env pass prefix-ok=$([ "$cur" = re_ ] && echo yes || echo no)"
if [[ "$RK" == re_* ]] && [ "$cur" != re_ ]; then
  ( source scripts/deploy/lib.sh; sb_auth_patch "$(jq -n --arg k "$RK" '{smtp_pass: $k}')" ) 2>&1 | tail -2 | sayf
  sleep 5
  cur=$(vps_ssh "sudo docker exec supabase-auth printenv GOTRUE_SMTP_PASS | cut -c1-3")
  say "after: auth container pass prefix-ok=$([ "$cur" = re_ ] && echo yes || echo no); auth health $(code_time "$API/auth/v1/health" -H "apikey: $ANON")"
fi
say "== password reset email end to end (throwaway rent+vpscheck account)"
SH=(-H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H 'content-type: application/json')
E="rent+vpscheck-$RUN@carmacars.ca"
uid=$(curl -sS -X POST "$API/auth/v1/admin/users" "${SH[@]}" -d "{\"email\":\"$E\",\"password\":\"Vc!$(openssl rand -hex 10)aA9\",\"email_confirm\":true}" | jq -r '.id // empty')
say "recover: $(curl -sS -X POST "$API/auth/v1/recover?redirect_to=https%3A%2F%2Fcarmacars.ca%2Fauth%2Fcallback" -H "apikey: $ANON" -H 'content-type: application/json' -d "{\"email\":\"$E\"}" -w ' HTTP %{http_code}' | cut -c1-200)"
sleep 25
curl -sS "https://api.resend.com/emails?limit=30" -H "Authorization: Bearer $RK" > "$RUNNER_TEMP/re.json"
say "resend (emails to the test address): $(jq -r --arg r "vpscheck-$RUN" '[.data[]? | select((.to|tostring)|contains($r)) | "\(.last_event) subject=\(.subject)"] | join("; ")' "$RUNNER_TEMP/re.json") $(jq -r '.message // empty' "$RUNNER_TEMP/re.json")"
[ -n "$uid" ] && say "delete test account: $(code_time -X DELETE "$API/auth/v1/admin/users/$uid" "${SH[@]}")"

say "== stored files whose row has no file on disk"
vps_ssh "sudo bash -s" > "$RUNNER_TEMP/missing.txt" 2>&1 <<'EOS'
base=/opt/carmacars/supabase/volumes/storage/stub/stub
docker exec supabase-db psql -U supabase_admin -d postgres -X -At -F '|' -c "select bucket_id, name, coalesce(version,'') from storage.objects where name not like '%.emptyFolderPlaceholder'" |
while IFS='|' read -r b n v; do if [ -n "$v" ]; then [ -e "$base/$b/$n/$v" ] || echo "$b|$n"; else [ -e "$base/$b/$n" ] || echo "$b|$n"; fi; done
EOS
say "missing by bucket: $(cut -d'|' -f1 "$RUNNER_TEMP/missing.txt" | sort | uniq -c | paste -sd' ')"
say "sample: $(grep -v '^backups|' "$RUNNER_TEMP/missing.txt" | head -5 | cut -c1-80 | paste -sd' ')"
HK=$(DB_BACKEND=supabase SUPABASE_ACCESS_TOKEN=$SUPABASE_ACCESS_TOKEN scripts/deploy/sb.sh service-key 2>/dev/null)
HOSTED="https://$SUPABASE_PROJECT_REF.supabase.co/storage/v1"
ok=0; fail=0
while IFS='|' read -r b n; do
  [ "$b" = backups ] && continue
  e=$(jq -rn --arg p "$n" '$p|split("/")|map(@uri)|join("/")')
  ct=$(curl -sS -o "$RUNNER_TEMP/f.bin" -w '%{http_code} %{content_type}' --max-time 60 "$HOSTED/object/authenticated/$b/$e" -H "apikey: $HK" -H "Authorization: Bearer $HK")
  if [ "${ct%% *}" = 200 ]; then
    r=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$API/storage/v1/object/$b/$e" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "content-type: ${ct#* }" -H 'x-upsert: true' -H 'cache-control: max-age=3600' --data-binary @"$RUNNER_TEMP/f.bin")
    [ "$r" = 200 ] && ok=$((ok+1)) || { fail=$((fail+1)); say "upload $b/${n:0:60}: $r"; }
  else fail=$((fail+1)); say "hosted $b/${n:0:60}: ${ct%% *}"; fi
done < <(grep '|' "$RUNNER_TEMP/missing.txt")
say "copied from hosted: $ok; failed: $fail"
flush fix1
