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
# CI runs the suite in parallel slices (.github/workflows/ci.yml, db): each slice builds the same fresh database and
# runs, in the same order as the whole run, the base files and its share of the release files.
#   base files      00_ to 98_: each builds on the data the earlier ones left (04_rls needs 03_flows' statements, 07 the
#                   staff of 03 to 06), so every slice runs all of them, in order.
#   release files   99_*: one suite a change, written against the data the base files left. A slice runs those whose
#                   name's checksum falls in it, so a file keeps its slice when other files are added.
#   CARMACARS_TEST_SLICE=2/3      the base files and slice 2 of 3 of the release files. Unset: every file, as before.
#   CARMACARS_TEST_RESULTS=dir    also writes dir/files.txt (the files this slice answers for: its release files, and
#                                 in slice 1 the base files) and dir/results.tsv (their assertions), which
#                                 scripts/test-merge.sh turns into the one summary of all slices. The slice itself
#                                 still fails on any failed assertion, a base file's included.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS="$ROOT/supabase/migrations"
TESTS="$ROOT/supabase/tests"
DB=carmacars_test

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
in_slice() { [ "$SLICE_N" = 1 ] || is_base "$1" || [ $(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % SLICE_N + 1 )) = "$SLICE_I" ]; }
# the assertions of the base files are reported by slice 1 only: test.results rows up to FROM_ID are left out elsewhere
FROM_ID=0; BASE_DONE=0
RESULTS="${CARMACARS_TEST_RESULTS:-}"
if [ -n "$RESULTS" ]; then mkdir -p "$RESULTS"; : > "$RESULTS/files.txt"; fi

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

echo "== tests (a failed assertion prints a WARNING line here and is listed in the summary)$([ "$SLICE_N" = 1 ] || echo "; slice $SLICE")"
run "$DB_URL" -f "$TESTS/helpers.sql" >/dev/null
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
  run "$DB_URL" -f "$f" >/dev/null
  if [ -n "$RESULTS" ] && { [ "$SLICE_I" = 1 ] || ! is_base "$b"; }; then echo "$b" >> "$RESULTS/files.txt"; fi
done
if [ -n "$RESULTS" ]; then
  # a slice other than 1 that ran no release file reports nothing
  if [ "$BASE_DONE" = 0 ] && [ "$SLICE_I" != 1 ]; then FROM_ID="$("$PSQL" -X -q -At "$DB_URL" -c "select coalesce(max(id), 0) from test.results")"; fi
  "$PSQL" -X -q -v ON_ERROR_STOP=1 "$DB_URL" \
    -c "copy (select suite, passed, name, coalesce(detail, '') from test.results where id > $FROM_ID order by id) to stdout" > "$RESULTS/results.tsv"
fi

echo "== summary"
"$PSQL" -X -q -At "$DB_URL" -f "$TESTS/summary.sql"
FAILED="$("$PSQL" -X -q -At "$DB_URL" -c "select count(*) from test.results where not passed")"
[ "$FAILED" = "0" ] || { echo "FAILED: $FAILED assertion(s)"; exit 1; }
echo "ALL TESTS PASSED"
