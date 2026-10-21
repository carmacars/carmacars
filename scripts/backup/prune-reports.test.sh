#!/usr/bin/env bash
# Offline test of scripts/backup/prune-reports.sh: a made-up bucket listing, the plan it prints (no network, no delete).
#   scripts/backup/prune-reports.test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
dir() { echo "{\"name\":\"$1\",\"id\":null,\"metadata\":null}"; }
file() { echo "{\"name\":\"$1\",\"id\":\"x-$1\",\"created_at\":\"$2\",\"metadata\":{\"size\":$3}}"; }
# root: three verify runs (1, 2 and 5 days old by their newest file), guides, forms, and something else
echo "[$(dir 39000000001),$(dir 39000000002),$(dir 39000000003),$(dir guides),$(dir forms),$(file README.txt 2026-01-01T00:00:00Z 10)]" > "$D/root.json"
echo "[$(file report.json 2026-10-20T12:00:00Z 1000),$(file home.png 2026-10-20T12:00:01Z 2000000)]" > "$D/39000000001_.json"
echo "[$(file report.json 2026-10-16T12:00:00Z 1000),$(file home.png 2026-10-19T00:30:00Z 3000000)]" > "$D/39000000002_.json"
echo "[$(file report.json 2026-10-15T12:00:00Z 1000)]" > "$D/39000000003_.json"
# guides: three dates, each with a portal folder
echo "[$(dir 2026-10-14),$(dir 2026-10-21),$(dir 2026-10-19)]" > "$D/guides_.json"
for g in 2026-10-14 2026-10-19 2026-10-21; do
  echo "[$(file manifest.json ${g}T08:00:00Z 500),$(dir admin)]" > "$D/guides_${g}_.json"
  echo "[$(file 01-today-desktop.png ${g}T08:00:00Z 50000000),$(file 01-today-phone.png ${g}T08:00:00Z 20000000)]" > "$D/guides_${g}_admin_.json"
done
# forms: five runs
echo "[$(dir 100),$(dir 300),$(dir 200),$(dir 500),$(dir 400)]" > "$D/forms_.json"
for r in 100 200 300 400 500; do echo "[$(file report.json 2026-10-0${r:0:1}T00:00:00Z 100)]" > "$D/forms_${r}_.json"; done

out=$(env -u GITHUB_ACTIONS bash "$HERE/prune-reports.sh" --listing-dir "$D" --now 2026-10-21T13:00:00Z)
echo "$out"
want=$(cat <<'EOF'
keep    39000000001/ (verify run, 1 days old)
keep    39000000002/ (verify run, 2 days old)
keep    guides/2026-10-21/ (guides, newest 1)
keep    forms/500/ (forms run, newest 1)
keep    forms/400/ (forms run, newest 2)
keep    forms/300/ (forms run, newest 3)
remove  39000000003/ (verify run, 6 days old): 1 files, 0 MB
remove  guides/2026-10-19/ (guides, older than the newest 1): 3 files, 66.7 MB
remove  guides/2026-10-14/ (guides, older than the newest 1): 3 files, 66.7 MB
remove  forms/200/ (forms run, older than the newest 3): 1 files, 0 MB
remove  forms/100/ (forms run, older than the newest 3): 1 files, 0 MB
dry run: would remove 5 folders, 9 files, 133.5 MB from deploy-reports (PRUNE=1 removes them)
EOF
)
if [ "$out" = "$want" ]; then echo "prune-reports: plan as expected"; else echo "prune-reports: UNEXPECTED PLAN"; diff <(echo "$want") <(echo "$out") || true; exit 1; fi
# the paths it would delete are the files, never the folder or another prefix
PRUNE=1 bash "$HERE/prune-reports.sh" --listing-dir "$D" 2>/dev/null && { echo "PRUNE=1 with offline listings must refuse"; exit 1; }
echo "prune-reports: PRUNE=1 refused offline"
