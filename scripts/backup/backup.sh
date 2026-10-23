#!/usr/bin/env bash
# Nightly database backup (docs/backups.md). Run by .github/workflows/backup.yml; needs SUPABASE_ACCESS_TOKEN,
# SUPABASE_PROJECT_REF, SUPABASE_DB_PASSWORD and pg_dump 17 (the server's major version).
#
#   1. pg_dump of the live database through the session pooler (IPv4): the schemas public, app, auth, storage and
#      supabase_migrations, custom format, in one consistent snapshot; the row count of every table is read in
#      that same snapshot and written to the manifest, so a restore can be checked table by table.
#   2. Encrypted with age to the public key in the vault (backup_age_recipient). Only the private key
#      (backup_age_identity, in the vault and the company password manager) can read it. The plain dump never
#      leaves the runner.
#   3. Uploaded to the private Supabase Storage bucket `backups` under nightly/<stamp>/ (parts of 45 MB, the free
#      plan's 50 MB file limit), with manifest.json (no data: table names, counts, sizes, checksums).
#   4. Folders older than BACKUP_KEEP_DAYS (30) are deleted.
#   5. The run is recorded in job_runs ('backup-nightly'); a failure shows on Admin > Today (no email).
# Prints the stamp on the last line. BACKUP_DIR keeps the files (for the restore test in the same job).
#
# DB_BACKEND=vps (the company's own server, infra/vps/CUTOVER.md; run by .github/workflows/vps-backup.yml): the dump
# is read through the SSH tunnel, and the encrypted parts go to the S3-compatible backup bucket instead of Supabase
# Storage: s3://$BACKUP_S3_BUCKET/logical/nightly/<stamp>/ (BACKUP_S3_ENDPOINT, BACKUP_S3_REGION,
# BACKUP_S3_ACCESS_KEY_ID, BACKUP_S3_SECRET_ACCESS_KEY; the aws CLI of the GitHub runner). The server also archives
# its WAL and takes nightly base backups with wal-g into the same bucket (infra/vps/bin/walg-base).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../deploy/lib.sh
source "$ROOT/scripts/deploy/lib.sh"

KEEP_DAYS="${BACKUP_KEEP_DAYS:-30}"
PART_BYTES=$((45 * 1024 * 1024))
OUT="${BACKUP_DIR:-$(mktemp -d)}"; mkdir -p "$OUT"; chmod 700 "$OUT"
STAMP="$(date -u +%Y-%m-%dT%H%MZ)"
SCHEMAS=(public app auth storage supabase_migrations)
FILE="$OUT/carmacars-$STAMP.dump"

record() { # status summary-json error
  local err="${3:-}"
  sbq "insert into public.job_runs (job_name, run_key, status, started_at, finished_at, summary, error)
       values ('backup-nightly', '$STAMP', '$1', now(), now(), \$j\$$2\$j\$::jsonb, nullif(\$e\$$err\$e\$, ''))
       on conflict (job_name, run_key) do nothing" > /dev/null || true
}
fail() { record failed '{}' "$1"; die "backup: $1"; }
trap 'rc=$?; [ $rc -eq 0 ] || record failed "{}" "the backup step stopped (exit $rc); see the workflow run"' EXIT

command -v pg_dump >/dev/null || fail "pg_dump is not installed"
command -v age >/dev/null || fail "age is not installed"
log "$(pg_dump --version)"

# ---------------------------------------------------------------- connection (session pooler, IPv4; or the tunnel)
if [ "$DB_BACKEND" = vps ]; then
  export PGHOST=127.0.0.1 PGPORT="$VPS_PG_PORT" PGUSER=postgres PGDATABASE=postgres PGSSLMODE=disable PGCONNECT_TIMEOUT=20 PGAPPNAME=carmacars-backup
  PGPASSWORD=$(vps_secret POSTGRES_PASSWORD); export PGPASSWORD
  for v in BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!v:-}" ] || fail "$v is not set (repository secret; infra/vps/CUTOVER.md, Backups)"
  done
  export AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION="${BACKUP_S3_REGION:-us-east-1}"
  S3=(aws s3 --endpoint-url "$BACKUP_S3_ENDPOINT" --only-show-errors)
  S3_BASE="s3://$BACKUP_S3_BUCKET/logical/nightly"
else
  pool=$(sbapi GET "/config/database/pooler")
  export PGHOST PGUSER PGPORT=5432 PGDATABASE=postgres PGSSLMODE=require PGCONNECT_TIMEOUT=20 PGAPPNAME=carmacars-backup
  PGHOST=$(jq -r '[.[] | select(.database_type == "PRIMARY")][0].db_host' <<<"$pool")
  PGUSER=$(jq -r '[.[] | select(.database_type == "PRIMARY")][0].db_user' <<<"$pool")
  export PGPASSWORD="${SUPABASE_DB_PASSWORD:?SUPABASE_DB_PASSWORD is needed}"
fi
mask "$PGPASSWORD"

RECIPIENT="${BACKUP_AGE_RECIPIENT:-$(vault_get backup_age_recipient)}"
[[ "$RECIPIENT" == age1* ]] || fail "no age recipient (vault secret backup_age_recipient)"

# ---------------------------------------------------------------- one snapshot for the counts and the dump
in_list=$(printf "'%s'," "${SCHEMAS[@]}"); in_list="${in_list%,}"
COUNTS_SQL="select coalesce(json_object_agg(t.table_schema || '.' || t.table_name,
              (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', t.table_schema, t.table_name), false, true, '')))[1]::text::bigint
              order by t.table_schema, t.table_name), '{}') from information_schema.tables t
             where t.table_type = 'BASE TABLE' and t.table_schema in ($in_list)"
consistent=true
coproc PSQL { psql -X -q -At -v ON_ERROR_STOP=1 2>&1; }
echo "begin isolation level repeatable read read only; select pg_export_snapshot();" >&"${PSQL[1]}"
read -r -t 60 snap <&"${PSQL[0]}" || snap=""
dump_args=(--format=custom --compress=6 --no-comments --verbose)
for s in "${SCHEMAS[@]}"; do dump_args+=(--schema="$s"); done
if [[ "$snap" =~ ^[0-9A-F-]+$ ]]; then
  log "snapshot $snap"
  if ! pg_dump "${dump_args[@]}" --snapshot="$snap" --file="$FILE" 2> "$OUT/pg_dump.log"; then
    warn "pg_dump with the exported snapshot failed ($(tail -n 2 "$OUT/pg_dump.log" | tr '\n' ' ')); dumping without it"
    consistent=false
  fi
else
  warn "the pooler did not export a snapshot ($snap); the counts are read right after the dump"
  consistent=false
fi
if [ "$consistent" = true ]; then
  echo "$COUNTS_SQL;" >&"${PSQL[1]}"
  read -r -t 300 counts <&"${PSQL[0]}" || counts=""
fi
echo "commit;" >&"${PSQL[1]}"; echo '\q' >&"${PSQL[1]}"; wait "${PSQL_PID:-}" 2>/dev/null || true
if [ "$consistent" != true ]; then
  pg_dump "${dump_args[@]}" --file="$FILE" 2> "$OUT/pg_dump.log" || fail "pg_dump failed: $(tail -n 3 "$OUT/pg_dump.log" | tr '\n' ' ')"
  counts=$(psql -X -q -At -v ON_ERROR_STOP=1 -c "$COUNTS_SQL")
fi
jq -e 'type == "object" and length > 100' <<<"$counts" > /dev/null || fail "the table counts could not be read"
server=$(psql -X -q -At -c "show server_version")

# ---------------------------------------------------------------- check the dump reads, then encrypt
pg_restore --list "$FILE" > "$OUT/toc.txt" || fail "the dump cannot be read back"
toc_tables=$(grep -c ' TABLE DATA ' "$OUT/toc.txt" || true)
plain_sha=$(sha256sum "$FILE" | cut -d' ' -f1); plain_bytes=$(stat -c %s "$FILE")
age --encrypt --recipient "$RECIPIENT" --output "$FILE.age" "$FILE"
rm -f "$FILE"
enc_sha=$(sha256sum "$FILE.age" | cut -d' ' -f1); enc_bytes=$(stat -c %s "$FILE.age")
( cd "$OUT" && split --bytes="$PART_BYTES" --numeric-suffixes=1 --suffix-length=2 "$(basename "$FILE.age")" "$(basename "$FILE.age").part" )
parts=$(cd "$OUT" && ls "$(basename "$FILE.age")".part* | jq -R . | jq -sc .)
jq -n --arg stamp "$STAMP" --arg server "$server" --arg pgdump "$(pg_dump --version)" --arg sha "${GITHUB_SHA:-local}" \
      --arg plain_sha "$plain_sha" --argjson plain_bytes "$plain_bytes" --arg enc_sha "$enc_sha" --argjson enc_bytes "$enc_bytes" \
      --argjson parts "$parts" --argjson counts "$counts" --argjson consistent "$consistent" --argjson toc_tables "$toc_tables" \
      --arg recipient "$RECIPIENT" --argjson schemas "$(printf '%s\n' "${SCHEMAS[@]}" | jq -R . | jq -sc .)" \
  '{stamp: $stamp, created_at: (now | todate), server_version: $server, pg_dump: $pgdump, commit: $sha, schemas: $schemas,
    format: "pg_dump custom, age encrypted", recipient: $recipient, file: ($parts[0] | sub("\\.part01$"; "")), parts: $parts,
    encrypted: {sha256: $enc_sha, bytes: $enc_bytes}, plain: {sha256: $plain_sha, bytes: $plain_bytes},
    consistent_counts: $consistent, tables_with_data: $toc_tables, row_counts: $counts}' > "$OUT/manifest.json"

# ---------------------------------------------------------------- upload to the backup bucket (S3) on the server's backend
if [ "$DB_BACKEND" = vps ]; then
  for f in $(jq -r '.parts[]' "$OUT/manifest.json") manifest.json; do
    "${S3[@]}" cp "$OUT/$f" "$S3_BASE/$STAMP/$f" || fail "upload of $f to the backup bucket failed"
  done
  log "uploaded logical/nightly/$STAMP ($(jq -r '.parts | length' "$OUT/manifest.json") part(s), $enc_bytes bytes encrypted)"
  cutoff=$(date -u -d "-$KEEP_DAYS days" +%Y-%m-%dT%H%MZ)
  folders=$("${S3[@]}" ls "$S3_BASE/" | awk '$1 == "PRE" {sub("/$", "", $2); print $2}')
  removed=0
  for d in $folders; do
    [[ "$d" < "$cutoff" ]] || continue
    "${S3[@]}" rm --recursive "$S3_BASE/$d/" && removed=$((removed + 1))
  done
  kept=$(( $(wc -w <<<"$folders") - removed ))
else
  KEY=$(curl -sS "$SB_API/api-keys?reveal=true" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" | jq -r '.[] | select(.name == "service_role") | .api_key')
  [ -n "$KEY" ] || fail "no service role key"
  mask "$KEY"
  ST="https://$SUPABASE_PROJECT_REF.supabase.co/storage/v1"
  H=(-H "Authorization: Bearer $KEY" -H "apikey: $KEY")
  curl -sS -o /dev/null -X POST "$ST/bucket" "${H[@]}" -H 'content-type: application/json' \
    --data '{"id":"backups","name":"backups","public":false,"file_size_limit":52428800}' || true
  [ "$(curl -sS "$ST/bucket/backups" "${H[@]}" | jq -r '.public')" = "false" ] || fail "the backups bucket is missing or public"
  for f in $(jq -r '.parts[]' "$OUT/manifest.json") manifest.json; do
    ct=application/octet-stream; [ "$f" = manifest.json ] && ct=application/json
    code=$(curl -sS -o "$OUT/up.txt" -w '%{http_code}' -X POST "$ST/object/backups/nightly/$STAMP/$f" "${H[@]}" \
      -H "content-type: $ct" -H 'x-upsert: true' --data-binary "@$OUT/$f")
    [ "${code:0:1}" = 2 ] || fail "upload of $f answered $code: $(head -c 300 "$OUT/up.txt")"
  done
  log "uploaded nightly/$STAMP ($(jq -r '.parts | length' "$OUT/manifest.json") part(s), $enc_bytes bytes encrypted)"

  # ---------------------------------------------------------------- keep 30 days
  cutoff=$(date -u -d "-$KEEP_DAYS days" +%Y-%m-%dT%H%MZ)
  folders=$(curl -sS -X POST "$ST/object/list/backups" "${H[@]}" -H 'content-type: application/json' \
    --data '{"prefix":"nightly/","limit":1000,"sortBy":{"column":"name","order":"asc"}}' | jq -r '.[] | select(.id == null) | .name')
  removed=0
  for d in $folders; do
    [[ "$d" < "$cutoff" ]] || continue
    files=$(curl -sS -X POST "$ST/object/list/backups" "${H[@]}" -H 'content-type: application/json' \
      --data "$(jq -nc --arg p "nightly/$d/" '{prefix: $p, limit: 100}')" | jq -c --arg p "nightly/$d/" '[.[] | select(.id != null) | $p + .name]')
    [ "$files" != "[]" ] || continue
    curl -sS -o /dev/null -X DELETE "$ST/object/backups" "${H[@]}" -H 'content-type: application/json' --data "{\"prefixes\": $files}"
    removed=$((removed + 1))
  done
  kept=$(( $(wc -w <<<"$folders") - removed ))

fi

record succeeded "$(jq -c --argjson removed "$removed" --argjson kept "$kept" '{folder: ("nightly/" + .stamp), parts: (.parts | length), encrypted_bytes: .encrypted.bytes, tables: (.row_counts | length), rows: ([.row_counts[]] | add), consistent_counts, removed: $removed, kept: $kept}' "$OUT/manifest.json")"
trap - EXIT
notice "backup nightly/$STAMP: $(jq -r '"\(.row_counts | length) tables, \([.row_counts[]] | add) rows, \(.encrypted.bytes) bytes encrypted, counts \(if .consistent_counts then "from the dump snapshot" else "read after the dump" end)"' "$OUT/manifest.json"); $removed old folder(s) removed, $kept kept"
echo "$STAMP"
