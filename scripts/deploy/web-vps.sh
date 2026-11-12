#!/usr/bin/env bash
# Release 42: the website on the company's server (docs/hosting/off-cloudflare.md), run by the deploy-vps job
# (.github/workflows/deploy-vps.yml). Nothing here changes DNS or the Cloudflare Worker.
#   scripts/deploy/web-vps.sh envfile <out>   the site's settings and secrets as NAME='value' lines (mode 600), from
#                                             this job's environment (the same names the Worker gets as secrets)
#   scripts/deploy/web-vps.sh ship <image.tgz> <web.env>   image, compose file and settings to the server, the
#                                             container started and healthy, Caddy's site file installed and loaded
#   scripts/deploy/web-vps.sh rollback        the image that ran before the last deploy, started again
# Environment: WEB_IMAGE_TAG (the commit), WEB_VPS_HOSTNAMES (comma separated, e.g. a temporary hostname first),
# WEB_CRON (keep, on or off; keep leaves the server's setting, off on a first deploy), VPS_SSH_KEY.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
say() { echo "[web-vps] $*"; }
die() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=deploy-vps::$*"; else echo "ERROR: $*"; fi; exit 1; }

# The names the site reads at run time. Public settings first, then the secrets (web/src/lib/env.ts).
NAMES="APP_ENV DATA_BACKEND NEXT_PUBLIC_APP_URL NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY NEXT_PUBLIC_SUPABASE_AUTH_COOKIE
NEXT_PUBLIC_VEHICLE_PHOTOS_URL NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY TURNSTILE_PROVIDER NEXT_PUBLIC_TURNSTILE_SITE_KEY PAYMENTS_PROVIDER
STORAGE_PROVIDER MAPS_PROVIDER VIN_DECODER LLM_PROVIDER PHOTO_PROVIDER QUO_PROVIDER RENTALCOVER_API_BASE APP_APPLE_TEAM_ID APP_ANDROID_CERT_SHA256
AUTH_OAUTH_PROVIDERS CLOUDFLARE_ACCOUNT_ID WORKERS_AI_API_TOKEN
SUPABASE_SERVICE_ROLE_KEY SUPABASE_JWT_SECRET STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET LINK_SIGNING_KEY PAYOUT_ENCRYPTION_KEY TURNSTILE_SECRET_KEY
GOOGLE_MAPS_API_KEY GOOGLE_REVIEWS_CLIENT_ID GOOGLE_REVIEWS_CLIENT_SECRET QUO_API_KEY QUO_WEBHOOK_SECRET GEMINI_API_KEY META_APP_SECRET WHATSAPP_TOKEN
RENTALCOVER_API_KEY TWILIO_ACCOUNT_SID TWILIO_API_KEY TWILIO_API_SECRET TWILIO_CALLER_ID TWILIO_AUTH_TOKEN AUTH_SMS_HOOK_SECRET VAPID_PUBLIC_KEY
VAPID_PRIVATE_KEY WALLET_PASS_CERT WALLET_PASS_KEY WALLET_WWDR_CERT WALLET_PASS_TYPE_ID WALLET_TEAM_ID FCM_SERVICE_ACCOUNT RESEND_API_KEY"

envfile() {
  local out="$1" n v skipped=""
  umask 077
  : > "$out"
  for n in $NAMES; do
    v="${!n:-}"
    [ -n "$v" ] || continue
    # one line, single quoted (read as written by docker compose and by a shell); a value that cannot be is left out and named
    if [[ "$v" == *$'\n'* ]] || [[ "$v" == *"'"* ]]; then skipped="$skipped $n"; continue; fi
    printf "%s='%s'\n" "$n" "$v" >> "$out"
  done
  say "settings: $(wc -l < "$out" | tr -d ' ') names written"
  if [ -n "$skipped" ]; then echo "::warning title=deploy-vps::left out (a value of several lines or with a quote; give it in base64):$skipped"; fi
}

load_vps() {
  # shellcheck source=vps.sh
  declare -F vps_ssh > /dev/null || . "$HERE/vps.sh"
}

hostnames() {
  local h="${WEB_VPS_HOSTNAMES:-}"
  h="$(tr -d '[:space:]' <<<"$h" | tr 'A-Z' 'a-z')"
  [[ "$h" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(,[a-z0-9]([a-z0-9.-]*[a-z0-9])?)*$ ]] || die "Set the repository variable WEB_VPS_HOSTNAMES (comma separated hostnames, e.g. the temporary one first)"
  echo "$h"
}

ship() {
  local image="$1" envf="$2" tag="${WEB_IMAGE_TAG:?WEB_IMAGE_TAG}" hosts cron="${WEB_CRON:-keep}" t="/tmp/carmacars-web-deploy"
  hosts="$(hostnames)"
  case "$cron" in keep|on|off) ;; *) die "WEB_CRON must be keep, on or off" ;; esac
  [[ "$tag" =~ ^[0-9a-f]{7,40}$ ]] || die "WEB_IMAGE_TAG must be a commit id"
  load_vps
  local stage; stage="$(mktemp -d)"
  sed "s/^__WEB_HOSTNAMES__/${hosts//,/, }/" "$ROOT/infra/vps/web/site.caddy" > "$stage/web.caddy"
  cp "$ROOT/infra/vps/web/docker-compose.yml" "$stage/docker-compose.yml"
  cp "$ROOT/infra/vps/supabase/docker-compose.yml" "$stage/supabase-compose.yml"
  cp "$ROOT/infra/vps/supabase/caddy/Caddyfile" "$stage/Caddyfile"
  cp "$envf" "$stage/web.env"; cp "$image" "$stage/image.tgz"
  sed -e "s/@TAG@/$tag/" -e "s/@CRON@/$cron/" "$HERE/web-vps-remote.sh" > "$stage/remote.sh"
  vps_ssh "rm -rf $t && install -d -m 700 $t"
  vps_scp "$stage"/* "$t/"
  rm -rf "$stage"
  vps_ssh "sudo bash $t/remote.sh deploy; rc=\$?; sudo rm -rf $t; exit \$rc" || die "The server did not take the deploy (see the lines above); the Cloudflare Worker is untouched"
  local first="${hosts%%,*}" i code=""
  for i in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$first/api/health" || true)
    [ "$code" = 200 ] && break
    sleep 6
  done
  [ "$code" = 200 ] || die "https://$first/api/health answered ${code:-nothing} after 4 minutes: check the hostname's DNS-only A record points at the server (Caddy needs it for the certificate)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=deploy-vps::$tag is running on the server and https://$first/api/health answers 200 (cron: $cron). DNS for the public site is unchanged."; fi
}

rollback() {
  load_vps
  vps_scp "$HERE/web-vps-remote.sh" /tmp/carmacars-web-remote.sh
  vps_ssh "sudo bash /tmp/carmacars-web-remote.sh rollback; rc=\$?; sudo rm -f /tmp/carmacars-web-remote.sh; exit \$rc" || die "The rollback did not complete"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  envfile) envfile "$@" ;;
  ship) ship "$@" ;;
  rollback) rollback ;;
  *) die "usage: web-vps.sh envfile <out> | ship <image.tgz> <web.env> | rollback" ;;
esac
