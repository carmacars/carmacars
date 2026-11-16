#!/usr/bin/env bash
# Release 42: the server's side of scripts/deploy/web-vps.sh (run there as root). @TAG@ and @CRON@ are filled in by
# web-vps.sh ship; the files it copied are next to this script.
#   deploy    the image loaded, /opt/carmacars/web installed, the container started and healthy, then Caddy's site file
#   rollback  the image that ran before the last deploy
#   switch    no new image: the running one restarted with the cron setting asked for, and Caddy reloaded so it asks
#             for the certificates of hostnames whose DNS has just moved here (the DNS switch, in a minute or two)
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

# r48 (migration 2980): the site's LISTEN for queued texts and emails (web/src/lib/platform/db-listen.ts) logs in as
# carmacars_listen, a role that may connect and listen and nothing else. Its password is made here once and kept
# ($W/listen.pw, mode 600); the address is added to web.env. No role yet (the migration not applied): no listen, the
# minute tick sends as before.
listen_env() {
  local pw has
  has=$(docker exec supabase-db psql -U supabase_admin -d postgres -XAtq -c "select 1 from pg_roles where rolname = 'carmacars_listen'" 2>/dev/null || true)
  if [ "$has" != 1 ]; then say "listen: off (the database has no carmacars_listen role yet)"; return 0; fi
  [ -s "$W/listen.pw" ] || (umask 077; openssl rand -hex 24 > "$W/listen.pw")
  pw=$(tr -dc 'a-f0-9' < "$W/listen.pw")
  docker exec -i supabase-db psql -U supabase_admin -d postgres -XAtq -v ON_ERROR_STOP=1 > /dev/null <<SQL || { say "listen: off (the password was not set)"; return 0; }
alter role carmacars_listen with login password '$pw';
SQL
  printf "DATABASE_LISTEN_URL='postgresql://carmacars_listen:%s@supabase-db:5432/postgres'\n" "$pw" >> "$W/web.env"
  say "listen: on"
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
  # r48 (3070): the Cloudflare Origin CA certificate. A new one (sent by this deploy) is installed only when its key matches;
  # the site file's origin-tls block is dropped (Let's Encrypt over HTTP-01) when the server has no matching pair
  local O="$S/caddy/sites/origin"
  pair() { [ -s "$1" ] && [ -s "$2" ] && [ "$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null)" = "$(openssl pkey -in "$2" -pubout 2>/dev/null)" ]; }
  if [ -s "$T/origin-cert.pem" ]; then
    if pair "$T/origin-cert.pem" "$T/origin-key.pem"; then
      install -d -m 700 "$O"
      [ -s "$O/cert.pem" ] && cp -p "$O/cert.pem" "$O/cert.pem.prev" && cp -p "$O/key.pem" "$O/key.pem.prev"
      install -m 644 "$T/origin-cert.pem" "$O/cert.pem"; install -m 600 "$T/origin-key.pem" "$O/key.pem"
      say "Origin CA certificate installed (until $(openssl x509 -in "$O/cert.pem" -noout -enddate | cut -d= -f2))"
    else say "the Origin CA certificate sent does not match its key: not installed"; fi
  fi
  if grep -q 'origin-tls-begin' "$T/web.caddy" && ! pair "$O/cert.pem" "$O/key.pem"; then
    sed -i '/# origin-tls-begin/,/# origin-tls-end/d' "$T/web.caddy"
    say "no Origin CA certificate on the server: Let's Encrypt over HTTP-01"
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
    listen_env
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
  switch)
    cur=$(grep -s '^WEB_IMAGE_TAG=' "$W/.env" | cut -d= -f2 || true)
    [ -n "$cur" ] || { say "nothing is deployed yet: run the deploy action first"; exit 1; }
    start "$cur"
    docker exec supabase-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
    say "Caddy reloaded (certificates are asked for again now)"
    ;;
  *) echo "usage: remote.sh deploy|rollback|switch" >&2; exit 2 ;;
esac
