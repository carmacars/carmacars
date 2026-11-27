#!/usr/bin/env bash
# Release 48 (3070): the Cloudflare side of the move to the company's server, through the API only (no dashboard clicks).
# docs/hosting/off-cloudflare.md, section 6. Run by deploy-vps (.github/workflows/deploy-vps.yml) and ci.yml with the
# CI token CLOUDFLARE_API_TOKEN (the one wrangler and scripts/deploy/cloudflare.sh use). Every step is idempotent: run it
# twice and the second run changes nothing. A step the token may not do is named with the exact permission it needs, and
# the script goes on with the rest; the list is printed at the end (and in the job summary).
#   cf-site.sh prepare              A: the `new` record (proxied) to the server, visitor location headers on, SSL Full
#                                   (strict) (Full when another proxied host of the zone has no publicly valid certificate)
#   cf-site.sh origin-cert <dir> [current.pem]   the Cloudflare Origin CA certificate of the web hostnames (ORIGIN_HOSTS), never *.DOMAIN (15 years):
#                                   prints `reuse` when current.pem still covers them for 30 days or more, else creates one
#                                   (dir/cert.pem, dir/key.pem; the key is made here and never leaves this job but to the
#                                   server) and prints `new`; prints `none` when the token may not (Caddy then uses HTTP-01)
#   cf-site.sh https-off            Always Use HTTPS off (only for HTTP-01, the fallback without an Origin CA certificate)
#   cf-site.sh switch               B: the Worker's cron trigger deleted, its DOMAIN and www custom domains and routes
#                                   removed, A records (proxied) for DOMAIN and www to the server. Writes
#                                   CF_WORKER_CRON=off|on to GITHUB_ENV: the server's cron goes on only when the Worker's is off
#   cf-site.sh unswitch             the rollback of B: the A records to the server removed, the Worker's custom domains and
#                                   its cron trigger back
#   cf-site.sh media NAME           r50 (5010): the media server's record (calls in the site, LiveKit): exactly one A NAME ->
#                                   the server, DNS-only (grey): WebRTC and TURN cannot pass Cloudflare's proxy
#   cf-site.sh live-on              worker or vps (where DOMAIN is served now), for ci.yml: WEB_LIVE_ON_INPUT (worker|vps)
#                                   wins, then WEB_LIVE_ON_VAR=vps, else read from the zone; exits 1 when it cannot be read
# Environment: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, DOMAIN (carmacars.ca), WORKER_NAME (carmacars-prod),
# DEPLOY_HOST (the server; an IPv4 address or a name, else infra/vps/host), WEB_VPS_HOSTNAMES, CF_API (tests).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CF_API="${CF_API:-https://api.cloudflare.com/client/v4}"
DOMAIN="${DOMAIN:-carmacars.ca}"
W="${WORKER_NAME:-carmacars-prod}"
ACC="${CLOUDFLARE_ACCOUNT_ID:-}"
MISSING=()

say() { echo "[cf-site] $*" >&2; }
note() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice title=cloudflare::$*" >&2; else say "$*"; fi; }
warn() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning title=cloudflare::$*" >&2; else say "WARNING: $*"; fi; }
die() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error title=cloudflare::$*" >&2; else say "ERROR: $*"; fi; exit 1; }
# a permission the token lacks: named once, the run goes on
need() { local p="$1" what="$2"; MISSING+=("$p ($what)"); warn "The API token lacks $p: $what was not done"; }
report() {
  [ "${#MISSING[@]}" -gt 0 ] || { say "every step was allowed"; return 0; }
  local m; m="$(printf '%s; ' "${MISSING[@]}")"
  warn "Token permissions missing: ${m%; }"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then { echo "### Cloudflare token: permissions missing"; printf -- '- %s\n' "${MISSING[@]}"; } >> "$GITHUB_STEP_SUMMARY"; fi
}
setenv() { export "$1=$2"; if [ -n "${GITHUB_ENV:-}" ]; then echo "$1=$2" >> "$GITHUB_ENV"; fi; }

# cf METHOD PATH [JSON]: the result's JSON on stdout; on failure 1, with Cloudflare's errors on stderr and in CF_ERR
CF_ERR=""
cf() {
  local m="$1" p="$2" d="${3:-}" out code
  out=$(mktemp)
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "CLOUDFLARE_API_TOKEN is not in this job"
  if [ -n "$d" ]; then
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$m" "$CF_API$p" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'content-type: application/json' --data-binary "$d" || echo 000)
  else
    code=$(curl -sS -o "$out" -w '%{http_code}' -X "$m" "$CF_API$p" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" || echo 000)
  fi
  if [ "$(jq -r '.success // false' "$out" 2>/dev/null)" != true ]; then
    CF_ERR="HTTP $code $(jq -c '[.errors[]? | "\(.code) \(.message)"]' "$out" 2>/dev/null | head -c 400)"
    say "$m $p: $CF_ERR"
    rm -f "$out"; return 1
  fi
  CF_ERR=""
  cat "$out"; rm -f "$out"
}
# a refusal for permissions (9109, 10000, 10405, 403) rather than a bad request
denied() { [[ "$CF_ERR" == *"HTTP 403"* || "$CF_ERR" == *'"9109 '* || "$CF_ERR" == *'"10000 '* || "$CF_ERR" == *'"10405 '* ]]; }

zone_id() {
  [ -n "${ZONE:-}" ] && { echo "$ZONE"; return; }
  ZONE=$(cf GET "/zones?name=$DOMAIN" | jq -r '.result[0].id // empty') || ZONE=""
  [ -n "$ZONE" ] || die "The token cannot read the zone $DOMAIN (it needs Zone > Zone > Read for $DOMAIN)"
  echo "$ZONE"
}

server_ip() {
  local h ip=""
  h="$(tr -d '[:space:]' <<<"${DEPLOY_HOST:-}")"
  # DEPLOY_HOST when it is an address; else the committed one (a name may sit behind Cloudflare's proxy and resolve to it)
  if [[ "$h" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then ip="$h"
  else ip=$(grep -v '^[[:space:]]*#' "$ROOT/infra/vps/host" 2>/dev/null | tr -d '[:space:]' | head -c 64 || true)
    if [ -z "$ip" ] && [ -n "$h" ]; then ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1 {print $1}'); fi
  fi
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "No IPv4 address for the server (DEPLOY_HOST, infra/vps/host)"
  echo "$ip"
}

# upsert_a NAME IP: exactly one proxied A record NAME -> IP; other A, AAAA and CNAME records of NAME are removed
upsert_a() {
  local name="$1" ip="$2" z recs keep="" r id t c p
  z=$(zone_id)
  recs=$(cf GET "/zones/$z/dns_records?name=$name&per_page=100") || { need "Zone > DNS > Edit" "read the records of $name"; return 1; }
  for r in $(jq -r '.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME") | "\(.id)|\(.type)|\(.content)|\(.proxied)"' <<<"$recs"); do
    IFS='|' read -r id t c p <<<"$r"
    if [ "$t" = A ] && [ "$c" = "$ip" ] && [ -z "$keep" ]; then
      keep="$id"
      if [ "$p" != true ]; then cf PATCH "/zones/$z/dns_records/$id" '{"proxied":true}' > /dev/null || { need "Zone > DNS > Edit" "proxy $name"; return 1; }; say "$name: proxied"; fi
      continue
    fi
    cf DELETE "/zones/$z/dns_records/$id" > /dev/null || { need "Zone > DNS > Edit" "remove $t $name -> $c"; return 1; }
    note "DNS: removed $t $name -> $c"
  done
  if [ -n "$keep" ]; then say "$name: A $ip (proxied) already there"; return 0; fi
  cf POST "/zones/$z/dns_records" "$(jq -nc --arg n "$name" --arg ip "$ip" '{type: "A", name: $n, content: $ip, proxied: true, ttl: 1, comment: "the website on the company server (deploy-vps)"}')" > /dev/null \
    || { if denied; then need "Zone > DNS > Edit" "add A $name -> $ip"; else warn "A $name -> $ip was refused: $CF_ERR"; fi; return 1; }
  note "DNS: A $name -> $ip (proxied)"
}

# media_a NAME: exactly one DNS-only A record NAME -> the server (the media server for the calls in the site, r50 5010);
# other A, AAAA and CNAME records of NAME are removed. Its certificate is Let's Encrypt over HTTP-01, straight to Caddy.
media_a() {
  local name="$1" ip z recs keep="" r id t c p
  [[ "$name" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "usage: cf-site.sh media NAME"
  ip=$(server_ip); z=$(zone_id)
  recs=$(cf GET "/zones/$z/dns_records?name=$name&per_page=100") || { need "Zone > DNS > Edit" "read the records of $name"; return 1; }
  for r in $(jq -r '.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME") | "\(.id)|\(.type)|\(.content)|\(.proxied)"' <<<"$recs"); do
    IFS='|' read -r id t c p <<<"$r"
    if [ "$t" = A ] && [ "$c" = "$ip" ] && [ -z "$keep" ]; then
      keep="$id"
      if [ "$p" != false ]; then cf PATCH "/zones/$z/dns_records/$id" '{"proxied":false}' > /dev/null || { need "Zone > DNS > Edit" "make $name DNS-only"; return 1; }; note "DNS: $name DNS-only"; fi
      continue
    fi
    cf DELETE "/zones/$z/dns_records/$id" > /dev/null || { need "Zone > DNS > Edit" "remove $t $name -> $c"; return 1; }
    note "DNS: removed $t $name -> $c"
  done
  if [ -n "$keep" ]; then say "$name: A $ip (DNS-only) already there"; return 0; fi
  cf POST "/zones/$z/dns_records" "$(jq -nc --arg n "$name" --arg ip "$ip" '{type: "A", name: $n, content: $ip, proxied: false, ttl: 300, comment: "the media server for calls in the site (deploy-vps, r50)"}')" > /dev/null \
    || { if denied; then need "Zone > DNS > Edit" "add A $name -> $ip"; else warn "A $name -> $ip was refused: $CF_ERR"; fi; return 1; }
  note "DNS: A $name -> $ip (DNS-only, for the calls in the site)"
}

# drop_a NAME IP: the A records NAME -> IP removed (the rollback); nothing else of NAME is touched
drop_a() {
  local name="$1" ip="$2" z id
  z=$(zone_id)
  for id in $(cf GET "/zones/$z/dns_records?name=$name&type=A&per_page=100" | jq -r --arg ip "$ip" '.result[] | select(.content == $ip) | .id'); do
    cf DELETE "/zones/$z/dns_records/$id" > /dev/null || { need "Zone > DNS > Edit" "remove A $name -> $ip"; return 1; }
    note "DNS: removed A $name -> $ip"
  done
}

setting() { # name value permission-label
  local z cur; z=$(zone_id)
  cur=$(cf GET "/zones/$z/settings/$1" | jq -r '.result.value // empty') || cur=""
  if [ "$cur" = "$2" ]; then say "$1: $2 already"; return 0; fi
  if cf PATCH "/zones/$z/settings/$1" "$(jq -nc --arg v "$2" '{value: $v}')" > /dev/null; then note "$1: ${cur:-?} -> $2"
  else need "Zone > Zone Settings > Edit" "$1 = $2 (now ${cur:-unreadable})"; return 1; fi
}

location_headers() {
  local z cur; z=$(zone_id)
  cur=$(cf GET "/zones/$z/managed_headers" | jq -r '[.result.managed_request_headers[]? | select(.id == "add_visitor_location_headers") | .enabled][0] // empty') || cur=""
  if [ "$cur" = true ]; then say "visitor location headers: on already"; return 0; fi
  if cf PATCH "/zones/$z/managed_headers" '{"managed_request_headers":[{"id":"add_visitor_location_headers","enabled":true}],"managed_response_headers":[]}' > /dev/null; then
    note "Managed Transforms: \"Add visitor location headers\" on"
  else need "Zone > Transform Rules > Edit" "turn on the managed transform \"Add visitor location headers\""; fi
}

# SSL Full (strict) checks every proxied origin of the zone. Another proxied host whose origin has no certificate a browser
# would accept would break under strict: then Full (which still encrypts and accepts the Origin CA certificate) and say so.
ssl_mode() {
  local z ip recs r name t c bad="" rc
  z=$(zone_id); ip=$(server_ip)
  cf PATCH "/zones/$z/settings/ssl_automatic_mode" '{"value":"custom"}' > /dev/null 2>&1 || true
  recs=$(cf GET "/zones/$z/dns_records?proxied=true&per_page=500") || recs='{"result":[]}'
  for r in $(jq -r --arg ip "$ip" '.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME") | select(.content != $ip and .content != "100::" and (.content | startswith("192.0.2.") | not)) | "\(.name)|\(.type)|\(.content)"' <<<"$recs"); do
    IFS='|' read -r name t c <<<"$r"
    rc=0
    case "$t" in
      A) curl -sS -o /dev/null --max-time 8 --resolve "$name:443:$c" "https://$name/" 2>/dev/null || rc=$? ;;
      AAAA) curl -sS -o /dev/null --max-time 8 --resolve "$name:443:[$c]" "https://$name/" 2>/dev/null || rc=$? ;;
      CNAME) curl -sS -o /dev/null --max-time 8 --connect-to "$name:443:$c:443" "https://$name/" 2>/dev/null || rc=$? ;;
    esac
    case "$rc" in 35|51|58|60|77|83|90|91) bad="$bad $name" ;; esac
  done
  if [ -n "$bad" ]; then
    warn "SSL: these proxied hosts have no publicly valid certificate at their origin:$bad. The zone is set to Full (not strict) so they keep working; set Full (strict) once they have one"
    setting ssl full || true
  else
    setting ssl strict || true
  fi
}

prepare() {
  local ip; ip=$(server_ip)
  zone_id > /dev/null
  upsert_a "new.$DOMAIN" "$ip" || true
  location_headers
  ssl_mode
  report
}

# ------------------------------------------------------------------ the Origin CA certificate
# r50 infra: the exact web hostnames (ORIGIN_HOSTS, comma separated; default DOMAIN and www.DOMAIN), never *.DOMAIN. A
# wildcard loaded in Caddy also matches the DNS-only hosts (api., meet.): Caddy then stops managing their Let's Encrypt
# certificates and serves the Origin CA one, which browsers, the web container and vps-health refuse (run 45653284663).
origin_hosts() { local h="${ORIGIN_HOSTS:-$DOMAIN,www.$DOMAIN}"; tr ',' '\n' <<<"${h// /}" | grep -v '^$' | sort -u; }
covers() { # cert.pem: every origin_hosts name and no wildcard, from Cloudflare's Origin CA, 30 days or more left
  local f="$1" san h
  [ -s "$f" ] || return 1
  openssl x509 -in "$f" -noout -checkend 2592000 > /dev/null 2>&1 || return 1
  openssl x509 -in "$f" -noout -issuer 2>/dev/null | grep -qi 'CloudFlare.*Origin' || return 1
  san=$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/^[[:space:]]*DNS://p')
  grep -qF '*' <<<"$san" && return 1
  for h in $(origin_hosts); do grep -qxF "$h" <<<"$san" || return 1; done
  return 0
}

origin_cert() {
  local dir="$1" cur="${2:-}" csr body out
  if [ -n "$cur" ] && covers "$cur"; then say "Origin CA certificate: the server's still covers $(origin_hosts | paste -sd' ') ($(openssl x509 -in "$cur" -noout -enddate | cut -d= -f2))"; echo reuse; return 0; fi
  install -d -m 700 "$dir"
  ( umask 077; openssl ecparam -name prime256v1 -genkey -noout -out "$dir/key.pem" 2>/dev/null )
  csr=$(openssl req -new -key "$dir/key.pem" -subj "/O=CarmaCars/CN=$DOMAIN" 2>/dev/null)
  body=$(origin_hosts | jq -Rnc --arg csr "$csr" '{hostnames: [inputs], requested_validity: 5475, request_type: "origin-ecc", csr: $csr}')
  if out=$(cf POST "/certificates" "$body"); then
    jq -r '.result.certificate' <<<"$out" > "$dir/cert.pem"
    if covers "$dir/cert.pem"; then
      note "Origin CA certificate created for $(origin_hosts | paste -sd' ') (15 years, $(openssl x509 -in "$dir/cert.pem" -noout -serial))"
      echo new; report; return 0
    fi
    warn "Cloudflare answered a certificate that does not cover exactly $(origin_hosts | paste -sd' ')"
  else
    need "Zone > SSL and Certificates > Edit" "create a Cloudflare Origin CA certificate (Caddy falls back to Let's Encrypt over HTTP-01)"
  fi
  rm -f "$dir/key.pem" "$dir/cert.pem"
  echo none; report
}

# proxy NAME on|off: the A records NAME -> the server proxied (orange) or DNS-only (grey). Only for the Let's Encrypt
# window of web-vps.sh (no Origin CA certificate yet): Let's Encrypt reaches the server directly for the few minutes of
# issuance, then the record is proxied again. Prints how many records point at the server (0: NAME is not served here).
proxy_a() {
  local name="$1" want ip z recs r id p n=0
  case "${2:-}" in on) want=true ;; off) want=false ;; *) die "usage: cf-site.sh proxy NAME on|off" ;; esac
  ip=$(server_ip); z=$(zone_id)
  recs=$(cf GET "/zones/$z/dns_records?name=$name&type=A&per_page=100") || { need "Zone > DNS > Edit" "read the records of $name"; echo 0; return 0; }
  for r in $(jq -r --arg ip "$ip" '.result[] | select(.content == $ip) | "\(.id)|\(.proxied)"' <<<"$recs"); do
    IFS='|' read -r id p <<<"$r"
    n=$((n + 1))
    [ "$p" = "$want" ] && continue
    cf PATCH "/zones/$z/dns_records/$id" "{\"proxied\":$want}" > /dev/null || { need "Zone > DNS > Edit" "set $name proxied=$want"; return 1; }
    note "DNS: $name $( [ "$want" = true ] && echo 'proxied again' || echo 'DNS-only for the Let'"'"'s Encrypt window')"
  done
  echo "$n"
}

# ------------------------------------------------------------------ B: the switch, and its rollback
worker_cron() { # off|on|unknown: whether the Worker still has a cron trigger
  local s
  if s=$(cf GET "/accounts/$ACC/workers/scripts/$W/schedules"); then
    [ "$(jq '.result.schedules | length' <<<"$s")" = 0 ] && echo off || echo on
  elif [[ "$CF_ERR" == *'"10007 '* || "$CF_ERR" == *"HTTP 404"* ]]; then echo off   # no such Worker
  else echo unknown; fi
}

switch() {
  local ip z h id n cron out
  [ -n "$ACC" ] || die "CLOUDFLARE_ACCOUNT_ID is not in this job"
  ip=$(server_ip); z=$(zone_id)
  # 1. the Worker's cron trigger: the jobs must never run twice, so the server's goes on only once this one is gone
  cron=$(worker_cron)
  if [ "$cron" = on ]; then
    if cf PUT "/accounts/$ACC/workers/scripts/$W/schedules" '[]' > /dev/null; then note "Worker $W: cron trigger deleted"; cron=off
    else need "Account > Workers Scripts > Edit" "delete the cron trigger of $W"; fi
  elif [ "$cron" = unknown ]; then need "Account > Workers Scripts > Read" "read the cron trigger of $W"; fi
  setenv CF_WORKER_CRON "$cron"
  # 2. its custom domains and routes on DOMAIN and www
  n=0
  if out=$(cf GET "/accounts/$ACC/workers/domains?zone_id=$z"); then
    for id in $(jq -r --arg w "$W" --arg a "$DOMAIN" --arg b "www.$DOMAIN" '.result[]? | select(.service == $w and (.hostname == $a or .hostname == $b)) | .id' <<<"$out"); do
      cf DELETE "/accounts/$ACC/workers/domains/$id" > /dev/null && n=$((n + 1)) || need "Account > Workers Scripts > Edit" "remove a custom domain of $W ($id)"
    done
  else need "Account > Workers Scripts > Read" "read the custom domains of $W"; fi
  if out=$(cf GET "/zones/$z/workers/routes"); then
    for id in $(jq -r --arg w "$W" --arg a "$DOMAIN" --arg b "www.$DOMAIN" '.result[]? | select(.script == $w) | select((.pattern | sub("/.*$"; "")) as $h | $h == $a or $h == $b or $h == "*.\($a)") | .id' <<<"$out"); do
      cf DELETE "/zones/$z/workers/routes/$id" > /dev/null && n=$((n + 1)) || need "Zone > Workers Routes > Edit" "remove a route of $W ($id)"
    done
  else need "Zone > Workers Routes > Read" "read the Worker routes of $DOMAIN"; fi
  [ "$n" = 0 ] || note "Worker $W: $n custom domain(s) or route(s) on $DOMAIN and www removed"
  # 3. the site's records to the server
  for h in "$DOMAIN" "www.$DOMAIN"; do upsert_a "$h" "$ip" || true; done
  report
}

unswitch() {
  local ip z h body
  [ -n "$ACC" ] || die "CLOUDFLARE_ACCOUNT_ID is not in this job"
  ip=$(server_ip); z=$(zone_id)
  for h in "$DOMAIN" "www.$DOMAIN"; do
    drop_a "$h" "$ip" || continue
    body=$(jq -nc --arg h "$h" --arg w "$W" --arg z "$z" '{environment: "production", hostname: $h, service: $w, zone_id: $z}')
    if cf PUT "/accounts/$ACC/workers/domains" "$body" > /dev/null; then note "Worker $W: custom domain $h back"
    else need "Account > Workers Scripts > Edit" "attach $h to $W"; fi
  done
  # the server's cron is turned off before this step (deploy-vps, action rollback)
  if cf PUT "/accounts/$ACC/workers/scripts/$W/schedules" '[{"cron":"* * * * *"}]' > /dev/null; then note "Worker $W: cron trigger * * * * * back"
  else need "Account > Workers Scripts > Edit" "put back the cron trigger of $W"; fi
  report
}

# records: read only (deploy-vps action=test): each A record of the site's hostnames with its proxy state, and the SSL mode
records() {
  local z h; z=$(zone_id)
  for h in "api.$DOMAIN" "meet.$DOMAIN" "new.$DOMAIN" "$DOMAIN" "www.$DOMAIN"; do
    cf GET "/zones/$z/dns_records?name=$h&per_page=20" | jq -r '.result[]? | "[cf-site] \(.name) \(.type) \(.content) proxied=\(.proxied)"' || say "$h: the records cannot be read"
  done
  cf GET "/zones/$z/settings/ssl" | jq -r '"[cf-site] SSL mode: \(.result.value)"' || say "the SSL mode cannot be read"
  cf GET "/zones/$z/settings/always_use_https" | jq -r '"[cf-site] Always Use HTTPS: \(.result.value)"' || true
}

# ------------------------------------------------------------------ where the site is live (ci.yml)
live_on() {
  case "${WEB_LIVE_ON_INPUT:-auto}" in worker|vps) echo "$WEB_LIVE_ON_INPUT"; return 0 ;; auto|'') ;; *) die "web_live_on must be auto, worker or vps" ;; esac
  [ "${WEB_LIVE_ON_VAR:-}" = vps ] && { echo vps; return 0; }
  local z ip a d
  z=$(zone_id); ip=$(server_ip)
  a=$(cf GET "/zones/$z/dns_records?name=$DOMAIN&type=A&per_page=100") || { say "the records of $DOMAIN cannot be read"; return 1; }
  if jq -e --arg ip "$ip" 'any(.result[]?; .content == $ip)' <<<"$a" > /dev/null; then echo vps; return 0; fi
  d=$(cf GET "/accounts/$ACC/workers/domains?zone_id=$z") || { say "the Worker's custom domains cannot be read"; return 1; }
  if jq -e --arg w "$W" --arg h "$DOMAIN" 'any(.result[]?; .service == $w and .hostname == $h)' <<<"$d" > /dev/null; then echo worker; return 0; fi
  # neither (a switch stopped half way): never give the Worker its domains and cron back from a deploy
  echo vps
}

cmd="${1:-}"; shift || true
# the zone once, in this shell (a function run under `|| true` would not stop on a failure)
case "$cmd" in prepare|https-off|switch|unswitch|live-on|proxy|media|records) ZONE=$(zone_id) ;; esac
case "$cmd" in
  prepare) prepare ;;
  origin-cert) origin_cert "$@" ;;
  https-off) setting always_use_https off || true; report ;;
  switch) switch ;;
  unswitch) unswitch ;;
  live-on) live_on ;;
  server-ip) server_ip ;;
  proxy) proxy_a "$@" ;;
  media) media_a "$@"; report ;;
  records) records ;;
  *) die "usage: cf-site.sh prepare | origin-cert <dir> [current.pem] | https-off | switch | unswitch | live-on | server-ip | proxy NAME on|off | media NAME" ;;
esac
