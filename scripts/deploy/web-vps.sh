#!/usr/bin/env bash
# Release 42: the website on the company's server (docs/hosting/off-cloudflare.md), run by the deploy-vps job
# (.github/workflows/deploy-vps.yml). Nothing here changes DNS or the Cloudflare Worker.
#   scripts/deploy/web-vps.sh envfile <out>   the site's settings and secrets as NAME='value' lines (mode 600), from
#                                             this job's environment (the same names the Worker gets as secrets)
#   scripts/deploy/web-vps.sh ship <image.tgz> <web.env>   image, compose file and settings to the server, the
#                                             container started and healthy, Caddy's site file installed and loaded
#   scripts/deploy/web-vps.sh rollback        the image that ran before the last deploy, started again (action rollback-image)
#   scripts/deploy/web-vps.sh switch          no build: the running image restarted with WEB_CRON, Caddy reloaded (the
#                                             certificates of hostnames whose DNS just moved), each hostname checked
#   scripts/deploy/web-vps.sh forwarder       the inbound email forwarder (infra/cloudflare/email-forwarder, a Worker on
#                                             Cloudflare's free plan) deployed with its address and secret
#   scripts/deploy/web-vps.sh email forwarder|worker   every Email Routing rule that hands mail to the website Worker
#                                             now hands it to the forwarder (or back: the rollback)
# WEB_PROXY (cloudflare, the default, or off): whether Caddy trusts Cloudflare's free proxy in front of the server.
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
AUTH_OAUTH_PROVIDERS CLOUDFLARE_ACCOUNT_ID WORKERS_AI_API_TOKEN LOCAL_LLM_URL LOCAL_LLM_MODEL LOCAL_LLM_DIGEST LOCAL_VISION_MODEL LOCAL_VISION_DIGEST LOCAL_STT_URL R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET_PREFIX
SUPABASE_SERVICE_ROLE_KEY SUPABASE_JWT_SECRET STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET LINK_SIGNING_KEY PAYOUT_ENCRYPTION_KEY TURNSTILE_SECRET_KEY
GOOGLE_MAPS_API_KEY GOOGLE_REVIEWS_CLIENT_ID GOOGLE_REVIEWS_CLIENT_SECRET QUO_API_KEY QUO_WEBHOOK_SECRET GEMINI_API_KEY META_APP_SECRET WHATSAPP_TOKEN
RENTALCOVER_API_KEY TWILIO_ACCOUNT_SID TWILIO_API_KEY TWILIO_API_SECRET TWILIO_CALLER_ID TWILIO_AUTH_TOKEN TWILIO_TWIML_APP_SID AUTH_SMS_HOOK_SECRET VAPID_PUBLIC_KEY
VAPID_PRIVATE_KEY WALLET_PASS_CERT WALLET_PASS_KEY WALLET_WWDR_CERT WALLET_PASS_TYPE_ID WALLET_TEAM_ID FCM_SERVICE_ACCOUNT RESEND_API_KEY
CALLS_PROVIDER LIVEKIT_URL LIVEKIT_API_KEY LIVEKIT_API_SECRET"

# r50 (5010): the media server for the calls in the site. No new secret: its API key and secret are derived from
# LINK_SIGNING_KEY (as the email forwarder's), the host is meet.<DOMAIN> (CALLS_HOST overrides), the site signs each
# person's token and checks the webhook with them. CALLS_PROVIDER=off keeps the outside call link only.
calls_host() { local h="${CALLS_HOST:-meet.${DOMAIN:-carmacars.ca}}"; [[ "$h" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "CALLS_HOST is not a hostname"; echo "$h"; }
calls_env() {
  [ "${CALLS_PROVIDER:-livekit}" = off ] && { export CALLS_PROVIDER=off; return 0; }
  [ -n "${LINK_SIGNING_KEY:-}" ] || { export CALLS_PROVIDER=off; echo "::warning title=deploy-vps::LINK_SIGNING_KEY is not set: the calls stay on the outside link"; return 0; }
  _hmac() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$LINK_SIGNING_KEY" | awk '{print $NF}'; }
  export CALLS_PROVIDER=livekit LIVEKIT_URL="wss://$(calls_host)"
  [ -n "${LIVEKIT_API_KEY:-}" ] || LIVEKIT_API_KEY="CC$(_hmac carmacars-livekit-key-v1 | cut -c1-14)"
  [ -n "${LIVEKIT_API_SECRET:-}" ] || LIVEKIT_API_SECRET="$(_hmac carmacars-livekit-secret-v1)"
  export LIVEKIT_API_KEY LIVEKIT_API_SECRET
}

envfile() {
  local out="$1" n v skipped=""
  calls_env
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
  calls_env
  case "$cron" in keep|on|off) ;; *) die "WEB_CRON must be keep, on or off" ;; esac
  [[ "$tag" =~ ^[0-9a-f]{7,40}$ ]] || die "WEB_IMAGE_TAG must be a commit id"
  load_vps
  local stage; stage="$(mktemp -d)"
  sed "s/^__WEB_HOSTNAMES__/${hosts//,/, }/" "$ROOT/infra/vps/web/site.caddy" > "$stage/web.caddy"
  # Cloudflare's free proxy in front (the default): its published ranges, read now, are the only ones whose headers are kept
  if [ "${WEB_PROXY:-cloudflare}" = cloudflare ]; then
    local ranges
    ranges="$( { curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4; echo; curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6; } | grep -E '^[0-9a-fA-F:.]+/[0-9]{1,3}$' | tr '\n' ' ' || true)"
    [ "$(wc -w <<<"$ranges")" -ge 10 ] || die "Cloudflare's address ranges could not be read (www.cloudflare.com/ips-v4): nothing was changed. Run again, or set WEB_PROXY=off for a DNS-only site"
    sed -i "s|__CF_RANGES__|${ranges% }|" "$stage/web.caddy"
    say "Caddy trusts Cloudflare's proxy ($(wc -w <<<"$ranges") ranges)"
  else
    sed -i '/# proxy-begin/,/# proxy-end/d' "$stage/web.caddy"
    say "Caddy: DNS-only site (WEB_PROXY=off): no location headers"
  fi
  # r48 (3070): the Cloudflare Origin CA certificate (docs/hosting/off-cloudflare.md, section 4): the server's own while it
  # covers the domain, else a new one through the API; without one, Let's Encrypt over HTTP-01 as before
  origin_tls "$stage" "$hosts"
  cp "$ROOT/infra/vps/web/docker-compose.yml" "$stage/docker-compose.yml"
  cp "$ROOT/infra/vps/supabase/docker-compose.yml" "$stage/supabase-compose.yml"
  cp "$ROOT/infra/vps/supabase/caddy/Caddyfile" "$stage/Caddyfile"
  cp "$envf" "$stage/web.env"; cp "$image" "$stage/image.tgz"
  # r48 O: the background remover's image is built on the server from these files (web-vps-remote.sh)
  tar -C "$ROOT/infra/vps/web/rembg" -czf "$stage/rembg.tgz" .
  # r48 part AI: the server's own AI models (infra/vps/ai), flat for the copy
  cp "$ROOT/infra/vps/ai/docker-compose.yml" "$stage/ai-compose.yml"; cp "$ROOT/infra/vps/ai/models.env" "$stage/ai-models.env"
  cp "$ROOT/infra/vps/ai/warm.sh" "$stage/ai-warm.sh"; cp "$ROOT/infra/vps/ai/stt/Dockerfile" "$stage/ai-stt.Dockerfile"
  cp "$ROOT/infra/vps/ai/stt/entrypoint.sh" "$stage/ai-stt-entrypoint.sh"
  # r50 (5010): the media server (infra/vps/livekit): its files, its Caddy site and its settings (mode 600)
  if [ "${CALLS_PROVIDER:-}" = livekit ]; then
    local ch; ch="$(calls_host)"
    tar -C "$ROOT/infra/vps/livekit" -czf "$stage/livekit.tgz" docker-compose.yml livekit.yaml.tmpl up.sh
    sed "s/^__CALLS_HOST__/$ch/" "$ROOT/infra/vps/livekit/meet.caddy" > "$stage/meet.caddy"
    cp "$ROOT/infra/vps/systemd/carmacars-livekit-tls.service" "$ROOT/infra/vps/systemd/carmacars-livekit-tls.timer" "$stage/"
    ( umask 077; printf "LIVEKIT_HOST='%s'\nLIVEKIT_API_KEY='%s'\nLIVEKIT_API_SECRET='%s'\nLIVEKIT_WEBHOOK='%s'\n" "$ch" "$LIVEKIT_API_KEY" "$LIVEKIT_API_SECRET" "https://${hosts%%,*}/api/calls/webhook" > "$stage/livekit.env" )
    # its DNS-only record first, so Caddy can get its certificate as soon as it loads the site
    "$HERE/cf-site.sh" media "$ch" || warn_ "the media host $ch has no DNS record yet (the token needs Zone > DNS > Edit): calls use the outside link until it has"
  fi
  sed -e "s/@TAG@/$tag/" -e "s/@CRON@/$cron/" "$HERE/web-vps-remote.sh" > "$stage/remote.sh"
  vps_ssh "rm -rf $t && install -d -m 700 $t"
  vps_scp "$stage"/* "$t/"
  rm -rf "$stage"
  vps_ssh "sudo bash $t/remote.sh deploy; rc=\$?; sudo rm -rf $t; exit \$rc" || die "The server did not take the deploy (see the lines above); the Cloudflare Worker is untouched"
  acme_window "$hosts"
  local first="${hosts%%,*}" i code=""
  for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$first/api/health" || true)
    [ "$code" = 200 ] && break
    sleep 6
  done
  [ "$code" = 200 ] || tls_diag "$first"
  [ "$code" = 200 ] || die "https://$first/api/health answered ${code:-nothing} after 6 minutes: check the hostname's A record points at the server, SSL is Full (strict) and the Origin CA certificate is in place (the lines above)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=deploy-vps::$tag is running on the server and https://$first/api/health answers 200 (cron: $cron). DNS for the public site is unchanged."; fi
  ai_state
}

# r48 part AI: the server's own models as the warm-up last wrote them; "warming up" until each is downloaded and checked
# (never a failed deploy: the site's chain uses Workers AI and Gemini meanwhile)
ai_state() {
  local st k v line=""
  st="$(vps_ssh "cat /opt/carmacars/ai/state 2>/dev/null || true" 2>/dev/null || true)"
  for k in text vision speech; do
    v="$(grep "^$k=" <<<"$st" | tail -1 | cut -d= -f2- || true)"
    [ -n "$v" ] && [ "$v" != warming ] || v="warming up"
    line="$line $k $v;"
  done
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=AI models on the server::${line% ;} (the warm-up runs in the background; Admin > Settings > Usage shows the state)"; else say "AI models:${line% ;}"; fi
}

# origin_tls <stage> <hosts>: stage/origin-cert.pem and origin-key.pem when a new certificate is made; the origin-tls block
# of stage/web.caddy kept when the server has (or gets) one, else removed and "Always Use HTTPS" turned off (HTTP-01)
origin_tls() {
  local stage="$1" hosts="$2" h st=none dom="${DOMAIN:-carmacars.ca}" ok=1
  for h in ${hosts//,/ }; do [ "$h" = "$dom" ] || [[ "$h" =~ ^[a-z0-9-]+\.${dom//./\\.}$ ]] || ok=0; done
  if [ "${WEB_PROXY:-cloudflare}" != cloudflare ]; then say "TLS: Let's Encrypt (WEB_PROXY=off: a browser would not trust an Origin CA certificate)"
  elif [ "$ok" != 1 ]; then warn_ "TLS: a hostname outside $dom and *.$dom ($hosts): Let's Encrypt over HTTP-01"
  else
    vps_ssh "sudo cat /opt/carmacars/supabase/caddy/sites/origin/cert.pem 2>/dev/null || true" > "$stage/current.pem" || : > "$stage/current.pem"
    st=$(DOMAIN="$dom" "$HERE/cf-site.sh" origin-cert "$stage/origin" "$stage/current.pem") || st=none
    if [ "$st" = new ]; then
      install -m 600 "$stage/origin/cert.pem" "$stage/origin-cert.pem"; install -m 600 "$stage/origin/key.pem" "$stage/origin-key.pem"
    fi
    rm -rf "$stage/origin" "$stage/current.pem"
  fi
  if [ "$st" = new ] || [ "$st" = reuse ]; then say "TLS: Cloudflare Origin CA certificate ($st)"; return 0; fi
  sed -i '/# origin-tls-begin/,/# origin-tls-end/d' "$stage/web.caddy"
  # HTTP-01 behind the proxy needs port 80 answered as it is, not redirected by Cloudflare
  if [ "${WEB_PROXY:-cloudflare}" = cloudflare ]; then DOMAIN="$dom" "$HERE/cf-site.sh" https-off || true; fi
}
# acme_window <hosts>: without the Origin CA certificate (the token lacks Zone > SSL and Certificates > Edit), Let's Encrypt
# cannot validate through Cloudflare's proxy (run 44931738642: 525). Each hostname whose A record points at the server and
# that has no publicly trusted certificate with 30 days left is made DNS-only for the issuance (HTTP-01 or TLS-ALPN-01
# straight to Caddy; the server's address is already public through api.), Caddy asks again, and the record is proxied
# again as soon as the certificate is there, or after 10 minutes, and on any exit (trap). Cloudflare then talks to Caddy
# under Full (strict) with that certificate. Renewal: every deploy repeats this when 30 days or fewer are left.
# Nothing happens when the server uses the Origin CA certificate. Hostnames still on the Worker are skipped.
ACME_WIN=""
acme_restore() { local h; for h in $ACME_WIN; do "$HERE/cf-site.sh" proxy "$h" on > /dev/null || warn_ "$h could not be proxied again: run deploy-vps again (step A proxies it)"; done; ACME_WIN=""; }
has_cert() { # hostname: a certificate a browser trusts for it, 30 days or more left, served by Caddy on the server
  vps_ssh "echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername '$1' -verify_hostname '$1' -verify_return_error 2>/dev/null | openssl x509 -noout -checkend 2592000" > /dev/null 2>&1
}
tls_diag() { # hostname: what Caddy loaded and logged about its certificate (no secret in any of it)
  local h="${1%% *}"
  vps_ssh "set +e; S=/opt/carmacars/supabase
    echo \"[tls] Caddyfile imports the site folder (host, container): \$(sudo grep -c '^import sites/' \$S/caddy/Caddyfile), \$(sudo docker exec supabase-caddy grep -c '^import sites/' /etc/caddy/Caddyfile)\"
    echo \"[tls] hosts in Caddy's running config: \$(sudo docker exec supabase-caddy wget -qO- http://localhost:2019/config/apps/http/servers 2>/dev/null | jq -rc '[.. | .host? // empty | .[]] | unique | join(\" \")')\"
    echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername '$h' 2>&1 | grep -E '^(subject|issuer)=|Verify return code|alert' | sed 's/^/[tls] /'
    sudo docker logs supabase-caddy --since 40m 2>&1 | grep -vF 'http.log.access' | grep -iE 'tls|acme|certificate|$h' | tail -30 | cut -c1-600" || true
}
acme_window() {
  local hosts="$1" h n i left
  [ "${WEB_PROXY:-cloudflare}" = cloudflare ] || return 0
  if vps_ssh "sudo grep -q 'sites/origin/cert.pem' /opt/carmacars/supabase/caddy/sites/web.caddy" 2>/dev/null; then return 0; fi
  for h in ${hosts//,/ }; do
    if has_cert "$h"; then say "TLS: $h has a trusted certificate (30 days or more)"; continue; fi
    n=$("$HERE/cf-site.sh" proxy "$h" off) || n=0
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then ACME_WIN="$ACME_WIN $h"; else say "TLS: $h does not point at the server yet: skipped"; fi
  done
  [ -n "$ACME_WIN" ] || return 0
  trap acme_restore EXIT
  say "TLS: Let's Encrypt window (DNS-only) for:$ACME_WIN"
  sleep 20
  vps_ssh "sudo docker exec supabase-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force" > /dev/null 2>&1 || true
  for i in $(seq 1 60); do
    left=""
    for h in $ACME_WIN; do has_cert "$h" || left="$left $h"; done
    [ -z "$left" ] && break
    sleep 10
  done
  acme_restore; trap - EXIT
  if [ -n "$left" ]; then
    warn_ "TLS: no Let's Encrypt certificate after 10 minutes for:$left (Caddy's lines below)"
    tls_diag "${left# }"
  else
    say "TLS: Let's Encrypt certificate in place; records proxied again"
    sleep 15
  fi
}
warn_() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning title=deploy-vps::$*"; else echo "WARNING: $*"; fi; }

rollback() {
  load_vps
  vps_scp "$HERE/web-vps-remote.sh" /tmp/carmacars-web-remote.sh
  vps_ssh "sudo bash /tmp/carmacars-web-remote.sh rollback; rc=\$?; sudo rm -f /tmp/carmacars-web-remote.sh; exit \$rc" || die "The rollback did not complete"
}

switch() {
  local cron="${WEB_CRON:-keep}" hosts h i code
  hosts="$(hostnames)"
  case "$cron" in keep|on|off) ;; *) die "WEB_CRON must be keep, on or off" ;; esac
  load_vps
  local f; f="$(mktemp)"
  sed -e "s/@TAG@/none/" -e "s/@CRON@/$cron/" "$HERE/web-vps-remote.sh" > "$f"
  vps_scp "$f" /tmp/carmacars-web-remote.sh; rm -f "$f"
  vps_ssh "sudo bash /tmp/carmacars-web-remote.sh switch; rc=\$?; sudo rm -f /tmp/carmacars-web-remote.sh; exit \$rc" || die "The switch did not complete on the server (see the lines above)"
  acme_window "$hosts"
  for h in ${hosts//,/ }; do
    code=""
    for i in $(seq 1 30); do
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/api/health" || true)
      [ "$code" = 200 ] && break
      sleep 6
    done
    if [ "$code" = 200 ]; then echo "::notice title=deploy-vps::https://$h/api/health answers 200 (cron: $cron)"
    else echo "::warning title=deploy-vps::https://$h/api/health answered ${code:-nothing} after 3 minutes: check its DNS record points at the server"; fi
  done
}

# The inbound email forwarder: a Worker on Cloudflare's free plan. Its secret is derived from LINK_SIGNING_KEY with a
# fixed label (web/src/lib/platform/inbound-email.ts inboundSecret), so the Worker never holds the key itself.
forwarder() {
  local hosts first secret dir="$ROOT/infra/cloudflare/email-forwarder" ver
  hosts="$(hostnames)"; first="${hosts%%,*}"
  [ -n "${LINK_SIGNING_KEY:-}" ] || die "LINK_SIGNING_KEY is not in this job: the forwarder's secret cannot be made"
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] || die "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are needed to deploy the forwarder"
  secret="$(printf '%s' 'carmacars-inbound-email-v1' | openssl dgst -sha256 -hmac "$LINK_SIGNING_KEY" -r | cut -d' ' -f1)"
  [[ "$secret" =~ ^[0-9a-f]{64}$ ]] || die "The forwarder's secret could not be made"
  [ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::$secret"
  ver="$(node -p "require('$ROOT/web/package.json').devDependencies.wrangler.replace(/^[^0-9]*/, '')")"
  ( cd "$dir" && npx --yes "wrangler@$ver" deploy --var "INBOUND_URL:https://$first/api/inbound/email" --keep-vars \
    && printf '%s' "$secret" | npx --yes "wrangler@$ver" secret put INBOUND_EMAIL_SECRET ) || die "The email forwarder was not deployed (the token needs Account > Workers Scripts > Edit); inbound mail is unchanged"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=deploy-vps::email forwarder deployed (free plan); it posts to https://$first/api/inbound/email"; fi
}

# Every enabled Email Routing rule of the zone whose action is the website Worker (or the forwarder) is pointed at the
# other one. Only the action's Worker name changes: no address, no MX record, nothing of the root domain's mail.
email() {
  local to="${1:-}" from want zone rules n=0 r id body
  case "$to" in forwarder) from="carmacars-prod"; want="carmacars-email-forwarder" ;; worker) from="carmacars-email-forwarder"; want="carmacars-prod" ;; *) die "usage: web-vps.sh email forwarder|worker" ;; esac
  # shellcheck source=lib.sh
  declare -F cfapi > /dev/null || . "$HERE/lib.sh"
  zone=$(cfapi GET "/zones?name=${DOMAIN:-carmacars.ca}" 2>/dev/null | jq -r '.result[0].id // empty') || zone=""
  [ -n "$zone" ] || die "The token cannot read the zone ${DOMAIN:-carmacars.ca}"
  rules=$(cfapi GET "/zones/$zone/email/routing/rules?per_page=50" 2>/dev/null) || die "The token cannot read the Email Routing rules (Zone > Email Routing Rules > Edit). By hand: Cloudflare > ${DOMAIN:-carmacars.ca} > Email > Email Routing > Routing rules: Send to a Worker > $want"
  for r in $(jq -r --arg w "$from" '.result[]? | select(any(.actions[]?; .type == "worker" and (.value | index($w)))) | @base64' <<<"$rules"); do
    id=$(base64 -d <<<"$r" | jq -r '.id // .tag')
    body=$(base64 -d <<<"$r" | jq -c --arg w "$want" '{name, enabled, matchers, priority, actions: [.actions[] | if .type == "worker" then .value = [$w] else . end]} | with_entries(select(.value != null))')
    cfapi PUT "/zones/$zone/email/routing/rules/$id" "$body" > /dev/null || die "An Email Routing rule could not be changed (rule $id); set it by hand: Send to a Worker > $want"
    n=$((n + 1))
  done
  # the catch-all rule has its own address
  r=$(cfapi GET "/zones/$zone/email/routing/rules/catch_all" 2>/dev/null | jq -c --arg w "$from" '.result | select(. != null) | select(any(.actions[]?; .type == "worker" and (.value | index($w))))') || r=""
  if [ -n "$r" ]; then
    body=$(jq -c --arg w "$want" '{name, enabled, matchers, actions: [.actions[] | if .type == "worker" then .value = [$w] else . end]} | with_entries(select(.value != null))' <<<"$r")
    cfapi PUT "/zones/$zone/email/routing/rules/catch_all" "$body" > /dev/null || die "The catch-all Email Routing rule could not be changed; set it by hand: Send to a Worker > $want"
    n=$((n + 1))
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=deploy-vps::inbound email: $n rule(s) now send mail to the Worker $want"; else say "inbound email: $n rule(s) -> $want"; fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  envfile) envfile "$@" ;;
  ship) ship "$@" ;;
  rollback) rollback ;;
  forwarder) forwarder ;;
  switch) switch ;;
  email) email "$@" ;;
  *) die "usage: web-vps.sh envfile <out> | ship <image.tgz> <web.env> | rollback | forwarder | email forwarder|worker" ;;
esac
