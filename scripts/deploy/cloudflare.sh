#!/usr/bin/env bash
# Cloudflare side of the deploy (ci workflow, deploy job). Idempotent.
#
#   scripts/deploy/cloudflare.sh token       check the API token and report what it may do
#   scripts/deploy/cloudflare.sh resources   R2 buckets and the D1 tag cache (its id into web/wrangler.jsonc)
#   scripts/deploy/cloudflare.sh turnstile   the Turnstile widget for the site; exports the keys, or turns
#                                            Turnstile off (TURNSTILE_PROVIDER=off) when the token cannot
#   scripts/deploy/cloudflare.sh dns         frees carmacars.ca and www for the Worker's custom domains: only
#                                            A, AAAA or CNAME records on those two names are removed (never
#                                            MX, TXT or anything else, never another name)
#   scripts/deploy/cloudflare.sh photos      the stand-in photos into the public bucket (once; a marker object
#                                            records it)
#
# Needs CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID; DEPLOY_ENV (production | staging), DOMAIN (carmacars.ca).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
ACC="${CLOUDFLARE_ACCOUNT_ID:?}"
DEPLOY_ENV="${DEPLOY_ENV:-production}"
DOMAIN="${DOMAIN:-carmacars.ca}"
P=$([ "$DEPLOY_ENV" = staging ] && echo carmacars-staging || echo carmacars-prod)
BUCKETS=(opennext-cache vehicle-public vehicle-originals documents identity condition-photos agreements)

token() {
  local v
  v=$(cfapi GET "/accounts/$ACC/tokens/verify" 2>/dev/null || cfapi GET "/user/tokens/verify") || die "The Cloudflare API token does not verify"
  log "token: $(jq -c '.result | {status, expires_on}' <<<"$v")"
  local probes=()
  cfapi GET "/accounts/$ACC/workers/scripts" > /dev/null 2>&1 && probes+=("workers:yes") || probes+=("workers:NO")
  cfapi GET "/accounts/$ACC/r2/buckets" > /dev/null 2>&1 && probes+=("r2:yes") || probes+=("r2:NO")
  cfapi GET "/accounts/$ACC/d1/database" > /dev/null 2>&1 && probes+=("d1:yes") || probes+=("d1:NO")
  cfapi GET "/accounts/$ACC/challenges/widgets" > /dev/null 2>&1 && probes+=("turnstile:yes") || probes+=("turnstile:NO")
  cfapi GET "/zones?name=$DOMAIN" > /dev/null 2>&1 && probes+=("zone:yes") || probes+=("zone:NO")
  notice "Cloudflare token read access: ${probes[*]}"
}

resources() {
  local b name
  for b in "${BUCKETS[@]}"; do
    name="$P-$b"
    if cfapi GET "/accounts/$ACC/r2/buckets/$name" > /dev/null 2>&1; then
      log "r2: $name exists"
    else
      cfapi POST "/accounts/$ACC/r2/buckets" "$(jq -n --arg n "$name" '{name: $n, locationHint: "enam"}')" > /dev/null \
        || die "Could not create the R2 bucket $name (the token needs Workers R2 Storage Edit)"
      notice "R2: bucket $name created"
    fi
  done
  local db="$P-tag-cache" id
  id=$(cfapi GET "/accounts/$ACC/d1/database?name=$db" | jq -r --arg n "$db" '[.result[]? | select(.name == $n)][0].uuid // empty') || id=""
  if [ -z "$id" ]; then
    id=$(cfapi POST "/accounts/$ACC/d1/database" "$(jq -n --arg n "$db" '{name: $n, primary_location_hint: "enam"}')" | jq -r '.result.uuid // empty') \
      || die "Could not create the D1 database $db (the token needs D1 Edit)"
    [ -n "$id" ] || die "Could not create the D1 database $db"
    notice "D1: database $db created"
  fi
  # the database id goes on the line naming this database (the file keeps the zero id in git)
  sed -i -E "/\"database_name\": \"$db\"/ s/\"database_id\": \"[0-9a-f-]+\"/\"database_id\": \"$id\"/" "$ROOT/web/wrangler.jsonc"
  grep -q "$id" "$ROOT/web/wrangler.jsonc" || die "Could not put the D1 id into wrangler.jsonc"
  log "d1: $db = $id"
}

turnstile() {
  local list key secret name="$DOMAIN"
  [ "$DEPLOY_ENV" = staging ] && name="staging.$DOMAIN"
  if list=$(cfapi GET "/accounts/$ACC/challenges/widgets?per_page=50" 2>/dev/null); then
    key=$(jq -r --arg n "$name" '[.result[]? | select(.name == $n)][0].sitekey // empty' <<<"$list")
    if [ -z "$key" ]; then
      local created
      if created=$(cfapi POST "/accounts/$ACC/challenges/widgets" "$(jq -n --arg n "$name" --arg d "$DOMAIN" \
            '{name: $n, domains: [$d, ("www." + $d)], mode: "managed", region: "world"}')" 2>/dev/null); then
        key=$(jq -r '.result.sitekey' <<<"$created"); secret=$(jq -r '.result.secret' <<<"$created")
        notice "Turnstile: widget $name created"
      fi
    else
      secret=$(cfapi GET "/accounts/$ACC/challenges/widgets/$key" | jq -r '.result.secret // empty') || secret=""
    fi
  fi
  if [ -n "${key:-}" ] && [ -n "${secret:-}" ]; then
    mask "$secret"
    export_env TURNSTILE_PROVIDER cloudflare
    export_env NEXT_PUBLIC_TURNSTILE_SITE_KEY "$key"
    export_env TURNSTILE_SECRET_KEY "$secret"
    log "turnstile: on ($key)"
  else
    export_env TURNSTILE_PROVIDER off
    export_env NEXT_PUBLIC_TURNSTILE_SITE_KEY ""
    warn "Turnstile is OFF: the API token cannot read or create Turnstile widgets (needs Account > Turnstile > Edit). Public forms rely on the database rate limits until it is on."
  fi
}

dns() {
  [ "$DEPLOY_ENV" = production ] || { log "dns: staging has no custom domain"; return; }
  local zone recs attached
  zone=$(cfapi GET "/zones?name=$DOMAIN" | jq -r '.result[0].id // empty') || die "The token cannot read the $DOMAIN zone"
  [ -n "$zone" ] || die "Zone $DOMAIN is not in this account"
  attached=$(cfapi GET "/accounts/$ACC/workers/domains?zone_id=$zone" 2>/dev/null | jq -r '[.result[]? | "\(.hostname)=\(.service)"] | join(" ")') || attached=""
  log "dns: worker custom domains now: ${attached:-none}"
  local h
  for h in "$DOMAIN" "www.$DOMAIN"; do
    if grep -qw "$h=$P" <<<"$attached"; then log "dns: $h already on $P"; continue; fi
    recs=$(cfapi GET "/zones/$zone/dns_records?name=$h&per_page=100" | jq -c '[.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME")]')
    local n
    n=$(jq 'length' <<<"$recs")
    [ "$n" = "0" ] && { log "dns: $h has no address record (the custom domain creates it)"; continue; }
    local r
    for r in $(jq -r '.[] | @base64' <<<"$recs"); do
      local rec
      rec=$(base64 -d <<<"$r")
      cfapi DELETE "/zones/$zone/dns_records/$(jq -r '.id' <<<"$rec")" > /dev/null || die "Could not remove $(jq -c '{type,name,content}' <<<"$rec") (the token needs DNS Edit)"
      notice "DNS: removed $(jq -r '"\(.type) \(.name) -> \(.content) (proxied \(.proxied))"' <<<"$rec") so the Worker custom domain can take $h"
    done
  done
}

photos() {
  local bucket="$P-vehicle-public" marker=".seeded/stand-in-photos-v1"
  cd "$ROOT/web"
  if npx wrangler r2 object get "$bucket/$marker" --remote --pipe > /dev/null 2>&1; then
    log "photos: already uploaded"; return
  fi
  local list
  list=$(mktemp)
  node -e '
    const fs = require("fs"), path = require("path");
    const dir = path.join(process.argv[1], "prototype/assets/photos");
    const cars = Object.keys(JSON.parse(fs.readFileSync(path.join(process.argv[1], "prototype/assets/photos.json"), "utf8")).cars);
    for (const f of fs.readdirSync(dir)) {
      const isCar = cars.some((s) => f.startsWith(s + "-"));
      console.log((isCar ? "vehicles/" : "site/") + f + "\t" + path.join(dir, f));
    }' "$ROOT" > "$list"
  log "photos: uploading $(wc -l < "$list") files to $bucket"
  # shellcheck disable=SC2016
  tr '\t' '\n' < "$list" | xargs -n 2 -P 8 sh -c 'ct=image/jpeg; case "$0" in *.svg) ct=image/svg+xml;; *.webp) ct=image/webp;; *.png) ct=image/png;; *.avif) ct=image/avif;; esac;
      npx wrangler r2 object put "'"$bucket"'/$0" --file "$1" --content-type "$ct" --cache-control "public, max-age=31536000" --remote > /dev/null 2>&1 || { echo "upload failed: $0" >&2; exit 255; }'
  echo "uploaded $(date -u +%FT%TZ)" > "$list.marker"
  npx wrangler r2 object put "$bucket/$marker" --file "$list.marker" --content-type text/plain --remote > /dev/null
  notice "Photos: $(wc -l < "$list") stand-in photos uploaded to $bucket"
  rm -f "$list" "$list.marker"
}

for step in "$@"; do "$step"; done
