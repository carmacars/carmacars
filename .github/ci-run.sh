#!/usr/bin/env bash
# Runs a CI step and, when it fails, puts the last lines of its output into error annotations, which
# can be read in the run summary and through the API (GET .../check-runs/<job id>/annotations) without
# downloading the logs.
#   .github/ci-run.sh "<label>" <command> [args...]
label="$1"; shift
log="$(mktemp)"
set +e
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r//g' "$log" | grep -v '^\s*$' | tail -n 90 > "$log.tail"
  first="$(sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | grep -m 12 -iE -A2 'error|failed|exception' | head -n 30)"
  if [ -n "$first" ]; then
    echo "::error title=${label} first errors::$(printf '%s' "$first" | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')"
  fi
  for part in 1 2 3; do
    chunk="$(sed -n "$(( (part - 1) * 30 + 1 )),$(( part * 30 ))p" "$log.tail")"
    [ -n "$chunk" ] || continue
    msg="$(printf '%s' "$chunk" | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')"
    echo "::error title=${label} failed (${part}/3)::${msg}"
  done
  # Playwright's page snapshot at the failure (what the page showed), first failures only
  for f in $(find . -path '*test-results*' -name error-context.md 2>/dev/null | head -n 3); do
    ctx="$(grep -v '^\s*$' "$f" | head -n 60)"
    echo "::error title=${label} page at failure ($(basename "$(dirname "$f")"))::$(printf '%s' "$ctx" | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')"
  done
fi
rm -f "$log" "$log.tail"
exit "$rc"
