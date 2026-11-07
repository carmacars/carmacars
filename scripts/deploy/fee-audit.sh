#!/usr/bin/env bash
# The fee check (0584, docs/changes/2026-11-06-plain-staff-emails.md): the month's owner invoices against each car's signed
# terms, printed on every production deploy as one annotation: how many owners and invoices, the total, each owner's
# count and total, and every invoice that does not match the agreement, with why. Owners appear by a short reference
# (the repository is public: never a name, an address or an email). Read only: nothing is changed.
#
#   scripts/deploy/fee-audit.sh [YYYY-MM-01]                    (in the deploy job; default: this month)
#   FEE_AUDIT_JSON='{...}' scripts/deploy/fee-audit.sh --offline  (the unit test: no database)
# Never fails the deploy: a read that fails is a warning.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --offline ]; then j="${FEE_AUDIT_JSON:-}"
else
  m="${1:-}"; [[ -z "$m" || "$m" =~ ^[0-9]{4}-[0-9]{2}-01$ ]] || { echo "::warning title=fee check::not a month: $m"; exit 0; }
  arg=$([ -n "$m" ] && echo "'$m'::date" || echo "null")
  j=$("$HERE/sb.sh" sql "select public.server_owner_fee_audit($arg) as a" 2>/dev/null | jq -c '.[0].a // empty' 2>/dev/null) || j=''
fi
[ -n "$j" ] || { echo "::warning title=fee check::the owner invoices could not be read; Admin > Money > Owner money > Debits shows the fee check"; exit 0; }
n=$(jq '.problems | length' <<<"$j")
head=$(jq -r '"\(.month): \(.invoices) invoices to \(.owners) owners, \(.total)"' <<<"$j")
owners=$(jq -r '.by_owner | map("- \(.owner): \(.invoices) invoice\(if .invoices == 1 then "" else "s" end), \(.total)") | join("\n")' <<<"$j")
probs=$(jq -r '.problems | map("- \(.invoice) (car \(.car // "?"), \(.owner)), \(.total): \(.problem)") | join("\n")' <<<"$j")
if [ "$n" = 0 ]; then
  msg="$head. Every invoice matches the agreement."$'\n'"$owners"
  echo "::notice title=fee check::${msg//$'\n'/%0A}"
else
  msg="$head. $n do not match the agreement (nothing was changed; an Admin decides):"$'\n'"$probs"$'\n'"Invoiced:"$'\n'"$owners"
  echo "::warning title=fee check ($n to look at)::${msg//$'\n'/%0A}"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then { echo "## Fee check"; echo; echo "$msg"; } >> "$GITHUB_STEP_SUMMARY"; fi
exit 0
