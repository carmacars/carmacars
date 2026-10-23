#!/usr/bin/env bash
# The full copy of the hosted Supabase project to the company's server (the vps-copy workflow runs the steps in this
# order; each can be run again). The hosted project is only read: SQL selects through the Management API, pg_dump
# through the session pooler, file downloads through the Storage API. Secret values are never printed.
#
#   copy.sh preflight   versions, sizes, extensions; refuses when the server is already live
#   copy.sh dump        supabase db dump: roles, schema, data (COPY) of the hosted database
#   copy.sh reset       the server's database starts over empty (bin/db-reset; refused when live)
#   copy.sh restore     extensions, roles + schema, then the data fitted to the server's schema (filter-data.py) with
#                       session_replication_role = replica, the reserved roles' settings (anon's statement timeout...)
#   copy.sh migrations  the migration history (supabase_migrations; the CLI's data dump leaves it out); part of restore
#   copy.sh vault       every vault secret re-created from its decrypted value, so it decrypts with the server's key
#   copy.sh cron        every pg_cron job re-created PAUSED, the Edge Function address changed to the server's Kong;
#                       the hosted jobs' states are kept on the server for the cutover (state/cron-hosted.json)
#   copy.sh auth        the hosted Auth settings (config/auth) into the server's GoTrue (auth.env, templates)
#   copy.sh functions   the three Edge Functions and their secrets (scripts/deploy/supabase.sh fnsync)
#   copy.sh storage     every stored file not already on the server with the same size (bucket by bucket)
#   copy.sh basebackup  a wal-g base backup of the copy (when the backup bucket is configured)
#   copy.sh verify      row counts table by table, vault, cron, Auth, Storage, functions and RPC answers compared
#
# Env: SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF, SUPABASE_DB_PASSWORD (dump), VPS_SSH_KEY; COPY_DIR (work folder,
# default $RUNNER_TEMP/copy); SKIP_BUCKETS (space separated, default "backups"); COPY_MODE rehearsal|final (final:
# hosted and server counts must match exactly; the hosted project is frozen by then).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../../scripts/deploy/vps.sh
. "$ROOT/scripts/deploy/vps.sh"
: "${SUPABASE_ACCESS_TOKEN:?}" "${SUPABASE_PROJECT_REF:?}"
REF="$SUPABASE_PROJECT_REF"
HAPI="https://api.supabase.com/v1/projects/$REF"
HURL="https://$REF.supabase.co"
W="${COPY_DIR:-${RUNNER_TEMP:-/tmp}/copy}"
mkdir -p "$W"; chmod 700 "$W"
SKIP_BUCKETS="${SKIP_BUCKETS:-backups}"
COPY_MODE="${COPY_MODE:-rehearsal}"
APP_SCHEMAS="public app supabase_migrations"

say() { echo "[copy] $*"; }
note() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=copy::$*"; else echo "NOTICE: $*"; fi; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning title=copy::$*"; else echo "WARNING: $*"; fi; }
die() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=copy::$*"; else echo "ERROR: $*"; fi; exit 1; }
mask() { if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$1" ]; then echo "::add-mask::$1" >&2; fi; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >> "$GITHUB_STEP_SUMMARY"; else cat; fi; }
tag() { echo "q$(openssl rand -hex 6)"; }

# ---------------------------------------------------------------- the hosted project (read only)
hq_file() {
  local body out code
  body=$(mktemp); out=$(mktemp)
  jq -Rs '{query: .}' < "$1" > "$body"
  code=$(curl -sS -o "$out" -w '%{http_code}' --max-time 600 -X POST "$HAPI/database/query" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'content-type: application/json' --data-binary @"$body") || code=000
  rm -f "$body"
  if [ "${code:0:1}" != 2 ]; then echo "hosted SQL failed ($code): $(head -c 800 "$out")" >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}
hq() { local f; f=$(mktemp); printf '%s' "$1" > "$f"; local rc=0; hq_file "$f" || rc=$?; rm -f "$f"; return $rc; }
hapi() { curl -sS -f --max-time 60 "$HAPI$1" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN"; }
hkey() {
  if [ -z "${HKEY:-}" ]; then
    local k; k=$(hapi "/api-keys?reveal=true")
    HKEY=$(jq -r '[.[] | select(.name == "service_role")][0].api_key // empty' <<<"$k")
    HANON=$(jq -r '[.[] | select(.name == "anon")][0].api_key // empty' <<<"$k")
    [ -n "$HKEY" ] && [ -n "$HANON" ] || die "no service_role or anon key from the hosted project"
    mask "$HKEY"; mask "$HANON"
  fi
}
hdb_url() {
  [ -n "${SUPABASE_DB_PASSWORD:-}" ] || die "SUPABASE_DB_PASSWORD (repository secret) is needed to dump the hosted database"
  local pool host user enc
  pool=$(hapi "/config/database/pooler")
  host=$(jq -r '[.[] | select(.database_type == "PRIMARY")][0].db_host' <<<"$pool")
  user=$(jq -r '[.[] | select(.database_type == "PRIMARY")][0].db_user' <<<"$pool")
  enc=$(jq -rn --arg p "$SUPABASE_DB_PASSWORD" '$p|@uri'); mask "$enc"
  printf 'postgresql://%s:%s@%s:5432/postgres' "$user" "$enc" "$host"
}
# the server, as postgres (owner of the app's objects, as on the hosted project) and as supabase_admin
vdb_url() {
  local pw; pw=$(vps_secret POSTGRES_PASSWORD)
  printf 'postgresql://%s:%s@127.0.0.1:%s/postgres' "${1:-postgres}" "$(jq -rn --arg p "$pw" '$p|@uri')" "$VPS_PG_PORT"
}
vkey() { if [ -z "${VKEY:-}" ]; then VKEY=$(vps_secret SERVICE_ROLE_KEY); VANON=$(vps_secret ANON_KEY); fi; }
VURL="http://127.0.0.1:$VPS_KONG_PORT"

refuse_if_live() { if vps_is_live; then die "the server is the live backend (state/live): a copy would overwrite new data; refused"; fi; }

# row counts of every base table of the app's and the services' schemas (the same query on both sides)
COUNTS_SQL="select coalesce(json_object_agg(t.table_schema || '.' || t.table_name,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', t.table_schema, t.table_name), false, true, '')))[1]::text::bigint
  order by t.table_schema, t.table_name), '{}') as counts from information_schema.tables t
  where t.table_type = 'BASE TABLE' and t.table_schema in ('public', 'app', 'auth', 'storage', 'supabase_migrations')"

# ---------------------------------------------------------------- steps
preflight() {
  vps_tunnel
  refuse_if_live
  local ver size exts
  ver=$(hapi "" | jq -r '.database.version // "?"')
  size=$(hq "select pg_database_size('postgres') as b" | jq -r '.[0].b')
  exts=$(hq "select e.extname as name, e.extversion as version, n.nspname as schema from pg_extension e join pg_namespace n on n.oid = e.extnamespace order by 1")
  printf '%s' "$exts" > "$W/extensions.json"
  hq "select bucket_id, count(*) as objects, coalesce(sum((metadata->>'size')::bigint), 0) as bytes from storage.objects group by 1 order by 1" > "$W/buckets.json"
  local vimg vfree
  vimg=$(vps_ssh "sudo docker inspect -f '{{.Config.Image}}' supabase-db" 2>/dev/null || echo "not running")
  vfree=$(vps_ssh "df -B1 --output=avail / | tail -n 1")
  [ "$vfree" -gt $(( size * 4 + 5 * 1024 * 1024 * 1024 )) ] || die "the server has $((vfree / 1024 / 1024)) MB free; the database is $((size / 1024 / 1024)) MB"
  { echo "### Copy preflight ($COPY_MODE)"; echo
    echo "- hosted Postgres $ver, database $((size / 1024 / 1024)) MB, $(jq length "$W/extensions.json") extensions"
    echo "- server: $vimg, $((vfree / 1024 / 1024 / 1024)) GB free"
    echo "- stored files: $(jq -r 'map("\(.bucket_id) \(.objects) (\(.bytes | tonumber / 1048576 | floor) MB)") | join(", ")' "$W/buckets.json"); skipped: ${SKIP_BUCKETS:-none}"
  } | summary
  [[ "$ver" == 17.* ]] || die "the hosted project runs Postgres $ver; the server runs 17"
  case "$vimg" in *postgres:17.*) ;; *) die "the server's database container is not Postgres 17 ($vimg); run vps-provision first" ;; esac
}

dump() {
  command -v supabase > /dev/null || die "the Supabase CLI is not installed"
  local url t0; url=$(hdb_url); t0=$(date +%s)
  rm -f "$W/roles.sql" "$W/schema.sql" "$W/data.sql"
  supabase db dump --db-url "$url" -f "$W/roles.sql" --role-only > /dev/null
  supabase db dump --db-url "$url" -f "$W/schema.sql" > /dev/null
  supabase db dump --db-url "$url" -f "$W/data.sql" --use-copy --data-only > /dev/null
  for f in roles schema data; do [ -s "$W/$f.sql" ] || [ "$f" = roles ] || die "$f.sql is empty"; done
  note "dump: roles $(wc -c < "$W/roles.sql") B, schema $(wc -c < "$W/schema.sql") B, data $(( $(wc -c < "$W/data.sql") / 1024 / 1024 )) MB in $(( $(date +%s) - t0 )) s ($(supabase --version))"
  # the hosted counts right after the dump (exact when the project is frozen: COPY_MODE=final)
  hq "$COUNTS_SQL" | jq '.[0].counts | (if type == "string" then fromjson else . end) | map_values(tonumber)' > "$W/hosted-counts.json"
}

reset() {
  refuse_if_live
  vps_ssh sudo /opt/carmacars/bin/db-reset --yes | tail -n 12
  note "reset: the server's database was started over empty"
}

restore() {
  vps_tunnel
  refuse_if_live
  local pg admin t0; pg=$(vdb_url postgres); admin=$(vdb_url supabase_admin); t0=$(date +%s)
  mask "$pg"; mask "$admin"
  [ -s "$W/extensions.json" ] || hq "select e.extname as name, e.extversion as version, n.nspname as schema from pg_extension e join pg_namespace n on n.oid = e.extnamespace order by 1" > "$W/extensions.json"
  # 1. the hosted project's extensions, in the same schemas (Supabase's restore guide, step 3)
  local name schema sql
  while IFS=$'\t' read -r name schema; do
    [ "$name" = plpgsql ] && continue
    # pg_cron and the like live in pg_catalog, which is no schema to name (their control file decides)
    if [[ "$schema" == pg_* ]]; then sql="create extension if not exists \"$name\" cascade"
    else sql="create schema if not exists \"$schema\"; create extension if not exists \"$name\" with schema \"$schema\" cascade"; fi
    if ! psql "$admin" -X -q -v ON_ERROR_STOP=1 -c "$sql" > /dev/null 2> "$W/ext.err"; then
      warn "extension $name ($schema) could not be created on the server: $(head -c 300 "$W/ext.err")"
    fi
  done < <(jq -r '.[] | [.name, .schema] | @tsv' "$W/extensions.json")
  psql "$pg" -X -q -v ON_ERROR_STOP=1 -c "create schema if not exists supabase_migrations;
    create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);" > /dev/null
  # 2. the hosted project's own roles (as supabase_admin: the file also sets reserved roles' options; a refusal is
  #    reported, not fatal), then the schema in one transaction as postgres (the owner, as on the hosted project)
  psql "$admin" -X -q -f "$W/roles.sql" > /dev/null 2> "$W/roles.err" || true
  if grep -q 'ERROR' "$W/roles.err"; then warn "roles.sql: $(grep 'ERROR' "$W/roles.err" | head -n 5 | tr '\n' ' ')"; fi
  psql "$pg" -X -q -v ON_ERROR_STOP=1 --single-transaction -f "$W/schema.sql" > "$W/schema.out" 2> "$W/schema.err" \
    || { grep -v 'supautils' "$W/schema.err" | tail -n 20 >&2; die "restoring the schema failed (above); nothing of it was kept"; }
  # 3. the data, fitted to the server's tables, one transaction with triggers off
  vps_sql "select json_build_object(
      'tables', (select json_object_agg(c.table_schema || '.' || c.table_name, c.cols) from
                 (select table_schema, table_name, json_agg(column_name::text order by ordinal_position) as cols
                    from information_schema.columns where table_schema not in ('pg_catalog', 'information_schema') group by 1, 2) c),
      'sequences', (select coalesce(json_agg(sequence_schema || '.' || sequence_name), '[]') from information_schema.sequences)) as t" \
    | jq '.[0].t | if type == "string" then fromjson else . end' > "$W/target.json"
  python3 -I "$HERE/filter-data.py" "$W/data.sql" "$W/target.json" "$W/data.fit.sql" "$W/filter.json"
  local missing
  missing=$(jq -r --arg s "$APP_SCHEMAS" '.missing_on_server | keys[] | select((split(".")[0]) as $x | ($s | split(" ") | index($x)))' "$W/filter.json")
  [ -z "$missing" ] || die "the server has no table for: $(tr '\n' ' ' <<<"$missing") (the schema restore did not create them)"
  psql "$pg" -X -q -v ON_ERROR_STOP=1 --single-transaction -c 'SET session_replication_role = replica' -f "$W/data.fit.sql" > /dev/null 2> "$W/data.err" \
    || { grep -v '^psql:.*NOTICE' "$W/data.err" | tail -n 10 >&2; die "loading the data failed (above); the data part was rolled back"; }
  migrations
  # 4. settings of the reserved roles and the database (pg_dump does not carry them): anon's statement timeout...
  hq "select coalesce(r.rolname, '') as role, unnest(s.setconfig) as setting from pg_db_role_setting s
        left join pg_roles r on r.oid = s.setrole
       where s.setdatabase in (0, (select oid from pg_database where datname = 'postgres'))
         and (r.rolname in ('anon', 'authenticated', 'service_role', 'authenticator', 'postgres') or s.setrole = 0)" > "$W/role-settings.json"
  local role setting key val n=0 failed=0 left=()
  while IFS=$'\t' read -r role setting; do
    key="${setting%%=*}"; val="${setting#*=}"
    # never the hosted project's freeze, nor what docker-compose.yml sets
    case "$key" in default_transaction_read_only|app.settings.jwt_exp|app.settings.jwt_secret) continue ;; esac
    # single values only (timeouts, PostgREST's pgrst.*, the app's app.*); list settings such as search_path or
    # session_preload_libraries keep the image's Supabase defaults and are listed for a look
    if ! [[ "$key" =~ ^(statement_timeout|lock_timeout|idle_in_transaction_session_timeout|idle_session_timeout|work_mem|temp_file_limit|pgrst\.[a-z_.]+|app\.[a-z_.]+)$ ]]; then
      left+=("${role:-database}: $key"); continue
    fi
    local t; t=$(tag)
    if [ -n "$role" ]; then stmt="alter role \"$role\" set $key = \$$t\$$val\$$t\$"; else stmt="alter database postgres set $key = \$$t\$$val\$$t\$"; fi
    if psql "$admin" -X -q -v ON_ERROR_STOP=1 -c "$stmt" > /dev/null 2> "$W/set.err"; then n=$((n + 1))
    else failed=$((failed + 1)); warn "could not set $key for ${role:-the database}: $(head -c 200 "$W/set.err")"; fi
  done < <(jq -r '.[] | [.role, .setting] | @tsv' "$W/role-settings.json")
  psql "$admin" -X -q -c "notify pgrst, 'reload config'; notify pgrst, 'reload schema'" > /dev/null || true
  psql "$admin" -X -q -c "vacuum analyze" > /dev/null 2>&1 || warn "vacuum analyze did not finish"
  local f; f="$W/filter.json"
  { echo "### Restore"; echo
    echo "- $(jq .tables_copied "$f") tables, $(jq .rows_copied "$f") rows loaded in $(( $(date +%s) - t0 )) s; $n role/database settings copied, $failed failed"
    echo "- role settings left to the image's defaults (compare by hand): ${left[*]:-none}"
    echo "- left to their own step: $(jq -r '.skipped_by_rule | to_entries | map("\(.key) (\(.value))") | join(", ")' "$f")"
    echo "- tables the server does not have (Auth/Storage versions): $(jq -r '.missing_on_server | to_entries | map("\(.key) (\(.value) rows)") | join(", ") | if . == "" then "none" else . end' "$f")"
    echo "- columns dropped (the hosted Auth/Storage is newer): $(jq -r '.columns_dropped | to_entries | map("\(.key): \(.value | join(" "))") | join("; ") | if . == "" then "none" else . end' "$f")"
  } | tee "$W/restore-summary.md" | summary
  note "restore: $(grep '^- ' "$W/restore-summary.md" | sed 's/^- //' | paste -sd ';' - | cut -c1-3500)"
  jq -e '.columns_dropped | length == 0' "$f" > /dev/null || warn "some columns of the hosted project were dropped (see the summary); check them before the cutover"
}

migrations() {
  vps_tunnel
  # 3b. the migration history (the CLI's data dump leaves supabase_migrations out; without it the deploy would run every
  #     migration after the baseline again)
  local t mig; t=$(tag); mig=$(mktemp)
  hq "select coalesce(json_agg(m), '[]') as m from supabase_migrations.schema_migrations m" \
    | jq -r --arg t "$t" '.[0].m | (if type == "string" then fromjson else . end) | tojson as $j
        | ("$" + $t + "$") as $d | if ($j | contains($d)) then error("tag") else
          "insert into supabase_migrations.schema_migrations select * from json_populate_recordset(null::supabase_migrations.schema_migrations, \($d)\($j)\($d)::json) on conflict (version) do nothing;" end' > "$mig"
  vps_sql_file "$mig" > /dev/null || { rm -f "$mig"; die "copying the migration history failed"; }
  rm -f "$mig"
  local mh mv
  mh=$(hq "select count(*) as n from supabase_migrations.schema_migrations" | jq -r '.[0].n | tostring')
  mv=$(vps_sql "select count(*) as n from supabase_migrations.schema_migrations" | jq -r '.[0].n | tostring')
  [ "$mh" = "$mv" ] || die "migration history: $mh rows on the hosted project, $mv on the server"
  note "migrations: $mv rows of history copied"
}

vault() {
  vps_tunnel
  local n_h out t
  ( umask 077; hq "select coalesce(json_agg(json_build_object('name', name, 'description', coalesce(description, ''), 'secret', decrypted_secret)), '[]') as s
                   from vault.decrypted_secrets" | jq '.[0].s | if type == "string" then fromjson else . end' > "$W/vault.json" )
  n_h=$(jq 'length' "$W/vault.json")
  jq -e 'all(.[]; .secret != null)' "$W/vault.json" > /dev/null || die "some hosted vault secrets did not decrypt"
  # one SQL file: upsert by name (vault.create_secret / update_secret); every value dollar-quoted with a tag of its own
  # (a random prefix and its index; refused if a value contains its tag). Built by jq: no value on a command line.
  t=$(tag)
  ( umask 077; jq -r --arg t "$t" '
      def q($i; $v): ("$" + $t + "_" + ($i | tostring) + "$") as $d | if ($v | contains($d)) then error("tag collision") else $d + $v + $d end;
      "do " + q("o"; ([to_entries[] |
        if (.value.name // "") != "" then
          "select id into s from vault.secrets where name = \(q(.key; .value.name)); if s is null then perform vault.create_secret(\(q(.key; .value.secret)), \(q(.key; .value.name)), \(q(.key; .value.description))); else perform vault.update_secret(s, \(q(.key; .value.secret)), \(q(.key; .value.name)), \(q(.key; .value.description))); end if;"
        else "perform vault.create_secret(\(q(.key; .value.secret)), null, \(q(.key; .value.description)));" end] | "declare s uuid; begin " + join(" ") + " end")) + ";"
    ' "$W/vault.json" > "$W/vault.sql" ) || { rm -f "$W/vault.json" "$W/vault.sql"; die "could not build the vault SQL"; }
  vps_sql_file "$W/vault.sql" > /dev/null || { rm -f "$W/vault.sql" "$W/vault.json"; die "writing the vault on the server failed"; }
  out=$(vps_sql "select count(*) as n, count(*) filter (where decrypted_secret is not null) as ok,
                        coalesce(json_agg(name order by name) filter (where name is not null), '[]') as names from vault.decrypted_secrets")
  local names_h; names_h=$(jq -c '[.[].name | select(. != null)] | sort' "$W/vault.json")
  rm -f "$W/vault.sql" "$W/vault.json"
  [ "$(jq -c '.[0].names | sort' <<<"$out")" = "$names_h" ] || die "the vault names on the server differ from the hosted project's"
  [ "$(jq -r '.[0].ok | tostring' <<<"$out")" = "$(jq -r '.[0].n | tostring' <<<"$out")" ] || die "some vault secrets on the server do not decrypt"
  note "vault: $n_h secrets re-created on the server; all decrypt with the server's key"
}

cron() {
  vps_tunnel
  local jobs n sqlf t rewritten
  jobs=$(hq "select coalesce(json_agg(json_build_object('jobname', jobname, 'schedule', schedule, 'command', command, 'active', active) order by jobid), '[]') as j from cron.job" | jq '.[0].j | if type == "string" then fromjson else . end')
  printf '%s' "$jobs" | vps_ssh "sudo sh -c 'umask 077; cat > /opt/carmacars/state/cron-hosted.json'"
  n=$(jq 'length' <<<"$jobs")
  sqlf=$(mktemp)
  rewritten=$(jq --arg from "$HURL/functions/v1/" '[.[] | select(.command | contains($from))] | length' <<<"$jobs")
  # remove what an earlier run made, then every hosted job, paused, in one transaction (never seen active); the
  # Edge Function address becomes the server's Kong on the Docker network
  t=$(tag)
  jq -r --arg t "$t" --arg from "$HURL/functions/v1/" --arg to "http://kong:8000/functions/v1/" '
      def q($i; $v): ("$" + $t + "_" + ($i | tostring) + "$") as $d | if ($v | contains($d)) then error("tag collision") else $d + $v + $d end;
      "select cron.unschedule(jobid) from cron.job;",
      (to_entries[] | (.value.command | split($from) | join($to)) as $cmd |
        if (.value.jobname // "") != "" then "select cron.alter_job(cron.schedule(\(q(.key; .value.jobname)), \(q(.key; .value.schedule)), \(q(.key; $cmd))), active := false);"
        else "select cron.alter_job(cron.schedule(\(q(.key; .value.schedule)), \(q(.key; $cmd))), active := false);" end)
    ' <<<"$jobs" > "$sqlf"
  vps_sql_file "$sqlf" > /dev/null || { rm -f "$sqlf"; die "re-creating the pg_cron jobs on the server failed"; }
  rm -f "$sqlf"
  local v; v=$(vps_sql "select count(*) as n, count(*) filter (where active) as active,
                               coalesce(json_agg(jobname) filter (where command like '%supabase.co%'), '[]') as hosted_urls from cron.job")
  [ "$(jq -r '.[0].n | tostring' <<<"$v")" = "$n" ] || die "the server has $(jq -r '.[0].n | tostring' <<<"$v") pg_cron jobs, the hosted project $n"
  [ "$(jq -r '.[0].active | tostring' <<<"$v")" = 0 ] || die "some pg_cron jobs on the server are active before the cutover"
  [ "$(jq '.[0].hosted_urls | length' <<<"$v")" = 0 ] || warn "jobs that still name a supabase.co address: $(jq -c '.[0].hosted_urls' <<<"$v")"
  note "cron: $n jobs re-created paused on the server ($rewritten call an Edge Function, now through the server's Kong); the hosted states are kept for the cutover"
}

auth() {
  vps_tunnel
  local host
  ( umask 077; hapi "/config/auth" > "$W/auth-config.json" )
  # what the API does not show back: the SMTP password (Resend: the deploy_resend_api_key in the vault) and the SMS
  # hook's signing secret (deploy_auth_sms_hook_secret), from the server's vault (copied by the vault step)
  host=$(jq -r '.smtp_host // ""' "$W/auth-config.json")
  if ! jq -e '.smtp_pass // "" | test("^[^*]+$")' "$W/auth-config.json" > /dev/null && [[ "$host" == *resend* ]]; then
    local k; k=$(vps_sql "select decrypted_secret as v from vault.decrypted_secrets where name = 'deploy_resend_api_key'" | jq -r '.[0].v // empty'); mask "$k"
    if [ -n "$k" ]; then jq --arg k "$k" '.smtp_pass = $k' "$W/auth-config.json" > "$W/a.tmp" && mv "$W/a.tmp" "$W/auth-config.json"; else warn "no SMTP password: Auth emails will fail until deploy_resend_api_key is in the vault"; fi
  fi
  if jq -e '.hook_send_sms_enabled == true and ((.hook_send_sms_secrets // "") | test("^v1,whsec_") | not)' "$W/auth-config.json" > /dev/null; then
    local s; s=$(vps_sql "select decrypted_secret as v from vault.decrypted_secrets where name = 'deploy_auth_sms_hook_secret'" | jq -r '.[0].v // empty'); mask "$s"
    if [ -n "$s" ]; then jq --arg s "$s" '.hook_send_sms_secrets = $s' "$W/auth-config.json" > "$W/a.tmp" && mv "$W/a.tmp" "$W/auth-config.json"; else warn "the Send SMS hook is on but its secret is not in the vault (deploy_auth_sms_hook_secret)"; fi
  fi
  jq --arg u "$VPS_API_URL" '. + {__api_external_url: $u}' "$W/auth-config.json" > "$W/a.tmp" && mv "$W/a.tmp" "$W/auth-config.json"
  local out; out=$(mktemp -d); chmod 700 "$out"
  node "$HERE/auth-env.mjs" --out "$out" < "$W/auth-config.json" > "$W/auth-render.json"
  cp "$W/auth-config.json" "$out/auth-config.json"
  tar -C "$out" -cf - . | vps_ssh sudo /opt/carmacars/bin/auth-config apply > /dev/null
  rm -rf "$out" "$W/auth-config.json"
  local iss; iss=$(curl -sS --max-time 20 "$VURL/auth/v1/.well-known/openid-configuration" | jq -r '.issuer // empty' || true)
  [ "$iss" = "$VPS_API_URL/auth/v1" ] || warn "Auth's issuer is '$iss', expected $VPS_API_URL/auth/v1 (web/src/lib/auth/jwt-verify.ts checks it)"
  note "auth: $(jq -r '"\(.carried) settings and \(.templates | length) templates carried; not carried: \(.not_carried | if length == 0 then "none" else join(", ") end)"' "$W/auth-render.json"); issuer $iss"
}

functions() {
  DB_BACKEND=vps APP_URL="${APP_URL:-https://carmacars.ca}" "$ROOT/scripts/deploy/supabase.sh" fnsync
}

storage() {
  vps_tunnel; hkey; vkey
  local list skip b
  skip=$(printf '%s\n' $SKIP_BUCKETS | jq -R . | jq -sc 'map(select(length > 0))')
  hq "select bucket_id as b, name as n, coalesce((metadata->>'size')::bigint, 0) as s, coalesce(metadata->>'mimetype', 'application/octet-stream') as m,
             coalesce(metadata->>'cacheControl', 'max-age=3600') as c from storage.objects order by 1, 2" \
    | jq -r --argjson skip "$skip" '.[] | select(.b as $b | $skip | index($b) | not) | [.b, .n, (.s | tostring), .m, .c] | @tsv' > "$W/objects.tsv"
  list="$W/objects.tsv"
  # buckets: the rows came with the data; make sure each hosted bucket exists on the server with the same settings
  for b in $(hq "select id from storage.buckets order by 1" | jq -r '.[].id'); do
    curl -sS -f -o /dev/null "$VURL/storage/v1/bucket/$b" -H "Authorization: Bearer $VKEY" -H "apikey: $VKEY" || die "bucket $b is missing on the server after the restore"
  done
  export HKEY VKEY HURL VURL W
  # shellcheck disable=SC2016
  local script='
    set -u
    b="$1"; n="$2"; s="$3"; m="$4"; c="$5"
    p=$(jq -rn --arg n "$n" '"'"'$n | split("/") | map(@uri) | join("/")'"'"')
    # the first byte, read from the file itself (a HEAD answers from the database row even when the file is missing)
    if [ "$s" != 0 ]; then
      have=$(curl -sS -o /dev/null -r 0-0 -w "%{http_code} %header{content-range}" "$VURL/storage/v1/object/authenticated/$b/$p" -H "Authorization: Bearer $VKEY" -H "apikey: $VKEY" 2>/dev/null || echo "000 x")
      if [ "${have%% *}" = 206 ] && [ "${have##*/}" = "$s" ]; then echo "skip"; exit 0; fi
    fi
    f=$(mktemp -p "$W")
    if ! curl -sS -f -o "$f" "$HURL/storage/v1/object/authenticated/$b/$p" -H "Authorization: Bearer $HKEY" -H "apikey: $HKEY"; then rm -f "$f"; echo "fail download $b/$n" ; exit 0; fi
    code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$VURL/storage/v1/object/$b/$p" -H "Authorization: Bearer $VKEY" -H "apikey: $VKEY" \
      -H "content-type: $m" -H "cache-control: $c" -H "x-upsert: true" --data-binary "@$f")
    rm -f "$f"
    case "$code" in 2*) echo "copied" ;; *) echo "fail upload($code) $b/$n" ;; esac'
  local t0; t0=$(date +%s)
  tr '\t' '\n' < "$list" | xargs -d '\n' -n 5 -P 8 bash -c "$script" _ > "$W/storage.log"
  local copied skipped failed
  copied=$(grep -c '^copied' "$W/storage.log" || true); skipped=$(grep -c '^skip' "$W/storage.log" || true); failed=$(grep -c '^fail' "$W/storage.log" || true)
  { echo "### Storage"; echo; echo "- $(wc -l < "$list") objects (buckets skipped: ${SKIP_BUCKETS:-none}): $copied copied, $skipped already there, $failed failed, $(( $(date +%s) - t0 )) s"; } | summary
  if [ "$failed" != 0 ]; then grep '^fail' "$W/storage.log" | head -n 20 >&2; die "$failed stored files could not be copied"; fi
  note "storage: $copied copied, $skipped already on the server"
}

verify() {
  vps_tunnel; vkey; hkey
  local problems=() infos=()
  # 1. every table: server rows == rows in the dump (proves the restore); and == the hosted project now (exact in final)
  vps_sql "$COUNTS_SQL" | jq '.[0].counts | (if type == "string" then fromjson else . end) | map_values(tonumber)' > "$W/vps-counts.json"
  hq "$COUNTS_SQL" | jq '.[0].counts | (if type == "string" then fromjson else . end) | map_values(tonumber)' > "$W/hosted-counts-now.json"
  local vs_dump vs_hosted
  [ -f "$W/filter.json" ] || echo '{"rows": {}}' > "$W/filter.json"   # verify alone: no dump to compare with
  vs_dump=$(jq -n --slurpfile v "$W/vps-counts.json" --slurpfile f "$W/filter.json" '[$f[0].rows | to_entries[] | select(($v[0][.key] // -1) != .value) | {table: .key, dump: .value, server: ($v[0][.key] // null)}]')
  vs_hosted=$(jq -n --slurpfile v "$W/vps-counts.json" --slurpfile h "$W/hosted-counts-now.json" '[$h[0] | to_entries[] | select(.key | test("^(auth\\.schema_migrations|storage\\.migrations)$") | not) | select(($v[0][.key] // 0) != .value) | {table: .key, hosted: .value, server: ($v[0][.key] // null)}]')
  printf '%s' "$vs_dump" > "$W/diff-dump.json"; printf '%s' "$vs_hosted" > "$W/diff-hosted.json"
  [ "$(jq length <<<"$vs_dump")" = 0 ] || problems+=("$(jq length <<<"$vs_dump") tables differ from the dump: $(jq -c '.[:8]' <<<"$vs_dump")")
  # sign-ins keep writing these on the hosted project when only the database API could be frozen (cutover.sh)
  local churn='^auth\.(refresh_tokens|sessions|audit_log_entries|flow_state|one_time_tokens|mfa_challenges|mfa_amr_claims)$'
  if [ "$COPY_MODE" = final ] && [ "$(jq --arg c "$churn" '[.[] | select(.table | test($c))] | length' <<<"$vs_hosted")" != 0 ]; then
    infos+=("sign-in tables changed on the hosted project after the dump: $(jq -c --arg c "$churn" '[.[] | select(.table | test($c)) | .table]' <<<"$vs_hosted") (people signed in during the copy sign in again)")
    vs_hosted=$(jq -c --arg c "$churn" '[.[] | select(.table | test($c) | not)]' <<<"$vs_hosted")
  fi
  if [ "$(jq length <<<"$vs_hosted")" != 0 ]; then
    if [ "$COPY_MODE" = final ]; then problems+=("$(jq length <<<"$vs_hosted") tables differ from the frozen hosted project: $(jq -c '.[:8]' <<<"$vs_hosted")")
    else infos+=("$(jq length <<<"$vs_hosted") tables changed on the hosted project since the dump (expected while it is live): $(jq -c '[.[:6][] | .table]' <<<"$vs_hosted")"); fi
  fi
  # 2. vault, cron
  local vh vv ch cv
  vh=$(hq "select count(*) as n from vault.secrets" | jq -r '.[0].n | tostring'); vv=$(vps_sql "select count(*) filter (where decrypted_secret is not null) as n from vault.decrypted_secrets" | jq -r '.[0].n | tostring')
  [ "$vh" = "$vv" ] || problems+=("vault: $vh secrets on the hosted project, $vv decryptable on the server")
  ch=$(hq "select count(*) as n from cron.job" | jq -r '.[0].n | tostring'); cv=$(vps_sql "select count(*) as n, count(*) filter (where active) as a from cron.job")
  [ "$ch" = "$(jq -r '.[0].n | tostring' <<<"$cv")" ] || problems+=("cron: $ch jobs on the hosted project, $(jq -r '.[0].n | tostring' <<<"$cv") on the server")
  if ! vps_is_live && [ "$(jq -r '.[0].a | tostring' <<<"$cv")" != 0 ]; then problems+=("cron: $(jq -r '.[0].a | tostring' <<<"$cv") jobs active on the server before the cutover"); fi
  # 3. the same answers from the database API (anon) and the same Auth settings
  local rpc hh vh2
  rpc_sig() { # base key rpc -> "code sha"
    local o c; o=$(mktemp)
    c=$(curl -sS -o "$o" -w '%{http_code}' --max-time 20 -X POST "$1/rest/v1/rpc/$3" -H "apikey: $2" -H "Authorization: Bearer $2" -H 'content-type: application/json' -d '{}' || echo 000)
    printf '%s %s' "$c" "$( (jq -S -c . "$o" 2>/dev/null || cat "$o") | sha256sum | cut -c1-16)"; rm -f "$o"
  }
  for rpc in site_settings_public chauffeur_services; do
    hh=$(rpc_sig "$HURL" "$HANON" "$rpc"); vh2=$(rpc_sig "$VURL" "$VANON" "$rpc")
    if [ "$hh" = "$vh2" ]; then infos+=("rpc $rpc: same answer (HTTP ${hh%% *})"); else problems+=("rpc $rpc: the answers differ (hosted HTTP ${hh%% *}, server HTTP ${vh2%% *})"); fi
  done
  hh=$(curl -sS --max-time 20 "$HURL/auth/v1/settings" -H "apikey: $HANON" | jq -S -c '{external, disable_signup, mailer_autoconfirm, phone_autoconfirm, sms_provider}')
  vh2=$(curl -sS --max-time 20 "$VURL/auth/v1/settings" -H "apikey: $VANON" | jq -S -c '{external, disable_signup, mailer_autoconfirm, phone_autoconfirm, sms_provider}')
  if [ "$hh" = "$vh2" ]; then infos+=("auth settings: same"); else problems+=("auth settings differ: hosted $hh, server $vh2"); fi
  # 4. buckets, functions
  hh=$(curl -sS "$HURL/storage/v1/bucket" -H "Authorization: Bearer $HKEY" -H "apikey: $HKEY" | jq -S -c 'map({id, public}) | sort_by(.id)')
  vh2=$(curl -sS "$VURL/storage/v1/bucket" -H "Authorization: Bearer $VKEY" -H "apikey: $VKEY" | jq -S -c 'map({id, public}) | sort_by(.id)')
  [ "$hh" = "$vh2" ] || problems+=("buckets differ: hosted $hh, server $vh2")
  local fn code
  for fn in send-outbox owner-debit calendar-sync; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$VURL/functions/v1/$fn" || true)
    [ "$code" = 403 ] || problems+=("function $fn without a token answered $code (403 expected)")
  done
  # 5. two-step sign-in: TOTP secrets readable without the hosted project's key?
  local totp; totp=$(vps_sql "select count(*) as n, count(*) filter (where secret like '{%') as enc from auth.mfa_factors where factor_type = 'totp'")
  [ "$(jq -r '.[0].enc | tostring' <<<"$totp")" = 0 ] || problems+=("$(jq -r '.[0].enc | tostring' <<<"$totp") of $(jq -r '.[0].n | tostring' <<<"$totp") TOTP factors are stored encrypted with the hosted project's key: those people must enrol their authenticator again")
  infos+=("TOTP factors: $(jq -r '.[0].n | tostring' <<<"$totp")")
  { echo "### Verify ($COPY_MODE)"; echo
    echo "- tables: $(jq length "$W/vps-counts.json") on the server, $(jq '.rows | length' "$W/filter.json") loaded from the dump"
    for i in "${infos[@]}"; do echo "- $i"; done
    if [ "${#problems[@]}" = 0 ]; then echo; echo "**No problems found.**"; else echo; echo "**Problems:**"; for p in "${problems[@]}"; do echo "- $p"; done; fi
  } | summary
  jq -n --arg mode "$COPY_MODE" --argjson problems "$(printf '%s\n' "${problems[@]:-}" | jq -R 'select(length > 0)' | jq -sc .)" \
    --argjson infos "$(printf '%s\n' "${infos[@]:-}" | jq -R 'select(length > 0)' | jq -sc .)" \
    '{mode: $mode, ok: ($problems | length == 0), problems: $problems, infos: $infos}' > "$W/verify.json"
  note "verify details: $(printf '%s; ' "${infos[@]}" | cut -c1-3500)"
  if [ "${#problems[@]}" != 0 ]; then for p in "${problems[@]}"; do warn "$p"; done; die "verify: ${#problems[@]} problem(s)"; fi
  note "verify: the server matches ($COPY_MODE)"
}

basebackup() {
  if vps_ssh sudo test -f /opt/carmacars/backup/enabled-flag/enabled; then
    note "base backup: $(vps_ssh sudo /opt/carmacars/bin/walg-base | tail -n 1)"
  else
    note "base backup: the backup bucket is not configured (vps-backup configure)"
  fi
}

for step in "$@"; do
  case "$step" in preflight|dump|reset|restore|migrations|vault|cron|auth|functions|storage|verify|basebackup) ;; *) die "unknown step $step" ;; esac
  say "== $step"
  "$step"
done
