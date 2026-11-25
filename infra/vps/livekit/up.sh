#!/usr/bin/env bash
# r50 (5010): the media server, started or refreshed. Run by the deploy (web-vps-remote.sh livekit_up) and daily by
# carmacars-livekit-tls.timer (the TURN certificate, which Caddy renews for meet.<domain>). Never fails a deploy: the site
# offers the outside call link while the media server is down.
#   /opt/carmacars/livekit/livekit.env   LIVEKIT_HOST, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_WEBHOOK (mode 600)
set -uo pipefail
L=/opt/carmacars/livekit
say() { echo "[livekit] $*"; }
[ -s "$L/livekit.env" ] || { say "no livekit.env: not set up by a deploy yet"; exit 0; }
# shellcheck disable=SC1091
. "$L/livekit.env"
[ -n "${LIVEKIT_HOST:-}" ] && [ -n "${LIVEKIT_API_KEY:-}" ] && [ -n "${LIVEKIT_API_SECRET:-}" ] || { say "livekit.env is incomplete"; exit 0; }
install -d -m 700 "$L/tls"
# the TURN certificate: Caddy's Let's Encrypt certificate of the media host, copied out of its data volume
D="/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$LIVEKIT_HOST"
tls=off
if docker exec supabase-caddy test -s "$D/$LIVEKIT_HOST.crt" 2>/dev/null; then
  docker exec supabase-caddy cat "$D/$LIVEKIT_HOST.crt" > "$L/tls/cert.pem.new" && docker exec supabase-caddy cat "$D/$LIVEKIT_HOST.key" > "$L/tls/key.pem.new"
  if [ -s "$L/tls/cert.pem.new" ] && [ -s "$L/tls/key.pem.new" ]; then chmod 600 "$L/tls/"*.new; mv -f "$L/tls/cert.pem.new" "$L/tls/cert.pem"; mv -f "$L/tls/key.pem.new" "$L/tls/key.pem"; tls=on; fi
fi
new="$(mktemp)"
sed -e "s|@KEY@|$LIVEKIT_API_KEY|g" -e "s|@SECRET@|$LIVEKIT_API_SECRET|g" -e "s|@HOST@|$LIVEKIT_HOST|g" -e "s|@WEBHOOK@|$LIVEKIT_WEBHOOK|g" "$L/livekit.yaml.tmpl" > "$new"
[ "$tls" = on ] || sed -i '/# tls-begin/,/# tls-end/d' "$new"
cert=""; [ -f "$L/tls/cert.pem" ] && cert="$(sha256sum "$L/tls/cert.pem" | cut -c1-16)"
changed=1
if [ -f "$L/livekit.yaml" ] && cmp -s "$new" "$L/livekit.yaml" && [ "$cert" = "$(grep -s '^cert=' "$L/state" | cut -d= -f2)" ]; then changed=0; fi
install -m 600 "$new" "$L/livekit.yaml"; rm -f "$new"
dc() { docker compose --project-directory "$L" -f "$L/docker-compose.yml" "$@"; }
if [ "$changed" = 1 ] || ! docker inspect -f '{{.State.Running}}' carmacars-livekit 2>/dev/null | grep -q true; then
  dc up -d --force-recreate > /dev/null 2>&1 && say "running (TURN over TLS: $tls)" || { say "WARNING: the media server did not start; the outside call link is the fallback"; exit 0; }
else say "running, unchanged (TURN over TLS: $tls)"; fi
printf 'tls=%s\ncert=%s\nat=%s\n' "$tls" "$cert" "$(date -u +%FT%TZ)" > "$L/state"
exit 0
