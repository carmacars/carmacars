#!/usr/bin/env bash
# Restore a backup into a scratch PostgreSQL and prove it is complete (docs/backups.md).
#
#   scripts/backup/restore-test.sh [--dir DIR] [--stamp STAMP | --latest] [--keep]
#
# --dir DIR     the parts and manifest.json are already in DIR (the nightly job, right after the backup)
# --latest      download the newest folder of the Storage bucket `backups` (needs SUPABASE_ACCESS_TOKEN and
#               SUPABASE_PROJECT_REF); --stamp downloads that folder instead
# The private key is BACKUP_AGE_IDENTITY, or a file named by BACKUP_AGE_IDENTITY_FILE, or the vault secret
# backup_age_identity. A scratch server is started from initdb (PostgreSQL 17, or RESTORE_PGBIN) on port
# RESTORE_PORT (54340) and removed afterwards (--keep leaves it running and prints its address); RESTORE_PGURL
# uses a server you already run (the database carmacars_restore is created there).
#
# Checks: the encrypted file's SHA-256, decryption, the plain dump's SHA-256, pg_restore, then the row count of
# every table against the manifest (exact when the manifest's counts came from the dump's own snapshot), and a
# few reads through the app's functions. Writes restore-report.json beside the files; exits 1 on a failed check.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR=""; STAMP=""; LATEST=false; KEEP=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --stamp) STAMP="$2"; shift 2 ;;
    --latest) LATEST=true; shift ;;
    --keep) KEEP=true; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
say() { echo "[restore] $*"; }
note() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=restore::$*"; else echo "NOTICE: $*"; fi; }
bad() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=restore::$*"; else echo "ERROR: $*"; fi; exit 1; }
t0=$(date +%s)

# ---------------------------------------------------------------- the files
if [ -z "$DIR" ]; then
  # shellcheck source=../deploy/lib.sh
  source "$ROOT/scripts/deploy/lib.sh"
  DIR="$(mktemp -d)"; chmod 700 "$DIR"
  KEY=$(curl -sS "$SB_API/api-keys?reveal=true" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" | jq -r '.[] | select(.name == "service_role") | .api_key')
  mask "$KEY"
  ST="https://$SUPABASE_PROJECT_REF.supabase.co/storage/v1"
  H=(-H "Authorization: Bearer $KEY" -H "apikey: $KEY")
  if [ -z "$STAMP" ]; then
    $LATEST || bad "give --dir, --stamp or --latest"
    STAMP=$(curl -sS -X POST "$ST/object/list/backups" "${H[@]}" -H 'content-type: application/json' \
      --data '{"prefix":"nightly/","limit":1000,"sortBy":{"column":"name","order":"desc"}}' | jq -r '[.[] | select(.id == null) | .name] | sort | last // empty')
    [ -n "$STAMP" ] || bad "no backup in the bucket"
  fi
  say "downloading nightly/$STAMP"
  curl -sS -f -o "$DIR/manifest.json" "$ST/object/backups/nightly/$STAMP/manifest.json" "${H[@]}" || bad "no manifest in nightly/$STAMP"
  for p in $(jq -r '.parts[]' "$DIR/manifest.json"); do
    curl -sS -f -o "$DIR/$p" "$ST/object/backups/nightly/$STAMP/$p" "${H[@]}" || bad "part $p could not be downloaded"
  done
fi
M="$DIR/manifest.json"
[ -f "$M" ] || bad "no manifest.json in $DIR"
STAMP=$(jq -r .stamp "$M")
ENC="$DIR/$(jq -r .file "$M")"
if [ ! -f "$ENC" ]; then (cd "$DIR" && cat $(jq -r '.parts[]' "$M") > "$(basename "$ENC")"); fi
[ "$(sha256sum "$ENC" | cut -d' ' -f1)" = "$(jq -r .encrypted.sha256 "$M")" ] || bad "the encrypted file's checksum does not match the manifest"
say "checksum of the encrypted file matches ($(stat -c %s "$ENC") bytes)"

# ---------------------------------------------------------------- decrypt
IDF="$DIR/identity.txt"; ( umask 077; : > "$IDF" )
if [ -n "${BACKUP_AGE_IDENTITY:-}" ]; then printf '%s\n' "$BACKUP_AGE_IDENTITY" > "$IDF"
elif [ -n "${BACKUP_AGE_IDENTITY_FILE:-}" ]; then cat "$BACKUP_AGE_IDENTITY_FILE" > "$IDF"
else
  # shellcheck source=../deploy/lib.sh
  source "$ROOT/scripts/deploy/lib.sh"
  v=$(vault_get backup_age_identity); mask "$v"; printf '%s\n' "$v" > "$IDF"
fi
grep -q '^AGE-SECRET-KEY-' "$IDF" || bad "no age identity (BACKUP_AGE_IDENTITY, BACKUP_AGE_IDENTITY_FILE or the vault secret backup_age_identity)"
DUMP="$DIR/restore.dump"
age --decrypt --identity "$IDF" --output "$DUMP" "$ENC" || { rm -f "$IDF"; bad "decryption failed"; }
rm -f "$IDF"
[ "$(sha256sum "$DUMP" | cut -d' ' -f1)" = "$(jq -r .plain.sha256 "$M")" ] || bad "the decrypted dump's checksum does not match the manifest"
say "decrypted; the dump's checksum matches"

# ---------------------------------------------------------------- a scratch server
find_bin() {
  local b
  if [ -n "${RESTORE_PGBIN:-}" ] && [ -x "$RESTORE_PGBIN/$1" ]; then echo "$RESTORE_PGBIN/$1"; return; fi
  for b in /usr/lib/postgresql/17/bin/"$1" /usr/lib/postgresql/*/bin/"$1"; do [ -x "$b" ] && { echo "$b"; return; }; done
  command -v "$1" || { echo "missing PostgreSQL program: $1" >&2; exit 2; }
}
PSQL="$(find_bin psql)"; PG_RESTORE="$(find_bin pg_restore)"
SCRATCH=""; AS_PG=()
cleanup() {
  if [ -n "$SCRATCH" ] && ! $KEEP; then
    ${AS_PG[@]+"${AS_PG[@]}"} "$(find_bin pg_ctl)" -D "$SCRATCH/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$SCRATCH"
  fi
  rm -f "$DUMP"
}
trap cleanup EXIT
if [ -n "${RESTORE_PGURL:-}" ]; then
  ADMIN_URL="$RESTORE_PGURL"; URL="${RESTORE_PGURL%/*}/carmacars_restore"
else
  PORT="${RESTORE_PORT:-54340}"; BASE="${TMPDIR:-/tmp}"
  if [ "$(id -u)" = 0 ]; then AS_PG=(runuser -u postgres --); BASE="$(getent passwd postgres | cut -d: -f6)"; fi
  SCRATCH="$(${AS_PG[@]+"${AS_PG[@]}"} mktemp -d "$BASE/carmacars-restore.XXXXXX")"
  ${AS_PG[@]+"${AS_PG[@]}"} "$(find_bin initdb)" -D "$SCRATCH/data" -U postgres -A trust -E UTF8 --locale=C >/dev/null
  ${AS_PG[@]+"${AS_PG[@]}"} "$(find_bin pg_ctl)" -D "$SCRATCH/data" -l "$SCRATCH/log" -w \
    -o "-k $SCRATCH -p $PORT -c listen_addresses='' -c timezone=UTC -c fsync=off" start >/dev/null
  chmod 755 "$SCRATCH" 2>/dev/null || ${AS_PG[@]+"${AS_PG[@]}"} chmod 755 "$SCRATCH"
  ADMIN_URL="postgresql://postgres@/postgres?host=$SCRATCH&port=$PORT"
  URL="postgresql://postgres@/carmacars_restore?host=$SCRATCH&port=$PORT"
fi
say "scratch server: $("$PSQL" -X -At "$ADMIN_URL" -c 'show server_version')"
"$PSQL" -X -q -v ON_ERROR_STOP=1 "$ADMIN_URL" -c "drop database if exists carmacars_restore" -c "create database carmacars_restore"

# What Supabase provides around the schemas in the dump: its roles and the extensions' schema. (On a new Supabase
# project these exist already; see docs/backups.md for that restore.)
"$PSQL" -X -q -v ON_ERROR_STOP=1 "$URL" <<'SQL'
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'authenticator', 'supabase_admin', 'supabase_auth_admin',
                           'supabase_storage_admin', 'dashboard_user', 'pgbouncer', 'supabase_replication_admin',
                           'supabase_read_only_user', 'supabase_realtime_admin', 'pgsodium_keyholder', 'pgsodium_keyiduser', 'pgsodium_keymaker'] loop
    if not exists (select 1 from pg_roles where rolname = r) then execute format('create role %I nologin', r); end if;
  end loop;
end $$;
alter role service_role bypassrls;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists btree_gist with schema public;
alter database carmacars_restore set search_path = "$user", public, extensions;
SQL

# ---------------------------------------------------------------- restore
say "pg_restore"
set +e
"$PG_RESTORE" --no-owner --dbname="$URL" "$DUMP" 2> "$DIR/restore.log"
rc=$?
set -e
# Errors about what only Supabase has (its extensions, roles and event triggers) are expected on a plain server;
# an error about a table's data or a table itself is not.
grep -E '^pg_restore: error:' "$DIR/restore.log" > "$DIR/restore-errors.log" || true
errors=$(wc -l < "$DIR/restore-errors.log")
grep -iE 'TABLE DATA|COPY |could not execute query: ERROR: .*relation .* does not exist|PRIMARY KEY|unique' "$DIR/restore-errors.log" > "$DIR/restore-serious.log" || true
serious=$(wc -l < "$DIR/restore-serious.log")
say "pg_restore exit $rc, $errors error line(s), $serious about tables or their data"

# ---------------------------------------------------------------- every table's rows
COUNTS_SQL="select coalesce(json_object_agg(t.table_schema || '.' || t.table_name,
              (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', t.table_schema, t.table_name), false, true, '')))[1]::text::bigint), '{}')
              from information_schema.tables t where t.table_type = 'BASE TABLE' and t.table_schema in (select jsonb_array_elements_text('$(jq -c .schemas "$M")'::jsonb))"
"$PSQL" -X -q -At -v ON_ERROR_STOP=1 "$URL" -c "$COUNTS_SQL" > "$DIR/restored-counts.json"
jq -n --slurpfile want <(jq .row_counts "$M") --slurpfile got "$DIR/restored-counts.json" '
  ($want[0]) as $w | ($got[0]) as $g |
  {tables: ($w | length), restored_tables: ($g | length),
   matched: ([$w | to_entries[] | select($g[.key] == .value)] | length),
   rows_expected: ([$w[]] | add), rows_restored: ([$w | keys[] as $k | $g[$k] // 0] | add),
   missing: [$w | keys[] | select($g[.] == null)],
   different: [$w | to_entries[] | select($g[.key] != null and $g[.key] != .value) | {table: .key, expected: .value, restored: $g[.key]}]}' > "$DIR/compare.json"

# ---------------------------------------------------------------- reads through the app's functions
reads=$("$PSQL" -X -q -At -v ON_ERROR_STOP=1 "$URL" <<'SQL'
select json_build_object(
  'migrations', (select count(*) from supabase_migrations.schema_migrations),
  'settings_cap', (select notify_daily_cap from app.settings()),
  'today_toronto', app.today()::text,
  'bookings', (select count(*) from public.bookings),
  'vehicles', (select count(*) from public.vehicles),
  'users', (select count(*) from public.users),
  'auth_users', case when to_regclass('auth.users') is null then null
                 else (xpath('/row/c/text()', query_to_xml('select count(*) as c from auth.users', false, true, '')))[1]::text::bigint end,
  'catalogue', (select count(*) from public.notification_catalogue),
  'policies', (select count(*) from pg_policies where schemaname = 'public'),
  'functions_app', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app'))
SQL
)
dur=$(( $(date +%s) - t0 ))
consistent=$(jq -r .consistent_counts "$M")
jq -n --arg stamp "$STAMP" --argjson compare "$(cat "$DIR/compare.json")" --argjson reads "$reads" --argjson errors "$errors" \
      --argjson serious "$serious" --argjson consistent "$consistent" --argjson seconds "$dur" \
      --arg server "$("$PSQL" -X -At "$ADMIN_URL" -c 'show server_version')" \
      --arg error_sample "$(head -c 1500 "$DIR/restore-errors.log")" \
  '{stamp: $stamp, restored_into: ("PostgreSQL " + $server), seconds: $seconds, consistent_counts: $consistent,
    pg_restore_errors: $errors, pg_restore_errors_about_tables: $serious, error_sample: $error_sample} + $compare + {reads: $reads}' > "$DIR/restore-report.json"
cat "$DIR/restore-report.json"
if $KEEP && [ -n "$SCRATCH" ]; then say "kept: $URL"; fi

# ---------------------------------------------------------------- verdict
jq -e '.missing | length == 0' "$DIR/restore-report.json" > /dev/null || bad "tables missing after the restore: $(jq -c .missing "$DIR/restore-report.json")"
[ "$serious" = 0 ] || bad "pg_restore errors about tables or their data: $(head -c 600 "$DIR/restore-serious.log")"
if [ "$consistent" = true ]; then
  jq -e '.different | length == 0' "$DIR/restore-report.json" > /dev/null || bad "row counts differ: $(jq -c '.different[:10]' "$DIR/restore-report.json")"
fi
jq -e '.reads.migrations > 0 and .reads.settings_cap > 0' "$DIR/restore-report.json" > /dev/null || bad "the app's reads failed after the restore"
note "restore of nightly/$STAMP: $(jq -r '"\(.matched) of \(.tables) tables with the same row count, \(.rows_restored) rows, \(.reads.migrations) migrations, \(.reads.policies) policies, \(.reads.functions_app) app functions, \(.pg_restore_errors) expected pg_restore errors (Supabase-only objects), \(.seconds) s"' "$DIR/restore-report.json")"
