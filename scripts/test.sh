#!/usr/bin/env bash
# One command: build a fresh database, apply every migration, run every test.
#
#   scripts/test.sh
#
# By default it starts a throwaway PostgreSQL server (needs initdb/pg_ctl/psql 15+ on the
# machine) and removes it afterwards. To use a server you already run, set
#   CARMACARS_TEST_PGURL=postgres://user:pass@host:5432/postgres
# and the script creates and drops the database "carmacars_test" there.
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

echo "== tests (a failed assertion prints a WARNING line here and is listed in the summary)"
run "$DB_URL" -f "$TESTS/helpers.sql" >/dev/null
for f in "$TESTS"/[0-9]*.sql; do
  echo "   $(basename "$f")"
  run "$DB_URL" -f "$f" >/dev/null
done

echo "== summary"
"$PSQL" -X -q -At "$DB_URL" -f "$TESTS/summary.sql"
FAILED="$("$PSQL" -X -q -At "$DB_URL" -c "select count(*) from test.results where not passed")"
[ "$FAILED" = "0" ] || { echo "FAILED: $FAILED assertion(s)"; exit 1; }
echo "ALL TESTS PASSED"
