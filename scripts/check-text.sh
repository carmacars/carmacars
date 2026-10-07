#!/usr/bin/env bash
# Text check: no em dash, and no en dash used as a sentence dash, in what we write.
#
#   scripts/check-text.sh
#
# Covers every tracked file under src/, docs/ (except docs/source/, which holds the signed
# source documents as received), supabase/ and README.md. Prints file:line for each hit and
# exits 1 if there is any. Rewrite the sentence with a comma, colon, period or parentheses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EM=$'\xe2\x80\x94'            # U+2014
EN_SPACED=$' \xe2\x80\x93 '   # U+2013 with a space on each side

HITS=0
while IFS= read -r -d '' f; do
  case "$f" in docs/source/*) continue ;; esac
  [ -f "$f" ] || continue
  if out="$(LC_ALL=C grep -n -I -e "$EM" -e "$EN_SPACED" -- "$f")"; then
    while IFS= read -r line; do
      echo "$f:$line"
      HITS=$((HITS + 1))
    done <<< "$out"
  fi
done < <(git ls-files -z -- src docs supabase README.md)

if [ "$HITS" -gt 0 ]; then
  echo "TEXT CHECK FAILED: $HITS line(s) with an em dash or a spaced en dash"
  exit 1
fi
echo "TEXT CHECK PASSED"
