#!/usr/bin/env bash
# Release 42: the server's side of scripts/deploy/web-vps.sh (run there as root). @TAG@ and @CRON@ are filled in by
# web-vps.sh ship; the files it copied are next to this script.
#   deploy    the image loaded, /opt/carmacars/web installed, the container started and healthy, then Caddy's site file
#   rollback  the image that ran before the last deploy
# The Supabase stack is touched in one way only: the first run gives its Caddy the folder of site files (the container
# is recreated once, a few seconds), and only when that mount is the whole difference to the server's compose file.
set -euo pipefail
T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W=/opt/carmacars/web
S=/opt/carmacars/supabase
TAG="@TAG@"
CRON="@CRON@"
say() { echo "[web-vps] $*"; }
dcw() { docker compose --project-directory "$W" -f "$W/docker-compose.yml" "$@"; }

healthy() {
  local i st=none
  for i in $(seq 1 60); do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' carmacars-web 2>/dev/null || echo none)
    [ "$st" = healthy ] && return 0
    sleep 3
  done
  say "the container is $st after 3 minutes; its last lines:"; docker logs --tail 60 carmacars-web 2>&1 | sed 's/^/  /' || true
  return 1
}

start() { # tag
  local cron
  cron=$(grep -s '^CRON_ENABLED=' "$W/.env" | cut -d= -f2 || true)
  case "$CRON" in on) cron=1 ;; off) cron=0 ;; esac
  printf 'WEB_IMAGE_TAG=%s\nCRON_ENABLED=%s\n' "$1" "${cron:-0}" > "$W/.env"
  dcw up -d --remove-orphans
  healthy
  say "running carmacars-web:$1 (cron $( [ "${cron:-0}" = 1 ] && echo on || echo off ))"
}

caddy_site() {
  install -d -m 755 "$S/caddy/sites"
  if ! docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' supabase-caddy | grep -q '/etc/caddy/sites'; then
    # the mount and the import line must be the whole difference: anything else waits for vps-ops (never applied from here)
    if ! diff -q <(grep -v -e 'caddy/sites' -e 'release 42: the website' "$T/supabase-compose.yml") "$S/docker-compose.yml" > /dev/null; then
      say "the server's Supabase compose file differs from this commit's by more than the site folder: run vps-ops (reboot installs it), then this job again"; return 1
    fi
    # the Caddyfile of this commit is checked with the same Caddy image before the container is recreated with it
    if ! docker run --rm -e API_HOSTNAME=api.example.com -e ACME_EMAIL=admin@example.com -v "$T/Caddyfile:/etc/caddy/Caddyfile:ro" \
         "$(docker inspect -f '{{.Config.Image}}' supabase-caddy)" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1; then
      say "this commit's Caddyfile does not validate: nothing was changed"; return 1
    fi
    cp -p "$S/docker-compose.yml" "/opt/carmacars/state/docker-compose.yml.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
    install -m 644 "$T/supabase-compose.yml" "$S/docker-compose.yml"
    install -m 644 "$T/Caddyfile" "$S/caddy/Caddyfile"
    # no site file yet: Caddy comes back with exactly what it served before
    rm -f "$S/caddy/sites/web.caddy"
    /opt/carmacars/bin/dc up -d --no-deps caddy
    sleep 5
    say "Caddy recreated with the site folder"
  fi
  local old=""
  [ -f "$S/caddy/sites/web.caddy" ] && old="$(mktemp)" && cp "$S/caddy/sites/web.caddy" "$old"
  install -m 644 "$T/web.caddy" "$S/caddy/sites/web.caddy"
  # a reload Caddy refuses leaves the running configuration as it was; the file is then put back
  if ! docker exec supabase-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
    if [ -n "$old" ]; then install -m 644 "$old" "$S/caddy/sites/web.caddy"; else rm -f "$S/caddy/sites/web.caddy"; fi
    say "Caddy refused the site file; it keeps serving what it served"; return 1
  fi
  [ -n "$old" ] && rm -f "$old"
  say "Caddy serves: $(sed -n 's/ {$//p' "$S/caddy/sites/web.caddy" | grep -v '^[[:space:]#]' | head -1)"
}

case "${1:-}" in
  deploy)
    install -d -m 750 "$W"
    gunzip -c "$T/image.tgz" | docker load
    install -m 644 "$T/docker-compose.yml" "$W/docker-compose.yml"
    install -m 600 "$T/web.env" "$W/web.env"
    prev=$(docker inspect -f '{{.Config.Image}}' carmacars-web 2>/dev/null | sed 's/^carmacars-web://' || true)
    if [ -n "$prev" ] && [ "$prev" != "$TAG" ]; then echo "$prev" > "$W/previous-tag"; fi
    start "$TAG"
    caddy_site
    # the last four images are kept (a rollback needs the one before)
    docker images carmacars-web --format '{{.CreatedAt}}\t{{.Tag}}' | sort -r | awk -F'\t' 'NR>4 {print $2}' | xargs -r -I{} docker rmi "carmacars-web:{}" > /dev/null 2>&1 || true
    ;;
  rollback)
    prev=$(cat "$W/previous-tag" 2>/dev/null || true)
    [ -n "$prev" ] || { say "no earlier image is recorded"; exit 1; }
    docker image inspect "carmacars-web:$prev" > /dev/null 2>&1 || { say "the image carmacars-web:$prev is no longer on the server"; exit 1; }
    CRON=keep
    start "$prev"
    ;;
  *) echo "usage: remote.sh deploy|rollback" >&2; exit 2 ;;
esac
