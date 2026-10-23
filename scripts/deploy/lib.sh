# shellcheck shell=bash
# Shared helpers for the deploy scripts (sourced). Needs SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF;
# the Cloudflare helpers need CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. Never echo a secret value.
#
# DB_BACKEND picks where the database, Auth, Storage and the Edge Functions are (infra/vps/CUTOVER.md):
#   supabase (default)  the hosted project, through the Management API (api.supabase.com) and <ref>.supabase.co
#   vps                 the company's own server (scripts/deploy/vps.sh): SQL through pg-meta and Postgres over an SSH
#                       tunnel, keys from the server's .env, functions copied into the edge-runtime volume, Auth
#                       settings rendered into the server's auth.env, restart = docker compose restart.
# The helpers below (sbq, sbq_file, vault_get, vault_set, sb_keys, sb_db_url, sb_auth_get, sb_auth_patch,
# sb_fn_secrets, sb_fn_deploy, sb_fn_url, sb_restart) work the same on both; sbapi is the hosted project only.
# SB_URL is the Supabase API base this runner can reach (<ref>.supabase.co, or the tunnel to the server's Kong);
# SB_PUBLIC_URL the address the site and browsers use.
set -euo pipefail

DB_BACKEND="${DB_BACKEND:-supabase}"
case "$DB_BACKEND" in supabase|vps) ;; *) echo "DB_BACKEND must be supabase or vps (got $DB_BACKEND)" >&2; exit 1 ;; esac
SB_API="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF:-}"
CF_API="https://api.cloudflare.com/client/v4"
if [ "$DB_BACKEND" = vps ]; then
  # shellcheck source=vps.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vps.sh"
  vps_tunnel
  SB_URL="http://127.0.0.1:$VPS_KONG_PORT"
  export SB_PUBLIC_URL="$VPS_API_URL"
  # for the node scripts (web/scripts/catalog/import.mjs, verify-live.mjs): pg-meta's /query instead of the Management API
  export SQL_API_URL="http://127.0.0.1:$VPS_META_PORT/query"
  [ -n "${GITHUB_ENV:-}" ] && echo "SQL_API_URL=$SQL_API_URL" >> "$GITHUB_ENV"
else
  : "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF is needed}"
  SB_URL="https://$SUPABASE_PROJECT_REF.supabase.co"
  export SB_PUBLIC_URL="$SB_URL"
fi

log() { echo "[deploy] $*"; }
# A GitHub annotation (visible in the run summary and through the API); plain text elsewhere.
notice() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=deploy::$*"; else echo "NOTICE: $*"; fi; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning title=deploy::$*"; else echo "WARNING: $*"; fi; }
die() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=deploy::$*"; else echo "ERROR: $*"; fi; exit 1; }
# (on stderr, which the runner reads for commands too: a mask inside $(...) must not end up in the captured value)
mask() { if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$1" ]; then echo "::add-mask::$1" >&2; fi; }
# Export to this shell and, in GitHub Actions, to the following steps.
export_env() {
  local k="$1" v="$2"
  export "$k=$v"
  if [ -n "${GITHUB_ENV:-}" ]; then
    local d="EOF_$(openssl rand -hex 8)"
    printf '%s<<%s\n%s\n%s\n' "$k" "$d" "$v" "$d" >> "$GITHUB_ENV"
  fi
}

# Run SQL through the Supabase Management API (one implicit transaction per call); prints the JSON rows.
sbq() {
  if [ "$DB_BACKEND" = vps ]; then vps_sql "$1"; return; fi
  local body out code
  body=$(jq -n --arg q "$1" '{query: $q}')
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X POST "$SB_API/database/query" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'content-type: application/json' --data-binary "$body")
  if [ "${code:0:1}" != "2" ]; then
    echo "SQL failed ($code): $(head -c 1500 "$out")" >&2
    rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}
# Same as sbq, with the SQL read from a file: arguments are capped at 128 KB by the kernel, and large
# migrations or the email templates (about 1.8 MB) exceed that.
sbq_file() {
  if [ "$DB_BACKEND" = vps ]; then vps_sql_file "$1"; return; fi
  local body out code
  body=$(mktemp)
  jq -Rs '{query: .}' < "$1" > "$body"
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X POST "$SB_API/database/query" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'content-type: application/json' --data-binary @"$body")
  rm -f "$body"
  if [ "${code:0:1}" != "2" ]; then
    echo "SQL failed ($code): $(head -c 1500 "$out")" >&2
    rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}
sbapi() { # method path [json]; the hosted project only (use the sb_* helpers for what both backends have)
  [ "$DB_BACKEND" = supabase ] || { echo "sbapi $1 $2: the Management API is the hosted project only (DB_BACKEND=$DB_BACKEND)" >&2; return 1; }
  local m="$1" p="$2" d="${3:-}" out code
  out=$(mktemp)
  if [ -n "$d" ]; then
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$m" "$SB_API$p" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'content-type: application/json' --data-binary "$d")
  else
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$m" "$SB_API$p" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN")
  fi
  if [ "${code:0:1}" != "2" ]; then echo "Supabase API $m $p failed ($code): $(head -c 800 "$out")" >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}
vault_get() { sbq "select decrypted_secret as v from vault.decrypted_secrets where name = '$1'" | jq -r '.[0].v // empty'; }
vault_set() { # name value description; dollar-quoted with a random tag, so any value is safe
  local t="v$(openssl rand -hex 6)"
  local n="\$$t\$$1\$$t\$" v="\$$t\$$2\$$t\$" d="\$$t\$$3\$$t\$"
  sbq "do \$m\$ declare s uuid; begin select id into s from vault.secrets where name = $n; if s is null then perform vault.create_secret($v, $n, $d); else perform vault.update_secret(s, $v); end if; end \$m\$;" > /dev/null
}

# ---------------------------------------------------------------- the same on both backends
# The anon and service_role keys: sets SB_ANON_KEY and SB_SERVICE_KEY (masked).
sb_keys() {
  [ -n "${SB_SERVICE_KEY:-}" ] && [ -n "${SB_ANON_KEY:-}" ] && return 0
  if [ "$DB_BACKEND" = vps ]; then
    SB_ANON_KEY=$(vps_secret ANON_KEY); SB_SERVICE_KEY=$(vps_secret SERVICE_ROLE_KEY)
  else
    local keys; keys=$(sbapi GET "/api-keys?reveal=true")
    SB_ANON_KEY=$(jq -r '[.[] | select(.name == "anon")][0].api_key // empty' <<<"$keys")
    SB_SERVICE_KEY=$(jq -r '[.[] | select(.name == "service_role")][0].api_key // empty' <<<"$keys")
  fi
  if [ -z "$SB_ANON_KEY" ] || [ -z "$SB_SERVICE_KEY" ]; then echo "The anon or service_role key was not returned ($DB_BACKEND)" >&2; return 1; fi
  mask "$SB_ANON_KEY"; mask "$SB_SERVICE_KEY"
}
# The service_role key on stdout (for $(...)); masked.
sb_service_key() { sb_keys; printf '%s' "$SB_SERVICE_KEY"; }
# The legacy HS256 JWT secret (empty when none); masked.
sb_jwt_secret() {
  local j
  if [ "$DB_BACKEND" = vps ]; then j=$(vps_secret JWT_SECRET); else j=$(sbapi GET "/postgrest" | jq -r '.jwt_secret // empty'); fi
  mask "$j"; printf '%s' "$j"
}
# A Postgres URL this runner can use (session pooler on the hosted project, needs SUPABASE_DB_PASSWORD; the SSH tunnel
# as postgres on the server). Empty when it cannot be made. Masked.
sb_db_url() {
  local url="" enc=""
  if [ "$DB_BACKEND" = vps ]; then
    enc=$(jq -rn --arg p "$(vps_secret POSTGRES_PASSWORD)" '$p|@uri')
    url="postgresql://postgres:$enc@127.0.0.1:$VPS_PG_PORT/postgres"
  elif [ -n "${SUPABASE_DB_PASSWORD:-}" ]; then
    local pool host user
    pool=$(sbapi GET "/config/database/pooler") || return 0
    host=$(jq -r '[.[]? | select(.database_type == "PRIMARY")][0].db_host // empty' <<<"$pool")
    user=$(jq -r '[.[]? | select(.database_type == "PRIMARY")][0].db_user // empty' <<<"$pool")
    enc=$(jq -rn --arg p "$SUPABASE_DB_PASSWORD" '$p|@uri')
    if [ -n "$host" ] && [ -n "$user" ]; then url="postgresql://$user:$enc@$host:5432/postgres"; fi
  fi
  if [ -n "$url" ]; then mask "$enc"; mask "$url"; fi
  printf '%s' "$url"
}
# Supabase Auth's settings as the Management API's config/auth shape. On the server they are kept in
# /opt/carmacars/supabase/auth-config.json (copied from the hosted project by vps-copy) and rendered into auth.env.
sb_auth_get() {
  if [ "$DB_BACKEND" = vps ]; then vps_ssh sudo "$VPS_DIR/bin/auth-config" get; else sbapi GET "/config/auth"; fi
}
# Change some of them (a JSON object of config/auth fields).
sb_auth_patch() {
  if [ "$DB_BACKEND" = vps ]; then
    local cfg tpl
    cfg=$(jq -s '.[0] + .[1]' <(sb_auth_get) <(printf '%s' "$1"))
    tpl=$(mktemp -d)
    node "$(dirname "${BASH_SOURCE[0]}")/../../infra/vps/scripts/auth-env.mjs" --out "$tpl" <<<"$cfg" > /dev/null
    printf '%s' "$cfg" > "$tpl/auth-config.json"
    tar -C "$tpl" -cf - . | vps_ssh sudo "$VPS_DIR/bin/auth-config" apply
    rm -rf "$tpl"
  else
    sbapi PATCH "/config/auth" "$1"
  fi
}
# Edge Function secrets: a JSON array [{name, value}] (added or replaced; others kept).
sb_fn_secrets() {
  if [ "$DB_BACKEND" = vps ]; then printf '%s' "$1" | vps_ssh sudo "$VPS_DIR/bin/fn-secrets" > /dev/null
  else sbapi POST "/secrets" "$1" > /dev/null; fi
}
# Deploy one Edge Function from a directory whose entry point is index.ts (verify_jwt off, as every function here).
sb_fn_deploy() { # slug dir
  local slug="$1" dir="$2"
  if [ "$DB_BACKEND" = vps ]; then
    tar -C "$dir" -cf - . | vps_ssh sudo "$VPS_DIR/bin/fn-deploy" "$slug"
    return
  fi
  local out code files=() f
  for f in "$dir"/*; do
    case "$f" in *.ts) files+=(-F "file=@$(basename "$f");type=application/typescript") ;; *) files+=(-F "file=@$(basename "$f");type=application/javascript") ;; esac
  done
  out=$(mktemp)
  code=$(cd "$dir" && curl -sS -o "$out" -w '%{http_code}' -X POST "$SB_API/functions/deploy?slug=$slug" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -F "metadata={\"entrypoint_path\":\"index.ts\",\"name\":\"$slug\",\"verify_jwt\":false};type=application/json" "${files[@]}")
  [ "${code:0:1}" = "2" ] || { echo "$slug deploy failed ($code): $(head -c 800 "$out")" >&2; rm -f "$out"; return 1; }
  jq -c '{slug, version, status}' "$out"; rm -f "$out"
}
# The address pg_cron (pg_net) calls a function at: the public URL on the hosted project; on the server the Docker
# network (Kong), so the calls never leave the machine.
sb_fn_url() { if [ "$DB_BACKEND" = vps ]; then echo "http://kong:8000/functions/v1/$1"; else echo "$SB_URL/functions/v1/$1"; fi; }
# The address this runner tests a function at.
sb_fn_test_url() { echo "$SB_URL/functions/v1/$1"; }
# Restart a part (vps: docker compose restart <service>; hosted: the project's restart, which takes minutes).
sb_restart() {
  if [ "$DB_BACKEND" = vps ]; then vps_ssh sudo "$VPS_DIR/bin/dc" restart "$@"; else sbapi POST "/restart" '{}' > /dev/null; fi
}

# Cloudflare API: prints the JSON; returns 1 when success is false.
cfapi() { # method path [json]
  local m="$1" p="$2" d="${3:-}" out
  out=$(mktemp)
  if [ -n "$d" ]; then
    curl -sS -o "$out" -X "$m" "$CF_API$p" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'content-type: application/json' --data-binary "$d" || true
  else
    curl -sS -o "$out" -X "$m" "$CF_API$p" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" || true
  fi
  if [ "$(jq -r '.success // false' "$out" 2>/dev/null)" != "true" ]; then
    echo "Cloudflare API $m $p failed: $(jq -c '.errors // .' "$out" 2>/dev/null | head -c 800)" >&2
    cat "$out"; rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}
