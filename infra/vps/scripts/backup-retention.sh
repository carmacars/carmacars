#!/usr/bin/env bash
# What the backups take in the backup bucket (Cloudflare R2, free up to 10 GB) and the retention that keeps them well
# under it (the vps-ops workflow's backup-report and apply-retention).
#
#   backup-retention.sh report   JSON on stdout: the bucket's usage per prefix (wal-g base backups, WAL, logical
#                                nightly backups, anything else), the server's wal-g backup list and retention, the
#                                logical backups' retention, and the plan: the retention that keeps the projected
#                                total under the target (70% of 10 GB)
#   backup-retention.sh apply    report, then the plan applied: WALG_RETAIN_FULL in the server's walg.env (bin/walg-base
#                                reads it every night), /opt/carmacars/backup/logical-keep-days (scripts/backup/backup.sh
#                                reads it), and backups beyond it deleted now (wal-g delete retain FULL, logical folders
#                                older than the kept days)
#
# Retention ladder (the first that fits): wal-g full backups 7 / logical days 30, 7/14, 5/14, 4/14, 3/14, 3/7, 2/7.
# Projection: newest base backup x kept + WAL per day x (kept + 1) + newest logical backup x (days + 1), all x 1.25 for
# growth, + anything else in the bucket.
#
# Env: BACKUP_S3_ENDPOINT, BACKUP_S3_REGION, BACKUP_S3_BUCKET, BACKUP_S3_ACCESS_KEY_ID, BACKUP_S3_SECRET_ACCESS_KEY
# (infra/vps/scripts/backup-env.sh), VPS_SSH_KEY; BACKUP_FREE_BYTES (10^10), BACKUP_TARGET_PCT (70). Nothing secret is
# printed (wal-g's settings stay on the server; only WALG_RETAIN_FULL is read from them).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../../../scripts/deploy/vps.sh
. "$ROOT/scripts/deploy/vps.sh"
mode="${1:-report}"
case "$mode" in report|apply) ;; *) echo "usage: backup-retention.sh report|apply" >&2; exit 2 ;; esac
for v in BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
  [ -n "${!v:-}" ] || { echo "backup-retention: $v is not set (repository secret or the vault; backup-env.sh)" >&2; exit 1; }
done
FREE="${BACKUP_FREE_BYTES:-10000000000}"
TARGET=$(( FREE * ${BACKUP_TARGET_PCT:-70} / 100 ))
export AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${BACKUP_S3_REGION:-auto}"
# R2 does not take the newer default checksums of the aws CLI on every call
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
S3API=(aws s3api --endpoint-url "$BACKUP_S3_ENDPOINT")
S3=(aws s3 --endpoint-url "$BACKUP_S3_ENDPOINT")
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# ---------------------------------------------------------------- the bucket: every object's key, size and date
"${S3API[@]}" list-objects-v2 --bucket "$BACKUP_S3_BUCKET" --output json \
  --query 'Contents[].{k: Key, s: Size, t: LastModified}' > "$W/objects.json"
jq -e 'type == "array"' "$W/objects.json" > /dev/null 2>&1 || echo '[]' > "$W/objects.json"

# ---------------------------------------------------------------- the server: wal-g's list and the retention in effect
# shellcheck disable=SC2016 # runs on the server
vps_ssh sudo bash -s > "$W/server.json" <<'SERVER'
set -uo pipefail
D=/opt/carmacars
retain=$(sed -n "s/^WALG_RETAIN_FULL='\{0,1\}\([0-9]*\)'\{0,1\}$/\1/p" "$D/backup/walg.env" 2>/dev/null | tail -n 1)
reads=false; grep -q 'backup/walg.env' "$D/bin/walg-base" 2>/dev/null && reads=true
keep=$(tr -dc 0-9 < "$D/backup/logical-keep-days" 2>/dev/null)
list=$("$D/bin/walg" backup-list --detail --json 2>/dev/null); jq -e 'type == "array"' <<<"$list" > /dev/null 2>&1 || list='[]'
next=$(systemctl show carmacars-walg-base.timer -p NextElapseUSecRealtime --value 2>/dev/null)
last=$(cat "$D/state/walg-base.last" 2>/dev/null)
enabled=false; [ -f "$D/backup/enabled-flag/enabled" ] && enabled=true
storage=$(du -sb "$D/supabase/volumes/storage" 2>/dev/null | cut -f1)
dbdata=$(du -sb "$D/supabase/volumes/db/data" 2>/dev/null | cut -f1)
jq -n --arg retain "$retain" --argjson reads "$reads" --arg keep "$keep" --argjson list "$list" --arg next "$next" \
  --arg last "$last" --argjson enabled "$enabled" --arg storage "$storage" --arg dbdata "$dbdata" \
  '{walg_env_retain_full: ($retain | tonumber? // null), walg_base_reads_walg_env: $reads,
    walg_base_retain_in_effect: (if $reads then ($retain | tonumber? // 7) else 7 end),
    logical_keep_days_file: ($keep | tonumber? // null), wal_archiving: $enabled, next_base_backup: $next,
    last_base_backup: $last, storage_files_bytes: ($storage | tonumber? // null), db_data_bytes: ($dbdata | tonumber? // null),
    backups: $list}'
SERVER

# ---------------------------------------------------------------- usage, projection, plan
jq -n --slurpfile o "$W/objects.json" --slurpfile s "$W/server.json" --argjson free "$FREE" --argjson target "$TARGET" '
  def sum: map(.s) | add // 0;
  def days_since($t): try ((now - ($t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601)) / 86400) catch 1;
  $o[0] as $all | $s[0] as $srv |
  ($all | map(select(.k | startswith("walg/basebackups_005/")))) as $base |
  ($all | map(select(.k | startswith("walg/wal_005/")))) as $wal |
  ($all | map(select(.k | startswith("logical/nightly/")))) as $log |
  ($all | map(select((.k | startswith("walg/basebackups_005/") or startswith("walg/wal_005/") or startswith("logical/nightly/")) | not))) as $other |
  # one base backup = its folder base_<name>/ + its sentinel base_<name>_backup_stop_sentinel.json
  ($base | map(. + {b: (.k | ltrimstr("walg/basebackups_005/") | split("/")[0] | sub("_backup_stop_sentinel\\.json$"; ""))})
         | group_by(.b) | map({name: .[0].b, bytes: sum, at: (map(.t) | max),
                              complete: (map(.k | endswith("_backup_stop_sentinel.json")) | any)}) | sort_by(.at)) as $bases |
  ($log | map(. + {f: (.k | ltrimstr("logical/nightly/") | split("/")[0])}) | group_by(.f)
        | map({folder: .[0].f, bytes: sum, files: length}) | sort_by(.folder)) as $logs |
  ($bases | map(select(.complete))) as $full |
  (($srv.backups | map(.start_time // .time) | min) // ($full[0].at // null)) as $oldest |
  ((if $oldest then days_since($oldest) else 1 end) | if . < 1 then 1 else . end) as $span |
  (($full | last | .bytes) // 0) as $base1 | (($wal | sum) / $span) as $walpd | (($logs | last | .bytes) // 0) as $log1 |
  ($other | sum) as $oth |
  def proj($n; $k): ((1.25 * ($base1 * $n + $walpd * ($n + 1) + $log1 * ($k + 1))) + $oth) | floor;
  ([[7,30],[7,14],[5,14],[4,14],[3,14],[3,7],[2,7]] | map({walg_retain_full: .[0], logical_keep_days: .[1], projected_bytes: proj(.[0]; .[1])})) as $ladder |
  (($ladder | map(select(.projected_bytes <= $target)) | first) // ($ladder | last + {over_target: true})) as $plan |
  {bucket_total_bytes: ($all | sum), objects: ($all | length), free_tier_bytes: $free, target_bytes: $target,
   pct_of_free: ((($all | sum) * 1000 / $free | floor) / 10),
   prefixes: {
     walg_base: {backups: ($full | length), incomplete: ($bases | map(select(.complete | not)) | length), bytes: ($base | sum),
                 newest_bytes: $base1, list: $bases},
     walg_wal: {files: ($wal | length), bytes: ($wal | sum), per_day_bytes: ($walpd | floor), days_spanned: (($span * 10 | floor) / 10)},
     logical_nightly: {backups: ($logs | length), bytes: ($log | sum), newest_bytes: $log1,
                       oldest: ($logs | first | .folder // null), newest: ($logs | last | .folder // null)},
     other: ($other | map(. + {p: (.k | split("/") | .[0:2] | join("/"))}) | group_by(.p) | map({prefix: .[0].p, files: length, bytes: sum}))
   },
   retention: {walg_env_retain_full: $srv.walg_env_retain_full, walg_base_reads_walg_env: $srv.walg_base_reads_walg_env,
               walg_retain_in_effect: $srv.walg_base_retain_in_effect,
               logical_keep_days_in_effect: ($srv.logical_keep_days_file // 30),
               logical_cleanup: "scripts/backup/backup.sh deletes logical/nightly/<stamp>/ folders older than the kept days after each nightly upload"},
   server: ($srv | del(.backups)), walg_backups: ($srv.backups | map({backup_name, time: (.start_time // .time), compressed_size, uncompressed_size})),
   ladder: $ladder, plan: $plan}' > "$W/report.json"

if [ "$mode" = report ]; then cat "$W/report.json"; exit 0; fi

# ---------------------------------------------------------------- apply
n=$(jq -r '.plan.walg_retain_full' "$W/report.json"); k=$(jq -r '.plan.logical_keep_days' "$W/report.json")
if ! { [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 2 ] && [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -ge 7 ]; }; then echo "backup-retention: no usable plan" >&2; exit 1; fi
# the server: walg.env (600, root) gets the new WALG_RETAIN_FULL; the logical days in their own file
# shellcheck disable=SC2016
vps_ssh sudo bash -s "$n" "$k" <<'SERVER' >&2
set -euo pipefail
D=/opt/carmacars; n="$1"; k="$2"; E="$D/backup/walg.env"
if [ -f "$E" ]; then
  if grep -q '^WALG_RETAIN_FULL=' "$E"; then sed -i "s/^WALG_RETAIN_FULL=.*/WALG_RETAIN_FULL='$n'/" "$E"; else echo "WALG_RETAIN_FULL='$n'" >> "$E"; fi
  chmod 600 "$E"
fi
install -d -m 700 "$D/backup"
echo "$k" > "$D/backup/logical-keep-days.tmp"; chmod 644 "$D/backup/logical-keep-days.tmp"; mv "$D/backup/logical-keep-days.tmp" "$D/backup/logical-keep-days"
grep -q 'backup/walg.env' "$D/bin/walg-base" || { echo "walg-base on the server does not read walg.env yet (install bin/ first)" >&2; exit 1; }
echo "server: WALG_RETAIN_FULL=$(sed -n 's/^WALG_RETAIN_FULL=//p' "$E" | tr -d "'"), logical-keep-days=$(cat "$D/backup/logical-keep-days")"
SERVER
# the backups beyond the retention, now (wal-g also deletes the WAL older than the oldest backup kept)
deleted_base=0
have=$(jq '.prefixes.walg_base.backups' "$W/report.json")
if [ "$have" -gt "$n" ]; then
  if ! vps_ssh "sudo systemctl is-active --quiet carmacars-walg-base.service"; then
    vps_ssh sudo /opt/carmacars/bin/walg delete retain FULL "$n" --confirm >&2
    deleted_base=$(( have - n ))
  else
    echo "backup-retention: a base backup is running; wal-g's retention applies when it finishes" >&2
  fi
fi
cutoff=$(date -u -d "-$k days" +%Y-%m-%dT%H%MZ)
deleted_logical=0
for d in $("${S3[@]}" ls "s3://$BACKUP_S3_BUCKET/logical/nightly/" 2>/dev/null | awk '$1 == "PRE" {sub("/$", "", $2); print $2}'); do
  [[ "$d" < "$cutoff" ]] || continue
  "${S3[@]}" rm --only-show-errors --recursive "s3://$BACKUP_S3_BUCKET/logical/nightly/$d/" >&2 && deleted_logical=$((deleted_logical + 1))
done
jq --argjson db "$deleted_base" --argjson dl "$deleted_logical" '. + {applied: {walg_retain_full: .plan.walg_retain_full,
  logical_keep_days: .plan.logical_keep_days, base_backups_deleted: $db, logical_folders_deleted: $dl}}' "$W/report.json"
