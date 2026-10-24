# shellcheck shell=bash
# The company's own Supabase server (infra/vps/CUTOVER.md), reached from GitHub-hosted runners over SSH (sourced by
# lib.sh when DB_BACKEND=vps, and by the infra/vps scripts and vps-* workflows). Never echo a secret value.
#
# Needs VPS_SSH_KEY (the repository secret: an ed25519 private key for the ubuntu user). The address is the first
# non-comment line of infra/vps/host (committed; or VPS_HOST). The server's host keys are pinned by
# infra/vps/known_hosts when that file exists (commit the line vps-provision prints); until then the first contact
# trusts the key the server presents and says so.
#
# One SSH connection per job is shared (ControlMaster) and carries the tunnels:
#   127.0.0.1:$VPS_KONG_PORT (18000)  -> Kong on the server (the Supabase API, without DNS or TLS)
#   127.0.0.1:$VPS_META_PORT (18085)  -> pg-meta (SQL as JSON rows, like the Management API's database/query)
#   127.0.0.1:$VPS_PG_PORT   (15432)  -> Postgres (pg_dump, psql, the seed script and imports)
set -euo pipefail

_VPS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_ROOT="$(cd "$_VPS_HERE/../.." && pwd)"
VPS_KONG_PORT="${VPS_KONG_PORT:-18000}"
VPS_META_PORT="${VPS_META_PORT:-18085}"
VPS_PG_PORT="${VPS_PG_PORT:-15432}"
VPS_USER="${VPS_USER:-ubuntu}"
VPS_API_URL="${VPS_API_URL:-https://api.carmacars.ca}"
VPS_DIR=/opt/carmacars

_vps_say() { echo "[vps] $*" >&2; }
_vps_die() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=vps::$*"; else echo "ERROR: $*"; fi >&2; exit 1; }

vps_host() {
  if [ -n "${VPS_HOST:-}" ]; then echo "$VPS_HOST"; return; fi
  local h=""
  [ -f "$VPS_ROOT/infra/vps/host" ] && h=$(grep -v '^[[:space:]]*#' "$VPS_ROOT/infra/vps/host" | tr -d '[:space:]' | head -c 255)
  [ -n "$h" ] || _vps_die "No server address: put the VPS IPv4 address in infra/vps/host (one line) and commit it"
  [[ "$h" =~ ^[0-9A-Za-z.:-]+$ ]] || _vps_die "infra/vps/host does not hold a plain address"
  VPS_HOST="$h"
  echo "$h"
}

_vps_ssh_setup() {
  [ -n "${_VPS_SSH_READY:-}" ] && return 0
  local d="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vps-ssh"
  mkdir -p "$d"; chmod 700 "$d"
  if [ ! -s "$d/key" ]; then
    [ -n "${VPS_SSH_KEY:-}" ] || _vps_die "VPS_SSH_KEY is empty (the repository secret, passed as env)"
    ( umask 077; printf '%s\n' "$VPS_SSH_KEY" | tr -d '\r' > "$d/key" )
  fi
  local host; host=$(vps_host)
  if [ -s "$VPS_ROOT/infra/vps/known_hosts" ]; then
    cp "$VPS_ROOT/infra/vps/known_hosts" "$d/known_hosts"
    VPS_SSH_OPTS=(-o StrictHostKeyChecking=yes)
  else
    if [ ! -s "$d/known_hosts" ]; then
      ssh-keyscan -T 15 -t ed25519 "$host" 2>/dev/null > "$d/known_hosts" || true
      [ -s "$d/known_hosts" ] || _vps_die "The server $host does not answer on port 22 (ssh-keyscan)"
      if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning title=vps::infra/vps/known_hosts is not committed yet: trusting the host key the server presented ($(ssh-keygen -lf "$d/known_hosts" | awk '{print $2}'))"; fi
    fi
    VPS_SSH_OPTS=(-o StrictHostKeyChecking=yes)
  fi
  VPS_SSH_OPTS+=(-i "$d/key" -o IdentitiesOnly=yes -o UserKnownHostsFile="$d/known_hosts" -o BatchMode=yes
                 -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=8
                 -o ControlPath="$d/cm-%C" -o ControlMaster=auto -o ControlPersist=3600 -o LogLevel=ERROR)
  _VPS_SSH_READY=1
}

# The server's firewall limits new SSH connections (ufw limit: more than 6 in 30 s from one address are dropped, and
# every attempt during a block extends it): commands share one connection (ControlMaster), and a command whose
# connection could not be made is tried again after 35, 60, 90 and 120 s of silence (VPS_SSH_RETRY=0: once only).
# Only failures before the session (connect, banner, key exchange) are retried, so a command never runs twice.
_vps_connect_failed() {
  grep -qE 'connect to host .* port [0-9]+:|kex_exchange_identification|banner exchange|Connection closed by [0-9a-fA-F.:]+ port [0-9]+$|Connection reset by [0-9a-fA-F.:]+ port|Control socket connect' "$1"
}
_vps_retry() { # command... (ssh or scp): its stderr is shown as it comes and kept to recognise a connection failure
  local err rc i delays
  read -r -a delays <<<"${VPS_SSH_RETRY_DELAYS:-35 60 90 120}"
  err=$(mktemp)
  for i in 0 1 2 3 4; do
    rc=0
    "$@" 2> >(tee "$err" >&2) || rc=$?
    # tee finishes a moment after the command (not waited for: a backgrounded master detaches from stderr)
    if [ "$rc" != 0 ]; then sleep 0.5; fi
    if [ "$rc" != 0 ] && [ "$i" -lt 4 ] && [ "${VPS_SSH_RETRY:-1}" = 1 ] && _vps_connect_failed "$err"; then
      _vps_say "SSH could not connect ($(grep -v '^$' "$err" | tail -n 1)); trying again in ${delays[$i]} s"
      sleep "${delays[$i]}"
      continue
    fi
    break
  done
  rm -f "$err"
  return "$rc"
}

# vps_ssh <command...>: one command on the server as the ubuntu user (sudo for root). Stdin is passed through.
vps_ssh() {
  _vps_ssh_setup
  _vps_retry ssh "${VPS_SSH_OPTS[@]}" "$VPS_USER@$(vps_host)" "$@"
}

# The shared connection closed (before a reboot: it would hang on the dead server).
vps_ssh_close() {
  _vps_ssh_setup
  ssh "${VPS_SSH_OPTS[@]}" -O exit "$VPS_USER@$(vps_host)" 2>/dev/null || true
}

# Copy local files to the server (scp over the shared connection).
vps_scp() { # src... dest(remote path)
  _vps_ssh_setup
  local args=("$@") n=$#
  local dest="${args[$((n - 1))]}"
  unset 'args[$((n - 1))]'
  _vps_retry scp -q "${VPS_SSH_OPTS[@]}" "${args[@]}" "$VPS_USER@$(vps_host):$dest"
}

# The tunnels (idempotent). Exports SB_URL/SQL_API_URL for this shell and, in Actions, for later steps of the job.
vps_tunnel() {
  _vps_ssh_setup
  local host; host=$(vps_host)
  if ! ssh "${VPS_SSH_OPTS[@]}" -O check "$VPS_USER@$host" 2>/dev/null; then
    _vps_retry ssh "${VPS_SSH_OPTS[@]}" -fN "$VPS_USER@$host" || _vps_die "SSH to $VPS_USER@$host failed"
  fi
  if ! curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$VPS_META_PORT/" 2>/dev/null; then
    ssh "${VPS_SSH_OPTS[@]}" -O forward -L "127.0.0.1:$VPS_KONG_PORT:127.0.0.1:8000" "$VPS_USER@$host" 2>/dev/null || true
    ssh "${VPS_SSH_OPTS[@]}" -O forward -L "127.0.0.1:$VPS_META_PORT:127.0.0.1:8085" "$VPS_USER@$host" 2>/dev/null || true
    ssh "${VPS_SSH_OPTS[@]}" -O forward -L "127.0.0.1:$VPS_PG_PORT:127.0.0.1:5432" "$VPS_USER@$host" 2>/dev/null || true
  fi
}

# One value from the server's secret .env (never printed; masked in Actions).
vps_secret() {
  local v
  v=$(vps_ssh sudo "$VPS_DIR/bin/secret" "$1") || return 1
  if [ -n "$v" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$v" >&2; fi
  printf '%s' "$v"
}

# SQL through pg-meta (POST /query): the rows of the last statement as a JSON array, one implicit transaction per
# call, like the Management API's database/query. Prints the rows; returns 1 with the error on stderr.
vps_sql_file() {
  vps_tunnel
  local body out code
  body=$(mktemp); out=$(mktemp)
  jq -Rs '{query: .}' < "$1" > "$body"
  code=$(curl -sS -o "$out" -w '%{http_code}' --max-time 900 -X POST "http://127.0.0.1:$VPS_META_PORT/query" \
    -H 'content-type: application/json' --data-binary @"$body") || code=000
  rm -f "$body"
  if [ "${code:0:1}" != 2 ]; then echo "SQL failed ($code): $(head -c 1500 "$out")" >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}
vps_sql() { local f; f=$(mktemp); printf '%s' "$1" > "$f"; local rc=0; vps_sql_file "$f" || rc=$?; rm -f "$f"; return $rc; }

# psql as supabase_admin (superuser) through the tunnel: for restores and settings pg-meta's postgres role cannot make.
vps_psql_url() {
  vps_tunnel
  local pw; pw=$(vps_secret POSTGRES_PASSWORD)
  printf 'postgresql://supabase_admin:%s@127.0.0.1:%s/postgres' "$(jq -rn --arg p "$pw" '$p|@uri')" "$VPS_PG_PORT"
}

# The server is the live backend (the cutover is done): the copy and reset workflows refuse to run.
vps_is_live() { vps_ssh sudo test -f "$VPS_DIR/state/live"; }
