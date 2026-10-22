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
#   scripts/deploy/supabase.sh debit     deploy the owner-debit Edge Function (the automatic monthly owner debit) and
#                                        schedule it hourly
#   scripts/deploy/supabase.sh calsync   deploy the calendar-sync Edge Function (Turo and other calendar links) and
#                                        schedule it every 5 minutes
#   scripts/deploy/supabase.sh storage   the file buckets in Supabase Storage (used when the Cloudflare account
#                                        has no R2: STORAGE_PROVIDER=supabase); vehicle-public is public
#   scripts/deploy/supabase.sh photos    the stand-in photos into vehicle-public (once; a marker object records it)
#   scripts/deploy/supabase.sh stripe    the Stripe webhook endpoint (test or live, by the secret key) and its
#                                        signing secret in the vault (deploy_stripe_webhook_secret)
#   scripts/deploy/supabase.sh quo       the Quo phone line (0085): the key (repository secret QUO_API_KEY, kept in the
#                                        vault as deploy_quo_api_key), our webhook for the CarmaCars number (Site settings,
#                                        phone) and its signing secret in the vault (deploy_quo_webhook_secret); exports
#                                        QUO_API_KEY and QUO_WEBHOOK_SECRET for the Worker. Never another Quo account.
#   scripts/deploy/supabase.sh smshook   sign-in by phone (0091): the Send SMS hook's signing secret in the vault
#                                        (deploy_auth_sms_hook_secret, made once) exported as AUTH_SMS_HOOK_SECRET for the
#                                        Worker. Changes nothing in Supabase Auth.
#   scripts/deploy/supabase.sh phoneauth sign-in by phone (0091), production only, after the Worker is deployed: the phone
#                                        provider with 6-digit codes valid 5 minutes, the SMS text, and the Send SMS hook
#                                        to $APP_URL/api/webhooks/auth-sms with that secret (Management API, config/auth).
#                                        Only the settings that differ are sent.
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
  # the project's JWT secret (the legacy HS256 key the database API still accepts): Admin "view as" reads a renter's or
  # owner's portal with a 5-minute token for that person, made on the server (web/src/server/view-as.ts)
  local jwt
  jwt=$(sbapi GET "/postgrest" | jq -r '.jwt_secret // empty')
  if [ -n "$jwt" ]; then mask "$jwt"; export_env SUPABASE_JWT_SECRET "$jwt"
  else notice "No JWT secret from the project: Admin view as cannot open the renter and owner portals"; fi
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

# The automatic monthly owner debit (docs/changes/2026-10-14-owner-debit.md): the owner-debit Edge Function, its
# secrets (a job token in the vault, the Stripe key) and the hourly pg_cron call. The function decides itself whether
# anything is due (the debit day and hour are Program settings), so an hourly call is safe.
debit() {
  local token dir out code
  token=$(vault_get debit_job_token)
  if [ -z "$token" ]; then
    token=$(openssl rand -hex 32)
    vault_set debit_job_token "$token" "Bearer token pg_cron sends to the owner-debit Edge Function"
  fi
  mask "$token"
  : "${STRIPE_SECRET_KEY:=$(vault_get deploy_stripe_secret_key)}"
  mask "$STRIPE_SECRET_KEY"
  sbapi POST "/secrets" "$(jq -n --arg t "$token" --arg s "$STRIPE_SECRET_KEY" '[{name: "DEBIT_JOB_TOKEN", value: $t}, {name: "STRIPE_SECRET_KEY", value: $s}]')" > /dev/null
  dir=$(mktemp -d)
  cp "$ROOT/supabase/functions/owner-debit/index.ts" "$ROOT/supabase/functions/owner-debit/run.ts" "$dir/"
  out=$(mktemp)
  code=$(cd "$dir" && curl -sS -o "$out" -w '%{http_code}' -X POST "$SB_API/functions/deploy?slug=owner-debit" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -F 'metadata={"entrypoint_path":"index.ts","name":"owner-debit","verify_jwt":false};type=application/json' \
    -F 'file=@index.ts;type=application/typescript' -F 'file=@run.ts;type=application/typescript')
  [ "${code:0:1}" = "2" ] || die "owner-debit deploy failed ($code): $(head -c 800 "$out")"
  log "owner-debit deployed: $(jq -c '{slug, version, status}' "$out")"
  rm -rf "$dir" "$out"
  sbq "select cron.schedule('carmacars-owner-debit', '28 * * * *', \$c\$
         select net.http_post(
           url := 'https://$REF.supabase.co/functions/v1/owner-debit',
           headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization',
                        'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'debit_job_token')),
           body := '{}'::jsonb, timeout_milliseconds := 60000)
       \$c\$)" > /dev/null
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://$REF.supabase.co/functions/v1/owner-debit")
  [ "$code" = "403" ] || warn "owner-debit without a token answered $code (expected 403)"
  code=$(curl -sS -o "$dir.json" -w '%{http_code}' -X POST "https://$REF.supabase.co/functions/v1/owner-debit" -H "Authorization: Bearer $token")
  [ "$code" = "200" ] && notice "Owner debit: Edge Function owner-debit answers ($(head -c 300 "$dir.json")), pg_cron job carmacars-owner-debit hourly" \
    || warn "owner-debit with the token answered $code: $(head -c 300 "$dir.json")"
  rm -f "$dir.json"
}

# Calendar sync (docs/changes/2026-10-19-calendar-sync-recovery-uptime.md): the calendar-sync Edge Function with the
# site's own reader (web/src/features/calendar/ical.ts and sync-run.ts, copied beside index.ts), its job token in the
# vault, and the pg_cron call every 5 minutes. The database decides which calendar links are due
# (calendar_sync_minutes, 10 by default), so a call with nothing due costs one query.
calsync() {
  local token dir out code
  token=$(vault_get calsync_job_token)
  if [ -z "$token" ]; then
    token=$(openssl rand -hex 32)
    vault_set calsync_job_token "$token" "Bearer token pg_cron sends to the calendar-sync Edge Function"
  fi
  mask "$token"
  sbapi POST "/secrets" "$(jq -n --arg t "$token" '[{name: "CALSYNC_JOB_TOKEN", value: $t}]')" > /dev/null
  dir=$(mktemp -d)
  cp "$ROOT/supabase/functions/calendar-sync/index.ts" "$dir/index.ts"
  cp "$ROOT/web/src/features/calendar/ical.ts" "$dir/ical.ts"
  cp "$ROOT/web/src/features/calendar/sync-run.ts" "$dir/run.ts"
  out=$(mktemp)
  code=$(cd "$dir" && curl -sS -o "$out" -w '%{http_code}' -X POST "$SB_API/functions/deploy?slug=calendar-sync" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -F 'metadata={"entrypoint_path":"index.ts","name":"calendar-sync","verify_jwt":false};type=application/json' \
    -F 'file=@index.ts;type=application/typescript' -F 'file=@ical.ts;type=application/typescript' -F 'file=@run.ts;type=application/typescript')
  [ "${code:0:1}" = "2" ] || die "calendar-sync deploy failed ($code): $(head -c 800 "$out")"
  log "calendar-sync deployed: $(jq -c '{slug, version, status}' "$out")"
  rm -rf "$dir" "$out"
  sbq "select cron.schedule('carmacars-calendar-sync', '*/5 * * * *', \$c\$
         select net.http_post(
           url := 'https://$REF.supabase.co/functions/v1/calendar-sync',
           headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization',
                        'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'calsync_job_token')),
           body := '{}'::jsonb, timeout_milliseconds := 120000)
       \$c\$)" > /dev/null
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://$REF.supabase.co/functions/v1/calendar-sync")
  [ "$code" = "403" ] || warn "calendar-sync without a token answered $code (expected 403)"
  code=$(curl -sS -o "$dir.json" -w '%{http_code}' -X POST "https://$REF.supabase.co/functions/v1/calendar-sync" -H "Authorization: Bearer $token")
  [ "$code" = "200" ] && notice "Calendar sync: Edge Function calendar-sync answers ($(head -c 300 "$dir.json")), pg_cron job carmacars-calendar-sync every 5 minutes" \
    || warn "calendar-sync with the token answered $code: $(head -c 300 "$dir.json")"
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
  for f in brand_background_v1.png studio_v2.png shadow_v1.png; do
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
  # the PaymentIntent events of bookings and owner invoices, the debit settling days later (processing, canceled),
  # a pre-authorized debit agreement set up from Banking (setup_intent) and one cancelled at the bank (mandate.updated)
  local events=(payment_intent.amount_capturable_updated payment_intent.succeeded payment_intent.payment_failed
                payment_intent.processing payment_intent.canceled setup_intent.succeeded setup_intent.setup_failed mandate.updated)
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

quo() {
  # the key: the repository secret when set (then kept in the vault), otherwise the vault's copy
  if [ -n "${QUO_API_KEY:-}" ]; then
    mask "$QUO_API_KEY"
    [ "$(vault_get deploy_quo_api_key)" = "$QUO_API_KEY" ] || vault_set deploy_quo_api_key "$QUO_API_KEY" "Quo API key of the CarmaCars workspace (the phone line, 0085)"
  else
    QUO_API_KEY=$(vault_get deploy_quo_api_key)
  fi
  if [ -z "$QUO_API_KEY" ]; then
    notice "Phone line: no Quo key (repository secret QUO_API_KEY). Calls and texts are not recorded and no text is sent until it is set."
    return 0
  fi
  mask "$QUO_API_KEY"
  export_env QUO_API_KEY "$QUO_API_KEY"
  local number secret have out res
  number=$(sbq "select app.phone_our_number() as n" | jq -r '.[0].n // empty')
  [ -n "$number" ] || { warn "Phone line: Site settings has no phone number; the Quo webhook was not set up"; return 0; }
  secret=$(vault_get deploy_quo_webhook_secret)
  have=no; [ -n "$secret" ] && have=yes
  out=$(mktemp); chmod 600 "$out"
  if ! res=$(cd "$ROOT" && QUO_API_KEY="$QUO_API_KEY" node --experimental-strip-types --no-warnings scripts/deploy/quo.mjs setup \
        --url "$APP_URL/api/webhooks/quo" --number "$number" --have-key "$have" --out "$out" 2>&1); then
    rm -f "$out"
    warn "Phone line: the Quo webhook could not be set up: $res"
    [ -n "$secret" ] && { mask "$secret"; export_env QUO_WEBHOOK_SECRET "$secret"; }
    return 0
  fi
  if [ -s "$out" ]; then
    secret=$(cat "$out"); mask "$secret"
    vault_set deploy_quo_webhook_secret "$secret" "Signing secret of the Quo webhook $APP_URL/api/webhooks/quo"
  fi
  rm -f "$out"
  mask "$secret"
  export_env QUO_WEBHOOK_SECRET "$secret"
  local pn wid action
  pn=$(jq -r '.phone_number_id' <<<"$res"); wid=$(jq -r '.webhook_id' <<<"$res"); action=$(jq -r '.action' <<<"$res")
  sbq "update quo_config set phone_number_id = '$(tr -cd 'A-Za-z0-9' <<<"$pn")', webhook_id = '$(tr -cd 'A-Za-z0-9' <<<"$wid")', checked_at = now()" > /dev/null
  notice "Phone line: Quo inbox $(jq -r '.number_name // "?"' <<<"$res") ($pn) for $number; webhook $wid $action"
}

# ---------------------------------------------------------------- sign-in by phone (migration 0091)
# The Standard Webhooks secret Supabase signs each Send SMS hook call with ("v1,whsec_<base64 of 32 random bytes>").
smshook() {
  local secret
  secret=$(vault_get deploy_auth_sms_hook_secret)
  if [ -z "$secret" ]; then
    secret="v1,whsec_$(openssl rand -base64 32 | tr -d '\n')"
    vault_set deploy_auth_sms_hook_secret "$secret" "Signing secret of Supabase Auth's Send SMS hook ($APP_URL/api/webhooks/auth-sms)"
    notice "Sign-in by phone: a new Send SMS hook secret is in the vault (deploy_auth_sms_hook_secret)"
  fi
  mask "$secret"; mask "${secret#v1,}"
  export_env AUTH_SMS_HOOK_SECRET "$secret"
}

# The SMS text, as web/src/features/auth/sms-hook.ts SMS_TEMPLATE says it (the hook texts it; Supabase keeps it too).
SMS_TEMPLATE="CarmaCars code: {{ .Code }}. It expires in 5 minutes. Don't share it."
phoneauth() {
  if [ "${DEPLOY_ENV:-production}" != production ]; then log "phoneauth: production only (DEPLOY_ENV=$DEPLOY_ENV); nothing changed"; return 0; fi
  : "${AUTH_SMS_HOOK_SECRET:=$(vault_get deploy_auth_sms_hook_secret)}"
  [ -n "$AUTH_SMS_HOOK_SECRET" ] || die "No Send SMS hook secret (run the smshook step before the Worker deploy)"
  mask "$AUTH_SMS_HOOK_SECRET"; mask "${AUTH_SMS_HOOK_SECRET#v1,}"
  local uri="$APP_URL/api/webhooks/auth-sms" code cfg want diff
  # the hook must be live (and refuse an unsigned call) before Supabase is told to use it
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$uri" -H 'content-type: application/json' --data '{}' || true)
  if [ "$code" != 401 ]; then
    warn "Sign-in by phone: $uri answered $code to an unsigned call (expected 401); the phone provider was not switched on"
    return 0
  fi
  cfg=$(sbapi GET "/config/auth")
  want=$(jq -n --arg uri "$uri" --arg sec "$AUTH_SMS_HOOK_SECRET" --arg tpl "$SMS_TEMPLATE" '{
    external_phone_enabled: true, sms_autoconfirm: false, sms_otp_length: 6, sms_otp_exp: 300, sms_max_frequency: 60, sms_template: $tpl,
    hook_send_sms_enabled: true, hook_send_sms_uri: $uri, hook_send_sms_secrets: $sec }')
  # only what differs (a secret Supabase does not show back is sent again: the same value, so nothing changes)
  diff=$(jq -n --argjson c "$cfg" --argjson w "$want" '[$w | to_entries[] | select($c[.key] != .value)] | from_entries')
  if [ "$diff" = "{}" ]; then log "phoneauth: already configured"; return 0; fi
  sbapi PATCH "/config/auth" "$diff" > /dev/null
  cfg=$(sbapi GET "/config/auth")
  jq -e --arg uri "$uri" '.external_phone_enabled == true and .hook_send_sms_enabled == true and .hook_send_sms_uri == $uri and .sms_otp_length == 6 and .sms_otp_exp == 300' <<<"$cfg" > /dev/null \
    || die "Sign-in by phone: Supabase Auth did not keep the phone settings"
  notice "Sign-in by phone: phone provider on (6-digit codes, 5 minutes), Send SMS hook $uri; changed: $(jq -r 'keys - ["hook_send_sms_secrets"] | join(", ")' <<<"$diff")$(jq -r 'if has("hook_send_sms_secrets") then ", hook secret" else "" end' <<<"$diff")"
}

for step in "$@"; do "$step"; done
