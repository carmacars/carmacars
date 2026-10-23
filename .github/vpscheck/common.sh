# shellcheck shell=bash
# Temporary post-cutover check helpers (branch vpscheck). Never prints a secret, an email address or a phone number.
set -uo pipefail
cd "$GITHUB_WORKSPACE"
# shellcheck source=/dev/null
source scripts/deploy/vps.sh
set +eu
API=https://api.carmacars.ca
SITE=https://carmacars.ca
SINCE='2026-10-23 15:15:00+00'
SINCE_ISO='2026-10-23T15:15:00Z'
OUT="$RUNNER_TEMP/out.txt"; : > "$OUT"
RUN="${GITHUB_RUN_ID:-0}"

clean() { sed -E -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g' -e 's/\+?1?[0-9]{10}\b/<num>/g' -e 's/\(?[0-9]{3}\)?[ .-][0-9]{3}[ .-][0-9]{4}/<num>/g' -e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.?[A-Za-z0-9_-]*/<jwt>/g'; }
say() { printf '%s\n' "$*" | clean >> "$OUT"; echo "$*" | clean; }
sayf() { clean < "${1:-/dev/stdin}" | tee -a "$OUT"; }
# psql as supabase_admin inside the db container (SQL on stdin), unaligned rows with | between columns
q() { vps_ssh "sudo /opt/carmacars/bin/dc exec -T db psql -U supabase_admin -d postgres -X -At -F '|' -v ON_ERROR_STOP=1" 2>&1; }
flush() { # title: the collected lines as up to 6 notice annotations of ~6000 characters
  local t="$1" i=0 chunk
  [ -s "$OUT" ] || return 0
  split -C 6000 -d "$OUT" "$RUNNER_TEMP/part."
  for f in "$RUNNER_TEMP"/part.*; do
    i=$((i + 1)); [ $i -le 6 ] || break
    chunk=$(sed -e 's/%/%25/g' "$f" | awk 'BEGIN{ORS="%0A"} {print}')
    echo "::notice title=$t ($i)::$chunk"
  done
  rm -f "$RUNNER_TEMP"/part.*
}
keys() {
  ANON=$(vps_secret ANON_KEY); SERVICE=$(vps_secret SERVICE_ROLE_KEY); JWT_SECRET=$(vps_secret JWT_SECRET)
  export ANON SERVICE JWT_SECRET
}
vault() { # name: a vault value (masked)
  local v; v=$(q <<<"select decrypted_secret from vault.decrypted_secrets where name = '$1'" | head -1)
  [ -n "$v" ] && echo "::add-mask::$v" >&2; printf '%s' "$v"
}
code_time() { curl -sS -o /dev/null -w '%{http_code} %{time_total}s' --max-time 30 "$@" 2>/dev/null || echo "000"; }
