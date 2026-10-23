#!/usr/bin/env bash
# Retention of the private Storage bucket deploy-reports (docs/changes/2026-10-21-cpu-and-storage.md). Run nightly by
# .github/workflows/backup.yml (and by hand there with prune_now). The bucket holds:
#   <run id>/            the verify workflow's report and screenshots: kept REPORTS_KEEP_DAYS (3) days, by the newest
#                        file in the folder
#   guides/<date>/       the guides workflow's screenshots (about 100 MB a run): only the newest GUIDES_KEEP (1) date
#   forms/<run id>/      the forms-fetch workflow's PDFs and report: the newest FORMS_KEEP (3) runs
# Anything else in the bucket is left alone. Every run prints what it keeps and what it removes (folder, files, size).
# Dry run unless PRUNE=1: it lists and deletes nothing.
#
#   PRUNE=1 scripts/backup/prune-reports.sh        needs SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_REF (the service
#                                                   key is read from the Management API, masked in the log)
#   scripts/backup/prune-reports.sh --listing-dir <dir> [--now <ISO time>]
#                                                   offline: each listing is read from <dir>/<prefix with / as _>.json
#                                                   (the test, scripts/backup/prune-reports.test.sh)
set -euo pipefail

BUCKET="${REPORTS_BUCKET:-deploy-reports}"
KEEP_DAYS="${REPORTS_KEEP_DAYS:-3}"
GUIDES_KEEP="${GUIDES_KEEP:-1}"
FORMS_KEEP="${FORMS_KEEP:-3}"
PRUNE="${PRUNE:-0}"
LISTING_DIR=""; NOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --listing-dir) LISTING_DIR="$2"; shift 2 ;;
    --now) NOW="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
say() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=deploy-reports::$*"; else echo "$*"; fi; }

if [ -n "$LISTING_DIR" ]; then
  [ "$PRUNE" = 1 ] && { echo "offline listings: nothing to delete" >&2; exit 2; }
  list() { local f="$LISTING_DIR/$(printf '%s' "${1:-root}" | tr '/' '_').json"; [ -f "$f" ] && cat "$f" || echo '[]'; }
else
  # the hosted project or the company's server (DB_BACKEND, scripts/deploy/lib.sh)
  # shellcheck source=../deploy/lib.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../deploy/lib.sh"
  KEY=$(sb_service_key) || { echo "the service key could not be read" >&2; exit 1; }
  ST="$SB_URL/storage/v1"
  H=(-H "Authorization: Bearer $KEY" -H "apikey: $KEY")
  # one folder level, every page (the Storage API answers at most 1000 entries a call)
  list() {
    local prefix="$1" offset=0 page all='[]'
    while :; do
      page=$(curl -sS -f -X POST "$ST/object/list/$BUCKET" "${H[@]}" -H 'content-type: application/json' \
        --data "$(jq -nc --arg p "$prefix" --argjson o "$offset" '{prefix: $p, limit: 1000, offset: $o, sortBy: {column: "name", order: "asc"}}')")
      all=$(jq -c --argjson a "$all" '$a + .' <<<"$page")
      [ "$(jq 'length' <<<"$page")" -lt 1000 ] && break
      offset=$((offset + 1000))
    done
    echo "$all"
  }
fi
NOW_S=$(date -u -d "${NOW:-now}" +%s)

# every file under a folder: [{path, size, created_at}]
files_under() {
  local prefix="$1" entries out='[]' sub
  entries=$(list "$prefix")
  out=$(jq -c --arg p "$prefix" '[.[] | select(.id != null) | {path: ($p + .name), size: (.metadata.size // 0), created_at: (.created_at // .updated_at // "")}]' <<<"$entries")
  for sub in $(jq -r '.[] | select(.id == null) | .name' <<<"$entries"); do
    out=$(jq -c --argjson a "$out" '$a + .' <<<"$(files_under "$prefix$sub/")")
  done
  echo "$out"
}

PLAN='[]'   # [{folder, why, files: [...], bytes}]
KEPT='[]'   # [{folder, why}]
remove() { PLAN=$(jq -c --arg f "$1" --arg w "$2" --argjson x "$3" '. + [{folder: $f, why: $w, files: [$x[].path], bytes: ([$x[].size] | add // 0)}]' <<<"$PLAN"); }
keep() { KEPT=$(jq -c --arg f "$1" --arg w "$2" '. + [{folder: $f, why: $w}]' <<<"$KEPT"); }

ROOT_LIST=$(list "")
# 1. the verify runs: numeric folders, by the newest file in each
for run in $(jq -r '.[] | select(.id == null) | .name | select(test("^[0-9]+$"))' <<<"$ROOT_LIST"); do
  f=$(files_under "$run/")
  newest=$(jq -r '[.[].created_at | select(. != "")] | max // ""' <<<"$f")
  if [ -z "$newest" ]; then keep "$run/" "no files"; continue; fi
  age_d=$(( (NOW_S - $(date -u -d "$newest" +%s)) / 86400 ))
  if [ "$age_d" -ge "$KEEP_DAYS" ]; then remove "$run/" "verify run, $age_d days old" "$f"; else keep "$run/" "verify run, $age_d days old"; fi
done
# 2. the guides: the newest dates only
i=0
for d in $(jq -r '.[] | select(.id == null) | .name' <<<"$(list "guides/")" | sort -r); do
  i=$((i + 1))
  if [ "$i" -le "$GUIDES_KEEP" ]; then keep "guides/$d/" "guides, newest $i"; else remove "guides/$d/" "guides, older than the newest $GUIDES_KEEP" "$(files_under "guides/$d/")"; fi
done
# 3. the forms runs: the newest run ids
i=0
for r in $(jq -r '.[] | select(.id == null) | .name' <<<"$(list "forms/")" | sort -rn); do
  i=$((i + 1))
  if [ "$i" -le "$FORMS_KEEP" ]; then keep "forms/$r/" "forms run, newest $i"; else remove "forms/$r/" "forms run, older than the newest $FORMS_KEEP" "$(files_under "forms/$r/")"; fi
done

n_files=$(jq '[.[].files | length] | add // 0' <<<"$PLAN")
bytes=$(jq '[.[].bytes] | add // 0' <<<"$PLAN")
mb=$(awk "BEGIN { printf \"%.1f\", $bytes / 1048576 }")
jq -r '.[] | "keep    \(.folder) (\(.why))"' <<<"$KEPT"
jq -r '.[] | "remove  \(.folder) (\(.why)): \(.files | length) files, \(.bytes / 1048576 * 10 | floor / 10) MB"' <<<"$PLAN"
if [ "$PRUNE" != 1 ]; then
  say "dry run: would remove $(jq 'length' <<<"$PLAN") folders, $n_files files, $mb MB from $BUCKET (PRUNE=1 removes them)"
  exit 0
fi
# the Storage API removes up to 1000 named files a call
deleted=0
while read -r batch; do
  [ "$batch" = "[]" ] && continue
  curl -sS -f -o /dev/null -X DELETE "$ST/object/$BUCKET" "${H[@]}" -H 'content-type: application/json' --data "{\"prefixes\": $batch}"
  deleted=$((deleted + $(jq 'length' <<<"$batch")))
done < <(jq -c '[.[].files[]] | _nwise(1000)' <<<"$PLAN")
say "removed $(jq 'length' <<<"$PLAN") folders, $deleted files, $mb MB from $BUCKET; kept $(jq 'length' <<<"$KEPT") folders"
