#!/usr/bin/env bash
# Supabase side of the deploy (run by the ci workflow's deploy job; also runnable by hand with the same
# variables). Every part is idempotent and safe to run again.
#
#   scripts/deploy/supabase.sh secrets   fetch the project's keys and the deploy_* vault secrets, mask them,
#                                        export them to the next steps (GITHUB_ENV)
#   scripts/deploy/supabase.sh migrate   apply only the migrations not yet applied, through the Management API
#   scripts/deploy/supabase.sh auth      redirect URLs and the invitation email link (Supabase Auth)
#   scripts/deploy/supabase.sh outbox    deploy the send-outbox Edge Function and schedule it every minute
#   scripts/deploy/supabase.sh stripe    the Stripe webhook endpoint (test or live, by the secret key) and its
#                                        signing secret in the vault (deploy_stripe_webhook_secret)
#
# Needs SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF; APP_URL (default https://carmacars.ca).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
APP_URL="${APP_URL:-https://carmacars.ca}"
REF="$SUPABASE_PROJECT_REF"

# Migrations 0001 to 0030 were applied to the live project through the Management API before this
# runner existed. On a project that already has the schema but an empty history, they are recorded
# as applied (never run again); everything after them runs once, in order.
BASELINE_MAX="0030"

secrets() {
  local keys anon service
  keys=$(sbapi GET "/api-keys?reveal=true")
  anon=$(jq -r '[.[] | select(.name == "anon")][0].api_key // empty' <<<"$keys")
  service=$(jq -r '[.[] | select(.name == "service_role")][0].api_key // empty' <<<"$keys")
  [ -n "$anon" ] && [ -n "$service" ] || die "The project's anon or service_role key was not returned"
  mask "$anon"; mask "$service"
  export_env NEXT_PUBLIC_SUPABASE_URL "https://$REF.supabase.co"
  export_env NEXT_PUBLIC_SUPABASE_ANON_KEY "$anon"
  export_env SUPABASE_SERVICE_ROLE_KEY "$service"
  local rows
  rows=$(sbq "select name, decrypted_secret as v from vault.decrypted_secrets where name like 'deploy\_%'")
  local pair name var val
  for pair in stripe_secret_key:STRIPE_SECRET_KEY stripe_publishable_key:NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY \
              resend_api_key:RESEND_API_KEY link_signing_key:LINK_SIGNING_KEY payout_encryption_key:PAYOUT_ENCRYPTION_KEY \
              stripe_webhook_secret:STRIPE_WEBHOOK_SECRET; do
    name="deploy_${pair%%:*}"; var="${pair##*:}"
    val=$(jq -r --arg n "$name" '[.[] | select(.name == $n)][0].v // empty' <<<"$rows")
    if [ -z "$val" ]; then
      [ "$var" = STRIPE_WEBHOOK_SECRET ] && { log "no $name yet (the stripe step creates it)"; continue; }
      die "Vault secret $name is missing"
    fi
    mask "$val"
    export_env "$var" "$val"
  done
  # session pooler (IPv4) for the seed script
  local pool host user
  pool=$(sbapi GET "/config/database/pooler")
  host=$(jq -r '[.[] | select(.database_type == "PRIMARY")][0].db_host' <<<"$pool")
  user=$(jq -r '[.[] | select(.database_type == "PRIMARY")][0].db_user' <<<"$pool")
  if [ -n "${SUPABASE_DB_PASSWORD:-}" ]; then
    local enc
    enc=$(jq -rn --arg p "$SUPABASE_DB_PASSWORD" '$p|@uri')
    mask "$enc"
    export_env DATABASE_URL "postgresql://$user:$enc@$host:5432/postgres"
  fi
  log "secrets: Supabase keys, vault secrets and the pooler address are exported"
}

migrate() {
  sbq "create schema if not exists supabase_migrations;
       create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);" > /dev/null
  local n has_schema
  n=$(sbq "select count(*)::int as n from supabase_migrations.schema_migrations" | jq -r '.[0].n')
  has_schema=$(sbq "select to_regclass('public.notification_catalogue') is not null as x" | jq -r '.[0].x')
  if [ "$n" = "0" ] && [ "$has_schema" = "true" ]; then
    local values="" f v
    for f in "$ROOT"/supabase/migrations/*.sql; do
      v=$(basename "$f"); v="${v%%_*}"
      [[ "$v" > "$BASELINE_MAX" ]] && continue
      values+="${values:+,}('$v', '$(basename "$f" .sql)')"
    done
    sbq "insert into supabase_migrations.schema_migrations (version, name) values $values on conflict do nothing" > /dev/null
    notice "Migrations: recorded 0001 to $BASELINE_MAX as already applied (baseline); they were not run again"
  fi
  local applied f v name count=0
  applied=$(sbq "select version from supabase_migrations.schema_migrations" | jq -r '.[].version')
  for f in "$ROOT"/supabase/migrations/*.sql; do
    name=$(basename "$f" .sql); v="${name%%_*}"
    grep -qx "$v" <<<"$applied" && continue
    log "applying $name"
    # The file and its history row in one call: one implicit transaction, so a failure leaves nothing behind.
    if ! sbq "$(cat "$f")
;
insert into supabase_migrations.schema_migrations (version, name) values ('$v', '$name');" > /dev/null; then
      die "Migration $name failed and was rolled back; later migrations were not run"
    fi
    count=$((count + 1))
  done
  notice "Migrations: $count new migration(s) applied; history has $(sbq "select count(*)::int as n from supabase_migrations.schema_migrations" | jq -r '.[0].n') rows"
}

auth() {
  local cfg list want u patch
  cfg=$(sbapi GET "/config/auth")
  list=$(jq -r '.uri_allow_list // ""' <<<"$cfg")
  want="$list"
  for u in "$APP_URL/auth/callback" "${APP_URL/https:\/\//https://www.}/auth/callback" "$APP_URL/update-password" "${APP_URL/https:\/\//https://www.}/update-password"; do
    tr ',' '\n' <<<"$want" | grep -qxF "$u" || want="${want:+$want,}$u"
  done
  patch=$(jq -n --arg l "$want" '{uri_allow_list: $l}')
  # Invitations are created on the server (no PKCE verifier), so the email links to the callback with a token hash.
  if ! jq -r '.mailer_templates_invite_content // ""' <<<"$cfg" | grep -q 'token_hash'; then
    patch=$(jq --arg c '<h2>You are invited to CarmaCars</h2>
<p>An account has been created for you at CarmaCars. Follow the link below to choose your password and sign in.</p>
<p><a href="{{ .SiteURL }}/auth/callback?token_hash={{ .TokenHash }}&type=invite&next=/update-password">Choose your password</a></p>
<p>The link works once. If it has expired, use "Forgot password" on the sign-in page.</p>' \
      '. + {mailer_templates_invite_content: $c, mailer_subjects_invite: "Your CarmaCars account"}' <<<"$patch")
  fi
  if [ "$want" != "$list" ] || jq -e 'has("mailer_templates_invite_content")' <<<"$patch" > /dev/null; then
    sbapi PATCH "/config/auth" "$patch" > /dev/null
    notice "Auth: redirect allow list and invitation link updated"
  else
    log "auth: already configured"
  fi
}

outbox() {
  local token dir
  token=$(vault_get outbox_job_token)
  if [ -z "$token" ]; then
    token=$(openssl rand -hex 32)
    vault_set outbox_job_token "$token" "Bearer token pg_cron sends to the send-outbox Edge Function"
  fi
  mask "$token"
  : "${RESEND_API_KEY:=$(vault_get deploy_resend_api_key)}"
  mask "$RESEND_API_KEY"
  sbapi POST "/secrets" "$(jq -n --arg t "$token" --arg r "$RESEND_API_KEY" --arg u "$APP_URL" \
    '[{name: "OUTBOX_JOB_TOKEN", value: $t}, {name: "RESEND_API_KEY", value: $r}, {name: "APP_URL", value: $u}]')" > /dev/null
  dir=$(mktemp -d)
  cp "$ROOT/supabase/functions/send-outbox/index.ts" "$dir/index.ts"
  cp "$ROOT/emails/src/engine.mjs" "$dir/engine.mjs"
  local out code
  out=$(mktemp)
  code=$(cd "$dir" && curl -sS -o "$out" -w '%{http_code}' -X POST "$SB_API/functions/deploy?slug=send-outbox" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -F 'metadata={"entrypoint_path":"index.ts","name":"send-outbox","verify_jwt":false};type=application/json' \
    -F 'file=@index.ts;type=application/typescript' -F 'file=@engine.mjs;type=application/javascript')
  [ "${code:0:1}" = "2" ] || die "send-outbox deploy failed ($code): $(head -c 800 "$out")"
  log "send-outbox deployed: $(jq -c '{slug, version, status}' "$out")"
  rm -rf "$dir" "$out"
  sbq "select cron.schedule('carmacars-send-outbox', '* * * * *', \$c\$
         select net.http_post(
           url := 'https://$REF.supabase.co/functions/v1/send-outbox',
           headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization',
                        'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'outbox_job_token')),
           body := '{}'::jsonb, timeout_milliseconds := 30000)
       \$c\$)" > /dev/null
  # the function answers 403 without the token
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://$REF.supabase.co/functions/v1/send-outbox")
  [ "$code" = "403" ] || warn "send-outbox without a token answered $code (expected 403)"
  code=$(curl -sS -o "$dir.json" -w '%{http_code}' -X POST "https://$REF.supabase.co/functions/v1/send-outbox" -H "Authorization: Bearer $token")
  [ "$code" = "200" ] && notice "Outbox sender: Edge Function send-outbox answers ($(cat "$dir.json")), pg_cron job carmacars-send-outbox every minute" \
    || warn "send-outbox with the token answered $code: $(head -c 300 "$dir.json")"
  rm -f "$dir.json"
}

stripe() {
  : "${STRIPE_SECRET_KEY:=$(vault_get deploy_stripe_secret_key)}"
  mask "$STRIPE_SECRET_KEY"
  local url="$APP_URL/api/webhooks/stripe" list id secret
  local events=(payment_intent.amount_capturable_updated payment_intent.succeeded payment_intent.payment_failed)
  list=$(curl -sS -G https://api.stripe.com/v1/webhook_endpoints -u "$STRIPE_SECRET_KEY:" -d limit=100)
  id=$(jq -r --arg u "$url" '[.data[]? | select(.url == $u)][0].id // empty' <<<"$list")
  secret=$(vault_get deploy_stripe_webhook_secret)
  local ev=() e
  for e in "${events[@]}"; do ev+=(-d "enabled_events[]=$e"); done
  if [ -n "$id" ] && [ -n "$secret" ]; then
    curl -sS -f https://api.stripe.com/v1/webhook_endpoints/"$id" -u "$STRIPE_SECRET_KEY:" "${ev[@]}" -d disabled=false > /dev/null
    log "stripe: webhook endpoint $id kept (events refreshed)"
  else
    if [ -n "$id" ]; then
      curl -sS -f -X DELETE https://api.stripe.com/v1/webhook_endpoints/"$id" -u "$STRIPE_SECRET_KEY:" > /dev/null
      log "stripe: endpoint $id had no stored signing secret; replaced"
    fi
    local created
    created=$(curl -sS https://api.stripe.com/v1/webhook_endpoints -u "$STRIPE_SECRET_KEY:" -d url="$url" "${ev[@]}" \
      -d description="CarmaCars site (created by the CI deploy job)")
    id=$(jq -r '.id // empty' <<<"$created"); secret=$(jq -r '.secret // empty' <<<"$created")
    [ -n "$id" ] && [ -n "$secret" ] || die "Stripe did not create the webhook endpoint: $(jq -c '.error.message // .' <<<"$created")"
    mask "$secret"
    vault_set deploy_stripe_webhook_secret "$secret" "Stripe webhook signing secret for $url"
    notice "Stripe: webhook endpoint $id created for $url ($(jq -r '.livemode' <<<"$created" | sed 's/false/test mode/;s/true/live mode/'))"
  fi
  mask "$secret"
  export_env STRIPE_WEBHOOK_SECRET "$secret"
}

for step in "$@"; do "$step"; done
