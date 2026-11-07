#!/usr/bin/env bash
# Stale emails (0601, docs/changes/2026-11-07-outbox-stale.md): one annotation on every production deploy with the
# emails skipped as stale in the last day, by audience and by code, and how many still wait. Counts only (the repository
# is public: never an address).
#
#   scripts/deploy/outbox-stale.sh                                  (in the deploy job)
#   OUTBOX_STALE_JSON='{...}' scripts/deploy/outbox-stale.sh --offline   (the unit test: no database)
# Never fails the deploy: a read that fails is a warning.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --offline ]; then j="${OUTBOX_STALE_JSON:-}"
else j=$("$HERE/sb.sh" sql "select public.server_outbox_stale_report() as r" 2>/dev/null | jq -c '.[0].r // empty' 2>/dev/null) || j=''
fi
[ -n "$j" ] || { echo "::warning title=stale emails::the email counts could not be read; Admin > Settings > Email log shows each skipped email"; exit 0; }
total=$(jq -r '.total' <<<"$j")
aud=$(jq -r '.by_audience | to_entries | sort_by(-.value) | map("\(.key) \(.value)") | join(", ")' <<<"$j")
codes=$(jq -r '.by_code | map("- \(.code): \(.n)") | join("\n")' <<<"$j")
msg="$total emails skipped as stale in the last day (never sent late); $(jq -r '.waiting' <<<"$j") still waiting."
[ "$total" = 0 ] || msg="$msg"$'\n'"By audience: $aud"$'\n'"By code:"$'\n'"$codes"
echo "::notice title=stale emails::${msg//$'\n'/%0A}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then { echo "## Stale emails"; echo; echo "$msg"; } >> "$GITHUB_STEP_SUMMARY"; fi
exit 0
