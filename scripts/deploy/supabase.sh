#!/usr/bin/env bash
# Supabase side of the deploy (run by the ci workflow's deploy job; also runnable by hand with the same
# variables). Every part is idempotent and safe to run again.
#
#   scripts/deploy/supabase.sh secrets   fetch the project's keys and the deploy_* vault secrets, mask them,
#                                        export them to the next steps (GITHUB_ENV)
#   scripts/deploy/supabase.sh migrate   apply only the migrations not yet applied, through the Management API
#   scripts/deploy/supabase.sh templates load the email templates into the catalogue (the sender renders them)
#   scripts/deploy/supabase.sh auth      redirect URLs and the invitation email link (Supabase Auth)
#   scripts/deploy/supabase.sh outbox    deploy the send-outbox Edge Function and schedule it every minute
#   scripts/deploy/supabase.sh storage   the file buckets in Supabase Storage (used when the Cloudflare account
#                                        has no R2: STORAGE_PROVIDER=supabase); vehicle-public is public
#   scripts/deploy/supabase.sh photos    the stand-in photos into vehicle-public (once; a marker object records it)
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
  # optional: the Google Maps server key (Places API (New) and Routes); without it the site uses the fake adapter
  val=$(jq -r '[.[] | select(.name == "deploy_google_maps_api_key")][0].v // empty' <<<"$rows")
  if [ -n "$val" ]; then
    mask "$val"; export_env GOOGLE_MAPS_API_KEY "$val"; export_env MAPS_PROVIDER google
    notice "Maps: Google (deploy_google_maps_api_key is in the vault)"
  else
    export_env MAPS_PROVIDER fake
    notice "Maps: the fake adapter (add deploy_google_maps_api_key to the vault for Google Places and Routes)"
  fi
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
    local tmp; tmp=$(mktemp)
    { cat "$f"; printf '\n;\ninsert into supabase_migrations.schema_migrations (version, name) values (%s, %s);\n' "'$v'" "'$name'"; } > "$tmp"
    if ! sbq_file "$tmp" > /dev/null; then
      rm -f "$tmp"
      die "Migration $name failed and was rolled back; later migrations were not run"
    fi
    rm -f "$tmp"
    count=$((count + 1))
  done
  notice "Migrations: $count new migration(s) applied; history has $(sbq "select count(*)::int as n from supabase_migrations.schema_migrations" | jq -r '.[0].n') rows"
}

# The email templates: migration 0018 stores only the file names; the sender renders the contents.
# Rebuilds emails/ and loads every template's HTML and text into notification_catalogue.
templates() {
  local tmp out; tmp=$(mktemp)
  (cd "$ROOT/emails" && node build.mjs > /dev/null)
  node "$ROOT/scripts/deploy/email-templates-sql.mjs" > "$tmp"
  out=$(sbq_file "$tmp") || { rm -f "$tmp"; die "Loading the email templates failed"; }
  rm -f "$tmp"
  [ "$(jq -r '.[0].still_paths' <<<"$out")" = "0" ] || die "Some email templates are still file names: $out"
  notice "Email templates: $(jq -r '.[0].total' <<<"$out") loaded"
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
  # Every Supabase Auth email links to /auth/callback with a token hash (scripts/deploy/auth-templates.mjs).
  local tpl; tpl=$(node "$ROOT/scripts/deploy/auth-templates.mjs")
  # any subject or template that differs from the file (all of them, not only the first three)
  if [ "$(jq -n --argjson c "$cfg" --argjson t "$tpl" '[$t | to_entries[] | select($c[.key] != .value)] | length')" != 0 ]; then
    patch=$(jq -s '.[0] + .[1]' <(echo "$patch") <(echo "$tpl"))
  fi
  if [ "$want" != "$list" ] || jq -e 'has("mailer_templates_confirmation_content")' <<<"$patch" > /dev/null; then
    sbapi PATCH "/config/auth" "$patch" > /dev/null
    notice "Auth: redirect allow list and email templates updated"
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
  : "${LINK_SIGNING_KEY:=$(vault_get deploy_link_signing_key)}"
  mask "$LINK_SIGNING_KEY"
  # LINK_SIGNING_KEY: the 7-day file links in emails are signed here and opened by the site (/d/<token>)
  sbapi POST "/secrets" "$(jq -n --arg t "$token" --arg r "$RESEND_API_KEY" --arg u "$APP_URL" --arg l "$LINK_SIGNING_KEY" \
    '[{name: "OUTBOX_JOB_TOKEN", value: $t}, {name: "RESEND_API_KEY", value: $r}, {name: "APP_URL", value: $u}, {name: "LINK_SIGNING_KEY", value: $l}]')" > /dev/null
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

service_key() {
  if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
    SUPABASE_SERVICE_ROLE_KEY=$(sbapi GET "/api-keys?reveal=true" | jq -r '[.[] | select(.name == "service_role")][0].api_key')
    mask "$SUPABASE_SERVICE_ROLE_KEY"
  fi
}

storage() {
  service_key
  local b pub code
  for b in vehicle-public vehicle-originals documents identity condition-photos agreements; do
    pub=false; [ "$b" = vehicle-public ] && pub=true
    code=$(curl -sS -o /dev/null -w '%{http_code}' "https://$REF.supabase.co/storage/v1/bucket/$b" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" -H "apikey: $SUPABASE_SERVICE_ROLE_KEY")
    if [ "$code" = 200 ]; then log "storage: bucket $b exists"; continue; fi
    code=$(curl -sS -o /tmp/sb-bucket.json -w '%{http_code}' -X POST "https://$REF.supabase.co/storage/v1/bucket" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H 'content-type: application/json' \
      --data "$(jq -n --arg b "$b" --argjson p "$pub" '{id: $b, name: $b, public: $p, file_size_limit: 15728640}')")
    [ "${code:0:1}" = 2 ] || die "Could not create the storage bucket $b ($code): $(head -c 300 /tmp/sb-bucket.json)"
    notice "Storage: bucket $b created (public: $pub)"
  done
}

# The listing pipeline's studio backdrop and shadow (web/src/features/listing/presets), under site/backdrop/.
presets() {
  service_key
  local base="https://$REF.supabase.co/storage/v1/object" f
  for f in brand_background_v1.png shadow_v1.png; do
    curl -sS -f -o /dev/null -X POST "$base/vehicle-public/site/backdrop/$f" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
      -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H 'content-type: image/png' -H 'x-upsert: true' -H 'cache-control: max-age=31536000' \
      --data-binary "@$ROOT/web/src/features/listing/presets/$f" || die "Could not upload the listing preset $f"
  done
  log "photos: listing backdrop presets uploaded"
}

photos() {
  service_key
  presets
  local base="https://$REF.supabase.co/storage/v1/object" marker=".seeded/stand-in-photos-v1"
  if [ "$(curl -sS -o /dev/null -w '%{http_code}' "$base/public/vehicle-public/$marker")" = 200 ]; then
    log "photos: already uploaded"; return
  fi
  local list
  list=$(mktemp)
  node -e '
    const fs = require("fs"), path = require("path");
    const dir = path.join(process.argv[1], "prototype/assets/photos");
    const cars = Object.keys(JSON.parse(fs.readFileSync(path.join(process.argv[1], "prototype/assets/photos.json"), "utf8")).cars);
    for (const f of fs.readdirSync(dir)) console.log((cars.some((s) => f.startsWith(s + "-")) ? "vehicles/" : "site/") + f + "\t" + path.join(dir, f));
  ' "$ROOT" > "$list"
  export SUPABASE_SERVICE_ROLE_KEY base
  # shellcheck disable=SC2016
  tr '\t' '\n' < "$list" | xargs -n 2 -P 8 sh -c 'ct=image/jpeg; case "$0" in *.svg) ct=image/svg+xml;; *.webp) ct=image/webp;; *.png) ct=image/png;; esac
    code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$base/vehicle-public/$0" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
      -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "content-type: $ct" -H "x-upsert: true" -H "cache-control: max-age=31536000" --data-binary "@$1")
    case "$code" in 2*) ;; *) echo "upload failed ($code): $0" >&2; exit 255;; esac'
  date -u +%FT%TZ | curl -sS -f -o /dev/null -X POST "$base/vehicle-public/$marker" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H 'content-type: text/plain' -H 'x-upsert: true' --data-binary @-
  notice "Photos: $(wc -l < "$list") stand-in photos uploaded to Supabase Storage vehicle-public"
  rm -f "$list"
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
