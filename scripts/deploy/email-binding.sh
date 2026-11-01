#!/usr/bin/env bash
# The Worker's Cloudflare Email Service binding (0222; docs/changes/2026-11-06-audit-gaps.md). The repository variable
# CF_EMAIL_BINDING turns it on: 1, true, yes, on or EMAIL (any case; the owner set it to EMAIL, the binding's name, and
# the deploy only took 1, so the binding was never added). The binding is always named EMAIL (the app reads env.EMAIL).
# Every production deploy says in an annotation whether it was added and why.
#
#   scripts/deploy/email-binding.sh <wrangler.jsonc> <DEPLOY_ENV> "<value of CF_EMAIL_BINDING>"
#   source it for cf_email_on (scripts/deploy/owner-steps.sh)

# cf_email_on <value>: exit 0 when the variable turns the binding on
cf_email_on() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    1|true|yes|on|email) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  f="${1:?wrangler.jsonc}"; envname="${2:-production}"; v="${3:-}"
  [ "$envname" = production ] || { echo "email binding: not on $envname (production only)"; exit 0; }
  if ! cf_email_on "$v"; then
    echo "::warning title=email::EMAIL binding NOT added: the repository variable CF_EMAIL_BINDING is $([ -n "$v" ] && echo "'$v'" || echo 'not set'), not one of 1, true, yes, on or EMAIL, so every email goes through Resend (100 a day). Owner step: GitHub > Settings > Secrets and variables > Actions > Variables, CF_EMAIL_BINDING = 1"
    exit 0
  fi
  if grep -q '"send_email"' "$f"; then echo "::notice title=email::EMAIL binding already in wrangler.jsonc (CF_EMAIL_BINDING='$v')"; exit 0; fi
  sed -i '0,/"ai": { "binding": "AI" },/s//"ai": { "binding": "AI" },\n  "send_email": [{ "name": "EMAIL" }],/' "$f"
  if grep -q '"send_email": \[{ "name": "EMAIL" }\]' "$f"; then
    echo "::notice title=email::EMAIL binding added (CF_EMAIL_BINDING='$v'): the Worker sends the outbox through Cloudflare Email Service first, Resend after"
  else
    echo "::warning title=email::EMAIL binding NOT added: CF_EMAIL_BINDING='$v' turns it on, but wrangler.jsonc has no AI binding line to put it after; every email goes through Resend (100 a day)"
  fi
fi
