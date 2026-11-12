#!/usr/bin/env bash
# The one summary of a database suite that ran in slices (scripts/test.sh with CARMACARS_TEST_SLICE and
# CARMACARS_TEST_RESULTS; .github/workflows/ci.yml, db-suite).
#
#   scripts/test-merge.sh <dir> [<dir> ...]     each dir holds one slice's files.txt and results.tsv
#
# Prints the summary of scripts/test.sh (one line a suite, TOTAL, a FAILED line for each failed assertion) over all
# slices, and fails when an assertion failed or when the slices together did not run every file of supabase/tests
# exactly once (a missing slice, or a file run twice).
set -euo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -ge 1 ] || { echo "usage: $0 <dir> [<dir> ...]" >&2; exit 2; }

ran="$(mktemp)"; want="$(mktemp)"; all="$(mktemp)"
trap 'rm -f "$ran" "$want" "$all"' EXIT
for d in "$@"; do
  [ -f "$d/files.txt" ] && [ -f "$d/results.tsv" ] || { echo "no results of a slice in $d" >&2; exit 1; }
  cat "$d/files.txt" >> "$ran"; cat "$d/results.tsv" >> "$all"
done
sort "$ran" -o "$ran"
(cd "$ROOT/supabase/tests" && ls [0-9]*.sql) | sort > "$want"

echo "== summary ($# slices, $(wc -l < "$ran" | tr -d ' ') test files)"
# results.tsv: suite, passed (t or f), name, detail (PostgreSQL's copy text format: one assertion a line)
awk -F '\t' '{ if ($2 == "t") p[$1]++; else f[$1]++; s[$1] = 1 } END { for (k in s) printf "%-22s %4d passed %4d failed\n", k, p[k], f[k] }' "$all" | sort
awk -F '\t' '{ if ($2 == "t") p++; else f++ } END { printf "%-22s %4d passed %4d failed\n", "TOTAL", p, f }' "$all"
awk -F '\t' '$2 != "t" { print "FAILED: [" $1 "] " $3 ($4 == "" ? "" : " -- " $4) }' "$all"

bad=0
if ! cmp -s "$want" "$ran"; then
  echo "the slices did not run every test file exactly once:"
  comm -23 "$want" "$ran" | sed 's/^/   not run: /'
  comm -13 "$want" "$ran" | sed 's/^/   not a test file: /'
  uniq -d "$ran" | sed 's/^/   run more than once: /'
  bad=1
fi
FAILED="$(awk -F '\t' '$2 != "t"' "$all" | wc -l | tr -d ' ')"
[ "$FAILED" = "0" ] || { echo "FAILED: $FAILED assertion(s)"; exit 1; }
[ "$bad" = 0 ] || exit 1
echo "ALL TESTS PASSED"
