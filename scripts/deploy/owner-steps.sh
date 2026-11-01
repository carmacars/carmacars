#!/usr/bin/env bash
# Every feature waiting on a step only the owner can take, with the exact step (0321, docs/changes/2026-11-06-audit-gaps.md):
# one annotation on every production deploy, so no switch-on step is ever hidden. The database's part comes from
# public.server_owner_steps() (Meta Page token, GoHighLevel tokens, the RentalCoverage link, the VAPID and Wallet values in
# the vault); this script adds the Cloudflare email binding (the repository variable CF_EMAIL_BINDING).
#
#   CF_EMAIL_BINDING=<vars.CF_EMAIL_BINDING> scripts/deploy/owner-steps.sh             (in the deploy job)
#   OWNER_STEPS_JSON='[...]' CF_EMAIL_BINDING= scripts/deploy/owner-steps.sh --offline  (the unit test: no database)
# Never fails the deploy: a read that fails is a warning.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --offline ]; then rows="${OWNER_STEPS_JSON:-[]}"
else
  rows=$("$HERE/sb.sh" sql "select public.server_owner_steps() as s" 2>/dev/null | jq -c '.[0].s // []' 2>/dev/null) || rows=''
  [ -n "$rows" ] || { echo "::warning title=owner steps::the database's list could not be read; Admin > Settings shows the Setup checklist"; rows='[]'; }
fi
if [ "${CF_EMAIL_BINDING:-}" != 1 ]; then
  rows=$(jq -c '. + [{key: "cf_email", feature: "Emails through Cloudflare Email Service (3,000 a month; until then Resend, 100 a day)",
    step: "Cloudflare dashboard > Compute (Workers) > Email Service: enable it and add the sending domain carmacars.ca with the DNS records it shows; then GitHub > the repository > Settings > Secrets and variables > Actions > Variables: CF_EMAIL_BINDING = 1; then deploy (Admin > Settings > Usage, Emails)"}]' <<<"$rows")
fi
n=$(jq 'length' <<<"$rows")
if [ "$n" = 0 ]; then echo "::notice title=owner steps::nothing is waiting on an owner step"; exit 0; fi
# one annotation (GitHub keeps line breaks as %0A), and the same list in the run's summary
msg=$(jq -r 'map("- \(.feature): \(.step)") | join("\n")' <<<"$rows")
echo "::warning title=owner steps ($n waiting)::${msg//$'\n'/%0A}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then { echo "## Waiting on an owner step ($n)"; echo; echo "$msg"; } >> "$GITHUB_STEP_SUMMARY"; fi
exit 0
