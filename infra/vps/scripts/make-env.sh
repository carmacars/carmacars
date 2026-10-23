#!/usr/bin/env bash
# Writes the server's secret settings, /opt/carmacars/supabase/.env (mode 600, root), from the GitHub runner.
# Nothing secret is printed: values travel from the Management API (or the server's current .env) straight into the
# file over SSH; the run log shows names and where each came from.
#
#   the hosted project's    JWT_SECRET (GET /postgrest jwt_secret), ANON_KEY and SERVICE_ROLE_KEY
#                           (GET /api-keys?reveal=true): the Worker, the stored anon key in the browser bundle and
#                           Admin view-as tokens keep working unchanged
#   the hosted project's    PGRST_DB_SCHEMAS, PGRST_DB_MAX_ROWS, PGRST_DB_EXTRA_SEARCH_PATH (GET /postgrest)
#   the Postgres image      defaults.env's PG_IMAGE (the official self-hosted compose's tag; same major version as the
#                           hosted project, checked). PG_IMAGE_MATCH_HOSTED=1 takes the hosted project's exact tag
#                           instead (database.version): the platform's newer images (17.11.0.003 tried on Oct 23, 2026)
#                           did not initialise the self-hosted roles and schemas. Chosen once, then kept;
#                           PG_IMAGE_OVERRIDE replaces it (only with an empty data directory: reset_db)
#   made here once, kept    POSTGRES_PASSWORD, PG_META_CRYPTO_KEY, SECRET_KEY_BASE, VAULT_ENC_KEY, the ES256 key
#   derived                 JWT_KEYS, JWT_JWKS (jwt-keys.mjs; the hosted project's public keys unless TRUST_HOSTED_JWKS=0)
#
# Once the server is live (the cutover is done) the hosted project may be gone: the keys already in .env are kept
# and the Management API is not needed. Before that, the hosted values win (they must match).
# Needs VPS_SSH_KEY; SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF unless .env already has the keys.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../../scripts/deploy/vps.sh
. "$ROOT/scripts/deploy/vps.sh"
say() { echo "[make-env] $*"; }
mask() { if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$1" ]; then echo "::add-mask::$1" >&2; fi; }

W=$(mktemp -d); chmod 700 "$W"
trap 'rm -rf "$W"' EXIT
vps_ssh "sudo cat /opt/carmacars/supabase/.env 2>/dev/null || true" > "$W/old.env"
old() { local l; l=$(grep -m1 "^$1=" "$W/old.env" || true); l="${l#*=}"; l="${l#\'}"; l="${l%\'}"; printf '%s' "$l"; }
live=false; vps_is_live && live=true

declare -A V SRC
keep_or_make() { # name generator...
  local n="$1"; shift
  V[$n]=$(old "$n")
  if [ -n "${V[$n]}" ]; then SRC[$n]=kept; else V[$n]=$("$@"); SRC[$n]=new; fi
  mask "${V[$n]}"
}
keep_or_make POSTGRES_PASSWORD openssl rand -hex 32
keep_or_make PG_META_CRYPTO_KEY openssl rand -hex 32
keep_or_make SECRET_KEY_BASE openssl rand -hex 48
keep_or_make VAULT_ENC_KEY openssl rand -hex 16

# ---------------------------------------------------------------- the hosted project's values
hosted=false
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] && [ -n "${SUPABASE_PROJECT_REF:-}" ]; then
  API="https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF"
  H=(-H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN")
  if curl -sS -f -o "$W/keys.json" "${H[@]}" "$API/api-keys?reveal=true" && curl -sS -f -o "$W/pgrst.json" "${H[@]}" "$API/postgrest" \
     && curl -sS -f -o "$W/project.json" "${H[@]}" "$API"; then
    hosted=true
    curl -sS -f -o "$W/jwks.json" "https://$SUPABASE_PROJECT_REF.supabase.co/auth/v1/.well-known/jwks.json" || echo '{"keys":[]}' > "$W/jwks.json"
  else
    say "the Management API did not answer; using what the server has"
  fi
fi
for pair in ANON_KEY:anon SERVICE_ROLE_KEY:service_role; do
  n="${pair%%:*}"; k="${pair##*:}"
  h=""; $hosted && h=$(jq -r --arg k "$k" '[.[] | select(.name == $k)][0].api_key // empty' "$W/keys.json")
  o=$(old "$n")
  if $live && [ -n "$o" ]; then V[$n]="$o"; SRC[$n]=kept-live
  elif [ -n "$h" ]; then
    V[$n]="$h"; SRC[$n]=hosted
    if [ -n "$o" ] && [ "$o" != "$h" ]; then say "WARNING: $n on the server differed from the hosted project's; replaced"; fi
  elif [ -n "$o" ]; then V[$n]="$o"; SRC[$n]=kept
  else _vps_die "No $n: the hosted project did not return it and the server has none"; fi
  mask "${V[$n]}"
done
h=""; $hosted && h=$(jq -r '.jwt_secret // empty' "$W/pgrst.json")
o=$(old JWT_SECRET)
if $live && [ -n "$o" ]; then V[JWT_SECRET]="$o"; SRC[JWT_SECRET]=kept-live
elif [ -n "$h" ]; then V[JWT_SECRET]="$h"; SRC[JWT_SECRET]=hosted
elif [ -n "$o" ]; then V[JWT_SECRET]="$o"; SRC[JWT_SECRET]=kept
else _vps_die "No JWT secret: the hosted project did not return one (GET /postgrest jwt_secret) and the server has none"; fi
mask "${V[JWT_SECRET]}"

for pair in PGRST_DB_SCHEMAS:db_schema PGRST_DB_MAX_ROWS:max_rows PGRST_DB_EXTRA_SEARCH_PATH:db_extra_search_path; do
  n="${pair%%:*}"; k="${pair##*:}"
  h=""; $hosted && h=$(jq -r --arg k "$k" '.[$k] // empty | tostring' "$W/pgrst.json")
  o=$(old "$n")
  if [ -n "$h" ] && ! $live; then V[$n]="$h"; SRC[$n]=hosted; elif [ -n "$o" ]; then V[$n]="$o"; SRC[$n]=kept; fi
done

# ---------------------------------------------------------------- the Postgres image
o=$(old PG_IMAGE)
hv=""; $hosted && hv=$(jq -r '.database.version // empty' "$W/project.json")
if [ -n "$hv" ]; then say "hosted project: Postgres $hv"; fi
if [ -n "${PG_IMAGE_OVERRIDE:-}" ]; then
  V[PG_IMAGE]="$PG_IMAGE_OVERRIDE"; SRC[PG_IMAGE]=override
  if [ -n "$o" ] && [ "$o" != "$PG_IMAGE_OVERRIDE" ]; then say "WARNING: PG_IMAGE changes from $o to $PG_IMAGE_OVERRIDE (only a minor version step is safe on existing data)"; fi
elif [ -n "$o" ]; then V[PG_IMAGE]="$o"; SRC[PG_IMAGE]=kept
elif [ "${PG_IMAGE_MATCH_HOSTED:-0}" = 1 ] && [[ "$hv" =~ ^17\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$(curl -sS -o /dev/null -w '%{http_code}' "https://hub.docker.com/v2/namespaces/supabase/repositories/postgres/tags/$hv")" = 200 ]; then
  V[PG_IMAGE]="supabase/postgres:$hv"; SRC[PG_IMAGE]="hosted-version"
else
  if [ -n "$hv" ] && [[ ! "$hv" =~ ^17\. ]]; then _vps_die "The hosted project runs Postgres $hv; this stack, the backups and the copy expect 17"; fi
  SRC[PG_IMAGE]=defaults.env
fi

# ---------------------------------------------------------------- JWT keys
hjwks='{"keys":[]}'; $hosted && hjwks=$(cat "$W/jwks.json")
JWT_SECRET="${V[JWT_SECRET]}" JWT_KEYS="$(old JWT_KEYS)" HOSTED_JWKS="$hjwks" TRUST_HOSTED_JWKS="${TRUST_HOSTED_JWKS:-1}" \
  node "$HERE/jwt-keys.mjs" > "$W/jwt.txt"
V[JWT_KEYS]=$(sed -n 's/^JWT_KEYS=//p' "$W/jwt.txt"); V[JWT_JWKS]=$(sed -n 's/^JWT_JWKS=//p' "$W/jwt.txt")
mask "$(jq -r '.[0].d' <<<"${V[JWT_KEYS]}")"
SRC[JWT_KEYS]=derived; SRC[JWT_JWKS]=derived

# ---------------------------------------------------------------- write
{
  echo "# Written by infra/vps/scripts/make-env.sh ($(date -u +%FT%TZ)). Secret: root only, never in the repository."
  for n in POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY JWT_KEYS JWT_JWKS PG_META_CRYPTO_KEY SECRET_KEY_BASE VAULT_ENC_KEY \
           PG_IMAGE PGRST_DB_SCHEMAS PGRST_DB_MAX_ROWS PGRST_DB_EXTRA_SEARCH_PATH; do
    [ -n "${V[$n]:-}" ] || continue
    case "${V[$n]}" in *"'"*|*$'\n'*) _vps_die "$n holds a quote or a newline; refusing to write it" ;; esac
    printf "%s='%s'\n" "$n" "${V[$n]}"
  done
} > "$W/new.env"
vps_ssh "sudo sh -c 'umask 077; mkdir -p /opt/carmacars/supabase; cat > /opt/carmacars/supabase/.env.new && mv /opt/carmacars/supabase/.env.new /opt/carmacars/supabase/.env'" < "$W/new.env"
changed=no; cmp -s <(grep -v '^#' "$W/old.env") <(grep -v '^#' "$W/new.env") || changed=yes
summary=""
for n in "${!SRC[@]}"; do summary+="$n=${SRC[$n]} "; done
say "written (changed: $changed): $(tr ' ' '\n' <<<"$summary" | sort | tr '\n' ' ')"
say "Postgres image: ${V[PG_IMAGE]:-$(grep '^PG_IMAGE=' "$ROOT/infra/vps/supabase/defaults.env" | cut -d= -f2) (defaults.env)}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Server .env"; echo; echo "changed: $changed; live: $live; hosted project reachable: $hosted"; echo
    echo '| name | source |'; echo '|---|---|'
    for n in $(printf '%s\n' "${!SRC[@]}" | sort); do echo "| $n | ${SRC[$n]} |"; done; } >> "$GITHUB_STEP_SUMMARY"
fi
