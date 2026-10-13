# Shared helpers for the deploy scripts (sourced). Needs SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF;
# the Cloudflare helpers need CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. Never echo a secret value.
set -euo pipefail

SB_API="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF:?}"
CF_API="https://api.cloudflare.com/client/v4"

log() { echo "[deploy] $*"; }
# A GitHub annotation (visible in the run summary and through the API); plain text elsewhere.
notice() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=deploy::$*"; else echo "NOTICE: $*"; fi; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning title=deploy::$*"; else echo "WARNING: $*"; fi; }
die() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=deploy::$*"; else echo "ERROR: $*"; fi; exit 1; }
mask() { if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$1" ]; then echo "::add-mask::$1"; fi; }
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
sbapi() { # method path [json]
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
