#!/usr/bin/env bash
# One command: build a fresh database, apply every migration, run every test.
#
#   scripts/test.sh
#
# By default it starts a throwaway PostgreSQL server (needs initdb/pg_ctl/psql 15+ on the
# machine) and removes it afterwards. To use a server you already run, set
#   CARMACARS_TEST_PGURL=postgres://user:pass@host:5432/postgres
# and the script creates and drops the database "carmacars_test" there.
#
# CI runs the suite in two steps (.github/workflows/ci.yml, db-base and db). The base files run once; the release
# files are spread over parallel slices that each restore the database the base files left.
#   base files      00_ to 98_: each builds on the data the earlier ones left (04_rls needs 03_flows' statements, 07 the
#                   staff of 03 to 06), so they run in one job, in order.
#   release files   99_*: one suite a change, written against the data the base files left. A 99_ file never needs the
#                   data or the settings another 99_ file leaves.
#   CARMACARS_TEST_PHASE=base     fresh database, every migration, the base files; with CARMACARS_TEST_DUMP=file it
#                                 then writes the database (pg_dump -Fc) and its roles (file.roles.sql) for the slices.
#   CARMACARS_TEST_PHASE=release  restores CARMACARS_TEST_DUMP and runs only this slice's release files.
#   CARMACARS_TEST_SLICE=2/3      slice 2 of 3 of the release files. Unset: every file, as before. With
#                                 CARMACARS_TEST_TIMINGS=file.json (scripts/test-slices.mjs) the slices are balanced by
#                                 the seconds each file took in the last run; without it, by the checksum of the name.
#   CARMACARS_TEST_ONLY="99_a.sql 99_b.sql"  with PHASE=release: only these release files (a helper's local check of the
#                                 files its change touches, on the base database a base run left in CARMACARS_TEST_DUMP).
#   CARMACARS_TEST_RESULTS=dir    also writes dir/files.txt (the files this run answers for), dir/results.tsv (their
#                                 assertions) and dir/timings.tsv (seconds a file), which scripts/test-merge.sh turns
#                                 into the one summary of all slices. A run fails on its own failed assertions.
#   No phase (local, the default): one database, every migration, every file, in order.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="$ROOT/supabase/migrations"
TESTS="$ROOT/supabase/tests"
DB="${CARMACARS_TEST_DB:-carmacars_test}"

find_bin() {
  local b
  if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return; fi
  for b in /usr/lib/postgresql/*/bin/"$1" /usr/local/opt/postgresql*/bin/"$1" /opt/homebrew/opt/postgresql*/bin/"$1"; do
    [ -x "$b" ] && { echo "$b"; return; }
  done
  echo "missing PostgreSQL program: $1" >&2; exit 2
}

PSQL="$(find_bin psql)"
CLEANUP_DIR=""
AS_PG=()

cleanup() {
  if [ -n "$CLEANUP_DIR" ]; then
    ${AS_PG[@]+"${AS_PG[@]}"} "$PG_CTL" -D "$CLEANUP_DIR/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$CLEANUP_DIR"
  fi
}
trap cleanup EXIT

if [ -n "${CARMACARS_TEST_PGURL:-}" ]; then
  ADMIN_URL="$CARMACARS_TEST_PGURL"
  DB_URL="${CARMACARS_TEST_PGURL%/*}/$DB"
else
  INITDB="$(find_bin initdb)"; PG_CTL="$(find_bin pg_ctl)"
  BASE="${CARMACARS_TEST_TMP:-${TMPDIR:-/tmp}}"
  # PostgreSQL refuses to run as root: use the postgres account for the server only.
  if [ "$(id -u)" = "0" ]; then
    id postgres >/dev/null 2>&1 || { echo "running as root needs a 'postgres' system user" >&2; exit 2; }
    AS_PG=(runuser -u postgres --)
    [ -n "${CARMACARS_TEST_TMP:-}" ] || BASE="$(getent passwd postgres | cut -d: -f6)"
  fi
  CLEANUP_DIR="$(${AS_PG[@]+"${AS_PG[@]}"} mktemp -d "$BASE/carmacars-pg.XXXXXX")"
  PORT="${CARMACARS_TEST_PORT:-54329}"
  ${AS_PG[@]+"${AS_PG[@]}"} "$INITDB" -D "$CLEANUP_DIR/data" -U postgres -A trust -E UTF8 --locale=C >/dev/null
  ${AS_PG[@]+"${AS_PG[@]}"} "$PG_CTL" -D "$CLEANUP_DIR/data" -l "$CLEANUP_DIR/log" -w \
      -o "-k $CLEANUP_DIR -p $PORT -c listen_addresses='' -c timezone=UTC -c fsync=off" start >/dev/null
  chmod 755 "$CLEANUP_DIR" 2>/dev/null || ${AS_PG[@]+"${AS_PG[@]}"} chmod 755 "$CLEANUP_DIR"
  ADMIN_URL="postgresql://postgres@/postgres?host=$CLEANUP_DIR&port=$PORT"
  DB_URL="postgresql://postgres@/$DB?host=$CLEANUP_DIR&port=$PORT"
fi

run() { "$PSQL" -X -q -v ON_ERROR_STOP=1 "$@"; }

SLICE="${CARMACARS_TEST_SLICE:-1/1}"
[[ "$SLICE" =~ ^([0-9]+)/([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] \
  || { echo "CARMACARS_TEST_SLICE must be i/n with 1 <= i <= n (got $SLICE)" >&2; exit 2; }
SLICE_I="${BASH_REMATCH[1]}"; SLICE_N="${BASH_REMATCH[2]}"
# base files run in every slice; a release file's slice is the POSIX checksum of its name (the same on every machine)
is_base() { case "$1" in 99_*) return 1 ;; *) return 0 ;; esac; }
PHASE="${CARMACARS_TEST_PHASE:-all}"
case "$PHASE" in all|base|release) ;; *) echo "CARMACARS_TEST_PHASE must be all, base or release" >&2; exit 2 ;; esac
DUMP="${CARMACARS_TEST_DUMP:-}"
[ "$PHASE" != release ] || [ -f "$DUMP" ] || { echo "CARMACARS_TEST_PHASE=release needs CARMACARS_TEST_DUMP (a file)" >&2; exit 2; }
# the release files of this slice: balanced by recorded timings when given, else by the checksum of the name
SLICE_LIST=""
TIMINGS="${CARMACARS_TEST_TIMINGS:-}"; [ -z "$TIMINGS" ] || [ "${TIMINGS#/}" != "$TIMINGS" ] || TIMINGS="$PWD/$TIMINGS"   # the list is made in the tests folder
if [ "$SLICE_N" != 1 ] && [ -n "$TIMINGS" ] && [ -f "$TIMINGS" ]; then
  SLICE_LIST="$(cd "$TESTS" && ls 99_*.sql | node "$ROOT/scripts/test-slices.mjs" "$TIMINGS" "$SLICE_I" "$SLICE_N")"
fi
in_slice() {
  if [ "$PHASE" = base ]; then is_base "$1"; return; fi
  if [ "$PHASE" = release ] && is_base "$1"; then return 1; fi
  if [ -n "${CARMACARS_TEST_ONLY:-}" ]; then [[ " $CARMACARS_TEST_ONLY " == *" $1 "* ]]; return; fi
  [ "$SLICE_N" = 1 ] || is_base "$1" && return 0
  if [ -n "$SLICE_LIST" ]; then grep -qxF "$1" <<< "$SLICE_LIST"; return; fi
  [ $(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % SLICE_N + 1 )) = "$SLICE_I" ]
}
# the assertions of the base files are reported by slice 1 only: test.results rows up to FROM_ID are left out elsewhere
FROM_ID=0; BASE_DONE=0
RESULTS="${CARMACARS_TEST_RESULTS:-}"
if [ -n "$RESULTS" ]; then mkdir -p "$RESULTS"; : > "$RESULTS/files.txt"; : > "$RESULTS/timings.tsv"; fi

if [ "$PHASE" = release ]; then
  echo "== the base database (restored from $DUMP)"
  run "$ADMIN_URL" -c "drop database if exists $DB"
  "$PSQL" -X -q "$ADMIN_URL" -f "$DUMP.roles.sql" >/dev/null 2>&1 || true   # anon, authenticated, service_role and their settings
  PG_RESTORE="$(find_bin pg_restore)"
  # --create keeps the database's own settings (time zone UTC, app.read_cache off of helpers.sql)
  "$PG_RESTORE" --create --exit-on-error -j 4 -d "$ADMIN_URL" "$DUMP"
  [ "$("$PSQL" -X -q -At "$ADMIN_URL" -c "select datname from pg_database where datname = '$DB'")" = "$DB" ] \
    || { echo "the dump holds another database than $DB" >&2; exit 2; }
  FROM_ID="$("$PSQL" -X -q -At "$DB_URL" -c "select coalesce(max(id), 0) from test.results")"; BASE_DONE=1
else
echo "== fresh database"
run "$ADMIN_URL" -c "drop database if exists $DB" -c "create database $DB"
# The session time zone is UTC on purpose: nothing may depend on the server's zone.
run "$DB_URL" -c "alter database $DB set timezone to 'UTC'"

echo "== local shim (auth schema; not a migration)"
run "$DB_URL" -f "$TESTS/shim/00_supabase_shim.sql"

echo "== migrations"
for f in "$MIGRATIONS"/*.sql; do
  echo "   $(basename "$f")"
  run "$DB_URL" -1 -f "$f" >/dev/null          # each migration is one transaction
done
echo "   tables: $("$PSQL" -X -q -At "$DB_URL" -c "select count(*) from pg_tables where schemaname = 'public'")" \
     " policies: $("$PSQL" -X -q -At "$DB_URL" -c "select count(*) from pg_policies where schemaname = 'public'")"
run "$DB_URL" -f "$TESTS/helpers.sql" >/dev/null
fi

echo "== tests (a failed assertion prints a WARNING line here and is listed in the summary)$([ "$PHASE" = all ] || echo "; $PHASE")$([ "$SLICE_N" = 1 ] || echo "; slice $SLICE")"
for f in "$TESTS"/[0-9]*.sql; do
  b="$(basename "$f")"
  in_slice "$b" || continue
  if [ "$BASE_DONE" = 0 ] && ! is_base "$b"; then
    # the first release file: the base files sort before it (the glob's order), so their rows end here
    BASE_DONE=1
    if [ "$SLICE_I" != 1 ]; then FROM_ID="$("$PSQL" -X -q -At "$DB_URL" -c "select coalesce(max(id), 0) from test.results")"; fi
  elif [ "$BASE_DONE" = 1 ] && is_base "$b"; then
    echo "a base file sorts after a release file: $b" >&2; exit 2
  fi
  echo "   $b"
  t0="$(date +%s.%N)"
  # a release file starts with no event another file left unprocessed: app.process_events takes the oldest first, one
  # batch at a time, so leftovers would delay or add to its own notices (REQ-117; runs 46004944280 and the local slices
  # of Nov 27: 99_r41_marketing, 99_booking_moments, 99_push_alerts failed only after certain other files)
  is_base "$b" || run "$DB_URL" -c "update app_events set processed_at = now(), process_note = 'left by an earlier test file' where processed_at is null" >/dev/null
  run "$DB_URL" -f "$f" >/dev/null
  if [ -n "$RESULTS" ]; then awk -v b="$b" -v t0="$t0" -v t1="$(date +%s.%N)" 'BEGIN { printf "%s\t%.1f\n", b, t1 - t0 }' >> "$RESULTS/timings.tsv"; fi
  if [ -n "$RESULTS" ] && { [ "$SLICE_I" = 1 ] || ! is_base "$b"; }; then echo "$b" >> "$RESULTS/files.txt"; fi
done
if [ -n "$RESULTS" ]; then
  # a slice other than 1 that ran no release file reports nothing
  if [ "$BASE_DONE" = 0 ] && [ "$SLICE_I" != 1 ]; then FROM_ID="$("$PSQL" -X -q -At "$DB_URL" -c "select coalesce(max(id), 0) from test.results")"; fi
  "$PSQL" -X -q -v ON_ERROR_STOP=1 "$DB_URL" \
    -c "copy (select suite, passed, name, coalesce(detail, '') from test.results where id > $FROM_ID order by id) to stdout" > "$RESULTS/results.tsv"
fi

if [ "$PHASE" = base ] && [ -n "$DUMP" ]; then
  echo "== the base database for the slices: $DUMP"
  PG_DUMP="$(find_bin pg_dump)"; PG_DUMPALL="$(find_bin pg_dumpall)"
  "$PG_DUMP" -Fc -Z 1 -f "$DUMP" "$DB_URL"
  "$PG_DUMPALL" -r --no-role-passwords -d "$ADMIN_URL" > "$DUMP.roles.sql"
fi

echo "== summary"
if [ "$PHASE" = release ]; then
  # the base rows were reported (and failed, if any failed) by the base run
  "$PSQL" -X -q -At "$DB_URL" -c "delete from test.results where id <= $FROM_ID"
fi
"$PSQL" -X -q -At "$DB_URL" -f "$TESTS/summary.sql"
FAILED="$("$PSQL" -X -q -At "$DB_URL" -c "select count(*) from test.results where not passed")"
[ "$FAILED" = "0" ] || { echo "FAILED: $FAILED assertion(s)"; exit 1; }
echo "ALL TESTS PASSED"
