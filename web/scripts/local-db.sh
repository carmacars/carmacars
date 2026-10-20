#!/usr/bin/env bash
# The local stack: a PostgreSQL server with the Supabase shim, every migration of
# ../supabase/migrations, the local auth stand-in and the seed. See web/README.md.
#
#   scripts/local-db.sh up      start the server; build the database on first run (up --no-seed: schema only)
#   scripts/local-db.sh reset   drop and rebuild the database, then seed it
#   scripts/local-db.sh down    stop the server
set -euo pipefail
WEB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$WEB/.." && pwd)"
PORT="${CARMACARS_LOCAL_PORT:-54322}"
DB=carmacars

find_bin() {
  local b
  if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return; fi
  for b in /usr/lib/postgresql/*/bin/"$1" /usr/local/opt/postgresql*/bin/"$1" /opt/homebrew/opt/postgresql*/bin/"$1"; do
    [ -x "$b" ] && { echo "$b"; return; }
  done
  echo "missing PostgreSQL program: $1" >&2; exit 2
}
PSQL="$(find_bin psql)"; INITDB="$(find_bin initdb)"; PG_CTL="$(find_bin pg_ctl)"
AS_PG=()
if [ "$(id -u)" = "0" ]; then
  AS_PG=(runuser -u postgres --)
  DIR="${CARMACARS_LOCAL_DIR:-$(getent passwd postgres | cut -d: -f6)/cc-local}"
else
  DIR="${CARMACARS_LOCAL_DIR:-$HOME/.carmacars-local}"
fi
ADMIN="postgresql://postgres@127.0.0.1:$PORT/postgres"
URL="postgresql://postgres@127.0.0.1:$PORT/$DB"
run() { "$PSQL" -X -q -v ON_ERROR_STOP=1 "$@"; }

start() {
  if [ ! -d "$DIR/data" ]; then
    ${AS_PG[@]+"${AS_PG[@]}"} mkdir -p "$DIR"
    ${AS_PG[@]+"${AS_PG[@]}"} "$INITDB" -D "$DIR/data" -U postgres -A trust -E UTF8 --locale=C >/dev/null
  fi
  if ! ${AS_PG[@]+"${AS_PG[@]}"} "$PG_CTL" -D "$DIR/data" status >/dev/null 2>&1; then
    ${AS_PG[@]+"${AS_PG[@]}"} "$PG_CTL" -D "$DIR/data" -l "$DIR/log" -w \
      -o "-p $PORT -c listen_addresses=127.0.0.1 -c timezone=UTC -k $DIR -c max_connections=200" start >/dev/null
  fi
}

build() {
  echo "== database $DB on port $PORT"
  run "$ADMIN" -c "drop database if exists $DB with (force)" -c "create database $DB"
  run "$URL" -c "alter database $DB set timezone to 'UTC'"
  run "$URL" -f "$ROOT/supabase/tests/shim/00_supabase_shim.sql" >/dev/null
  # the migration history, as the deploy keeps it (scripts/deploy/supabase.sh): app.schema_marker() reads it, so the
  # local database reports its newest migration like production does
  run "$URL" -c "create schema if not exists supabase_migrations" \
    -c "create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text)"
  for f in "$ROOT"/supabase/migrations/*.sql; do
    run "$URL" -1 -f "$f" >/dev/null 2>&1 || { echo "migration failed: $f"; run "$URL" -1 -f "$f" >/dev/null; }
    b="$(basename "$f" .sql)"
    run "$URL" -c "insert into supabase_migrations.schema_migrations (version, name) values ('${b%%_*}', '${b#*_}') on conflict do nothing"
  done
  run "$URL" -f "$WEB/local/local_auth.sql" >/dev/null
  echo "   migrations applied: $(ls "$ROOT"/supabase/migrations/*.sql | wc -l)"
}

case "${1:-up}" in
  up)
    start
    if ! "$PSQL" -X -At "$ADMIN" -c "select 1 from pg_database where datname = '$DB'" | grep -q 1; then
      build; [ "${2:-}" = --no-seed ] || (cd "$WEB" && node scripts/seed.mjs)
    fi
    echo "DATABASE_URL=$URL" ;;
  reset) start; build; (cd "$WEB" && node scripts/seed.mjs) ;;
  down) ${AS_PG[@]+"${AS_PG[@]}"} "$PG_CTL" -D "$DIR/data" -m fast stop ;;
  *) echo "usage: $0 up|reset|down" >&2; exit 2 ;;
esac
