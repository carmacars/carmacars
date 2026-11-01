#!/usr/bin/env bash
# Phone and browser alerts (0300): the VAPID key pair, made by the deploy itself when the vault of the live database has
# none (the owner's approval of November 1, 2026: "yes, auto-create the alert keys"; docs/changes/2026-11-06-audit-gaps.md).
# Made once: a later deploy reads the stored pair and never makes another (a new pair would end every subscription).
# Sourced by supabase.sh secrets; the unit test (web/src/lib/deploy-scripts.test.ts) runs it directly:
#   scripts/deploy/vapid.sh need "<public>" "<private>"   prints yes or no
#   scripts/deploy/vapid.sh make                          prints "<public> <private>" (base64url; the test only)

# vapid_need <public> <private>: exit 0 when a pair must be made (either is missing: one alone cannot sign)
vapid_need() { [ -z "${1:-}" ] || [ -z "${2:-}" ]; }

# vapid_make: a P-256 key pair as web push wants it, "<public (uncompressed point)> <private (d)>", base64url
vapid_make() {
  node -e "const k=require('crypto').generateKeyPairSync('ec',{namedCurve:'prime256v1'}).privateKey.export({format:'jwk'});const b=s=>Buffer.from(s,'base64url');process.stdout.write(Buffer.concat([Buffer.from([4]),b(k.x),b(k.y)]).toString('base64url')+' '+k.d)"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  case "${1:-}" in
    need) if vapid_need "${2:-}" "${3:-}"; then echo yes; else echo no; fi ;;
    make) vapid_make; echo ;;
    *) echo "usage: vapid.sh need <public> <private> | make" >&2; exit 2 ;;
  esac
fi
