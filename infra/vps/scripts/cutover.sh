#!/usr/bin/env bash
# The cutover's switches (the vps-cutover workflow; infra/vps/CUTOVER.md says when to use each). These are the only
# commands of the move that change the hosted project, and only when run by hand on the day.
#
#   cutover.sh status            the hosted project (read-only default, active jobs) and the server (live, jobs)
#   cutover.sh freeze-hosted     the hosted project stops taking writes: its pg_cron jobs are paused (their states
#                                kept on the server, state/cron-hosted-frozen.json), new database sessions default to
#                                read-only, the database API's and Storage's open sessions are closed so they reconnect
#                                read-only. The site stays up for reading; bookings, sign-ins that write and uploads
#                                fail with an error until the Worker points at the server.
#   cutover.sh unfreeze-hosted   undoes freeze-hosted (writes back on, the jobs that were active resumed)
#   cutover.sh go-live           the server becomes the live backend: state/live is set (the copy and reset refuse
#                                from then on), its pg_cron jobs that were active on the hosted project are resumed
#   cutover.sh assert-frozen     fails unless the hosted project is frozen (before the final copy and go-live)
#   cutover.sh rollback          the server's jobs paused and state/live removed, then unfreeze-hosted. Data written on
#                                the server after go-live is NOT carried back (CUTOVER.md, Rollback).
# Env: SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF, VPS_SSH_KEY.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../../scripts/deploy/vps.sh
. "$ROOT/scripts/deploy/vps.sh"
: "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_REF:?}"
HAPI="https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF/database/query"
note() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=cutover::$*"; else echo "NOTICE: $*"; fi; }
die() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=cutover::$*"; else echo "ERROR: $*"; fi; exit 1; }

hq() { # SQL on the hosted project (Management API); prints the rows
  local out code; out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' --max-time 120 -X POST "$HAPI" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H 'content-type: application/json' --data-binary "$(jq -n --arg q "$1" '{query: $q}')") || code=000
  if [ "${code:0:1}" != 2 ]; then echo "hosted SQL failed ($code): $(head -c 600 "$out")" >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}
hosted_state() {
  hq "select current_setting('default_transaction_read_only') as db_read_only,
             coalesce((select array_to_string(setconfig, ',') from pg_db_role_setting s join pg_roles r on r.oid = s.setrole
                        where r.rolname = 'authenticator' and s.setdatabase = 0), '') as authenticator_settings,
             (select count(*) from cron.job) as jobs, (select count(*) from cron.job where active) as active_jobs"
}

status() {
  local h v
  h=$(hosted_state) || die "the hosted project did not answer"
  v=$(vps_sql "select (select count(*) from cron.job) as jobs, (select count(*) from cron.job where active) as active_jobs")
  local live=no; vps_is_live && live="yes, since $(vps_ssh sudo cat /opt/carmacars/state/live)"
  note "hosted: read-only default $(jq -r '.[0].db_read_only' <<<"$h"), authenticator settings '$(jq -r '.[0].authenticator_settings' <<<"$h")', jobs $(jq -r '.[0].active_jobs' <<<"$h") active of $(jq -r '.[0].jobs' <<<"$h")"
  note "server: live $live; jobs $(jq -r '.[0].active_jobs' <<<"$v") active of $(jq -r '.[0].jobs' <<<"$v")"
}

freeze_hosted() {
  vps_is_live && die "the server is already live"
  # 1. the jobs' states, kept on the server before anything changes (only if not already frozen: a second run must
  #    not record the paused states)
  local jobs
  jobs=$(hq "select coalesce(json_agg(json_build_object('jobname', jobname, 'active', active) order by jobid), '[]') as j from cron.job" | jq '.[0].j')
  if [ "$(jq '[.[] | select(.active)] | length' <<<"$jobs")" != 0 ] || ! vps_ssh sudo test -s /opt/carmacars/state/cron-hosted-frozen.json; then
    printf '%s' "$jobs" | vps_ssh "sudo sh -c 'umask 077; cat > /opt/carmacars/state/cron-hosted-frozen.json'"
  fi
  # 2. pause the jobs (before the read-only default, which would make this a failing write)
  hq "select count(cron.alter_job(jobid, active := false)) as paused from cron.job where active" > /dev/null
  # 3. new sessions read-only: the whole database when the role may (database owner), else the database API's role
  local how=database
  if ! hq "alter database postgres set default_transaction_read_only = on" > /dev/null 2>&1; then
    how=authenticator
    hq "alter role authenticator set default_transaction_read_only = on" > /dev/null || die "could not make the hosted database read-only (neither the database nor the authenticator role)"
  fi
  # 4. close the open sessions of the database API and Storage (their pools reconnect read-only); the API's idle
  #    connections also end on their own within 30 s, so a refusal here is not fatal
  hq "select count(pg_terminate_backend(pid)) as closed from pg_stat_activity
       where usename in ('authenticator', 'supabase_storage_admin') and pid <> pg_backend_pid()" > /dev/null \
    || note "open sessions could not be closed; waiting for the pools to recycle"
  sleep 35
  status
  note "hosted project frozen ($how read-only by default, jobs paused). Next: vps-cutover final-copy."
}

unfreeze_hosted() {
  # writes back on: the explicit READ WRITE transaction works even when new sessions default to read-only
  hq "begin read write; alter database postgres reset default_transaction_read_only; commit;" > /dev/null 2>&1 \
    || hq "set transaction read write; alter database postgres reset default_transaction_read_only;" > /dev/null 2>&1 || true
  hq "begin read write; alter role authenticator reset default_transaction_read_only; commit;" > /dev/null 2>&1 || true
  local ro; ro=$(hq "select current_setting('default_transaction_read_only') as v" | jq -r '.[0].v')
  [ "$ro" = off ] || die "the hosted database still defaults to read-only; in the Supabase dashboard's SQL editor run:
    begin read write; alter database postgres reset default_transaction_read_only; alter role authenticator reset default_transaction_read_only; commit;"
  # the jobs that were active at the freeze
  local names
  names=$(vps_ssh "sudo cat /opt/carmacars/state/cron-hosted-frozen.json 2>/dev/null || echo '[]'" | jq -c '[.[] | select(.active) | .jobname | select(. != null)]')
  if [ "$names" != "[]" ]; then
    hq "select count(cron.alter_job(jobid, active := true)) as resumed from cron.job where jobname = any(array(select jsonb_array_elements_text('$(sed "s/'/''/g" <<<"$names")'::jsonb)))" > /dev/null
  else
    note "no record of the hosted jobs' states at the freeze: check Integrations > Cron in the dashboard"
  fi
  status
  note "hosted project writable again"
}

assert_frozen() {
  local h; h=$(hosted_state)
  if [ "$(jq -r '.[0].active_jobs' <<<"$h")" != 0 ]; then die "the hosted project still has active pg_cron jobs: run freeze-hosted first (both would send the same emails)"; fi
  if [ "$(jq -r '.[0].db_read_only' <<<"$h")" != on ] && [[ "$(jq -r '.[0].authenticator_settings' <<<"$h")" != *default_transaction_read_only=on* ]]; then
    die "the hosted project is not frozen: run freeze-hosted first"
  fi
}

go_live() {
  assert_frozen
  local names
  names=$(vps_ssh "sudo cat /opt/carmacars/state/cron-hosted-frozen.json 2>/dev/null || sudo cat /opt/carmacars/state/cron-hosted.json 2>/dev/null || echo '[]'" \
    | jq -c '[.[] | select(.active) | .jobname | select(. != null)]')
  vps_ssh "sudo sh -c 'date -u +%FT%TZ > /opt/carmacars/state/live'"
  vps_sql "select count(cron.alter_job(jobid, active := true)) as resumed from cron.job where jobname = any(array(select jsonb_array_elements_text('$(sed "s/'/''/g" <<<"$names")'::jsonb)))" > /dev/null
  status
  note "the server is live: its pg_cron jobs run (emails, debits, calendar sync). Next (the vps-cutover workflow does it unless deploy is off): infra/vps/backend = vps, then ci with deploy."
}

rollback() {
  vps_sql "select count(cron.alter_job(jobid, active := false)) as paused from cron.job where active" > /dev/null || true
  vps_ssh "sudo rm -f /opt/carmacars/state/live"
  unfreeze_hosted
  note "rolled back to the hosted project: infra/vps/backend = supabase, then ci with deploy (the vps-cutover workflow does both unless deploy is off)"
}

case "${1:-}" in
  status) status ;;
  freeze-hosted) freeze_hosted ;;
  unfreeze-hosted) unfreeze_hosted ;;
  go-live) go_live ;;
  rollback) rollback ;;
  assert-frozen) assert_frozen; note "the hosted project is frozen" ;;
  *) die "usage: cutover.sh status|freeze-hosted|unfreeze-hosted|go-live|rollback|assert-frozen" ;;
esac
